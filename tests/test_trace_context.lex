# tests/test_trace_context.lex — conversation-scoped history (#46).
#
# Two conversations with the same agent must not leak into each other's
# replayed history; an empty contextId keeps the agent-global behavior.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "../src/migrate" as migrate

import "../src/trace" as trace

fn seed(db :: Db) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let __m := migrate.run(db)
  let __a1 := trace.record(db, "ctx-A", "seller-1", "received", "how much coffee do you have?")
  let __a2 := trace.record(db, "ctx-A", "seller-1", "llm_done", "we hold 15 kg")
  let __b1 := trace.record(db, "ctx-B", "seller-1", "received", "flex tender: shed 100 kW")
  let __b2 := trace.record(db, "ctx-B", "seller-1", "llm_done", "COMMITTED 100 kW")
  ()
}

fn scoped_history_stays_in_its_conversation() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __s := seed(db)
      let a := trace.recent_messages_json_for(db, "seller-1", "ctx-A", 8)
      let b := trace.recent_messages_json_for(db, "seller-1", "ctx-B", 8)
      let all := trace.recent_messages_json_for(db, "seller-1", "", 8)
      if str.contains(a, "15 kg") and not str.contains(a, "100 kW") and str.contains(b, "100 kW") and not str.contains(b, "15 kg") and str.contains(all, "15 kg") and str.contains(all, "100 kW") {
        Ok(())
      } else {
        Err(str.concat("history leaked. ctx-A=", str.concat(a, str.concat(" ctx-B=", b))))
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [scoped_history_stays_in_its_conversation()]
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

