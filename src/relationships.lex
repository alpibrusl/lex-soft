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

type Relationship = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str }

type RelRow = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str, active :: Int }

fn parse_rel_row(r :: RelRow) -> Relationship {
  { id: r.id, from_agent: r.from_agent, to_agent: r.to_agent, role: r.role, contract_json: r.contract_json }
}

fn add(db :: Db, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str) -> [sql, fs_write, random, time] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := "INSERT INTO relationships (id, from_agent, to_agent, role, contract_json, active, created_at) SELECT ?, ?, ?, ?, ?, 1, ? WHERE NOT EXISTS (SELECT 1 FROM relationships WHERE from_agent=? AND to_agent=? AND role=? AND active=1)"
  match sql.exec(db, q, [PStr(id), PStr(from_agent), PStr(to_agent), PStr(role), PStr(contract_json), PStr(now), PStr(from_agent), PStr(to_agent), PStr(role)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn remove(db :: Db, from_agent :: Str, to_agent :: Str, role :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := "UPDATE relationships SET active=0 WHERE from_agent=? AND to_agent=? AND role=?"
  match sql.exec(db, q, [PStr(from_agent), PStr(to_agent), PStr(role)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn peers_of(db :: Db, from_agent :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := "SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent=? AND active=1"
  let rows :: Result[List[RelRow], SqlError] := sql.query(db, q, [PStr(from_agent)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

fn peers_by_role(db :: Db, from_agent :: Str, role :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := "SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent=? AND role=? AND active=1"
  let rows :: Result[List[RelRow], SqlError] := sql.query(db, q, [PStr(from_agent), PStr(role)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

fn resolve_refs(db :: Db, rels :: List[Relationship]) -> [sql, fs_read] List[reg.AgentRef] {
  list.fold(rels, [], fn (acc :: List[reg.AgentRef], r :: Relationship) -> [sql, fs_read] List[reg.AgentRef] {
    match reg.find_by_id(db, r.to_agent) {
      Ok(Some(ref)) => if ref.status == "active" {
        list.concat(acc, [ref])
      } else {
        acc
      },
      _ => acc,
    }
  })
}

