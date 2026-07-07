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

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/kinds" as kinds

import "./identity" as identity

import "./audit" as audit

type Usage = { tasks :: Int, escalations :: Int, spend_total :: Int, spend_denied :: Int }

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
    let q := str.join(["SELECT COUNT(*) AS n FROM events WHERE ", audit.agent_where(ids), " AND kind='", audit.sq(kind), "'"], "")
    let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, q, [])
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
fn spend_rows(db :: Db, ids :: List[Str]) -> [sql, fs_read] List[{ payload_json :: Str }] {
  if list.is_empty(ids) {
    []
  } else {
    let q := str.join(["SELECT payload_json FROM events WHERE ", audit.agent_where(ids), " AND kind='", audit.sq(spend_kind()), "'"], "")
    let rows :: Result[List[{ payload_json :: Str }], SqlError] := sql.query(db, q, [])
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

fn usage_for(db :: Db, org :: Str) -> [sql, fs_read] Usage {
  let ids := audit.org_agent_ids(db, org)
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
  { tasks: count_kind(db, ids, kinds.cap_completed()), escalations: count_kind(db, ids, escalation_requested_kind()), spend_total: approved_total, spend_denied: denied_count }
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
# account is known to exist.
fn over_quota(db :: Db, org :: Str, plan :: Str) -> [sql, fs_read] Bool {
  usage_for(db, org).tasks >= plan_limit(plan)
}

fn usage_json(u :: Usage) -> jv.Json {
  JObj([("tasks", JInt(u.tasks)), ("escalations", JInt(u.escalations)), ("spend_total", JInt(u.spend_total)), ("spend_denied", JInt(u.spend_denied))])
}

fn usage_response(db :: Db, secret :: Bytes, c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject(db, secret, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"usage lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => {
        let plan := match identity.get_account(db, subj.account) {
          Ok(Some(a)) => a.plan,
          _ => "free",
        }
        let u := usage_for(db, subj.org)
        resp.json(jv.stringify(JObj([("org", JStr(subj.org)), ("account", JStr(subj.account)), ("plan", JStr(plan)), ("plan_limit_tasks", JInt(plan_limit(plan))), ("usage", usage_json(u))])))
      },
    },
  }
}

# Host opt-in: mount GET /usage. `secret` is the same federation secret
# credentials are issued under (identity.resolve_subject).
fn mount(r :: router.Router, db :: Db, secret :: Bytes) -> router.Router {
  router.route_effectful(r, "GET", "/usage", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    usage_response(db, secret, c)
  })
}

