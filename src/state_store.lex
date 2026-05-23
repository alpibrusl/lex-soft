# state_store.lex — per-agent JSON state persistence.
#
# Each agent has exactly one state row. The runner loads it before
# calling the LLM and saves it afterwards. The state blob is opaque
# to the platform — agents own their own schema.

import "std.sql" as sql
import "std.time" as time

fn load(db :: sql.Db, agent_id :: Str) -> [sql, fs_read] Str {
  let q := "SELECT state_json FROM agent_state WHERE agent_id=?"
  match sql.query(db, q, [PStr(agent_id)]) {
    Err(_)   => "{}",
    Ok(rows) => match rows {
      [[SqlText(s) | _] | _] => s,
      _ => "{}",
    },
  }
}

fn save(db :: sql.Db, agent_id :: Str, state_json :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let now := time.now_iso()
  let q := "INSERT INTO agent_state (agent_id, state_json, updated_at) VALUES (?, ?, ?) \
            ON CONFLICT(agent_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at"
  match sql.exec(db, q, [PStr(agent_id), PStr(state_json), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}
