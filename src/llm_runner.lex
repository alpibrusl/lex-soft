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

import "lex-agent-llm/src/bridge" as bridge

import "std.str" as str

import "./mesh" as mesh

import "./resolver" as resolver

import "./escalation" as escalation

# Parse the host's intent→roles map out of the request JSON (serialized by the
# caller's runner). Absent/malformed → empty map = find_peers matches any peer.
fn parse_intent_map(j :: jv.Json) -> List[resolver.IntentRoles] {
  match jv.get_field(j, "intent_roles") {
    Some(JList(xs)) => list.fold(xs, [], fn (acc :: List[resolver.IntentRoles], item :: jv.Json) -> List[resolver.IntentRoles] {
      let intent := match jv.get_field(item, "intent") {
        Some(JStr(sv)) => sv,
        _ => "",
      }
      let roles := match jv.get_field(item, "roles") {
        Some(JList(rs)) => list.fold(rs, [], fn (racc :: List[Str], r :: jv.Json) -> List[Str] {
          match r {
            JStr(rv) => list.concat(racc, [rv]),
            _ => racc,
          }
        }),
        _ => [],
      }
      if str.is_empty(intent) {
        acc
      } else {
        list.concat(acc, [{ intent: intent, roles: roles }])
      }
    }),
    _ => [],
  }
}

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

fn run_json(j :: jv.Json, tool_factory :: (jv.Json) -> List[t.Tool]) -> [net, llm, io, env, proc] Str {
  let provider_name := get_str(j, "provider", "vertex")
  let api_url := get_str(j, "api_url", "")
  let api_key := get_str(j, "api_key", "")
  let model := get_str(j, "model", "")
  let system := get_str(j, "system", "")
  let user := get_str(j, "user", "")
  let agent_id := get_str(j, "agent_id", "")
  let history := match jv.get_field(j, "history") {
    Some(JList(xs)) => xs,
    _ => [],
  }
  let provider := providers.select_provider(provider_name, api_url, api_key)
  let model_ref := prov.make_model_ref(provider.name, model)
  let hist_msgs := list.map(history, fn (h :: jv.Json) -> msg.Message {
    let role := match jv.get_field(h, "role") {
      Some(JStr(s)) => s,
      _ => "user",
    }
    let txt := match jv.get_field(h, "text") {
      Some(JStr(s)) => s,
      _ => "",
    }
    if role == "agent" {
      AssistantMsg(txt, [])
    } else {
      UserMsg(txt)
    }
  })
  let peers := match jv.get_field(j, "peers") {
    Some(JList(xs)) => xs,
    _ => [],
  }
  let gateway_url := match env.get("HUMAN_GATEWAY_URL") {
    Some(u) => u,
    None => "",
  }
  let esc_tools := if str.is_empty(str.trim(gateway_url)) {
    []
  } else {
    [escalation.make_escalate_tool(agent_id, gateway_url)]
  }
  let tools := list.concat(list.concat(tool_factory(j), mesh.make_mesh_tools(agent_id, peers, parse_intent_map(j))), esc_tools)
  let conv := list.concat(hist_msgs, [UserMsg(user)])
  let agent := ag.make_agent(agent_id, system, model_ref, provider, tools, ag.default_options())
  let steps := iter.to_list(ag.run_loop(agent, conv))
  let out := bridge.collect(steps)
  jv.stringify(JObj([("text", JStr(out.text)), ("tools", JList(list.map(out.tools, fn (n :: Str) -> jv.Json {
    JStr(n)
  })))]))
}

