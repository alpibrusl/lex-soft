# specs.lex — gate predicates.
#
# Ports of `soft/agents/{depot,vehicle}.spec` as pure lex functions.
# The original `.spec` DSL was a `forall` over record-typed bindings;
# each one collapses to a regular function with the same shape.

# depot.spec — grid-budget invariant.
fn depot_grid_budget(
  s :: { current_kw :: Float, budget_kw :: Float, pv_kw :: Float },
  a :: { power_kw :: Float },
) -> Bool {
  s.current_kw + a.power_kw <= s.budget_kw + s.pv_kw
}

# vehicle.spec — SOC reserve invariant.
fn vehicle_soc_reserve(
  s :: { soc :: Float, reserve :: Float, energy_needed :: Float },
) -> Bool {
  s.soc - s.energy_needed >= s.reserve
}
