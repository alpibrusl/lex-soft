# trace.lex — append-only audit log.
#
# event_kind values (LLM turn):    received, llm_start, llm_done, sent, error
# event_kind values (platform):    agent_registered, heartbeat, msg_delivered,
#                                   msg_pulled, state_saved

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-memory/src/memory" as mem

import "./settlement" as settlement

fn new_run_id() -> [random, crypto] Str {
  crypto.random_str_hex(16)
}

fn record(db :: Db, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  let id := new_run_id()
  let now := time.now_str()
  let q := "INSERT INTO traces (id, run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, ?, ?, ?, ?)"
  let __lex_discard_1 := sql.exec(db, q, [PStr(id), PStr(run_id), PStr(agent_id), PStr(event_kind), PStr(data_json), PStr(now)])
  ()
}

# Convenience wrapper for platform-layer events (no caller-supplied run_id).
fn record_platform(db :: Db, agent_id :: Str, event_kind :: Str, detail :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  record(db, str.concat("platform-", new_run_id()), agent_id, event_kind, detail)
}

# Recent conversation lines for one agent (received → "User:", llm_done →
# "Agent:"), oldest-first, for feeding prior-interaction context back into the
# next prompt. Single-column query (safe under the sqlite multi-col bug).
fn recent_exchanges(db :: Db, agent_id :: Str, n :: Int) -> [sql] Str {
  let q := "SELECT line FROM (SELECT (CASE event_kind WHEN 'received' THEN 'User: ' ELSE 'Agent: ' END) || data_json AS line, ts FROM traces WHERE agent_id = ? AND event_kind IN ('received','llm_done') AND data_json <> '' AND data_json NOT LIKE '[%' ORDER BY ts DESC LIMIT ?) s ORDER BY ts ASC"
  match sql.query(db, q, [PStr(agent_id), PInt(n)]) {
    Err(_) => "",
    Ok(rows) => str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "line") {
        Some(s) => s,
        None => "",
      }
    }), "\n"),
  }
}

# Same recent exchanges as a JSON array string of {role:'user'|'agent', text},
# oldest-first — fed to the LLM as real prior conversation turns. Prior empty/
# error agent responses (start with '[') are filtered out.
fn recent_messages_json(db :: Db, agent_id :: Str, n :: Int) -> [sql] Str {
  recent_messages_json_for(db, agent_id, "", n)
}

# History scoped to ONE conversation (#46): when ctx is non-empty only that
# conversation's turns are replayed. An empty ctx keeps the old agent-global
# behavior — the transport supplied no contextId, so there is nothing better.
fn recent_messages_json_for(db :: Db, agent_id :: Str, ctx :: Str, n :: Int) -> [sql] Str {
  let ctx_clause := if str.is_empty(ctx) {
    ""
  } else {
    " AND run_id = ?"
  }
  let ctx_params := if str.is_empty(ctx) {
    []
  } else {
    [PStr(ctx)]
  }
  let q := str.join(["SELECT j FROM (SELECT json_object('role', CASE event_kind WHEN 'received' THEN 'user' ELSE 'agent' END, 'text', substr(data_json, 1, 800)) AS j, ts FROM traces WHERE agent_id = ?", ctx_clause, " AND event_kind IN ('received','llm_done') AND data_json <> '' AND data_json NOT LIKE '[%' ORDER BY ts DESC LIMIT ?) s ORDER BY ts ASC"], "")
  let params := list.concat(list.concat([PStr(agent_id)], ctx_params), [PInt(n)])
  match sql.query(db, q, params) {
    Err(_) => "[]",
    Ok(rows) => str.concat("[", str.concat(str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "j") {
        Some(s) => s,
        None => "",
      }
    }), ","), "]")),
  }
}

# ---- Durable memory --------------------------------------------------
# Delegates to lex-memory/src/memory (alpibrusl/lex-memory#1 — extracted out
# of lex-agent once a second unrelated consumer needed it) — the shared,
# cross-repo memory primitive lex-loom already consumes directly, extended to
# cover what this module needed (importance/scope/expiry/supersession). `kind`
# is fixed to one constant for every write through this module: soft's domain
# model has no separate category-tag dimension the way lex-agent's `kind`
# does, so a single value here makes lex-agent's `(agent_id, kind, ...)`
# keying reduce to exactly this module's original `(agent_id, ...)` keying —
# schema-compatible, not just behavior-compatible.
fn mem_kind() -> Str {
  "fact"
}

fn conndb(db :: Db) -> [sql] conn.ConnDb {
  { dialect: settlement.detect_dialect(db), handle: db }
}

# Store a keyless fact for an agent (deduped: same fact for the same agent is a
# no-op). Back-compat entry point; stored as semantic/medium/global.
fn remember_fact(db :: Db, agent_id :: Str, fact :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  if str.is_empty(str.trim(fact)) {
    ()
  } else {
    mem.store_kv(conndb(db), agent_id, mem_kind(), "", fact, "semantic", "medium", "global", "")
  }
}

# Store a typed/keyed fact with temporal supersession (the 2026 memory model).
# - keyless (mkey == ""): falls back to deduped append (semantic/medium).
# - keyed: if the current value for (agent_id, scope, mkey) already equals the
#   new fact -> NOOP; otherwise mark the prior value superseded (kept for history
#   / "what was true when") and insert the new one. So evolving facts REPLACE
#   rather than accumulate contradictions.
fn remember_kv(db :: Db, agent_id :: Str, scope0 :: Str, mkey :: Str, fact :: Str, mtype0 :: Str, importance0 :: Str, expires_at :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  if str.is_empty(str.trim(fact)) {
    ()
  } else {
    mem.store_kv(conndb(db), agent_id, mem_kind(), mkey, fact, mtype0, importance0, scope0, expires_at)
  }
}

fn memory_line(e :: mem.MemoryEntry) -> Str {
  let label := if str.is_empty(e.key) {
    ""
  } else {
    str.concat(e.key, ": ")
  }
  str.concat("- ", str.concat(label, e.content))
}

# Recall an agent's live durable memory as a bulleted block, or "" if none.
# Filters out superseded + expired rows; orders by importance (high first) then
# recency; keyed facts render as "key: value".
fn recall_facts_text(db :: Db, agent_id :: Str, n :: Int) -> [sql, fs_read, time] Str {
  str.join(list.map(mem.recall_ranked(conndb(db), agent_id, n), memory_line), "\n")
}

fn memory_entry_json(e :: mem.MemoryEntry) -> jv.Json {
  JObj([("key", JStr(e.key)), ("fact", JStr(e.content)), ("type", JStr(e.mtype)), ("importance", JStr(e.importance)), ("scope", JStr(e.scope)), ("ts", JStr(e.ts)), ("expires_at", JStr(e.expires_at))])
}

# Structured live memory for the GET endpoint.
fn recall_memory_json(db :: Db, agent_id :: Str, n :: Int) -> [sql, fs_read, time] Str {
  jv.stringify(JList(list.map(mem.recall_ranked(conndb(db), agent_id, n), memory_entry_json)))
}

# Recent audit events for one agent, newest first, as a JSON array string.
# Each row is built server-side via json_object() so the result is a single
# column (the lex sqlite driver mis-maps multi-column raw rows).
fn recent_by_agent(db :: Db, agent_id :: Str, lim :: Int) -> [sql] Str {
  let q := "SELECT json_object('run_id', run_id, 'event', event_kind, 'data', data_json, 'ts', ts) AS j FROM traces WHERE agent_id = ? ORDER BY ts DESC LIMIT ?"
  match sql.query(db, q, [PStr(agent_id), PInt(lim)]) {
    Err(_) => "[]",
    Ok(rows) => str.concat("[", str.concat(str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "j") {
        Some(s) => s,
        None => "",
      }
    }), ","), "]")),
  }
}

