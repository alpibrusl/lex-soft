# external_agent.lex — front a GENERIC external A2A endpoint with an audited,
# platform-recording handler (#225).
#
# A third party runs their own A2A agent (Google-A2A, LangGraph, an OpenAI-SDK
# app — anything that speaks `tasks/send`) at some inbox URL. Registering it as
# a registry-only peer (federation.register_peer_json) makes it routable but
# INVISIBLE to /audit: the caller reaches the external inbox directly and the
# node never sees the exchange — the external-inbox blind spot documented in
# #224.
#
# The adapter closes that gap WITHOUT asking the third party to adopt the agent
# kit. The platform mounts a normal `srv.AgentDef` (federation.mount_agent)
# whose handler PROXY-RECORDS:
#   1. record `received` on the local trace,
#   2. forward the task to the external inbox (synchronous A2A `tasks/send`),
#   3. record the interaction to the settlement trail (record_dispatch),
#   4. return the external agent's own reply.
# The mounted id lives on the platform, so discovery, capability gating, usage
# metering and /audit all treat it as a first-class agent, while the external
# endpoint stays exactly as its owner wrote it.
#
# Idempotency with the node-side recorder (#224): the handler embeds a
# `trail_id` artifact (as the runner does), so federation.mount_agent's
# post-dispatch guard sees it and skips its own record_dispatch — the
# interaction is recorded once, here, where the reply text is known.
#
# Auth: the forward reuses the platform's own outbound path (mesh.post_a2a), so
# `forward_token` (when set) rides as `Authorization: Bearer <token>` and the
# request text is stamped with the platform agent id — the external endpoint can
# authenticate and attribute the caller exactly as a peer agent would.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "./mesh" as mesh

import "./settlement" as settlement

import "./trace" as trace

# One external endpoint to front. `id` is the platform-side agent id (the mount
# path + the audit/discovery identity); `inbox_url` is where the external agent
# actually listens; `skill` names the capability the card advertises (and the
# skill forwarded onward); `forward_token` (optional) is presented to the
# external inbox as a bearer token; `card_url` is this agent's own base url on
# the node.
type ExternalConfig = { id :: Str, inbox_url :: Str, skill :: Str, forward_token :: Str, description :: Str, version :: Str, card_url :: Str }

# First text part of an inbound message (the request text we forward + record).
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

# First text part inside a serialized `parts` array (wire shape
# {"type":"text","text":...}). "" if none.
fn parts_text(parts :: jv.Json) -> Str {
  match parts {
    JList(items) => list.fold(items, "", fn (acc :: Str, it :: jv.Json) -> Str {
      if str.is_empty(acc) {
        match jv.get_field(it, "text") {
          Some(JStr(s)) => s,
          _ => acc,
        }
      } else {
        acc
      }
    }),
    _ => "",
  }
}

# Text of a message object's parts, given the parent object and the field the
# message lives under ("" if absent).
fn msg_field_text(obj :: jv.Json, field :: Str) -> Str {
  match jv.get_field(obj, field) {
    Some(mo) => match jv.get_field(mo, "parts") {
      Some(p) => parts_text(p),
      None => "",
    },
    None => "",
  }
}

# Best-effort reply text from an A2A `tasks/send` result envelope (a Task or a
# bare Message). Tries, in order: the terminal `message`, `status.message`, a
# top-level `parts`, then the first artifact's parts; falls back to the raw JSON
# so a non-empty answer is ALWAYS recorded (a blank trail would be worse than a
# verbatim one).
fn reply_text(result :: jv.Json) -> Str {
  let from_msg := msg_field_text(result, "message")
  if not str.is_empty(from_msg) {
    from_msg
  } else {
    let from_status := msg_field_text(result, "status")
    if not str.is_empty(from_status) {
      from_status
    } else {
      let from_parts := match jv.get_field(result, "parts") {
        Some(p) => parts_text(p),
        None => "",
      }
      if not str.is_empty(from_parts) {
        from_parts
      } else {
        let from_art := match jv.get_field(result, "artifacts") {
          Some(JList(arts)) => match list.head(arts) {
            Some(a) => match jv.get_field(a, "parts") {
              Some(p) => parts_text(p),
              None => "",
            },
            None => "",
          },
          _ => "",
        }
        if str.is_empty(from_art) {
          jv.stringify(result)
        } else {
          from_art
        }
      }
    }
  }
}

# The proxy-record handler. Records the inbound turn, forwards it to the
# external inbox, records the interaction to the trail, and returns the external
# agent's reply plus a `trail_id` artifact (so the node-side recorder skips it).
fn make_handler(db :: Db, ec :: ExternalConfig) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let run_id := if str.is_empty(m.context_id) {
      trace.new_run_id()
    } else {
      m.context_id
    }
    let text_in := first_text(m)
    let __t1 := trace.record(db, run_id, ec.id, "received", text_in)
    let __t2 := trace.record(db, run_id, ec.id, "forwarded", ec.inbox_url)
    let body := jv.stringify(mesh.send_body(ec.id, ec.id, ec.skill, text_in))
    let answer := match mesh.post_a2a(ec.inbox_url, ec.forward_token, body) {
      Err(_) => "external agent unreachable",
      Ok(reply) => match jv.get_field(reply, "reply_raw") {
        Some(JStr(raw)) => match jv.parse(raw) {
          Ok(j) => reply_text(match jv.get_field(j, "result") {
            Some(r) => r,
            None => j,
          }),
          Err(_) => raw,
        },
        _ => "external agent did not deliver the task",
      },
    }
    let __t3 := trace.record(db, run_id, ec.id, "reply", answer)
    let trail_id := settlement.record_dispatch(settlement.trail_on(db), ec.id, ec.skill, text_in, answer)
    let trail_artifact := { name: "trail", index: 0, parts: [DataPart(JObj([("trail_id", JStr(trail_id)), ("verify_url", JStr(str.concat("/trails/", trail_id)))]))] }
    { next_state: tk.TSCompleted, reply: Some(msg.agent_text(answer)), artifacts: [trail_artifact] }
  }
}

# The capability the fronted agent advertises. A single inbound skill whose
# message text is forwarded verbatim to the external endpoint.
fn adapter_capability(ec :: ExternalConfig) -> cap.Capability {
  cap.inbound(ec.skill, ec.description, { title: "ExternalTask", description: ec.description, fields: [sch.required_str("text", [])] })
}

# Assemble a mountable AgentDef fronting `ec.inbox_url`. Mount it with
# federation.mount_agent(r, db, external_agent.make_agent_def(db, ec), ec.id, cfg)
# exactly like any persona — no core change, no runner, no LLM.
fn make_agent_def(db :: Db, ec :: ExternalConfig) -> srv.AgentDef {
  let capability := adapter_capability(ec)
  let c := card.make(ec.id, ec.description, ec.version, ec.card_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: make_handler(db, ec) }])
}

