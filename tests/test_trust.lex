# Trust ladder: named presets stored as contract data; L1 chargebacks are
# trail events metering aggregates per account.

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "std.list" as list

import "std.bytes" as bytes

import "std.int" as int

import "std.float" as float

import "../src/migrate" as migrate

import "../src/trust" as trust

import "../src/relationships" as rel

import "../src/registry" as reg

import "../src/settlement" as settlement

import "../src/metering" as metering

fn presets_and_levels() -> Result[Unit, Str] {
  if trust.level_of("{}") != "L0" {
    Err("absent level should read as L0")
  } else {
    let c := trust.with_level("{\"capabilities\":[\"x\"]}", "L2")
    if trust.level_of(c) != "L2" {
      Err("with_level/level_of round-trip failed")
    } else {
      if trust.level_of(trust.with_level(c, "L9")) != "L2" {
        Err("invalid level should be a no-op")
      } else {
        if trust.default_level(true) != "L0" or trust.default_level(false) != "L2" {
          Err("default levels wrong")
        } else {
          match trust.preset("L3") {
            None => Err("L3 preset missing"),
            Some(p) => if p.arm_gate and p.requires_conn_token and p.settlement == "pay_on_proof" {
              Ok(())
            } else {
              Err("L3 preset gates wrong")
            },
          }
        }
      }
    }
  }
}

fn l1_edge_carries_internal_price() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let contract := trust.with_level(trust.contract_skeleton("L1"), "L1")
      let __a := rel.add(db, "retail-01", "charging-01", "customer", contract)
      match rel.peers_of(db, "retail-01") {
        Err(e) => Err(e),
        Ok(rs) => match list.head(rs) {
          None => Err("edge not created"),
          Some(r) => if trust.level_of(r.contract_json) == "L1" {
            Ok(())
          } else {
            Err("edge lost its L1 level")
          },
        },
      }
    },
  }
}

fn chargebacks_meter_per_account() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __r1 := reg.register_in(db, "hyper", "retail-01", "shipper", "Retail", "http://x/", [])
      let __r2 := reg.register_in(db, "hyper", "charging-01", "depot", "Charging BU", "http://x/", [])
      let log := settlement.trail_on(db)
      let __c1 := settlement.record_chargeback(log, "retail-01", "charging-01", 10.8, "EUR", "cdr-1")
      let __c2 := settlement.record_chargeback(log, "retail-01", "charging-01", 17.6, "EUR", "cdr-2")
      match metering.usage_for(db, "hyper") {
        Err(e) => Err(str.concat("usage_for failed: ", e)),
        Ok(u) => if u.chargeback_count == 2 and u.chargeback_total > 28.3 and u.chargeback_total < 28.5 {
          Ok(())
        } else {
          Err(str.concat("chargeback aggregate wrong: count/total = ", str.concat(int.to_str(u.chargeback_count), str.concat("/", float.to_str(u.chargeback_total)))))
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [presets_and_levels(), l1_edge_carries_internal_price(), chargebacks_meter_per_account()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __show := list.fold(failures, (), fn (_a :: Unit, m :: Str) -> [io] Unit {
      io.print(str.concat("FAIL: ", str.concat(m, "\n")))
    })
    let __boom := 1 / 0
    ()
  }
}

