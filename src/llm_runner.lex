# llm_runner.lex — Generic agent tool-loop subprocess entry point (lex-soft).
#
# runner.lex spawns a subprocess to run the LLM tool loop (working around the
# net.serve_fn outbound-HTTP limitation: in-process handlers can't make outbound
# calls, so the LLM call AND the domain tool calls must run in a fresh process).
#
# Every lex-soft app shares THIS loop. An app only supplies a tool-factory
# closure: given the parsed request JSON, return the agent's domain tools (which
# are closures over service URLs, so they cannot cross the subprocess boundary
# and must be reconstructed here). The app's own llm_call.lex is then a few lines:
#
#   import "lex-soft/src/llm_runner" as runner
#   fn call() -> [net, llm, io, env, fs_read, proc] Unit {
#     runner.run(fn (j :: jv.Json) -> List[t.Tool] { ...build tools from j... })
#   }
#
# Request JSON (from $LLM_REQ_FILE), written by runner.lex:
#   { "provider", "api_url", "api_key", "model", "system", "user",
#     "history": [ {"role":"user|agent","text":"..."}, ... ],
#     "agent_id", + any app-specific fields the tool factory reads (kind, urls) }
#
# Prints { "text": "<final assistant text>", "tools": ["<tool name>", ...] }.

import "std.env" as env

import "std.io" as io

import "std.list" as list

import "std.iter" as iter

import "lex-schema/json_value" as jv

import "lex-llm/src/providers" as providers

import "lex-llm/src/provider" as prov

import "lex-llm/src/message" as msg

import "lex-llm/src/tool" as t

import "lex-llm/src/agent" as ag

import "lex-llm/src/delta" as d

import "./mesh" as mesh

type LoopOut = { text :: Str, tools :: List[Str] }

# Entry point: read the request file, build the agent from a caller tool factory,
# run the loop, and print the {text, tools} result. `tool_factory` receives the
# parsed request JSON so the app can pull whatever it needs (kind, agent_id,
# service URLs) to construct its domain tools.
fn run(tool_factory :: (jv.Json) -> List[t.Tool]) -> [net, llm, io, env, fs_read, proc] Unit {
  let req_file := match env.get("LLM_REQ_FILE") {
    None => "/tmp/llm_req.json",
    Some(f) => f,
  }
  match io.read(req_file) {
    Err(_) => io.print(empty_out()),
    Ok(raw) => match jv.parse(raw) {
      Err(_) => io.print(empty_out()),
      Ok(j) => io.print(run_json(j, tool_factory)),
    },
  }
}

fn empty_out() -> Str {
  jv.stringify(JObj([("text", JStr("")), ("tools", JList([]))]))
}

fn get_str(j :: jv.Json, key :: Str, default :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => default,
  }
}

# Fold the step stream into final text + executed tool names (in order).
fn collect_loop(steps :: List[d.Step]) -> LoopOut {
  list.fold(steps, { text: "", tools: [] }, fn (acc :: LoopOut, st :: d.Step) -> LoopOut {
    match st {
      StepDone(m) => { text: msg.content(m), tools: acc.tools },
      StepToolExec(name, _id) => { text: acc.text, tools: list.concat(acc.tools, [name]) },
      _ => acc,
    }
  })
}

fn run_json(j :: jv.Json, tool_factory :: (jv.Json) -> List[t.Tool]) -> [net, llm, io, proc] Str {
  let provider_name := get_str(j, "provider", "vertex")
  let api_url := get_str(j, "api_url", "")
  let api_key := get_str(j, "api_key", "")
  let model := get_str(j, "model", "")
  let system := get_str(j, "system", "")
  let user := get_str(j, "user", "")
  let agent_id := get_str(j, "agent_id", "")
  # Prior-interaction context, passed as real conversation turns (more robust
  # than stuffing transcript into the system prompt).
  let history := match jv.get_field(j, "history") {
    Some(JList(xs)) => xs,
    _ => [],
  }
  let provider := providers.select_provider(provider_name, api_url, api_key)
  let model_ref := prov.make_model_ref(provider.name, model)
  let hist_msgs := list.map(history, fn (h :: jv.Json) -> msg.Message {
    let role := match jv.get_field(h, "role") { Some(JStr(s)) => s, _ => "user" }
    let txt := match jv.get_field(h, "text") { Some(JStr(s)) => s, _ => "" }
    if role == "agent" { AssistantMsg(txt, []) } else { UserMsg(txt) }
  })
  # Domain tools (app-supplied) + the agent-mesh tools (find_peers/send_message),
  # rebuilt from the `peers` snapshot the parent serialized into the request — so
  # outbound agent-to-agent works in the subprocess loop, including to external
  # peers onboarded via POST /peers.
  let peers := match jv.get_field(j, "peers") {
    Some(JList(xs)) => xs,
    _ => [],
  }
  let tools := list.concat(tool_factory(j), mesh.make_mesh_tools(agent_id, peers))
  # run_loop prepends SystemMsg(agent.goal) itself, so the goal carries the
  # system prompt and the conversation is just history + the new user turn.
  let conv := list.concat(hist_msgs, [UserMsg(user)])
  let agent := ag.make_agent(agent_id, system, model_ref, provider, tools, ag.default_options())
  let steps := iter.to_list(ag.run_loop(agent, conv))
  let out := collect_loop(steps)
  jv.stringify(JObj([
    ("text", JStr(out.text)),
    ("tools", JList(list.map(out.tools, fn (n :: Str) -> jv.Json { JStr(n) })))
  ]))
}
