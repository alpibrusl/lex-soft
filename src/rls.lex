# rls.lex — Postgres session-GUC bridge for lex-soft's tenant RLS policies
# (GDPR-01, see migrate.rls_migrations). Sets app.tenant_id to the caller's
# CRYPTOGRAPHICALLY VERIFIED org via identity.resolve_subject_in — the same
# fail-closed resolver already used ad hoc by audit/federation/metering/pool/
# notifications — rather than a caller-supplied header: a forged X-Tenant-Id
# can't buy cross-tenant rows this way.
#
# Takes TWO connections, not one. `credentials` (the table resolve_subject_in
# reads to turn a jti into its owning org) is itself RLS-protected — but
# app.tenant_id isn't known yet at the moment we're trying to determine it,
# so a lookup through the RLS-restricted connection would always see zero
# rows and could never resolve anything (the mechanism would permanently
# defeat itself). `owner_db` is the bypass connection (the migration/owner
# role, which always bypasses RLS) used ONLY for that one bootstrapping
# lookup — the caller has already proved ownership of the exact credential
# row via a verified signature, so reading its `org` column back is not a
# cross-tenant leak. `serving_db` is the RLS-restricted `ev_app` connection
# that every request handler actually queries through; set_config must run
# on THAT connection's session, since it's a per-connection session variable
# — setting it on owner_db would have zero effect on what handlers see.
#
# When no subject resolves (missing/invalid/revoked bearer token, or a route
# that legitimately has none — e.g. the federation bootstrap endpoints), the
# GUC is left unset. Every RLS-protected table's policy compares its tenant/
# org column against current_setting('app.tenant_id', true), which is NULL
# when unset, and NULL never equals a real tenant value — so an unresolved
# caller sees ZERO rows from any RLS table rather than falling back to an
# open default. This middleware never short-circuits the request itself
# (routes with no RLS-protected data — health, dashboard, bootstrap
# onboarding — are unaffected either way; existing per-handler auth such as
# AUDIT_KEY / DEVICE_ADMIN_KEY / conn-token verification is untouched).
#
# EVERY branch below sets the GUC — including to '' when no subject
# resolves — never just skips it. set_config is SESSION-scoped, not
# per-request: on a shared/reused connection, an unauthenticated request
# that merely left the GUC untouched would silently inherit whatever the
# PREVIOUS request (on the same connection) last set it to, which live
# testing confirmed actually happens (an anonymous request right after an
# authenticated one saw that caller's rows). Explicitly clearing it on
# every non-resolving path closes that.
#
# Known limitation (shared with lex-tms's rls.lex, the reference
# implementation this mirrors): set_config is still SESSION- not
# transaction-scoped — under truly concurrent requests interleaved on one
# connection there is a narrow window between one request's set_config and
# its own queries where another request's set_config could land first. RLS
# is defense-in-depth on top of every handler's own explicit tenant WHERE
# clause, not lex-soft's sole isolation boundary.

import "std.sql" as sql

import "lex-web/middleware" as mw

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./identity" as identity

fn set_tenant_guc(serving_db :: Db, tenant :: Str) -> [sql] Unit {
  let __rls := sql.query(serving_db, "SELECT set_config('app.tenant_id', $1, false)", [PStr(tenant)])
  ()
}

fn before(owner_db :: Db, serving_db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
  match ctx.bearer_token(c) {
    None => {
      let __clear := set_tenant_guc(serving_db, "")
      mw.Continue(c)
    },
    Some(tok) => match identity.resolve_subject_in(owner_db, secrets, tok) {
      Err(_) => {
        let __clear := set_tenant_guc(serving_db, "")
        mw.Continue(c)
      },
      Ok(None) => {
        let __clear := set_tenant_guc(serving_db, "")
        mw.Continue(c)
      },
      Ok(Some(subj)) => {
        let __set := set_tenant_guc(serving_db, subj.org)
        mw.Continue(c)
      },
    },
  }
}

fn after(c :: ctx.Ctx, r :: resp.Response) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  r
}

fn make(owner_db :: Db, serving_db :: Db, secrets :: List[Bytes]) -> mw.MiddlewareKind {
  mw.custom("tenant-rls", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] mw.PreResult {
    before(owner_db, serving_db, secrets, c)
  }, after)
}

