# tests/test_intent_roles.lex — host-supplied intent→roles resolution (#34).
#
# The core no longer hardcodes a domain vocabulary; it resolves intents against
# a caller-supplied List[IntentRoles]. These lock that behaviour: a mapped
# intent yields its roles, an unmapped one yields [] (which role_matches treats
# as "any peer"), and intents_of enumerates the map for the tool description.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "../src/resolver" as resolver

fn fleet() -> List[resolver.IntentRoles] {
  [{ intent: "charging", roles: ["preferred_charger", "charger", "charging"] }, { intent: "dispatch", roles: ["contracted", "freelance", "dispatch"] }, { intent: "reporting", roles: ["reporting"] }]
}

fn same(got :: List[Str], want :: List[Str]) -> Bool {
  if list.len(got) == list.len(want) {
    list.fold(want, true, fn (acc :: Bool, w :: Str) -> Bool {
      acc and list.fold(got, false, fn (a :: Bool, g :: Str) -> Bool {
        a or g == w
      })
    })
  } else {
    false
  }
}

fn mapped_intent_yields_its_roles() -> Result[Unit, Str] {
  let r := resolver.roles_for(fleet(), "charging")
  if same(r, ["preferred_charger", "charger", "charging"]) {
    Ok(())
  } else {
    Err(str.concat("charging roles wrong: ", str.join(r, ",")))
  }
}

fn unmapped_intent_yields_empty() -> Result[Unit, Str] {
  let r := resolver.roles_for(fleet(), "teleport")
  if list.is_empty(r) {
    Ok(())
  } else {
    Err(str.concat("expected empty for unknown intent, got: ", str.join(r, ",")))
  }
}

fn empty_map_yields_empty() -> Result[Unit, Str] {
  let r := resolver.roles_for([], "charging")
  if list.is_empty(r) {
    Ok(())
  } else {
    Err("empty map should resolve to no roles")
  }
}

fn intents_of_enumerates_the_map() -> Result[Unit, Str] {
  let got := resolver.intents_of(fleet())
  if same(got, ["charging", "dispatch", "reporting"]) {
    Ok(())
  } else {
    Err(str.concat("intents_of wrong: ", str.join(got, ",")))
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [mapped_intent_yields_its_roles(), unmapped_intent_yields_empty(), empty_map_yields_empty(), intents_of_enumerates_the_map()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __show := list.fold(failures, (), fn (_a :: Unit, m :: Str) -> [io] Unit {
      io.print(str.concat("FAIL: ", str.concat(m, "\n")))
    })
    let __boom := 1 / 0
    ()
  }
}

