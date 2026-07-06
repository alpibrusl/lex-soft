# audit.lex — tenant-scoped audit over the settlement trail (#60).
#
# The settlement trail (settlement.lex) already records every task run as a
# hash-chained, tamper-evident event. This exposes it as a CUSTOMER-facing audit
# surface: a caller presents its agent credential (identity.lex), and only ever
# sees the events belonging to its own org's agents — never another tenant's.
#
#   GET /audit/events[?agent=&kind=]   — this account's org's trail events
#
# Scoping (Option A): an account owns an `org` (identity.Subject); the org owns
# agents (registry #26, `tenant == org`); every trail event's payload carries the
# acting `agent`. So an account's events are the events whose payload agent is one
# of its org's agents — resolved via the registry, filtered at the SQL layer with
# the same payload LIKE pattern arm.lex uses. Integrity is not re-checked here
# (that is POST /verify); this is the scoped, queryable view.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./identity" as identity

import "./registry" as reg

# A raw trail event row (mirrors lex-trail's events table columns).
type EvRow = { id :: Str, kind :: Str, parent :: Option[Str], payload_json :: Str, ts_ms :: Int }

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

# The agent ids owned by an org (its tenant slice of the registry). This is the
# tenant boundary: an account can only ever see events for these agents.
fn org_agent_ids(db :: Db, org :: Str) -> [sql, fs_read] List[Str] {
  match reg.list_by_tenant(db, org) {
    Err(_) => [],
    Ok(refs) => list.map(refs, fn (a :: reg.AgentRef) -> Str {
      a.id
    }),
  }
}

fn in_set(ids :: List[Str], want :: Str) -> Bool {
  list.fold(ids, false, fn (acc :: Bool, id :: Str) -> Bool {
    acc or id == want
  })
}

# (payload_json LIKE '%"agent":"a1"%' OR …) — matches events acted by any of ids.
fn agent_where(ids :: List[Str]) -> Str {
  let parts := list.map(ids, fn (id :: Str) -> Str {
    str.join(["payload_json LIKE '%\"agent\":\"", sq(id), "\"%'"], "")
  })
  str.join(["(", str.join(parts, " OR "), ")"], "")
}

# Scoped, newest-first events for a set of agents, optionally filtered by kind.
fn query_events(db :: Db, ids :: List[Str], kind_filter :: Str) -> [sql, fs_read] List[EvRow] {
  if list.is_empty(ids) {
    []
  } else {
    let kind_clause := if str.is_empty(kind_filter) {
      ""
    } else {
      str.join([" AND kind='", sq(kind_filter), "'"], "")
    }
    let q := str.join(["SELECT id, kind, parent, payload_json, ts_ms FROM events WHERE ", agent_where(ids), kind_clause, " ORDER BY ts_ms DESC LIMIT 500"], "")
    let rows :: Result[List[EvRow], SqlError] := sql.query(db, q, [])
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

fn ev_json(r :: EvRow) -> jv.Json {
  let payload := match jv.parse(r.payload_json) {
    Ok(j) => j,
    Err(_) => JStr(r.payload_json),
  }
  let parent_j := match r.parent {
    Some(p) => JStr(p),
    None => JNull,
  }
  JObj([("id", JStr(r.id)), ("kind", JStr(r.kind)), ("parent", parent_j), ("ts_ms", JInt(r.ts_ms)), ("payload", payload)])
}

# Resolve the requesting subject, scope to its org's agents (or a single ?agent=
# that must belong to the org), optionally filter by ?kind=, and return the events.
fn events_response(db :: Db, secret :: Bytes, c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject(db, secret, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"audit lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => {
        let all_ids := org_agent_ids(db, subj.org)
        let want := ctx.query_param_or(c, "agent", "")
        let ids := if str.is_empty(want) {
          all_ids
        } else {
          if in_set(all_ids, want) {
            [want]
          } else {
            []
          }
        }
        let rows := query_events(db, ids, ctx.query_param_or(c, "kind", ""))
        resp.json(jv.stringify(JObj([("org", JStr(subj.org)), ("account", JStr(subj.account)), ("count", JInt(list.len(rows))), ("events", JList(list.map(rows, ev_json)))])))
      },
    },
  }
}

# Host opt-in: mount the tenant-scoped audit routes. `secret` is the same
# federation secret credentials were issued under (identity.resolve_subject).
fn mount(r :: router.Router, db :: Db, secret :: Bytes) -> router.Router {
  router.route_effectful(r, "GET", "/audit/events", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    events_response(db, secret, c)
  })
}

