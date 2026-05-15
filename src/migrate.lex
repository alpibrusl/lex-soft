# migrate.lex — SQL schema setup.
#
# Two tables:
#  * agent_state — one row per agent, JSON state blob
#  * traces     — append-only event log

import "std.sql" as sql

fn ddl_agent_state() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_state ( \
     agent         TEXT PRIMARY KEY, \
     state_json    TEXT NOT NULL, \
     updated_ts_ms INTEGER NOT NULL \
   )"
}

fn ddl_traces() -> Str {
  "CREATE TABLE IF NOT EXISTS traces ( \
     id          INTEGER PRIMARY KEY AUTOINCREMENT, \
     run_id      TEXT NOT NULL, \
     agent       TEXT NOT NULL, \
     kind        TEXT NOT NULL, \
     target      TEXT NOT NULL, \
     input_json  TEXT, \
     output_json TEXT, \
     error       TEXT, \
     ts_ms       INTEGER NOT NULL \
   )"
}

fn ddl_traces_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_traces_agent_ts ON traces(agent, ts_ms)"
}

fn run(db :: sql.Db) -> [sql, fs_write] Result[Unit, sql.SqlError] {
  match sql.exec(db, ddl_agent_state(), []) {
    Err(e) => Err(e),
    Ok(_)  =>
      match sql.exec(db, ddl_traces(), []) {
        Err(e) => Err(e),
        Ok(_)  =>
          match sql.exec(db, ddl_traces_idx(), []) {
            Err(e) => Err(e),
            Ok(_)  => Ok(unit),
          },
      },
  }
}
