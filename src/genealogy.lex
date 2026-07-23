# genealogy.lex — chain-of-transformations back to origin (#229).
#
# Agri-food (EUDR), provenance and similar domains need to trace a unit back
# through every transformation to a declared origin. The edges already exist in
# the trail — agri-food writes `agrifood.transformation` ({to_lot, from_lots})
# and `agrifood.origin` ({lot_ref, producer}). This is the reusable genealogy
# primitive over them: a generic recorder for new domains and a WALK that,
# given a unit, follows the parent edges back to the origins.
#
#   GET /trace/unit/:ref   — the full transformation chain for a unit, to origin
#
# The walk reads a small VOCABULARY of (transform_kind, unit_field, parents_field,
# origin_kind, …) mappings, pre-registered with agri-food's, so existing agri-food
# provenance renders with no pack change; a new domain either adopts the generic
# `genealogy.*` kinds (via record_transformation/record_origin) or registers its
# own vocab.
#
# Scope: unlike /audit and /ledger, provenance is INTENTIONALLY cross-party — the
# point of EUDR traceability is to reach the origin farm regardless of who owns
# the intermediate lots. So the walk is gated on a valid credential (any tenant)
# but returns the full chain for the requested unit; it exposes provenance
# metadata (unit ids, transformation kinds, producers, timestamps), never money
# or private payloads.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-trail/event" as ev

import "./identity" as identity

import "./audit" as audit

import "./evidence" as evidence

# How a domain names its provenance edges. A transformation event names the
# produced unit (`unit_field`) and the units it consumed (`parents_field`, a JSON
# list); an origin event declares a unit with no parents (`origin_unit_field`).
type Vocab = { transform_kind :: Str, unit_field :: Str, parents_field :: Str, origin_kind :: Str, origin_unit_field :: Str, actor_field :: Str }

fn agrifood_vocab() -> Vocab {
  { transform_kind: "agrifood.transformation", unit_field: "to_lot", parents_field: "from_lots", origin_kind: "agrifood.origin", origin_unit_field: "lot_ref", actor_field: "producer" }
}

# The generic vocabulary a new domain gets by recording via this module.
fn generic_vocab() -> Vocab {
  { transform_kind: "genealogy.transformation", unit_field: "unit", parents_field: "parents", origin_kind: "genealogy.origin", origin_unit_field: "unit", actor_field: "agent" }
}

fn vocabs() -> List[Vocab] {
  [agrifood_vocab(), generic_vocab()]
}

# Depth cap so a cyclic or pathological graph can never loop forever.
fn max_depth() -> Int {
  64
}

# The newest event of `kind` whose payload binds `field` to `value`.
fn find_by_field(db :: Db, kind :: Str, field :: Str, value :: Str) -> [sql] Option[audit.EvRow] {
  let pat := str.join(["%\"", field, "\":", jv.stringify(JStr(value)), "%"], "")
  let q := "SELECT id, kind, COALESCE(parent, '') AS parent, payload_json, ts_ms FROM events WHERE kind=? AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1"
  let rows :: Result[List[audit.EvRow], SqlError] := sql.query(db, q, [PStr(kind), PStr(pat)])
  match rows {
    Ok(rs) => list.head(rs),
    Err(_) => None,
  }
}

fn parents_of(payload_json :: Str, field :: Str) -> List[Str] {
  match jv.parse(payload_json) {
    Err(_) => [],
    Ok(j) => match jv.get_field(j, field) {
      Some(JList(xs)) => list.fold(xs, [], fn (acc :: List[Str], x :: jv.Json) -> List[Str] {
        match x {
          JStr(s) => list.concat(acc, [s]),
          _ => acc,
        }
      }),
      _ => [],
    },
  }
}

# One resolved node in a unit's genealogy: what it is, what it came from, and
# whether it is a declared origin. `parents` are the units to recurse into.
type Node = { unit :: Str, kind :: Str, source_kind :: Str, actor :: Str, parents :: List[Str], is_origin :: Bool, ts_ms :: Int, found :: Bool }

# Resolve one unit against every vocabulary: prefer a transformation (it names
# parents); otherwise an origin; otherwise an unknown leaf.
fn resolve(db :: Db, unit :: Str) -> [sql] Node {
  let via_transform := list.fold(vocabs(), None, fn (acc :: Option[Node], v :: Vocab) -> [sql] Option[Node] {
    match acc {
      Some(_) => acc,
      None => match find_by_field(db, v.transform_kind, v.unit_field, unit) {
        None => None,
        Some(r) => Some({ unit: unit, kind: audit.payload_field(r.payload_json, "kind"), source_kind: r.kind, actor: audit.payload_field(r.payload_json, v.actor_field), parents: parents_of(r.payload_json, v.parents_field), is_origin: false, ts_ms: r.ts_ms, found: true }),
      },
    }
  })
  match via_transform {
    Some(n) => n,
    None => {
      let via_origin := list.fold(vocabs(), None, fn (acc :: Option[Node], v :: Vocab) -> [sql] Option[Node] {
        match acc {
          Some(_) => acc,
          None => match find_by_field(db, v.origin_kind, v.origin_unit_field, unit) {
            None => None,
            Some(r) => Some({ unit: unit, kind: v.origin_kind, source_kind: r.kind, actor: audit.payload_field(r.payload_json, v.actor_field), parents: [], is_origin: true, ts_ms: r.ts_ms, found: true }),
          },
        }
      })
      match via_origin {
        Some(n) => n,
        None => { unit: unit, kind: "", source_kind: "", actor: "", parents: [], is_origin: false, ts_ms: 0, found: false },
      }
    },
  }
}

fn seen(visited :: List[Str], u :: Str) -> Bool {
  list.fold(visited, false, fn (acc :: Bool, x :: Str) -> Bool {
    acc or x == u
  })
}

# Walk the provenance DAG from `unit` back to origins: a flat, de-duplicated node
# list (each node carries its own parents, so a client can rebuild the tree).
fn walk(db :: Db, unit :: Str, depth :: Int, visited :: List[Str]) -> [sql] { nodes :: List[Node], visited :: List[Str] } {
  if depth > max_depth() or seen(visited, unit) {
    { nodes: [], visited: visited }
  } else {
    let n := resolve(db, unit)
    let v1 := list.concat(visited, [unit])
    list.fold(n.parents, { nodes: [n], visited: v1 }, fn (acc :: { nodes :: List[Node], visited :: List[Str] }, p :: Str) -> [sql] { nodes :: List[Node], visited :: List[Str] } {
      let sub := walk(db, p, depth + 1, acc.visited)
      { nodes: list.concat(acc.nodes, sub.nodes), visited: sub.visited }
    })
  }
}

fn node_json(n :: Node) -> jv.Json {
  JObj([("unit", JStr(n.unit)), ("kind", JStr(n.kind)), ("source_kind", JStr(n.source_kind)), ("actor", JStr(n.actor)), ("parents", JList(list.map(n.parents, fn (p :: Str) -> jv.Json {
    JStr(p)
  }))), ("is_origin", JBool(n.is_origin)), ("ts_ms", JInt(n.ts_ms)), ("found", JBool(n.found))])
}

fn chain_for(db :: Db, unit :: Str) -> [sql] jv.Json {
  let result := walk(db, unit, 0, [])
  let origins := list.filter(result.nodes, fn (n :: Node) -> Bool {
    n.is_origin
  })
  JObj([("unit", JStr(unit)), ("depth", JInt(list.len(result.nodes))), ("origins", JList(list.map(origins, fn (n :: Node) -> jv.Json {
    JStr(n.unit)
  }))), ("traced_to_origin", JBool(not list.is_empty(origins))), ("nodes", JList(list.map(result.nodes, node_json)))])
}

# ── Generic recorder (for domains that adopt the genealogy.* kinds) ──────────
# A transformation edge: `unit` was produced from `parents` by a `kind` step,
# actor-stamped + audit-shaped via evidence.record.
fn record_transformation(log :: tlog.Log, actor :: Str, unit :: Str, parents :: List[Str], kind :: Str) -> [sql, time] Result[ev.Event, Str] {
  evidence.record(log, "genealogy.transformation", actor, None, [("unit", JStr(unit)), ("parents", JList(list.map(parents, fn (p :: Str) -> jv.Json {
    JStr(p)
  }))), ("kind", JStr(kind))])
}

# An origin declaration: `unit` originates here, with no parents.
fn record_origin(log :: tlog.Log, actor :: Str, unit :: Str, kind :: Str) -> [sql, time] Result[ev.Event, Str] {
  evidence.record(log, "genealogy.origin", actor, None, [("unit", JStr(unit)), ("kind", JStr(kind))])
}

fn trace_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"trace lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(_)) => {
        let unit := match ctx.path_param(c, "ref") {
          Some(s) => s,
          None => "",
        }
        if str.is_empty(unit) {
          resp.bad_request("{\"error\":\"unit ref required\"}")
        } else {
          resp.json(jv.stringify(chain_for(db, unit)))
        }
      },
    },
  }
}

# Host opt-in: mount the trace route. `secrets` is the same federation keyring
# /audit and /ledger are mounted with (identity.resolve_subject).
fn mount(r :: router.Router, db :: Db, secrets :: List[Bytes]) -> router.Router {
  router.route_effectful(r, "GET", "/trace/unit/:ref", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    trace_response(db, secrets, c)
  })
}

