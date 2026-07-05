# tests/test_arm.lex — acceptance tests for #27 (ARM: counterparty profile +
# trust score). Asserts:
#   - the trust score is re-derived from the trail and REPRODUCIBLE,
#   - it CHANGES when new verified outcomes / denied spends land,
#   - the profile JOINS identity + relationships + memory + reputation + spend,
#   - the good-standing gate an agent calls before accepting a task.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "../src/migrate" as migrate

import "../src/settlement" as settlement

import "../src/registry" as reg

import "../src/relationships" as rel

import "../src/trace" as trace

import "../src/arm" as arm

fn score_of(log :: tlog.Log, cp :: Str) -> [sql] Int {
  arm.trust_score(arm.tally(log.db, cp))
}

# 3 verified of 4 interactions → 75; and re-deriving it gives the same answer.
fn trust_score_reproducible() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let __1 := arm.record_outcome(log, "partner-co", true)
      let __2 := arm.record_outcome(log, "partner-co", true)
      let __3 := arm.record_outcome(log, "partner-co", true)
      let __4 := arm.record_outcome(log, "partner-co", false)
      let s1 := score_of(log, "partner-co")
      let s2 := score_of(log, "partner-co")
      if s1 == 75 and s2 == 75 {
        Ok(())
      } else {
        Err(str.concat("expected reproducible 75, got ", str.concat(int.to_str(s1), str.concat("/", int.to_str(s2)))))
      }
    },
  }
}

# A new verified outcome and a denied spend both move the score.
fn score_changes_with_history() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let __1 := arm.record_outcome(log, "p", true)
      let after_good := score_of(log, "p")
      let __2 := arm.record_outcome(log, "p", false)
      let after_fail := score_of(log, "p")
      let __3 := arm.record_spend(log, "p", false, 9000)
      let after_denied := score_of(log, "p")
      if after_good == 100 and after_fail == 50 and after_denied < after_fail {
        Ok(())
      } else {
        Err(str.concat("score should track history: ", str.join([int.to_str(after_good), int.to_str(after_fail), int.to_str(after_denied)], ",")))
      }
    },
  }
}

# An unknown counterparty is neutral (50) and not in good standing at 60.
fn unknown_is_neutral() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let t := arm.tally(log.db, "stranger")
      if arm.trust_score(t) == 50 and not arm.in_good_standing(t, 60) {
        Ok(())
      } else {
        Err("an unknown counterparty should be neutral (50) and below a 60 gate")
      }
    },
  }
}

# The profile joins identity + relationships + memory + reputation into one view.
fn profile_joins_sources() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let __reg := reg.register(db, "partner-co", "external", "Partner Co", "", ["logistics.query"])
      let __rel := rel.add(db, "partner-co", "truck-01", "contracted", "{}")
      let __mem := trace.remember_kv(db, "partner-co", "", "note", "pays on time", "", "", "")
      let __o := arm.record_outcome(log, "partner-co", true)
      let pj := arm.profile_json(db, log, "partner-co")
      match jv.parse(pj) {
        Err(_) => Err("profile json did not parse"),
        Ok(j) => {
          let has := fn (k :: Str) -> Bool {
            match jv.get_field(j, k) {
              Some(_) => true,
              None => false,
            }
          }
          let id_present := match jv.get_field(j, "identity") {
            Some(JObj(_)) => true,
            _ => false,
          }
          let rels_present := match jv.get_field(j, "relationships") {
            Some(JList(xs)) => not list.is_empty(xs),
            _ => false,
          }
          if id_present and rels_present and has("trust_score") and has("spend") and has("memory") and has("interactions") {
            Ok(())
          } else {
            Err("profile should join identity + relationships + trust_score + spend + memory")
          }
        },
      }
    },
  }
}

# Good standing gates accept-dispatch: a reliable peer passes a 60 threshold.
fn good_standing_gate() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let log := settlement.trail_on(db)
      let __1 := arm.record_outcome(log, "good", true)
      let __2 := arm.record_outcome(log, "good", true)
      if arm.in_good_standing(arm.tally(log.db, "good"), 60) {
        Ok(())
      } else {
        Err("a peer with all-verified outcomes should be in good standing")
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let results := [trust_score_reproducible(), score_changes_with_history(), unknown_is_neutral(), profile_joins_sources(), good_standing_gate()]
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

