# pack-template/persona.lex — copy me into your product's agents/ dir.
#
# A minimal persona: one capability, one read tool, one act tool over a
# single REST backend. See docs/DOMAIN-PACKS.md for the rules that bite.
import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    req0
  } else {
    http.with_header(req0, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn example_capability() -> cap.Capability {
  cap.make("mydomain.role.handle", "Role", "What this persona coordinates.")
}

fn make_tools(backend_url :: Str, tenant :: Str) -> List[t.Tool] {
  [t.define("get_things", "Read the persona's world from its backend.", { title: "GetThings", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(backend_url, "/api/v1/things"), tenant))
  })]
}
