# notifications.lex — per-account notification bus (#64).
#
# Generalises the Phase 5 human-gateway (a person as an A2A agent, for
# approvals only) into an account-scoped notification bus: platform events
# (quota breaches, escalations, verify failures, trust drops) are ENQUEUED by
# serve handlers (sql only) and DELIVERED by a sidecar to the account's
# configured channels — exactly the split scheduler.lex uses, because an
# in-process serve handler can't make outbound HTTP.
#
#   enqueue(account, event_type, payload)   — serve-safe; records a pending row
#   deliver_pending(db, sign_seed, pub_b64) — SIDECAR: outbound http, signs the
#                                             webhook payload with the
#                                             deployment ed25519 key, records a
#                                             notification.delivered trail event
#   GET|POST /channels    — the caller's account configures/lists its channels
#   GET /notifications     — the caller's account's delivery history
#
# Webhook payloads are Ed25519-signed with the same deployment seed the human-
# gateway signs decisions with, and carry the public key, so a receiver can
# verify authenticity against /.well-known/agent-key.json — notifications are
# provable, not merely POSTed.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "std.map" as map

import "std.bytes" as bytes

import "std.http" as http

import "lex-crypto/src/ed25519" as ed

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "./identity" as identity

import "./settlement" as settlement

type Channel = { id :: Str, account :: Str, ctype :: Str, target :: Str, active :: Int }

type Notification = { id :: Str, account :: Str, event_type :: Str, payload_json :: Str, status :: Str, attempts :: Int, response_code :: Int, created_at :: Str, delivered_at :: Str }

# ── Channel config (serve-safe: sql only) ────────────────────────────────────
fn chan_cols() -> Str {
  "id, account, ctype, target, active"
}

fn configure_channel(db :: Db, account :: Str, ctype :: Str, target :: Str) -> [sql, fs_write, time, random] Result[Channel, Str] {
  let id := str.concat("ch_", crypto.random_str_hex(10))
  let now := time.now_str()
  let q := "INSERT INTO notify_channels (id, account, ctype, target, active, created_at) VALUES (?, ?, ?, ?, 1, ?)"
  match sql.exec(db, q, [PStr(id), PStr(account), PStr(ctype), PStr(target), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok({ id: id, account: account, ctype: ctype, target: target, active: 1 }),
  }
}

fn list_channels(db :: Db, account :: Str) -> [sql, fs_read] List[Channel] {
  let q := str.join(["SELECT ", chan_cols(), " FROM notify_channels WHERE account=? ORDER BY created_at"], "")
  let rows :: Result[List[Channel], SqlError] := sql.query(db, q, [PStr(account)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn active_channels(db :: Db, account :: Str) -> [sql, fs_read] List[Channel] {
  let q := str.join(["SELECT ", chan_cols(), " FROM notify_channels WHERE account=? AND active=1"], "")
  let rows :: Result[List[Channel], SqlError] := sql.query(db, q, [PStr(account)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# ── Enqueue (serve-safe: sql only — NO outbound) ─────────────────────────────
# Records a pending notification. Returns its id, or "" if the write failed —
# a notification failure must never break the operation that triggered it.
fn enqueue(db :: Db, account :: Str, event_type :: Str, payload_json :: Str) -> [sql, fs_write, time, random] Str {
  let id := str.concat("nt_", crypto.random_str_hex(12))
  let now := time.now_str()
  let q := "INSERT INTO notifications (id, account, event_type, payload_json, status, attempts, response_code, created_at) VALUES (?, ?, ?, ?, 'pending', 0, 0, ?)"
  match sql.exec(db, q, [PStr(id), PStr(account), PStr(event_type), PStr(payload_json), PStr(now)]) {
    Err(_) => "",
    Ok(_) => id,
  }
}

fn list_notifications(db :: Db, account :: Str) -> [sql, fs_read] List[Notification] {
  let q := "SELECT id, account, event_type, payload_json, status, attempts, response_code, created_at, delivered_at FROM notifications WHERE account=? ORDER BY created_at DESC LIMIT 200"
  let rows :: Result[List[Notification], SqlError] := sql.query(db, q, [PStr(account)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn pending(db :: Db) -> [sql, fs_read] List[Notification] {
  let q := "SELECT id, account, event_type, payload_json, status, attempts, response_code, created_at, delivered_at FROM notifications WHERE status='pending' ORDER BY created_at LIMIT 100"
  let rows :: Result[List[Notification], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# ── Delivery (SIDECAR ONLY: outbound http) ───────────────────────────────────
fn canonical(id :: Str, account :: Str, event_type :: Str, payload_json :: Str) -> Str {
  str.join([id, "|", account, "|", event_type, "|", payload_json], "")
}

# The signed body POSTed to a webhook target. Ed25519 over canonical(...) with
# the deployment seed; the receiver verifies against `public_key`.
fn signed_body(n :: Notification, sign_seed :: Bytes, pub_b64 :: Str) -> Str {
  let sig := match ed.sign_text(sign_seed, canonical(n.id, n.account, n.event_type, n.payload_json)) {
    Ok(s) => s,
    Err(_) => "",
  }
  let payload := match jv.parse(n.payload_json) {
    Ok(j) => j,
    Err(_) => JStr(n.payload_json),
  }
  jv.stringify(JObj([("id", JStr(n.id)), ("account", JStr(n.account)), ("event_type", JStr(n.event_type)), ("payload", payload), ("alg", JStr("ed25519")), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))]))
}

fn post_webhook(url :: Str, body :: Str) -> [net, io] Int {
  let base := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(15000) }
  let req := http.with_header(base, "Content-Type", "application/json")
  match http.send(req) {
    Err(_) => 0,
    Ok(r) => r.status,
  }
}

fn mark(db :: Db, id :: Str, status :: Str, code :: Int, now :: Str) -> [sql, fs_write] Unit {
  let q := "UPDATE notifications SET status=?, attempts=attempts+1, response_code=?, delivered_at=? WHERE id=?"
  let __r := sql.exec(db, q, [PStr(status), PInt(code), PStr(now), PStr(id)])
  ()
}

# Deliver one notification to all of its account's active webhook channels; a
# channel with no webhook (email/slack) is recorded but not POSTed here (those
# transports are follow-ups). Returns true if at least one delivery succeeded
# OR there were no channels (nothing to do — don't retry forever).
fn deliver_one(db :: Db, n :: Notification, sign_seed :: Bytes, pub_b64 :: Str) -> [net, io, sql, fs_read, fs_write, time] Bool {
  let chans := active_channels(db, n.account)
  let body := signed_body(n, sign_seed, pub_b64)
  let best := list.fold(chans, 0, fn (acc :: Int, ch :: Channel) -> [net, io] Int {
    if ch.ctype == "webhook" {
      let code := post_webhook(ch.target, body)
      if code >= 200 and code < 400 {
        200
      } else {
        acc
      }
    } else {
      acc
    }
  })
  let now := time.now_str()
  if list.is_empty(chans) {
    let __m := mark(db, n.id, "no_channel", 0, now)
    let __t := record_delivery(db, n, "no_channel")
    true
  } else {
    if best == 200 {
      let __m := mark(db, n.id, "delivered", 200, now)
      let __t := record_delivery(db, n, "delivered")
      true
    } else {
      let __m := mark(db, n.id, "failed", 1, now)
      let __t := record_delivery(db, n, "failed")
      false
    }
  }
}

# Notifications are themselves auditable: each delivery attempt appends a
# tamper-evident event to the settlement trail.
fn record_delivery(db :: Db, n :: Notification, status :: Str) -> [sql, time] Unit {
  let log := settlement.trail_on(db)
  let payload := jv.stringify(JObj([("account", JStr(n.account)), ("event_type", JStr(n.event_type)), ("notification_id", JStr(n.id)), ("status", JStr(status))]))
  let __e := tlog.append(log, "notification.delivered", head_parent(log), payload)
  ()
}

fn head_parent(log :: tlog.Log) -> [sql] Option[Str] {
  match tlog.head(log) {
    Some(e) => Some(e.id),
    None => None,
  }
}

# One pass over the outbox. SIDECAR ONLY — does outbound HTTP. Returns count.
fn deliver_pending(db :: Db, sign_seed :: Bytes, pub_b64 :: Str) -> [net, io, sql, fs_read, fs_write, time] Int {
  list.fold(pending(db), 0, fn (acc :: Int, n :: Notification) -> [net, io, sql, fs_read, fs_write, time] Int {
    let __d := deliver_one(db, n, sign_seed, pub_b64)
    acc + 1
  })
}

fn run_loop(db :: Db, sign_seed :: Bytes, pub_b64 :: Str, sleep_ms :: Int) -> [net, io, sql, fs_read, fs_write, time, concurrent] Unit {
  let __n := deliver_pending(db, sign_seed, pub_b64)
  let __z := time.sleep_ms(sleep_ms)
  run_loop(db, sign_seed, pub_b64, sleep_ms)
}

# ── HTTP surface (tenant-scoped by credential; sql only) ─────────────────────
fn chan_json(ch :: Channel) -> jv.Json {
  JObj([("id", JStr(ch.id)), ("ctype", JStr(ch.ctype)), ("target", JStr(ch.target)), ("active", JBool(ch.active == 1))])
}

fn notif_json(n :: Notification) -> jv.Json {
  JObj([("id", JStr(n.id)), ("event_type", JStr(n.event_type)), ("status", JStr(n.status)), ("attempts", JInt(n.attempts)), ("response_code", JInt(n.response_code)), ("created_at", JStr(n.created_at)), ("delivered_at", JStr(n.delivered_at))])
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn subject_of(db :: Db, secret :: Bytes, c :: ctx.Ctx) -> [sql, fs_read, time] Option[identity.Subject] {
  match ctx.bearer_token(c) {
    None => None,
    Some(tok) => match identity.resolve_subject(db, secret, tok) {
      Ok(some) => some,
      Err(_) => None,
    },
  }
}

fn mount(r :: router.Router, db :: Db, secret :: Bytes) -> router.Router {
  let with_list := router.route_effectful(r, "GET", "/channels", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match subject_of(db, secret, c) {
      None => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Some(subj) => resp.json(jv.stringify(JObj([("account", JStr(subj.account)), ("channels", JList(list.map(list_channels(db, subj.account), fn (ch :: Channel) -> jv.Json {
        chan_json(ch)
      })))]))),
    }
  })
  let with_post := router.route_effectful(with_list, "POST", "/channels", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match subject_of(db, secret, c) {
      None => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Some(subj) => match jv.parse(c.body) {
        Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
        Ok(j) => {
          let ctype := if str.is_empty(jstr(j, "ctype")) {
            "webhook"
          } else {
            jstr(j, "ctype")
          }
          let target := jstr(j, "target")
          if str.is_empty(target) {
            resp.bad_request("{\"error\":\"target is required\"}")
          } else {
            match configure_channel(db, subj.account, ctype, target) {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(ch) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("channel", chan_json(ch))]))),
            }
          }
        },
      },
    }
  })
  router.route_effectful(with_post, "GET", "/notifications", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match subject_of(db, secret, c) {
      None => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Some(subj) => resp.json(jv.stringify(JObj([("account", JStr(subj.account)), ("notifications", JList(list.map(list_notifications(db, subj.account), fn (n :: Notification) -> jv.Json {
        notif_json(n)
      })))]))),
    }
  })
}

