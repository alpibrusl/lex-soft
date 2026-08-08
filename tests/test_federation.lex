# tests/test_federation.lex — acceptance tests for federation.lex (#130), the
# domain-agnostic A2A federation surface (mount_agent dispatch auth, the
# onboarding handshake, rate limiting, directory). No dedicated test file
# existed despite this being the module every cross-org call passes through.
# test_tenancy.lex covers relationship-GATED access (#26); this file covers
# the layer beneath it: is the CALLER authenticated at all. Asserts:
#   - mount_agent dispatch with require_token=true rejects a missing bearer
#     token (401) and a garbage/unresolvable one (401) — an unauthenticated
#     call never reaches the handler or the relationship gate.
#   - a genuinely issued credential's token IS accepted (200) — the rejection
#     tests above aren't vacuously true because nothing can ever pass.
#   - POST /connections onboarding: a configured signup_token refuses a
#     request presenting the wrong (or no) token (401) before any account or
#     credential is created, and accepts the matching one (200).
#   - POST /connections onboarding rate-limits a single org's repeated
#     attempts within the hour (429) rather than issuing unbounded credentials.
#   - GET /directory/find?capability= only returns orgs that actually
#     published that capability.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-spec/capability" as cap

import "lex-schema/schema" as sch

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/federation" as fed

import "../src/identity" as identity

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

# ── fixtures ──────────────────────────────────────────────────────────────────
fn ping_capability() -> cap.Capability {
  cap.inbound("handle", "Reply pong.", { title: "Ping", description: "ping", fields: [sch.required_str("text", [])] })
}

fn ping_handler(_m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  { next_state: tk.TSCompleted, reply: Some(msg.agent_text("pong")), artifacts: [] }
}

fn ping_def(id :: Str) -> srv.AgentDef {
  let c := card.make(id, "ping", "0.1.0", str.concat("http://localhost/agents/", id), [ping_capability()])
  srv.make_agent_def(c, [{ capability: ping_capability(), handle: ping_handler }])
}

fn cfg_requiring_token(secret :: Bytes, signup_token :: Str) -> fed.FederationConfig {
  { base: "http://localhost", org: "acme", secret: secret, prev_secrets: [], ttl: 3600, sign_seed: crypto.sha256(bytes.from_str("d")), pub_b64: "", require_token: true, signup_token: signup_token, hs256_dispatch: true }
}

fn dispatch_req(tok :: Str) -> ctx.RawRequest {
  let hdrs := if str.is_empty(tok) {
    map.from_list([])
  } else {
    map.from_list([("authorization", str.concat("Bearer ", tok))])
  }
  { body: "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"tasks/send\",\"params\":{\"message\":{\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}]}}}", method: "POST", path: "/agents/depot-1/", query: "", headers: hdrs }
}

# ── mount_agent dispatch auth ────────────────────────────────────────────────
fn dispatch_missing_token_is_rejected() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "")
      let r := fed.mount_agent(router.new(), db, ping_def("depot-1"), "depot-1", cfg)
      let res := router.dispatch(r, dispatch_req(""))
      assert_true(res.status == 401, str.concat("require_token=true with no bearer token must 401, got ", int_str(res.status)))
    },
  }
}

fn dispatch_garbage_token_is_rejected() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "")
      let r := fed.mount_agent(router.new(), db, ping_def("depot-1"), "depot-1", cfg)
      let res := router.dispatch(r, dispatch_req("not-a-real-token"))
      assert_true(res.status == 401, str.concat("an unresolvable bearer token must 401, got ", int_str(res.status)))
    },
  }
}

# A genuinely issued credential must be accepted — proves the two rejection
# tests above are testing real auth, not a handler that always 401s. depot-1
# is registered under a real tenant so this also exercises caller_authorized's
# tenant-ownership check (#132): the credential's org must match the target
# agent's own tenant, not just resolve to *some* subject.
fn dispatch_valid_credential_is_accepted() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __reg := reg.register_in(db, "acme-org", "depot-1", "depot", "Depot 1", "http://x/d1", [])
      let secret := bytes.from_str("s")
      let cfg := cfg_requiring_token(secret, "")
      match identity.issue_credential(db, secret, "acme", "acct-1", "acme-org", "", "peer", 3600) {
        Err(e) => Err(e),
        Ok(ic) => {
          let r := fed.mount_agent(router.new(), db, ping_def("depot-1"), "depot-1", cfg)
          let res := router.dispatch(r, dispatch_req(ic.token))
          assert_true(res.status == 200, str.concat("a real, unrevoked credential must be accepted, got ", int_str(res.status)))
        },
      }
    },
  }
}

# ── onboarding: signup_token gate ────────────────────────────────────────────
fn conn_body(org :: Str, signup_token :: Str) -> Str {
  jv.stringify(JObj([("org", JStr(org)), ("signup_token", JStr(signup_token)), ("agents", JList([]))]))
}

fn conn_req(body :: Str) -> ctx.RawRequest {
  { body: body, method: "POST", path: "/connections", query: "", headers: map.from_list([]) }
}

fn onboarding_wrong_signup_token_is_refused() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "correct-token")
      let r := fed.mount_federation(router.new(), db, db, cfg)
      let res := router.dispatch(r, conn_req(conn_body("acme-partner", "wrong-token")))
      if res.status == 401 {
        match identity.get_account(db, "acme-partner") {
          Ok(None) => Ok(()),
          Ok(Some(_)) => Err("a refused onboarding must not have created an account"),
          Err(e) => Err(e),
        }
      } else {
        Err(str.concat("a wrong signup_token must 401, got ", int_str(res.status)))
      }
    },
  }
}

fn onboarding_missing_signup_token_is_refused() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "correct-token")
      let r := fed.mount_federation(router.new(), db, db, cfg)
      let res := router.dispatch(r, conn_req(conn_body("acme-partner", "")))
      assert_true(res.status == 401, str.concat("a missing signup_token when one is configured must 401, got ", int_str(res.status)))
    },
  }
}

fn onboarding_correct_signup_token_succeeds() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "correct-token")
      let r := fed.mount_federation(router.new(), db, db, cfg)
      let res := router.dispatch(r, conn_req(conn_body("acme-partner", "correct-token")))
      assert_true(res.status == 200 and str.contains(res.body, "\"token\""), str.concat("a correct signup_token must onboard and mint a token, got ", int_str(res.status)))
    },
  }
}

# ── onboarding: per-org rate limit ───────────────────────────────────────────
fn onboarding_rate_limits_after_threshold() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "")
      let r := fed.mount_federation(router.new(), db, db, cfg)
      let statuses := list.map(range(21), fn (_i :: Int) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Int {
        router.dispatch(r, conn_req(conn_body("rate-limited-org", ""))).status
      })
      let saw_429 := list.fold(statuses, false, fn (acc :: Bool, s :: Int) -> Bool {
        acc or s == 429
      })
      assert_true(saw_429, "21 onboarding attempts for the same org within an hour must trip the rate limiter (429) at some point")
    },
  }
}

fn range(n :: Int) -> List[Int] {
  range_from(0, n)
}

fn range_from(i :: Int, n :: Int) -> List[Int] {
  if i >= n {
    []
  } else {
    list.concat([i], range_from(i + 1, n))
  }
}

# ── directory ─────────────────────────────────────────────────────────────────
fn publish_req(org :: Str, caps :: List[Str]) -> ctx.RawRequest {
  let catalog := JObj([("agents", JList([JObj([("id", JStr("a1")), ("capabilities", JList(list.map(caps, fn (c :: Str) -> jv.Json {
    JStr(c)
  })))])]))])
  let body := jv.stringify(JObj([("org", JStr(org)), ("catalog_url", JStr(str.concat("http://", str.concat(org, "/.well-known/agents.json")))), ("catalog", catalog)]))
  { body: body, method: "POST", path: "/directory/publish", query: "", headers: map.from_list([]) }
}

fn find_req(capability :: Str) -> ctx.RawRequest {
  { body: "", method: "GET", path: "/directory/find", query: str.concat("capability=", capability), headers: map.from_list([]) }
}

fn directory_find_only_returns_matching_orgs() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __d := fed.init_directory(db)
      let cfg := cfg_requiring_token(bytes.from_str("s"), "")
      let r := fed.mount_federation(router.new(), db, db, cfg)
      let __p1 := router.dispatch(r, publish_req("voltgrid", ["energy.v2g.dispatch"]))
      let __p2 := router.dispatch(r, publish_req("acme-logistics", ["logistics.truck.handle"]))
      let res := router.dispatch(r, find_req("energy.v2g.dispatch"))
      if str.contains(res.body, "voltgrid") and str.contains(res.body, "acme-logistics") == false {
        Ok(())
      } else {
        Err(str.concat("capability-scoped find must include the publisher and exclude the non-matching org: ", res.body))
      }
    },
  }
}

fn int_str(n :: Int) -> Str {
  jv.stringify(JInt(n))
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let results := [dispatch_missing_token_is_rejected(), dispatch_garbage_token_is_rejected(), dispatch_valid_credential_is_accepted(), onboarding_wrong_signup_token_is_refused(), onboarding_missing_signup_token_is_refused(), onboarding_correct_signup_token_succeeds(), onboarding_rate_limits_after_threshold(), directory_find_only_returns_matching_orgs()]
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

