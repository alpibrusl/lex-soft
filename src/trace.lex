# trace.lex — append-only audit log.
#
# event_kind values (LLM turn):    received, llm_start, llm_done, sent, error
# event_kind values (platform):    agent_registered, heartbeat, msg_delivered,
#                                   msg_pulled, state_saved

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

fn new_run_id() -> [random, crypto] Str {
  crypto.random_str_hex(16)
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn record(db :: Db, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  let id := new_run_id()
  let now := time.now_str()
  let q := str.join(["INSERT INTO traces (id, run_id, agent_id, event_kind, data_json, ts) VALUES ('", id, "', '", sq(run_id), "', '", sq(agent_id), "', '", sq(event_kind), "', '", sq(data_json), "', '", now, "')"], "")
  let __lex_discard_1 := sql.exec(db, q, [])
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
  let q := str.join(["SELECT line FROM (SELECT (CASE event_kind WHEN 'received' THEN 'User: ' ELSE 'Agent: ' END) || data_json AS line, ts FROM traces WHERE agent_id = '", sq(agent_id), "' AND event_kind IN ('received','llm_done') AND data_json <> '' AND data_json NOT LIKE '[%' ORDER BY ts DESC LIMIT ", int.to_str(n), ") s ORDER BY ts ASC"], "")
  match sql.query(db, q, []) {
    Err(_) => "",
    Ok(rows) => str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "line") { Some(s) => s, None => "" }
    }), "\n"),
  }
}

# Same recent exchanges as a JSON array string of {role:'user'|'agent', text},
# oldest-first — fed to the LLM as real prior conversation turns. Prior empty/
# error agent responses (start with '[') are filtered out.
fn recent_messages_json(db :: Db, agent_id :: Str, n :: Int) -> [sql] Str {
  let q := str.join(["SELECT j FROM (SELECT json_object('role', CASE event_kind WHEN 'received' THEN 'user' ELSE 'agent' END, 'text', data_json) AS j, ts FROM traces WHERE agent_id = '", sq(agent_id), "' AND event_kind IN ('received','llm_done') AND data_json <> '' AND data_json NOT LIKE '[%' ORDER BY ts DESC LIMIT ", int.to_str(n), ") s ORDER BY ts ASC"], "")
  match sql.query(db, q, []) {
    Err(_) => "[]",
    Ok(rows) => str.concat("[", str.concat(str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "j") { Some(s) => s, None => "" }
    }), ","), "]")),
  }
}

# ---- Durable memory --------------------------------------------------
# Store a fact for an agent (deduped: same fact for the same agent is a no-op).
fn remember_fact(db :: Db, agent_id :: Str, fact :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  if str.is_empty(str.trim(fact)) {
    ()
  } else {
    let id := new_run_id()
    let now := time.now_str()
    # Parameterised (sqlite `?`) so facts with semicolons/quotes can't break or
    # split the statement — the user-supplied `fact` is data, not SQL.
    let q := "INSERT INTO agent_memory (id, agent_id, fact, ts) SELECT ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM agent_memory WHERE agent_id = ? AND fact = ?)"
    let __lex_discard_m := sql.exec(db, q, [PStr(id), PStr(agent_id), PStr(fact), PStr(now), PStr(agent_id), PStr(fact)])
    ()
  }
}

# Recall an agent's most recent durable facts as a bulleted block (newest first),
# or "" if none. Single-column query (safe under the sqlite multi-col bug).
fn recall_facts_text(db :: Db, agent_id :: Str, n :: Int) -> [sql] Str {
  let q := str.join(["SELECT fact FROM agent_memory WHERE agent_id = '", sq(agent_id), "' ORDER BY ts DESC LIMIT ", int.to_str(n)], "")
  match sql.query(db, q, []) {
    Err(_) => "",
    Ok(rows) => str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "fact") { Some(s) => str.concat("- ", s), None => "" }
    }), "\n"),
  }
}

# Recent audit events for one agent, newest first, as a JSON array string.
# Each row is built server-side via json_object() so the result is a single
# column (the lex sqlite driver mis-maps multi-column raw rows).
fn recent_by_agent(db :: Db, agent_id :: Str, lim :: Int) -> [sql] Str {
  let q := str.join(["SELECT json_object('run_id', run_id, 'event', event_kind, 'data', data_json, 'ts', ts) AS j FROM traces WHERE agent_id = '", sq(agent_id), "' ORDER BY ts DESC LIMIT ", int.to_str(lim)], "")
  match sql.query(db, q, []) {
    Err(_) => "[]",
    Ok(rows) => str.concat("[", str.concat(str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "j") { Some(s) => s, None => "" }
    }), ","), "]")),
  }
}

