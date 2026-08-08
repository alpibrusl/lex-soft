# tests/test_rls.lex — acceptance tests for rls.lex (#130), the Postgres
# session-GUC bridge that is lex-soft's tenant-isolation BACKSTOP (GDPR-01).
# Had zero test coverage despite being explicitly a safety-critical module in
# its own docstring. Two halves:
#
#   Part A (no services required): rls.before()'s CONTRACT that it never
#   short-circuits the request itself, on every resolution path (no token,
#   an invalid token, a genuinely valid one) — a regression that turned this
#   into a `Short(...)` would break every route in the platform, so this is
#   worth locking down even without a live Postgres server.
#
#   Part B (opt-in, LEX_SOFT_PG_URL, same convention as
#   test_trail_dialect.lex's postgres path — SKIPs without it, and CI's
#   postgres job supplies it): the actual Tier-0 claim from #130 — "a query
#   scoped to tenant A never returns tenant B's rows." Connecting as the
#   owner role (as every other test's LEX_SOFT_PG_URL does) would prove
#   nothing, since a superuser/table-owner bypasses RLS entirely regardless
#   of policy — that's exactly why production runs behind a separate,
#   restricted `ev_app`-style role (see rls.lex's own docstring). This test
#   creates that restricted role itself (NOSUPERUSER NOBYPASSRLS) so the
#   proof is real: two tenants' rows are seeded via the owner connection,
#   then read back through the RESTRICTED role with rls.set_tenant_guc /
#   rls.before — the actual functions under test, not a hand-rolled stand-in.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.env" as env

import "std.time" as time

import "std.crypto" as crypto

import "std.bytes" as bytes

import "std.map" as map

import "lex-web/ctx" as ctx

import "lex-web/middleware" as mw

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/rls" as rls

import "../src/identity" as identity

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn empty_req() -> ctx.RawRequest {
  { body: "", method: "GET", path: "/x", query: "", headers: map.new() }
}

fn req_with_bearer(tok :: Str) -> ctx.RawRequest {
  { body: "", method: "GET", path: "/x", query: "", headers: map.from_list([("authorization", str.concat("Bearer ", tok))]) }
}

# ── Part A: before() never blocks the request itself ────────────────────────
fn before_no_token_continues() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match rls.before(db, db, [], ctx.from_request(empty_req(), map.new())) {
      Continue(_) => Ok(()),
      Short(_) => Err("rls middleware must never short-circuit an unauthenticated request — it only narrows what the request can SEE"),
    },
  }
}

fn before_invalid_token_continues() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match rls.before(db, db, [bytes.from_str("s")], ctx.from_request(req_with_bearer("garbage"), map.new())) {
      Continue(_) => Ok(()),
      Short(_) => Err("an invalid bearer token must clear the GUC, not short-circuit the request"),
    },
  }
}

fn before_valid_subject_continues() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let secret := bytes.from_str("s")
      match identity.issue_credential(db, secret, "acme", "acct-a", "tenant-a", "", "peer", 3600) {
        Err(e) => Err(e),
        Ok(ic) => match rls.before(db, db, [secret], ctx.from_request(req_with_bearer(ic.token), map.new())) {
          Continue(_) => Ok(()),
          Short(_) => Err("a genuinely resolved subject must still Continue"),
        },
      }
    },
  }
}

# ── Part B: the real Postgres RLS proof (opt-in) ─────────────────────────────
fn pg_url() -> [env] Str {
  match env.get("LEX_SOFT_PG_URL") {
    None => "",
    Some(u) => u,
  }
}

# LEX_SOFT_PG_URL is postgres://<owner>:<pw>@host:port/db — the owner half is
# what production calls the MIGRATION role. Rebuild the same URL against a
# restricted role this test provisions, so the RLS proof runs through a
# connection that cannot bypass it (a superuser/table-owner always can,
# regardless of policy — see rls.lex's docstring on `ev_app`).
fn restricted_role() -> Str {
  "test_rls_restricted"
}

fn restricted_pw() -> Str {
  "test_rls_restricted_pw"
}

fn with_role(url :: Str, role :: Str, pw :: Str) -> Str {
  match list.tail(str.split(url, "@")) {
    rest => match list.head(rest) {
      Some(hostpart) => str.join(["postgres://", role, ":", pw, "@", hostpart], ""),
      None => url,
    },
  }
}

fn exec_tolerant(db :: Db, stmt :: Str) -> [sql, fs_write] Unit {
  let __i := sql.exec(db, stmt, [])
  ()
}

# Idempotent: safe to re-run against a Postgres instance that already has
# this role from a prior test run. NOSUPERUSER NOBYPASSRLS is the whole
# point — this role must be genuinely subject to the RLS policies under test.
fn setup_restricted_role(owner :: Db) -> [sql, fs_write] Unit {
  let __c := exec_tolerant(owner, str.join(["CREATE ROLE ", restricted_role(), " LOGIN PASSWORD '", restricted_pw(), "' NOSUPERUSER NOBYPASSRLS"], ""))
  let __p := exec_tolerant(owner, str.join(["ALTER ROLE ", restricted_role(), " WITH PASSWORD '", restricted_pw(), "'"], ""))
  let __u := exec_tolerant(owner, str.join(["GRANT USAGE ON SCHEMA public TO ", restricted_role()], ""))
  let __g := exec_tolerant(owner, str.join(["GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ", restricted_role()], ""))
  ()
}

type TenantRow = { id :: Str, tenant :: Str }

fn visible_agent_ids(db :: Db) -> [sql, fs_read] List[Str] {
  let rows :: Result[List[TenantRow], SqlError] := sql.query(db, "SELECT id, tenant FROM agents ORDER BY id", [])
  match rows {
    Err(_) => [],
    Ok(rs) => list.map(rs, fn (r :: TenantRow) -> Str {
      r.id
    }),
  }
}

# The core #130 claim: a query scoped to tenant A never returns tenant B's
# rows, exercised through rls.set_tenant_guc — the real function `before`
# calls — on a connection that cannot bypass RLS.
fn rls_blocks_cross_tenant_reads(owner :: Db, restricted :: Db) -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  let __a := reg.register_in(owner, "rls-tenant-a", "rls-agent-a1", "truck", "A1", "http://x/1", [])
  let __b := reg.register_in(owner, "rls-tenant-b", "rls-agent-b1", "truck", "B1", "http://x/2", [])
  let __set_a := rls.set_tenant_guc(restricted, "rls-tenant-a")
  let seen_a := visible_agent_ids(restricted)
  if seen_a != ["rls-agent-a1"] {
    Err(str.concat("scoped to tenant A, expected only rls-agent-a1, saw: ", str.join(seen_a, ",")))
  } else {
    let __set_b := rls.set_tenant_guc(restricted, "rls-tenant-b")
    let seen_b := visible_agent_ids(restricted)
    if seen_b != ["rls-agent-b1"] {
      Err(str.concat("scoped to tenant B, expected only rls-agent-b1, saw: ", str.join(seen_b, ",")))
    } else {
      let __clear := rls.set_tenant_guc(restricted, "")
      let seen_none := visible_agent_ids(restricted)
      assert_true(list.is_empty(seen_none), str.concat("an unresolved (cleared) GUC must see zero rows, saw: ", str.join(seen_none, ",")))
    }
  }
}

# WITH CHECK is the write-side half of the same policy: a restricted
# connection scoped to tenant A must not be able to WRITE a row claiming
# tenant B, even though it can freely read/write its own tenant's rows.
fn rls_with_check_blocks_cross_tenant_write(restricted :: Db) -> [sql, fs_write] Result[Unit, Str] {
  let __set_a := rls.set_tenant_guc(restricted, "rls-tenant-a")
  let own_write := sql.exec(restricted, "INSERT INTO agents (id, kind, name, inbox_url, tenant, registered_at, last_seen_at) VALUES ('rls-agent-a2', 'truck', 'A2', 'http://x/3', 'rls-tenant-a', '', '')", [])
  match own_write {
    Err(e) => Err(str.concat("a write to the caller's OWN tenant must succeed, got: ", e.message)),
    Ok(_) => {
      let cross_write := sql.exec(restricted, "INSERT INTO agents (id, kind, name, inbox_url, tenant, registered_at, last_seen_at) VALUES ('rls-agent-should-fail', 'truck', 'X', 'http://x/4', 'rls-tenant-b', '', '')", [])
      match cross_write {
        Err(_) => Ok(()),
        Ok(_) => Err("WITH CHECK must refuse a write claiming a DIFFERENT tenant than the session GUC"),
      }
    },
  }
}

# End-to-end: rls.before itself (not set_tenant_guc directly) driven by a
# genuinely issued credential, proving the whole middleware — token
# resolution through GUC application — enforces the boundary, not just the
# SQL primitive it calls.
fn rls_before_end_to_end_scopes_visibility(owner :: Db, restricted :: Db) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] Result[Unit, Str] {
  let secret := bytes.from_str("e2e-secret")
  match identity.issue_credential(owner, secret, "acme", "acct-a", "rls-tenant-a", "", "peer", 3600) {
    Err(e) => Err(e),
    Ok(ic) => {
      let __before := rls.before(owner, restricted, [secret], ctx.from_request(req_with_bearer(ic.token), map.new()))
      let seen := visible_agent_ids(restricted)
      if list.fold(seen, true, fn (acc :: Bool, id :: Str) -> Bool {
        acc and str.contains(id, "rls-agent-a")
      }) and list.is_empty(seen) == false {
        let __clear := rls.before(owner, restricted, [secret], ctx.from_request(empty_req(), map.new()))
        assert_true(list.is_empty(visible_agent_ids(restricted)), "an unauthenticated request through before() must see zero rows")
      } else {
        Err(str.concat("before() with a tenant-a credential must scope visibility to tenant-a rows only, saw: ", str.join(seen, ",")))
      }
    },
  }
}

fn postgres_rls(url :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, env] Result[Unit, Str] {
  match sql.open(url) {
    Err(e) => Err(str.concat("LEX_SOFT_PG_URL set but connect failed: ", e.message)),
    Ok(owner) => {
      let __m := migrate.run(owner)
      let __role := setup_restricted_role(owner)
      match sql.open(with_role(url, restricted_role(), restricted_pw())) {
        Err(e) => Err(str.concat("could not connect as the restricted RLS-test role: ", e.message)),
        Ok(restricted) => match rls_blocks_cross_tenant_reads(owner, restricted) {
          Err(e) => Err(e),
          Ok(_) => match rls_with_check_blocks_cross_tenant_write(restricted) {
            Err(e) => Err(e),
            Ok(_) => rls_before_end_to_end_scopes_visibility(owner, restricted),
          },
        },
      }
    },
  }
}

fn postgres_rls_opt_in() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, env] Result[Unit, Str] {
  let url := pg_url()
  if str.is_empty(url) {
    let __skip := io.print("SKIP: postgres RLS (set LEX_SOFT_PG_URL to run it)\n")
    Ok(())
  } else {
    postgres_rls(url)
  }
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, env] Unit {
  let results := [before_no_token_continues(), before_invalid_token_continues(), before_valid_subject_continues(), postgres_rls_opt_in()]
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

