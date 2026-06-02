# trace.lex — append-only audit log.
#
# event_kind values (LLM turn):    received, llm_start, llm_done, sent, error
# event_kind values (platform):    agent_registered, heartbeat, msg_delivered,
#                                   msg_pulled, state_saved

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.crypto" as crypto

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

