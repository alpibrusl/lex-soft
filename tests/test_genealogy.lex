# tests/test_genealogy.lex — acceptance tests for the trace/genealogy module
# (#229). Asserts:
#   - a chain recorded via the generic recorder walks back to its origin,
#   - the walk also reads EXISTING agri-food edges (agrifood.transformation /
#     agrifood.origin) with no pack change,
#   - a unit with no recorded provenance yields a single not-found leaf.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "../src/genealogy" as genealogy

fn open_log() -> [sql, fs_write] Result[tlog.Log, Str] {
  tlog.open_memory()
}

fn jbool(j :: jv.Json, k :: Str) -> Bool {
  match jv.get_field(j, k) {
    Some(JBool(b)) => b,
    _ => false,
  }
}

fn jint(j :: jv.Json, k :: Str) -> Int {
  match jv.get_field(j, k) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# final ← mid ← farm(origin), recorded via the generic recorder.
fn generic_chain_to_origin() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => {
      let __o := genealogy.record_origin(log, "farmer-1", "lot-farm", "harvest")
      let __t1 := genealogy.record_transformation(log, "miller-1", "lot-mid", ["lot-farm"], "mill")
      let __t2 := genealogy.record_transformation(log, "baker-1", "lot-final", ["lot-mid"], "bake")
      let chain := genealogy.chain_for(log.db.handle, "lot-final")
      if jint(chain, "depth") == 3 and jbool(chain, "traced_to_origin") {
        Ok(())
      } else {
        Err("lot-final should trace through 3 nodes to a declared origin")
      }
    },
  }
}

# The walk reads existing agri-food edges verbatim (no pack migration).
fn reads_agrifood_edges() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => {
      let origin_payload := jv.stringify(JObj([("lot_ref", JStr("af-farm")), ("producer", JStr("finca-1")), ("agent", JStr("finca-1"))]))
      let __o := tlog.append(log, "agrifood.origin", None, origin_payload)
      let xform_payload := jv.stringify(JObj([("to_lot", JStr("af-prod")), ("from_lots", JList([JStr("af-farm")])), ("kind", JStr("roast")), ("site", JStr("mill-9"))]))
      let __t := tlog.append(log, "agrifood.transformation", None, xform_payload)
      let chain := genealogy.chain_for(log.db.handle, "af-prod")
      let origins := match jv.get_field(chain, "origins") {
        Some(JList(xs)) => xs,
        _ => [],
      }
      if jint(chain, "depth") == 2 and list.len(origins) == 1 and jbool(chain, "traced_to_origin") {
        Ok(())
      } else {
        Err("af-prod should trace to the af-farm origin via the agri-food vocab")
      }
    },
  }
}

# An unknown unit is a single leaf, not traced to origin.
fn unknown_unit_is_leaf() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => {
      let chain := genealogy.chain_for(log.db.handle, "nope")
      if jint(chain, "depth") == 1 and not jbool(chain, "traced_to_origin") {
        Ok(())
      } else {
        Err("an unknown unit should be a single not-found leaf")
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := [generic_chain_to_origin(), reads_agrifood_edges(), unknown_unit_is_leaf()]
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

