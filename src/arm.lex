# src/arm.lex — Agent Relationship Management: counterparty profile + trust score.
#
# Humans manage partners with a CRM; agents need the same — a system of record
# for who I deal with, our history, can I trust them, what we've agreed. The
# platform already has every ingredient scattered across subsystems; this unifies
# them into ONE counterparty view + a trust score an agent queries BEFORE
# accepting a task or extending a budget.
#
#   GET /counterparties/:org -> { identity, relationships, interactions,
#                                 reputation, spend, trust_score, memory }
#
# The trust score is RE-DERIVED from the tamper-evident trail (#19/#20/#21), not
# self-reported: outcomes and spends are appended as hash-chained `arm.*` events,
# and the score is a pure, reproducible function of their tally. Domain-agnostic
# by construction — consumes only generic subsystems.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-trail/event" as ev

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./registry" as reg

import "./relationships" as rel

import "./trace" as trace

import "./settlement" as settlement

# ARM events are recorded into the same tamper-evident trail as everything else.
fn k_outcome() -> Str {
  "arm.outcome"
}

fn k_spend() -> Str {
  "arm.spend"
}

# The current trail head, used as each new event's parent — so the ARM ledger is
# a tamper-evident chain AND identical outcomes (same cp/verdict/ms) don't
# collapse to one content-addressed id.
fn head_parent(log :: tlog.Log) -> [sql] Option[Str] {
  match tlog.head(log) {
    Some(e) => Some(e.id),
    None => None,
  }
}

# Record a verified-or-not interaction outcome for a counterparty.
fn record_outcome(log :: tlog.Log, cp :: Str, verified :: Bool) -> [sql, time] Unit {
  let __r := tlog.append(log, k_outcome(), head_parent(log), jv.stringify(JObj([("cp", JStr(cp)), ("verified", JBool(verified))])))
  ()
}

# Record a spend outcome (approved/denied + amount) against a counterparty.
fn record_spend(log :: tlog.Log, cp :: Str, approved :: Bool, amount :: Int) -> [sql, time] Unit {
  let __r := tlog.append(log, k_spend(), head_parent(log), jv.stringify(JObj([("cp", JStr(cp)), ("approved", JBool(approved)), ("amount", JInt(amount))])))
  ()
}

# ---- json helpers ----
fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jbool(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# Counts re-derived from the trail for one counterparty.
type Tally = { interactions :: Int, verified :: Int, spends :: Int, denied_spends :: Int, total_spend :: Int }

fn fold_event(acc :: Tally, e :: ev.Event, cp :: Str) -> Tally {
  match jv.parse(e.payload_json) {
    Err(_) => acc,
    Ok(p) => if jstr(p, "cp") == cp {
      if e.kind == k_outcome() {
        { interactions: acc.interactions + 1, verified: acc.verified + if jbool(p, "verified") {
          1
        } else {
          0
        }, spends: acc.spends, denied_spends: acc.denied_spends, total_spend: acc.total_spend }
      } else {
        if e.kind == k_spend() {
          if jbool(p, "approved") {
            { interactions: acc.interactions, verified: acc.verified, spends: acc.spends + 1, denied_spends: acc.denied_spends, total_spend: acc.total_spend + jint(p, "amount") }
          } else {
            { interactions: acc.interactions, verified: acc.verified, spends: acc.spends, denied_spends: acc.denied_spends + 1, total_spend: acc.total_spend }
          }
        } else {
          acc
        }
      }
    } else {
      acc
    },
  }
}

# Tally a counterparty's ARM events from the trail (reproducible: same trail →
# same tally → same score).
fn tally(log :: tlog.Log, cp :: Str) -> [sql] Tally {
  let events := match tlog.range(log, 0, 99999999999999) {
    Ok(es) => es,
    Err(_) => [],
  }
  list.fold(events, { interactions: 0, verified: 0, spends: 0, denied_spends: 0, total_spend: 0 }, fn (acc :: Tally, e :: ev.Event) -> Tally {
    fold_event(acc, e, cp)
  })
}

fn clamp(n :: Int, lo :: Int, hi :: Int) -> Int {
  if n < lo {
    lo
  } else {
    if n > hi {
      hi
    } else {
      n
    }
  }
}

# Reproducible trust score 0-100, re-derived from the tally. A never-seen
# counterparty is neutral (50). Otherwise reputation is the % of verified
# outcomes, penalized for denied spends (attempted over-cap spend is a red flag).
fn trust_score(t :: Tally) -> Int {
  if t.interactions == 0 {
    50
  } else {
    clamp(100 * t.verified / t.interactions - t.denied_spends * 10, 0, 100)
  }
}

# The good-standing gate an agent calls before accepting a task / granting budget.
fn in_good_standing(t :: Tally, threshold :: Int) -> Bool {
  trust_score(t) >= threshold
}

# The joined counterparty profile — five sources in one response.
fn profile_json(db :: Db, log :: tlog.Log, cp :: Str) -> [sql, fs_read, time] Str {
  let identity := match reg.find_by_id(db, cp) {
    Ok(Some(a)) => JObj([("id", JStr(a.id)), ("kind", JStr(a.kind)), ("name", JStr(a.name)), ("status", JStr(a.status)), ("capabilities", JList(list.map(a.capabilities, fn (c :: Str) -> jv.Json {
      JStr(c)
    })))]),
    _ => JNull,
  }
  let rels := match rel.peers_of(db, cp) {
    Ok(rs) => JList(list.map(rs, fn (r :: rel.Relationship) -> jv.Json {
      JObj([("to", JStr(r.to_agent)), ("role", JStr(r.role)), ("contract", JStr(r.contract_json))])
    })),
    Err(_) => JList([]),
  }
  let t := tally(log, cp)
  let mem := match jv.parse(trace.recall_memory_json(db, cp, 20)) {
    Ok(j) => j,
    Err(_) => JNull,
  }
  jv.stringify(JObj([("org", JStr(cp)), ("identity", identity), ("relationships", rels), ("interactions", JInt(t.interactions)), ("reputation", JObj([("verified", JInt(t.verified)), ("interactions", JInt(t.interactions))])), ("spend", JObj([("approved", JInt(t.spends)), ("denied", JInt(t.denied_spends)), ("total", JInt(t.total_spend))])), ("trust_score", JInt(trust_score(t))), ("good_standing", JBool(in_good_standing(t, 60))), ("memory", mem)]))
}

# Mount GET /counterparties/:org — the agent-facing ARM query.
fn mount(r :: router.Router, db :: Db) -> router.Router {
  router.route_effectful(r, "GET", "/counterparties/:org", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let org := match ctx.path_param(c, "org") {
      Some(s) => s,
      None => "",
    }
    if str.is_empty(org) {
      resp.bad_request("{\"error\":\"org is required\"}")
    } else {
      resp.json(profile_json(db, settlement.trail_on(db), org))
    }
  })
}

