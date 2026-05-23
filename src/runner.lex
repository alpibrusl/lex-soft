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

import "std.sql" as sql
import "std.str" as str
import "std.list" as list
import "std.iter" as iter
import "lex-schema/json_value" as jv
import "lex-llm/src/agent" as llm_agent
import "lex-llm/src/message" as llm_msg
import "lex-llm/src/delta" as d
import "lex-llm/src/tool" as t
import "lex-llm/src/providers" as providers
import "./state_store" as state_store
import "./trace" as trace
import "./resolver" as resolver
import "./a2a" as a2a
import "./registry" as reg

type AgentDef = {
  id            :: Str,
  kind          :: Str,
  system_prompt :: Str,
  model_name    :: Str,
  provider      :: providers.Provider,
  tools         :: List[t.Tool],
}

fn extract_answer(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, step :: d.Step) -> Str {
    match step {
      StepDone(m) => {
        let c := llm_msg.content(m)
        if str.is_empty(c) { acc } else { c }
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

fn platform_tools(db :: sql.Db, agent_id :: Str) -> List[t.Tool] {
  [
    t.define(
      "find_peers",
      "Find active peers you are authorised to contact for a given intent. Intents: charging, dispatch, reporting, coordination.",
      { title: "FindPeers", description: "Peer resolution by intent.", fields: [{ name: "intent", type: "string", required: true, description: "The interaction intent.", constraints: [] }] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let intent := match jv.get_field(args, "intent") {
          Some(JStr(s)) => s,
          _ => "coordination",
        }
        match resolver.resolve(db, agent_id, intent) {
          Err(e) => Ok(JObj([("error", JStr(e))])),
          Ok(peers) => Ok(JArr(list.map(peers, fn (p :: reg.AgentRef) -> jv.Json {
            JObj([("id", JStr(p.id)), ("kind", JStr(p.kind)), ("name", JStr(p.name))])
          }))),
        }
      }
    ),
    t.define(
      "send_message",
      "Send an A2A message to a peer agent. Use find_peers first to get valid peer IDs.",
      { title: "SendMessage", description: "Send a message to another agent.", fields: [
        { name: "to_id",       type: "string", required: true,  description: "Recipient agent ID.",  constraints: [] },
        { name: "topic",       type: "string", required: true,  description: "Message topic/intent.", constraints: [] },
        { name: "payload_json", type: "string", required: false, description: "JSON payload string.", constraints: [] },
      ] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let to_id   := match jv.get_field(args, "to_id")   { Some(JStr(s)) => s, _ => "" }
        let topic   := match jv.get_field(args, "topic")   { Some(JStr(s)) => s, _ => "" }
        let payload := match jv.get_field(args, "payload_json") { Some(JStr(s)) => s, _ => "{}" }
        if str.is_empty(to_id) {
          Ok(JObj([("error", JStr("to_id is required"))]))
        } else {
          match a2a.send(db, agent_id, to_id, topic, payload) {
            Err(e) => Ok(JObj([("error", JStr(e))])),
            Ok(_)  => Ok(JObj([("sent", JBool(true))])),
          }
        }
      }
    ),
  ]
}

fn step(
  db      :: sql.Db,
  def     :: AgentDef,
  msg_json :: Str,
) -> [io, time, sql, concurrent, net, crypto, random, fs_read, fs_write] Str {
  let run_id   := trace.new_run_id()
  let state    := state_store.load(db, def.id)
  let _t1      := trace.record(db, run_id, def.id, "received", msg_json)
  let sys      := build_system_prompt(def, state)
  let all_tools := list.concat(platform_tools(db, def.id), def.tools)
  let the_model := { provider: def.provider.name, model: def.model_name }
  let llm_def  := {
    name:     def.id,
    goal:     sys,
    model:    the_model,
    provider: def.provider,
    tools:    all_tools,
    options:  llm_agent.default_options(),
  }
  let conv   := [llm_msg.UserMsg(msg_json)]
  let _t2    := trace.record(db, run_id, def.id, "llm_start", "{}")
  let steps  := iter.to_list(llm_agent.run_loop(llm_def, conv))
  let answer := extract_answer(steps)
  let _t3    := trace.record(db, run_id, def.id, "llm_done", jv.stringify(JStr(answer)))
  answer
}
