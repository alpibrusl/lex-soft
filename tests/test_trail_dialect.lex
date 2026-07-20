# tests/test_trail_dialect.lex — the trail writes through trail_on (#62), and
# trail_on probes the dialect rather than assuming SQLite (L-3).
#
# The Postgres half is opt-in: it runs only when LEX_SOFT_PG_URL points at a
# reachable server, and reports SKIP otherwise, so the suite stays runnable
# with no services. CI supplies the URL from a postgres:16 service container,
# which is what makes the Postgres path actually covered rather than assumed.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.env" as env

import "std.time" as time

import "std.int" as int

import "lex-orm/connection" as conn

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

# The probe classifies a real SQLite handle as SQLite.
fn sqlite_is_detected() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let name := conn.dialect_name(settlement.detect_dialect(db))
      assert_true(name == "sqlite", str.concat("sqlite handle probed as: ", name))
    },
  }
}

fn pg_url() -> [env] Str {
  match env.get("LEX_SOFT_PG_URL") {
    None => "",
    Some(u) => u,
  }
}

# The same trail write, against a real Postgres server. Asserts the probe says
# postgres (so the SQLite tag is genuinely gone, not merely unused) and that a
# run round-trips: record_run returns an id, and that id is readable back out
# of the events table the trail just created.
fn trail_writes_on_postgres(url :: Str) -> [sql, fs_read, fs_write, time, env] Result[Unit, Str] {
  match sql.open(url) {
    Err(e) => Err(str.concat("LEX_SOFT_PG_URL set but connect failed: ", e.message)),
    Ok(db) => {
      let name := conn.dialect_name(settlement.detect_dialect(db))
      if name != "postgres" {
        Err(str.concat("postgres handle probed as: ", name))
      } else {
        let agent := str.concat("agent-pg-", int.to_str(time.now_ms()))
        let log := settlement.trail_on(db)
        let id := settlement.record_run(log, agent, "handle", "in", "out", [])
        if str.is_empty(id) {
          Err("record_run returned no trail id on postgres")
        } else {
          let rows :: Result[List[{ id :: Str }], SqlError] := sql.query(db, "SELECT id FROM events WHERE id=?", [PStr(id)])
          match rows {
            Err(e) => Err(str.concat("reading the trail back on postgres failed: ", e.message)),
            Ok(rs) => assert_true(list.len(rs) == 1, "the postgres trail event was not readable back"),
          }
        }
      }
    },
  }
}

fn postgres_trail() -> [io, sql, fs_read, fs_write, time, env] Result[Unit, Str] {
  let url := pg_url()
  if str.is_empty(url) {
    let __skip := io.print("SKIP: postgres trail (set LEX_SOFT_PG_URL to run it)\n")
    Ok(())
  } else {
    trail_writes_on_postgres(url)
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc, env] Unit {
  let results := [trail_writes_on_sqlite(), sqlite_is_detected(), postgres_trail()]
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

