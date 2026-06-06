# runner.lex — LLM-driven step loop.
#
# Each incoming A2A message is handled by:
#   1. Load agent state from SQL
#   2. Inject state + message into an LLM conversation
#   3. Run the lex-llm tool loop with platform tools + agent domain tools
#   4. Save updated state
#   5. Write trace events
#
# AgentDef carries the agent's identity and the domain-specific tools
# it contributes on top of the platform tools (find_peers, send_message).

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as llm_msg

import "lex-llm/src/delta" as d

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers" as providers

import "./state_store" as state_store

import "./trace" as trace

import "./relationships" as rel

import "./registry" as reg

type AgentDef = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider :: prov.Provider, tools :: List[t.Tool] }

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

fn state_context(state_json :: Str) -> Str {
  str.concat("Your current state: ", state_json)
}

fn build_system_prompt(def :: AgentDef, state_json :: Str) -> Str {
  str.concat(def.system_prompt, str.concat("\n\n", state_context(state_json)))
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

fn platform_tools(db :: Db, agent_id :: Str) -> [sql, fs_read] List[t.Tool] {
  let peers := load_peers(db, agent_id)
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
  }), t.define("send_message", "Send an A2A message to a peer agent. Use find_peers first to get valid peer IDs.", { title: "SendMessage", description: "Send a message to another agent.", fields: [s.required_str("to_id", []), s.required_str("topic", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
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
      let peer_opt := list.fold(peers, None, fn (acc :: Option[PeerInfo], p :: PeerInfo) -> Option[PeerInfo] {
        match acc {
          Some(_) => acc,
          None => if p.id == to_id {
            Some(p)
          } else {
            None
          },
        }
      })
      match peer_opt {
        None => Ok(JObj([("error", JStr(str.concat("agent not found: ", to_id)))])),
        Some(peer) => {
          let body := jv.stringify(JObj([("from", JStr(agent_id)), ("topic", JStr(topic)), ("payload_json", JStr(payload))]))
          match http.post(peer.inbox_url, bytes.from_str(body), "application/json") {
            Err(_) => Ok(JObj([("error", JStr("send failed"))])),
            Ok(_) => Ok(JObj([("sent", JBool(true))])),
          }
        },
      }
    }
  })]
}

fn step(db :: Db, def :: AgentDef, msg_json :: Str) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, env] Str {
  let run_id := trace.new_run_id()
  let state := state_store.load(db, def.id)
  let _t1 := trace.record(db, run_id, def.id, "received", msg_json)
  let sys := build_system_prompt(def, state)
  let all_tools := list.concat(platform_tools(db, def.id), def.tools)
  let the_model := prov.make_model_ref(def.provider.name, def.model_name)
  let llm_def := { name: def.id, goal: sys, model: the_model, provider: def.provider, tools: all_tools, options: llm_agent.default_options(), permission_spec: None }
  let conv := [llm_msg.UserMsg(msg_json)]
  let _t2 := trace.record(db, run_id, def.id, "llm_start", "{}")
  let steps := iter.to_list(llm_agent.run_loop(llm_def, conv))
  let answer := extract_answer(steps)
  let _t3 := trace.record(db, run_id, def.id, "llm_done", jv.stringify(JStr(answer)))
  answer
}

