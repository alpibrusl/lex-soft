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

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

fn cache_key(db :: Db, org :: Str, public_key :: Str) -> [sql, fs_write, time] Result[Unit, Str] {
  let now := time.now_str()
  let q := str.join(["INSERT INTO partner_keys (org, public_key, updated_at) VALUES ('", sq(org), "', '", sq(public_key), "', '", now, "') ON CONFLICT(org) DO UPDATE SET public_key=excluded.public_key, updated_at=excluded.updated_at"], "")
  match sql.exec(db, q, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn get_key(db :: Db, org :: Str) -> [sql, fs_read] Option[Str] {
  let q := str.join(["SELECT org, public_key FROM partner_keys WHERE org='", sq(org), "'"], "")
  let rows :: Result[List[KeyRow], SqlError] := sql.query(db, q, [])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => Some(r.public_key),
    },
  }
}

fn drop_key(db :: Db, org :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := str.join(["DELETE FROM partner_keys WHERE org='", sq(org), "'"], "")
  match sql.exec(db, q, []) {
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

