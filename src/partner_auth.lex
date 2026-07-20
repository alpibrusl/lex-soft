# src/partner_auth.lex — asymmetric (Ed25519) partner connection tokens.
#
# Connection tokens were HS256 (symmetric): a node could only verify tokens IT
# issued (federation.lex `issue_conn_token`/`verify_conn_token`). That can't
# verify a token a PARTNER signed — what real multi-org federation needs. Org
# identity is already Ed25519 (`/.well-known/agent-key.json`), so we reuse that
# primitive for tokens.
#
# A partner signs a compact token with their Ed25519 key; we verify it against
# their PUBLISHED public key (cached at connection time), with no pre-shared
# secret. Dropping a partner's key from the cache revokes them. This sits
# alongside the HS256 self-issued path (federation dual-accepts both).
#
# Token = JSON { org, scope, exp, sig } where
#   sig = ed.sign_text(partner_seed, canonical(org, scope, exp))
#   canonical = "<org>|<scope>|<exp>"
# Verification looks up the signer's cached public key by `org`, checks the
# signature, and rejects expired tokens.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "std.time" as time

import "lex-crypto/src/ed25519" as ed

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

# The canonical text a partner signs.
fn canonical(org :: Str, scope :: Str, exp :: Int) -> Str {
  str.join([org, "|", scope, "|", int.to_str(exp)], "")
}

# Issue a partner token (used by a partner / SDK / tests; the signer holds seed).
fn issue_token(seed :: Bytes, org :: Str, scope :: Str, exp :: Int) -> Str {
  let sig := match ed.sign_text(seed, canonical(org, scope, exp)) {
    Ok(s) => s,
    Err(_) => "",
  }
  jv.stringify(JObj([("org", JStr(org)), ("scope", JStr(scope)), ("exp", JInt(exp)), ("sig", JStr(sig))]))
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# Verify a token against a KNOWN public key (pure crypto + expiry check).
fn verify_with_key(pub_b64 :: Str, tok :: Str) -> [time] Bool {
  match jv.parse(tok) {
    Err(_) => false,
    Ok(j) => {
      let org := jstr(j, "org")
      let scope := jstr(j, "scope")
      let sig := jstr(j, "sig")
      let exp := jint(j, "exp")
      if str.is_empty(org) {
        false
      } else {
        if str.is_empty(sig) {
          false
        } else {
          if ed.verify_text(pub_b64, canonical(org, scope, exp), sig) {
            time.now() < exp
          } else {
            false
          }
        }
      }
    },
  }
}

# ── Partner key cache ─────────────────────────────────────────────────────────
# org → published Ed25519 public key. Populated at connection time; deleting a
# row revokes that partner.
type KeyRow = { org :: Str, public_key :: Str }

fn init(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS partner_keys (org TEXT PRIMARY KEY, public_key TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT '')", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── Proof of key possession (H-2) ────────────────────────────────────────────
# A partner key used to be cached on the caller's say-so: POST /connections
# carried {org, public_key} and the node believed both. Two consequences, and
# the second is the sharp one:
#
#   1. a caller could bind ANY key to an org it does not control, and
#   2. cache_key upserts, so an org that ALREADY had a key was silently
#      overwritten — a takeover, not just a bad first binding.
#
# So a key is now bound only against a server-issued, single-use nonce that the
# caller has signed with the matching private key. Rotating a key additionally
# requires a signature from the key being replaced, so holding the new key is
# never on its own enough to displace an incumbent.
#
# Honest about what this proves: possession of a key, plus continuity of
# whoever bound it first. It is trust-on-first-use, not proof that the caller
# is the real-world organisation named — that needs a binding from org id to
# something externally verifiable (a domain serving /.well-known/agent-key.json)
# and these org ids are opaque slugs, not domains. Recorded in SECURITY.md.
type ChallengeRow = { nonce :: Str, org :: Str, expires_ms :: Int, used :: Int }

fn init_challenges(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE IF NOT EXISTS partner_challenges (nonce TEXT PRIMARY KEY, org TEXT NOT NULL, expires_ms INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0)", []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn challenge_ttl_ms() -> Int {
  300000
}

# Mint a nonce for `org` to sign. Bound to the org so a nonce issued for one
# cannot be replayed to bind a key for another.
fn issue_challenge(db :: Db, org :: Str, now_ms :: Int) -> [sql, fs_write, random] Result[Str, Str] {
  let nonce := crypto.random_str_hex(32)
  match sql.exec(db, "INSERT INTO partner_challenges (nonce, org, expires_ms, used) VALUES (?, ?, ?, 0)", [PStr(nonce), PStr(org), PInt(now_ms + challenge_ttl_ms())]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(nonce),
  }
}

# Spend a nonce: it must exist, be for this org, be unexpired and unused. The
# UPDATE is the claim — gated on used=0 in the WHERE, so two racing requests
# cannot both spend the same nonce.
fn consume_challenge(db :: Db, org :: Str, nonce :: Str, now_ms :: Int) -> [sql, fs_read, fs_write] Bool {
  let rows :: Result[List[ChallengeRow], SqlError] := sql.query(db, "SELECT nonce, org, expires_ms, used FROM partner_challenges WHERE nonce=?", [PStr(nonce)])
  match rows {
    Err(_) => false,
    Ok(rs) => match list.head(rs) {
      None => false,
      Some(r) => if r.org != org or r.used != 0 or r.expires_ms < now_ms {
        false
      } else {
        match sql.exec(db, "UPDATE partner_challenges SET used=1 WHERE nonce=? AND used=0", [PStr(nonce)]) {
          Err(_) => false,
          Ok(_) => true,
        }
      },
    },
  }
}

# Bind a key to an org, having proved possession. `key_proof` is the new key's
# signature over the nonce; `rotation_proof` is the CURRENT key's signature over
# the same nonce, required only when replacing a different existing key.
fn bind_key(db :: Db, org :: Str, public_key :: Str, key_proof :: Str, rotation_proof :: Str, nonce :: Str, now_ms :: Int) -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  if str.is_empty(public_key) or str.is_empty(key_proof) or str.is_empty(nonce) {
    Err("binding a partner key requires public_key, key_proof and challenge")
  } else {
    if not consume_challenge(db, org, nonce, now_ms) {
      Err("challenge is unknown, expired, already used, or issued for another org")
    } else {
      if not ed.verify_text(public_key, nonce, key_proof) {
        Err("key_proof does not verify against public_key")
      } else {
        match get_key(db, org) {
          None => cache_key(db, org, public_key),
          Some(current) => if current == public_key {
            Ok(())
          } else {
            if ed.verify_text(current, nonce, rotation_proof) {
              cache_key(db, org, public_key)
            } else {
              Err("replacing an org key requires rotation_proof signed by the current key")
            }
          },
        }
      }
    }
  }
}

fn cache_key(db :: Db, org :: Str, public_key :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := "INSERT INTO partner_keys (org, public_key, updated_at) VALUES (?, ?, ?) ON CONFLICT(org) DO UPDATE SET public_key=excluded.public_key, updated_at=excluded.updated_at"
  match sql.exec(db, q, [PStr(org), PStr(public_key), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn get_key(db :: Db, org :: Str) -> [sql, fs_read] Option[Str] {
  let q := "SELECT org, public_key FROM partner_keys WHERE org=?"
  let rows :: Result[List[KeyRow], SqlError] := sql.query(db, q, [PStr(org)])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.public_key),
    },
  }
}

fn drop_key(db :: Db, org :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := "DELETE FROM partner_keys WHERE org=?"
  match sql.exec(db, q, [PStr(org)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# Verify a partner token by looking up the signer's cached key. Unknown or
# revoked signer (no cached key) → deny.
fn verify(db :: Db, tok :: Str) -> [sql, fs_read, time] Bool {
  match jv.parse(tok) {
    Err(_) => false,
    Ok(j) => {
      let org := jstr(j, "org")
      if str.is_empty(org) {
        false
      } else {
        match get_key(db, org) {
          None => false,
          Some(pub) => verify_with_key(pub, tok),
        }
      }
    },
  }
}

