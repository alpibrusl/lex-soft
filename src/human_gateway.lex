# human_gateway.lex — the human as just another A2A agent (#50/#52).
#
# The agnostic trick for human-in-the-loop: instead of inventing a "human API",
# model the human as an agent whose runtime is a person. The gateway is a
# normal AgentDef (capability `approval.request`) mounted like any persona —
# discoverable, addressable via tasks/send, and framework-agnostic: a LangGraph
# or OpenAI-SDK agent escalates to it exactly like a lex agent does.
#
#   agent  --tasks/send approval.request-->  human-gateway  (approval recorded,
#                                            approval_id returned immediately)
#   human  --dashboard / POST /approvals/:id/decide-->      decision, Ed25519-
#                                            signed with the deployment seed,
#                                            appended to the settlement trail
#   agent/caller --GET /approvals/:id-->     polls status; re-sends the original
#                                            task (same contextId) to resume
#
# The signature makes approvals PROVABLE, not just trusted: the verdict layer
# can re-check "a human authorized this" from the trail + the published
# federation key (`/.well-known/agent-key.json`), the same key material as the
# signed node identity.

import "std.sql" as sql

import "std.map" as map

import "std.str" as str

import "std.list" as list

import "std.time" as time

import "std.crypto" as crypto

import "lex-crypto/src/ed25519" as ed

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-trail/log" as tlog

import "./settlement" as settlement

import "./registry" as reg

import "./identity" as identity

import "./notifications" as notifications

type Approval = { id :: Str, from_agent :: Str, question :: Str, kind :: Str, detail :: Str, status :: Str, decision :: Str, decided_by :: Str, signature :: Str, created_at :: Str, decided_at :: Str }

fn cols() -> Str {
  "id, from_agent, question, kind, detail, status, decision, decided_by, signature, created_at, decided_at"
}

fn init(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS approvals (id TEXT PRIMARY KEY, from_agent TEXT NOT NULL, question TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'other', detail TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'pending', decision TEXT NOT NULL DEFAULT '', decided_by TEXT NOT NULL DEFAULT '', signature TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, decided_at TEXT NOT NULL DEFAULT '')", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Chain trail events off the current head (the ARM lesson: content-addressed
# ids dedup identical events unless parented distinctly).
fn head_parent(log :: tlog.Log) -> [sql] Option[Str] {
  match tlog.head(log) {
    Some(e) => Some(e.id),
    None => None,
  }
}

# The account that owns an agent (agent → its tenant/org → account). "" if the
# agent isn't registered or its org has no account — best-effort, never fatal.
fn account_for_agent(db :: Db, agent_id :: Str) -> [sql, fs_read] Str {
  match reg.find_by_id(db, agent_id) {
    Ok(Some(a)) => match identity.account_by_org(db, a.tenant) {
      Ok(Some(acct)) => acct.id,
      _ => "",
    },
    _ => "",
  }
}

# Record a new escalation. Returns the approval id the requester will cite.
fn request(db :: Db, from_agent :: Str, question :: Str, kind :: Str, detail :: Str) -> [sql, fs_read, fs_write, random, time] Result[Str, Str] {
  let id := crypto.random_str_hex(16)
  let now := time.now_str()
  let q := "INSERT INTO approvals (id, from_agent, question, kind, detail, status, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?)"
  match sql.exec(db, q, [PStr(id), PStr(from_agent), PStr(question), PStr(kind), PStr(detail), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => {
      let log := settlement.trail_on(db)
      let payload := jv.stringify(JObj([("approval_id", JStr(id)), ("from_agent", JStr(from_agent)), ("kind", JStr(kind))]))
      let __t := tlog.append(log, "escalation.requested", head_parent(log), payload)
      let acct := account_for_agent(db, from_agent)
      let __n := if str.is_empty(acct) {
        ""
      } else {
        notifications.enqueue(db, acct, "escalation.raised", payload)
      }
      Ok(id)
    },
  }
}

# The canonical text a human decision signs: verifiable by anyone holding the
# deployment's published Ed25519 key.
fn canonical(id :: Str, decision :: Str, decided_by :: Str, decided_at :: Str) -> Str {
  str.join([id, "|", decision, "|", decided_by, "|", decided_at], "")
}

# Record the human's decision, Ed25519-signed with the deployment seed.
# Returns the signature (b64).
fn decide(db :: Db, sign_seed :: Bytes, id :: Str, approve :: Bool, decided_by :: Str) -> [sql, fs_write, crypto, time] Result[Str, Str] {
  let decision := if approve {
    "approved"
  } else {
    "denied"
  }
  let now := time.now_str()
  let sig := match ed.sign_text(sign_seed, canonical(id, decision, decided_by, now)) {
    Ok(s) => s,
    Err(_) => "",
  }
  if str.is_empty(sig) {
    Err("signing failed")
  } else {
    let q := "UPDATE approvals SET status='decided', decision=?, decided_by=?, signature=?, decided_at=? WHERE id=? AND status='pending'"
    match sql.exec(db, q, [PStr(decision), PStr(decided_by), PStr(sig), PStr(now), PStr(id)]) {
      Err(e) => Err(e.message),
      Ok(_) => {
        let log := settlement.trail_on(db)
        let payload := jv.stringify(JObj([("approval_id", JStr(id)), ("decision", JStr(decision)), ("decided_by", JStr(decided_by)), ("signature", JStr(sig)), ("decided_at", JStr(now))]))
        let __t := tlog.append(log, "escalation.decided", head_parent(log), payload)
        Ok(sig)
      },
    }
  }
}

# Anyone holding the deployment's published key can re-verify a decision.
fn verify_decision(pub_b64 :: Str, id :: Str, decision :: Str, decided_by :: Str, decided_at :: Str, sig :: Str) -> [crypto] Bool {
  ed.verify_text(pub_b64, canonical(id, decision, decided_by, decided_at), sig)
}

fn find(db :: Db, id :: Str) -> [sql, fs_read] Option[Approval] {
  let q := str.join(["SELECT ", cols(), " FROM approvals WHERE id=?"], "")
  let rows :: Result[List[Approval], SqlError] := sql.query(db, q, [PStr(id)])
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn pending(db :: Db) -> [sql, fs_read] List[Approval] {
  let q := str.join(["SELECT ", cols(), " FROM approvals WHERE status='pending' ORDER BY created_at"], "")
  let rows :: Result[List[Approval], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn approval_json(a :: Approval) -> jv.Json {
  JObj([("id", JStr(a.id)), ("from_agent", JStr(a.from_agent)), ("question", JStr(a.question)), ("kind", JStr(a.kind)), ("detail", JStr(a.detail)), ("status", JStr(a.status)), ("decision", JStr(a.decision)), ("decided_by", JStr(a.decided_by)), ("signature", JStr(a.signature)), ("created_at", JStr(a.created_at)), ("decided_at", JStr(a.decided_at))])
}

# ── The gateway as an A2A agent ───────────────────────────────────────────────
fn gateway_capability() -> cap.Capability {
  cap.inbound("approval.request", "Request human approval for an action an agent cannot take autonomously. The message text is JSON {from_agent, question, kind, detail}; the reply is JSON {approval_id, status}.", { title: "ApprovalRequest", description: "An escalation to a human decision-maker.", fields: [sch.required_str("text", [])] })
}

fn first_text(m :: msg.Message) -> Str {
  list.fold(m.parts, "", fn (acc :: Str, p :: msg.Part) -> Str {
    if str.is_empty(acc) {
      match p {
        TextPart(s) => s,
        _ => acc,
      }
    } else {
      acc
    }
  })
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn make_handler(db :: Db) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
    let body := match jv.parse(first_text(m)) {
      Ok(j) => j,
      Err(_) => JObj([]),
    }
    let from_agent := jstr(body, "from_agent")
    let question := if str.is_empty(jstr(body, "question")) {
      first_text(m)
    } else {
      jstr(body, "question")
    }
    match request(db, from_agent, question, jstr(body, "kind"), jstr(body, "detail")) {
      Err(e) => { next_state: tk.TSFailed, reply: Some(msg.agent_text(str.concat("escalation failed: ", e))), artifacts: [] },
      Ok(id) => {
        let reply := jv.stringify(JObj([("approval_id", JStr(id)), ("status", JStr("pending"))]))
        let art := { name: "approval", index: 0, parts: [DataPart(JObj([("approval_id", JStr(id)), ("status", JStr("pending")), ("decide_url", JStr(str.concat("/approvals/", str.concat(id, "/decide"))))]))] }
        { next_state: tk.TSCompleted, reply: Some(msg.agent_text(reply)), artifacts: [art] }
      },
    }
  }
}

fn make_agent_def(db :: Db, id :: Str, base_url :: Str) -> srv.AgentDef {
  let capability := gateway_capability()
  let c := card.make(id, "Human approval gateway — escalations are decided by a person.", "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: make_handler(db) }])
}

# ── HTTP surface for the human + the polling requester ───────────────────────
# GET  /approvals            — pending approvals (the dashboard inbox)
# GET  /approvals/:id        — one approval, incl. decision + signature
# POST /approvals/:id/decide — the human decision: {"approve": bool, "by": str}
fn mount(r :: router.Router, db :: Db, sign_seed :: Bytes, pub_b64 :: Str) -> router.Router {
  let with_list := router.route_effectful(r, "GET", "/approvals", fn (_c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    resp.json(jv.stringify(JObj([("approvals", JList(list.map(pending(db), fn (a :: Approval) -> jv.Json {
      approval_json(a)
    })))])))
  })
  let with_get := router.route_effectful(with_list, "GET", "/approvals/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match find(db, id) {
      None => { status: 404, body: "{\"error\":\"unknown approval\"}", headers: map.from_list([("content-type", "application/json")]) },
      Some(a) => resp.json(jv.stringify(approval_json(a))),
    }
  })
  router.route_effectful(with_get, "POST", "/approvals/:id/decide", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let id := match ctx.path_param(c, "id") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let approve := match jv.get_field(j, "approve") {
          Some(JBool(b)) => b,
          _ => false,
        }
        let by := if str.is_empty(jstr(j, "by")) {
          "human"
        } else {
          jstr(j, "by")
        }
        match find(db, id) {
          None => { status: 404, body: "{\"error\":\"unknown approval\"}", headers: map.from_list([("content-type", "application/json")]) },
          Some(a) => if a.status == "pending" {
            match decide(db, sign_seed, id, approve, by) {
              Err(e) => resp.json(str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(sig) => resp.json(jv.stringify(JObj([("ok", JBool(true)), ("id", JStr(id)), ("decision", JStr(if approve {
                "approved"
              } else {
                "denied"
              })), ("signature", JStr(sig)), ("public_key", JStr(pub_b64))]))),
            }
          } else {
            resp.bad_request("{\"error\":\"already decided\"}")
          },
        }
      },
    }
  })
}

