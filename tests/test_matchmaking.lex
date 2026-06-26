# tests/test_matchmaking.lex — acceptance tests for #16 (typed capability
# matchmaking). Asserts the three acceptance criteria under `lex test`:
#   1. a structured query returns ONLY orgs whose advertised capability +
#      constraints satisfy it,
#   2. namespaced ids don't collide across domains,
#   3. the backward-compatible exact `?capability=` (no constraints) matches by
#      exact id (incl. legacy plain-string offers).

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/matchmaking" as mm

# ---- fixtures ----
fn entry(org :: Str, caps_json :: Str) -> mm.OrgCaps {
  let caps := match jv.parse(caps_json) {
    Ok(j) => j,
    Err(_) => JList([]),
  }
  { org: org, caps: caps }
}

# alpha/beta advertise the same typed reefer capability with different attrs;
# gamma is a DIFFERENT domain (energy); delta uses the legacy plain-string form.
fn directory() -> List[mm.OrgCaps] {
  [entry("alpha", "[{\"id\":\"logistics.freight.reefer\",\"attrs\":{\"region\":\"EU-south\",\"max_hours\":48,\"price_eur\":1200}}]"), entry("beta", "[{\"id\":\"logistics.freight.reefer\",\"attrs\":{\"region\":\"EU-north\",\"max_hours\":72,\"price_eur\":900}}]"), entry("gamma", "[{\"id\":\"energy.balancing.frequency\",\"attrs\":{\"region\":\"EU-south\"}}]"), entry("delta", "[\"logistics.freight.reefer\"]")]
}

fn con(attr :: Str, op :: Str, v :: jv.Json) -> mm.Constraint {
  { attr: attr, op: op, value: v }
}

# ---- assertion helper: match-org set equals expected set ----
fn orgs_of(ms :: List[mm.Match]) -> List[Str] {
  list.map(ms, fn (m :: mm.Match) -> Str {
    m.org
  })
}

fn has(xs :: List[Str], s :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    acc or x == s
  })
}

fn same_set(got :: List[Str], want :: List[Str]) -> Bool {
  if list.len(got) == list.len(want) {
    list.fold(want, true, fn (acc :: Bool, w :: Str) -> Bool {
      acc and has(got, w)
    })
  } else {
    false
  }
}

fn expect_orgs(label :: Str, ms :: List[mm.Match], want :: List[Str]) -> Result[Unit, Str] {
  let got := orgs_of(ms)
  if same_set(got, want) {
    Ok(())
  } else {
    Err(str.concat(label, str.concat(": got [", str.concat(str.join(got, ","), str.concat("], want [", str.concat(str.join(want, ","), "]"))))))
  }
}

# ---- tests ----
# 1. Structured query: reefer in EU-south within 48h → only alpha. beta is
#    EU-north, delta has no attrs (constraints fail), gamma is another domain.
fn structured_query_filters() -> Result[Unit, Str] {
  let q := { capability: "logistics.freight.reefer", constraints: [con("region", "eq", JStr("EU-south")), con("max_hours", "lte", JInt(48))] }
  expect_orgs("structured_query_filters", mm.find(directory(), q), ["alpha"])
}

# Numeric constraint: price ≤ 1000 → only beta (900); alpha is 1200, delta has none.
fn numeric_constraint_filters() -> Result[Unit, Str] {
  let q := { capability: "logistics.freight.reefer", constraints: [con("price_eur", "lte", JInt(1000))] }
  expect_orgs("numeric_constraint_filters", mm.find(directory(), q), ["beta"])
}

# 2. Namespacing: querying the energy id matches only gamma — no collision with
#    the logistics orgs.
fn namespaces_do_not_collide() -> Result[Unit, Str] {
  let q := { capability: "energy.balancing.frequency", constraints: [] }
  expect_orgs("namespaces_do_not_collide", mm.find(directory(), q), ["gamma"])
}

# 3. Backward-compatible exact id (no constraints) matches every advertiser of
#    that id, including the legacy plain-string offer (delta).
fn exact_id_backward_compatible() -> Result[Unit, Str] {
  let q := mm.exact_query("logistics.freight.reefer")
  expect_orgs("exact_id_backward_compatible", mm.find(directory(), q), ["alpha", "beta", "delta"])
}

# A non-existent capability matches nothing.
fn unknown_capability_empty() -> Result[Unit, Str] {
  let q := mm.exact_query("logistics.freight.dry")
  expect_orgs("unknown_capability_empty", mm.find(directory(), q), [])
}

fn run_all() -> Unit {
  let results := [structured_query_filters(), numeric_constraint_filters(), namespaces_do_not_collide(), exact_id_backward_compatible(), unknown_capability_empty()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

