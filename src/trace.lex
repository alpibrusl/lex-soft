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
  let q := str.join(["SELECT j FROM (SELECT json_object('role', CASE event_kind WHEN 'received' THEN 'user' ELSE 'agent' END, 'text', substr(data_json, 1, 800)) AS j, ts FROM traces WHERE agent_id = '", sq(agent_id), "' AND event_kind IN ('received','llm_done') AND data_json <> '' AND data_json NOT LIKE '[%' ORDER BY ts DESC LIMIT ", int.to_str(n), ") s ORDER BY ts ASC"], "")
  match sql.query(db, q, []) {
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
# Store a keyless fact for an agent (deduped: same fact for the same agent is a
# no-op). Back-compat entry point; stored as semantic/medium/global.
fn remember_fact(db :: Db, agent_id :: Str, fact :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  if str.is_empty(str.trim(fact)) {
    ()
  } else {
    let id := new_run_id()
    let now := time.now_str()
    let q := "INSERT INTO agent_memory (id, agent_id, fact, ts, updated_at) SELECT ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM agent_memory WHERE agent_id = ? AND fact = ? AND superseded = 0)"
    let __lex_discard_m := sql.exec(db, q, [PStr(id), PStr(agent_id), PStr(fact), PStr(now), PStr(now), PStr(agent_id), PStr(fact)])
    ()
  }
}

fn norm_type(t :: Str) -> Str {
  if t == "episodic" or t == "procedural" or t == "semantic" {
    t
  } else {
    "semantic"
  }
}

fn norm_importance(i :: Str) -> Str {
  if i == "high" or i == "low" or i == "medium" {
    i
  } else {
    "medium"
  }
}

# Current (non-superseded) value stored under a key, or "" if none.
fn current_value(db :: Db, agent_id :: Str, scope :: Str, mkey :: Str) -> [sql] Str {
  let q := "SELECT fact FROM agent_memory WHERE agent_id = ? AND scope = ? AND mkey = ? AND superseded = 0 ORDER BY ts DESC LIMIT 1"
  match sql.query(db, q, [PStr(agent_id), PStr(scope), PStr(mkey)]) {
    Err(_) => "",
    Ok(rows) => match list.head(rows) {
      None => "",
      Some(r) => match sql.get_str(r, "fact") {
        Some(s) => s,
        None => "",
      },
    },
  }
}

# Store a typed/keyed fact with temporal supersession (the 2026 memory model).
# - keyless (mkey == ""): falls back to deduped append (semantic/medium).
# - keyed: if the current value for (agent_id, scope, mkey) already equals the
#   new fact -> NOOP; otherwise mark the prior value superseded (kept for history
#   / "what was true when") and insert the new one. So evolving facts REPLACE
#   rather than accumulate contradictions.
fn remember_kv(db :: Db, agent_id :: Str, scope0 :: Str, mkey :: Str, fact :: Str, mtype0 :: Str, importance0 :: Str, expires_at :: Str) -> [sql, fs_write, time, random, crypto] Unit {
  if str.is_empty(str.trim(fact)) {
    ()
  } else {
    let scope := if str.is_empty(scope0) {
      "global"
    } else {
      scope0
    }
    let mtype := norm_type(mtype0)
    let importance := norm_importance(importance0)
    if str.is_empty(str.trim(mkey)) {
      let id := new_run_id()
      let now := time.now_str()
      let q := "INSERT INTO agent_memory (id, agent_id, fact, ts, mtype, importance, scope, expires_at, updated_at) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM agent_memory WHERE agent_id = ? AND fact = ? AND superseded = 0)"
      let __k := sql.exec(db, q, [PStr(id), PStr(agent_id), PStr(fact), PStr(now), PStr(mtype), PStr(importance), PStr(scope), PStr(expires_at), PStr(now), PStr(agent_id), PStr(fact)])
      ()
    } else {
      let cur := current_value(db, agent_id, scope, mkey)
      if cur == fact {
        ()
      } else {
        let now := time.now_str()
        let __sup := sql.exec(db, "UPDATE agent_memory SET superseded = 1, updated_at = ? WHERE agent_id = ? AND scope = ? AND mkey = ? AND superseded = 0", [PStr(now), PStr(agent_id), PStr(scope), PStr(mkey)])
        let id := new_run_id()
        let __ins := sql.exec(db, "INSERT INTO agent_memory (id, agent_id, fact, ts, mkey, mtype, importance, scope, superseded, expires_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)", [PStr(id), PStr(agent_id), PStr(fact), PStr(now), PStr(mkey), PStr(mtype), PStr(importance), PStr(scope), PStr(expires_at), PStr(now)])
        ()
      }
    }
  }
}

# Recall an agent's live durable memory as a bulleted block, or "" if none.
# Filters out superseded + expired rows; orders by importance (high first) then
# recency; keyed facts render as "key: value". Single-column query (safe under
# the sqlite multi-col bug).
fn recall_facts_text(db :: Db, agent_id :: Str, n :: Int) -> [sql, time] Str {
  let now := time.now_str()
  let q := "SELECT (CASE WHEN mkey <> '' THEN mkey || ': ' ELSE '' END) || fact AS line FROM agent_memory WHERE agent_id = ? AND superseded = 0 AND (expires_at = '' OR expires_at > ?) ORDER BY CASE importance WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, ts DESC LIMIT ?"
  match sql.query(db, q, [PStr(agent_id), PStr(now), PInt(n)]) {
    Err(_) => "",
    Ok(rows) => str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "line") {
        Some(s) => str.concat("- ", s),
        None => "",
      }
    }), "\n"),
  }
}

# Structured live memory for the GET endpoint (single-column json_object rows).
fn recall_memory_json(db :: Db, agent_id :: Str, n :: Int) -> [sql, time] Str {
  let now := time.now_str()
  let q := "SELECT json_object('key', mkey, 'fact', fact, 'type', mtype, 'importance', importance, 'scope', scope, 'ts', ts, 'expires_at', expires_at) AS j FROM agent_memory WHERE agent_id = ? AND superseded = 0 AND (expires_at = '' OR expires_at > ?) ORDER BY CASE importance WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, ts DESC LIMIT ?"
  match sql.query(db, q, [PStr(agent_id), PStr(now), PInt(n)]) {
    Err(_) => "[]",
    Ok(rows) => str.concat("[", str.concat(str.join(list.map(rows, fn (r :: jv.Json) -> Str {
      match sql.get_str(r, "j") {
        Some(s) => s,
        None => "",
      }
    }), ","), "]")),
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
      match sql.get_str(r, "j") {
        Some(s) => s,
        None => "",
      }
    }), ","), "]")),
  }
}

