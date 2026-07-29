# src/ctl.lex — host-opt-in wiring of the lex-ctl controller kernel to
# soft's own scheduler + outbox (#106 task 2; feeds lex-loom#118/#126).
#
# lex-ctl (github.com/alpibrusl/lex-ctl) ships mechanism only: effect
# contracts, the verifier's pure judgement, autonomy tiers, and
# stability primitives — no SQL, no HTTP, no host vocabulary. This
# module is the thin, OPT-IN host integration a product wires in if it
# wants a pack action to carry a falsifiable predicted effect: SQL
# storage for proposed contracts, a scheduled pass that judges the ones
# past their deadline, a trail record of the disposition (same
# tamper-evident substrate as verdict.lex/evidence.lex), and an outbox
# notification back to the agent that proposed the action.
#
# NOT part of core migrate.lex — a deployment that never calls
# `ctl.init` never gets this table, same as `scheduler`/`outbox` are
# opt-in per product, not forced on every lex-soft install.
#
# Deliberately out of scope here (soft#106's remaining tasks, not this
# one):
#   - Tier integration: routing Propose/Escalate outcomes through
#     `escalation`/`human_gateway`, and the trust-boundary rule that the
#     gate consults only `cap.gate` + action classification, never
#     message narrative. This module never imports `lex-ctl/src/tier`
#     or `lex-ctl/src/stability` — a host wanting autonomy tiers layers
#     that on top of the disposition history this module persists.
#   - `verdict` <-> contract-disposition interplay.
#
#   POST /ctl/contracts       propose a contract (pack supplies the
#                             predicate/deadline/confidence/on_falsify —
#                             this module invents no policy)
#   GET  /ctl/contracts/:id   read one contract's current disposition
#
# Both routes are DB-only — safe on the in-process serve router, same
# reasoning as `scheduler.mount`'s subscription CRUD. `run_loop` is
# SIDECAR ONLY: judging a contract calls the host-supplied `observe`
# callback, which does outbound HTTP to read the real signal value —
# exactly why `scheduler.tick_once`/`run_loop` also require a sidecar.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-ctl/src/contract" as kct

import "lex-ctl/src/verify" as kverify

import "./outbox" as outbox

fn ddl() -> Str {
  "CREATE TABLE IF NOT EXISTS ctl_effects (id TEXT PRIMARY KEY, tenant TEXT NOT NULL DEFAULT 'default', action_id TEXT NOT NULL, proposer_id TEXT NOT NULL DEFAULT '', class_key TEXT NOT NULL, subsystem TEXT NOT NULL, signal TEXT NOT NULL, cmp TEXT NOT NULL, threshold_milli BIGINT NOT NULL, deadline_ms BIGINT NOT NULL, confidence_pct BIGINT NOT NULL, on_falsify TEXT NOT NULL, disposition TEXT NOT NULL DEFAULT 'pending', proposed_at_ms BIGINT NOT NULL DEFAULT 0, disposed_at_ms BIGINT NOT NULL DEFAULT 0)"
}

fn ddl_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_ctl_effects_due ON ctl_effects(tenant, disposition, deadline_ms)"
}

# Call once at boot, same as `outbox.init`. Idempotent.
fn init(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, ddl(), []) {
    Err(e) => Err(e.message),
    Ok(_) => match sql.exec(db, ddl_idx(), []) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(()),
    },
  }
}

type EffectRow = { id :: Str, tenant :: Str, action_id :: Str, proposer_id :: Str, class_key :: Str, subsystem :: Str, signal :: Str, cmp :: Str, threshold_milli :: Int, deadline_ms :: Int, confidence_pct :: Int, on_falsify :: Str, disposition :: Str, proposed_at_ms :: Int, disposed_at_ms :: Int }

fn cols() -> Str {
  "id, tenant, action_id, proposer_id, class_key, subsystem, signal, cmp, threshold_milli, deadline_ms, confidence_pct, on_falsify, disposition, proposed_at_ms, disposed_at_ms"
}

# ── Str <-> kernel enum, the direction lex-ctl doesn't provide (it only
# serializes, for its content hash — it never needs to parse a host's
# stored row back into its own types).
fn cmp_of_str(s :: Str) -> kct.Comparator
  examples {
    cmp_of_str("above") => Above,
    cmp_of_str("below") => Below,
    cmp_of_str("garbage") => Below
  }
{
  match s {
    "above" => Above,
    _ => Below,
  }
}

fn on_falsify_of_str(s :: Str) -> kct.OnFalsify
  examples {
    on_falsify_of_str("hold") => Hold,
    on_falsify_of_str("handoff") => Handoff,
    on_falsify_of_str("rollback") => Rollback,
    on_falsify_of_str("garbage") => Rollback
  }
{
  match s {
    "hold" => Hold,
    "handoff" => Handoff,
    _ => Rollback,
  }
}

fn outcome_str(o :: kverify.Outcome) -> Str
  examples {
    outcome_str(Pending) => "pending",
    outcome_str(Materialised) => "materialised",
    outcome_str(Falsified) => "falsified",
    outcome_str(Ambiguous) => "ambiguous"
  }
{
  match o {
    Pending => "pending",
    Materialised => "materialised",
    Falsified => "falsified",
    Ambiguous => "ambiguous",
  }
}

# The stored row IS the contract's content — reconstructed directly
# rather than recomputed through `kct.make` (which would derive a fresh
# id from the fields and silently mask a corrupted row instead of
# surfacing it as an id mismatch).
fn to_contract(r :: EffectRow) -> kct.EffectContract {
  { id: r.id, action_id: r.action_id, class_key: r.class_key, subsystem: r.subsystem, predicate: { signal: r.signal, cmp: cmp_of_str(r.cmp), threshold_milli: r.threshold_milli }, deadline_ms: r.deadline_ms, confidence_pct: r.confidence_pct, on_falsify: on_falsify_of_str(r.on_falsify) }
}

# ── Storage ───────────────────────────────────────────────────────────────
# Idempotent: the same logical prediction has the same content-addressed
# id wherever it's proposed (lex-ctl's own invariant), so re-proposing
# is a safe no-op rather than an error.
fn propose(db :: Db, tenant :: Str, proposer_id :: Str, contract :: kct.EffectContract, now_ms :: Int) -> [sql] Result[Unit, Str] {
  let q := "INSERT INTO ctl_effects (id, tenant, action_id, proposer_id, class_key, subsystem, signal, cmp, threshold_milli, deadline_ms, confidence_pct, on_falsify, disposition, proposed_at_ms, disposed_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, 0) ON CONFLICT(id) DO NOTHING"
  match sql.exec(db, q, [PStr(contract.id), PStr(tenant), PStr(contract.action_id), PStr(proposer_id), PStr(contract.class_key), PStr(contract.subsystem), PStr(contract.predicate.signal), PStr(kct.cmp_str(contract.predicate.cmp)), PInt(contract.predicate.threshold_milli), PInt(contract.deadline_ms), PInt(contract.confidence_pct), PStr(kct.on_falsify_str(contract.on_falsify)), PInt(now_ms)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn get_by_id(db :: Db, id :: Str) -> [sql] Option[EffectRow] {
  let q := str.join(["SELECT ", cols(), " FROM ctl_effects WHERE id=?"], "")
  let rows :: Result[List[EffectRow], SqlError] := sql.query(db, q, [PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

# Still-pending contracts whose deadline has passed — what a verify
# pass judges this tick. Only guards on `disposition='pending'` in the
# UPDATE below, so a contract judged twice (a slow tick overlapping the
# next) is a safe no-op the second time, never a double notification.
fn pending_due(db :: Db, tenant :: Str, now_ms :: Int) -> [sql] List[EffectRow] {
  let q := str.join(["SELECT ", cols(), " FROM ctl_effects WHERE tenant=? AND disposition='pending' AND deadline_ms<=? ORDER BY deadline_ms ASC"], "")
  let rows :: Result[List[EffectRow], SqlError] := sql.query(db, q, [PStr(tenant), PInt(now_ms)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# Returns the affected row count (0 or 1) rather than Unit — a caller
# racing another tick on the same contract needs to know whether IT was
# the one that actually flipped the row, not just that the UPDATE ran
# without error (a WHERE clause matching zero rows is still Ok(0), not
# an error). `judge_and_record` uses this to gate the trail write and
# outbox notify, so a race can't double-fire either one.
fn record_disposition(db :: Db, id :: Str, outcome :: kverify.Outcome, disposed_at_ms :: Int) -> [sql] Result[Int, Str] {
  let q := "UPDATE ctl_effects SET disposition=?, disposed_at_ms=? WHERE id=? AND disposition='pending'"
  match sql.exec(db, q, [PStr(outcome_str(outcome)), PInt(disposed_at_ms), PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(n) => Ok(n),
  }
}

# ── The verifier's judgement, wired to a real observation ───────────────────
# The kernel has no notion of "the real world" — `observed_milli`/
# `concurrent_on_subsystem` are exactly what a host must supply, per
# contract, at judgement time. Pinned to [net, io] (same pinning
# discipline as this repo's tool `execute` closures, DOMAIN-PACKS.md):
# a real observe implementation calls the domain backend over HTTP.
type Observation = { observed_milli :: Option[Int], concurrent_on_subsystem :: Int }

fn k_disposed() -> Str {
  "ctl.effect.disposed"
}

fn disposition_payload(r :: EffectRow, outcome :: kverify.Outcome) -> Str {
  jv.stringify(JObj([("agent", JStr(r.proposer_id)), ("from_agent", JStr(r.proposer_id)), ("contract_id", JStr(r.id)), ("action_id", JStr(r.action_id)), ("class_key", JStr(r.class_key)), ("subsystem", JStr(r.subsystem)), ("outcome", JStr(outcome_str(outcome)))]))
}

# Judge one due contract and, only on a FINAL disposition (never on
# Pending — `is_final` is the kernel's own call), persist it, trail-
# record it (audit-shaped: `agent`/`from_agent` set, same rule
# evidence.lex enforces), and enqueue an outbox notification back to
# whichever agent proposed the action. Reuses `outbox`'s existing
# durable queue rather than inventing a second delivery mechanism.
fn judge_and_record(db :: Db, log :: tlog.Log, r :: EffectRow, now_ms :: Int, observe :: (EffectRow) -> [net, io] Observation) -> [net, io, sql, time] Result[kverify.Outcome, Str] {
  let obs := observe(r)
  let outcome := kverify.judge(to_contract(r), obs.observed_milli, now_ms, obs.concurrent_on_subsystem)
  if kverify.is_final(outcome) {
    match record_disposition(db, r.id, outcome, now_ms) {
      Err(e) => Err(e),
      Ok(0) => Ok(outcome),
      Ok(_) => {
        let __trail := tlog.append_actor(log, k_disposed(), r.proposer_id, None, disposition_payload(r, outcome))
        let __notify := if str.is_empty(r.proposer_id) {
          Ok(())
        } else {
          outbox.enqueue(db, "ctl", r.proposer_id, "ctl.disposition", disposition_payload(r, outcome))
        }
        Ok(outcome)
      },
    }
  } else {
    Ok(outcome)
  }
}

# One sweep over every due contract for a tenant.
fn verify_pass(db :: Db, log :: tlog.Log, tenant :: Str, now_ms :: Int, observe :: (EffectRow) -> [net, io] Observation) -> [net, io, sql, time] List[(Str, Str)] {
  list.map(pending_due(db, tenant, now_ms), fn (r :: EffectRow) -> [net, io, sql, time] (Str, Str) {
    match judge_and_record(db, log, r, now_ms, observe) {
      Err(e) => (r.id, str.concat("error: ", e)),
      Ok(o) => (r.id, outcome_str(o)),
    }
  })
}

# Blocking loop for the sidecar process — same shape as
# `scheduler.run_loop`, same reason (outbound HTTP via `observe`).
fn run_loop(db :: Db, log :: tlog.Log, tenant :: Str, observe :: (EffectRow) -> [net, io] Observation, sleep_ms :: Int) -> [net, io, sql, time, concurrent] Unit {
  let __pass := verify_pass(db, log, tenant, time.now_ms(), observe)
  let __z := time.sleep_ms(sleep_ms)
  run_loop(db, log, tenant, observe, sleep_ms)
}

# ── mount_ctl: DB-only CRUD, safe on the in-process serve router ───────────
fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

fn effect_row_json(r :: EffectRow) -> jv.Json {
  JObj([("id", JStr(r.id)), ("tenant", JStr(r.tenant)), ("action_id", JStr(r.action_id)), ("proposer_id", JStr(r.proposer_id)), ("class_key", JStr(r.class_key)), ("subsystem", JStr(r.subsystem)), ("signal", JStr(r.signal)), ("cmp", JStr(r.cmp)), ("threshold_milli", JInt(r.threshold_milli)), ("deadline_ms", JInt(r.deadline_ms)), ("confidence_pct", JInt(r.confidence_pct)), ("on_falsify", JStr(r.on_falsify)), ("disposition", JStr(r.disposition)), ("proposed_at_ms", JInt(r.proposed_at_ms)), ("disposed_at_ms", JInt(r.disposed_at_ms))])
}

# POST /ctl/contracts  {tenant?, proposer_id?, action_id, class_key,
#                        subsystem, signal, cmp, threshold_milli,
#                        deadline_ms, confidence_pct, on_falsify}
# GET  /ctl/contracts/:id
fn mount_ctl(r :: router.Router, db :: Db) -> router.Router {
  let with_post := router.route_effectful(r, "POST", "/ctl/contracts", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let action_id := jstr(j, "action_id")
        let class_key := jstr(j, "class_key")
        let subsystem := jstr(j, "subsystem")
        let signal := jstr(j, "signal")
        if str.is_empty(action_id) or str.is_empty(class_key) or str.is_empty(subsystem) or str.is_empty(signal) {
          resp.bad_request("{\"error\":\"action_id, class_key, subsystem, signal are required\"}")
        } else {
          let tenant := if str.is_empty(jstr(j, "tenant")) {
            "default"
          } else {
            jstr(j, "tenant")
          }
          let predicate := { signal: signal, cmp: cmp_of_str(jstr(j, "cmp")), threshold_milli: jint(j, "threshold_milli") }
          let contract := kct.make(action_id, class_key, subsystem, predicate, jint(j, "deadline_ms"), jint(j, "confidence_pct"), on_falsify_of_str(jstr(j, "on_falsify")))
          match propose(db, tenant, jstr(j, "proposer_id"), contract, time.now_ms()) {
            Err(e) => resp.json(str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
            Ok(_) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("contract_id", JStr(contract.id))]))),
          }
        }
      },
    }
  })
  router.route_effectful(with_post, "GET", "/ctl/contracts/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match ctx.path_param(c, "id") {
      None => resp.not_found(),
      Some(id) => match get_by_id(db, id) {
        None => resp.not_found(),
        Some(row) => resp.json(jv.stringify(effect_row_json(row))),
      },
    }
  })
}

