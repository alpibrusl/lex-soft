# tests/test_outbox.lex — acceptance tests for outbox.lex (#130), the durable
# agent-side send queue offline tolerance depends on ("trucks accumulate
# messages during connectivity gaps... the platform never sees a gap, only a
# delay"). Untested until now, despite being the module whose whole job is a
# delivery guarantee. Asserts:
#   - init is idempotent (safe to call on every boot).
#   - enqueue writes a real lex_jobs row under queue "outbox" / handler "send"
#     with the documented {from,to,topic,body} JSON payload shape — a
#     mismatch here would silently break the flush_loop consumer contract
#     since nothing else asserts wire compatibility between the two ends.
#   - pending_count reflects real queue depth.
#   - AT-LEAST-ONCE delivery under a simulated failure: dispatching against an
#     unreachable endpoint retries (job stays deliverable, attempts climb)
#     rather than dropping the message, and only gives up — landing in
#     'failed', inspectable, never silently vanished — once max_attempts is
#     exhausted. This reproduces flush_loop's own dispatch closure against
#     jobs.work_one (bounded) rather than flush_loop itself (an intentional
#     infinite loop unsuitable for a deterministic test).

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.bytes" as bytes

import "std.http" as http

import "lex-jobs/src/jobs" as jobs

import "lex-schema/json_value" as jv

import "../src/outbox" as outbox

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn init_is_idempotent() -> [sql, fs_write] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match outbox.init(db) {
      Err(e) => Err(e),
      Ok(_) => match outbox.init(db) {
        Err(e) => Err(str.concat("second init must be a safe no-op, got: ", e)),
        Ok(_) => Ok(()),
      },
    },
  }
}

fn enqueue_and_pending_count_roundtrip() -> [sql, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := outbox.init(db)
      match outbox.pending_count(db) {
        Err(e) => Err(e),
        Ok(0) => match outbox.enqueue(db, "truck-1", "platform", "status.update", "{\"lat\":1}") {
          Err(e) => Err(e),
          Ok(_) => match outbox.pending_count(db) {
            Err(e) => Err(e),
            Ok(1) => Ok(()),
            Ok(n) => Err(str.concat("expected pending_count 1 after one enqueue, got ", int_str(n))),
          },
        },
        Ok(n) => Err(str.concat("expected pending_count 0 on a fresh queue, got ", int_str(n))),
      }
    },
  }
}

# The exact wire shape flush_loop's "send" handler depends on: queue "outbox",
# handler "send", and a JSON payload carrying from/to/topic/body untouched.
fn enqueue_writes_documented_payload_shape() -> [sql, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := outbox.init(db)
      match outbox.enqueue(db, "truck-1", "platform", "status.update", "{\"lat\":1}") {
        Err(e) => Err(e),
        Ok(_) => {
          let rows :: Result[List[{ queue :: Str, handler :: Str, payload :: Str }], SqlError] := sql.query(db, "SELECT queue, handler, payload FROM lex_jobs LIMIT 1", [])
          match rows {
            Err(e) => Err(e.message),
            Ok(rs) => match list.head(rs) {
              None => Err("enqueue did not write a lex_jobs row"),
              Some(row) => if row.queue != "outbox" {
                Err(str.concat("expected queue \"outbox\", got ", row.queue))
              } else {
                if row.handler != "send" {
                  Err(str.concat("expected handler \"send\", got ", row.handler))
                } else {
                  match jv.parse(row.payload) {
                    Err(_) => Err(str.concat("payload is not valid JSON: ", row.payload)),
                    Ok(j) => if jfield(j, "from") == "truck-1" and jfield(j, "to") == "platform" and jfield(j, "topic") == "status.update" and jfield(j, "body") == "{\"lat\":1}" {
                      Ok(())
                    } else {
                      Err(str.concat("payload fields don't match what was enqueued: ", row.payload))
                    },
                  }
                }
              },
            },
          }
        },
      }
    },
  }
}

fn jfield(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn int_str(n :: Int) -> Str {
  jv.stringify(JInt(n))
}

# flush_loop's own dispatch closure, reproduced here so it can be driven
# through jobs.work_one (bounded) instead of jobs.work_forever (which
# flush_loop calls and which never returns, making it unusable in a
# deterministic test). Same handler name, same http.post call, same error
# mapping — only the "forever" wrapper is left out.
fn outbox_dispatch(deliver_url :: Str, handler :: Str, payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
  match handler {
    "send" => match http.post(deliver_url, bytes.from_str(payload), "application/json") {
      Err(e) => Retry(str.concat("http: ", match e {
        TimeoutError => "timeout",
        TlsError(m) => m,
        NetworkError(m) => m,
        DecodeError(m) => m,
      })),
      Ok(_) => Done,
    },
    _ => Fail(str.concat("unknown handler: ", handler)),
  }
}

# An address nothing listens on: the connection is refused immediately
# (a real, deterministic "simulated failure" — no mock server needed).
fn unreachable_url() -> Str {
  "http://127.0.0.1:1/v1/messages"
}

fn status_of(db :: Db) -> [sql, fs_read] Str {
  let rows :: Result[List[{ status :: Str }], SqlError] := sql.query(db, "SELECT status FROM lex_jobs LIMIT 1", [])
  match rows {
    Err(_) => "?",
    Ok(rs) => match list.head(rs) {
      None => "?",
      Some(r) => r.status,
    },
  }
}

fn attempts_of(db :: Db) -> [sql, fs_read] Int {
  let rows :: Result[List[{ attempts :: Int }], SqlError] := sql.query(db, "SELECT attempts FROM lex_jobs LIMIT 1", [])
  match rows {
    Err(_) => -1,
    Ok(rs) => match list.head(rs) {
      None => -1,
      Some(r) => r.attempts,
    },
  }
}

# One failed delivery attempt against an unreachable endpoint must requeue
# the job (status back to 'pending', attempts incremented) — the message is
# NOT dropped just because the platform was unreachable once.
fn one_failed_attempt_requeues_not_drops() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := outbox.init(db)
      let __e := outbox.enqueue(db, "truck-1", "platform", "status.update", "{}")
      match jobs.work_one(db, "outbox", fn (h :: Str, p :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
        outbox_dispatch(unreachable_url(), h, p)
      }) {
        Err(e) => Err(e),
        Ok(None) => Err("expected the enqueued job to be claimed"),
        Ok(Some(_)) => if status_of(db) == "pending" and attempts_of(db) == 1 {
          Ok(())
        } else {
          Err(str.join(["expected status=pending attempts=1 after one failed attempt, got status=", status_of(db), " attempts=", int_str(attempts_of(db))], ""))
        },
      }
    },
  }
}

# Exhausting max_attempts (default 3) against a still-unreachable endpoint
# lands the job in 'failed' — inspectable via pending_count/status, never
# silently vanished. This is the "gives up loudly, not silently" half of
# at-least-once: the message is never both undelivered AND untracked.
fn exhausted_retries_land_in_failed_not_lost() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := outbox.init(db)
      let __e := outbox.enqueue(db, "truck-1", "platform", "status.update", "{}")
      let dispatch := fn (h :: Str, p :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
        outbox_dispatch(unreachable_url(), h, p)
      }
      let __a1 := jobs.work_one(db, "outbox", dispatch)
      let __a2 := jobs.work_one(db, "outbox", dispatch)
      let __a3 := jobs.work_one(db, "outbox", dispatch)
      match outbox.pending_count(db) {
        Err(e) => Err(e),
        Ok(pending) => if pending == 0 and status_of(db) == "failed" {
          Ok(())
        } else {
          Err(str.join(["expected pending_count=0, status=failed after exhausting attempts, got pending=", int_str(pending), " status=", status_of(db)], ""))
        },
      }
    },
  }
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Unit {
  let results := [init_is_idempotent(), enqueue_and_pending_count_roundtrip(), enqueue_writes_documented_payload_shape(), one_failed_attempt_requeues_not_drops(), exhausted_retries_land_in_failed_not_lost()]
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

