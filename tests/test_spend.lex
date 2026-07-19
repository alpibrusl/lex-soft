# tests/test_spend.lex — acceptance tests for #21 (priced, capped tasks).
# Asserts:
#   - a task within cap settles (approved + executor_ref) and the spend
#     attestation is part of the verifiable (hash-chained, intact) trail,
#   - an over-cap task is DENIED (approved:false, denial_reason) and NEVER
#     charged (no executor_ref).

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-trail/log" as tlog

import "lex-trail/export" as txport

import "lex-guard/src/models" as gm

import "lex-guard/src/token" as gtoken

import "lex-trail/kinds" as kinds

import "lex-schema/json_value" as jv

import "lex-spec/spec" as sp

import "lex-guard/src/release" as grel

import "../src/settlement" as settlement

import "../src/spend" as spend

type KP = { secret :: Bytes, pub :: Str }

fn kp() -> KP {
  let secret := crypto.sha256(bytes.from_str("budget-issuer-seed"))
  let pub := match gtoken.public_key(secret) {
    Ok(p) => p,
    Err(_) => "",
  }
  { secret: secret, pub: pub }
}

# A budget policy capping per-transaction spend; everything else unrestricted.
fn policy(cap_tx :: Int) -> gm.Policy {
  { token_id: "tok-depot", agent_id: "depot-north", currency: "USDC", cap_total: 0, cap_per_day: 0, cap_per_transaction: cap_tx, merchants_allow: [], categories_allow: [], max_tx_per_hour: 0, expires_at: 9999999999, require_memo: false, policy_version: 1 }
}

fn mint(k :: KP, cap_tx :: Int) -> Str {
  match gtoken.issue(k.secret, policy(cap_tx)) {
    Ok(t) => t,
    Err(_) => "",
  }
}

fn charge_intent(amount :: Int) -> gm.SpendIntent {
  spend.intent("charge-roaming-co", amount, "USDC", "charging", "depot roaming session")
}

# Within the per-tx cap: settles (approved + a settlement ref).
fn within_cap_settles() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let k := kp()
      match spend.authorize_spend_mock(log, k.pub, mint(k, 5000), charge_intent(2000)) {
        Err(e) => Err(str.concat("authorize failed: ", e)),
        Ok(o) => if o.approved and not str.is_empty(o.executor_ref) {
          Ok(())
        } else {
          Err(str.concat("within-cap spend should settle, denial=", o.denial_reason))
        },
      }
    },
  }
}

# Over the per-tx cap: denied and never charged.
fn over_cap_denied_not_charged() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let k := kp()
      match spend.authorize_spend_mock(log, k.pub, mint(k, 2500), charge_intent(9999)) {
        Err(e) => Err(str.concat("authorize errored instead of denying: ", e)),
        Ok(o) => if not o.approved and str.is_empty(o.executor_ref) and not str.is_empty(o.denial_reason) {
          Ok(())
        } else {
          Err("over-cap spend must be denied and never charged")
        },
      }
    },
  }
}

# The spend attestation rides in the verifiable hash-chained trail.
fn attestation_in_trail() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let k := kp()
      match spend.authorize_spend_mock(log, k.pub, mint(k, 5000), charge_intent(2000)) {
        Err(e) => Err(str.concat("authorize failed: ", e)),
        Ok(_) => match tlog.range(log, 0, 99999999999999) {
          Err(e) => Err(str.concat("range failed: ", e)),
          Ok(events) => if not list.is_empty(events) and txport.all_valid(events) {
            Ok(())
          } else {
            Err("spend attestation should be present + intact in the trail")
          },
        },
      }
    },
  }
}

# A forged budget token (not signed by the issuer key) is rejected.
fn forged_token_rejected() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let issuer := kp()
      let attacker := { secret: crypto.sha256(bytes.from_str("attacker-seed")), pub: issuer.pub }
      match spend.authorize_spend_mock(log, issuer.pub, mint(attacker, 5000), charge_intent(2000)) {
        Err(_) => Ok(()),
        Ok(_) => Err("a token not signed by the issuer key must be rejected"),
      }
    },
  }
}

# ---- evidence-gated spend (Phase 2: pay only against proven fulfilment) ----
# "outcome.approved == true" — a host fulfilment predicate.
fn proof_spec() -> sp.Spec {
  { name: "delivered", quantifiers: [QRecord({ name: "outcome", fields: [{ name: "approved", ty: TBool }] })], predicate: EBinop({ op: "==", lhs: EField({ binding: "outcome", field: "approved" }), rhs: EConst(VBool(true)) }) }
}

fn fulfilment(log :: tlog.Log, approved :: Bool) -> [sql, time] Result[Str, Str] {
  match tlog.append(log, kinds.cap_completed(), None, jv.stringify(JObj([("approved", JBool(approved))]))) {
    Err(e) => Err(str.concat("record fulfilment: ", e)),
    Ok(ev) => Ok(ev.id),
  }
}

fn proof_of(tid :: Str) -> grel.Evidence {
  { trail_id: tid, spec: Some(proof_spec()), binding: "outcome" }
}

# Within cap AND fulfilment proven → settles.
fn gated_pays_on_proof() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let k := kp()
      match fulfilment(log, true) {
        Err(e) => Err(e),
        Ok(tid) => match spend.authorize_spend_gated_mock(log, k.pub, mint(k, 5000), charge_intent(2000), Some(proof_of(tid))) {
          Err(e) => Err(str.concat("authorize failed: ", e)),
          Ok(o) => if o.approved and not str.is_empty(o.executor_ref) {
            Ok(())
          } else {
            Err(str.concat("proven in-cap spend should settle, denial=", o.denial_reason))
          },
        },
      }
    },
  }
}

# Within cap but fulfilment NOT proven → blocked, never charged.
fn gated_blocks_without_proof() -> [sql, fs_read, fs_write, time, net, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let k := kp()
      match fulfilment(log, false) {
        Err(e) => Err(e),
        Ok(tid) => match spend.authorize_spend_gated_mock(log, k.pub, mint(k, 5000), charge_intent(2000), Some(proof_of(tid))) {
          Err(e) => Err(str.concat("authorize errored instead of blocking: ", e)),
          Ok(o) => if not o.approved and str.is_empty(o.executor_ref) {
            Ok(())
          } else {
            Err("in-cap spend with unproven fulfilment must be blocked and never charged")
          },
        },
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, net, crypto] Unit {
  let results := [within_cap_settles(), over_cap_denied_not_charged(), attestation_in_trail(), forged_token_rejected(), gated_pays_on_proof(), gated_blocks_without_proof()]
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

