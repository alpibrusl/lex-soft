# tests/test_audit_export.lex — signed audit archive (#48).
#
# The export body must verify against the deployment's published key: Ed25519
# over the sha256 hex of the archive string. A different key must NOT verify.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.map" as map

import "std.crypto" as crypto

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-crypto/src/ed25519" as ed

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/identity" as identity

import "../src/settlement" as settlement

import "../src/audit" as audit

fn jfield(j :: jv.Json, k :: Str) -> Str {
  match jv.get_field(j, k) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn export_verifies_against_published_key() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let secret := bytes.from_str("test-secret")
      let seed := crypto.sha256(bytes.from_str("test-deploy-seed"))
      let pub := match ed.public_key_b64(seed) {
        Ok(p) => p,
        Err(_) => "",
      }
      let __r := reg.register_in(db, "org-e", "agent-e1", "truck", "agent-e1", "http://x/", ["x"])
      let log := settlement.trail_on(db)
      let __e := settlement.record_run(log, "agent-e1", "handle", "in-1", "out-1", [])
      let __a := identity.create_account(db, "org-e", "org-e", "Org E", "free")
      let tok := match identity.issue_credential(db, secret, "node", "org-e", "org-e", "agent-e1", "", 3600) {
        Ok(cred) => cred.token,
        Err(e) => str.concat("ERR:", e),
      }
      let r := audit.mount_export(router.new(), db, secret, seed, pub)
      let req := { body: "", method: "POST", path: "/audit/export", query: "", headers: map.from_list([("authorization", str.concat("Bearer ", tok))]) }
      let response := router.dispatch(r, req)
      match jv.parse(response.body) {
        Err(_) => Err(str.concat("export not json: ", str.slice(response.body, 0, 120))),
        Ok(j) => {
          let archive := jfield(j, "archive")
          let digest := jfield(j, "sha256")
          let sig := jfield(j, "signature")
          let recomputed := crypto.hex_encode(crypto.sha256(bytes.from_str(archive)))
          let sig_ok := ed.verify_text(pub, digest, sig)
          let wrong_pub := match ed.public_key_b64(crypto.sha256(bytes.from_str("another-seed"))) {
            Ok(p) => p,
            Err(_) => "",
          }
          let wrong_fails := not ed.verify_text(wrong_pub, digest, sig)
          if recomputed == digest and sig_ok and wrong_fails and str.contains(archive, "org-e") {
            Ok(())
          } else {
            Err(str.join(["export bad: digest_match=", if recomputed == digest {
              "y"
            } else {
              "n"
            }, " sig_ok=", if sig_ok {
              "y"
            } else {
              "n"
            }, " wrong_fails=", if wrong_fails {
              "y"
            } else {
              "n"
            }], ""))
          }
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [export_verifies_against_published_key()]
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

