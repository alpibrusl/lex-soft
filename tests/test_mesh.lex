# tests/test_mesh.lex — acceptance tests for mesh.lex (#130), the tool-loop
# surface that makes OUTBOUND agent-to-agent calls (find_peers/send_message),
# reconstructed from a `peers` JSON snapshot rather than the registry DB. Was
# entirely untested. Asserts:
#   - role_matches: an empty role constraint authorises any peer (the
#     "coordination"/unmapped-intent default); a non-empty constraint accepts
#     only a listed role.
#   - peer_field_for looks up a field on the peer with the given id, and
#     returns "" for an id not in the snapshot (never crashes/None-panics).
#   - find_peers filters the snapshot by the host's intent->roles map — a peer
#     reached under a role the intent doesn't authorise must not be returned.
#   - send_message: an empty to_id and an unknown/unauthorised to_id are both
#     refused with a descriptive error, WITHOUT attempting any network call
#     (never a peer-existence oracle for an id that isn't in the snapshot).
#   - send_message against a known peer whose inbox is unreachable degrades to
#     {"delivered":false} rather than a hard error or a crash — the network
#     failure is contained (post_a2a's own contract).
#   - send_body stamps the sender id into the outbound text so the receiver
#     always knows who is calling (A2A tasks/send carries no from-field).
#   - is_unknown_skill recognises a peer's "unknown skill" bounce.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "lex-llm/src/tool" as t

import "../src/mesh" as mesh

import "../src/resolver" as resolver

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

# ── role_matches / peer_field_for (pure) ─────────────────────────────────────
fn role_matches_empty_constraint_allows_any() -> Result[Unit, Str] {
  assert_true(mesh.role_matches([], "anything"), "an empty role list must authorise any peer")
}

fn role_matches_nonempty_constraint_is_selective() -> Result[Unit, Str] {
  if mesh.role_matches(["charger"], "charger") {
    assert_true(mesh.role_matches(["charger"], "tms") == false, "a role constraint must reject a role it doesn't list")
  } else {
    Err("a role constraint must accept a role it lists")
  }
}

fn peer(id :: Str, role :: Str, inbox :: Str) -> jv.Json {
  JObj([("id", JStr(id)), ("kind", JStr("agent")), ("name", JStr(id)), ("inbox_url", JStr(inbox)), ("role", JStr(role)), ("token", JStr(""))])
}

fn snapshot() -> List[jv.Json] {
  [peer("charger-07", "charger", "http://127.0.0.1:1/inbox"), peer("billing-svc", "tms", "http://127.0.0.1:1/inbox")]
}

fn peer_field_for_known_and_unknown() -> Result[Unit, Str] {
  if mesh.peer_field_for(snapshot(), "charger-07", "role") == "charger" {
    assert_true(str.is_empty(mesh.peer_field_for(snapshot(), "no-such-peer", "role")), "an id absent from the snapshot must yield \"\", not crash")
  } else {
    Err("peer_field_for did not find the known peer's role")
  }
}

# ── find_peers tool ───────────────────────────────────────────────────────────
fn find_peers_tool() -> t.Tool {
  match mesh.make_mesh_tools("truck-1", snapshot(), [{ intent: "charging", roles: ["charger"] }]) {
    tools => match list.head(tools) {
      Some(tool) => tool,
      None => tool_panic(),
    },
  }
}

fn tool_panic() -> t.Tool {
  { name: "", description: "", params: { title: "", description: "", fields: [] }, execute: fn (_a :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(JNull)
  }, precondition: None, approval_scope: None }
}

fn ids_in(j :: jv.Json) -> List[Str] {
  match j {
    JList(items) => list.fold(items, [], fn (acc :: List[Str], it :: jv.Json) -> List[Str] {
      match jv.get_field(it, "id") {
        Some(JStr(s)) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
}

fn find_peers_narrows_by_mapped_intent() -> [net, io, proc] Result[Unit, Str] {
  let tool := find_peers_tool()
  match tool.execute(JObj([("intent", JStr("charging"))])) {
    Err(_) => Err("find_peers should not error on a valid intent"),
    Ok(j) => assert_true(ids_in(j) == ["charger-07"], str.concat("expected only charger-07, got ", str.join(ids_in(j), ","))),
  }
}

fn find_peers_unmapped_intent_returns_all() -> [net, io, proc] Result[Unit, Str] {
  let tool := find_peers_tool()
  match tool.execute(JObj([("intent", JStr("some-unmapped-intent"))])) {
    Err(_) => Err("find_peers should not error on an unmapped intent"),
    Ok(j) => assert_true(list.len(ids_in(j)) == 2, str.concat("an unmapped intent has no role constraint and should return every peer, got ", str.join(ids_in(j), ","))),
  }
}

# ── send_message tool ─────────────────────────────────────────────────────────
fn send_message_tool() -> t.Tool {
  match mesh.make_mesh_tools("truck-1", snapshot(), []) {
    tools => match list.head(list.reverse(tools)) {
      Some(tool) => tool,
      None => tool_panic(),
    },
  }
}

fn json_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn json_bool(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn send_message_requires_to_id() -> [net, io, proc] Result[Unit, Str] {
  let tool := send_message_tool()
  match tool.execute(JObj([("to_id", JStr("")), ("topic", JStr("t")), ("payload_json", JStr("{}"))])) {
    Err(_) => Err("send_message should return a soft error, not Err, for a missing to_id"),
    Ok(j) => assert_true(str.contains(json_str(j, "error"), "to_id is required"), str.concat("expected a to_id-required error, got ", jv.stringify(j))),
  }
}

fn send_message_refuses_unknown_peer() -> [net, io, proc] Result[Unit, Str] {
  let tool := send_message_tool()
  match tool.execute(JObj([("to_id", JStr("ghost-agent")), ("topic", JStr("t")), ("payload_json", JStr("{}"))])) {
    Err(_) => Err("send_message should return a soft error, not Err, for an unknown peer"),
    Ok(j) => assert_true(str.contains(json_str(j, "error"), "unknown or unauthorised peer"), str.concat("expected an unauthorised-peer error, got ", jv.stringify(j))),
  }
}

# The peer IS in the snapshot but its inbox is an unreachable local port —
# post_a2a must degrade to {"delivered":false}, never surface as a hard tool
# Err or crash the tool loop over an ordinary network failure.
fn send_message_unreachable_inbox_degrades_gracefully() -> [net, io, proc] Result[Unit, Str] {
  let tool := send_message_tool()
  match tool.execute(JObj([("to_id", JStr("charger-07")), ("topic", JStr("restart")), ("payload_json", JStr("{}"))])) {
    Err(_) => Err("an unreachable peer must not surface as a hard tool error"),
    Ok(j) => assert_true(json_bool(j, "delivered") == false, str.concat("expected delivered:false for an unreachable inbox, got ", jv.stringify(j))),
  }
}

# ── send_body / is_unknown_skill (pure) ──────────────────────────────────────
fn send_body_stamps_sender() -> Result[Unit, Str] {
  let body := mesh.send_body("truck-1", "charger-07", "restart", "{\"x\":1}")
  let text := jv.stringify(body)
  assert_true(str.contains(text, "[from agent truck-1]"), "send_body must stamp the sender id so the receiver knows who is calling")
}

fn is_unknown_skill_detects_bounce() -> Result[Unit, Str] {
  let bounce := JObj([("delivered", JBool(true)), ("reply_raw", JStr("{\"error\":\"unknown skill: foo\"}"))])
  let normal := JObj([("delivered", JBool(true)), ("reply_raw", JStr("{\"ok\":true}"))])
  if mesh.is_unknown_skill(bounce) {
    assert_true(mesh.is_unknown_skill(normal) == false, "a normal reply must not be misread as an unknown-skill bounce")
  } else {
    Err("an \"unknown skill\" bounce in reply_raw must be detected")
  }
}

fn run_all() -> [net, io, proc] Unit {
  let results := [role_matches_empty_constraint_allows_any(), role_matches_nonempty_constraint_is_selective(), peer_field_for_known_and_unknown(), find_peers_narrows_by_mapped_intent(), find_peers_unmapped_intent_returns_all(), send_message_requires_to_id(), send_message_refuses_unknown_peer(), send_message_unreachable_inbox_degrades_gracefully(), send_body_stamps_sender(), is_unknown_skill_detects_bounce()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

