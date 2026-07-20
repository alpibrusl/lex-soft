# tests/test_identity.lex — the unified account/credential model (#59).
#
# Covers the identity chain that the audit (#60) and metering (#61) layers
# depend on: create an account, issue a credential bound to it, and prove that a
# presented token resolves back to the right subject — and stops resolving the
# moment the credential is revoked (even though the JWT itself still verifies).

import "std.io" as io

import "std.str" as str

import "std.bytes" as bytes

import "std.sql" as sql

import "std.list" as list

import "../src/migrate" as migrate

import "../src/identity" as identity

fn secret() -> Bytes {
  bytes.from_str("test-federation-secret")
}

# create_account → get_account round-trips; account_by_org finds it by org.
fn account_crud() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      match identity.create_account(db, "acct_1", "acme", "Acme Freight", "pro") {
        Err(e) => Err(str.concat("create failed: ", e)),
        Ok(_) => match identity.get_account(db, "acct_1") {
          Err(e) => Err(str.concat("get failed: ", e)),
          Ok(None) => Err("account not found after create"),
          Ok(Some(a)) => if a.org == "acme" and a.plan == "pro" {
            match identity.account_by_org(db, "acme") {
              Err(e) => Err(str.concat("by_org failed: ", e)),
              Ok(Some(b)) => if b.id == "acct_1" {
                Ok(())
              } else {
                Err("account_by_org returned wrong account")
              },
              Ok(None) => Err("account_by_org found nothing"),
            }
          } else {
            Err(str.concat("account fields wrong: org=", str.concat(a.org, str.concat(" plan=", a.plan))))
          },
        },
      }
    },
  }
}

# issue_credential mints a token whose jti resolves back to the issuing account.
fn issue_and_resolve() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a := identity.create_account(db, "acct_2", "beta-logistics", "Beta", "free")
      match identity.issue_credential(db, secret(), "platform", "acct_2", "beta-logistics", "beta-agent", "logistics", 3600) {
        Err(e) => Err(str.concat("issue failed: ", e)),
        Ok(iss) => match identity.resolve_subject(db, secret(), iss.token) {
          Err(e) => Err(str.concat("resolve failed: ", e)),
          Ok(None) => Err("freshly-issued token did not resolve"),
          Ok(Some(s)) => if s.account == "acct_2" and s.org == "beta-logistics" and s.agent_id == "beta-agent" and s.scope == "logistics" {
            Ok(())
          } else {
            Err(str.concat("subject mismatch: account=", str.concat(s.account, str.concat(" org=", s.org))))
          },
        },
      }
    },
  }
}

# A token signed with a different secret must not resolve (forgery / wrong node).
fn foreign_token_denied() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a := identity.create_account(db, "acct_3", "gamma", "Gamma", "free")
      match identity.issue_credential(db, secret(), "platform", "acct_3", "gamma", "gamma-agent", "logistics", 3600) {
        Err(e) => Err(str.concat("issue failed: ", e)),
        Ok(iss) => match identity.resolve_subject(db, bytes.from_str("a-different-secret"), iss.token) {
          Err(e) => Err(str.concat("resolve failed: ", e)),
          Ok(None) => Ok(()),
          Ok(Some(_)) => Err("token verified under the wrong secret"),
        },
      }
    },
  }
}

# Revocation is authoritative: after revoke, the (still cryptographically valid,
# unexpired) token stops resolving.
fn revoke_denies_resolution() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a := identity.create_account(db, "acct_4", "delta", "Delta", "free")
      match identity.issue_credential(db, secret(), "platform", "acct_4", "delta", "delta-agent", "logistics", 3600) {
        Err(e) => Err(str.concat("issue failed: ", e)),
        Ok(iss) => {
          let __before := identity.resolve_subject(db, secret(), iss.token)
          match __before {
            Ok(Some(_)) => match identity.revoke_credential(db, iss.cred_id) {
              Err(e) => Err(str.concat("revoke failed: ", e)),
              Ok(_) => match identity.resolve_subject(db, secret(), iss.token) {
                Err(e) => Err(str.concat("resolve-after-revoke failed: ", e)),
                Ok(None) => Ok(()),
                Ok(Some(_)) => Err("revoked credential still resolved"),
              },
            },
            _ => Err("token did not resolve before revoke"),
          }
        },
      }
    },
  }
}

# M-3: rotating the signing secret must not invalidate live credentials.
# A credential issued under the OLD secret still resolves while that secret is
# in the ring, and stops resolving once it is dropped — which is what makes a
# rotation drain rather than log everyone out.
fn a_retired_secret_still_resolves_until_dropped() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let old := bytes.from_str("secret-v1")
      let new_sec := bytes.from_str("secret-v2")
      let __a := identity.create_account(db, "rot", "rot", "Rot", "free")
      match identity.issue_credential(db, old, "node", "rot", "rot", "agent-r", "", 3600) {
        Err(e) => Err(str.concat("issue failed: ", e)),
        Ok(cred) => {
          let under_new_only := identity.resolve_subject_in(db, [new_sec], cred.token)
          let under_ring := identity.resolve_subject_in(db, [new_sec, old], cred.token)
          let under_empty := identity.resolve_subject_in(db, [], cred.token)
          match (under_new_only, under_ring, under_empty) {
            (Ok(None), Ok(Some(s)), Ok(None)) => if s.org == "rot" {
              Ok(())
            } else {
              Err("the ring resolved the wrong org")
            },
            _ => Err("rotation semantics wrong: a retired secret must resolve only while it is in the ring, and an empty ring must resolve nothing"),
          }
        },
      }
    },
  }
}

# The ring widens which KEYS are recognised, never what a recognised token may
# do: a revoked credential stays revoked under every secret in the ring.
fn the_ring_does_not_bypass_revocation() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let old := bytes.from_str("secret-v1")
      let __a := identity.create_account(db, "rot", "rot", "Rot", "free")
      match identity.issue_credential(db, old, "node", "rot", "rot", "agent-r", "", 3600) {
        Err(e) => Err(str.concat("issue failed: ", e)),
        Ok(cred) => {
          let __rev := identity.revoke_credential(db, cred.cred_id)
          match identity.resolve_subject_in(db, [bytes.from_str("secret-v2"), old], cred.token) {
            Ok(None) => Ok(()),
            _ => Err("a revoked credential resolved through the keyring"),
          }
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [a_retired_secret_still_resolves_until_dropped(), the_ring_does_not_bypass_revocation(), account_crud(), issue_and_resolve(), foreign_token_denied(), revoke_denies_resolution()]
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

