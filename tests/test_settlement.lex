# tests/test_settlement.lex — acceptance tests for #19 (trail as the unit of
# settlement). Asserts:
#   - a recorded run returns a content-addressed trail_id,
#   - fetching + re-hashing the trail reproduces the id (verify holds),
#   - a MUTATED trail fails verification (tamper-evident),
#   - an unknown trail id verifies false,
#   - the fetch report carries trail_id + a valid flag.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "../src/settlement" as st

# A fresh recorded run verifies and yields a non-empty trail_id.
fn records_and_verifies() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := st.trail_on(db)
      let tid := st.record_run(log, "truck-01", "handle", "what is my SoC?", "SoC is 62%", ["get_telemetry"])
      if str.is_empty(tid) {
        Err("record_run should return a non-empty trail_id")
      } else {
        if st.verify(log, tid) {
          Ok(())
        } else {
          Err("a freshly recorded trail should verify")
        }
      }
    },
  }
}

# Mutating a stored event breaks the content hash → verification fails.
fn mutated_trail_fails() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := st.trail_on(db)
      let tid := st.record_run(log, "truck-01", "handle", "in", "out", [])
      if st.verify(log, tid) {
        let __m := sql.exec(db, str.concat("UPDATE events SET payload_json='{\"tampered\":1}' WHERE id='", str.concat(tid, "'")), [])
        if st.verify(log, tid) {
          Err("a mutated trail must fail verification")
        } else {
          Ok(())
        }
      } else {
        Err("trail should have verified before mutation")
      }
    },
  }
}

# An unknown trail id verifies false.
fn unknown_trail_denied() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := st.trail_on(db)
      if st.verify(log, "0000nonexistent") {
        Err("unknown trail id should not verify")
      } else {
        Ok(())
      }
    },
  }
}

# The fetch report carries trail_id + a valid flag.
fn report_has_fields() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := st.trail_on(db)
      let tid := st.record_run(log, "tms-primary", "handle", "dispatch", "assigned", [])
      let rep := match jv.parse(st.report_json(log, tid)) {
        Ok(j) => j,
        Err(_) => JNull,
      }
      let has := fn (k :: Str) -> Bool {
        match jv.get_field(rep, k) {
          Some(_) => true,
          None => false,
        }
      }
      if has("trail_id") and has("valid") and has("events") {
        Ok(())
      } else {
        Err("report should carry trail_id, valid and events")
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := [records_and_verifies(), mutated_trail_fails(), unknown_trail_denied(), report_has_fields()]
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

