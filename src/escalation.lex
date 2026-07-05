# escalation.lex — the agent-side `escalate` tool (#50/#51).
#
# When an agent's LLM hits an autonomy boundary it cannot resolve on its own —
# an action over its spend cap, a low-trust counterparty, a policy-inconclusive
# or irreversible step — it calls `escalate(question, kind, detail)`. The tool
# sends a normal A2A `tasks/send` (skill `approval.request`) to the HUMAN
# GATEWAY agent (see human_gateway.lex): the human is just another agent in the
# directory, so the escalation is plain agent-to-agent traffic — nothing
# lex-specific, and any framework that speaks A2A can escalate the same way.
#
# The gateway assigns an approval id and replies immediately; the requester's
# OWN task then pauses in the A2A `input-required` state (runner.lex flips the
# outcome when it sees `escalate` among the called tools). A human decides at
# the gateway (dashboard / GET-POST /approvals); the caller re-sends on the
# same contextId to resume.
#
# This tool runs inside the llm_runner SUBPROCESS (which, unlike serve
# handlers, can make outbound HTTP). It is appended to every agent's tool set
# when the deployment sets HUMAN_GATEWAY_URL.

import "std.str" as str

import "std.map" as map

import "std.bytes" as bytes

import "std.http" as http

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# The requester's message to the gateway: a JSON text part the gateway parses.
fn request_body(agent_id :: Str, question :: Str, kind :: Str, detail :: Str) -> Str {
  let payload := jv.stringify(JObj([("from_agent", JStr(agent_id)), ("question", JStr(question)), ("kind", JStr(kind)), ("detail", JStr(detail))]))
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", JStr("1")), ("method", JStr("tasks/send")), ("params", JObj([("id", JStr(str.concat("esc-", agent_id))), ("contextId", JStr(str.concat("ctx-", agent_id))), ("skill", JStr("approval.request")), ("message", JObj([("role", JStr("user")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr(payload))])]))]))]))]))
}

# Pull the gateway's reply text (the {"approval_id", "status"} JSON) out of the
# A2A task result: result.message.parts[0].text.
fn reply_text(task_json :: jv.Json) -> Str {
  match jv.get_field(task_json, "result") {
    None => "",
    Some(res) => match jv.get_field(res, "message") {
      None => "",
      Some(m) => match jv.get_field(m, "parts") {
        Some(JList(parts)) => list.fold(parts, "", fn (acc :: Str, p :: jv.Json) -> Str {
          if str.is_empty(acc) {
            jstr(p, "text")
          } else {
            acc
          }
        }),
        _ => "",
      },
    },
  }
}

fn post_gateway(url :: Str, body :: Str) -> [net, io, proc] Result[jv.Json, e.Errors] {
  let base := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req := http.with_header(base, "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => Ok(JObj([("delivered", JBool(false)), ("error", JStr("gateway unreachable"))])),
    Ok(r) => if r.status >= 400 {
      Ok(JObj([("delivered", JBool(false)), ("status", JInt(r.status))]))
    } else {
      match bytes.to_str(r.body) {
        Err(_) => Ok(JObj([("delivered", JBool(true))])),
        Ok(txt) => match jv.parse(txt) {
          Err(_) => Ok(JObj([("delivered", JBool(true)), ("reply_raw", JStr(txt))])),
          Ok(task) => match jv.parse(reply_text(task)) {
            Err(_) => Ok(JObj([("delivered", JBool(true)), ("reply_raw", JStr(reply_text(task)))])),
            Ok(inner) => Ok(inner),
          },
        },
      }
    },
  }
}

# Build the escalate tool for one agent. The description is the policy the LLM
# follows — escalation is the exception path, not the default.
fn make_escalate_tool(agent_id :: Str, gateway_url :: Str) -> t.Tool {
  t.define("escalate", "Ask a HUMAN for approval. Use ONLY when you hit a boundary you cannot resolve autonomously: an action exceeding your spend cap or budget token, a counterparty you do not trust, an irreversible or policy-ambiguous action, or conflicting instructions. Returns an approval_id. After calling this, END your reply by telling the requester the task is paused pending human approval and include the approval_id. kind is one of: spend, trust, policy, other.", { title: "Escalate", description: "Request human approval for an action you cannot take autonomously.", fields: [sch.required_str("question", []), sch.required_str("kind", []), sch.required_str("detail", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    post_gateway(gateway_url, request_body(agent_id, jstr(args, "question"), jstr(args, "kind"), jstr(args, "detail")))
  })
}

