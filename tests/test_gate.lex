# test_gate.lex — verdict construction + EV-fleet spec truth tables.

import "std.list" as list

import "lex-soft/gate"   as gate
import "lex-soft/action" as action

import "../examples/ev_fleet/specs" as specs

fn test_allow_is_allow() -> Result[Unit, Str] {
  if gate.is_allow(gate.allow()) { Ok(unit) }
  else { Err("Allow should be Allow") }
}

fn test_deny_is_not_allow() -> Result[Unit, Str] {
  if gate.is_allow(gate.deny("spec", "reason")) {
    Err("Deny should not be Allow")
  } else { Ok(unit) }
}

fn test_depot_budget_within() -> Result[Unit, Str] {
  let s := { current_kw: 100.0, budget_kw: 200.0, pv_kw: 10.0 }
  let a := { power_kw: 50.0 }
  if specs.depot_grid_budget(s, a) { Ok(unit) }
  else { Err("100 + 50 <= 200 + 10 should hold") }
}

fn test_depot_budget_over() -> Result[Unit, Str] {
  let s := { current_kw: 180.0, budget_kw: 200.0, pv_kw: 5.0 }
  let a := { power_kw: 50.0 }
  if specs.depot_grid_budget(s, a) {
    Err("180 + 50 > 200 + 5 should violate")
  } else { Ok(unit) }
}

fn test_vehicle_reserve_ok() -> Result[Unit, Str] {
  let s := { soc: 0.8, reserve: 0.2, energy_needed: 0.5 }
  if specs.vehicle_soc_reserve(s) { Ok(unit) }
  else { Err("0.8 - 0.5 >= 0.2 should hold") }
}

fn test_vehicle_reserve_violation() -> Result[Unit, Str] {
  let s := { soc: 0.4, reserve: 0.2, energy_needed: 0.5 }
  if specs.vehicle_soc_reserve(s) {
    Err("0.4 - 0.5 < 0.2 should violate")
  } else { Ok(unit) }
}

fn suite() -> List[Result[Unit, Str]] {
  [ test_allow_is_allow(),
    test_deny_is_not_allow(),
    test_depot_budget_within(),
    test_depot_budget_over(),
    test_vehicle_reserve_ok(),
    test_vehicle_reserve_violation() ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => n, Err(_) => n + 1 }
  })
}
