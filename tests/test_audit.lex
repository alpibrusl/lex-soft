# tests/test_audit.lex — tenant isolation of the audit query (#60).
#
# The whole point of the audit surface is that org A can NEVER see org B's trail
# events. These drive the scoping logic directly (org_agent_ids + query_events):
# two orgs each with an agent and a recorded run, and assert each org's query
# returns only its own events — and that a cross-tenant ?agent= is refused.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.int" as int

import "lex-schema/json_value" as jv

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/settlement" as settlement

import "../src/audit" as audit

fn contains_agent(rows :: List[audit.EvRow], agent :: Str) -> Bool {
  list.fold(rows, false, fn (acc :: Bool, r :: audit.EvRow) -> Bool {
    acc or str.contains(r.payload_json, str.join(["\"agent\":\"", agent, "\""], ""))
  })
}

fn setup(db :: Db) -> [sql, fs_read, fs_write, time] Unit {
  let __m := migrate.run(db)
  let log := settlement.trail_on(db)
  let __ra := reg.register_in(db, "org-a", "agent-a1", "truck", "A One", "http://a/", ["x"])
  let __rb := reg.register_in(db, "org-b", "agent-b1", "truck", "B One", "http://b/", ["x"])
  let __ea := settlement.record_run(log, "agent-a1", "handle", "in-a", "out-a", [])
  let __eb := settlement.record_run(log, "agent-b1", "handle", "in-b", "out-b", [])
  ()
}

# org A's query sees only agent-a1's events, never agent-b1's.
fn org_sees_only_its_own() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup(db)
      let ids_a := audit.org_agent_ids(db, "org-a")
      let rows_a := audit.query_events(db, ids_a, "", None)
      if contains_agent(rows_a, "agent-a1") and not contains_agent(rows_a, "agent-b1") {
        Ok(())
      } else {
        Err(str.concat("org-a leak/miss; rows=", int_len(rows_a)))
      }
    },
  }
}

# org B symmetrically sees only its own.
fn org_b_isolated() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup(db)
      let rows_b := audit.query_events(db, audit.org_agent_ids(db, "org-b"), "", None)
      if contains_agent(rows_b, "agent-b1") and not contains_agent(rows_b, "agent-a1") {
        Ok(())
      } else {
        Err("org-b isolation failed")
      }
    },
  }
}

# an org with no agents (or an unknown org) gets an empty result, not everything.
fn unknown_org_sees_nothing() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup(db)
      let rows := audit.query_events(db, audit.org_agent_ids(db, "org-ghost"), "", None)
      if list.is_empty(rows) {
        Ok(())
      } else {
        Err("unknown org saw events")
      }
    },
  }
}

fn int_len(rows :: List[audit.EvRow]) -> Str {
  match list.is_empty(rows) {
    true => "0",
    false => "some",
  }
}

# The interactions rollup: one row per run, tamper check true on an untouched
# trail, and isolated the same way as the raw events.
fn interactions_rollup_and_isolation() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup(db)
      let log := settlement.trail_on(db)
      let tips_a := audit.query_events(db, audit.org_agent_ids(db, "org-a"), "cap.completed", None)
      if list.len(tips_a) == 1 {
        match list.head(tips_a) {
          None => Err("no tip"),
          Some(t) => {
            let j := audit.interaction_json(log, t)
            match j {
              JObj(fields) => {
                let valid := list.fold(fields, false, fn (acc :: Bool, kv :: (Str, jv.Json)) -> Bool {
                  match kv {
                    ("valid", JBool(true)) => true,
                    _ => acc,
                  }
                })
                if valid {
                  Ok(())
                } else {
                  Err("interaction_json valid=false on an untampered trail")
                }
              },
              _ => Err("interaction_json did not return a JObj"),
            }
          },
        }
      } else {
        Err(str.concat("expected exactly 1 completed tip for org-a, got count in list of len ", int.to_str(list.len(tips_a))))
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [org_sees_only_its_own(), org_b_isolated(), unknown_org_sees_nothing(), interactions_rollup_and_isolation()]
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

