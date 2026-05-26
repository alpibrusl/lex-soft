# migrate.lex — full DDL for the lex-soft platform.
#
# Tables:
#   agents        — registered agents (truck, depot, tms, …)
#   relationships — directed graph: who is authorised to talk to whom
#   agent_state   — per-agent JSON state blob
#   traces        — append-only audit log

import "std.sql" as sql

fn ddl_agents() -> Str {
  "CREATE TABLE IF NOT EXISTS agents (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, inbox_url TEXT NOT NULL, capabilities_json TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', registered_at TEXT NOT NULL, last_seen_at TEXT NOT NULL)"
}

fn ddl_relationships() -> Str {
  "CREATE TABLE IF NOT EXISTS relationships (id TEXT PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, role TEXT NOT NULL, contract_json TEXT NOT NULL DEFAULT '{}', active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL)"
}

fn ddl_rel_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_agent, active)"
}

fn ddl_agent_state() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_state (agent_id TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at TEXT NOT NULL)"
}

fn ddl_traces() -> Str {
  "CREATE TABLE IF NOT EXISTS traces (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL, agent_id TEXT NOT NULL, event_kind TEXT NOT NULL, data_json TEXT, ts TEXT NOT NULL)"
}

fn ddl_traces_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_traces_agent_ts ON traces(agent_id, ts)"
}

fn exec_ddl(db :: Db, stmt :: Str) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, stmt, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn run(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match exec_ddl(db, ddl_agents()) {
    Err(e) => Err(e),
    Ok(_) => match exec_ddl(db, ddl_relationships()) {
      Err(e) => Err(e),
      Ok(_) => match exec_ddl(db, ddl_rel_idx()) {
        Err(e) => Err(e),
        Ok(_) => match exec_ddl(db, ddl_agent_state()) {
          Err(e) => Err(e),
          Ok(_) => match exec_ddl(db, ddl_traces()) {
            Err(e) => Err(e),
            Ok(_) => exec_ddl(db, ddl_traces_idx()),
          },
        },
      },
    },
  }
}

