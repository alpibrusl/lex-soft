# tests/test_schema_registry.lex — acceptance tests for #17 (per-capability
# schema registry). Asserts that a peer can resolve a capability's published
# request schema and use it to build a VALID payload (and that a bad payload is
# rejected), plus id resolution and versioning.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "../src/schema_registry" as sr

# A trivial domain capability: `tasks/send` carries a required `text` field.
fn truck_handle() -> cap.Capability {
  cap.inbound("handle", "Accept operational messages.", { title: "TruckMessage", description: "Inbound message for a truck agent.", fields: [sch.required_str("text", [])] })
}

fn registry() -> List[sr.CapabilitySchema] {
  [sr.from_capability("logistics.truck.handle", "1.0.0", truck_handle())]
}

fn parse(s :: Str) -> jv.Json {
  match jv.parse(s) {
    Ok(j) => j,
    Err(_) => JNull,
  }
}

# 1. Resolve a capability id → its published schema; unknown ids resolve to None.
fn resolves_by_id() -> Result[Unit, Str] {
  match sr.find(registry(), "logistics.truck.handle") {
    None => Err("expected to resolve logistics.truck.handle"),
    Some(cs) => if cs.version == "1.0.0" {
      Ok(())
    } else {
      Err(str.concat("expected version 1.0.0, got ", cs.version))
    },
  }
}

fn unknown_id_is_none() -> Result[Unit, Str] {
  match sr.find(registry(), "logistics.truck.nope") {
    None => Ok(()),
    Some(_) => Err("unknown capability id should not resolve"),
  }
}

# 2. THE acceptance: a payload built from the resolved request schema validates,
#    and a non-conforming one (missing required `text`) is rejected — proving a
#    peer can construct a valid tasks/send payload with no out-of-band docs.
fn published_schema_validates_payload() -> Result[Unit, Str] {
  match sr.find(registry(), "logistics.truck.handle") {
    None => Err("capability not found"),
    Some(cs) => match sch.validate(cs.request, parse("{\"text\":\"reach the depot?\"}")) {
      Err(_) => Err("a conforming payload should validate"),
      Ok(_) => match sch.validate(cs.request, parse("{}")) {
        Ok(_) => Err("a payload missing required `text` should be rejected"),
        Err(_) => Ok(()),
      },
    },
  }
}

# 3. The published doc + per-id schema render machine-readable JSON Schema that
#    carries the id, version and a `request` object schema.
fn renders_json_schema() -> Result[Unit, Str] {
  let one := sr.schema_json({ id: "logistics.truck.handle", version: "1.0.0", description: "d", request: truck_handle().params, result: None })
  let has := fn (key :: Str) -> Bool {
    match jv.get_field(one, key) {
      Some(_) => true,
      None => false,
    }
  }
  if has("id") and has("version") and has("request") and has("result") {
    Ok(())
  } else {
    Err("rendered schema json missing id/version/request/result")
  }
}

fn run_all() -> Unit {
  let results := [resolves_by_id(), unknown_id_is_none(), published_schema_validates_payload(), renders_json_schema()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

