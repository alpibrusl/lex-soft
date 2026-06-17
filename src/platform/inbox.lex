# platform/inbox.lex — per-agent inbox routing on the platform side.
#
# Messages arriving at POST /v1/messages are handed here. The platform
# checks the agent's registered inbox_url to decide delivery mode:
#
#   push  — agent has a reachable inbox_url (TMS, depot running in cloud).
#            Message is enqueued in the "push" queue; the push_worker
#            delivers via A2A HTTP POST with retry. The agent never polls.
#
#   pull  — inbox_url is empty (truck, edge device behind NAT / cell).
#            Message is enqueued in "pull:{agent_id}". The agent polls
#            GET /v1/messages/{id}/pull on reconnect to drain its inbox.
#
# Both queues are backed by the platform's Postgres DB (passed as `db`).
# lex-jobs handles persistence, retry and at-least-once guarantees.

import "lex-jobs/src/jobs" as jobs

import "../registry" as reg

import "std.http" as http

import "std.bytes" as bytes

import "std.str" as str

import "std.int" as int

import "lex-schema/json_value" as jv

fn pull_queue(agent_id :: Str) -> Str {
  str.concat("pull:", agent_id)
}

# Build an A2A JSON-RPC tasks/send message from a platform envelope.
fn build_a2a_msg(from :: Str, topic :: Str, body :: Str) -> Str {
  let payload := if str.is_empty(body) {
    "{}"
  } else {
    body
  }
  let text := str.join(["From: ", from, "\nTopic: ", topic, "\nPayload: ", payload], "")
  jv.stringify(JObj([("jsonrpc", JStr("2.0")), ("id", JStr("1")), ("method", JStr("tasks/send")), ("params", JObj([("id", JStr(str.concat("msg-", from))), ("contextId", JStr(str.concat("ctx-", from))), ("skill", JStr("handle")), ("message", JObj([("role", JStr("user")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr(text))])]))]))]))]))
}

# Route an incoming message to the correct delivery path for `to_agent_id`.
#   push — agent has a reachable inbox_url: deliver synchronously via A2A HTTP.
#   pull — inbox_url empty: enqueue in pull:{agent_id} for the agent to poll.
fn deliver(db :: Db, to_agent_id :: Str, payload :: Str) -> [sql, fs_read, fs_write, time, net] Result[Unit, Str] {
  match reg.find_by_id(db, to_agent_id) {
    Err(_) => match jobs.enqueue(db, pull_queue(to_agent_id), "pull", payload) {
      Err(e) => Err(e),
      Ok(_) => Ok(()),
    },
    Ok(None) => match jobs.enqueue(db, pull_queue(to_agent_id), "pull", payload) {
      Err(e) => Err(e),
      Ok(_) => Ok(()),
    },
    Ok(Some(ref)) => if str.is_empty(ref.inbox_url) {
      match jobs.enqueue(db, pull_queue(to_agent_id), "pull", payload) {
        Err(e) => Err(e),
        Ok(_) => Ok(()),
      }
    } else {
      let parsed := match jv.parse(payload) {
        Err(_) => JObj([]),
        Ok(j) => j,
      }
      let from := match jv.get_field(parsed, "from") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let topic := match jv.get_field(parsed, "topic") {
        Some(JStr(s)) => s,
        _ => "message",
      }
      let body := match jv.get_field(parsed, "body") {
        Some(JStr(s)) => s,
        _ => "{}",
      }
      let a2a := build_a2a_msg(from, topic, body)
      match http.post(ref.inbox_url, bytes.from_str(a2a), "application/json") {
        Err(e) => Err(str.concat("push failed: ", match e {
          TimeoutError => "timeout",
          TlsError(m) => m,
          NetworkError(m) => m,
          DecodeError(m) => m,
        })),
        Ok(_) => Ok(()),
      }
    },
  }
}

# Pull the next queued message for an edge agent. Acks immediately
# (at-most-once). Returns None when the inbox is empty.
fn pull_next(db :: Db, agent_id :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Option[Str], Str] {
  match jobs.work_one(db, pull_queue(agent_id), fn (_handler :: Str, _payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
    Done
  }) {
    Err(e) => Err(e),
    Ok(None) => Ok(None),
    Ok(Some(row)) => Ok(Some(row.payload)),
  }
}

# Background push worker. Processes the "push" queue and delivers each
# message to the cloud agent's A2A inbox_url. Run via conc.spawn.
fn push_worker(db :: Db, sleep_ms :: Int) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  jobs.work_forever(db, "push", sleep_ms, fn (handler :: Str, payload :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] jobs.WorkOutcome {
    let agent_id := handler
    match reg.find_by_id(db, agent_id) {
      Err(e) => Fail(str.concat("registry error: ", e)),
      Ok(None) => Fail(str.concat("agent not found: ", agent_id)),
      Ok(Some(ref)) => match http.post(ref.inbox_url, bytes.from_str(payload), "application/json") {
        Err(e) => Retry(str.concat("http: ", match e {
          TimeoutError => "timeout",
          TlsError(m) => m,
          NetworkError(m) => m,
          DecodeError(m) => m,
        })),
        Ok(_) => Done,
      },
    }
  })
}

# How many messages are waiting in the pull inbox for a given agent.
fn pull_pending(db :: Db, agent_id :: Str) -> [sql] Result[Int, Str] {
  jobs.count_pending(db, pull_queue(agent_id))
}

