# test_runner.lex — vehicle dispatch path, end-to-end pure.
#
# The runner.step() function touches SQL + HTTP, so it's not pure. But
# the agent's `dispatch_and_gate` IS pure — and that's what determines
# whether the right actions get proposed + gated. Test that layer.

import "std.list" as list

import "lex-soft/message" as message
import "lex-soft/gate"    as gate
import "lex-soft/action"  as action

import "../examples/ev_fleet/agents/vehicle" as vehicle
import "../examples/ev_fleet/agents/depot"   as depot

# Vehicle with enough SOC -> Acknowledge to sender.
fn test_vehicle_dispatch_acknowledges() -> Result[Unit, Str] {
  let m := message.new("ops", "Dispatch", "{}")
  let out := vehicle.dispatch_and_gate(vehicle.initial_state_json(), m)
  if list.length(out.gated) != 1 {
    Err("expected exactly one action")
  } else {
    match list.first(out.gated) {
      None     => Err("empty"),
      Some(ga) =>
        match ga.action {
          action.SendA2a({ peer, topic, payload_json: _ }) =>
            if peer == "ops" && topic == "Acknowledge" { Ok(unit) }
            else { Err("wrong peer/topic") },
          _ => Err("wrong action kind"),
        }
    }
  }
}

# Depot within budget -> GrantSession allowed.
fn test_depot_grants_within_budget() -> Result[Unit, Str] {
  let m := message.new("vehicle", "RequestSession",
                       "{\"vehicle_id\":\"v-1\",\"power_kw\":50}")
  let out := depot.dispatch_and_gate(
    "current_kw=100.0;budget_kw=200.0;pv_kw=10.0;requested_kw=50.0", m)
  match list.first(out.gated) {
    None     => Err("no actions"),
    Some(ga) => if gate.is_allow(ga.verdict) { Ok(unit) }
                else { Err("should Allow within budget") },
  }
}

# Depot over budget -> verdict Deny on the GrantSession.
fn test_depot_denies_over_budget() -> Result[Unit, Str] {
  let m := message.new("vehicle", "RequestSession",
                       "{\"vehicle_id\":\"v-1\",\"power_kw\":50}")
  let out := depot.dispatch_and_gate(
    "current_kw=180.0;budget_kw=200.0;pv_kw=5.0;requested_kw=50.0", m)
  match list.first(out.gated) {
    None     => Err("no actions"),
    Some(ga) => {
      # the handler returned a GrantSession (budget-check inside handler
      # is the same — both should agree). But the spec gate is what
      # matters here:
      if gate.is_allow(ga.verdict) {
        Err("gate should Deny when over budget")
      } else { Ok(unit) }
    },
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [ test_vehicle_dispatch_acknowledges(),
    test_depot_grants_within_budget(),
    test_depot_denies_over_budget() ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
}
