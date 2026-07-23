# tests/test_ledger.lex — acceptance tests for the settlement/finance ledger
# view (#228). Asserts:
#   - money_where scopes to a party's agents as BOTH payer and payee (a payee
#     never "acted", so it must still see its incoming payments),
#   - the per-currency summary sums incoming/outgoing/net correctly,
#   - a ledger entry's direction is from the org's point of view.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "../src/settlement" as settlement

import "../src/audit" as audit

import "../src/ledger" as ledger

# A trail with two chargebacks: A pays B 100 EUR, C pays A 50 EUR.
fn seed() -> [sql, fs_read, fs_write, time] Result[tlog.Log, Str] {
  match tlog.open_memory() {
    Err(e) => Err(e),
    Ok(log) => match settlement.record_chargeback_dec(log, "agent-a", "agent-b", "100.00", "EUR", "inv-1") {
      Err(e) => Err(str.concat("cb1: ", e)),
      Ok(_) => match settlement.record_chargeback_dec(log, "agent-c", "agent-a", "50.00", "EUR", "inv-2") {
        Err(e) => Err(str.concat("cb2: ", e)),
        Ok(_) => Ok(log),
      },
    },
  }
}

fn db_of(log :: tlog.Log) -> Db {
  log.db.handle
}

# A is party to both (payer of #1, payee of #2); B only to #1 (as payee).
fn scopes_both_sides() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match seed() {
    Err(e) => Err(e),
    Ok(log) => {
      let db := db_of(log)
      let a_rows := ledger.query_kind(db, ["agent-a"], ledger.chargeback_kind(), None)
      let b_rows := ledger.query_kind(db, ["agent-b"], ledger.chargeback_kind(), None)
      if list.len(a_rows) == 2 and list.len(b_rows) == 1 {
        Ok(())
      } else {
        Err("A should see both movements (payer + payee); B only its incoming one")
      }
    },
  }
}

fn f_field(j :: jv.Json, k :: Str) -> Float {
  match jv.get_field(j, k) {
    Some(JFloat(f)) => f,
    Some(JInt(n)) => int.to_float(n),
    _ => 0.0,
  }
}

fn s_field(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# A's summary: incoming 50 (from C), outgoing 100 (to B), net -50, in EUR.
fn summary_nets() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match seed() {
    Err(e) => Err(e),
    Ok(log) => {
      let rows := ledger.query_kind(db_of(log), ["agent-a"], ledger.chargeback_kind(), None)
      let totals := ledger.summarize(["agent-a"], rows)
      match list.head(totals) {
        None => Err("expected one currency total"),
        Some(t) => if t.currency == "EUR" and t.incoming == 50.0 and t.outgoing == 100.0 and t.count == 2 {
          Ok(())
        } else {
          Err(str.concat("EUR totals wrong: in/out/count = ", str.join([flt(t.incoming), "/", flt(t.outgoing), "/", int.to_str(t.count)], "")))
        },
      }
    },
  }
}

fn flt(f :: Float) -> Str {
  int.to_str(float.to_int(f))
}

# Direction is from the org's point of view: A→B is outgoing for A.
fn direction_is_org_relative() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match seed() {
    Err(e) => Err(e),
    Ok(log) => {
      let rows := ledger.query_kind(db_of(log), ["agent-a"], ledger.chargeback_kind(), None)
      let dirs := list.map(rows, fn (r :: audit.EvRow) -> Str {
        s_field(ledger.entry_json(["agent-a"], r), "direction")
      })
      let has_in := list.fold(dirs, false, fn (acc :: Bool, d :: Str) -> Bool {
        acc or d == "in"
      })
      let has_out := list.fold(dirs, false, fn (acc :: Bool, d :: Str) -> Bool {
        acc or d == "out"
      })
      if has_in and has_out {
        Ok(())
      } else {
        Err("A's two entries should be one in (from C) and one out (to B)")
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time] Unit {
  let results := [scopes_both_sides(), summary_nets(), direction_is_org_relative()]
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

