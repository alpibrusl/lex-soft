# action.lex — Action ADT.
#
# What a handler can propose for the runner to execute. v1 ships SendA2a
# only; CallMcp / LocalLlm / CloudLlm are deferred (the original `soft`
# runtime hosted those; pure-lex needs an MCP-over-HTTP client first).

type Action =
    SendA2a({ peer :: Str, topic :: Str, payload_json :: Str })
  | NoOp

fn send_a2a(peer :: Str, topic :: Str, payload_json :: Str) -> Action {
  SendA2a({ peer: peer, topic: topic, payload_json: payload_json })
}

fn noop() -> Action { NoOp }

# Topic for tracing — "a2a.<peer>.<topic>" for SendA2a, "noop" otherwise.
fn describe(a :: Action) -> Str {
  match a {
    SendA2a({ peer, topic, payload_json: _ }) =>
      str.concat("a2a.", str.concat(peer, str.concat(".", topic))),
    NoOp => "noop",
  }
}

fn payload(a :: Action) -> Str {
  match a {
    SendA2a({ peer: _, topic: _, payload_json }) => payload_json,
    NoOp => "",
  }
}
