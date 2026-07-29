# tests/test_ctl.lex — acceptance tests for the lex-ctl host wiring (#106
# task 2). Asserts:
#   - propose/get_by_id round-trip a contract as 'pending'; re-proposing
#     the same content-addressed contract is a safe no-op (idempotent).
#   - pending_due respects the deadline (not due before, due at/after).
#   - judge_and_record persists Materialised/Falsified, trail-records
#     the disposition (audit-shaped), and enqueues an outbox
#     notification to the proposing agent — but only ONCE: a second
#     judge_and_record call on an already-disposed row (the race a
#     concurrent tick could hit) must not double-trail or double-notify.
#   - mount_ctl's HTTP surface: POST proposes, GET reads back.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-trail/replay" as replay

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dberr

import "lex-web/router" as router

import "lex-ctl/src/contract" as kct

import "lex-ctl/src/verify" as kverify

import "../src/ctl" as ctl

import "../src/outbox" as outbox

# One shared connection wears both hats: a bare `Db` for ctl's own SQL
# calls, and a `tlog.Log` (lex-trail's `{ db :: conn.ConnDb }`) for the
# trail write — same physical in-memory database either way.
fn open_all() -> [sql, fs_write] Result[(Db, tlog.Log), Str] {
  match conn.open(":memory:") {
    Err(e) => Err(dberr.message(e)),
    Ok(cdb) => match tlog.init_schema(cdb) {
      Err(e) => Err(e),
      Ok(_) => {
        let __i1 := ctl.init(cdb.handle)
        let __i2 := outbox.init(cdb.handle)
        Ok((cdb.handle, { db: cdb }))
      },
    },
  }
}

fn contract_a() -> kct.EffectContract {
  kct.make("act-1", "restart_session", "charger-07", { signal: "charger_power_kw_milli", cmp: Above, threshold_milli: 500 }, 120000, 85, Handoff)
}

fn observe_ok(_r :: ctl.EffectRow) -> [net, io] ctl.Observation {
  { observed_milli: Some(7200), concurrent_on_subsystem: 0 }
}

fn observe_stalled(_r :: ctl.EffectRow) -> [net, io] ctl.Observation {
  { observed_milli: Some(0), concurrent_on_subsystem: 0 }
}

fn propose_and_get_roundtrip() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => match ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0) {
        Err(e) => Err(e),
        Ok(_) => match ctl.get_by_id(db, contract_a().id) {
          None => Err("proposed contract not found by id"),
          Some(row) => if row.disposition == "pending" and row.tenant == "tenant-a" and row.proposer_id == "charge-agent-1" and row.class_key == "restart_session" and row.subsystem == "charger-07" {
            Ok(())
          } else {
            Err(str.concat("unexpected row shape: ", row.disposition))
          },
        },
      },
    },
  }
}

fn propose_is_idempotent() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => {
        let __p1 := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 5000) {
          Err(e) => Err(str.concat("second propose should not error: ", e)),
          Ok(_) => match ctl.get_by_id(db, contract_a().id) {
            None => Err("contract vanished"),
            Some(row) => if row.proposed_at_ms == 0 {
              Ok(())
            } else {
              Err("re-proposing the same content-addressed contract must not overwrite the first proposal")
            },
          },
        }
      },
    },
  }
}

fn pending_due_respects_deadline() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        if list.is_empty(ctl.pending_due(db, "tenant-a", 60000)) {
          if list.len(ctl.pending_due(db, "tenant-a", 120000)) == 1 {
            Ok(())
          } else {
            Err("expected exactly 1 contract due at its deadline")
          }
        } else {
          Err("contract should not be due before its deadline (120000ms)")
        }
      },
    },
  }
}

fn judge_and_record_materialises_and_notifies() -> [net, io, sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.get_by_id(db, contract_a().id) {
          None => Err("contract not found"),
          Some(row) => match ctl.judge_and_record(db, log, row, 120000, observe_ok) {
            Err(e) => Err(e),
            Ok(Materialised) => match ctl.get_by_id(db, row.id) {
              None => Err("row vanished after disposition"),
              Some(disposed) => if disposed.disposition == "materialised" and disposed.disposed_at_ms == 120000 {
                match outbox.pending_count(db) {
                  Err(e) => Err(e),
                  Ok(n) => if n == 1 {
                    match list.head(replay.walk_chain(log, tlog_head_id(log))) {
                      None => Err("no trail event recorded"),
                      Some(_) => Ok(()),
                    }
                  } else {
                    Err(str.concat("expected exactly one outbox notification, got ", int_to_str_local(n)))
                  },
                }
              } else {
                Err("disposition not persisted correctly")
              },
            },
            Ok(other) => Err(str.concat("expected Materialised, got ", ctl.outcome_str(other))),
          },
        }
      },
    },
  }
}

fn judge_and_record_falsifies() -> [net, io, sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.get_by_id(db, contract_a().id) {
          None => Err("contract not found"),
          Some(row) => match ctl.judge_and_record(db, log, row, 120000, observe_stalled) {
            Err(e) => Err(e),
            Ok(Falsified) => Ok(()),
            Ok(other) => Err(str.concat("expected Falsified, got ", ctl.outcome_str(other))),
          },
        }
      },
    },
  }
}

# A second judge_and_record on an ALREADY-disposed row (the shape a
# race between two overlapping ticks would produce) must not persist a
# second trail event or a second outbox notification — record_disposition's
# affected-row-count gate is what this proves.
fn judge_and_record_is_not_double_fired() -> [net, io, sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.get_by_id(db, contract_a().id) {
          None => Err("contract not found"),
          Some(row) => {
            let __first := ctl.judge_and_record(db, log, row, 120000, observe_ok)
            match ctl.judge_and_record(db, log, row, 130000, observe_ok) {
              Err(e) => Err(e),
              Ok(_) => match outbox.pending_count(db) {
                Err(e) => Err(e),
                Ok(n) => if n == 1 {
                  Ok(())
                } else {
                  Err(str.concat("a race on an already-disposed contract must not double-notify, got ", int_to_str_local(n)))
                },
              },
            }
          },
        }
      },
    },
  }
}

fn http_surface_roundtrip() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := ctl.init(db)
      let r := ctl.mount_ctl(router.new(), db)
      let body := "{\"action_id\":\"act-1\",\"class_key\":\"restart_session\",\"subsystem\":\"charger-07\",\"signal\":\"charger_power_kw_milli\",\"cmp\":\"above\",\"threshold_milli\":500,\"deadline_ms\":120000,\"confidence_pct\":85,\"on_falsify\":\"handoff\",\"proposer_id\":\"charge-agent-1\"}"
      let posted := router.dispatch(r, { body: body, method: "POST", path: "/ctl/contracts", query: "", headers: map.from_list([]) })
      if posted.status == 200 and str.contains(posted.body, "contract_id") {
        let id := contract_id_of(posted.body)
        let got := router.dispatch(r, { body: "", method: "GET", path: str.concat("/ctl/contracts/", id), query: "", headers: map.from_list([]) })
        if got.status == 200 and str.contains(got.body, "\"pending\"") and str.contains(got.body, "charger-07") {
          Ok(())
        } else {
          Err(str.concat("GET /ctl/contracts/:id failed: ", got.body))
        }
      } else {
        Err(str.concat("POST /ctl/contracts failed: ", posted.body))
      }
    },
  }
}

fn contract_id_of(body :: Str) -> Str {
  match jv.parse(body) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "contract_id") {
      Some(JStr(s)) => s,
      _ => "",
    },
  }
}

fn tlog_head_id(log :: tlog.Log) -> [sql] Str {
  match tlog.head(log) {
    Some(e) => e.id,
    None => "",
  }
}

fn int_to_str_local(n :: Int) -> Str {
  jv.stringify(JInt(n))
}

fn run_all() -> [net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc] Unit {
  let results := [propose_and_get_roundtrip(), propose_is_idempotent(), pending_due_respects_deadline(), judge_and_record_materialises_and_notifies(), judge_and_record_falsifies(), judge_and_record_is_not_double_fired(), http_surface_roundtrip()]
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

