# mesh.lex — agent-to-agent (A2A) mesh tools, reconstructable from a peers list.
#
# The agent tool loop runs in a subprocess (llm_runner) that can't reach the
# registry DB, so the mesh tools are rebuilt from a `peers` snapshot the parent
# serialized into the request JSON. Each peer is {id,kind,name,inbox_url,role}.
#
# Two tools, mirroring lex-soft/src/runner.lex's in-process platform tools:
#   find_peers(intent)                  — authorised peers for an intent
#   send_message(to_id, topic, payload) — A2A tasks/send to a peer's inbox_url
#
# This is what makes OUTBOUND agent-to-agent work in the live loop, including to
# external / third-party agents registered via POST /peers.

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "std.http" as http

import "std.bytes" as bytes

import "std.list" as list

import "std.str" as str

import "std.map" as map

import "./resolver" as resolver

fn pfield(pj :: jv.Json, key :: Str) -> Str {
  match jv.get_field(pj, key) {
    Some(JStr(sv)) => sv,
    _ => "",
  }
}

# Intent → roles is host-supplied (resolver.IntentRoles); the core no longer
# hardcodes a domain vocabulary. An empty match set means "any peer" (role_matches).
fn role_matches(roles :: List[Str], role :: Str) -> Bool {
  if list.is_empty(roles) {
    true
  } else {
    list.fold(roles, false, fn (acc :: Bool, r :: Str) -> Bool {
      acc or r == role
    })
  }
}

fn peer_field_for(peers :: List[jv.Json], to_id :: Str, field :: Str) -> Str {
  list.fold(peers, "", fn (acc :: Str, pj :: jv.Json) -> Str {
    if str.is_empty(acc) {
      if pfield(pj, "id") == to_id {
        pfield(pj, field)
      } else {
        acc
      }
    } else {
      acc
    }
  })
}

# POST an A2A tasks/send to `url`, attaching `Authorization: Bearer <token>` when
# a connection token is present (so the peer can authenticate the caller).
fn send_body(agent_id :: Str, to_id :: Str, skill :: Str, payload :: Str) -> jv.Json {
  JObj([("jsonrpc", JStr("2.0")), ("id", JStr("1")), ("method", JStr("tasks/send")), ("params", JObj([("id", JStr(str.concat("msg-", to_id))), ("contextId", JStr(str.concat("ctx-", agent_id))), ("skill", JStr(skill)), ("message", JObj([("role", JStr("user")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr(payload))])]))]))]))])
}

# A JSON-RPC "unknown skill" bounce, spotted in the peer's raw reply. Topic
# names come from an LLM, and a near-miss ("Handle", a capability id, a made-up
# verb) should not kill the conversation — the caller retries against the
# peer's DEFAULT skill (empty skill = first advertised), which every A2A serve
# resolves.
fn is_unknown_skill(reply :: jv.Json) -> Bool {
  match jv.get_field(reply, "reply_raw") {
    Some(JStr(raw)) => str.contains(raw, "unknown skill"),
    _ => false,
  }
}

fn post_a2a(url :: Str, token :: Str, body :: Str) -> [net, io, proc] Result[jv.Json, e.Errors] {
  let base := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(60000) }
  let with_ct := http.with_header(base, "Content-Type", "application/json")
  let req := if str.is_empty(token) {
    with_ct
  } else {
    http.with_header(with_ct, "Authorization", str.concat("Bearer ", token))
  }
  match http.send(req) {
    Err(_) => Ok(JObj([("delivered", JBool(false))])),
    Ok(r) => if r.status >= 400 {
      Ok(JObj([("delivered", JBool(false)), ("status", JInt(r.status))]))
    } else {
      match bytes.to_str(r.body) {
        Err(_) => Ok(JObj([("delivered", JBool(true))])),
        Ok(txt) => Ok(JObj([("delivered", JBool(true)), ("reply_raw", JStr(txt))])),
      }
    },
  }
}

# Build the mesh tools from a peers snapshot (List of {id,kind,name,inbox_url,role}
# JSON objects), the calling agent's id, and the host's intent→roles map. The
# find_peers tool describes its intents from that map, so the core names none.
fn make_mesh_tools(agent_id :: Str, peers :: List[jv.Json], map :: List[resolver.IntentRoles]) -> List[t.Tool] {
  let intents := resolver.intents_of(map)
  let find_desc := if list.is_empty(intents) {
    "Find active peer agents you are authorised to contact. Returns peer ids you can pass to send_message."
  } else {
    str.join(["Find active peer agents you are authorised to contact for an intent. Intents: ", str.join(intents, ", "), ", coordination. Returns peer ids you can pass to send_message."], "")
  }
  [t.define("find_peers", find_desc, { title: "FindPeers", description: "Peer resolution by intent.", fields: [s.required_str("intent", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let intent := match jv.get_field(args, "intent") {
      Some(JStr(sv)) => sv,
      _ => "coordination",
    }
    let roles := resolver.roles_for(map, intent)
    let filtered := list.filter(peers, fn (pj :: jv.Json) -> Bool {
      role_matches(roles, pfield(pj, "role"))
    })
    Ok(JList(list.map(filtered, fn (pj :: jv.Json) -> jv.Json {
      JObj([("id", JStr(pfield(pj, "id"))), ("kind", JStr(pfield(pj, "kind"))), ("name", JStr(pfield(pj, "name")))])
    })))
  }), t.define("send_message", "Send a message to a peer agent over A2A. Call find_peers first to get a valid to_id. topic becomes the receiving skill; payload is plain text.", { title: "SendMessage", description: "Send an A2A message to another agent.", fields: [s.required_str("to_id", []), s.required_str("topic", []), s.required_str("payload_json", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
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
      let url := peer_field_for(peers, to_id, "inbox_url")
      if str.is_empty(url) {
        Ok(JObj([("error", JStr(str.concat("unknown or unauthorised peer: ", to_id)))]))
      } else {
        let token := peer_field_for(peers, to_id, "token")
        let first := post_a2a(url, token, jv.stringify(send_body(agent_id, to_id, str.trim(topic), payload)))
        match first {
          Err(err) => Err(err),
          Ok(reply) => if is_unknown_skill(reply) and not str.is_empty(str.trim(topic)) {
            post_a2a(url, token, jv.stringify(send_body(agent_id, to_id, "", payload)))
          } else {
            Ok(reply)
          },
        }
      }
    }
  })]
}

