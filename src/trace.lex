# trace.lex — append-only audit log.
#
# event_kind values: received, llm_start, llm_done, sent, error

import "std.sql" as sql
import "std.time" as time
import "std.crypto" as crypto

fn record(db :: sql.Db, run_id :: Str, agent_id :: Str, event_kind :: Str, data_json :: Str) -> [sql, fs_write] Unit {
  let now := time.now_iso()
  let q := "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, ?, ?, ?)"
  let _ := sql.exec(db, q, [PStr(run_id), PStr(agent_id), PStr(event_kind), PStr(data_json), PStr(now)])
  unit
}

fn new_run_id() -> [crypto] Str {
  crypto.uuid()
}
