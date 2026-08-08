# tests/test_resolver.lex — acceptance tests for resolver.lex (#130).
#
# resolver.lex is the intent -> authorised-peers boundary every domain pack's
# find_peers tool goes through (directly here, or via mesh.make_mesh_tools'
# snapshot-based wrapper). Untested until now despite being exactly the kind
# of logic that decides which peers an agent is allowed to discover. Asserts:
#   - roles_for concatenates roles across every map entry matching an intent,
#     and returns [] for an intent the host never mapped.
#   - intents_of surfaces the host-declared intent vocabulary (used to
#     describe find_peers to the LLM) — order-preserving, one per entry.
#   - resolve() with an empty/unmatched-intent map falls back to ALL of the
#     caller's active peers (the "coordination" fallback) — never zero peers
#     just because the host didn't map that intent.
#   - resolve() with a matched intent narrows to only the peers reached via a
#     relationship whose role is in that intent's role list — a peer reached
#     via a DIFFERENT role must not leak in.
#   - resolve_one() returns the first match, and None when nothing matches.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/relationships" as rel

import "../src/resolver" as resolver

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn ids_of(refs :: List[reg.AgentRef]) -> List[Str] {
  list.map(refs, fn (a :: reg.AgentRef) -> Str {
    a.id
  })
}

fn same_set(got :: List[Str], want :: List[Str]) -> Bool {
  if list.len(got) == list.len(want) {
    list.fold(want, true, fn (acc :: Bool, w :: Str) -> Bool {
      acc and list.fold(got, false, fn (seen :: Bool, g :: Str) -> Bool {
        seen or g == w
      })
    })
  } else {
    false
  }
}

# ── roles_for / intents_of (pure) ────────────────────────────────────────────
fn charging_map() -> List[resolver.IntentRoles] {
  [{ intent: "charging", roles: ["charger"] }, { intent: "charging", roles: ["depot"] }, { intent: "billing", roles: ["tms"] }]
}

fn roles_for_concatenates_across_entries() -> Result[Unit, Str] {
  let roles := resolver.roles_for(charging_map(), "charging")
  assert_true(same_set(roles, ["charger", "depot"]), str.concat("expected [charger, depot], got ", str.join(roles, ",")))
}

fn roles_for_unmapped_intent_is_empty() -> Result[Unit, Str] {
  assert_true(list.is_empty(resolver.roles_for(charging_map(), "coordination")), "an intent the host never mapped must return no role constraint (empty), not an error")
}

fn intents_of_lists_every_entry() -> Result[Unit, Str] {
  let got := resolver.intents_of(charging_map())
  assert_true(got == ["charging", "charging", "billing"], str.concat("intents_of should surface one entry per map row (order-preserving, dupes included), got ", str.join(got, ",")))
}

# ── resolve() fallback + narrowing ───────────────────────────────────────────
fn seed(db :: Db) -> [sql, fs_write, random, time] Unit {
  let __m := migrate.run(db)
  let __a := reg.register_in(db, "acme", "truck-1", "truck", "Truck 1", "http://x/1", [])
  let __b := reg.register_in(db, "acme", "charger-07", "charger", "Charger 7", "http://x/2", [])
  let __c := reg.register_in(db, "acme", "billing-svc", "tms", "Billing", "http://x/3", [])
  let __r1 := rel.add(db, "truck-1", "charger-07", "charger", "{}")
  let __r2 := rel.add(db, "truck-1", "billing-svc", "tms", "{}")
  ()
}

# An empty map (host defined no intents at all) must resolve to every active
# peer — the generic "coordination" fallback resolver.lex's own docstring
# promises, not an empty list.
fn resolve_empty_map_returns_all_peers() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := seed(db)
      match resolver.resolve(db, "truck-1", "coordination", []) {
        Err(e) => Err(e),
        Ok(refs) => assert_true(same_set(ids_of(refs), ["charger-07", "billing-svc"]), str.concat("expected all peers, got ", str.join(ids_of(refs), ","))),
      }
    },
  }
}

# A mapped intent must narrow to only the role(s) it lists — a peer reached
# via a different role (billing-svc, role "tms") must not leak into a
# "charging" (role "charger") resolution.
fn resolve_narrows_to_mapped_roles() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := seed(db)
      let map := [{ intent: "charging", roles: ["charger"] }]
      match resolver.resolve(db, "truck-1", "charging", map) {
        Err(e) => Err(e),
        Ok(refs) => if same_set(ids_of(refs), ["charger-07"]) {
          Ok(())
        } else {
          Err(str.concat("charging must resolve only the charger-role peer, got ", str.join(ids_of(refs), ",")))
        },
      }
    },
  }
}

# A mapped intent whose role no relationship actually uses resolves to zero
# peers, not a fallback to "all" — the map, once it names the intent, is the
# authority on what counts.
fn resolve_mapped_intent_with_no_matching_role_is_empty() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := seed(db)
      let map := [{ intent: "dispatch", roles: ["dispatcher"] }]
      match resolver.resolve(db, "truck-1", "dispatch", map) {
        Err(e) => Err(e),
        Ok(refs) => assert_true(list.is_empty(refs), str.concat("expected no peers for an unmatched role, got ", str.join(ids_of(refs), ","))),
      }
    },
  }
}

fn resolve_one_returns_first_match() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := seed(db)
      let map := [{ intent: "charging", roles: ["charger"] }]
      match resolver.resolve_one(db, "truck-1", "charging", map) {
        Err(e) => Err(e),
        Ok(None) => Err("expected a match"),
        Ok(Some(r)) => assert_true(r.id == "charger-07", str.concat("expected charger-07, got ", r.id)),
      }
    },
  }
}

fn resolve_one_none_when_no_relationships() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      match resolver.resolve_one(db, "lonely-truck", "coordination", []) {
        Err(e) => Err(e),
        Ok(None) => Ok(()),
        Ok(Some(r)) => Err(str.concat("expected None for an agent with no relationships, got ", r.id)),
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, random, time] Unit {
  let results := [roles_for_concatenates_across_entries(), roles_for_unmapped_intent_is_empty(), intents_of_lists_every_entry(), resolve_empty_map_returns_all_peers(), resolve_narrows_to_mapped_roles(), resolve_mapped_intent_with_no_matching_role_is_empty(), resolve_one_returns_first_match(), resolve_one_none_when_no_relationships()]
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

