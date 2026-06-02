# outbox.lex — durable agent-side send queue for offline tolerance.
#
# Every outbound A2A message is written to a local lex-jobs table in
# the agent's SQLite DB before the HTTP attempt is made. A background
# flush_loop drains the queue when the platform is reachable. Trucks
# accumulate messages during connectivity gaps and deliver in order on
# reconnect — the platform never sees a gap, only a delay.
#
# Integration:
#   1. Call outbox.init(local_db) on agent boot.
#   2. Replace direct http.post in send_message tool with outbox.enqueue.
#   3. Spawn outbox.flush_loop in a background actor via conc.spawn.
#
# Queue name:  "outbox"
# Handler:     "send"
# Payload:     JSON { "from", "to", "topic", "body" }

import "lex-jobs/src/jobs" as jobs

import "std.http" as http

import "std.bytes" as bytes

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

# Bootstrap the lex-jobs schema in the agent's local SQLite.
# Safe to call on every boot — idempotent.
fn init(db :: Db) -> [sql] Result[Unit, Str] {
  jobs.init_schema(db)
}

# Enqueue one outbound message. Returns immediately; the flush_loop
# delivers it asynchronously. Safe to call when the platform is
# unreachable — the job survives process restarts via SQLite.
fn enqueue(db :: Db, from_id :: Str, to_id :: Str, topic :: Str, body :: Str) -> [sql, time] Result[Unit, Str] {
  let payload := jv.stringify(JObj([("from", JStr(from_id)), ("to", JStr(to_id)), ("topic", JStr(topic)), ("body", JStr(body))]))
  match jobs.enqueue(db, "outbox", "send", payload) {
    Err(e) => Err(e),
    Ok(_) => Ok(()),
  }
}

# Background flush worker. Blocks forever; run via conc.spawn.
# Retries up to max_attempts (default 3) on network failure,
# then marks the job failed for manual inspection.
fn flush_loop(db :: Db, platform_url :: Str, sleep_ms :: Int) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let deliver_url := str.concat(platform_url, "/v1/messages")
  jobs.work_forever(db, "outbox", sleep_ms, fn (handler :: Str, payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
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
  })
}

# How many messages are waiting to be delivered.
# Useful for a health / status endpoint on the agent.
fn pending_count(db :: Db) -> [sql] Result[Int, Str] {
  jobs.count_pending(db, "outbox")
}

