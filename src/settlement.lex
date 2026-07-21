# src/settlement.lex — the trail as the unit of settlement (#19).
#
# An A2A `tasks/send` returns natural-language text — no verifiable artifact of
# WHAT the agent did, so you can't settle a payment or SLA against a proven
# outcome. This records every task run as a hash-chained `lex-trail` and exposes
# its content-addressed id, so a requester can replay + verify it (#20) and pay
# against it (#21).
#
# A run records a parent-linked chain: received → llm_step → completed. The
# `trail_id` is the TIP event's content hash (sha256 over kind|parent|payload|ts,
# from lex-trail/event). Fetching walks the chain up from the tip; re-hashing
# every event (export.all_valid) reproduces the ids, so any mutation is detected.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-money/src/decimal" as mdec

import "lex-money/src/money" as money

import "lex-money/src/currency" as mcur

import "lex-money/src/rounding" as mround

import "lex-trail/replay" as replay

import "lex-trail/export" as txport

import "lex-trail/kinds" as kinds

import "lex-orm/connection" as conn

# Which dialect an open handle actually speaks, probed rather than assumed.
#
# `sqlite_master` is the SQLite catalog table: it exists on every SQLite
# database (empty ones included, where the query returns zero rows — still Ok)
# and on no Postgres one. So Ok means SQLite and Err means "not SQLite", which
# for the two dialects lex-orm models is Postgres.
#
# The probe is a catalog read on a table SQLite always has resident, and it
# runs once per trail_on — the same place the previous hardcoded tag was
# produced. It stays inside the `sql` effect, so no caller signature changes.
fn detect_dialect(db :: Db) -> [sql] conn.Dialect {
  let probe :: Result[List[{ present :: Int }], SqlError] := sql.query(db, "SELECT 1 AS present FROM sqlite_master LIMIT 1", [])
  match probe {
    Ok(_) => DbSqlite(()),
    Err(_) => DbPostgres(()),
  }
}

# Wrap an existing db as a trail log (idempotent schema init).
#
# DIALECT (#62, L-3): lex-soft opens its own database and passes a bare `Db`,
# so it cannot know from the type whether that handle is SQLite or Postgres.
# It used to tag every trail SQLite. That tag was benign — std.sql accepts both
# `?` and `$n` (the driver normalizes), and the trail's DDL and ON CONFLICT are
# portable — but it was an assumption a node on a postgres:// DB_PATH silently
# depended on, and it would become load-bearing the moment lex-trail grows any
# dialect-SENSITIVE SQL. It is now probed instead of assumed.
#
# A host that already knows its dialect can still bypass the probe by calling
# trail_on_dialect directly.
fn trail_on(db :: Db) -> [sql] tlog.Log {
  trail_on_dialect(db, detect_dialect(db))
}

# Same, for a host that knows its database is Postgres.
fn trail_on_dialect(db :: Db, dialect :: conn.Dialect) -> [sql] tlog.Log {
  match tlog.attach(db, dialect) {
    Ok(l) => l,
    Err(_) => { db: { dialect: dialect, handle: db } },
  }
}

# Record a run's hash-chained trail; returns the content-addressed trail_id
# (the tip event's id), or "" if the trail could not be written.
# L1 internal market (trust ladder): a metered exchange between two agents of
# the SAME account, settled by accounting rather than payment. One trail
# event per charge; `ref` must be unique per charge (an invoice line, a CDR
# id) — identical payloads content-hash-dedup to one event.
fn record_chargeback(log :: tlog.Log, from_agent :: Str, to_agent :: Str, amount :: Float, currency :: Str, ref :: Str) -> [sql, time] Result[Str, Str] {
  let payload := jv.stringify(JObj([("agent", JStr(from_agent)), ("from_agent", JStr(from_agent)), ("to_agent", JStr(to_agent)), ("amount", JFloat(amount)), ("currency", JStr(currency)), ("ref", JStr(ref))]))
  match tlog.append_actor(log, "settlement.chargeback", from_agent, None, payload) {
    Err(e) => Err(e),
    Ok(ev) => Ok(ev.id),
  }
}

# Exact-decimal chargeback (lex-soft#57): the amount arrives as a STRING,
# is validated and canonicalized to the currency's minor units via lex-money
# (HalfUp), and the payload carries BOTH amount_dec (the canonical string —
# authoritative) and amount (a float derived once, for legacy consumers).
# A malformed amount is an Err, never a silent 0.
fn record_chargeback_dec(log :: tlog.Log, from_agent :: Str, to_agent :: Str, amount_str :: Str, currency_code :: Str, ref :: Str) -> [sql, time] Result[Str, Str] {
  let cur := match mcur.from_code(currency_code) {
    Some(c) => c,
    None => mcur.Unknown(currency_code),
  }
  match money.parse(amount_str, cur, mround.HalfUp(())) {
    None => Err(str.concat("invalid decimal amount: ", amount_str)),
    Some(m) => {
      let canonical := money.format(m)
      let approx := int.to_float(m.amount) / int.to_float(mdec.pow10(0 - m.exponent))
      let payload := jv.stringify(JObj([("agent", JStr(from_agent)), ("from_agent", JStr(from_agent)), ("to_agent", JStr(to_agent)), ("amount_dec", JStr(canonical)), ("amount", JFloat(approx)), ("currency", JStr(currency_code)), ("ref", JStr(ref))]))
      match tlog.append_actor(log, "settlement.chargeback", from_agent, None, payload) {
        Err(e) => Err(e),
        Ok(ev) => Ok(ev.id),
      }
    },
  }
}

fn record_run(log :: tlog.Log, agent :: Str, skill :: Str, input :: Str, answer :: Str, tools :: List[Str]) -> [sql, time] Str {
  let recv := jv.stringify(JObj([("agent", JStr(agent)), ("skill", JStr(skill)), ("input", JStr(input))]))
  match tlog.append_actor(log, kinds.a2a_task_received(), agent, None, recv) {
    Err(_) => "",
    Ok(e1) => {
      let step := jv.stringify(JObj([("agent", JStr(agent)), ("tool_calls", JList(list.map(tools, fn (t :: Str) -> jv.Json {
        JStr(t)
      })))]))
      match tlog.append_actor(log, kinds.llm_step(), agent, Some(e1.id), step) {
        Err(_) => "",
        Ok(e2) => {
          let done := jv.stringify(JObj([("agent", JStr(agent)), ("skill", JStr(skill)), ("result", JStr(answer))]))
          match tlog.append_actor(log, kinds.cap_completed(), agent, Some(e2.id), done) {
            Err(_) => "",
            Ok(e3) => e3.id,
          }
        },
      }
    },
  }
}

# Verify a trail: walk the chain from its tip id and re-hash every event.
# Empty (unknown id) or any tampered event → false.
fn verify(log :: tlog.Log, trail_id :: Str) -> [sql] Bool {
  let evts := replay.walk_chain(log, trail_id)
  if list.is_empty(evts) {
    false
  } else {
    txport.all_valid(evts)
  }
}

# A fetch report: the trail's id, validity, and its events.
fn report_json(log :: tlog.Log, trail_id :: Str) -> [sql] Str {
  let evts := replay.walk_chain(log, trail_id)
  let events := match jv.parse(txport.events_json(evts)) {
    Ok(j) => j,
    Err(_) => JList([]),
  }
  jv.stringify(JObj([("trail_id", JStr(trail_id)), ("valid", JBool(txport.all_valid(evts))), ("events", events)]))
}

