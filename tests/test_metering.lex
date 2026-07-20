# tests/test_metering.lex — usage counters + plan quotas (#61).
#
# usage_for aggregates the same tenant-scoped slice audit.lex queries, but as
# SQL counts. over_quota() gates onboarding (federation.lex's POST
# /connections) so a plan-exhausted org can't onboard more agents.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/settlement" as settlement

import "../src/metering" as metering

fn setup_with_n_tasks(db :: Db, org :: Str, agent :: Str, n :: Int) -> [sql, fs_read, fs_write, time] Unit {
  let __m := migrate.run(db)
  let __r := reg.register_in(db, org, agent, "truck", agent, "http://x/", ["x"])
  let log := settlement.trail_on(db)
  let __runs := list.fold(list.range(0, n), (), fn (_acc :: Unit, i :: Int) -> [sql, time] Unit {
    let __e := settlement.record_run(log, agent, "handle", str.concat("in-", int.to_str(i)), "out", [])
    ()
  })
  ()
}

# usage_for counts exactly the recorded task completions for the org's agent,
# and reports 0 spend (arm.record_spend has no callers today — honest zero).
fn usage_counts_tasks() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup_with_n_tasks(db, "org-m", "agent-m1", 5)
      match metering.usage_for(db, "org-m") {
        Err(e) => Err(str.concat("usage_for failed: ", e)),
        Ok(u) => if u.tasks == 5 and u.spend_total == 0 and u.spend_denied == 0 {
          Ok(())
        } else {
          Err(str.concat("unexpected usage: tasks=", str.concat(int.to_str(u.tasks), str.concat(" spend_total=", int.to_str(u.spend_total)))))
        },
      }
    },
  }
}

# A plan's task quota trips over_quota once usage reaches the ceiling; a
# different, unrelated org is unaffected (the quota is per-org, from the
# tenant-scoped usage_for, not global).
fn over_quota_trips_at_the_plan_ceiling() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup_with_n_tasks(db, "org-free", "agent-f1", 100)
      let __s2 := setup_with_n_tasks(db, "org-quiet", "agent-q1", 1)
      if metering.over_quota(db, "org-free", "free") {
        if metering.over_quota(db, "org-quiet", "free") {
          Err("an org with only 1 task tripped the free-plan quota")
        } else {
          Ok(())
        }
      } else {
        Err("an org at exactly the free-plan ceiling (100 tasks) was not flagged over quota")
      }
    },
  }
}

# A pro-plan org is not over quota at the same task count that trips free.
fn higher_plan_raises_the_ceiling() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup_with_n_tasks(db, "org-pro", "agent-p1", 100)
      if metering.over_quota(db, "org-pro", "pro") {
        Err("a pro-plan org was flagged over quota at only 100 tasks")
      } else {
        Ok(())
      }
    },
  }
}

# Float-hostile amounts (0.10 + 0.20) must sum to exactly "0.30" through the
# amount_dec path; a malformed amount is an Err, never a silent zero.
fn exact_chargebacks_sum_exactly() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := setup_with_n_tasks(db, "org-x", "agent-x1", 1)
      let log := settlement.trail_on(db)
      let r1 := settlement.record_chargeback_dec(log, "agent-x1", "peer", "0.10", "EUR", "cb-x-1")
      let r2 := settlement.record_chargeback_dec(log, "agent-x1", "peer", "0.20", "EUR", "cb-x-2")
      let bad := settlement.record_chargeback_dec(log, "agent-x1", "peer", "1,50", "EUR", "cb-x-3")
      let both_ok := match r1 {
        Ok(_) => match r2 {
          Ok(_) => true,
          Err(_) => false,
        },
        Err(_) => false,
      }
      let bad_rejected := match bad {
        Err(_) => true,
        Ok(_) => false,
      }
      match metering.usage_for(db, "org-x") {
        Err(e) => Err(str.concat("usage_for failed: ", e)),
        Ok(u) => if both_ok and bad_rejected and u.chargeback_count == 2 and u.chargeback_total_dec == "0.30" {
          Ok(())
        } else {
          Err(str.concat("exact sum wrong: count=", str.concat(int.to_str(u.chargeback_count), str.concat(" total_dec=", u.chargeback_total_dec))))
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [usage_counts_tasks(), over_quota_trips_at_the_plan_ceiling(), higher_plan_raises_the_ceiling(), exact_chargebacks_sum_exactly()]
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

