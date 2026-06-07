# runner.lex — LLM handler factory for lex-agent skills.
#
# make_handler(db, cfg) returns a Skill handler closure. Each call:
#   1. Load agent state from SQL
#   2. Build system prompt (persona + state context)
#   3. Run lex-llm tool loop (platform tools + domain tools)
#   4. Write trace events
#   5. Return HandlerOutcome with the LLM reply
#
# Platform tools injected into every agent:
#   find_peers(intent)       — queries registry + relationship graph
#   send_message(to, topic, payload_json)
#                            — A2A tasks/send via lex-agent/client

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.int" as int

import "std.http" as http

import "std.bytes" as bytes

import "std.proc" as proc

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/message" as msg

import "./state_store" as state_store

import "./trace" as trace

import "./relationships" as rel

import "./registry" as reg

import "./platform/client" as pclient

import "./outbox" as outbox

# Configuration for an LLM-driven agent.
type AgentConfig = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, tools :: List[t.Tool] }

type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str }

# Selects where state, peers and outbound messages go.
#   Local  — single-process / dev: direct SQLite reads and A2A HTTP sends.
#   Remote — distributed: platform HTTP API for state/peers; outbox queue for sends.
type RemoteCtx = { client :: pclient.PlatformClient, local_db :: Db }

type Backend = BackendLocal(Db) | BackendRemote(RemoteCtx)

fn first_text(m :: msg.Message) -> Str {
  list.fold(m.parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
    if str.is_empty(acc) {
      match p {
        TextPart(s) => s,
        _ => acc,
      }
    } else {
      acc
    }
  })
}

fn build_system_prompt(cfg :: AgentConfig, state_json :: Str) -> Str {
  str.concat(cfg.system_prompt, str.concat("\n\nYour current state: ", state_json))
}

fn load_peers(db :: Db, agent_id :: Str) -> [sql, fs_read] List[PeerInfo] {
  match rel.peers_of(db, agent_id) {
    Err(_) => [],
    Ok(rels) => list.fold(rels, [], fn (acc :: List[PeerInfo], r :: rel.Relationship) -> [sql, fs_read] List[PeerInfo] {
      match reg.find_by_id(db, r.to_agent) {
        Ok(Some(ref)) => if ref.status == "active" {
          list.concat(acc, [{ id: ref.id, kind: ref.kind, name: ref.name, inbox_url: ref.inbox_url, role: r.role }])
        } else {
          acc
        },
        _ => acc,
      }
    }),
  }
}

fn intent_roles(intent :: Str) -> List[Str] {
  if intent == "charging" {
    ["preferred_charger", "charger"]
  } else {
    if intent == "dispatch" {
      ["contracted", "freelance"]
    } else {
      if intent == "reporting" {
        ["reporting"]
      } else {
        []
      }
    }
  }
}

fn load_state_backend(b :: Backend, agent_id :: Str) -> [sql, fs_read, net] Str {
  match b {
    BackendLocal(db) => state_store.load(db, agent_id),
    BackendRemote(rc) => pclient.load_state(rc.client, agent_id),
  }
}

fn load_peers_backend(b :: Backend, agent_id :: Str) -> [sql, fs_read, net] List[PeerInfo] {
  match b {
    BackendLocal(db) => load_peers(db, agent_id),
    BackendRemote(rc) => list.map(pclient.peers(rc.client, agent_id, "coordination"), fn (p :: pclient.PeerInfo) -> PeerInfo {
      { id: p.id, kind: p.kind, name: p.name, inbox_url: p.inbox_url, role: p.role }
    }),
  }
}

fn trace_db(b :: Backend) -> Db {
  match b {
    BackendLocal(db) => db,
    BackendRemote(rc) => rc.local_db,
  }
}

fn find_peer_url(peers :: List[PeerInfo], to_id :: Str) -> Option[Str] {
  list.fold(peers, None, fn (acc :: Option[Str], p :: PeerInfo) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None => if p.id == to_id {
        Some(p.inbox_url)
      } else {
        None
      },
    }
  })
}

fn make_platform_tools_for_backend(b :: Backend, peers :: List[PeerInfo], agent_id :: Str) -> List[t.Tool] {
  [t.define("find_peers", "Find active peers you are authorised to contact for a given intent. Intents: charging, dispatch, reporting, coordination.", { title: "FindPeers", description: "Peer resolution by intent.", fields: [s.required_str("intent", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let intent := match jv.get_field(args, "intent") {
      Some(JStr(sv)) => sv,
      _ => "coordination",
    }
    let roles := intent_roles(intent)
    let filtered := if list.len(roles) == 0 {
      peers
    } else {
      list.filter(peers, fn (p :: PeerInfo) -> Bool {
        list.fold(roles, false, fn (acc :: Bool, role :: Str) -> Bool {
          acc or p.role == role
        })
      })
    }
    Ok(JList(list.map(filtered, fn (p :: PeerInfo) -> jv.Json {
      JObj([("id", JStr(p.id)), ("kind", JStr(p.kind)), ("name", JStr(p.name))])
    })))
  }), t.define("send_message", "Send a message to a peer agent. Use find_peers first to get valid peer IDs.", { title: "SendMessage", description: "Send a message to another agent.", fields: [s.required_str("to_id", []), s.required_str("topic", []), s.required_str("payload_json", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let to_id := match jv.get_field(args, "to_id") {
      Some(JStr(sv)) => sv,
      _ => "",
    }
    let topic := match jv.get_field(args, "topic") {
      Some(JStr(sv)) => sv,
      _ => "",
    }
    let payload := match jv.get_field(args, "payload_json") {
      Some(JStr(sv)) => sv,
      _ => "{}",
    }
    if str.is_empty(to_id) {
      Ok(JObj([("error", JStr("to_id is required"))]))
    } else {
      match b {
        BackendLocal(_) => match find_peer_url(peers, to_id) {
          None => Ok(JObj([("error", JStr(str.concat("agent not found: ", to_id)))])),
          Some(peer_url) => {
            let body_json := JObj([("jsonrpc", JStr("2.0")), ("id", JStr("1")), ("method", JStr("tasks/send")), ("params", JObj([("id", JStr(str.concat("msg-", to_id))), ("contextId", JStr(str.concat("ctx-", agent_id))), ("skill", JStr(topic)), ("message", JObj([("role", JStr("user")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr(payload))])]))]))]))])
            match http.post(peer_url, bytes.from_str(jv.stringify(body_json)), "application/json") {
              Err(_) => Ok(JObj([("queued", JBool(false))])),
              Ok(_) => Ok(JObj([("queued", JBool(true))])),
            }
          },
        },
        BackendRemote(rc) => {
          let body := jv.stringify(JObj([("from", JStr(agent_id)), ("to", JStr(to_id)), ("topic", JStr(topic)), ("body", JStr(payload))]))
          let url := str.concat(rc.client.url, "/v1/messages")
          match http.post(url, bytes.from_str(body), "application/json") {
            Err(_) => Ok(JObj([("queued", JBool(false))])),
            Ok(_) => Ok(JObj([("queued", JBool(true))])),
          }
        },
      }
    }
  })]
}

# Core handler — backend-agnostic. Both make_handler and make_handler_remote
# delegate here.
fn make_handler_for_backend(b :: Backend, cfg :: AgentConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let tdb := trace_db(b)
    let run_id := trace.new_run_id()
    let state := load_state_backend(b, cfg.id)
    let text_in := first_text(m)
    let __t1 := trace.record(tdb, run_id, cfg.id, "received", text_in)
    let peers := load_peers_backend(b, cfg.id)
    let _platform := make_platform_tools_for_backend(b, peers, cfg.id)
    let sys := build_system_prompt(cfg, state)
    let req_file := str.concat("/tmp/llm_", str.concat(cfg.id, ".json"))
    let req_json := jv.stringify(JObj([
      ("provider", JStr(cfg.provider_name)),
      ("api_url", JStr(cfg.provider_url)),
      ("api_key", JStr(cfg.provider_key)),
      ("model", JStr(cfg.model_name)),
      ("system", JStr(sys)),
      ("user", JStr(text_in))
    ]))
    let shell_cmd := str.join([
      "set -e\ncat > ", req_file, " <<'LEXEOF'\n",
      req_json, "\n",
      "LEXEOF\n",
      "LLM_REQ_FILE=", req_file, " lex run --allow-effects net,llm,io,env,fs_read,fs_write,proc,sql,time llm_call.lex call"
    ], "")
    let __t2 := trace.record(tdb, run_id, cfg.id, "llm_start", "{}")
    let answer := match proc.spawn("sh", ["-c", shell_cmd]) {
      Err(e) => str.concat("[spawn error] ", e),
      Ok(out) => if out.exit_code != 0 {
        str.join(["[proc exit=", int.to_str(out.exit_code), "] stderr=", out.stderr], "")
      } else {
        let raw := str.trim(out.stdout)
        let stripped := match str.strip_suffix(raw, "null") {
          Some(s) => str.trim(s),
          None => raw,
        }
        if str.is_empty(stripped) {
          str.concat("[empty llm response] stderr=", out.stderr)
        } else {
          stripped
        }
      },
    }
    let __t3 := trace.record(tdb, run_id, cfg.id, "llm_done", answer)
    { next_state: TSCompleted, reply: Some(msg.agent_text(answer)), artifacts: [] }
  }
}

# Returns a lex-agent Skill handler closure backed by lex-llm.
# Captures db and cfg; loads peers fresh on every invocation so the
# relationship graph stays live.
fn make_handler(db :: Db, cfg :: AgentConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  make_handler_for_backend(BackendLocal(db), cfg)
}

# Distributed variant — state and peer discovery go through the platform HTTP
# API; outbound messages are durably queued in local_db via outbox.lex and
# flushed asynchronously by a background flush_loop. Trace is always local.
#
# Boot sequence for the caller:
#   1. outbox.init(local_db)
#   2. conc.spawn(fn () -> ... { outbox.flush_loop(local_db, platform_url, 500) })
#   3. pclient.register(client, id, kind, name, inbox_url, capabilities)
#   4. mount the handler returned here into your lex-agent srv.AgentDef
fn make_handler_remote(client :: pclient.PlatformClient, local_db :: Db, cfg :: AgentConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  make_handler_for_backend(BackendRemote({ client: client, local_db: local_db }), cfg)
}

