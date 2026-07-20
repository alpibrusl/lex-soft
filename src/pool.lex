# pool.lex — claim pre-mounted agents from the host's pool.
#
# Hosts that can't mount agents at runtime pre-mount a pool of personas
# (registered via reg.register_pooled into a holding tenant). A customer
# with a valid platform credential claims them:
#
#   POST /pool/claim   { "kind": "truck", "count": 2, "name": "Acme truck" }
#     -> { "claimed": 2, "ids": ["pool-truck-01", "pool-truck-02"] }
#
# The claimed rows move to the caller's org (tenant re-pointing — the
# tenant-stamped tool path picks the new org up on the next request) and
# become visible to discovery. The pool may run short: claimed < count.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./registry" as reg

import "./identity" as identity

fn body_str(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn body_int(j :: jv.Json, k :: Str, dflt :: Int) -> Int {
  match jv.get_field(j, k) {
    Some(JInt(n)) => n,
    _ => dflt,
  }
}

fn claim_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, fs_write, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"credential lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => {
        let j := match jv.parse(c.body) {
          Err(_) => JNull,
          Ok(v) => v,
        }
        let kind := body_str(j, "kind")
        let count := body_int(j, "count", 1)
        if str.is_empty(kind) or count < 1 {
          resp.bad_request("{\"error\":\"kind (and a positive count) required\"}")
        } else {
          match reg.claim_pooled(db, kind, count, subj.org, body_str(j, "name")) {
            Err(e) => resp.json_status(500, jv.stringify(JObj([("error", JStr(e))]))),
            Ok(ids) => resp.json(jv.stringify(JObj([("claimed", JInt(list.len(ids))), ("ids", JList(list.map(ids, fn (id :: Str) -> jv.Json {
              JStr(id)
            })))]))),
          }
        }
      },
    },
  }
}

fn mount(r :: router.Router, db :: Db, secrets :: List[Bytes]) -> router.Router {
  router.route_effectful(r, "POST", "/pool/claim", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    claim_response(db, secrets, c)
  })
}

