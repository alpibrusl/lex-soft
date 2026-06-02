# platform/client.lex — HTTP client for agents talking to the lex-soft platform.
#
# Replaces direct Db calls in runner.lex for distributed deployments.
# Every agent (truck, depot, TMS) calls these on boot and per-turn
# instead of reading/writing a local SQLite directly.
#
# Connectivity model:
#   Cloud agents (TMS, depot) — always connected; every call is live.
#   Edge agents (trucks)      — may be offline; use outbox.enqueue for
#                               sends (not send_direct here), and call
#                               pull_inbox on reconnect to drain messages.
#
# All functions accept a platform_token for bearer auth so the platform
# can reject registrations from unknown devices.

import "std.http" as http

import "std.bytes" as bytes

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

type PlatformClient = { url :: Str, token :: Str }

fn make(url :: Str, token :: Str) -> PlatformClient {
  { url: url, token: token }
}

# ---- Registration -----------------------------------------------
# Register this agent with the platform on boot.
# inbox_url: reachable A2A endpoint for push delivery (cloud agents).
#            Pass "" for pull mode (edge devices that cannot accept inbound).
fn register(client :: PlatformClient, agent_id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [net] Result[Unit, Str] {
  let body := jv.stringify(JObj([("id", JStr(agent_id)), ("kind", JStr(kind)), ("name", JStr(name)), ("inbox_url", JStr(inbox_url)), ("capabilities", JList(list.map(capabilities, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))]))
  let url := str.concat(client.url, "/v1/agents")
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(e) => Err(str.concat("register failed: ", match e {
      TimeoutError => "timeout",
      TlsError(m) => m,
      NetworkError(m) => m,
      DecodeError(m) => m,
    })),
    Ok(_) => Ok(()),
  }
}

# ---- Peer discovery ---------------------------------------------
type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str }

# Fetch peers for this agent filtered by intent from the platform.
# Intent values: "charging", "dispatch", "reporting", "coordination".
fn peers(client :: PlatformClient, agent_id :: Str, intent :: Str) -> [net] List[PeerInfo] {
  let url := str.concat(client.url, str.concat("/v1/agents/", str.concat(agent_id, str.concat("/peers?intent=", intent))))
  match http.get(url) {
    Err(_) => [],
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => [],
      Ok(body) => match jv.parse(body) {
        Err(_) => [],
        Ok(JList(items)) => list.fold(items, [], fn (acc :: List[PeerInfo], j :: jv.Json) -> List[PeerInfo] {
          match parse_peer(j) {
            None => acc,
            Some(p) => list.concat(acc, [p]),
          }
        }),
        Ok(_) => [],
      },
    },
  }
}

fn parse_peer(j :: jv.Json) -> Option[PeerInfo] {
  let id := match jv.get_field(j, "id") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let kind := match jv.get_field(j, "kind") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let name := match jv.get_field(j, "name") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let inbox_url := match jv.get_field(j, "inbox_url") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let role := match jv.get_field(j, "role") {
    Some(JStr(s)) => s,
    _ => "",
  }
  if str.is_empty(id) {
    None
  } else {
    Some({ id: id, kind: kind, name: name, inbox_url: inbox_url, role: role })
  }
}

# ---- State persistence ------------------------------------------
fn load_state(client :: PlatformClient, agent_id :: Str) -> [net] Str {
  let url := str.concat(client.url, str.concat("/v1/state/", agent_id))
  match http.get(url) {
    Err(_) => "{}",
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => "{}",
      Ok(body) => match jv.parse(body) {
        Ok(JObj(fields)) => match jv.get_field(JObj(fields), "state") {
          Some(JStr(s)) => s,
          _ => "{}",
        },
        _ => "{}",
      },
    },
  }
}

fn save_state(client :: PlatformClient, agent_id :: Str, state_json :: Str) -> [net] Result[Unit, Str] {
  let body := jv.stringify(JObj([("state", JStr(state_json))]))
  let url := str.concat(client.url, str.concat("/v1/state/", agent_id))
  match http.post(url, bytes.from_str(body), "application/json") {
    Err(e) => Err(str.concat("save_state failed: ", match e {
      TimeoutError => "timeout",
      TlsError(m) => m,
      NetworkError(m) => m,
      DecodeError(m) => m,
    })),
    Ok(_) => Ok(()),
  }
}

# ---- Edge agent inbox poll --------------------------------------
# Pull the next message from this agent's inbox on the platform.
# Edge agents (trucks) call this on reconnect to drain any messages
# that accumulated while they were offline. Returns None when inbox
# is empty. Call repeatedly until None to fully drain.
fn pull_inbox(client :: PlatformClient, agent_id :: Str) -> [net] Option[Str] {
  let url := str.concat(client.url, str.concat("/v1/messages/", str.concat(agent_id, "/pull")))
  match http.get(url) {
    Err(_) => None,
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => None,
      Ok(body) => match jv.parse(body) {
        Ok(JObj(fields)) => match jv.get_field(JObj(fields), "payload") {
          Some(JStr(s)) => Some(s),
          _ => None,
        },
        _ => None,
      },
    },
  }
}

fn jv_parse(body :: Str) -> jv.Json {
  match jv.parse(body) {
    Ok(j) => j,
    Err(_) => JObj([]),
  }
}

# ---- Heartbeat --------------------------------------------------
fn heartbeat(client :: PlatformClient, agent_id :: Str) -> [net] Unit {
  let url := str.concat(client.url, str.concat("/v1/agents/", str.concat(agent_id, "/heartbeat")))
  match http.post(url, bytes.from_str("{}"), "application/json") {
    Err(_) => (),
    Ok(_) => (),
  }
}

