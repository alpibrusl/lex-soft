# vehicle.lex — autonomous truck.
#
# State:     { soc, reserve, energy_needed, tried }
# Topics in: Dispatch, GrantSession, DenySession
# Topics out: Acknowledge | RequestSession (depot) | Complete | Failed (tms)
#
# Handlers are copied near-verbatim from soft/agents/vehicle.lex. The
# additions are (1) a state codec that round-trips through a flat
# `k=v;...` string (since std JSON parsing isn't used here), and
# (2) `dispatch_and_gate` — the entry point the lex-soft runner calls.

import "std.str"   as str
import "std.float" as float
import "std.list"  as list

import "lex-soft/action"  as action
import "lex-soft/message" as message
import "lex-soft/gate"    as gate
import "lex-soft/runner"  as runner

import "../specs" as specs

type State = { soc :: Float, reserve :: Float,
               energy_needed :: Float, tried :: Int }

fn name() -> Str { "vehicle" }

fn initial_state_json() -> Str {
  # soc=0.8 means the dispatch path returns Acknowledge instead of
  # routing through the depot. Lower this to exercise the request flow.
  "soc=0.8;reserve=0.2;energy_needed=0.5;tried=0"
}

fn decode(s :: Str) -> State {
  { soc:           kv_float(s, "soc",           0.0),
    reserve:       kv_float(s, "reserve",       0.0),
    energy_needed: kv_float(s, "energy_needed", 0.0),
    tried:         kv_int(s,   "tried",         0) }
}

fn encode(s :: State) -> Str {
  str.concat("soc=",           float.to_str(s.soc))
  |> fn (x :: Str) -> Str { str.concat(x, ";reserve=") }
  |> fn (x :: Str) -> Str { str.concat(x, float.to_str(s.reserve)) }
  |> fn (x :: Str) -> Str { str.concat(x, ";energy_needed=") }
  |> fn (x :: Str) -> Str { str.concat(x, float.to_str(s.energy_needed)) }
  |> fn (x :: Str) -> Str { str.concat(x, ";tried=") }
  |> fn (x :: Str) -> Str { str.concat(x, int.to_str(s.tried)) }
}

fn enough_soc(s :: State) -> Bool {
  s.soc - s.energy_needed >= s.reserve
}

fn on_dispatch(s :: State, m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if enough_soc(s) {
    { state: { soc: s.soc, reserve: s.reserve,
               energy_needed: s.energy_needed, tried: 0 },
      actions: [ action.send_a2a(m.from, "Acknowledge",
                                 "{\"delivery_id\":\"d-1\"}") ] }
  } else {
    { state: { soc: s.soc, reserve: s.reserve,
               energy_needed: s.energy_needed, tried: 1 },
      actions: [ action.send_a2a("depot", "RequestSession",
                                 "{\"vehicle_id\":\"v-1\",\"power_kw\":50}") ] }
  }
}

fn on_grant(s :: State, _m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  { state: s,
    actions: [ action.send_a2a("tms", "Complete",
                               "{\"delivery_id\":\"d-1\"}") ] }
}

fn on_deny(s :: State, _m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if s.tried >= 2 {
    { state: s,
      actions: [ action.send_a2a("tms", "Failed",
                                 "{\"reason\":\"all_depots_denied\"}") ] }
  } else {
    { state: { soc: s.soc, reserve: s.reserve,
               energy_needed: s.energy_needed, tried: s.tried + 1 },
      actions: [ action.send_a2a("depot2", "RequestSession",
                                 "{\"vehicle_id\":\"v-1\",\"power_kw\":50}") ] }
  }
}

fn route(s :: State, m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if m.topic == "Dispatch"     { on_dispatch(s, m) }
  else if m.topic == "GrantSession" { on_grant(s, m) }
  else if m.topic == "DenySession"  { on_deny(s, m) }
  else { { state: s, actions: [] } }
}

# Gate every outgoing action through the SOC-reserve spec. For
# Acknowledge/Complete/Failed the spec is vacuously true; for
# RequestSession we re-check before dispatching.
fn gate_one(s :: State, a :: action.Action) -> gate.Verdict {
  if specs.vehicle_soc_reserve({ soc: s.soc, reserve: s.reserve,
                                 energy_needed: s.energy_needed }) {
    gate.allow()
  } else {
    gate.deny("vehicle_soc_reserve",
              "soc - energy_needed < reserve")
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

# -- flat-string state codec helpers --------------------------------

fn kv_float(s :: Str, key :: Str, default :: Float) -> Float {
  match kv_get(s, key) {
    None    => default,
    Some(v) => match float.from_str(v) { Some(f) => f, None => default },
  }
}

fn kv_int(s :: Str, key :: Str, default :: Int) -> Int {
  match kv_get(s, key) {
    None    => default,
    Some(v) => match int.from_str(v) { Some(i) => i, None => default },
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
