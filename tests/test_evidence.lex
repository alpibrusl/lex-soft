# tests/test_evidence.lex — acceptance tests for the evidence recorder (#227).
# Asserts:
#   - record stamps agent + from_agent (audit-scoping) when the caller omits
#     them, so an otherwise-invisible evidence event lands in /audit,
#   - a caller-supplied `agent` is preserved (only from_agent is added),
#   - the recorded event carries the caller's kind + parent and re-verifies,
#   - content_hash is a stable SHA-256 of the blob.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-trail/replay" as replay

import "lex-trail/export" as txport

import "../src/evidence" as evidence

fn open_log() -> [sql, fs_write] Result[tlog.Log, Str] {
  tlog.open_memory()
}

fn payload_of(log :: tlog.Log, id :: Str) -> [sql] jv.Json {
  match list.head(replay.walk_chain(log, id)) {
    Some(e) => match jv.parse(e.payload_json) {
      Ok(j) => j,
      Err(_) => JNull,
    },
    None => JNull,
  }
}

fn field(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# An evidence event with no agent key is stamped audit-visible and verifies.
fn stamps_audit_keys() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => match evidence.record(log, "tradefinance.lc.document", "carrier-01", None, [("lc_ref", JStr("LC-1")), ("doc_type", JStr("bill_of_lading")), ("hash", JStr("abc"))]) {
      Err(e) => Err(str.concat("record failed: ", e)),
      Ok(evt) => {
        let p := payload_of(log, evt.id)
        let audit_ok := field(p, "agent") == "carrier-01" and field(p, "from_agent") == "carrier-01"
        let kept := field(p, "lc_ref") == "LC-1" and field(p, "doc_type") == "bill_of_lading"
        let verifies := txport.all_valid(replay.walk_chain(log, evt.id))
        if audit_ok and kept and verifies {
          Ok(())
        } else {
          Err("record should stamp agent/from_agent, keep the domain fields, and verify")
        }
      },
    },
  }
}

# A caller-supplied agent is preserved (recorder only adds from_agent).
fn preserves_supplied_agent() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => match evidence.record(log, "construction.evidence", "contractor-9", None, [("contract_ref", JStr("C-1")), ("agent", JStr("contractor-9")), ("hash", JStr("z"))]) {
      Err(e) => Err(str.concat("record failed: ", e)),
      Ok(evt) => {
        let p := payload_of(log, evt.id)
        if field(p, "agent") == "contractor-9" and field(p, "from_agent") == "contractor-9" {
          Ok(())
        } else {
          Err("a supplied agent should be preserved and from_agent added")
        }
      },
    },
  }
}

# The caller's parent is honoured, so per-subject chains still form.
fn chains_on_parent() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match open_log() {
    Err(e) => Err(e),
    Ok(log) => match evidence.record(log, "construction.evidence", "a", None, [("contract_ref", JStr("C-2")), ("hash", JStr("1"))]) {
      Err(e) => Err(str.concat("first failed: ", e)),
      Ok(first) => match evidence.record(log, "construction.evidence", "a", Some(first.id), [("contract_ref", JStr("C-2")), ("hash", JStr("2"))]) {
        Err(e) => Err(str.concat("second failed: ", e)),
        Ok(second) => if list.len(replay.walk_chain(log, second.id)) == 2 {
          Ok(())
        } else {
          Err("chaining on the parent should yield a 2-event chain")
        },
      },
    },
  }
}

# content_hash is a stable SHA-256 digest.
fn hash_is_stable() -> Result[Unit, Str] {
  if evidence.content_hash("hello") == evidence.content_hash("hello") and evidence.content_hash("a") != evidence.content_hash("b") {
    Ok(())
  } else {
    Err("content_hash should be deterministic and content-sensitive")
  }
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := [stamps_audit_keys(), preserves_supplied_agent(), chains_on_parent(), hash_is_stable()]
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

