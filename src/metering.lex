# metering.lex — per-account usage counters and plan quotas (#61).
#
# Aggregates the same tenant-scoped trail slice the Audit API (#60) queries,
# but as SQL-level counts rather than paginated rows — the billing/quota
# substrate, not a browsing view.
#
#   GET /usage   — this account's org's counters (all-time; no period yet)
#
# Counters:
#   tasks        — cap.completed events (one per completed run, #19/#60)
#   escalations  — escalation.requested events (human_gateway.request)
#   spend_total / spend_denied — arm.spend events. NOTE: arm.record_spend has
#     no callers anywhere in this codebase today (spend gating exists in
#     spend.lex but doesn't record into ARM) — these will read 0 until a host
#     wires that up. Reported honestly rather than papered over.
#
# Quotas: `accounts.plan` (identity.lex) maps to a task-count ceiling via
# plan_limit(). over_quota() is an all-time check for MVP simplicity — a
# rolling/billing-period window is a natural follow-up once accounts have a
# billing-cycle anchor. It is wired into federation.lex's POST /connections:
# an org already over its plan's quota cannot onboard MORE agents (a real,
# low-risk enforcement point) — it does not yet gate per-message dispatch.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-money/src/decimal" as mdec

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/kinds" as kinds

import "./identity" as identity

import "./audit" as audit

type Usage = { tasks :: Int, escalations :: Int, spend_total :: Int, spend_denied :: Int, chargeback_count :: Int, chargeback_total :: Float, chargeback_total_dec :: Str }

fn escalation_requested_kind() -> Str {
  "escalation.requested"
}

fn spend_kind() -> Str {
  "arm.spend"
}

fn count_kind(db :: Db, ids :: List[Str], kind :: Str) -> [sql, fs_read] Int {
  if list.is_empty(ids) {
    0
  } else {
    let aw := audit.agent_where(ids)
    let q := str.join(["SELECT COUNT(*) AS n FROM events WHERE ", aw.clause, " AND kind=?"], "")
    let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, q, list.concat(aw.params, [PStr(kind)]))
    match rows {
      Err(_) => 0,
      Ok(rs) => match list.head(rs) {
        None => 0,
        Some(r) => r.n,
      },
    }
  }
}

fn spend_field(payload_json :: Str, key :: Str) -> Bool {
  match jv.parse(payload_json) {
    Err(_) => false,
    Ok(j) => match jv.get_field(j, key) {
      Some(JBool(b)) => b,
      _ => false,
    },
  }
}

fn spend_amount(payload_json :: Str) -> Int {
  match jv.parse(payload_json) {
    Err(_) => 0,
    Ok(j) => match jv.get_field(j, "amount") {
      Some(JInt(n)) => n,
      _ => 0,
    },
  }
}

# arm.spend rows for an org (uncapped scan — spend volume is expected to be far
# lower than task volume; revisit with the same before_ts_ms cursor as #60 if
# that assumption stops holding).
fn chargeback_kind() -> Str {
  "settlement.chargeback"
}

fn pow10_f(exp :: Int) -> Float {
  if exp >= 0 {
    int.to_float(mdec.pow10(exp))
  } else {
    1.0 / int.to_float(mdec.pow10(0 - exp))
  }
}

fn chargeback_amount(payload_json :: Str) -> Float {
  match jv.parse(payload_json) {
    Err(_) => 0.0,
    Ok(j) => match jv.get_field(j, "amount") {
      Some(JFloat(f)) => f,
      Some(JInt(n)) => int.to_float(n),
      _ => 0.0,
    },
  }
}

# Exact amount when the event carries one (settlement.record_chargeback_dec
# stamps amount_dec); legacy float-only events fall back to the float sum.
fn chargeback_amount_dec(payload_json :: Str) -> Option[mdec.Decimal] {
  match jv.parse(payload_json) {
    Err(_) => None,
    Ok(j) => match jv.get_field(j, "amount_dec") {
      Some(JStr(s)) => mdec.parse(s),
      _ => None,
    },
  }
}

fn chargeback_rows(db :: Db, ids :: List[Str]) -> [sql, fs_read] List[{ payload_json :: Str }] {
  if list.is_empty(ids) {
    []
  } else {
    let aw := audit.agent_where(ids)
    let q := str.join(["SELECT payload_json FROM events WHERE ", aw.clause, " AND kind=?"], "")
    let rows :: Result[List[{ payload_json :: Str }], SqlError] := sql.query(db, q, list.concat(aw.params, [PStr(chargeback_kind())]))
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

fn spend_rows(db :: Db, ids :: List[Str]) -> [sql, fs_read] List[{ payload_json :: Str }] {
  if list.is_empty(ids) {
    []
  } else {
    let aw := audit.agent_where(ids)
    let q := str.join(["SELECT payload_json FROM events WHERE ", aw.clause, " AND kind=?"], "")
    let rows :: Result[List[{ payload_json :: Str }], SqlError] := sql.query(db, q, list.concat(aw.params, [PStr(spend_kind())]))
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

fn usage_over_ids(db :: Db, ids :: List[Str]) -> [sql, fs_read] Usage {
  let spends := spend_rows(db, ids)
  let approved_total := list.fold(spends, 0, fn (acc :: Int, r :: { payload_json :: Str }) -> Int {
    if spend_field(r.payload_json, "approved") {
      acc + spend_amount(r.payload_json)
    } else {
      acc
    }
  })
  let denied_count := list.fold(spends, 0, fn (acc :: Int, r :: { payload_json :: Str }) -> Int {
    if spend_field(r.payload_json, "approved") {
      acc
    } else {
      acc + 1
    }
  })
  let cbs := chargeback_rows(db, ids)
  let cb_exact := list.fold(cbs, mdec.zero(), fn (acc :: mdec.Decimal, r :: { payload_json :: Str }) -> mdec.Decimal {
    match chargeback_amount_dec(r.payload_json) {
      Some(d) => mdec.add(acc, d),
      None => acc,
    }
  })
  let cb_legacy := list.fold(cbs, 0.0, fn (acc :: Float, r :: { payload_json :: Str }) -> Float {
    match chargeback_amount_dec(r.payload_json) {
      Some(_) => acc,
      None => acc + chargeback_amount(r.payload_json),
    }
  })
  let exact_norm := mdec.normalize(cb_exact)
  let exact_f := int.to_float(exact_norm.coefficient) * pow10_f(exact_norm.exponent)
  { tasks: count_kind(db, ids, kinds.cap_completed()), escalations: count_kind(db, ids, escalation_requested_kind()), spend_total: approved_total, spend_denied: denied_count, chargeback_count: list.len(cbs), chargeback_total: exact_f + cb_legacy, chargeback_total_dec: mdec.to_str(cb_exact) }
}

# Usage for an org's tenant slice. Propagates a registry failure rather than
# reporting zero usage: a metered counter that silently reads 0 both under-bills
# and disables the quota ceiling built on top of it (M-2).
fn usage_for(db :: Db, org :: Str) -> [sql, fs_read] Result[Usage, Str] {
  match audit.org_agent_ids(db, org) {
    Err(e) => Err(e),
    Ok(ids) => Ok(usage_over_ids(db, ids)),
  }
}

# ── Plan quotas ────────────────────────────────────────────────────────────────
fn plan_limit(plan :: Str) -> Int {
  if plan == "enterprise" {
    1000000
  } else {
    if plan == "pro" {
      10000
    } else {
      100
    }
  }
}

# All-time task count against the org's plan ceiling. A brand-new org (no
# account yet) is never over quota — callers should only invoke this once an
# account is known to exist. A usage-lookup failure counts as OVER quota: the
# gate fails closed, matching federation.rate_limited (M-1).
fn over_quota(db :: Db, org :: Str, plan :: Str) -> [sql, fs_read] Bool {
  match usage_for(db, org) {
    Err(_) => true,
    Ok(u) => u.tasks >= plan_limit(plan),
  }
}

fn usage_json(u :: Usage) -> jv.Json {
  JObj([("tasks", JInt(u.tasks)), ("escalations", JInt(u.escalations)), ("spend_total", JInt(u.spend_total)), ("spend_denied", JInt(u.spend_denied)), ("chargebacks", JObj([("count", JInt(u.chargeback_count)), ("total", JFloat(u.chargeback_total)), ("total_dec", JStr(u.chargeback_total_dec))]))])
}

# A plan's commercial terms — HOST-SUPPLIED data (the core knows the shape,
# never the prices): base subscription, included tasks, and the overage rate
# beyond them. An empty catalog keeps /usage exactly as before.
type PlanPrice = { plan :: Str, base_eur_month :: Float, included_tasks :: Int, overage_eur_task :: Float }

fn price_for(catalog :: List[PlanPrice], plan :: Str) -> Option[PlanPrice] {
  list.head(list.filter(catalog, fn (p :: PlanPrice) -> Bool {
    p.plan == plan
  }))
}

# Billing preview over the SAME counters the customer can audit. Honest about
# the MVP window: counters are all-time until accounts get a billing anchor.
fn billing_json(p :: PlanPrice, tasks :: Int) -> jv.Json {
  let over := if tasks > p.included_tasks {
    tasks - p.included_tasks
  } else {
    0
  }
  let overage_eur := int.to_float(over) * p.overage_eur_task
  JObj([("plan", JStr(p.plan)), ("base_eur_month", JFloat(p.base_eur_month)), ("included_tasks", JInt(p.included_tasks)), ("tasks_used", JInt(tasks)), ("overage_tasks", JInt(over)), ("overage_eur_task", JFloat(p.overage_eur_task)), ("overage_eur", JFloat(overage_eur)), ("estimated_eur_month", JFloat(p.base_eur_month + overage_eur)), ("period", JStr("all_time_mvp"))])
}

fn usage_response(db :: Db, secret :: Bytes, catalog :: List[PlanPrice], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject(db, secret, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"usage lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => match usage_for(db, subj.org) {
        Err(_) => resp.json_status(500, "{\"error\":\"usage lookup failed\"}"),
        Ok(u) => {
          let plan := match identity.get_account(db, subj.account) {
            Ok(Some(a)) => a.plan,
            _ => "free",
          }
          let base := [("org", JStr(subj.org)), ("account", JStr(subj.account)), ("plan", JStr(plan)), ("plan_limit_tasks", JInt(plan_limit(plan))), ("usage", usage_json(u))]
          let fields := match price_for(catalog, plan) {
            None => base,
            Some(p) => list.concat(base, [("billing_preview", billing_json(p, u.tasks))]),
          }
          resp.json(jv.stringify(JObj(fields)))
        },
      },
    },
  }
}

# Host opt-in: mount GET /usage. `secret` is the same federation secret
# credentials are issued under (identity.resolve_subject). `catalog` carries
# the host's commercial terms per plan — pass [] for counters-only.
fn mount(r :: router.Router, db :: Db, secret :: Bytes, catalog :: List[PlanPrice]) -> router.Router {
  router.route_effectful(r, "GET", "/usage", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    usage_response(db, secret, catalog, c)
  })
}

