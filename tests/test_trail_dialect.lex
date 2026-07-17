# tests/test_trail_dialect.lex — the trail writes through trail_on (#62).

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "../src/settlement" as settlement

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

# And the trail actually writes through it (? binds; the chain is readable).
fn trail_writes_on_sqlite() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let log := settlement.trail_on(db)
      let id := settlement.record_run(log, "agent-d1", "handle", "in", "out", [])
      assert_true(not str.is_empty(id), "record_run must return a trail id on sqlite")
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [trail_writes_on_sqlite()]
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
