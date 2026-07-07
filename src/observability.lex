# observability.lex — the operator's cross-tenant aggregate (#63).
#
# Distinct from the tenant-scoped Audit/Usage APIs (#60/#61): this is the
# PLATFORM OPERATOR's view — not scoped to any one account, gated instead by a
# shared admin key. It answers "what is this node's overall state?" in one call,
# for a fleet dashboard or an alert rule, alongside the OTLP traces the runtime
# already exports (this is the pull-based counterpart to those push traces).
#
#   GET /admin/health   (X-Admin-Key: <key>)   — node aggregate + per-tenant load
#
# Node identity/version is supplied by the host (the core doesn't know its own
# deployment version). "Known peer nodes" come from the federation directory
# (org_directory) — the closest thing to a node registry in the federated,
# push-published topology. Everything else is a COUNT over this node's DB.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

# COUNT(*) over a table with an optional raw WHERE tail (constant literals only —
# no user input reaches these). 0 on
# any error (a missing table on an old DB shouldn't 500 the health endpoint).
fn count_where(db :: Db, table :: Str, where_tail :: Str) -> [sql, fs_read] Int {
  let q := str.join(["SELECT COUNT(*) AS n FROM ", table, " ", where_tail], "")
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

fn count(db :: Db, table :: Str) -> [sql, fs_read] Int {
  count_where(db, table, "")
}

type TenantLoad = { tenant :: Str, agents :: Int }

# Per-tenant agent counts — the "tenant load" distribution across the node.
fn tenant_loads(db :: Db) -> [sql, fs_read] List[TenantLoad] {
  let q := "SELECT tenant, COUNT(*) AS agents FROM agents GROUP BY tenant ORDER BY agents DESC"
  let rows :: Result[List[TenantLoad], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn distinct_tenants(db :: Db) -> [sql, fs_read] Int {
  let q := "SELECT COUNT(*) AS n FROM (SELECT DISTINCT tenant FROM agents) t"
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => 0,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

fn tenant_load_json(t :: TenantLoad) -> jv.Json {
  JObj([("tenant", JStr(t.tenant)), ("agents", JInt(t.agents))])
}

# The full aggregate as JSON. `version` and `org` are host-supplied node
# identity; the rest is derived from the DB.
fn health_json(db :: Db, org :: Str, version :: Str) -> [sql, fs_read] Str {
  let notif_status := JObj([("pending", JInt(count_where(db, "notifications", "WHERE status='pending'"))), ("delivered", JInt(count_where(db, "notifications", "WHERE status='delivered'"))), ("failed", JInt(count_where(db, "notifications", "WHERE status='failed'")))])
  let counts := JObj([("agents", JInt(count(db, "agents"))), ("tenants", JInt(distinct_tenants(db))), ("accounts", JInt(count(db, "accounts"))), ("credentials", JInt(count(db, "credentials"))), ("active_credentials", JInt(count_where(db, "credentials", "WHERE revoked=0"))), ("trail_events", JInt(count(db, "events"))), ("approvals_pending", JInt(count_where(db, "approvals", "WHERE status='pending'"))), ("known_peer_nodes", JInt(count(db, "org_directory")))])
  jv.stringify(JObj([("ok", JBool(true)), ("org", JStr(org)), ("version", JStr(version)), ("counts", counts), ("notifications", notif_status), ("tenant_load", JList(list.map(tenant_loads(db), fn (t :: TenantLoad) -> jv.Json {
    tenant_load_json(t)
  })))]))
}

# Host opt-in. `admin_key` gates the endpoint (X-Admin-Key header); an empty
# key means the operator endpoint is DISABLED (fail closed) — a deployment must
# set one deliberately to expose the aggregate.
fn mount(r :: router.Router, db :: Db, org :: Str, version :: Str, admin_key :: Str) -> router.Router {
  router.route_effectful(r, "GET", "/admin/health", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    if str.is_empty(admin_key) {
      resp.not_found()
    } else {
      if ctx.header_or(c, "x-admin-key", "") == admin_key {
        resp.json(health_json(db, org, version))
      } else {
        resp.unauthorized("{\"error\":\"invalid or missing X-Admin-Key\"}")
      }
    }
  })
}

