# tests/test_audit_export.lex — signed audit archive (#48).
#
# The export body must verify against the deployment's published key: Ed25519
# over the sha256 hex of the archive string. A different key must NOT verify.

import "std.io" as io

import "std.str" as str

import "std.int" as int

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
      let r := audit.mount_export(router.new(), db, [secret], seed, pub)
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

# M-2 negative: the tenant boundary holds at the HTTP surface, not just in the
# scoping helper. Org A holds a real credential and has one event of its own, so
# a pass here cannot be an artefact of a globally broken query. Org B's event id
# must appear in NEITHER the events page NOR the signed export archive, and the
# ?agent= override must not let A name B's agent.
fn cross_tenant_read_is_refused() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Result[Unit, Str] {
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
      let __ra := reg.register_in(db, "org-a", "agent-a1", "truck", "agent-a1", "http://a/", ["x"])
      let __rb := reg.register_in(db, "org-b", "agent-b1", "truck", "agent-b1", "http://b/", ["x"])
      let log := settlement.trail_on(db)
      let id_a := settlement.record_run(log, "agent-a1", "handle", "in-a", "out-a", [])
      let id_b := settlement.record_run(log, "agent-b1", "handle", "in-b", "out-b", [])
      let __acc := identity.create_account(db, "org-a", "org-a", "Org A", "free")
      let tok_a := match identity.issue_credential(db, secret, "node", "org-a", "org-a", "agent-a1", "", 3600) {
        Ok(cred) => cred.token,
        Err(e) => str.concat("ERR:", e),
      }
      let r := audit.mount_export(audit.mount(router.new(), db, [secret]), db, [secret], seed, pub)
      let hdrs := map.from_list([("authorization", str.concat("Bearer ", tok_a))])
      let events := router.dispatch(r, { body: "", method: "GET", path: "/audit/events", query: "", headers: hdrs })
      let spoofed := router.dispatch(r, { body: "", method: "GET", path: "/audit/events", query: "agent=agent-b1", headers: hdrs })
      let export := router.dispatch(r, { body: "", method: "POST", path: "/audit/export", query: "", headers: hdrs })
      let sees_own := str.contains(events.body, id_a)
      let leaks_events := str.contains(events.body, id_b)
      let leaks_spoofed := str.contains(spoofed.body, id_b)
      let leaks_export := str.contains(export.body, id_b)
      if sees_own and not leaks_events and not leaks_spoofed and not leaks_export {
        Ok(())
      } else {
        Err(str.join(["cross-tenant audit boundary broken: sees_own=", if sees_own {
          "y"
        } else {
          "n"
        }, " leak_events=", if leaks_events {
          "y"
        } else {
          "n"
        }, " leak_agent_param=", if leaks_spoofed {
          "y"
        } else {
          "n"
        }, " leak_export=", if leaks_export {
          "y"
        } else {
          "n"
        }], ""))
      }
    },
  }
}

# The summary counts only the caller's own events. Org A did ONE run (3 events:
# received/step/completed); org B did TWO (6). A's summary must total exactly 3
# and never mention B's event id — a leak would read 9. Same boundary as
# /audit/events, asserted independently because a GROUP BY is an easy place to
# forget the WHERE.
fn summary_is_tenant_scoped() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let secret := bytes.from_str("test-secret")
      let __ra := reg.register_in(db, "org-a", "agent-a1", "truck", "agent-a1", "http://a/", ["x"])
      let __rb := reg.register_in(db, "org-b", "agent-b1", "truck", "agent-b1", "http://b/", ["x"])
      let log := settlement.trail_on(db)
      let __ea := settlement.record_run(log, "agent-a1", "handle", "in-a", "out-a", [])
      let id_b := settlement.record_run(log, "agent-b1", "handle", "in-b", "out-b", [])
      let __eb := settlement.record_run(log, "agent-b1", "handle", "in-b2", "out-b2", [])
      let __acc := identity.create_account(db, "org-a", "org-a", "Org A", "free")
      let tok_a := match identity.issue_credential(db, secret, "node", "org-a", "org-a", "agent-a1", "", 3600) {
        Ok(cred) => cred.token,
        Err(e) => str.concat("ERR:", e),
      }
      let r := audit.mount(router.new(), db, [secret])
      let hdrs := map.from_list([("authorization", str.concat("Bearer ", tok_a))])
      let res := router.dispatch(r, { body: "", method: "GET", path: "/audit/summary", query: "", headers: hdrs })
      let leaks_b := str.contains(res.body, id_b)
      match jv.parse(res.body) {
        Err(_) => Err(str.concat("summary not json: ", str.slice(res.body, 0, 120))),
        Ok(j) => {
          let total := match jv.get_field(j, "total") {
            Some(JInt(n)) => n,
            _ => -1,
          }
          if res.status == 200 and total == 3 and not leaks_b {
            Ok(())
          } else {
            Err(str.join(["summary scope wrong: status=", int.to_str(res.status), " total=", int.to_str(total), " leaks_b=", if leaks_b {
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
  let results := [export_verifies_against_published_key(), cross_tenant_read_is_refused(), summary_is_tenant_scoped()]
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

