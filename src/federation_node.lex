# src/federation_node.lex — a runnable federation node (SA2, lex-loom#179).
#
# `federation.mount_federation` and `federation.mount_agent` are library
# calls, deliberately host-agnostic (see federation.lex's own header) — no
# runnable binary ships them anywhere in this repo today. That's fine for a
# real deployment (every product wires its own persona set + `main.lex`),
# but it means "stand up a second, independent soft node" for testing has
# no entry point to reach for. This is that entry point: the same
# `sql.open` + `router.new` + `net.serve_fn` shape `platform/server.lex`'s
# `main()` already uses for the intra-org coordination API, wired to
# `federation.mount_federation` instead of `build_router` — no domain
# personas mounted (mount_agent is a per-deployment concern), just the
# federation surface: discovery, /peers, /connections, /directory.
#
# Run it:
#   lex run --allow-effects net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto \
#     src/federation_node.lex serve_federation
#
# Env:
#   PORT           HTTP listen port                    (default: 9100)
#   DB_URL         Postgres DSN or SQLite path          (default: federation.db)
#   BASE_URL       this node's own public base URL      (default: http://localhost:<PORT>)
#   ORG            this node's org name                 (default: soft-node)
#   SIGNUP_TOKEN   required on POST /connections if set (default: "" — open, dev-only)
#   REQUIRE_TOKEN  "1" to require a bearer token on mounted agent dispatch (default: "0")
#   IDENTITY_SEED  seeds this node's ed25519 signing key deterministically (default: ORG's value)
#
# Two of these run side by side on different ports/DBs to prove SA2's
# promotion criterion: "a second, independent soft node discovers and
# successfully A2A-messages the registered role end to end" — see
# demo/sa2-mesh-roundtrip.sh.

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.io" as io

import "std.env" as env

import "std.net" as net

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-web/router" as router

import "./migrate" as migrate

import "./federation" as fed

fn env_or(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => default,
  }
}

fn env_int_or(key :: Str, default :: Int) -> [env] Int {
  match str.to_int(env_or(key, "")) {
    Some(n) => n,
    None => default,
  }
}

fn build_cfg(port :: Int) -> [env, crypto] fed.FederationConfig {
  let base := env_or("BASE_URL", str.concat("http://localhost:", int.to_str(port)))
  let org := env_or("ORG", "soft-node")
  let seed := env_or("IDENTITY_SEED", org)
  let sign_seed := crypto.sha256(bytes.from_str(seed))
  let require_token := env_or("REQUIRE_TOKEN", "0") == "1"
  { base: base, org: org, secret: crypto.sha256(bytes.from_str(str.concat(seed, "-secret"))), prev_secrets: [], ttl: 3600, sign_seed: sign_seed, pub_b64: "", require_token: require_token, signup_token: env_or("SIGNUP_TOKEN", ""), hs256_dispatch: true }
}

# ── Entry point ───────────────────────────────────────────────────────────────
fn serve_federation() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent, llm, proc, crypto, approval] Unit {
  let port := env_int_or("PORT", 9100)
  let db_url := env_or("DB_URL", "federation.db")
  let cfg := build_cfg(port)
  let __p1 := io.print("=== lex-soft federation node ===")
  let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
  let __p3 := io.print(str.concat("  db:   ", db_url))
  let __p4 := io.print(str.concat("  org:  ", cfg.org))
  let __p5 := io.print(str.concat("  base: ", cfg.base))
  match sql.open(db_url) {
    Err(e) => io.print(str.concat("FATAL: db open: ", e.message)),
    Ok(db) => match migrate.run(db) {
      Err(e) => io.print(str.concat("FATAL: migrate: ", e)),
      Ok(_) => {
        let __p6 := io.print("  migrations ok")
        let r := fed.mount_federation(router.new(), db, db, cfg)
        let __p7 := io.print("  ready")
        let handler := fn (req :: Request) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, crypto, approval] Response {
          let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
          let result := router.dispatch(r, raw)
          { status: result.status, body: BodyStr(result.body), headers: result.headers }
        }
        net.serve_fn(port, handler)
      },
    },
  }
}

