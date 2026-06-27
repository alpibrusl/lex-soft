# registry.lex — agent registration and discovery.
#
# Every agent (truck, depot, tms, …) registers itself on boot, sends
# heartbeats to update last_seen_at, and can be looked up by id or kind.

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

import "lex-schema/json_value" as jv

type AgentRef = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str], status :: Str, tenant :: Str }

type AgentRow = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities_json :: Str, status :: Str, tenant :: Str }

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
  { id: r.id, kind: r.kind, name: r.name, inbox_url: r.inbox_url, capabilities: cap_list, status: r.status, tenant: r.tenant }
}

# Column list shared by every SELECT — keeps tenant in lock-step with AgentRow.
fn cols() -> Str {
  "id, kind, name, inbox_url, capabilities_json, status, tenant"
}

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

# Register into the default tenant (back-compatible single-tenant API).
fn register(db :: Db, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  register_in(db, "default", id, kind, name, inbox_url, capabilities)
}

# Register an agent scoped to a tenant. The tenant is the multi-tenant boundary:
# discovery and visibility are filtered by it (see list_by_tenant / find_by_kind_in).
fn register_in(db :: Db, tenant :: Str, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let caps_json := jv.stringify(JList(list.map(capabilities, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))
  let q := str.join(["INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, tenant, registered_at, last_seen_at) VALUES ('", sq(id), "', '", sq(kind), "', '", sq(name), "', '", sq(inbox_url), "', '", sq(caps_json), "', 'active', '", sq(tenant), "', '", now, "', '", now, "') ON CONFLICT(id) DO UPDATE SET name=excluded.name, inbox_url=excluded.inbox_url, capabilities_json=excluded.capabilities_json, status='active', tenant=excluded.tenant, last_seen_at=excluded.last_seen_at"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn heartbeat(db :: Db, id :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := str.join(["UPDATE agents SET last_seen_at='", now, "' WHERE id='", sq(id), "'"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn set_status(db :: Db, id :: Str, status :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := str.join(["UPDATE agents SET status='", sq(status), "', last_seen_at='", now, "' WHERE id='", sq(id), "'"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn find_by_id(db :: Db, id :: Str) -> [sql, fs_read] Result[Option[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE id='", sq(id), "'"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(match list.head(rs) {
      None => None,
      Some(r) => Some(parse_agent_row(r)),
    }),
  }
}

fn find_by_kind(db :: Db, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE kind='", sq(kind), "' AND status='active'"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn list_all(db :: Db) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents ORDER BY kind, name"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

# ── Tenant-scoped discovery (the multi-tenant boundary, #26) ──────────────────
# An agent in tenant A must not see tenant B's registry. These return ONLY the
# rows owned by the given tenant; `find_by_id` is unscoped on purpose (it is a
# direct-key lookup used after a tenant check), the list views are the boundary.
fn list_by_tenant(db :: Db, tenant :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE tenant='", sq(tenant), "' ORDER BY kind, name"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn find_by_kind_in(db :: Db, tenant :: Str, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE tenant='", sq(tenant), "' AND kind='", sq(kind), "' AND status='active'"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

