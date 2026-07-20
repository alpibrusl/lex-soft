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

# ── H-2: a key is bound only against a signed, single-use challenge ──────────
fn setup_pa(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match pa.init(db) {
    Err(e) => Err(e),
    Ok(_) => pa.init_challenges(db),
  }
}

fn sign(k :: KP, text :: Str) -> Str {
  match ed.sign_text(k.seed, text) {
    Ok(sg) => sg,
    Err(_) => "",
  }
}

fn now() -> Int {
  1000000
}

# The honest path: ask for a nonce, sign it, get bound.
fn a_signed_challenge_binds_the_key() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let a := kp("acme")
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(nonce) => match pa.bind_key(db, "acme", a.pub, sign(a, nonce), "", nonce, now()) {
          Err(e) => Err(str.concat("honest binding refused: ", e)),
          Ok(_) => match pa.get_key(db, "acme") {
            Some(k) => if k == a.pub {
              Ok(())
            } else {
              Err("bound the wrong key")
            },
            None => Err("key was not bound"),
          },
        },
      }
    },
  }
}

# The headline fault: an unproved key must not bind at all.
fn an_unproved_key_is_refused() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let a := kp("acme")
      let no_proof := pa.bind_key(db, "acme", a.pub, "", "", "", now())
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(nonce) => {
          let bad_sig := pa.bind_key(db, "acme", a.pub, sign(kp("someone-else"), nonce), "", nonce, now())
          let bound := match pa.get_key(db, "acme") {
            None => false,
            Some(_) => true,
          }
          match (no_proof, bad_sig) {
            (Err(_), Err(_)) => if bound {
              Err("a refused binding still wrote a key")
            } else {
              Ok(())
            },
            _ => Err("a key with no proof, or a proof signed by another key, was accepted"),
          }
        },
      }
    },
  }
}

# The takeover: an attacker holding its OWN valid key must not be able to
# replace the key of an org that already has one. This is the fault that made
# H-2 a takeover rather than a bad first binding — cache_key upserts.
fn an_existing_org_key_cannot_be_hijacked() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let victim := kp("acme-real")
      let attacker := kp("attacker")
      let __b := match pa.issue_challenge(db, "acme", now()) {
        Err(_) => Err("x"),
        Ok(n1) => pa.bind_key(db, "acme", victim.pub, sign(victim, n1), "", n1, now()),
      }
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(n2) => {
          let takeover := pa.bind_key(db, "acme", attacker.pub, sign(attacker, n2), "", n2, now())
          let still_victim := match pa.get_key(db, "acme") {
            Some(k) => k == victim.pub,
            None => false,
          }
          match takeover {
            Ok(_) => Err("an attacker replaced an existing org key with its own"),
            Err(_) => if still_victim {
              Ok(())
            } else {
              Err("the incumbent key was lost even though the takeover was refused")
            },
          }
        },
      }
    },
  }
}

# Rotation is allowed, but only with a signature from the key being replaced.
fn rotation_requires_the_current_key() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let old := kp("acme-old")
      let new := kp("acme-new")
      let __b := match pa.issue_challenge(db, "acme", now()) {
        Err(_) => Err("x"),
        Ok(n1) => pa.bind_key(db, "acme", old.pub, sign(old, n1), "", n1, now()),
      }
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(n2) => match pa.bind_key(db, "acme", new.pub, sign(new, n2), sign(old, n2), n2, now()) {
          Err(e) => Err(str.concat("a properly countersigned rotation was refused: ", e)),
          Ok(_) => match pa.get_key(db, "acme") {
            Some(k) => if k == new.pub {
              Ok(())
            } else {
              Err("rotation did not take effect")
            },
            None => Err("rotation lost the key"),
          },
        },
      }
    },
  }
}

# A nonce is single-use and org-bound, so a captured one cannot be replayed —
# nor used to bind a key for a different org.
fn a_challenge_is_single_use_and_org_bound() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let a := kp("acme")
      let b := kp("other")
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(nonce) => {
          let cross := pa.bind_key(db, "other-org", b.pub, sign(b, nonce), "", nonce, now())
          let first := pa.bind_key(db, "acme", a.pub, sign(a, nonce), "", nonce, now())
          let replay := pa.bind_key(db, "acme", a.pub, sign(a, nonce), "", nonce, now())
          match (cross, first, replay) {
            (Err(_), Ok(_), Err(_)) => Ok(()),
            _ => Err("a challenge was reusable, or usable for an org it was not issued to"),
          }
        },
      }
    },
  }
}

fn an_expired_challenge_is_refused() -> [sql, fs_read, fs_write, time, crypto, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __i := setup_pa(db)
      let a := kp("acme")
      match pa.issue_challenge(db, "acme", now()) {
        Err(e) => Err(str.concat("challenge failed: ", e)),
        Ok(nonce) => match pa.bind_key(db, "acme", a.pub, sign(a, nonce), "", nonce, now() + pa.challenge_ttl_ms() + 1) {
          Ok(_) => Err("an expired challenge was accepted"),
          Err(_) => Ok(()),
        },
      }
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, crypto, random] Unit {
  let results := [a_signed_challenge_binds_the_key(), an_unproved_key_is_refused(), an_existing_org_key_cannot_be_hijacked(), rotation_requires_the_current_key(), a_challenge_is_single_use_and_org_bound(), an_expired_challenge_is_refused(), authenticates_with_published_key(), revocation_denies(), unknown_signer_denied(), forged_signature_denied(), expired_token_denied()]
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

