# tests/test_escalation.lex — acceptance tests for #50 (autonomous agents +
# human-in-the-loop escalation). Asserts:
#   1. The gateway records an escalation and a human decision flips it to
#      decided, with an Ed25519 signature that VERIFIES against the deployment's
#      published key (and tampered fields fail verification).
#   2. A decision is final — a second decide is rejected.
#   3. The gateway A2A handler answers an `approval.request` message with a
#      pending approval_id (the reply any framework's agent parses).
#   4. Scheduler subscriptions: not due before their interval, due after,
#      re-armed by mark_ran; empty inbox_url falls back to the registry.
#   5. The HTTP surface works end-to-end via dispatch: GET /approvals lists the
#      pending item, POST /approvals/:id/decide signs + settles it, and the
#      schedules CRUD round-trips.
#   6. Both trail events (escalation.requested / escalation.decided) land in
#      the settlement trail.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.time" as time

import "lex-crypto/src/ed25519" as ed

import "lex-schema/json_value" as jv

import "lex-agent/src/message" as msg

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/human_gateway" as hg

import "../src/scheduler" as sched

fn seed() -> Bytes {
  crypto.sha256(bytes.from_str("escalation-test"))
}

fn pub() -> [crypto] Str {
  match ed.public_key_b64(seed()) {
    Ok(p) => p,
    Err(_) => "",
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# 1 + 6. request → pending → decide(approve): signed, verifiable, trailed.
fn approve_flow_signs_and_verifies() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := hg.init(db)
      match hg.request(db, "truck-01", "Approve a 40 EUR charge (cap is 30)?", "spend", "SoC 18%") {
        Err(e) => Err(e),
        Ok(id) => match hg.decide(db, seed(), id, true, "alfonso") {
          Err(e) => Err(e),
          Ok(sig) => match hg.find(db, id) {
            None => Err("approval vanished after decide"),
            Some(a) => if a.status == "decided" and a.decision == "approved" {
              if hg.verify_decision(pub(), a.id, a.decision, a.decided_by, a.decided_at, sig) {
                if hg.verify_decision(pub(), a.id, "denied", a.decided_by, a.decided_at, sig) {
                  Err("a tampered decision must NOT verify")
                } else {
                  let evs :: Result[List[{ kind :: Str }], SqlError] := sql.query(db, "SELECT kind FROM events WHERE kind LIKE 'escalation.%' ORDER BY kind", [])
                  match evs {
                    Err(e) => Err(e.message),
                    Ok(rows) => if list.len(rows) == 2 {
                      Ok(())
                    } else {
                      Err("expected escalation.requested + escalation.decided in the trail")
                    },
                  }
                }
              } else {
                Err("signature must verify against the published key")
              }
            } else {
              Err(str.concat("unexpected status/decision: ", str.concat(a.status, a.decision)))
            },
          },
        },
      }
    },
  }
}

# 2. Decisions are final.
fn decision_is_final() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := hg.init(db)
      match hg.request(db, "truck-02", "Trust new counterparty?", "trust", "") {
        Err(e) => Err(e),
        Ok(id) => {
          let __d1 := hg.decide(db, seed(), id, false, "ops")
          let __d2 := hg.decide(db, seed(), id, true, "attacker")
          match hg.find(db, id) {
            None => Err("approval vanished"),
            Some(a) => if a.decision == "denied" and a.decided_by == "ops" {
              Ok(())
            } else {
              Err("a second decide must not overwrite the first")
            },
          }
        },
      }
    },
  }
}

# 3. The gateway answers approval.request over A2A with a pending approval_id.
fn gateway_handler_replies_with_approval_id() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := hg.init(db)
      let handler := hg.make_handler(db)
      let req := jv.stringify(JObj([("from_agent", JStr("grid-coordinator")), ("question", JStr("Dispatch 50kWh over the safety floor?")), ("kind", JStr("policy")), ("detail", JStr(""))]))
      let outcome := handler(msg.user_text(req))
      match outcome.reply {
        None => Err("gateway must reply"),
        Some(m) => {
          let text := list.fold(m.parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
            match p {
              TextPart(s) => if str.is_empty(acc) {
                s
              } else {
                acc
              },
              _ => acc,
            }
          })
          match jv.parse(text) {
            Err(_) => Err(str.concat("reply is not JSON: ", text)),
            Ok(j) => {
              let id := jstr(j, "approval_id")
              if str.is_empty(id) {
                Err("reply must carry approval_id")
              } else {
                match hg.find(db, id) {
                  Some(a) => if a.status == "pending" and a.from_agent == "grid-coordinator" {
                    Ok(())
                  } else {
                    Err("approval row not pending / wrong agent")
                  },
                  None => Err("approval_id not persisted"),
                }
              }
            },
          }
        },
      }
    },
  }
}

# 4. Scheduler due-windows + registry inbox fallback.
fn scheduler_due_and_rearm() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __i := sched.init(db)
      let __r := reg.register(db, "truck-01", "truck", "T1", "http://node/agents/truck-01/", [])
      match sched.subscribe(db, "truck-01", "", "tick", 600) {
        Err(e) => Err(e),
        Ok(id) => {
          let now := time.now_ms() / 1000
          if list.is_empty(sched.due(db, now)) {
            let later := now + 601
            match list.head(sched.due(db, later)) {
              None => Err("schedule must be due after its interval"),
              Some(s) => if s.inbox_url == "http://node/agents/truck-01/" {
                let __ran := sched.mark_ran(db, id, later)
                if list.is_empty(sched.due(db, later)) {
                  Ok(())
                } else {
                  Err("mark_ran must re-arm next_at past now")
                }
              } else {
                Err("empty inbox_url must fall back to the registry's")
              },
            }
          } else {
            Err("schedule must NOT be due before its interval")
          }
        },
      }
    },
  }
}

# 5. The HTTP surface end-to-end via dispatch.
fn http_surface_roundtrip() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __i := hg.init(db)
      let __i2 := sched.init(db)
      let __r := reg.register(db, "truck-01", "truck", "T1", "http://node/agents/truck-01/", [])
      let r0 := hg.mount(router.new(), db, seed(), pub())
      let r := sched.mount(r0, db)
      let __q := hg.request(db, "depot-north", "Grant out-of-contract charging?", "policy", "")
      let listed := router.dispatch(r, { body: "", method: "GET", path: "/approvals", query: "", headers: map.from_list([]) })
      if listed.status == 200 and str.contains(listed.body, "depot-north") {
        let id := match list.head(hg.pending(db)) {
          Some(a) => a.id,
          None => "",
        }
        let decided := router.dispatch(r, { body: "{\"approve\":true,\"by\":\"dashboard\"}", method: "POST", path: str.concat("/approvals/", str.concat(id, "/decide")), query: "", headers: map.from_list([]) })
        if decided.status == 200 and str.contains(decided.body, "approved") and str.contains(decided.body, "signature") {
          let sub := router.dispatch(r, { body: "{\"agent_id\":\"truck-01\",\"interval_seconds\":600}", method: "POST", path: "/schedules", query: "", headers: map.from_list([]) })
          let lst := router.dispatch(r, { body: "", method: "GET", path: "/schedules", query: "", headers: map.from_list([]) })
          if sub.status == 200 and lst.status == 200 and str.contains(lst.body, "truck-01") {
            Ok(())
          } else {
            Err(str.concat("schedules CRUD failed: ", lst.body))
          }
        } else {
          Err(str.concat("decide failed: ", decided.body))
        }
      } else {
        Err(str.concat("GET /approvals failed: ", listed.body))
      }
    },
  }
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let results := [approve_flow_signs_and_verifies(), decision_is_final(), gateway_handler_replies_with_approval_id(), scheduler_due_and_rearm(), http_surface_roundtrip()]
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

