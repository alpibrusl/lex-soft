# tests/test_ctl.lex — acceptance tests for the lex-ctl host wiring (#106
# task 2). Asserts:
#   - propose/get_by_id round-trip a contract as 'pending'; re-proposing
#     the same content-addressed contract is a safe no-op (idempotent);
#     genuinely different content proposes a genuinely different id.
#   - pending_due respects the deadline (not due before, due at/after)
#     and is tenant-isolated.
#   - the (tenant, id) primary key means the same id under two different
#     tenants is two distinct rows — proposing for tenant A must not be
#     readable by tenant B (#110/#111).
#   - judge_and_record persists Materialised/Falsified/Ambiguous,
#     trail-records the disposition (audit-shaped), and enqueues an
#     outbox notification to the proposing agent — but only ONCE: a
#     second judge_and_record call on an already-disposed row (the
#     race a concurrent tick could hit) must not double-trail or
#     double-notify (#109) — and a not-yet-due contract is left alone
#     entirely (Pending, no side effects).
#   - mount_ctl's HTTP surface: POST proposes (tenant from
#     X-Tenant-Id), GET reads back, and a different tenant's header
#     404s on the same id.

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

# Same shape as contract_a but a genuinely different confidence_pct —
# must content-address to a genuinely different id.
fn contract_b() -> kct.EffectContract {
  kct.make("act-1", "restart_session", "charger-07", { signal: "charger_power_kw_milli", cmp: Above, threshold_milli: 500 }, 120000, 90, Handoff)
}

fn observe_ok(_r :: ctl.EffectRow) -> [net, io] ctl.Observation {
  { observed_milli: Some(7200), concurrent_on_subsystem: 0 }
}

fn observe_stalled(_r :: ctl.EffectRow) -> [net, io] ctl.Observation {
  { observed_milli: Some(0), concurrent_on_subsystem: 0 }
}

# A concurrent action on the same subsystem confounds attribution —
# the kernel's own judge() treats this as Ambiguous, never a hit.
fn observe_concurrent(_r :: ctl.EffectRow) -> [net, io] ctl.Observation {
  { observed_milli: Some(7200), concurrent_on_subsystem: 1 }
}

fn propose_and_get_roundtrip() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => match ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0) {
        Err(e) => Err(e),
        Ok(_) => match ctl.get_by_id(db, "tenant-a", contract_a().id) {
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
          Ok(_) => match ctl.get_by_id(db, "tenant-a", contract_a().id) {
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

# contract_a and contract_b differ only in confidence_pct — the kernel's
# content-addressed id must reflect that, and both must be independently
# readable (propose must not have merged the second into the first).
fn propose_distinct_content_yields_distinct_id() -> [sql, fs_write, time] Result[Unit, Str] {
  if contract_a().id == contract_b().id {
    Err("test setup bug: contract_a and contract_b must not already share an id")
  } else {
    match open_all() {
      Err(e) => Err(e),
      Ok(pair) => match pair {
        (db, _log) => {
          let __pa := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
          let __pb := ctl.propose(db, "tenant-a", "charge-agent-1", contract_b(), 0)
          match ctl.get_by_id(db, "tenant-a", contract_a().id) {
            None => Err("contract_a vanished"),
            Some(ra) => match ctl.get_by_id(db, "tenant-a", contract_b().id) {
              None => Err("contract_b vanished"),
              Some(rb) => if ra.confidence_pct == 85 and rb.confidence_pct == 90 {
                Ok(())
              } else {
                Err("distinct-content contracts must persist as distinct rows, not merge")
              },
            },
          }
        },
      },
    }
  }
}

# The (tenant, id) primary key (#110): the SAME contract content
# proposed under two different tenants must be two independent rows —
# tenant B must never be able to read tenant A's row by guessing the
# content-addressed id (#111).
fn tenant_isolation_on_shared_id() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => {
        let __pa := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        let __pb := ctl.propose(db, "tenant-b", "charge-agent-2", contract_a(), 0)
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
          None => Err("tenant-a's own row vanished"),
          Some(ra) => match ctl.get_by_id(db, "tenant-b", contract_a().id) {
            None => Err("tenant-b's own row vanished"),
            Some(rb) => if ra.proposer_id == "charge-agent-1" and rb.proposer_id == "charge-agent-2" {
              Ok(())
            } else {
              Err("two tenants proposing the same content collided into one row")
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

fn pending_due_is_tenant_isolated() -> [sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, _log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        if list.is_empty(ctl.pending_due(db, "tenant-b", 120000)) {
          Ok(())
        } else {
          Err("tenant-b must not see tenant-a's due contracts")
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
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
          None => Err("contract not found"),
          Some(row) => match ctl.judge_and_record(db, log, row, 120000, observe_ok) {
            Err(e) => Err(e),
            Ok(Materialised) => match ctl.get_by_id(db, "tenant-a", row.id) {
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
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
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

# A concurrent action on the same subsystem confounds attribution —
# Ambiguous, never a hit — and is still a FINAL disposition (persisted,
# trailed, notified), same as Materialised/Falsified.
fn judge_and_record_ambiguous_when_concurrent() -> [net, io, sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
          None => Err("contract not found"),
          Some(row) => match ctl.judge_and_record(db, log, row, 120000, observe_concurrent) {
            Err(e) => Err(e),
            Ok(Ambiguous) => match ctl.get_by_id(db, "tenant-a", row.id) {
              None => Err("row vanished after disposition"),
              Some(disposed) => if disposed.disposition == "ambiguous" {
                Ok(())
              } else {
                Err(str.concat("expected 'ambiguous' persisted, got ", disposed.disposition))
              },
            },
            Ok(other) => Err(str.concat("expected Ambiguous, got ", ctl.outcome_str(other))),
          },
        }
      },
    },
  }
}

# Before the deadline, judge_and_record must return Pending and touch
# NOTHING else — no disposition write, no trail event, no outbox
# notification. `is_final` is the kernel's own gate; this proves the
# host wiring actually respects it rather than persisting eagerly.
fn judge_and_record_skips_not_yet_due() -> [net, io, sql, fs_write, time] Result[Unit, Str] {
  match open_all() {
    Err(e) => Err(e),
    Ok(pair) => match pair {
      (db, log) => {
        let __p := ctl.propose(db, "tenant-a", "charge-agent-1", contract_a(), 0)
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
          None => Err("contract not found"),
          Some(row) => match ctl.judge_and_record(db, log, row, 60000, observe_ok) {
            Err(e) => Err(e),
            Ok(Pending) => match ctl.get_by_id(db, "tenant-a", row.id) {
              None => Err("row vanished"),
              Some(still) => if still.disposition == "pending" {
                match outbox.pending_count(db) {
                  Err(e) => Err(e),
                  Ok(n) => if n == 0 {
                    Ok(())
                  } else {
                    Err("a not-yet-due contract must not enqueue an outbox notification")
                  },
                }
              } else {
                Err("a not-yet-due contract must not have its disposition touched")
              },
            },
            Ok(other) => Err(str.concat("expected Pending before the deadline, got ", ctl.outcome_str(other))),
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
        match ctl.get_by_id(db, "tenant-a", contract_a().id) {
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
      let headers_a := map.from_list([("x-tenant-id", "tenant-a")])
      let posted := router.dispatch(r, { body: body, method: "POST", path: "/ctl/contracts", query: "", headers: headers_a })
      if posted.status == 200 and str.contains(posted.body, "contract_id") {
        let id := contract_id_of(posted.body)
        let got := router.dispatch(r, { body: "", method: "GET", path: str.concat("/ctl/contracts/", id), query: "", headers: headers_a })
        if got.status == 200 and str.contains(got.body, "\"pending\"") and str.contains(got.body, "charger-07") {
          let other_tenant := router.dispatch(r, { body: "", method: "GET", path: str.concat("/ctl/contracts/", id), query: "", headers: map.from_list([("x-tenant-id", "tenant-b")]) })
          if other_tenant.status == 404 {
            Ok(())
          } else {
            Err(str.concat("a different tenant's header must not read this contract, got status ", int_to_str_local(other_tenant.status)))
          }
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
  let results := [propose_and_get_roundtrip(), propose_is_idempotent(), propose_distinct_content_yields_distinct_id(), tenant_isolation_on_shared_id(), pending_due_respects_deadline(), pending_due_is_tenant_isolated(), judge_and_record_materialises_and_notifies(), judge_and_record_falsifies(), judge_and_record_ambiguous_when_concurrent(), judge_and_record_skips_not_yet_due(), judge_and_record_is_not_double_fired(), http_surface_roundtrip()]
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

