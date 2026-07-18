# registry.lex — agent registration and discovery.
#
# Every agent (truck, depot, tms, …) registers itself on boot, sends
# heartbeats to update last_seen_at, and can be looked up by id or kind.

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

import "lex-schema/json_value" as jv

type AgentRef = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str], status :: Str }

type AgentRow = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities_json :: Str, status :: Str }

fn parse_agent_row(r :: AgentRow) -> AgentRef {
  let cap_list := match jv.parse(r.capabilities_json) {
    Ok(JList(items)) => list.fold(items, [], fn (acc :: List[Str], j :: jv.Json) -> List[Str] {
      match j {
        JStr(s) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
  { id: r.id, kind: r.kind, name: r.name, inbox_url: r.inbox_url, capabilities: cap_list, status: r.status }
}

fn register(db :: Db, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let caps_json := jv.stringify(JList(list.map(capabilities, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))
  let q := "INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, inbox_url=excluded.inbox_url, capabilities_json=excluded.capabilities_json, status='active', last_seen_at=excluded.last_seen_at"
  match sql.exec(db, q, [PStr(id), PStr(kind), PStr(name), PStr(inbox_url), PStr(caps_json), PStr(now), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn heartbeat(db :: Db, id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := "UPDATE agents SET last_seen_at=? WHERE id=?"
  match sql.exec(db, q, [PStr(now), PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn set_status(db :: Db, id :: Str, status :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := "UPDATE agents SET status=?, last_seen_at=? WHERE id=?"
  match sql.exec(db, q, [PStr(status), PStr(now), PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn find_by_id(db :: Db, id :: Str) -> [sql, fs_read] Result[Option[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents WHERE id=?"
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(id)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(match list.head(rs) {
      None => None,
      Some(r) => Some(parse_agent_row(r)),
    }),
  }
}

fn find_by_kind(db :: Db, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents WHERE kind=? AND status='active'"
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(kind)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn list_all(db :: Db) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status FROM agents ORDER BY kind, name"
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

