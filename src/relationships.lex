# relationships.lex — directed relationship graph between agents.
#
# A relationship (from, to, role) means: agent `from` is authorised to
# interact with agent `to` in the capacity described by `role`.
#
# Examples:
#   (truck-07, depot-north, preferred_charger)
#   (truck-07, tms-primary, contracted)
#   (truck-07, tms-secondary, freelance)
#   (depot-north, tms-primary, reporting)
#
# The `contract_json` field is free-form metadata (rates, schedule windows, etc.)

import "std.sql" as sql
import "std.str" as str
import "std.time" as time
import "std.list" as list
import "std.crypto" as crypto
import "./registry" as reg

type Relationship = {
  id            :: Str,
  from_agent    :: Str,
  to_agent      :: Str,
  role          :: Str,
  contract_json :: Str,
}

fn row_to_rel(row :: List[sql.SqlValue]) -> Option[Relationship] {
  match row {
    [SqlText(id), SqlText(from_a), SqlText(to_a), SqlText(role), SqlText(contract), _, _] =>
      Some({ id: id, from_agent: from_a, to_agent: to_a, role: role, contract_json: contract }),
    _ => None,
  }
}

fn add(db :: sql.Db, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str) -> [sql, fs_write, crypto] Result[Unit, Str] {
  let id := crypto.uuid()
  let now := time.now_iso()
  let q := "INSERT INTO relationships (id, from_agent, to_agent, role, contract_json, active, created_at) \
            VALUES (?, ?, ?, ?, ?, 1, ?)"
  match sql.exec(db, q, [PStr(id), PStr(from_agent), PStr(to_agent), PStr(role), PStr(contract_json), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}

fn remove(db :: sql.Db, from_agent :: Str, to_agent :: Str, role :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := "UPDATE relationships SET active=0 WHERE from_agent=? AND to_agent=? AND role=?"
  match sql.exec(db, q, [PStr(from_agent), PStr(to_agent), PStr(role)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}

fn peers_of(db :: sql.Db, from_agent :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := "SELECT id, from_agent, to_agent, role, contract_json, active, created_at \
            FROM relationships WHERE from_agent=? AND active=1"
  match sql.query(db, q, [PStr(from_agent)]) {
    Err(e) => Err(e.message),
    Ok(rows) => Ok(list.filter_map(rows, fn (r :: List[sql.SqlValue]) -> Option[Relationship] { row_to_rel(r) })),
  }
}

fn peers_by_role(db :: sql.Db, from_agent :: Str, role :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := "SELECT id, from_agent, to_agent, role, contract_json, active, created_at \
            FROM relationships WHERE from_agent=? AND role=? AND active=1"
  match sql.query(db, q, [PStr(from_agent), PStr(role)]) {
    Err(e) => Err(e.message),
    Ok(rows) => Ok(list.filter_map(rows, fn (r :: List[sql.SqlValue]) -> Option[Relationship] { row_to_rel(r) })),
  }
}

fn resolve_refs(db :: sql.Db, rels :: List[Relationship]) -> [sql, fs_read] List[reg.AgentRef] {
  list.filter_map(rels, fn (rel :: Relationship) -> Option[reg.AgentRef] {
    match reg.find_by_id(db, rel.to_agent) {
      Ok(Some(ref)) => if str.eq(ref.status, "active") { Some(ref) } else { None },
      _ => None,
    }
  })
}
