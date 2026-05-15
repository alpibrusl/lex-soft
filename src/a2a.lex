# a2a.lex — outgoing HTTP A2A sender.
#
# Resolves a peer name to a URL via the static peer map, then POSTs the
# message envelope. v1 ignores response bodies (fire-and-forget); the
# trace records the HTTP status.

import "std.http" as http
import "std.str"  as str
import "std.list" as list
import "std.int"  as int

import "./action" as action

type Peer = { name :: Str, url :: Str }

type SendOutcome = {
  ok :: Bool,
  status :: Int,
  detail :: Str,
}

fn resolve(peers :: List[Peer], name :: Str) -> Option[Str] {
  match list.find(peers, fn (p :: Peer) -> Bool { p.name == name }) {
    None    => None,
    Some(p) => Some(p.url),
  }
}

fn send(
  peers :: List[Peer],
  from :: Str,
  a :: action.Action,
) -> [net, time] SendOutcome {
  match a {
    action.NoOp => { ok: true, status: 0, detail: "noop" },
    action.SendA2a({ peer, topic, payload_json }) =>
      match resolve(peers, peer) {
        None => { ok: false, status: 0,
                  detail: str.concat("unknown peer: ", peer) },
        Some(base_url) => {
          let url := str.concat(base_url, "/agents/")
                       |> fn (u :: Str) -> Str { str.concat(u, peer) }
                       |> fn (u :: Str) -> Str { str.concat(u, "/inbox") }
          let body := str.concat("{\"from\":\"", from)
                       |> fn (s :: Str) -> Str { str.concat(s, "\",\"topic\":\"") }
                       |> fn (s :: Str) -> Str { str.concat(s, topic) }
                       |> fn (s :: Str) -> Str { str.concat(s, "\",\"payload_json\":") }
                       |> fn (s :: Str) -> Str { str.concat(s, json_escape(payload_json)) }
                       |> fn (s :: Str) -> Str { str.concat(s, "}") }
          match http.post(url, body, "application/json") {
            Err(e) => { ok: false, status: 0, detail: http.error_msg(e) },
            Ok(r)  => { ok: http.status(r) < 400, status: http.status(r), detail: "" },
          }
        },
      },
  }
}

# Quote a raw JSON value to embed in another JSON object. If it parses
# as JSON, leave as-is; otherwise wrap as a string. v1 keeps this naive
# — payloads in the EV fleet are already valid JSON literals.
fn json_escape(s :: Str) -> Str {
  if str.is_empty(s) { "\"\"" } else { s }
}
