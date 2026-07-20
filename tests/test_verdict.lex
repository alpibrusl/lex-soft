# tests/test_verdict.lex — acceptance tests for #20 (re-derived verdict).
# Asserts (mirroring the lex-games "authority is re-derived, not trusted" policy):
#   - an honest logistics trail verifies (intact ∧ linked ∧ legal),
#   - a FORGED trail (out-of-grant action claiming success, CORRECT hashes) is
#     legal:false → verified:false (the policy-eval DQ),
#   - a tampered trail is intact:false → verified:false,
#   - the legality check is a DOMAIN SPEC (a lex-spec value), not domain code,
#   - rank_key sinks disqualified verdicts below verified ones.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-trail/kinds" as kinds

import "lex-spec/spec" as sp

import "../src/settlement" as settlement

import "../src/verdict" as verdict

# The logistics legality rule as DATA: "a claimed success must have been in-grant."
fn grant_spec() -> sp.Spec {
  { name: "logistics.grant_on_success", quantifiers: [QRecord({ name: "outcome", fields: [{ name: "claimed_success", ty: TBool }, { name: "in_grant", ty: TBool }] })], predicate: EImplies(EField({ binding: "outcome", field: "claimed_success" }), EField({ binding: "outcome", field: "in_grant" })) }
}

# Build a hash-chained trail whose completed event records {claimed_success, in_grant}.
fn build_trail(log :: tlog.Log, claimed :: Bool, granted :: Bool) -> [sql, time] Str {
  match tlog.append(log, kinds.a2a_task_received(), None, "{\"agent\":\"depot-north\"}") {
    Err(_) => "",
    Ok(e1) => match tlog.append(log, kinds.llm_step(), Some(e1.id), "{}") {
      Err(_) => "",
      Ok(e2) => {
        let done := jv.stringify(JObj([("claimed_success", JBool(claimed)), ("in_grant", JBool(granted))]))
        match tlog.append(log, kinds.cap_completed(), Some(e2.id), done) {
          Err(_) => "",
          Ok(e3) => e3.id,
        }
      },
    },
  }
}

fn honest_trail_verifies() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let tid := build_trail(log, true, true)
      let v := verdict.verify(log, tid, Some(grant_spec()), "outcome")
      if v.verified and v.intact and v.linked and v.legal {
        Ok(())
      } else {
        Err(str.concat("honest trail should fully verify, reason=", v.reason))
      }
    },
  }
}

fn forged_out_of_grant_is_illegal() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let tid := build_trail(log, true, false)
      let v := verdict.verify(log, tid, Some(grant_spec()), "outcome")
      if v.intact and v.linked and not v.legal and not v.verified {
        Ok(())
      } else {
        Err(str.concat("forged out-of-grant trail should be legal:false → verified:false, reason=", v.reason))
      }
    },
  }
}

fn tampered_trail_not_intact() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let tid := build_trail(log, true, true)
      let __m := sql.exec(db, str.concat("UPDATE events SET payload_json='{\"claimed_success\":true,\"in_grant\":true,\"x\":1}' WHERE id='", str.concat(tid, "'")), [])
      let v := verdict.verify(log, tid, Some(grant_spec()), "outcome")
      if not v.intact and not v.verified {
        Ok(())
      } else {
        Err("a tampered trail must report intact:false → verified:false")
      }
    },
  }
}

# No spec → legality defaults to true (only integrity is checked).
fn no_spec_defaults_legal() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let tid := build_trail(log, true, false)
      let v := verdict.verify(log, tid, None, "outcome")
      if v.legal and v.verified {
        Ok(())
      } else {
        Err("with no spec, an intact+linked trail should verify")
      }
    },
  }
}

# Disqualified verdicts sort after verified ones (shared lex-games rank rule).
fn rank_sinks_disqualified() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let good := verdict.verify(log, build_trail(log, true, true), Some(grant_spec()), "outcome")
      let bad := verdict.verify(log, build_trail(log, true, false), Some(grant_spec()), "outcome")
      if verdict.rank_key(good) < verdict.rank_key(bad) {
        Ok(())
      } else {
        Err("a verified verdict must rank ahead of a disqualified one")
      }
    },
  }
}

# H-1: an unregistered capability must NOT verify. The /verify endpoint builds a
# fail-closed verdict (verified:false, spec_applied:false) even over an intact,
# linked trail, and spec_applied distinguishes "no spec checked" from "spec passed".
fn unregistered_capability_fails_closed() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let tid := build_trail(log, true, false)
      let with_spec := verdict.verify(log, tid, Some(grant_spec()), "outcome")
      let integrity := verdict.verify(log, tid, None, "outcome")
      let closed := verdict.no_spec_verdict(integrity, "cap.unknown")
      if with_spec.spec_applied and not integrity.spec_applied and not closed.verified and not closed.spec_applied and closed.intact {
        Ok(())
      } else {
        Err("unregistered capability must fail closed with spec_applied=false")
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := [honest_trail_verifies(), forged_out_of_grant_is_illegal(), tampered_trail_not_intact(), no_spec_defaults_legal(), rank_sinks_disqualified(), unregistered_capability_fails_closed()]
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

