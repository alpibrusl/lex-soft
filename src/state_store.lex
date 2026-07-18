# state_store.lex — per-agent JSON state persistence.
#
# Each agent has exactly one state row. The runner loads it before
# calling the LLM and saves it afterwards. The state blob is opaque
# to the platform — agents own their own schema.

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

type StateRow = { state_json :: Str }

fn load(db :: Db, agent_id :: Str) -> [sql, fs_read] Str {
  let q := "SELECT state_json FROM agent_state WHERE agent_id=?"
  let rows :: Result[List[StateRow], SqlError] := sql.query(db, q, [PStr(agent_id)])
  match rows {
    Err(_) => "{}",
    Ok(rs) => match list.head(rs) {
      None => "{}",
      Some(r) => r.state_json,
    },
  }
}

fn save(db :: Db, agent_id :: Str, state_json :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := "INSERT INTO agent_state (agent_id, state_json, updated_at) VALUES (?, ?, ?) ON CONFLICT(agent_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at"
  match sql.exec(db, q, [PStr(agent_id), PStr(state_json), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

