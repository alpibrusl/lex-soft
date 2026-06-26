# tests/test_partner_auth.lex — acceptance tests for #18 (Ed25519 partner
# connection tokens). Asserts:
#   - a peer with a published Ed25519 key authenticates with NO pre-shared secret,
#   - revocation: dropping the partner's cached key denies subsequent tokens,
#   - an unknown signer and a forged signature are denied,
#   - an expired token is denied.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.time" as time

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-crypto/src/ed25519" as ed

import "../src/partner_auth" as pa

type KP = { seed :: Bytes, pub :: Str }

fn kp(name :: Str) -> KP {
  let seed := crypto.sha256(bytes.from_str(name))
  let pub := match ed.public_key_b64(seed) {
    Ok(p) => p,
    Err(_) => "",
  }
  { seed: seed, pub: pub }
}

# A peer publishes its key (cached at connection time) and signs a token; we
# verify it against the cached key with no shared secret.
fn authenticates_with_published_key() -> [sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := pa.init(db)
      let partner := kp("partner-co-seed")
      let __c := pa.cache_key(db, "partner-co", partner.pub)
      let tok := pa.issue_token(partner.seed, "partner-co", "logistics", time.now() + 3600)
      if pa.verify(db, tok) {
        Ok(())
      } else {
        Err("partner token should verify against the cached published key")
      }
    },
  }
}

# Dropping the partner's key revokes them: a previously-valid token is denied.
fn revocation_denies() -> [sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := pa.init(db)
      let partner := kp("partner-co-seed")
      let __c := pa.cache_key(db, "partner-co", partner.pub)
      let tok := pa.issue_token(partner.seed, "partner-co", "logistics", time.now() + 3600)
      if pa.verify(db, tok) {
        let __d := pa.drop_key(db, "partner-co")
        if pa.verify(db, tok) {
          Err("revoked partner token should be denied")
        } else {
          Ok(())
        }
      } else {
        Err("token should have verified before revocation")
      }
    },
  }
}

# A signer we never cached a key for is denied.
fn unknown_signer_denied() -> [sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := pa.init(db)
      let stranger := kp("stranger-seed")
      let tok := pa.issue_token(stranger.seed, "stranger-co", "logistics", time.now() + 3600)
      if pa.verify(db, tok) {
        Err("token from an uncached signer should be denied")
      } else {
        Ok(())
      }
    },
  }
}

# A token signed by an attacker but claiming a legit org is denied (the cached
# key for that org won't verify the attacker's signature).
fn forged_signature_denied() -> [sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := pa.init(db)
      let partner := kp("partner-co-seed")
      let attacker := kp("attacker-seed")
      let __c := pa.cache_key(db, "partner-co", partner.pub)
      let forged := pa.issue_token(attacker.seed, "partner-co", "logistics", time.now() + 3600)
      if pa.verify(db, forged) {
        Err("a forged signature for a known org should be denied")
      } else {
        Ok(())
      }
    },
  }
}

# An expired token is denied even with a valid signature.
fn expired_token_denied() -> [sql, fs_read, fs_write, time, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := pa.init(db)
      let partner := kp("partner-co-seed")
      let __c := pa.cache_key(db, "partner-co", partner.pub)
      let tok := pa.issue_token(partner.seed, "partner-co", "logistics", time.now() - 10)
      if pa.verify(db, tok) {
        Err("expired partner token should be denied")
      } else {
        Ok(())
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, crypto] Unit {
  let results := [authenticates_with_published_key(), revocation_denies(), unknown_signer_denied(), forged_signature_denied(), expired_token_denied()]
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

