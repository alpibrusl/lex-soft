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
  let q := "INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, tenant, registered_at, last_seen_at) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, inbox_url=excluded.inbox_url, capabilities_json=excluded.capabilities_json, status='active', tenant=excluded.tenant, last_seen_at=excluded.last_seen_at"
  match sql.exec(db, q, [PStr(id), PStr(kind), PStr(name), PStr(inbox_url), PStr(caps_json), PStr(tenant), PStr(now), PStr(now)]) {
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

# ── Pooled agents: pre-mounted personas a customer claims at onboarding ──────
# A pooled row is invisible to discovery (kind lookups filter status='active',
# the full catalog filters status != 'pooled') and sits in a host-chosen
# holding tenant until claimed. Re-registration of an EXISTING row is a no-op,
# so a claimed agent is never downgraded back to the pool on reboot.
fn register_pooled(db :: Db, tenant :: Str, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  let caps_json := jv.stringify(JList(list.map(capabilities, fn (cap :: Str) -> jv.Json {
    JStr(cap)
  })))
  let now := time.now_str()
  let q := "INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, tenant, registered_at, last_seen_at) VALUES (?, ?, ?, ?, ?, 'pooled', ?, ?, ?) ON CONFLICT(id) DO NOTHING"
  match sql.exec(db, q, [PStr(id), PStr(kind), PStr(name), PStr(inbox_url), PStr(caps_json), PStr(tenant), PStr(now), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Claim up to `count` pooled agents of a kind for `new_tenant`. Returns the
# claimed ids (possibly fewer than asked — the pool may be short). A non-empty
# display_name renames the claimed agents "<display_name> <n>".
fn claim_pooled(db :: Db, kind :: Str, count :: Int, new_tenant :: Str, display_name :: Str) -> [sql, fs_read, fs_write, time] Result[List[Str], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE status='pooled' AND kind=? ORDER BY id LIMIT ?"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(kind), PInt(count)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => {
      let now := time.now_str()
      let ids := list.map(list.enumerate(rs), fn (p :: (Int, AgentRow)) -> [sql, fs_write] Str {
        match p {
          (i, r) => {
            let name := if str.is_empty(display_name) {
              r.name
            } else {
              str.join([display_name, " ", int.to_str(i + 1)], "")
            }
            let uq := "UPDATE agents SET tenant=?, status='active', name=?, last_seen_at=? WHERE id=? AND status='pooled'"
            let __u := sql.exec(db, uq, [PStr(new_tenant), PStr(name), PStr(now), PStr(r.id)])
            r.id
          },
        }
      })
      Ok(ids)
    },
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
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE id=?"], "")
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
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE kind=? AND status='active'"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(kind)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn list_all(db :: Db) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE status != 'pooled' ORDER BY kind, name"], "")
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
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE tenant=? ORDER BY kind, name"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(tenant)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

fn find_by_kind_in(db :: Db, tenant :: Str, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := str.join(["SELECT ", cols(), " FROM agents WHERE tenant=? AND kind=? AND status='active'"], "")
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db, q, [PStr(tenant), PStr(kind)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.map(rs, fn (r :: AgentRow) -> AgentRef {
      parse_agent_row(r)
    })),
  }
}

