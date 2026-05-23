# seed.lex — populate the registry and relationship graph for the demo.
#
# 20 trucks, 4 depots, 2 TMS providers with realistic relationship topology:
#   - Trucks 01-10  contracted to TMS-primary,   freelance to TMS-secondary
#   - Trucks 11-20  contracted to TMS-secondary, freelance to TMS-primary
#   - Trucks 01-05  preferred_charger at depot-north  + depot-west
#   - Trucks 06-10  preferred_charger at depot-south  + depot-west
#   - Trucks 11-15  preferred_charger at depot-east   + depot-north
#   - Trucks 16-20  preferred_charger at depot-south  + depot-east
#   - All depots report to both TMS providers

import "std.sql" as sql
import "std.str" as str
import "std.int" as int
import "std.list" as list
import "lex-soft/src/registry" as reg
import "lex-soft/src/relationships" as rel

fn truck_id(n :: Int) -> Str {
  let ns := int.to_str(n)
  if n < 10 {
    str.concat("truck-0", ns)
  } else {
    str.concat("truck-", ns)
  }
}

fn base_url(port :: Int) -> Str {
  str.concat("http://localhost:", int.to_str(port))
}

fn register_agents(db :: sql.Db) -> [sql, fs_write] Result[Unit, Str] {
  # depots
  match reg.register(db, "depot-north", "depot", "Depot North", base_url(8110), ["charging"]) {
    Err(e) => Err(e),
    Ok(_) => match reg.register(db, "depot-south", "depot", "Depot South", base_url(8111), ["charging"]) {
      Err(e) => Err(e),
      Ok(_) => match reg.register(db, "depot-east",  "depot", "Depot East",  base_url(8112), ["charging"]) {
        Err(e) => Err(e),
        Ok(_) => match reg.register(db, "depot-west",  "depot", "Depot West",  base_url(8113), ["charging"]) {
          Err(e) => Err(e),
          Ok(_) => match reg.register(db, "tms-primary",   "tms", "TMS Primary",   base_url(8120), ["dispatch"]) {
            Err(e) => Err(e),
            Ok(_) => match reg.register(db, "tms-secondary", "tms", "TMS Secondary", base_url(8121), ["dispatch"]) {
              Err(e) => Err(e),
              Ok(_) => {
                let trucks := list.range(1, 21)
                list.fold_result(trucks, unit, fn (_acc :: Unit, n :: Int) -> [sql, fs_write] Result[Unit, Str] {
                  reg.register(db, truck_id(n), "truck", str.concat("Truck ", int.to_str(n)), base_url(8100 + n), ["transport"])
                })
              },
            },
          },
        },
      },
    },
  }
}

fn wire_tms(db :: sql.Db) -> [sql, fs_write, crypto] Result[Unit, Str] {
  # trucks 01-10 → tms-primary (contracted) + tms-secondary (freelance)
  let group1 := list.range(1, 11)
  match list.fold_result(group1, unit, fn (_acc :: Unit, n :: Int) -> [sql, fs_write, crypto] Result[Unit, Str] {
    match rel.add(db, truck_id(n), "tms-primary",   "contracted", "{}") {
      Err(e) => Err(e),
      Ok(_)  => rel.add(db, truck_id(n), "tms-secondary", "freelance",  "{}"),
    }
  }) {
    Err(e) => Err(e),
    Ok(_) => {
      # trucks 11-20 → tms-secondary (contracted) + tms-primary (freelance)
      let group2 := list.range(11, 21)
      list.fold_result(group2, unit, fn (_acc :: Unit, n :: Int) -> [sql, fs_write, crypto] Result[Unit, Str] {
        match rel.add(db, truck_id(n), "tms-secondary", "contracted", "{}") {
          Err(e) => Err(e),
          Ok(_)  => rel.add(db, truck_id(n), "tms-primary", "freelance", "{}"),
        }
      })
    },
  }
}

fn wire_depots(db :: sql.Db) -> [sql, fs_write, crypto] Result[Unit, Str] {
  let groups := [
    (list.range(1,  6),  ["depot-north", "depot-west"]),
    (list.range(6,  11), ["depot-south", "depot-west"]),
    (list.range(11, 16), ["depot-east",  "depot-north"]),
    (list.range(16, 21), ["depot-south", "depot-east"]),
  ]
  list.fold_result(groups, unit, fn (_acc :: Unit, pair :: (List[Int], List[Str])) -> [sql, fs_write, crypto] Result[Unit, Str] {
    let trucks := pair.0
    let depots := pair.1
    list.fold_result(trucks, unit, fn (_a :: Unit, n :: Int) -> [sql, fs_write, crypto] Result[Unit, Str] {
      list.fold_result(depots, unit, fn (_b :: Unit, depot_id :: Str) -> [sql, fs_write, crypto] Result[Unit, Str] {
        rel.add(db, truck_id(n), depot_id, "preferred_charger", "{}")
      })
    })
  })
}

fn wire_depot_reporting(db :: sql.Db) -> [sql, fs_write, crypto] Result[Unit, Str] {
  let depots := ["depot-north", "depot-south", "depot-east", "depot-west"]
  let tmss   := ["tms-primary", "tms-secondary"]
  list.fold_result(depots, unit, fn (_a :: Unit, depot_id :: Str) -> [sql, fs_write, crypto] Result[Unit, Str] {
    list.fold_result(tmss, unit, fn (_b :: Unit, tms_id :: Str) -> [sql, fs_write, crypto] Result[Unit, Str] {
      rel.add(db, depot_id, tms_id, "reporting", "{}")
    })
  })
}

fn run(db :: sql.Db) -> [sql, fs_write, crypto] Result[Unit, Str] {
  match register_agents(db) {
    Err(e) => Err(e),
    Ok(_) => match wire_tms(db) {
      Err(e) => Err(e),
      Ok(_) => match wire_depots(db) {
        Err(e) => Err(e),
        Ok(_)  => wire_depot_reporting(db),
      },
    },
  }
}
