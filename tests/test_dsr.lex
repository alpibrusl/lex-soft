# tests/test_dsr.lex — GDPR Art. 15/17 over the platform's own PII (dsr.lex).
#
# Drive the pure export/erase functions directly: seed two agents with traces +
# durable memory, and assert (1) export returns a subject's rows, (2) erase
# removes exactly that subject's rows and leaves the other subject untouched, and
# (3) erase appends a `dsr.erased` receipt to the tamper-evident trail.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.int" as int

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/trace" as trace

import "../src/dsr" as dsr

fn seed_agent(db :: Db, agent_id :: Str) -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let __r := reg.register(db, agent_id, "truck", agent_id, "http://x/", ["x"])
  let __t1 := trace.record(db, "run-1", agent_id, "received", "driver Ana Ruiz asks about her shift")
  let __t2 := trace.record(db, "run-1", agent_id, "llm_done", "acknowledged Ana Ruiz")
  let __m := trace.remember_fact(db, agent_id, "Ana Ruiz prefers depot North")
  ()
}

fn count_kind(db :: Db, kind :: Str) -> [sql, fs_read] Int {
  let rows :: Result[List[{ n :: Int }], SqlError] := sql.query(db, "SELECT COUNT(*) AS n FROM events WHERE kind=?", [PStr(kind)])
  match rows {
    Err(_) => 0 - 1,
    Ok(rs) => match list.head(rs) {
      None => 0,
      Some(r) => r.n,
    },
  }
}

# Export surfaces the subject's traces and memory.
fn export_returns_subject_pii() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __s := seed_agent(db, "agent-a")
      let tr := dsr.subject_traces(db, "agent-a")
      let mem := dsr.subject_memory(db, "agent-a")
      if list.len(tr) == 2 and list.len(mem) == 1 {
        Ok(())
      } else {
        Err(str.concat("expected 2 traces + 1 memory, got traces=", str.concat(int.to_str(list.len(tr)), str.concat(" memory=", int.to_str(list.len(mem))))))
      }
    },
  }
}

# Erase removes exactly the subject's rows and leaves another subject intact.
fn erase_is_scoped_to_subject() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __sa := seed_agent(db, "agent-a")
      let __sb := seed_agent(db, "agent-b")
      let counts := dsr.erase_subject(db, "agent-a")
      let a_tr := list.len(dsr.subject_traces(db, "agent-a"))
      let a_mem := list.len(dsr.subject_memory(db, "agent-a"))
      let b_tr := list.len(dsr.subject_traces(db, "agent-b"))
      let b_mem := list.len(dsr.subject_memory(db, "agent-b"))
      if counts.traces == 2 and counts.memory == 1 and a_tr == 0 and a_mem == 0 and b_tr == 2 and b_mem == 1 {
        Ok(())
      } else {
        Err(str.concat("bad erase; a_tr=", str.concat(int.to_str(a_tr), str.concat(" a_mem=", str.concat(int.to_str(a_mem), str.concat(" b_tr=", int.to_str(b_tr)))))))
      }
    },
  }
}

# Erase appends a signed dsr.erased receipt to the trail (provable erasure).
fn erase_records_receipt() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __sa := seed_agent(db, "agent-a")
      let __e := dsr.erase_subject(db, "agent-a")
      let receipts := count_kind(db, "dsr.erased")
      if receipts >= 1 {
        Ok(())
      } else {
        Err(str.concat("expected a dsr.erased receipt on the trail, got ", int.to_str(receipts)))
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [export_returns_subject_pii(), erase_is_scoped_to_subject(), erase_records_receipt()]
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

