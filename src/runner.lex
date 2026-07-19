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

import "std.process" as process

import "lex-schema/json_value" as jv

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/message" as msg

import "./state_store" as state_store

import "./trace" as trace

import "./settlement" as settlement

import "./relationships" as rel

import "./resolver" as resolver

import "./registry" as reg

import "./platform/client" as pclient

import "./outbox" as outbox

# A backend service the agent's tools talk to, as an opaque key→url pair. The
# core never interprets these — it only carries them through to the subprocess
# (llm_call.lex) verbatim so the host can rebuild its own domain tools by key.
# Keeps the core domain-agnostic: no product-specific URL fields (was lex-soft#5).
type BackendRef = { key :: Str, url :: Str }

# Configuration for an LLM-driven agent.
#
# `backends` is a host-defined set of key→url pairs threaded through to the
# subprocess so it can rebuild this agent's domain tools and run the tool loop.
# The core treats them opaquely; only the host knows what a given key means.
type AgentConfig = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, backends :: List[BackendRef], intent_roles :: List[resolver.IntentRoles], tools :: List[t.Tool] }

type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str, token :: Str }

# A connection token (issued during the handshake) may be stored in a
# relationship's contract_json as {"token":"..."}; outbound A2A calls to that
# peer present it as a bearer token so the peer can authenticate the caller.
fn contract_token(contract :: Str) -> Str {
  match jv.parse(contract) {
    Ok(j) => match jv.get_field(j, "token") {
      Some(JStr(s)) => s,
      _ => "",
    },
    Err(_) => "",
  }
}

# Parsed result of the subprocess tool loop: the final assistant text plus
# the names of every tool the model executed (in call order).
type LoopResult = { text :: Str, tools :: List[Str] }

# User-facing fallback when the model returns nothing usable / errors / panics —
# so an agent NEVER surfaces a raw panic dump or a blank reply to the operator.
fn fallback_reply() -> Str {
  "I couldn't produce a response just now (the model returned nothing usable). Please try again in a moment."
}

# ── Peer hygiene ──────────────────────────────────────────────────────────────
# The relationship table accumulates duplicate edges across re-seeds, so a single
# agent can resolve hundreds of (mostly duplicate) peers. Dedup by id and cap, so
# the serialized peer snapshot stays small (it rides in the spawn arg, 64 KiB max).
fn list_has_str(xs :: List[Str], s :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == s
    }
  })
}

fn dedup_peers_go(xs :: List[PeerInfo], seen :: List[Str]) -> List[PeerInfo] {
  if list.is_empty(xs) {
    []
  } else {
    match list.head(xs) {
      None => [],
      Some(p) => if list_has_str(seen, p.id) {
        dedup_peers_go(list.tail(xs), seen)
      } else {
        list.cons(p, dedup_peers_go(list.tail(xs), list.cons(p.id, seen)))
      },
    }
  }
}

fn dedup_peers(xs :: List[PeerInfo]) -> List[PeerInfo] {
  dedup_peers_go(xs, [])
}

fn take_peers(xs :: List[PeerInfo], n :: Int) -> List[PeerInfo] {
  if n <= 0 or list.is_empty(xs) {
    []
  } else {
    match list.head(xs) {
      None => [],
      Some(p) => list.cons(p, take_peers(list.tail(xs), n - 1)),
    }
  }
}

# Parse the subprocess stdout — a JSON object {"text":..,"tools":[..]} —
# tolerating a trailing `null` printed by the `lex run` Unit return. Empty or
# non-JSON output degrades to a graceful fallback message (keeping any tool
# names so the audit still shows what ran).
fn parse_loop_out(stdout :: Str, _stderr :: Str) -> LoopResult {
  let raw := str.trim(stdout)
  let stripped := match str.strip_suffix(raw, "null") {
    Some(s) => str.trim(s),
    None => raw,
  }
  if str.is_empty(stripped) {
    { text: fallback_reply(), tools: [] }
  } else {
    match jv.parse(stripped) {
      Err(_) => { text: fallback_reply(), tools: [] },
      Ok(j) => {
        let raw_text := match jv.get_field(j, "text") {
          Some(JStr(s)) => s,
          _ => "",
        }
        let tools := match jv.get_field(j, "tools") {
          Some(JList(xs)) => list.fold(xs, [], fn (acc :: List[Str], x :: jv.Json) -> List[Str] {
            match x {
              JStr(s) => list.concat(acc, [s]),
              _ => acc,
            }
          }),
          _ => [],
        }
        let text := if str.is_empty(str.trim(raw_text)) {
          fallback_reply()
        } else {
          raw_text
        }
        { text: text, tools: tools }
      },
    }
  }
}

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
          list.concat(acc, [{ id: ref.id, kind: ref.kind, name: ref.name, inbox_url: ref.inbox_url, role: r.role, token: contract_token(r.contract_json) }])
        } else {
          acc
        },
        _ => acc,
      }
    }),
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
      { id: p.id, kind: p.kind, name: p.name, inbox_url: p.inbox_url, role: p.role, token: "" }
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

# Core handler — backend-agnostic. Both make_handler and make_handler_remote
# delegate here.
# The handler's run_id derivation: the A2A contextId IS the conversation key —
# traces of this turn are recorded under it, and only that conversation's turns
# feed the model (#46 — the fabricate-from-stale-history failure). No contextId
# from the transport -> fresh random run_id + agent-global history, as before.
fn make_handler_for_backend(b :: Backend, cfg :: AgentConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let tdb := trace_db(b)
    let run_id := if str.is_empty(m.context_id) {
      trace.new_run_id()
    } else {
      m.context_id
    }
    let state := load_state_backend(b, cfg.id)
    let text_in := first_text(m)
    let history_json := trace.recent_messages_json_for(tdb, cfg.id, m.context_id, 8)
    let history := match jv.parse(history_json) {
      Ok(h) => h,
      Err(_) => JList([]),
    }
    let __t1 := trace.record(tdb, run_id, cfg.id, "received", text_in)
    let peers := take_peers(dedup_peers(load_peers_backend(b, cfg.id)), 50)
    let sys_base := build_system_prompt(cfg, state)
    let mem := trace.recall_facts_text(tdb, cfg.id, 8)
    let sys := if str.is_empty(mem) {
      sys_base
    } else {
      str.concat(sys_base, str.concat("\n\nDurable memory (facts you have remembered, honor them):\n", mem))
    }
    let agent_tenant := match reg.find_by_id(trace_db(b), cfg.id) {
      Ok(Some(a)) => a.tenant,
      _ => "",
    }
    let req_file := str.concat("/tmp/llm_", str.concat(cfg.id, ".json"))
    let req_json := jv.stringify(JObj([("provider", JStr(cfg.provider_name)), ("api_url", JStr(cfg.provider_url)), ("api_key", JStr(cfg.provider_key)), ("model", JStr(cfg.model_name)), ("system", JStr(sys)), ("user", JStr(text_in)), ("history", history), ("kind", JStr(cfg.kind)), ("agent_id", JStr(cfg.id)), ("tenant", JStr(agent_tenant)), ("peers", JList(list.map(peers, fn (p :: PeerInfo) -> jv.Json {
      JObj([("id", JStr(p.id)), ("kind", JStr(p.kind)), ("name", JStr(p.name)), ("inbox_url", JStr(p.inbox_url)), ("role", JStr(p.role)), ("token", JStr(p.token))])
    }))), ("backends", JObj(list.map(cfg.backends, fn (bk :: BackendRef) -> (Str, jv.Json) {
      (bk.key, JStr(bk.url))
    }))), ("intent_roles", JList(list.map(cfg.intent_roles, fn (ir :: resolver.IntentRoles) -> jv.Json {
      JObj([("intent", JStr(ir.intent)), ("roles", JList(list.map(ir.roles, fn (rl :: Str) -> jv.Json {
        JStr(rl)
      })))])
    })))]))
    let shell_cmd := str.join(["umask 077\nset -e\ntrap 'rm -f ", req_file, "' EXIT\ncat > ", req_file, " <<'LEXEOF'\n", req_json, "\n", "LEXEOF\n", "LLM_REQ_FILE=", req_file, " lex run --allow-effects net,llm,io,env,fs_read,fs_write,proc,sql,time,concurrent,crypto,random llm_call.lex call"], "")
    let __t2 := trace.record(tdb, run_id, cfg.id, "llm_start", "{}")
    let outcome := match process.run("sh", ["-c", shell_cmd]) {
      Err(e) => { result: { text: fallback_reply(), tools: [] }, err: str.concat("spawn failed: ", e) },
      Ok(out) => if out.exit_code != 0 {
        { result: { text: fallback_reply(), tools: [] }, err: str.join(["subprocess exit ", int.to_str(out.exit_code), ": ", out.stderr], "") }
      } else {
        { result: parse_loop_out(out.stdout, out.stderr), err: "" }
      },
    }
    let result := outcome.result
    let __terr := if str.is_empty(outcome.err) {
      ()
    } else {
      trace.record(tdb, run_id, cfg.id, "error", outcome.err)
    }
    let answer := result.text
    let __t_tools := list.fold(result.tools, (), fn (_acc :: Unit, tname :: Str) -> [sql, fs_write, time, random, crypto] Unit {
      let __r := trace.record(tdb, run_id, cfg.id, "tool_call", tname)
      ()
    })
    let __t3 := trace.record(tdb, run_id, cfg.id, "llm_done", answer)
    let trail_id := settlement.record_run(settlement.trail_on(tdb), cfg.id, "handle", text_in, answer, result.tools)
    let trail_artifact := { name: "trail", index: 0, parts: [DataPart(JObj([("trail_id", JStr(trail_id)), ("verify_url", JStr(str.concat("/trails/", trail_id)))]))] }
    let escalated := list.fold(result.tools, false, fn (acc :: Bool, tname :: Str) -> Bool {
      acc or tname == "escalate"
    })
    if escalated {
      let __t4 := trace.record(tdb, run_id, cfg.id, "escalated", answer)
      let esc_artifact := { name: "escalation", index: 1, parts: [DataPart(JObj([("status", JStr("input-required")), ("approvals_url", JStr("/approvals")), ("resume", JStr("re-send tasks/send with the same contextId once the human decides"))]))] }
      { next_state: TSInputRequired, reply: Some(msg.agent_text(answer)), artifacts: [trail_artifact, esc_artifact] }
    } else {
      { next_state: TSCompleted, reply: Some(msg.agent_text(answer)), artifacts: [trail_artifact] }
    }
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

