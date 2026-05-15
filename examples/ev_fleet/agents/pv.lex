# pv.lex — solar-availability broadcaster.
#
# State:  { pv_kw }
# In:     Tick (synthetic — POST /agents/pv/tick fires it)
# Out:    PvUpdate to depot

import "std.str"   as str
import "std.float" as float
import "std.list"  as list

import "lex-soft/action"  as action
import "lex-soft/message" as message
import "lex-soft/gate"    as gate
import "lex-soft/runner"  as runner

type State = { pv_kw :: Float }

fn name() -> Str { "pv" }

fn initial_state_json() -> Str { "pv_kw=10.0" }

fn decode(s :: Str) -> State { { pv_kw: kv_float(s, "pv_kw", 0.0) } }
fn encode(s :: State) -> Str { str.concat("pv_kw=", float.to_str(s.pv_kw)) }

fn on_tick(_s :: State, _m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  { state: _s,
    actions: [ action.send_a2a("depot", "PvUpdate", "{}") ] }
}

fn route(s :: State, m :: message.Message) -> { state :: State, actions :: List[action.Action] } {
  if m.topic == "Tick" { on_tick(s, m) }
  else { { state: s, actions: [] } }
}

fn dispatch_and_gate(state_json :: Str, m :: message.Message) -> runner.DispatchOutput {
  let s := decode(state_json)
  let r := route(s, m)
  let gated := list.map(r.actions, fn (a :: action.Action) -> runner.GatedAction {
    { action: a, verdict: gate.allow() }
  })
  { new_state_json: encode(r.state), gated: gated }
}

fn kv_float(s :: Str, key :: Str, default :: Float) -> Float {
  let parts := str.split(s, ";")
  list.fold(parts, default, fn (acc :: Float, p :: Str) -> Float {
    let kv := str.split(p, "=")
    if list.length(kv) == 2 && list.at(kv, 0) == Some(key) {
      match list.at(kv, 1) {
        None    => acc,
        Some(v) => match float.from_str(v) { Some(f) => f, None => acc },
      }
    } else { acc }
  })
}
