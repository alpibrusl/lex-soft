# Pooled agents: pre-mounted personas are invisible until claimed, claiming
# re-tenants them, and a drained pool claims fewer than asked.

import "std.io" as io

import "std.str" as str

import "std.sql" as sql

import "std.list" as list

import "../src/migrate" as migrate

import "../src/registry" as reg

fn seed_pool(db :: Db) -> [sql, fs_write, time] Unit {
  let __a := reg.register_pooled(db, "pool", "pool-truck-01", "truck", "pool truck", "http://x/agents/pool-truck-01/", ["transport"])
  let __b := reg.register_pooled(db, "pool", "pool-truck-02", "truck", "pool truck", "http://x/agents/pool-truck-02/", ["transport"])
  ()
}

# pooled rows hide from the catalog and kind discovery until claimed
fn pooled_agents_are_invisible() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __s := seed_pool(db)
      match reg.list_all(db) {
        Err(e) => Err(e),
        Ok(all) => if not list.is_empty(all) {
          Err("pooled agents leaked into list_all")
        } else {
          match reg.find_by_kind(db, "truck") {
            Err(e) => Err(e),
            Ok(found) => if list.is_empty(found) {
              Ok(())
            } else {
              Err("pooled agents leaked into find_by_kind")
            },
          }
        },
      }
    },
  }
}

# claim moves the rows to the caller's org, renames, and makes them visible
fn claim_retenants_and_reveals() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __s := seed_pool(db)
      match reg.claim_pooled(db, "truck", 1, "acme", "Acme truck") {
        Err(e) => Err(e),
        Ok(ids) => if list.len(ids) != 1 {
          Err("expected exactly one claimed id")
        } else {
          match reg.list_by_tenant(db, "acme") {
            Err(e) => Err(e),
            Ok(mine) => match list.head(mine) {
              None => Err("claimed agent not in the org tenant"),
              Some(a) => if a.status == "active" and a.name == "Acme truck 1" {
                Ok(())
              } else {
                Err(str.concat("claimed agent wrong shape: ", str.concat(a.status, str.concat(" / ", a.name))))
              },
            },
          }
        },
      }
    },
  }
}

# a short pool yields fewer ids; a claimed agent is never claimed twice
fn pool_exhausts_honestly() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __s := seed_pool(db)
      match reg.claim_pooled(db, "truck", 5, "acme", "") {
        Err(e) => Err(e),
        Ok(first) => if list.len(first) != 2 {
          Err("expected the whole pool (2)")
        } else {
          match reg.claim_pooled(db, "truck", 1, "other", "") {
            Err(e) => Err(e),
            Ok(second) => if list.is_empty(second) {
              Ok(())
            } else {
              Err("drained pool still yielded an agent")
            },
          }
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [pooled_agents_are_invisible(), claim_retenants_and_reveals(), pool_exhausts_honestly()]
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

