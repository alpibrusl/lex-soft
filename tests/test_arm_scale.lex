# tests/test_arm_scale.lex — regression: arm.tally() must not scan the whole
# trail. It used to call tlog.range(log, 0, huge) — every event ever appended,
# regardless of counterparty — then interpretively JSON-parse each one. That
# is O(total trail size) per query: fine for a handful of events, but a
# long-running node's trail accumulates thousands (task received/step/
# completed events for every agent), and the interpreter's step budget blew
# on a live demo node once its trail passed ~2000 events. Fixed by scoping the
# scan to `kind IN (arm.outcome, arm.spend)` + a LIKE on the counterparty id at
# the SQL layer (idx_events_kind), before the interpreted per-row parse.

import "std.io" as io

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "../src/migrate" as migrate

import "../src/settlement" as settlement

import "../src/arm" as arm

fn tally_over_a_large_trail_does_not_exceed_the_step_budget() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let __bulk := list.fold(list.range(0, 2500), (), fn (_acc :: Unit, n :: Int) -> [sql, time] Unit {
        let __e := settlement.record_run(log, str.concat("agent-", int.to_str(n)), "handle", "in", "out", [])
        ()
      })
      let __o1 := arm.record_outcome(log, "truck-01", true)
      let __o2 := arm.record_outcome(log, "truck-01", true)
      let __o3 := arm.record_outcome(log, "truck-01", false)
      let t := arm.tally(db, "truck-01")
      if t.interactions == 3 and t.verified == 2 {
        if arm.trust_score(t) == 66 {
          Ok(())
        } else {
          Err(str.concat("unexpected trust_score: ", int.to_str(arm.trust_score(t))))
        }
      } else {
        Err(str.concat("unexpected tally over a large trail: interactions=", str.concat(int.to_str(t.interactions), str.concat(" verified=", int.to_str(t.verified)))))
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [tally_over_a_large_trail_does_not_exceed_the_step_budget()]
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

