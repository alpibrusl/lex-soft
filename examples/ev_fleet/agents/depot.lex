# depot.lex — charging depot.
#
# State:    { current_kw, budget_kw, pv_kw, requested_kw }
# In:       RequestSession, PvUpdate
# Out:      GrantSession | DenySession (to requester)
#
# Mirrors soft/agents/depot.lex. The pure-lex port additionally runs
# `depot_grid_budget` on the proposed Grant before letting it through.

import "std.str"   as str
import "std.float" as float
import "std.list"  as list

import "lex-soft/action"  as action
import "lex-soft/message" as message
import "lex-soft/gate"    as gate
import "lex-soft/runner"  as runner

import "../specs" as specs

type State = { current_kw :: Float, budget_kw :: Float,
               pv_kw :: Float, requested_kw :: Float }

fn name() -> Str { "depot" }

fn initial_state_json() -> Str {
  "current_kw=100.0;budget_kw=200.0;pv_kw=10.0;requested_kw=50.0"
}

fn decode(s :: Str) -> State {
  { current_kw:   kv_float(s, "current_kw",   0.0),
    budget_kw:    kv_float(s, "budget_kw",    0.0),
    pv_kw:        kv_float(s, "pv_kw",        0.0),
    requested_kw: kv_float(s, "requested_kw", 0.0) }
}

fn encode(s :: State) -> Str {
  str.concat("current_kw=",   float.to_str(s.current_kw))
  |> fn (x :: Str) -> Str { str.concat(x, ";budget_kw=") }
  |> fn (x :: Str) -> Str { str.concat(x, float.to_str(s.budget_kw)) }
  |> fn (x :: Str) -> Str { str.concat(x, ";pv_kw=") }
  |> fn (x :: Str) -> Str { str.concat(x, float.to_str(s.pv_kw)) }
  |> fn (x :: Str) -> Str { str.concat(x, ";requested_kw=") }
  |> fn (x :: Str) -> Str { str.concat(x, float.to_str(s.requested_kw)) }
}

fn within(cur :: Float, delta :: Float, grid :: Float, pv :: Float) -> Bool {
  cur + delta <= grid + pv
}

fn on_request_session(s :: State, m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if within(s.current_kw, s.requested_kw, s.budget_kw, s.pv_kw) {
    { state: s,
      actions: [ action.send_a2a(m.from, "GrantSession",
                                 "{\"charger_id\":\"c-1\",\"power_kw\":50}") ] }
  } else {
    { state: s,
      actions: [ action.send_a2a(m.from, "DenySession",
                                 "{\"reason\":\"grid_budget\"}") ] }
  }
}

fn on_pv_update(s :: State, _m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  { state: { current_kw: s.current_kw, budget_kw: s.budget_kw,
             pv_kw: s.pv_kw + 5.0, requested_kw: s.requested_kw },
    actions: [] }
}

fn route(s :: State, m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if m.topic == "RequestSession" { on_request_session(s, m) }
  else if m.topic == "PvUpdate"  { on_pv_update(s, m) }
  else { { state: s, actions: [] } }
}

# Gate: only GrantSession needs the budget check. DenySession and
# PvUpdate-derived no-ops trivially Allow.
fn gate_one(s :: State, a :: action.Action) -> gate.Verdict {
  match a {
    action.SendA2a({ peer: _, topic, payload_json: _ }) =>
      if topic == "GrantSession" {
        if specs.depot_grid_budget(
             { current_kw: s.current_kw, budget_kw: s.budget_kw,
               pv_kw: s.pv_kw },
             { power_kw: s.requested_kw }) {
          gate.allow()
        } else {
          gate.deny("depot_grid_budget",
                    "current_kw + power_kw > budget_kw + pv_kw")
        }
      } else {
        gate.allow()
      },
    action.NoOp => gate.allow(),
  }
}

fn dispatch_and_gate(state_json :: Str, m :: message.Message) -> runner.DispatchOutput {
  let s := decode(state_json)
  let r := route(s, m)
  let gated := list.map(r.actions, fn (a :: action.Action) -> runner.GatedAction {
    { action: a, verdict: gate_one(r.state, a) }
  })
  { new_state_json: encode(r.state), gated: gated }
}

# -- codec helpers (duplicated from vehicle.lex for now — slated for
# extraction into lex-soft once we have a `lex.kv` stdlib slice) ---

fn kv_float(s :: Str, key :: Str, default :: Float) -> Float {
  match kv_get(s, key) {
    None    => default,
    Some(v) => match float.from_str(v) { Some(f) => f, None => default },
  }
}

fn kv_get(s :: Str, key :: Str) -> Option[Str] {
  let parts := str.split(s, ";")
  list.fold(parts, None, fn (acc :: Option[Str], p :: Str) -> Option[Str] {
    match acc {
      Some(_) => acc,
      None    => {
        let kv := str.split(p, "=")
        if list.length(kv) == 2 && list.at(kv, 0) == Some(key) {
          list.at(kv, 1)
        } else { None }
      },
    }
  })
}
