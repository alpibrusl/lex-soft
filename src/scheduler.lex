# scheduler.lex — autonomy via platform-sent ticks (#50/#53).
#
# Agents never self-trigger: the invariant is that every agent turn is an
# inbound A2A `tasks/send`. Autonomy is therefore a SCHEDULER that periodically
# sends each subscribed agent a tick task ("periodic self-check — anything need
# doing?"). The agent cannot tell a timer from a peer, which is exactly what
# keeps the model agnostic: a non-lex agent gains autonomy by subscribing its
# inbox_url, or by running its own cron — the platform only ever sees
# tasks/send either way.
#
# Delivery does outbound HTTP, which in-process serve handlers cannot do — so
# `run_loop`/`tick_once` MUST run in a SIDECAR process (its own `lex run`,
# same pattern as llm_call.lex), sharing the platform DB. The subscription CRUD
# routes (`mount`) are DB-only and safe on the serve router.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "std.map" as map

import "std.bytes" as bytes

import "std.http" as http

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./registry" as reg

type Schedule = { id :: Str, agent_id :: Str, inbox_url :: Str, prompt :: Str, interval_seconds :: Int, next_at :: Int, active :: Int }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn cols() -> Str {
  "id, agent_id, inbox_url, prompt, interval_seconds, next_at, active"
}

# BIGINT for every Int-read column (int4 panics in the Postgres driver).
fn init(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS agent_schedules (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, inbox_url TEXT NOT NULL, prompt TEXT NOT NULL, interval_seconds BIGINT NOT NULL, next_at BIGINT NOT NULL, active BIGINT NOT NULL DEFAULT 1)", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn now_s() -> [time] Int {
  time.now_ms() / 1000
}

# Subscribe an agent to periodic ticks. Empty inbox_url falls back to the
# registry's — the common case for locally-mounted personas.
fn subscribe(db :: Db, agent_id :: Str, inbox_url :: Str, prompt :: Str, interval_seconds :: Int) -> [sql, fs_read, fs_write, random, time] Result[Str, Str] {
  let url := if str.is_empty(inbox_url) {
    match reg.find_by_id(db, agent_id) {
      Ok(Some(a)) => a.inbox_url,
      _ => "",
    }
  } else {
    inbox_url
  }
  if str.is_empty(url) {
    Err(str.concat("no inbox_url for agent: ", agent_id))
  } else {
    let id := crypto.random_str_hex(16)
    let next := now_s() + interval_seconds
    let q := str.join(["INSERT INTO agent_schedules (id, agent_id, inbox_url, prompt, interval_seconds, next_at, active) VALUES ('", id, "', '", sq(agent_id), "', '", sq(url), "', '", sq(prompt), "', ", int.to_str(interval_seconds), ", ", int.to_str(next), ", 1)"], "")
    match sql.exec(db, q, []) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(id),
    }
  }
}

fn list_all(db :: Db) -> [sql, fs_read] List[Schedule] {
  let q := str.join(["SELECT ", cols(), " FROM agent_schedules ORDER BY agent_id"], "")
  let rows :: Result[List[Schedule], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn due(db :: Db, now :: Int) -> [sql, fs_read] List[Schedule] {
  let q := str.join(["SELECT ", cols(), " FROM agent_schedules WHERE active=1 AND next_at <= ", int.to_str(now), " ORDER BY next_at"], "")
  let rows :: Result[List[Schedule], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# Re-arm after a tick, whether or not delivery succeeded — a dead agent just
# gets its next tick at the next interval instead of a tight retry storm.
fn mark_ran(db :: Db, id :: Str, now :: Int) -> [sql, fs_write] Result[Unit, Str] {
  let q := str.join(["UPDATE agent_schedules SET next_at = ", int.to_str(now), " + interval_seconds WHERE id='", sq(id), "'"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# The tick is an ordinary A2A tasks/send — indistinguishable from a peer's.
fn tick_body(s :: Schedule) -> Str {
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", JStr("1")), ("method", JStr("tasks/send")), ("params", JObj([("id", JStr(str.concat("tick-", s.id))), ("contextId", JStr(str.concat("ctx-tick-", s.agent_id))), ("skill", JStr("handle")), ("message", JObj([("role", JStr("user")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr(s.prompt))])]))]))]))]))
}

fn deliver(s :: Schedule) -> [net, io] Bool {
  let base := { method: "POST", url: s.inbox_url, headers: map.new(), body: Some(bytes.from_str(tick_body(s))), timeout_ms: Some(120000) }
  let req := http.with_header(base, "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => false,
    Ok(r) => r.status < 400,
  }
}

# One pass: deliver every due tick, re-arm each. Returns how many were sent.
# SIDECAR ONLY — does outbound HTTP.
fn tick_once(db :: Db) -> [net, io, sql, fs_read, fs_write, time] Int {
  let now := now_s()
  list.fold(due(db, now), 0, fn (acc :: Int, s :: Schedule) -> [net, io, sql, fs_read, fs_write, time] Int {
    let __sent := deliver(s)
    let __rearm := mark_ran(db, s.id, now)
    acc + 1
  })
}

# Blocking loop for the sidecar process.
fn run_loop(db :: Db, sleep_ms :: Int) -> [net, io, sql, fs_read, fs_write, time, concurrent] Unit {
  let __n := tick_once(db)
  let __z := time.sleep_ms(sleep_ms)
  run_loop(db, sleep_ms)
}

fn schedule_json(s :: Schedule) -> jv.Json {
  JObj([("id", JStr(s.id)), ("agent_id", JStr(s.agent_id)), ("inbox_url", JStr(s.inbox_url)), ("prompt", JStr(s.prompt)), ("interval_seconds", JInt(s.interval_seconds)), ("next_at", JInt(s.next_at)), ("active", JBool(s.active == 1))])
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Subscription CRUD (DB-only; safe on the serve router) ────────────────────
# POST /schedules {agent_id, inbox_url?, prompt?, interval_seconds}
# GET  /schedules
fn mount(r :: router.Router, db :: Db) -> router.Router {
  let with_post := router.route_effectful(r, "POST", "/schedules", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let agent_id := jstr(j, "agent_id")
        let interval := match jv.get_field(j, "interval_seconds") {
          Some(JInt(n)) => n,
          _ => 0,
        }
        if str.is_empty(agent_id) {
          resp.bad_request("{\"error\":\"agent_id is required\"}")
        } else {
          if interval < 1 {
            resp.bad_request("{\"error\":\"interval_seconds must be >= 1\"}")
          } else {
            let prompt := if str.is_empty(jstr(j, "prompt")) {
              "Periodic self-check: review your telemetry, pending work and peers. Take any action that is clearly needed; escalate to a human only at a real boundary. If nothing needs doing, reply briefly that all is nominal."
            } else {
              jstr(j, "prompt")
            }
            match subscribe(db, agent_id, jstr(j, "inbox_url"), prompt, interval) {
              Err(e) => resp.json(str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(id) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("schedule_id", JStr(id))]))),
            }
          }
        }
      },
    }
  })
  router.route_effectful(with_post, "GET", "/schedules", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(jv.stringify(JObj([("schedules", JList(list.map(list_all(db), fn (s :: Schedule) -> jv.Json {
      schedule_json(s)
    })))])))
  })
}

