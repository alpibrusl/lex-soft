# gate.lex — Verdict + Denial types.
#
# Specs themselves are pure lex predicate functions defined alongside
# each agent (see examples/ev_fleet/specs.lex). The runner asks the
# agent module to run its own gate and return a `Verdict` per proposed
# action; this module just defines the shared vocabulary.

import "./action" as action

type Verdict =
    Allow
  | Deny({ spec :: Str, reason :: Str })

type Denial = {
  spec :: Str,
  reason :: Str,
  action_topic :: Str,
  action_payload :: Str,
}

fn allow() -> Verdict { Allow }

fn deny(spec :: Str, reason :: Str) -> Verdict {
  Deny({ spec: spec, reason: reason })
}

fn is_allow(v :: Verdict) -> Bool {
  match v {
    Allow   => true,
    Deny(_) => false,
  }
}

fn denial_for(spec :: Str, reason :: Str, a :: action.Action) -> Denial {
  match a {
    action.SendA2a({ peer: _, topic, payload_json }) =>
      { spec: spec, reason: reason,
        action_topic: topic, action_payload: payload_json },
    action.NoOp =>
      { spec: spec, reason: reason,
        action_topic: "noop", action_payload: "" },
  }
}
