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

