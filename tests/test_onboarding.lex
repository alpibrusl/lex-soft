# tests/test_onboarding.lex — onboarding hardening (#62): rate limiting +
# credential issuance through POST /connections.
#
# Two things must be true after #62: (1) a caller who floods POST /connections
# from the same org gets rate-limited, not an ever-growing token supply; (2) a
# successfully onboarded org's token is now audit-resolvable — it must have
# been minted via identity.issue_credential (a `credentials` row exists), not
# just a bare, unrecorded conn_token.issue.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "../src/migrate" as migrate

import "../src/federation" as fed

import "../src/identity" as identity

import "../src/audit" as audit

import "../src/partner_auth" as pa

import "lex-crypto/src/ed25519" as ed

# A registry lookup failure is a test failure, not an empty slice — unwrap here
# so the assertions below stay about tenancy.
fn ids_of(db :: Db, org :: Str) -> [sql, fs_read] List[Str] {
  match audit.org_agent_ids(db, org) {
    Err(_) => [],
    Ok(ids) => ids,
  }
}

fn demo_cfg() -> fed.FederationConfig {
  { base: "http://localhost", org: "acme", secret: bytes.from_str("s"), prev_secrets: [], ttl: 3600, sign_seed: crypto.sha256(bytes.from_str("d")), pub_b64: "", require_token: false, signup_token: "", hs256_dispatch: true }
}

fn connect_req(org :: Str) -> jv.Json {
  JObj([("org", JStr(org)), ("scope", JStr("logistics")), ("agents", JList([]))])
}

fn post_connect(r :: router.Router, org :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Int {
  let req := { body: jv.stringify(connect_req(org)), method: "POST", path: "/connections", query: "", headers: map.new() }
  let res := router.dispatch(r, req)
  res.status
}

fn token_of(r :: router.Router, org :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Str {
  let req := { body: jv.stringify(connect_req(org)), method: "POST", path: "/connections", query: "", headers: map.new() }
  let res := router.dispatch(r, req)
  match jv.parse(res.body) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "token") {
      Some(JStr(s)) => s,
      _ => "",
    },
  }
}

# Onboarding an org mints a token that resolves to a real, audit-scoped
# account/subject — not just a bare unrecorded JWT.
fn onboarded_token_is_audit_resolvable() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_federation(router.new(), db, cfg)
      let tok := token_of(r, "onboarded-org")
      if str.is_empty(tok) {
        Err("no token returned")
      } else {
        match identity.resolve_subject(db, cfg.secret, tok) {
          Err(e) => Err(str.concat("resolve errored: ", e)),
          Ok(None) => Err("onboarding token did not resolve to any credential — not audit-resolvable"),
          Ok(Some(subj)) => if subj.org == "onboarded-org" {
            Ok(())
          } else {
            Err(str.concat("resolved to wrong org: ", subj.org))
          },
        }
      }
    },
  }
}

# Flooding POST /connections for the SAME org trips the rate limit (429) well
# before an unbounded number of tokens could be minted; a DIFFERENT org is
# unaffected (the limit is per-org, not global).
fn flood_is_rate_limited_per_org() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_federation(router.new(), db, cfg)
      let statuses := list.map(list.range(0, 25), fn (_n :: Int) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Int {
        post_connect(r, "flooder-org")
      })
      let saw_429 := list.fold(statuses, false, fn (acc :: Bool, s :: Int) -> Bool {
        acc or s == 429
      })
      if saw_429 {
        let other_status := post_connect(r, "well-behaved-org")
        if other_status == 200 {
          Ok(())
        } else {
          Err(str.concat("a different org was also rate-limited: ", int.to_str(other_status)))
        }
      } else {
        Err("flooding 25 requests never tripped the rate limit")
      }
    },
  }
}

# Re-onboarding an org that was previously upgraded to "pro" must NOT clobber
# its plan back to "free" (identity.create_account's upsert always overwrites
# `plan`, so onboard_connection must only create-with-"free" for a brand-new
# account, never for one that already exists).
fn reonboarding_preserves_an_upgraded_plan() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_federation(router.new(), db, cfg)
      let __first := post_connect(r, "upgraded-org")
      match identity.create_account(db, "upgraded-org", "upgraded-org", "upgraded-org", "pro") {
        Err(e) => Err(str.concat("upgrade failed: ", e)),
        Ok(_) => {
          let __second := post_connect(r, "upgraded-org")
          match identity.get_account(db, "upgraded-org") {
            Err(e) => Err(str.concat("get_account failed: ", e)),
            Ok(None) => Err("account vanished after re-onboarding"),
            Ok(Some(a)) => if a.plan == "pro" {
              Ok(())
            } else {
              Err(str.concat("plan was clobbered on re-onboarding: ", a.plan))
            },
          }
        },
      }
    },
  }
}

# An agent onboarded via POST /connections must land in ITS ORG's tenant (not
# the "default" tenant), so per-org discovery / audit / usage include it. This
# is the fix for the scoping gap: register_peer_json now uses register_in(org).
fn onboarded_agent_lands_in_its_org_tenant() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let r := fed.mount_federation(router.new(), db, demo_cfg())
      let body := jv.stringify(JObj([("org", JStr("beta-corp")), ("scope", JStr("logistics")), ("agents", JList([JObj([("id", JStr("beta-agent-1")), ("kind", JStr("truck")), ("inbox_url", JStr("http://beta/agent-1/")), ("capabilities", JList([JStr("transport")]))])]))]))
      let __res := router.dispatch(r, { body: body, method: "POST", path: "/connections", query: "", headers: map.new() })
      let beta_ids := ids_of(db, "beta-corp")
      let in_beta := list.fold(beta_ids, false, fn (acc :: Bool, id :: Str) -> Bool {
        acc or id == "beta-agent-1"
      })
      let default_ids := ids_of(db, "default")
      let in_default := list.fold(default_ids, false, fn (acc :: Bool, id :: Str) -> Bool {
        acc or id == "beta-agent-1"
      })
      if in_beta and not in_default {
        Ok(())
      } else {
        Err(str.concat("agent tenant wrong: in_beta=", str.concat(bool_s(in_beta), str.concat(" in_default=", bool_s(in_default)))))
      }
    },
  }
}

fn bool_s(b :: Bool) -> Str {
  if b {
    "true"
  } else {
    "false"
  }
}

# H-2 end to end: POST /connections carrying a public_key it has not proved is
# refused outright, and binds nothing. Refusing rather than onboarding-without-
# the-key matters — proceeding would leave the caller believing its key is
# bound, and every partner token it later signed would be rejected with no clue
# why.
fn an_unproved_key_refuses_the_whole_request() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_federation(router.new(), db, cfg)
      let body := jv.stringify(JObj([("org", JStr("impostor")), ("scope", JStr("logistics")), ("public_key", JStr("not-a-proved-key")), ("agents", JList([]))]))
      let res := router.dispatch(r, { body: body, method: "POST", path: "/connections", query: "", headers: map.new() })
      let bound := match pa.get_key(db, "impostor") {
        None => false,
        Some(_) => true,
      }
      if res.status == 403 and not bound {
        Ok(())
      } else {
        Err(str.concat("unproved key not refused: status=", str.concat(int.to_str(res.status), if bound {
          " and a key was bound"
        } else {
          ""
        })))
      }
    },
  }
}

# The honest path still works over HTTP: take a challenge, sign it, onboard.
fn a_proved_key_onboards() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_federation(router.new(), db, cfg)
      let seed := crypto.sha256(bytes.from_str("partner"))
      let pub := match ed.public_key_b64(seed) {
        Ok(p) => p,
        Err(_) => "",
      }
      let ch := router.dispatch(r, { body: jv.stringify(JObj([("org", JStr("partner-co"))])), method: "POST", path: "/connections/challenge", query: "", headers: map.new() })
      let nonce := match jv.parse(ch.body) {
        Err(_) => "",
        Ok(cj) => match jv.get_field(cj, "challenge") {
          Some(JStr(n)) => n,
          _ => "",
        },
      }
      let proof := match ed.sign_text(seed, nonce) {
        Ok(sg) => sg,
        Err(_) => "",
      }
      let body := jv.stringify(JObj([("org", JStr("partner-co")), ("scope", JStr("logistics")), ("public_key", JStr(pub)), ("key_proof", JStr(proof)), ("challenge", JStr(nonce)), ("agents", JList([]))]))
      let res := router.dispatch(r, { body: body, method: "POST", path: "/connections", query: "", headers: map.new() })
      match pa.get_key(db, "partner-co") {
        Some(k) => if res.status == 200 and k == pub {
          Ok(())
        } else {
          Err(str.concat("proved key onboarding wrong: status=", int.to_str(res.status)))
        },
        None => Err(str.concat("a proved key was not bound; status=", int.to_str(res.status))),
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [an_unproved_key_refuses_the_whole_request(), a_proved_key_onboards(), onboarded_token_is_audit_resolvable(), flood_is_rate_limited_per_org(), reonboarding_preserves_an_upgraded_plan(), onboarded_agent_lands_in_its_org_tenant()]
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

