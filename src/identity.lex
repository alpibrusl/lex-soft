# identity.lex — unified account / credential model for the platform control plane.
#
# Phase 6 (#59). Collapses the three fragmented identity models
#   conn_token.issue              (HS256, mesh dispatch)
#   partner_auth.issue_token     (ed25519, partner public keys)
#   a separate control-plane JWT (tenant + capability grants)
# onto ONE chain, keyed on the `org` the registry already carries (#26):
#
#   customer account  →  issued agent credential  →  the credential both
#   authenticates to the mesh (as a federation conn token) AND is the audit
#   subject (`resolve_subject`) reused by the audit (#60) and metering (#61)
#   layers.
#
# Tables (see migrate.lex):
#   accounts     — the persistent control-plane principal (one per customer org)
#   credentials  — an issued agent credential, bound to an account + org, keyed
#                  by the conn-token jti so revocation is authoritative (a
#                  revoked row → resolve denies, even though the JWT still
#                  verifies cryptographically and has not expired).

import "std.sql" as sql

import "std.str" as str

import "std.time" as time

import "std.list" as list

import "std.crypto" as crypto

import "lex-crypto/src/jwt" as jwt

import "./conn_token" as conn_token

# The control-plane principal. `org` is the mesh/registry join key (#26); one
# account owns exactly one org. `plan` drives quotas (#61); `status` gates login.
type Account = { id :: Str, org :: Str, name :: Str, status :: Str, plan :: Str }

# An issued agent credential. `jti` mirrors the conn-token's jti so a presented
# bearer token resolves back to its account without trusting the token's own
# claims. `revoked` is a soft flag (BIGINT: 0/1) — see resolve_subject.
type Credential = { id :: Str, account :: Str, org :: Str, agent_id :: Str, scope :: Str, jti :: Str, revoked :: Int }

# What issue_credential hands back: the record id, the jti, and the bearer token
# the agent presents on dispatch. The token is NOT stored (only its jti is).
type IssuedCredential = { cred_id :: Str, jti :: Str, token :: Str }

# The audit subject a presented token resolves to. This is the unit every
# downstream tenant-scoped query (#60/#61) filters by.
type Subject = { account :: Str, org :: Str, agent_id :: Str, scope :: Str }

# ── Accounts ──────────────────────────────────────────────────────────────────
fn acct_cols() -> Str {
  "id, org, name, status, plan"
}

fn create_account(db :: Db, id :: Str, org :: Str, name :: Str, plan :: Str) -> [sql, fs_write, time] Result[Account, Str] {
  let now := time.now_str()
  let q := "INSERT INTO accounts (id, org, name, status, plan, created_at) VALUES (?, ?, ?, 'active', ?, ?) ON CONFLICT(id) DO UPDATE SET org=excluded.org, name=excluded.name, plan=excluded.plan"
  match sql.exec(db, q, [PStr(id), PStr(org), PStr(name), PStr(plan), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok({ id: id, org: org, name: name, status: "active", plan: plan }),
  }
}

fn get_account(db :: Db, id :: Str) -> [sql, fs_read] Result[Option[Account], Str] {
  let q := str.join(["SELECT ", acct_cols(), " FROM accounts WHERE id=?"], "")
  let rows :: Result[List[Account], SqlError] := sql.query(db, q, [PStr(id)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.head(rs)),
  }
}

# Resolve an account by its org (the registry/mesh join key). Used when a mesh
# event carries an org and the caller needs the owning account.
fn account_by_org(db :: Db, org :: Str) -> [sql, fs_read] Result[Option[Account], Str] {
  let q := str.join(["SELECT ", acct_cols(), " FROM accounts WHERE org=?"], "")
  let rows :: Result[List[Account], SqlError] := sql.query(db, q, [PStr(org)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.head(rs)),
  }
}

fn list_accounts(db :: Db) -> [sql, fs_read] Result[List[Account], Str] {
  let q := str.join(["SELECT ", acct_cols(), " FROM accounts ORDER BY created_at"], "")
  let rows :: Result[List[Account], SqlError] := sql.query(db, q, [])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(rs),
  }
}

# ── Credentials ───────────────────────────────────────────────────────────────
fn cred_cols() -> Str {
  "id, account, org, agent_id, scope, jti, revoked"
}

# Mint a mesh-compatible connection token bound to an account and record it. The
# token is a federation conn token (so mesh dispatch verifies it exactly as
# before) whose jti we persist — that jti is the bridge back to the account.
# `our_org` is the issuing platform node's org; `org` is the account's org
# (becomes the token's `sub`, i.e. the mesh-visible identity).
fn issue_credential(db :: Db, secret :: Bytes, our_org :: Str, account :: Str, org :: Str, agent_id :: Str, scope :: Str, ttl :: Int) -> [sql, fs_write, time, random] Result[IssuedCredential, Str] {
  let jti := str.concat("cred_", crypto.random_str_hex(16))
  let token := conn_token.issue(secret, our_org, org, scope, ttl, jti, time.now())
  let cred_id := str.concat("cr_", crypto.random_str_hex(8))
  let now_s := time.now_str()
  let q := "INSERT INTO credentials (id, account, org, agent_id, scope, jti, revoked, created_at) VALUES (?, ?, ?, ?, ?, ?, 0, ?)"
  match sql.exec(db, q, [PStr(cred_id), PStr(account), PStr(org), PStr(agent_id), PStr(scope), PStr(jti), PStr(now_s)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok({ cred_id: cred_id, jti: jti, token: token }),
  }
}

fn find_cred_by_jti(db :: Db, jti :: Str) -> [sql, fs_read] Result[Option[Credential], Str] {
  let q := str.join(["SELECT ", cred_cols(), " FROM credentials WHERE jti=?"], "")
  let rows :: Result[List[Credential], SqlError] := sql.query(db, q, [PStr(jti)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(list.head(rs)),
  }
}

fn list_credentials(db :: Db, account :: Str) -> [sql, fs_read] Result[List[Credential], Str] {
  let q := str.join(["SELECT ", cred_cols(), " FROM credentials WHERE account=? ORDER BY created_at"], "")
  let rows :: Result[List[Credential], SqlError] := sql.query(db, q, [PStr(account)])
  match rows {
    Err(e) => Err(e.message),
    Ok(rs) => Ok(rs),
  }
}

fn revoke_credential(db :: Db, cred_id :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let q := "UPDATE credentials SET revoked=1 WHERE id=?"
  match sql.exec(db, q, [PStr(cred_id)]) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

# ── The audit-subject resolver ────────────────────────────────────────────────
#
# Given a presented bearer token: (1) verify it is a conn token we signed and
# that has not expired (stateless, same check as conn_token.verify),
# then (2) look up its jti in the credentials table. A token that verifies but
# whose credential is missing or revoked resolves to None — so revocation is
# immediate and authoritative, independent of the token's own (still-valid) exp.
# Ok(None) = "not a subject we recognise"; Err = a storage failure.
# Rotating the HS256 signing secret used to invalidate every live credential at
# once, because verification only ever tried one key. A node can now carry
# retired secrets alongside the current one: tokens are ISSUED under the current
# secret and ACCEPTED under any in the ring, so a rotation drains naturally as
# old credentials expire instead of logging everyone out.
#
# This does not weaken verification. A token still has to verify under exactly
# one secret, and the jti lookup plus the revoked check happen afterwards
# either way — the ring widens which keys are recognised, not what a recognised
# token is allowed to do.
#
# A `kid` header would let us pick the right key directly instead of trying
# each; lex-crypto's sign_hs256 writes a fixed header and exposes no header on
# decode, so that needs an upstream change. With a handful of secrets the
# difference is a few HMACs.
fn verify_any(secrets :: List[Bytes], presented :: Str) -> [time] Option[jwt.Claims] {
  list.fold(secrets, None, fn (found :: Option[jwt.Claims], sec :: Bytes) -> [time] Option[jwt.Claims] {
    match found {
      Some(c) => Some(c),
      None => match jwt.verify_hs256(sec, presented) {
        Ok(c) => Some(c),
        Err(_) => None,
      },
    }
  })
}

# Resolve against a whole keyring. `secrets` is current-first; an empty ring
# resolves nothing, which is the correct fail-closed reading of "this node has
# no signing key configured".
fn resolve_subject_in(db :: Db, secrets :: List[Bytes], presented :: Str) -> [sql, fs_read, time] Result[Option[Subject], Str] {
  match verify_any(secrets, presented) {
    None => Ok(None),
    Some(c) => match find_cred_by_jti(db, c.jti) {
      Err(e) => Err(e),
      Ok(None) => Ok(None),
      Ok(Some(cr)) => if cr.revoked == 0 {
        Ok(Some({ account: cr.account, org: cr.org, agent_id: cr.agent_id, scope: cr.scope }))
      } else {
        Ok(None)
      },
    },
  }
}

fn resolve_subject(db :: Db, secret :: Bytes, presented :: Str) -> [sql, fs_read, time] Result[Option[Subject], Str] {
  match jwt.verify_hs256(secret, presented) {
    Err(_) => Ok(None),
    Ok(c) => match find_cred_by_jti(db, c.jti) {
      Err(e) => Err(e),
      Ok(None) => Ok(None),
      Ok(Some(cr)) => if cr.revoked == 0 {
        Ok(Some({ account: cr.account, org: cr.org, agent_id: cr.agent_id, scope: cr.scope }))
      } else {
        Ok(None)
      },
    },
  }
}

