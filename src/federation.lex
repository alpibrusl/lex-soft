# src/federation.lex — domain-agnostic A2A federation core.
#
# This is the platform layer that turns any lex-soft deployment into a
# discoverable, federatable A2A node — independent of what domain its agents
# serve. It is the inter-org federation counterpart to platform/server.lex
# (which is the intra-org coordination hub); the two are unrelated layers.
#
# A domain pack (trucks, energy, robotics, …) mounts its personas with
# `mount_agent` and then calls `mount_federation` once to expose:
#   GET  /.well-known/agent-key.json       — published ed25519 identity key
#   GET  /.well-known/agent-identity.json  — signed identity assertion
#   GET  /.well-known/agents.json          — this node's AgentCards (discovery)
#   GET  /peers                            — list local registry
#   POST /peers                            — self-onboard a partner agent
#   POST /connections                      — onboard agents + mint a conn token
#   GET  /directory                        — capability directory (all orgs)
#   POST /directory                        — publish/refresh an org entry
#   GET  /directory/find?capability=…      — discover orgs by capability
#
# Nothing here is domain-specific: the core never imports a pack. Per-deployment
# identity/secret/org config is supplied by the caller via FederationConfig.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.map" as map

import "std.crypto" as crypto

import "std.time" as time

import "lex-crypto/src/ed25519" as ed

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-agent/src/server" as srv

import "./registry" as reg

import "./relationships" as rel

import "./trace" as trace

import "./matchmaking" as mm

import "./partner_auth" as pa

import "./settlement" as settlement

import "lex-trail/log" as tlog

import "./conn_token" as conn_token

import "./identity" as identity

import "./trust" as trust

import "./metering" as metering

import "./notifications" as notifications

# Per-deployment federation configuration. Supplied by the host (a domain pack's
# boot); the core derives nothing from the environment itself.
#   base         public base URL of this deployment
#   org          our org id (issuer of connection tokens / identity)
#   secret       HS256 secret used to issue + verify connection tokens
#   ttl          connection-token TTL in seconds
#   sign_seed    ed25519 seed for the deployment identity (distinct from secret)
#   pub_b64      base64 ed25519 public key matching sign_seed
#   require_token  if true, inbound A2A dispatch requires a valid conn token
# `signup_token` gates onboarding (H-2): a required field so a host cannot deploy
# an OPEN credential-issuance endpoint by accident. When non-empty, POST
# /connections must present a matching `signup_token`; empty means open (dev only
# — do NOT expose an empty-token deployment to the internet). Proof-of-org
# (challenge/response against the org's published key) is the stronger, follow-on
# gate; the shared signup token stops anonymous issuance now.
type FederationConfig = { base :: Str, org :: Str, secret :: Bytes, ttl :: Int, sign_seed :: Bytes, pub_b64 :: Str, require_token :: Bool, signup_token :: Str }

# ── JSON helpers ──────────────────────────────────────────────────────────────
fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn json_str_list(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(xs)) => list.fold(xs, [], fn (acc :: List[Str], x :: jv.Json) -> List[Str] {
      match x {
        JStr(s) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
}

# ── Connection tokens (HS256) ─────────────────────────────────────────────────
# Thin wrappers over conn_token.lex, kept here for API compatibility (external
# code may call fed.issue_conn_token/verify_conn_token). The primitives moved
# out to conn_token.lex so identity.lex can mint them without importing this
# module — federation.lex needs to import identity.lex for #62.
fn issue_conn_token(secret :: Bytes, our_org :: Str, partner_org :: Str, scope :: Str, ttl :: Int, jti :: Str, now :: Int) -> Str {
  conn_token.issue(secret, our_org, partner_org, scope, ttl, jti, now)
}

fn verify_conn_token(secret :: Bytes, presented :: Str) -> [time] Bool {
  conn_token.verify(secret, presented)
}

fn token_contract(token :: Str, org :: Str, scope :: Str) -> Str {
  jv.stringify(JObj([("org", JStr(org)), ("scope", JStr(scope)), ("token", JStr(token))]))
}

# ── Onboarding rate limit (#62) ────────────────────────────────────────────────
# A best-effort, fixed-window guard on POST /connections: at most
# `max_per_hour` onboarding attempts per requesting org per hour-bucket
# (now_str's ISO date+hour prefix, e.g. "2026-07-07T07"). Not a security
# boundary (an attacker can pick a new `org` value freely) — it exists to stop
# a single misbehaving/looping caller from hammering credential issuance.
fn max_per_hour() -> Int {
  20
}

fn hour_bucket(now_str :: Str) -> Str {
  str.slice(now_str, 0, 13)
}

# Bump this org's counter for the current hour and report whether it is still
# within budget. Fails CLOSED on a storage error (M-1): a rate-limit that can't
# be evaluated must deny, not wave the request through — returning 429 is safer
# than issuing credentials under DB pressure (the flood's own feedback loop).
# NOTE: still keyed on the caller-supplied `org`; keying off source IP/identity
# needs the transport to expose it (ctx has no header accessor today) and is a
# follow-on. A global issuance ceiling is a further backstop.
fn rate_limited(db :: Db, req_org :: Str, now_str :: Str) -> [sql, fs_read, fs_write] Bool {
  let w := hour_bucket(now_str)
  let ins := "INSERT INTO connection_rate (org, \"window\", count) VALUES (?, ?, 1) ON CONFLICT(org, \"window\") DO UPDATE SET count = connection_rate.count + 1"
  match sql.exec(db, ins, [PStr(req_org), PStr(w)]) {
    Err(_) => true,
    Ok(_) => {
      let sel := "SELECT count FROM connection_rate WHERE org=? AND \"window\"=?"
      let rows :: Result[List[{ count :: Int }], SqlError] := sql.query(db, sel, [PStr(req_org), PStr(w)])
      match rows {
        Err(_) => true,
        Ok(rs) => match list.head(rs) {
          None => true,
          Some(r) => r.count > max_per_hour(),
        },
      }
    },
  }
}

fn rate_limited_response() -> resp.Response {
  { status: 429, body: "{\"error\":\"too many onboarding attempts for this org this hour, try again later\"}", headers: map.from_list([("content-type", "application/json")]) }
}

# H-2: onboarding refused for lack of a valid signup token.
fn signup_refused_response() -> resp.Response {
  { status: 401, body: "{\"error\":\"onboarding requires a valid signup_token\"}", headers: map.from_list([("content-type", "application/json")]) }
}

# L-2: the credential store failed — fail the request rather than issue an
# unrevocable, unattributable token. The caller should retry.
fn credential_error_response() -> resp.Response {
  { status: 503, body: "{\"error\":\"could not issue an audit-resolvable credential right now; please retry\"}", headers: map.from_list([("content-type", "application/json")]) }
}

# The body of POST /connections once the rate-limit gate passes: register the
# onboarding org's agents, cache its partner key, and mint the connection token
# AS AN AUDIT-RESOLVABLE CREDENTIAL (#62) — one identity.Account per org
# (upserted, idempotent) and one identity.credentials row per issuance, so
# GET /audit/events can later resolve this org's calls back to an account
# (identity.resolve_subject). Falls back to a raw, unrecorded conn_token.issue
# only if the credential bookkeeping insert itself fails — onboarding must not
# hard-fail on that, but the fallback path is NOT audit-resolvable.
fn quota_exceeded_response() -> resp.Response {
  { status: 403, body: "{\"error\":\"this org's plan quota is exhausted — cannot onboard more agents until usage resets or the plan is upgraded\"}", headers: map.from_list([("content-type", "application/json")]) }
}

# Look up the org's EXISTING account (if any) without touching it — used to
# decide both the quota check and whether to create a fresh account, so a
# repeat onboarding call never clobbers a plan that was upgraded out-of-band
# (identity.create_account's upsert always overwrites `plan`, so calling it
# unconditionally here would silently downgrade an upgraded org back to free).
fn onboard_connection(db :: Db, cfg :: FederationConfig, org :: Str, base :: Str, j :: jv.Json, req_org :: Str) -> [sql, fs_read, fs_write, time, random] resp.Response {
  let existing := identity.get_account(db, req_org)
  let plan := match existing {
    Ok(Some(a)) => a.plan,
    _ => "free",
  }
  let over_quota := match existing {
    Ok(Some(_)) => metering.over_quota(db, req_org, plan),
    _ => false,
  }
  if over_quota {
    let __notify := notifications.enqueue(db, req_org, "quota.breach", jv.stringify(JObj([("org", JStr(req_org)), ("plan", JStr(plan))])))
    quota_exceeded_response()
  } else {
    let scope := jstr(j, "scope")
    let link_from := jstr(j, "link_from")
    let role := if str.is_empty(jstr(j, "role")) {
      "peer"
    } else {
      jstr(j, "role")
    }
    let caller_token := jstr(j, "token")
    let contract0 := token_contract(caller_token, req_org, scope)
    let level := jstr(j, "trust_level")
    let contract := if str.is_empty(level) {
      contract0
    } else {
      trust.with_level(contract0, level)
    }
    let agents := match jv.get_field(j, "agents") {
      Some(JList(xs)) => xs,
      _ => [],
    }
    let __regs := list.fold(agents, (), fn (_acc :: Unit, aj :: jv.Json) -> [sql, fs_write, time, random] Unit {
      register_peer_json(db, aj, req_org, link_from, role, contract)
    })
    let partner_key := jstr(j, "public_key")
    let __pk := if str.is_empty(partner_key) {
      Ok(())
    } else {
      pa.cache_key(db, req_org, partner_key)
    }
    let __acct := match existing {
      Ok(Some(_)) => (),
      _ => {
        let __c := identity.create_account(db, req_org, req_org, req_org, "free")
        ()
      },
    }
    match identity.issue_credential(db, cfg.secret, org, req_org, req_org, "", scope, cfg.ttl) {
      Err(_) => credential_error_response(),
      Ok(ic) => {
        let __ev := tlog.append(settlement.trail_on(db), "credential.issued", None, jv.stringify(JObj([("agent", JStr(req_org)), ("org", JStr(req_org)), ("scope", JStr(scope)), ("registered", JInt(list.len(agents)))])))
        resp.json(jv.stringify(JObj([("ok", JBool(true)), ("org", JStr(org)), ("scope", JStr(scope)), ("registered", JInt(list.len(agents))), ("token", JStr(ic.token)), ("agents", JList(list.map(registry_refs(db), fn (a :: reg.AgentRef) -> jv.Json {
          agentref_json(a, base)
        })))])))
      },
    }
  }
}

fn unauthorized_response() -> resp.Response {
  { status: 401, body: "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32099,\"message\":\"unauthorized: missing or invalid connection token\"}}", headers: map.from_list([("content-type", "application/json")]) }
}

fn forbidden_response() -> resp.Response {
  { status: 403, body: "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32098,\"message\":\"forbidden: no relationship contract grants this capability\"}}", headers: map.from_list([("content-type", "application/json")]) }
}

# ── Registry → JSON ───────────────────────────────────────────────────────────
fn agentref_json(a :: reg.AgentRef, base :: Str) -> jv.Json {
  JObj([("id", JStr(a.id)), ("kind", JStr(a.kind)), ("name", JStr(a.name)), ("status", JStr(a.status)), ("tenant", JStr(a.tenant)), ("inbox_url", JStr(a.inbox_url)), ("card_url", JStr(str.concat(base, str.concat("/agents/", str.concat(a.id, "/.well-known/agent.json"))))), ("a2a_url", JStr(str.concat(base, str.concat("/agents/", str.concat(a.id, "/"))))), ("capabilities", JList(list.map(a.capabilities, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))])
}

fn render_agents(refs :: List[reg.AgentRef], base :: Str) -> Str {
  jv.stringify(JObj([("agents", JList(list.map(refs, fn (a :: reg.AgentRef) -> jv.Json {
    agentref_json(a, base)
  })))]))
}

fn registry_json(db :: Db, base :: Str) -> [sql, fs_read] Str {
  match reg.list_all(db) {
    Err(_) => "{\"agents\":[]}",
    Ok(refs) => render_agents(refs, base),
  }
}

# Tenant-scoped catalog (#26): only the named tenant's agents. This is the
# "sees" half of the tenant boundary at the discovery routes — `?tenant=` on
# the catalog / peers list. (Production should bind the tenant to the
# authenticated caller rather than trust an open query param; this filter is the
# additive mechanism that makes scoped discovery available.)
fn registry_json_tenant(db :: Db, base :: Str, tenant :: Str) -> [sql, fs_read] Str {
  match reg.list_by_tenant(db, tenant) {
    Err(_) => "{\"agents\":[]}",
    Ok(refs) => render_agents(refs, base),
  }
}

# Pick the scoped catalog when `?tenant=` is present, else the full one.
fn catalog_for(db :: Db, base :: Str, tenant :: Str) -> [sql, fs_read] Str {
  if str.is_empty(tenant) {
    registry_json(db, base)
  } else {
    registry_json_tenant(db, base, tenant)
  }
}

fn registry_refs(db :: Db) -> [sql, fs_read] List[reg.AgentRef] {
  match reg.list_all(db) {
    Ok(rs) => rs,
    Err(_) => [],
  }
}

# Register one agent (from a JSON object {id,kind,name,inbox_url,capabilities})
# into the local registry, optionally adding a relationship edge so `link_from`
# may call it. The shared effector behind POST /peers and POST /connections.
# `tenant` scopes the agent to its owning org (the #26 multi-tenant boundary) so
# per-org discovery / audit / usage (which key off `agent.tenant == org`) include
# it. Empty tenant falls back to "default" — preserves the pre-tenant behaviour
# for any caller that doesn't supply an org.
fn register_peer_json(db :: Db, aj :: jv.Json, tenant :: Str, link_from :: Str, role :: Str, contract :: Str) -> [sql, fs_write, time, random] Unit {
  let id := jstr(aj, "id")
  if str.is_empty(id) {
    ()
  } else {
    let kind := if str.is_empty(jstr(aj, "kind")) {
      "external"
    } else {
      jstr(aj, "kind")
    }
    let name := if str.is_empty(jstr(aj, "name")) {
      id
    } else {
      jstr(aj, "name")
    }
    let inbox_url := jstr(aj, "inbox_url")
    let caps := json_str_list(aj, "capabilities")
    let t := if str.is_empty(tenant) {
      "default"
    } else {
      tenant
    }
    match reg.register_in(db, t, id, kind, name, inbox_url, caps) {
      Err(_) => (),
      Ok(_) => if str.is_empty(link_from) {
        ()
      } else {
        if str.is_empty(role) {
          ()
        } else {
          match rel.add(db, link_from, id, role, contract) {
            _ => (),
          }
        }
      },
    }
  }
}

# ── Agent mount ───────────────────────────────────────────────────────────────
# Mount an agent onto the router at /agents/:id/.well-known/agent.json (GET,
# pure) and /agents/:id/ (POST, effectful A2A dispatch), plus activity/remember.
# Generic over the agent's domain — `agent_def` carries the persona/tools.
fn mount_agent(r :: router.Router, db :: Db, agent_def :: srv.AgentDef, agent_id :: Str, cfg :: FederationConfig) -> router.Router {
  let card_path := str.concat("/agents/", str.concat(agent_id, "/.well-known/agent.json"))
  let rpc_path := str.concat("/agents/", str.concat(agent_id, "/"))
  let activity_path := str.concat("/agents/", str.concat(agent_id, "/activity"))
  let remember_path := str.concat("/agents/", str.concat(agent_id, "/remember"))
  let card_body := srv.agent_card_response(agent_def)
  let with_card := router.route(r, "GET", card_path, fn (_c :: ctx.Ctx) -> resp.Response {
    { status: 200, body: card_body, headers: map.from_list([("content-type", "application/json")]) }
  })
  let with_rpc := router.route_effectful(with_card, "POST", rpc_path, fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    if str.is_empty(c.body) {
      resp.bad_request("{\"error\":\"empty body\"}")
    } else {
      let tok := match ctx.bearer_token(c) {
        Some(s) => s,
        None => "",
      }
      let authed := if str.is_empty(tok) {
        not cfg.require_token
      } else {
        match identity.resolve_subject(db, cfg.secret, tok) {
          Ok(Some(_)) => true,
          _ => pa.verify(db, tok),
        }
      }
      if authed {
        let from_agent := ctx.header_or(c, "x-from-agent", "")
        let capability := ctx.header_or(c, "x-capability", "")
        let gated_ok := if str.is_empty(from_agent) {
          true
        } else {
          rel.grants(db, from_agent, agent_id, capability)
        }
        if gated_ok {
          resp.json(srv.dispatch_request(agent_def, c.body))
        } else {
          forbidden_response()
        }
      } else {
        unauthorized_response()
      }
    }
  })
  let with_activity := router.route_effectful(with_rpc, "GET", activity_path, fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(trace.recent_by_agent(db, agent_id, 60))
  })
  let with_remember := router.route_effectful(with_activity, "POST", remember_path, fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let bodyj := match jv.parse(c.body) {
      Ok(j) => j,
      Err(_) => JNull,
    }
    let sfield := fn (k :: Str) -> Str {
      match jv.get_field(bodyj, k) {
        Some(JStr(s)) => s,
        _ => "",
      }
    }
    let fact := sfield("fact")
    if str.is_empty(str.trim(fact)) {
      resp.bad_request("{\"error\":\"fact is required\"}")
    } else {
      let __r := trace.remember_kv(db, agent_id, sfield("scope"), sfield("key"), fact, sfield("type"), sfield("importance"), sfield("expires_at"))
      resp.json("{\"ok\":true}")
    }
  })
  router.route_effectful(with_remember, "GET", remember_path, fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(str.concat("{\"agent\":\"", str.concat(agent_id, str.concat("\",\"memory\":", str.concat(trace.recall_memory_json(db, agent_id, 50), "}")))))
  })
}

# ── Capability directory ──────────────────────────────────────────────────────
# A cross-org index (org → catalog_url + capabilities + published key) so a
# deployment can discover partners it does NOT already know, by capability. It
# indexes ENDPOINTS, not data — each org's catalog/identity stay decentralized.
type DirRow = { org :: Str, catalog_url :: Str, capabilities :: Str, public_key :: Str }

fn init_directory(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS org_directory (org TEXT PRIMARY KEY, catalog_url TEXT NOT NULL, capabilities TEXT NOT NULL DEFAULT '[]', public_key TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '')", []) {
    Err(e) => Err(e.message),
    Ok(_) => pa.init(db),
  }
}

fn dir_query(db :: Db, where_sql :: Str) -> [sql, fs_read] List[DirRow] {
  let q := str.concat("SELECT org, catalog_url, capabilities, public_key FROM org_directory ", str.concat(where_sql, " ORDER BY org"))
  let rows :: Result[List[DirRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn dir_to_json(r :: DirRow) -> jv.Json {
  let caps := match jv.parse(r.capabilities) {
    Ok(JList(items)) => JList(items),
    _ => JList([]),
  }
  JObj([("org", JStr(r.org)), ("catalog_url", JStr(r.catalog_url)), ("capabilities", caps), ("public_key", JStr(r.public_key))])
}

fn dir_list_json(rows :: List[DirRow]) -> Str {
  jv.stringify(JObj([("orgs", JList(list.map(rows, fn (r :: DirRow) -> jv.Json {
    dir_to_json(r)
  })))]))
}

# ── Federated publication (#26) ───────────────────────────────────────────────
# The cross-domain directory is fed by peers PUBLISHING their own catalog —
# their `/.well-known/agents.json` (the same document `mount_federation` serves)
# — rather than a central crawler. (In-process serve handlers can't make
# outbound calls, so PUSH is also the only viable federated model here; this
# settles the roadmap's central-vs-federated question in favor of federated.)
# We derive the org's advertised capabilities from the union of its agents'
# capabilities, so an org never hand-maintains a separate capability list.
fn caps_from_catalog(catalog :: jv.Json) -> List[Str] {
  let agents := match jv.get_field(catalog, "agents") {
    Some(JList(items)) => items,
    _ => [],
  }
  list.fold(agents, [], fn (acc :: List[Str], a :: jv.Json) -> List[Str] {
    match jv.get_field(a, "capabilities") {
      Some(JList(caps)) => list.fold(caps, acc, fn (inner :: List[Str], cj :: jv.Json) -> List[Str] {
        match cj {
          JStr(s) => if list.fold(inner, false, fn (seen :: Bool, x :: Str) -> Bool {
            seen or x == s
          }) {
            inner
          } else {
            list.concat(inner, [s])
          },
          _ => inner,
        }
      }),
      _ => acc,
    }
  })
}

# Upsert one org's directory row from its published catalog. Pure SQL — safe to
# call from a serve handler (no outbound HTTP).
fn index_catalog(db :: Db, org :: Str, catalog_url :: Str, public_key :: Str, caps :: List[Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  let caps_json := jv.stringify(JList(list.map(caps, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))
  let now := time.now_str()
  let q := "INSERT INTO org_directory (org, catalog_url, capabilities, public_key, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(org) DO UPDATE SET catalog_url=excluded.catalog_url, capabilities=excluded.capabilities, public_key=excluded.public_key, updated_at=excluded.updated_at"
  match sql.exec(db, q, [PStr(org), PStr(catalog_url), PStr(caps_json), PStr(public_key), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Typed capability matchmaking (see matchmaking.lex) ────────────────────────
# Project directory rows into the (org, parsed-capabilities) entries the
# matchmaker consumes, and look an org's row back up to enrich a match.
fn dir_entries(rows :: List[DirRow]) -> List[mm.OrgCaps] {
  list.map(rows, fn (r :: DirRow) -> mm.OrgCaps {
    let caps := match jv.parse(r.capabilities) {
      Ok(j) => j,
      Err(_) => JList([]),
    }
    { org: r.org, caps: caps }
  })
}

fn find_row(rows :: List[DirRow], org :: Str) -> Option[DirRow] {
  list.fold(rows, None, fn (acc :: Option[DirRow], r :: DirRow) -> Option[DirRow] {
    match acc {
      Some(_) => acc,
      None => if r.org == org {
        Some(r)
      } else {
        None
      },
    }
  })
}

fn match_detail_json(rows :: List[DirRow], m :: mm.Match) -> jv.Json {
  match find_row(rows, m.org) {
    Some(r) => JObj([("org", JStr(m.org)), ("capability", JStr(m.capability)), ("score", JInt(m.score)), ("catalog_url", JStr(r.catalog_url)), ("public_key", JStr(r.public_key))]),
    None => JObj([("org", JStr(m.org)), ("capability", JStr(m.capability)), ("score", JInt(m.score))]),
  }
}

# ── Federation routes ─────────────────────────────────────────────────────────
# Mount the full federation surface onto an existing router. Call once, after a
# domain pack has mounted its agents with `mount_agent`.
fn mount_federation(r :: router.Router, db :: Db, cfg :: FederationConfig) -> router.Router {
  let base := cfg.base
  let org := cfg.org
  let with_key := router.route(r, "GET", "/.well-known/agent-key.json", fn (_c :: ctx.Ctx) -> resp.Response {
    { status: 200, body: jv.stringify(JObj([("org", JStr(org)), ("alg", JStr("ed25519")), ("public_key", JStr(cfg.pub_b64))])), headers: map.from_list([("content-type", "application/json")]) }
  })
  let with_identity := router.route_effectful(with_key, "GET", "/.well-known/agent-identity.json", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let payload := str.join([org, "|", base, "|", cfg.pub_b64], "")
    let sig := match ed.sign_text(cfg.sign_seed, payload) {
      Ok(s) => s,
      Err(_) => "",
    }
    resp.json(jv.stringify(JObj([("org", JStr(org)), ("base_url", JStr(base)), ("alg", JStr("ed25519")), ("public_key", JStr(cfg.pub_b64)), ("payload", JStr(payload)), ("signature", JStr(sig))])))
  })
  let with_catalog := router.route_effectful(with_identity, "GET", "/.well-known/agents.json", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(catalog_for(db, base, ctx.query_param_or(c, "tenant", "")))
  })
  let with_list := router.route_effectful(with_catalog, "GET", "/peers", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(catalog_for(db, base, ctx.query_param_or(c, "tenant", "")))
  })
  let with_peers := router.route_effectful(with_list, "POST", "/peers", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let id := jstr(j, "id")
        let inbox_url := jstr(j, "inbox_url")
        if str.is_empty(id) {
          resp.bad_request("{\"error\":\"id is required\"}")
        } else {
          if str.is_empty(inbox_url) {
            resp.bad_request("{\"error\":\"inbox_url is required\"}")
          } else {
            let peer_contract0 := token_contract(jstr(j, "token"), "", "")
            let peer_level := jstr(j, "trust_level")
            let peer_contract := if str.is_empty(peer_level) {
              peer_contract0
            } else {
              trust.with_level(peer_contract0, peer_level)
            }
            let __r := register_peer_json(db, j, jstr(j, "org"), jstr(j, "from_agent"), jstr(j, "role"), peer_contract)
            resp.json(str.concat("{\"ok\":true,\"peer\":", str.concat(jv.stringify(JStr(id)), "}")))
          }
        }
      },
    }
  })
  let with_conn := router.route_effectful(with_peers, "POST", "/connections", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let req_org := jstr(j, "org")
        if not str.is_empty(cfg.signup_token) and jstr(j, "signup_token") != cfg.signup_token {
          signup_refused_response()
        } else {
          if rate_limited(db, req_org, time.now_str()) {
            rate_limited_response()
          } else {
            onboard_connection(db, cfg, org, base, j, req_org)
          }
        }
      },
    }
  })
  let with_dir_post := router.route_effectful(with_conn, "POST", "/directory", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let d_org := jstr(j, "org")
        let catalog_url := jstr(j, "catalog_url")
        if str.is_empty(d_org) {
          resp.bad_request("{\"error\":\"org is required\"}")
        } else {
          if str.is_empty(catalog_url) {
            resp.bad_request("{\"error\":\"catalog_url is required\"}")
          } else {
            let caps_json := match jv.get_field(j, "capabilities") {
              Some(JList(items)) => jv.stringify(JList(items)),
              _ => "[]",
            }
            let now := time.now_str()
            let q := "INSERT INTO org_directory (org, catalog_url, capabilities, public_key, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(org) DO UPDATE SET catalog_url=excluded.catalog_url, capabilities=excluded.capabilities, public_key=excluded.public_key, updated_at=excluded.updated_at"
            match sql.exec(db, q, [PStr(d_org), PStr(catalog_url), PStr(caps_json), PStr(jstr(j, "public_key")), PStr(now)]) {
              Err(e) => resp.json(str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
              Ok(_) => resp.json(str.concat("{\"ok\":true,\"org\":", str.concat(jv.stringify(JStr(d_org)), "}"))),
            }
          }
        }
      },
    }
  })
  let with_dir_publish := router.route_effectful(with_dir_post, "POST", "/directory/publish", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let d_org := jstr(j, "org")
        let catalog_url := jstr(j, "catalog_url")
        if str.is_empty(d_org) {
          resp.bad_request("{\"error\":\"org is required\"}")
        } else {
          if str.is_empty(catalog_url) {
            resp.bad_request("{\"error\":\"catalog_url is required\"}")
          } else {
            let catalog := match jv.get_field(j, "catalog") {
              Some(cat) => cat,
              None => JObj([]),
            }
            let caps := caps_from_catalog(catalog)
            match index_catalog(db, d_org, catalog_url, jstr(j, "public_key"), caps) {
              Err(e) => resp.json(str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(_) => resp.json(str.concat("{\"ok\":true,\"org\":", str.concat(jv.stringify(JStr(d_org)), str.concat(",\"capabilities\":", str.concat(int.to_str(list.len(caps)), "}"))))),
            }
          }
        }
      },
    }
  })
  let with_dir_list := router.route_effectful(with_dir_publish, "GET", "/directory", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(dir_list_json(dir_query(db, "")))
  })
  let with_dir_find := router.route_effectful(with_dir_list, "GET", "/directory/find", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let cap := ctx.query_param_or(c, "capability", "")
    let rows := dir_query(db, "")
    let matched_rows := if str.is_empty(cap) {
      rows
    } else {
      list.fold(mm.find(dir_entries(rows), mm.exact_query(cap)), [], fn (acc :: List[DirRow], m :: mm.Match) -> List[DirRow] {
        match find_row(rows, m.org) {
          Some(r) => list.concat(acc, [r]),
          None => acc,
        }
      })
    }
    resp.json(jv.stringify(JObj([("capability", JStr(cap)), ("orgs", JList(list.map(matched_rows, fn (rr :: DirRow) -> jv.Json {
      dir_to_json(rr)
    })))])))
  })
  let with_find_post := router.route_effectful(with_dir_find, "POST", "/directory/find", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let q := mm.parse_query(j)
        if str.is_empty(q.capability) {
          resp.bad_request("{\"error\":\"capability is required\"}")
        } else {
          let rows := dir_query(db, "")
          let matches := mm.find(dir_entries(rows), q)
          resp.json(jv.stringify(JObj([("capability", JStr(q.capability)), ("matches", JList(list.map(matches, fn (m :: mm.Match) -> jv.Json {
            match_detail_json(rows, m)
          })))])))
        }
      },
    }
  })
  router.route_effectful(with_find_post, "GET", "/trails/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    if str.is_empty(id) {
      resp.bad_request("{\"error\":\"trail id is required\"}")
    } else {
      resp.json(settlement.report_json(settlement.trail_on(db), id))
    }
  })
}

