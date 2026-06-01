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

import "std.iter" as iter

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as llm_msg

import "lex-llm/src/delta" as d

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-agent/src/server" as srv

import "lex-agent/src/message" as msg

import "lex-agent/src/client" as a2a_client

import "./state_store" as state_store

import "./trace" as trace

import "./relationships" as rel

import "./registry" as reg

# Configuration for an LLM-driven agent.
type AgentConfig = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider :: prov.Provider, tools :: List[t.Tool] }

type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str }

fn extract_answer(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, st :: d.Step) -> Str {
    match st {
      StepDone(m) => {
        let c := llm_msg.content(m)
        if str.is_empty(c) {
          acc
        } else {
          c
        }
      },
      _ => acc,
    }
  })
}

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

fn make_platform_tools(peers :: List[PeerInfo], agent_id :: Str) -> List[t.Tool] {
  [
    t.define(
      "find_peers",
      "Find active peers you are authorised to contact for a given intent. Intents: charging, dispatch, reporting, coordination.",
      { title: "FindPeers", description: "Peer resolution by intent.", fields: [s.required_str("intent", [])] },
      fn (args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, e.Errors] {
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
      }
    ),
    t.define(
      "send_message",
      "Send an A2A message to a peer agent via tasks/send. Use find_peers first to get valid peer IDs.",
      {
        title: "SendMessage",
        description: "Send a message to another agent.",
        fields: [s.required_str("to_id", []), s.required_str("topic", []), s.required_str("payload_json", [])],
      },
      fn (args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, e.Errors] {
        let to_id   := match jv.get_field(args, "to_id")        { Some(JStr(sv)) => sv, _ => "" }
        let topic   := match jv.get_field(args, "topic")        { Some(JStr(sv)) => sv, _ => "" }
        let payload := match jv.get_field(args, "payload_json") { Some(JStr(sv)) => sv, _ => "{}" }
        if str.is_empty(to_id) {
          Ok(JObj([("error", JStr("to_id is required"))]))
        } else {
          match find_peer_url(peers, to_id) {
            None => Ok(JObj([("error", JStr(str.concat("agent not found: ", to_id)))])),
            Some(peer_url) => {
              let m    := msg.user_text(payload)
              let opts := { task_id: str.concat("msg-", to_id), context_id: agent_id, skill: topic }
              match a2a_client.send_task(peer_url, m, opts) {
                Err(_) => Ok(JObj([("sent", JBool(false))])),
                Ok(_)  => Ok(JObj([("sent", JBool(true))])),
              }
            },
          }
        }
      }
    ),
  ]
}

# Returns a lex-agent Skill handler closure backed by lex-llm.
# Captures db and cfg; loads peers fresh on every invocation so the
# relationship graph stays live.
fn make_handler(db :: Db, cfg :: AgentConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let run_id    := trace.new_run_id()
    let state     := state_store.load(db, cfg.id)
    let text_in   := first_text(m)
    let __t1      := trace.record(db, run_id, cfg.id, "received", text_in)
    let peers     := load_peers(db, cfg.id)
    let platform  := make_platform_tools(peers, cfg.id)
    let all_tools := list.concat(platform, cfg.tools)
    let sys       := build_system_prompt(cfg, state)
    let the_model := { provider: cfg.provider.name, model: cfg.model_name }
    let llm_def   := { name: cfg.id, goal: sys, model: the_model, provider: cfg.provider, tools: all_tools, options: llm_agent.default_options() }
    let conv      := [llm_msg.UserMsg(text_in)]
    let __t2      := trace.record(db, run_id, cfg.id, "llm_start", "{}")
    let steps     := iter.to_list(llm_agent.run_loop(llm_def, conv))
    let answer    := extract_answer(steps)
    let __t3      := trace.record(db, run_id, cfg.id, "llm_done", answer)
    { next_state: TSCompleted, reply: Some(msg.agent_text(answer)), artifacts: [] }
  }
}
