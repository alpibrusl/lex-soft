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

import "lex-schema/json_value" as jv

import "./registry" as reg

type Relationship = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str }

type RelRow = { id :: Str, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str, active :: Int }

fn parse_rel_row(r :: RelRow) -> Relationship {
  { id: r.id, from_agent: r.from_agent, to_agent: r.to_agent, role: r.role, contract_json: r.contract_json }
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn add(db :: Db, from_agent :: Str, to_agent :: Str, role :: Str, contract_json :: Str) -> [sql, fs_write, random, time] Result[Unit, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := str.join(["INSERT INTO relationships (id, from_agent, to_agent, role, contract_json, active, created_at) SELECT '", id, "', '", sq(from_agent), "', '", sq(to_agent), "', '", sq(role), "', '", sq(contract_json), "', 1, '", now, "' WHERE NOT EXISTS (SELECT 1 FROM relationships WHERE from_agent='", sq(from_agent), "' AND to_agent='", sq(to_agent), "' AND role='", sq(role), "' AND active=1)"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn remove(db :: Db, from_agent :: Str, to_agent :: Str, role :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := str.join(["UPDATE relationships SET active=0 WHERE from_agent='", sq(from_agent), "' AND to_agent='", sq(to_agent), "' AND role='", sq(role), "'"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn peers_of(db :: Db, from_agent :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := str.join(["SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent='", sq(from_agent), "' AND active=1"], "")
  let rows :: Result[List[RelRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

# ── Relationship-gated invocation (#26) ───────────────────────────────────────
# A peer may only invoke a capability its relationship contract grants. The gate
# is the directed edge `caller -> target`: if no active edge exists the call is
# denied, so REMOVING the edge revokes access. The contract can further scope
# *which* capabilities the edge grants:
#   {}                                  → grants ALL (a plain trust edge)
#   {"capabilities": ["energy.v2g.dispatch", ...]}  → grants only those
#   {"capabilities": ["*"]}             → grants ALL (explicit wildcard)
fn contract_allows(contract_json :: Str, capability :: Str) -> Bool {
  match jv.parse(contract_json) {
    Err(_) => true,
    Ok(j) => match jv.get_field(j, "capabilities") {
      Some(JList(items)) => list.fold(items, false, fn (acc :: Bool, it :: jv.Json) -> Bool {
        match it {
          JStr(s) => acc or s == capability or s == "*",
          _ => acc,
        }
      }),
      _ => true,
    },
  }
}

# Active edges caller -> target (any role).
fn edges_between(db :: Db, from_agent :: Str, to_agent :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := str.join(["SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent='", sq(from_agent), "' AND to_agent='", sq(to_agent), "' AND active=1"], "")
  let rows :: Result[List[RelRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: RelRow) -> Relationship {
      parse_rel_row(r)
    })),
  }
}

# True iff some active caller -> target edge grants `capability`. This is the
# call gate the federation layer enforces before dispatching a peer's request.
fn grants(db :: Db, from_agent :: Str, to_agent :: Str, capability :: Str) -> [sql, fs_read] Bool {
  match edges_between(db, from_agent, to_agent) {
    Err(_) => false,
    Ok(edges) => list.fold(edges, false, fn (acc :: Bool, e :: Relationship) -> Bool {
      acc or contract_allows(e.contract_json, capability)
    }),
  }
}

# Capability-agnostic gate: is there ANY active caller -> target edge at all?
fn grants_any(db :: Db, from_agent :: Str, to_agent :: Str) -> [sql, fs_read] Bool {
  match edges_between(db, from_agent, to_agent) {
    Err(_) => false,
    Ok(edges) => list.len(edges) > 0,
  }
}

fn peers_by_role(db :: Db, from_agent :: Str, role :: Str) -> [sql, fs_read] Result[List[Relationship], Str] {
  let q := str.join(["SELECT id, from_agent, to_agent, role, contract_json, active FROM relationships WHERE from_agent='", sq(from_agent), "' AND role='", sq(role), "' AND active=1"], "")
  let rows :: Result[List[RelRow], SqlError] := sql.query(db, q, [])
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

