# dsr.lex — GDPR Art. 15 (access) & Art. 17 (erasure) over the platform's OWN PII.
#
# lex-soft holds two free-text stores that can contain personal data, because
# agent conversations and durable memory quote it: `traces.data_json` and
# `agent_memory.fact` (a driver's name in a dialogue turn, a "prefers depot X"
# fact). This exposes a data-subject request surface over exactly those, keyed by
# `agent_id` — the platform's handle for an edge agent bound to a person / device.
#
# The append-only settlement trail is deliberately NOT rewritten here: it is
# hash-chained and tamper-evident, so an erasure removes the MUTABLE stores and
# leaves the trail to age out via the GDPR-05 retention job (deploy/retention.sql).
# Every erasure appends a signed `dsr.erased` receipt to that trail, so the
# ERASURE ITSELF is provable — the receipt carries counts + the subject handle,
# never the erased free-text.
#
# Both routes are gated on a bearer token equal to DSR_KEY, fail-closed: with no
# key set the surface is disabled (403), never open. This is a DPO/admin surface,
# not a tenant-facing one — the caller is trusted to have verified the subject's
# identity out of band (the platform has no person-level identity of its own).

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-crypto/src/ed25519" as ed

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "./settlement" as settlement

type TraceRow = { id :: Str, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str, ts :: Str }

type MemRow = { id :: Str, fact :: Str, ts :: Str, mkey :: Str, mtype :: Str, importance :: Str, scope :: Str, expires_at :: Str }

# What an erasure removed, for the caller and the signed trail receipt.
type EraseCounts = { traces :: Int, memory :: Int }

fn trace_json(r :: TraceRow) -> jv.Json {
  JObj([("id", JStr(r.id)), ("run_id", JStr(r.run_id)), ("event_kind", JStr(r.event_kind)), ("data", JStr(r.data_json)), ("ts", JStr(r.ts))])
}

fn mem_json(r :: MemRow) -> jv.Json {
  JObj([("id", JStr(r.id)), ("fact", JStr(r.fact)), ("key", JStr(r.mkey)), ("type", JStr(r.mtype)), ("importance", JStr(r.importance)), ("scope", JStr(r.scope)), ("ts", JStr(r.ts)), ("expires_at", JStr(r.expires_at))])
}

fn subject_traces(db :: Db, agent_id :: Str) -> [sql, fs_read] List[TraceRow] {
  let q := "SELECT id, run_id, agent_id, event_kind, data_json, ts FROM traces WHERE agent_id=? ORDER BY ts"
  let rows :: Result[List[TraceRow], SqlError] := sql.query(db, q, [PStr(agent_id)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn subject_memory(db :: Db, agent_id :: Str) -> [sql, fs_read] List[MemRow] {
  let q := "SELECT id, fact, ts, mkey, mtype, importance, scope, expires_at FROM agent_memory WHERE agent_id=? ORDER BY ts"
  let rows :: Result[List[MemRow], SqlError] := sql.query(db, q, [PStr(agent_id)])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

# The Art. 15 access payload for one subject: everything the platform's mutable
# stores hold under `agent_id`, as a single JSON document.
fn export_subject(db :: Db, agent_id :: Str) -> [sql, fs_read, time] jv.Json {
  let traces := subject_traces(db, agent_id)
  let memory := subject_memory(db, agent_id)
  JObj([("subject", JStr(agent_id)), ("exported_at_ms", JInt(time.now_ms())), ("trace_count", JInt(list.len(traces))), ("memory_count", JInt(list.len(memory))), ("traces", JList(list.map(traces, trace_json))), ("memory", JList(list.map(memory, mem_json)))])
}

fn head_parent(log :: tlog.Log) -> [sql] Option[Str] {
  match tlog.head(log) {
    Some(e) => Some(e.id),
    None => None,
  }
}

fn count_rows(db :: Db, q :: Str, agent_id :: Str) -> [sql, fs_read] Int {
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, q, [PStr(agent_id)])
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Art. 17 erasure over the mutable stores. Counts are read BEFORE the deletes so
# the receipt reports what was removed. Appends a signed `dsr.erased` event to the
# settlement trail (counts + subject handle only — no erased free-text) so the
# erasure is itself an auditable, tamper-evident fact.
fn erase_subject(db :: Db, agent_id :: Str) -> [sql, fs_read, fs_write, time] EraseCounts {
  let n_tr := count_rows(db, "SELECT COUNT(*) AS n FROM traces WHERE agent_id=?", agent_id)
  let n_mem := count_rows(db, "SELECT COUNT(*) AS n FROM agent_memory WHERE agent_id=?", agent_id)
  let __dt := sql.exec(db, "DELETE FROM traces WHERE agent_id=?", [PStr(agent_id)])
  let __dm := sql.exec(db, "DELETE FROM agent_memory WHERE agent_id=?", [PStr(agent_id)])
  let log := settlement.trail_on(db)
  let payload := jv.stringify(JObj([("subject", JStr(agent_id)), ("traces_deleted", JInt(n_tr)), ("memory_deleted", JInt(n_mem)), ("erased_at_ms", JInt(time.now_ms()))]))
  let __t := tlog.append(log, "dsr.erased", head_parent(log), payload)
  { traces: n_tr, memory: n_mem }
}

# ── HTTP surface (DPO/admin-only; DSR_KEY bearer, fail-closed) ────────────────
fn authed(dsr_key :: Str, c :: ctx.Ctx) -> Bool {
  if str.is_empty(dsr_key) {
    false
  } else {
    match ctx.bearer_token(c) {
      None => false,
      Some(tok) => tok == dsr_key,
    }
  }
}

fn subject_of(c :: ctx.Ctx) -> Str {
  match jv.parse(c.body) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "subject") {
      Some(JStr(s)) => s,
      _ => "",
    },
  }
}

# Sign a body the notification/audit way: ed25519 over its sha256 hex, returned
# with the digest and public key so any third party can verify the artifact.
fn signed_envelope(body :: Str, sign_seed :: Bytes, pub_b64 :: Str) -> resp.Response {
  let digest := crypto.hex_encode(crypto.sha256(bytes.from_str(body)))
  let sig := match ed.sign_text(sign_seed, digest) {
    Ok(s) => s,
    Err(_) => "",
  }
  if str.is_empty(sig) {
    resp.json_status(500, "{\"error\":\"dsr signing failed\"}")
  } else {
    resp.json(jv.stringify(JObj([("archive", JStr(body)), ("sha256", JStr(digest)), ("alg", JStr("ed25519")), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))])))
  }
}

fn export_response(db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str, c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  if not authed(dsr_key, c) {
    if str.is_empty(dsr_key) {
      resp.forbidden("{\"error\":\"dsr endpoint disabled (DSR_KEY unset)\"}")
    } else {
      resp.unauthorized("{\"error\":\"missing or invalid bearer token\"}")
    }
  } else {
    let subject := subject_of(c)
    if str.is_empty(subject) {
      resp.bad_request("{\"error\":\"subject is required\"}")
    } else {
      signed_envelope(jv.stringify(export_subject(db, subject)), sign_seed, pub_b64)
    }
  }
}

fn erase_response(db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str, c :: ctx.Ctx) -> [sql, fs_read, fs_write, time] resp.Response {
  if not authed(dsr_key, c) {
    if str.is_empty(dsr_key) {
      resp.forbidden("{\"error\":\"dsr endpoint disabled (DSR_KEY unset)\"}")
    } else {
      resp.unauthorized("{\"error\":\"missing or invalid bearer token\"}")
    }
  } else {
    let subject := subject_of(c)
    if str.is_empty(subject) {
      resp.bad_request("{\"error\":\"subject is required\"}")
    } else {
      let counts := erase_subject(db, subject)
      let body := jv.stringify(JObj([("subject", JStr(subject)), ("traces_deleted", JInt(counts.traces)), ("memory_deleted", JInt(counts.memory)), ("erased_at_ms", JInt(time.now_ms())), ("note", JStr("mutable stores erased; the tamper-evident trail is excluded and ages out via retention"))]))
      signed_envelope(body, sign_seed, pub_b64)
    }
  }
}

# Host opt-in. `dsr_key` gates access (empty ⇒ disabled); `sign_seed`/`pub_b64`
# are the deployment ed25519 identity (same pair the audit export + human gateway
# sign with) so exports and erasure receipts are independently verifiable.
fn mount(r :: router.Router, db :: Db, dsr_key :: Str, sign_seed :: Bytes, pub_b64 :: Str) -> router.Router {
  let r_ex := router.route_effectful(r, "POST", "/dsr/export", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    export_response(db, dsr_key, sign_seed, pub_b64, c)
  })
  router.route_effectful(r_ex, "POST", "/dsr/erase", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    erase_response(db, dsr_key, sign_seed, pub_b64, c)
  })
}

