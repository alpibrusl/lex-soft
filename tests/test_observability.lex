# tests/test_observability.lex — the operator aggregate (#63).
#
# health_json is the operator's cross-tenant snapshot; these check the counts
# and per-tenant load reflect what's actually in the DB (two tenants, distinct
# agent counts, an account, a recorded run).

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/settlement" as settlement

import "../src/identity" as identity

import "../src/observability" as obs

fn count_agents_and_tenants() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a1 := reg.register_in(db, "org-x", "x-1", "truck", "X1", "http://x/", ["c"])
      let __a2 := reg.register_in(db, "org-x", "x-2", "truck", "X2", "http://x/", ["c"])
      let __b1 := reg.register_in(db, "org-y", "y-1", "depot", "Y1", "http://y/", ["c"])
      let __acct := identity.create_account(db, "org-x", "org-x", "Org X", "pro")
      let a := obs.count(db, "agents")
      let t := obs.distinct_tenants(db)
      let acc := obs.count(db, "accounts")
      if a == 3 and t == 2 and acc == 1 {
        Ok(())
      } else {
        Err(str.concat("counts wrong: agents=", str.concat(int_s(a), str.concat(" tenants=", str.concat(int_s(t), str.concat(" accounts=", int_s(acc)))))))
      }
    },
  }
}

fn tenant_load_reflects_distribution() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a1 := reg.register_in(db, "org-x", "x-1", "truck", "X1", "http://x/", ["c"])
      let __a2 := reg.register_in(db, "org-x", "x-2", "truck", "X2", "http://x/", ["c"])
      let __b1 := reg.register_in(db, "org-y", "y-1", "depot", "Y1", "http://y/", ["c"])
      let loads := obs.tenant_loads(db)
      let x := load_for(loads, "org-x")
      let y := load_for(loads, "org-y")
      if x == 2 and y == 1 {
        Ok(())
      } else {
        Err(str.concat("tenant load wrong: org-x=", str.concat(int_s(x), str.concat(" org-y=", int_s(y)))))
      }
    },
  }
}

fn health_json_is_wellformed() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a := reg.register_in(db, "org-x", "x-1", "truck", "X1", "http://x/", ["c"])
      let log := settlement.trail_on(db)
      let __e := settlement.record_run(log, "x-1", "handle", "in", "out", [])
      let j := obs.health_json(db, "ev-fleet", "v0.9")
      if str.contains(j, "\"version\":\"v0.9\"") and str.contains(j, "trail_events") and str.contains(j, "tenant_load") {
        Ok(())
      } else {
        Err(str.concat("health json missing fields: ", j))
      }
    },
  }
}

fn load_for(loads :: List[obs.TenantLoad], tenant :: Str) -> Int {
  list.fold(loads, 0, fn (acc :: Int, t :: obs.TenantLoad) -> Int {
    if t.tenant == tenant {
      t.agents
    } else {
      acc
    }
  })
}

fn int_s(n :: Int) -> Str {
  match n {
    0 => "0",
    1 => "1",
    2 => "2",
    3 => "3",
    _ => "n",
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [count_agents_and_tenants(), tenant_load_reflects_distribution(), health_json_is_wellformed()]
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

