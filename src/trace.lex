# trace.lex — SQL-backed audit log.
#
# Replaces the filesystem `lex-store` trace tree with a flat table.
# Each step emits one row per: a2a.received, action.proposed,
# gate.verdict, action.executed, error. Replay is a `SELECT ... ORDER BY ts_ms`.

import "std.sql"      as sql
import "std.datetime" as datetime
import "std.str"      as str

type Event = {
  run_id :: Str,
  agent :: Str,
  kind :: Str,
  target :: Str,
  input_json :: Str,
  output_json :: Str,
  error :: Str,
}

fn append(
  db :: sql.Db,
  run_id :: Str,
  agent :: Str,
  kind :: Str,
  target :: Str,
  input_json :: Str,
  output_json :: Str,
  error :: Str,
) -> [sql, fs_write, time] Result[Unit, Str] {
  let now_ms := datetime.now_ms()
  match sql.exec(db,
    "INSERT INTO traces(run_id, agent, kind, target, input_json, output_json, error, ts_ms) \
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    [run_id, agent, kind, target, input_json, output_json, error, now_ms]) {
    Err(e) => Err(sql.error_msg(e)),
    Ok(_)  => Ok(unit),
  }
}

fn for_agent(
  db :: sql.Db,
  agent :: Str,
  limit :: Int,
) -> [sql, fs_write] Result[List[{ ts_ms :: Int, kind :: Str, target :: Str, input_json :: Str, output_json :: Str, error :: Str }], Str] {
  match sql.query(db,
    "SELECT ts_ms, kind, target, input_json, output_json, error \
     FROM traces WHERE agent = ? ORDER BY ts_ms DESC LIMIT ?",
    [agent, limit]) {
    Err(e)   => Err(sql.error_msg(e)),
    Ok(rows) => Ok(rows),
  }
}
