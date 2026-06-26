# src/schema_registry.lex — per-capability request/result schema registry.
#
# A stranger agent can discover a capability (via the directory, #16) but needs a
# machine-readable way to learn what shape of `tasks/send` message it expects and
# what the result looks like. This registry publishes, per namespaced capability
# id, its request + result schema (reusing `lex-schema` ModelSchemas, rendered to
# JSON Schema) and a version, resolvable at runtime:
#
#   GET /.well-known/capabilities.json  — all offered capabilities + their schemas
#   GET /capabilities/:id/schema        — request/result schema for one capability
#
# A peer can then construct a valid payload with no out-of-band docs. Pure module
# (no effects) — the host (a domain pack) supplies the capability list at boot.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

# A published capability schema: a namespaced id (`logistics.truck.handle`), a
# version the id maps to, and the request/result ModelSchemas.
type CapabilitySchema = { id :: Str, version :: Str, description :: Str, request :: sch.ModelSchema, result :: Option[sch.ModelSchema] }

# Build a CapabilitySchema from a lex-spec Capability: params → request schema,
# reply → result schema. (Reuses what personas already declare.)
fn from_capability(id :: Str, version :: Str, c :: cap.Capability) -> CapabilitySchema {
  { id: id, version: version, description: c.description, request: c.params, result: c.reply }
}

# Render one capability + its schemas to JSON (request/result as JSON Schema).
fn schema_json(cs :: CapabilitySchema) -> jv.Json {
  let result_json := match cs.result {
    Some(r) => sch.to_json_schema(r),
    None => JNull,
  }
  JObj([("id", JStr(cs.id)), ("version", JStr(cs.version)), ("description", JStr(cs.description)), ("request", sch.to_json_schema(cs.request)), ("result", result_json)])
}

fn capabilities_json(caps :: List[CapabilitySchema]) -> Str {
  jv.stringify(JObj([("capabilities", JList(list.map(caps, fn (cs :: CapabilitySchema) -> jv.Json {
    schema_json(cs)
  })))]))
}

fn find(caps :: List[CapabilitySchema], id :: Str) -> Option[CapabilitySchema] {
  list.fold(caps, None, fn (acc :: Option[CapabilitySchema], cs :: CapabilitySchema) -> Option[CapabilitySchema] {
    match acc {
      Some(_) => acc,
      None => if cs.id == id {
        Some(cs)
      } else {
        None
      },
    }
  })
}

fn json_response(body :: Str) -> resp.Response {
  { status: 200, body: body, headers: map.from_list([("content-type", "application/json")]) }
}

# Mount the capability-schema registry routes onto a router.
fn mount(r :: router.Router, caps :: List[CapabilitySchema]) -> router.Router {
  let doc := capabilities_json(caps)
  let with_doc := router.route(r, "GET", "/.well-known/capabilities.json", fn (_c :: ctx.Ctx) -> resp.Response {
    json_response(doc)
  })
  router.route(with_doc, "GET", "/capabilities/:id/schema", fn (c :: ctx.Ctx) -> resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match find(caps, id) {
      Some(cs) => json_response(jv.stringify(schema_json(cs))),
      None => { status: 404, body: str.concat("{\"error\":\"unknown capability\",\"id\":", str.concat(jv.stringify(JStr(id)), "}")), headers: map.from_list([("content-type", "application/json")]) },
    }
  })
}

