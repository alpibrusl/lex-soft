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

fn fold_ok(xs :: List[Int], f :: (Int) -> [sql, fs_write, time] Result[Unit, Str]) -> [sql, fs_write, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], n :: Int) -> [sql, fs_write, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(n),
    }
  })
}

fn fold_ok_str(xs :: List[Str], f :: (Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], s :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(s),
    }
  })
}

fn fold_ok_n_crypto(xs :: List[Int], f :: (Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  list.fold(xs, Ok(()), fn (acc :: Result[Unit, Str], n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => f(n),
    }
  })
}

fn register_agents(db :: Db) -> [sql, fs_write, time] Result[Unit, Str] {
  match reg.register(db, "depot-north", "depot", "Depot North", base_url(8110), ["charging"]) {
    Err(e) => Err(e),
    Ok(_) => match reg.register(db, "depot-south", "depot", "Depot South", base_url(8111), ["charging"]) {
      Err(e) => Err(e),
      Ok(_) => match reg.register(db, "depot-east", "depot", "Depot East", base_url(8112), ["charging"]) {
        Err(e) => Err(e),
        Ok(_) => match reg.register(db, "depot-west", "depot", "Depot West", base_url(8113), ["charging"]) {
          Err(e) => Err(e),
          Ok(_) => match reg.register(db, "tms-primary", "tms", "TMS Primary", base_url(8120), ["dispatch"]) {
            Err(e) => Err(e),
            Ok(_) => match reg.register(db, "tms-secondary", "tms", "TMS Secondary", base_url(8121), ["dispatch"]) {
              Err(e) => Err(e),
              Ok(_) => fold_ok(list.range(1, 21), fn (n :: Int) -> [sql, fs_write, time] Result[Unit, Str] {
                reg.register(db, truck_id(n), "truck", str.concat("Truck ", int.to_str(n)), base_url(8100 + n), ["transport"])
              }),
            },
          },
        },
      },
    },
  }
}

fn wire_tms(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match fold_ok_n_crypto(list.range(1, 11), fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    match rel.add(db, truck_id(n), "tms-primary", "contracted", "{}") {
      Err(e) => Err(e),
      Ok(_) => rel.add(db, truck_id(n), "tms-secondary", "freelance", "{}"),
    }
  }) {
    Err(e) => Err(e),
    Ok(_) => fold_ok_n_crypto(list.range(11, 21), fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      match rel.add(db, truck_id(n), "tms-secondary", "contracted", "{}") {
        Err(e) => Err(e),
        Ok(_) => rel.add(db, truck_id(n), "tms-primary", "freelance", "{}"),
      }
    }),
  }
}

fn wire_group(db :: Db, trucks :: List[Int], depots :: List[Str]) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  fold_ok_n_crypto(trucks, fn (n :: Int) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    fold_ok_str(depots, fn (depot_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      rel.add(db, truck_id(n), depot_id, "preferred_charger", "{}")
    })
  })
}

fn wire_depots(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match wire_group(db, list.range(1, 6), ["depot-north", "depot-west"]) {
    Err(e) => Err(e),
    Ok(_) => match wire_group(db, list.range(6, 11), ["depot-south", "depot-west"]) {
      Err(e) => Err(e),
      Ok(_) => match wire_group(db, list.range(11, 16), ["depot-east", "depot-north"]) {
        Err(e) => Err(e),
        Ok(_) => wire_group(db, list.range(16, 21), ["depot-south", "depot-east"]),
      },
    },
  }
}

fn wire_depot_reporting(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  let depots := ["depot-north", "depot-south", "depot-east", "depot-west"]
  let tmss := ["tms-primary", "tms-secondary"]
  fold_ok_str(depots, fn (depot_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
    fold_ok_str(tmss, fn (tms_id :: Str) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
      rel.add(db, depot_id, tms_id, "reporting", "{}")
    })
  })
}

fn run(db :: Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  match register_agents(db) {
    Err(e) => Err(e),
    Ok(_) => match wire_tms(db) {
      Err(e) => Err(e),
      Ok(_) => match wire_depots(db) {
        Err(e) => Err(e),
        Ok(_) => wire_depot_reporting(db),
      },
    },
  }
}

