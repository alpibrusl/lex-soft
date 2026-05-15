# state_store.lex — per-agent state persistence.
#
# State is stored as a JSON string keyed by agent name. The runner
# treats it opaquely — encode/decode is the agent module's job.

import "std.sql"      as sql
import "std.list"     as list
import "std.datetime" as datetime

fn load_or_init(
  db :: sql.Db,
  agent :: Str,
  initial_json :: Str,
) -> [sql, fs_write, time] Result[Str, Str] {
  match sql.query(db, "SELECT state_json FROM agent_state WHERE agent = ?", [agent]) {
    Err(e) => Err(sql.error_msg(e)),
    Ok(rows) =>
      if list.is_empty(rows) {
        match save(db, agent, initial_json) {
          Err(e) => Err(e),
          Ok(_)  => Ok(initial_json),
        }
      } else {
        match list.first(rows) {
          None      => Err("unreachable: rows non-empty"),
          Some(row) => Ok(row.state_json),
        }
      },
  }
}

fn save(
  db :: sql.Db,
  agent :: Str,
  state_json :: Str,
) -> [sql, fs_write, time] Result[Unit, Str] {
  let now_ms := datetime.now_ms()
  match sql.exec(db,
    "INSERT INTO agent_state(agent, state_json, updated_ts_ms) \
     VALUES (?, ?, ?) \
     ON CONFLICT(agent) DO UPDATE SET state_json = excluded.state_json, updated_ts_ms = excluded.updated_ts_ms",
    [agent, state_json, now_ms]) {
    Err(e) => Err(sql.error_msg(e)),
    Ok(_)  => Ok(unit),
  }
}
