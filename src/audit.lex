# audit.lex — tenant-scoped audit over the settlement trail (#60).
#
# The settlement trail (settlement.lex) already records every task run as a
# hash-chained, tamper-evident event. This exposes it as a CUSTOMER-facing audit
# surface: a caller presents its agent credential (identity.lex), and only ever
# sees the events belonging to its own org's agents — never another tenant's.
#
#   GET /audit/events[?agent=&kind=&before_ts_ms=]        — this org's trail events
#   GET /audit/interactions[?agent=&before_ts_ms=]        — per-run rollup + tamper check
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

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/kinds" as kinds

import "./identity" as identity

import "./registry" as reg

import "lex-trail/log" as tlog

import "./settlement" as settlement

import "lex-crypto/src/ed25519" as ed

# A raw trail event row (mirrors lex-trail's events table columns).
type EvRow = { id :: Str, kind :: Str, parent :: Str, payload_json :: Str, ts_ms :: Int }

# A SQL fragment together with the parameters its `?` placeholders bind, so a
# dynamically-built WHERE can be passed to sql.query without concatenating any
# caller value into the query text.
type WhereClause = { clause :: Str, params :: List[SqlParam] }

# The agent ids owned by an org (its tenant slice of the registry). This is the
# tenant boundary: an account can only ever see events for these agents.
# A registry failure is propagated, NOT flattened to []: an audit surface that
# renders "no events" when the lookup actually failed silently under-reports,
# which is the one thing an audit trail must never do (M-2).
fn org_agent_ids(db :: Db, org :: Str) -> [sql, fs_read] Result[List[Str], Str] {
  match reg.list_by_tenant(db, org) {
    Err(e) => Err(e),
    Ok(refs) => Ok(list.map(refs, fn (a :: reg.AgentRef) -> Str {
      a.id
    })),
  }
}

fn in_set(ids :: List[Str], want :: Str) -> Bool {
  list.fold(ids, false, fn (acc :: Bool, id :: Str) -> Bool {
    acc or id == want
  })
}

# (payload_json LIKE '%"agent":"a1"%' OR …) — matches events acted by any of
# ids. Checks BOTH `"agent"` (settlement/arm events) and `"from_agent"`
# (escalation.requested — human_gateway.request uses that key, not "agent")
# so an org's escalations aren't silently invisible to its own audit/usage
# queries. Fixed here rather than left as a #60 follow-up since #61's usage
# counters depend on it being correct.
fn agent_where(ids :: List[Str]) -> WhereClause {
  let parts := list.map(ids, fn (_id :: Str) -> Str {
    "(payload_json LIKE ? OR payload_json LIKE ?)"
  })
  let params := list.fold(ids, [], fn (acc :: List[SqlParam], id :: Str) -> List[SqlParam] {
    list.concat(acc, [PStr(str.join(["%\"agent\":\"", id, "\"%"], "")), PStr(str.join(["%\"from_agent\":\"", id, "\"%"], ""))])
  })
  { clause: str.join(["(", str.join(parts, " OR "), ")"], ""), params: params }
}

# Page size for both /audit/events and /audit/interactions.
fn page_size() -> Int {
  100
}

# Scoped, newest-first events for a set of agents, optionally filtered by kind
# and/or paged with a `before_ts_ms` cursor (strictly older than the cursor —
# pass the previous page's oldest `ts_ms` to fetch the next page).
fn query_events(db :: Db, ids :: List[Str], kind_filter :: Str, before_ts_ms :: Option[Int]) -> [sql, fs_read] List[EvRow] {
  if list.is_empty(ids) {
    []
  } else {
    let aw := agent_where(ids)
    let kind_clause := if str.is_empty(kind_filter) {
      ""
    } else {
      " AND kind=?"
    }
    let kind_params := if str.is_empty(kind_filter) {
      []
    } else {
      [PStr(kind_filter)]
    }
    let cursor_clause := match before_ts_ms {
      None => "",
      Some(ts) => str.join([" AND ts_ms < ", int.to_str(ts)], ""),
    }
    let q := str.join(["SELECT id, kind, COALESCE(parent, '') AS parent, payload_json, ts_ms FROM events WHERE ", aw.clause, kind_clause, cursor_clause, " ORDER BY ts_ms DESC LIMIT ", int.to_str(page_size())], "")
    let rows :: Result[List[EvRow], SqlError] := sql.query(db, q, list.concat(aw.params, kind_params))
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

# Like query_events but with a caller-chosen cap (the export wants one big
# page, not the interactive page size).
fn collect_events(db :: Db, ids :: List[Str], kind_filter :: Str, before_ts_ms :: Option[Int], cap :: Int) -> [sql, fs_read] List[EvRow] {
  if list.is_empty(ids) {
    []
  } else {
    let aw := agent_where(ids)
    let kind_clause := if str.is_empty(kind_filter) {
      ""
    } else {
      " AND kind=?"
    }
    let kind_params := if str.is_empty(kind_filter) {
      []
    } else {
      [PStr(kind_filter)]
    }
    let cursor_clause := match before_ts_ms {
      None => "",
      Some(ts) => str.join([" AND ts_ms < ", int.to_str(ts)], ""),
    }
    let q := str.join(["SELECT id, kind, COALESCE(parent, '') AS parent, payload_json, ts_ms FROM events WHERE ", aw.clause, kind_clause, cursor_clause, " ORDER BY ts_ms DESC LIMIT ", int.to_str(cap)], "")
    let rows :: Result[List[EvRow], SqlError] := sql.query(db, q, list.concat(aw.params, kind_params))
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

fn parse_cursor(c :: ctx.Ctx) -> Option[Int] {
  let raw := ctx.query_param_or(c, "before_ts_ms", "")
  if str.is_empty(raw) {
    None
  } else {
    str.to_int(raw)
  }
}

# The cursor to pass as `before_ts_ms` to fetch the NEXT (older) page, or None
# when this page was short of a full page (nothing older left to fetch).
fn next_cursor(rows :: List[EvRow]) -> Option[Int] {
  if list.len(rows) < page_size() {
    None
  } else {
    match list.head(list.reverse(rows)) {
      None => None,
      Some(r) => Some(r.ts_ms),
    }
  }
}

# The agent ids to query for a request: the whole org, or a single ?agent=
# that must actually belong to the org (else empty — never leaks another org's).
fn scoped_ids(db :: Db, org :: Str, c :: ctx.Ctx) -> [sql, fs_read] Result[List[Str], Str] {
  match org_agent_ids(db, org) {
    Err(e) => Err(e),
    Ok(all_ids) => {
      let want := ctx.query_param_or(c, "agent", "")
      if str.is_empty(want) {
        Ok(all_ids)
      } else {
        if in_set(all_ids, want) {
          Ok([want])
        } else {
          Ok([])
        }
      }
    },
  }
}

fn payload_field(payload_json :: Str, key :: Str) -> Str {
  match jv.parse(payload_json) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, key) {
      Some(JStr(s)) => s,
      _ => "",
    },
  }
}

# One run's rollup: the tip (cap.completed) event plus a re-derived tamper
# check (settlement.verify — intact + linked; no domain legal-spec here, that
# stays in POST /verify since it needs a host-supplied CapSpec).
fn interaction_json(log :: tlog.Log, t :: EvRow) -> [sql] jv.Json {
  let valid := settlement.verify(log, t.id)
  JObj([("trail_id", JStr(t.id)), ("agent", JStr(payload_field(t.payload_json, "agent"))), ("skill", JStr(payload_field(t.payload_json, "skill"))), ("result", JStr(payload_field(t.payload_json, "result"))), ("ts_ms", JInt(t.ts_ms)), ("valid", JBool(valid))])
}

fn ev_json(r :: EvRow) -> jv.Json {
  let payload := match jv.parse(r.payload_json) {
    Ok(j) => j,
    Err(_) => JStr(r.payload_json),
  }
  let parent_j := if str.is_empty(r.parent) {
    JNull
  } else {
    JStr(r.parent)
  }
  JObj([("id", JStr(r.id)), ("kind", JStr(r.kind)), ("parent", parent_j), ("ts_ms", JInt(r.ts_ms)), ("payload", payload)])
}

# Resolve the requesting subject, scope to its org's agents (or a single ?agent=
# that must belong to the org), optionally filter by ?kind=, and return the events.
fn events_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"audit lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => match scoped_ids(db, subj.org, c) {
        Err(_) => resp.json_status(500, "{\"error\":\"audit scope lookup failed\"}"),
        Ok(ids) => {
          let rows := query_events(db, ids, ctx.query_param_or(c, "kind", ""), parse_cursor(c))
          let cursor_j := match next_cursor(rows) {
            None => JNull,
            Some(ts) => JInt(ts),
          }
          resp.json(jv.stringify(JObj([("org", JStr(subj.org)), ("account", JStr(subj.account)), ("count", JInt(list.len(rows))), ("next_cursor", cursor_j), ("events", JList(list.map(rows, ev_json)))])))
        },
      },
    },
  }
}

# Same scoping as /audit/events, rolled up per run (one row per cap.completed
# tip) with a re-derived tamper-evidence flag instead of the raw event triple.
fn interactions_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"audit lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => match scoped_ids(db, subj.org, c) {
        Err(_) => resp.json_status(500, "{\"error\":\"audit scope lookup failed\"}"),
        Ok(ids) => {
          let tips := query_events(db, ids, kinds.cap_completed(), parse_cursor(c))
          let log := settlement.trail_on(db)
          let cursor_j := match next_cursor(tips) {
            None => JNull,
            Some(ts) => JInt(ts),
          }
          resp.json(jv.stringify(JObj([("org", JStr(subj.org)), ("account", JStr(subj.account)), ("count", JInt(list.len(tips))), ("next_cursor", cursor_j), ("interactions", JList(list.map(tips, fn (t :: EvRow) -> [sql] jv.Json {
            interaction_json(log, t)
          })))])))
        },
      },
    },
  }
}

# Host opt-in: mount the tenant-scoped audit routes. `secret` is the same
# federation secret credentials were issued under (identity.resolve_subject).
# The export body: everything the tenant can already read, in one document —
# events (full page set up to the cap) + the interactions rollup — plus the
# export metadata. The SIGNATURE is Ed25519 over the sha256 of the canonical
# body with the DEPLOYMENT seed (the notification-webhook pattern), so any
# third party can verify the archive against /.well-known/agent-key.json
# without trusting the transport it arrived over.
fn export_cap() -> Int {
  2000
}

fn export_response(db :: Db, secrets :: List[Bytes], sign_seed :: Bytes, pub_b64 :: Str, c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"audit lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => match scoped_ids(db, subj.org, c) {
        Err(_) => resp.json_status(500, "{\"error\":\"audit scope lookup failed\"}"),
        Ok(ids) => {
          let events := collect_events(db, ids, "", None, export_cap())
          let tips := collect_events(db, ids, kinds.cap_completed(), None, export_cap())
          let log := settlement.trail_on(db)
          let interactions := list.map(tips, fn (t :: EvRow) -> [sql] jv.Json {
            interaction_json(log, t)
          })
          let body := jv.stringify(JObj([("org", JStr(subj.org)), ("account", JStr(subj.account)), ("exported_at_ms", JInt(time.now_ms())), ("event_count", JInt(list.len(events))), ("truncated", JBool(list.len(events) >= export_cap())), ("events", JList(list.map(events, ev_json))), ("interactions", JList(interactions))]))
          let digest := crypto.hex_encode(crypto.sha256(bytes.from_str(body)))
          let sig := match ed.sign_text(sign_seed, digest) {
            Ok(s) => s,
            Err(_) => "",
          }
          if str.is_empty(sig) {
            resp.json_status(500, "{\"error\":\"export signing failed\"}")
          } else {
            resp.json(jv.stringify(JObj([("archive", JStr(body)), ("sha256", JStr(digest)), ("alg", JStr("ed25519")), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))])))
          }
        },
      },
    },
  }
}

fn mount(r :: router.Router, db :: Db, secrets :: List[Bytes]) -> router.Router {
  let r_ev := router.route_effectful(r, "GET", "/audit/events", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    events_response(db, secrets, c)
  })
  router.route_effectful(r_ev, "GET", "/audit/interactions", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    interactions_response(db, secrets, c)
  })
}

# Host opt-in for the signed archive (#48): needs the deployment signing seed
# and its published key, which plain mount() deliberately doesn't take.
fn mount_export(r :: router.Router, db :: Db, secrets :: List[Bytes], sign_seed :: Bytes, pub_b64 :: Str) -> router.Router {
  router.route_effectful(r, "POST", "/audit/export", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    export_response(db, secrets, sign_seed, pub_b64, c)
  })
}

