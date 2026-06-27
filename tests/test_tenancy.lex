# tests/test_tenancy.lex — acceptance tests for #26 (multi-tenant org model +
# cross-domain directory + relationship-gated calls). Asserts:
#   1. Tenant boundary — an agent in one tenant does not see another tenant's
#      registry (list_by_tenant / find_by_kind_in are scoped).
#   2. Relationship-gated invocation — rel.grants is true only while an active
#      caller→target edge exists; REMOVING the edge revokes access. Contracts
#      can scope which capabilities an edge grants.
#   3. The gate is enforced at the HTTP boundary — a peer presenting
#      X-From-Agent gets 403 with no relationship, 200 once granted, 403 again
#      after revocation.
#   4. Federated publication — an org's advertised capabilities are derived from
#      its published catalog (union of its agents' capabilities) and indexed so
#      discovery spans domains/tenants.

import "std.str" as str

import "std.list" as list

import "std.map" as map

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "../src/migrate" as migrate

import "../src/registry" as reg

import "../src/relationships" as rel

import "../src/federation" as fed

# ── helpers ───────────────────────────────────────────────────────────────────
fn ids_of(refs :: List[reg.AgentRef]) -> List[Str] {
  list.map(refs, fn (a :: reg.AgentRef) -> Str {
    a.id
  })
}

fn same_set(got :: List[Str], want :: List[Str]) -> Bool {
  if list.len(got) == list.len(want) {
    list.fold(want, true, fn (acc :: Bool, w :: Str) -> Bool {
      acc and list.fold(got, false, fn (seen :: Bool, g :: Str) -> Bool {
        seen or g == w
      })
    })
  } else {
    false
  }
}

# ── 1. Tenant boundary ────────────────────────────────────────────────────────
fn tenant_isolation() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a1 := reg.register_in(db, "acme", "truck-1", "truck", "Truck 1", "http://x/1", ["logistics.truck.handle"])
      let __a2 := reg.register_in(db, "acme", "depot-1", "depot", "Depot 1", "http://x/d1", ["logistics.depot.handle"])
      let __v1 := reg.register_in(db, "voltgrid", "v2g-north", "v2g", "V2G North", "http://x/v", ["energy.v2g.dispatch"])
      match reg.list_by_tenant(db, "acme") {
        Err(e) => Err(e),
        Ok(acme) => match reg.list_by_tenant(db, "voltgrid") {
          Err(e) => Err(e),
          Ok(volt) => if same_set(ids_of(acme), ["truck-1", "depot-1"]) {
            if same_set(ids_of(volt), ["v2g-north"]) {
              match reg.find_by_kind_in(db, "voltgrid", "v2g") {
                Ok(vs) => if same_set(ids_of(vs), ["v2g-north"]) {
                  Ok(())
                } else {
                  Err("find_by_kind_in leaked across tenants")
                },
                Err(e) => Err(e),
              }
            } else {
              Err(str.concat("voltgrid tenant saw wrong agents: ", str.join(ids_of(volt), ",")))
            }
          } else {
            Err(str.concat("acme tenant saw wrong agents: ", str.join(ids_of(acme), ",")))
          },
        },
      }
    },
  }
}

# Default-tenant back-compat: reg.register (no tenant) lands in 'default'.
fn default_tenant_backcompat() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __r := reg.register(db, "legacy-1", "truck", "Legacy", "http://x/l", [])
      match reg.list_by_tenant(db, "default") {
        Ok(rows) => if same_set(ids_of(rows), ["legacy-1"]) {
          Ok(())
        } else {
          Err("reg.register should default to the 'default' tenant")
        },
        Err(e) => Err(e),
      }
    },
  }
}

# ── 2. Relationship-gated invocation (logic) ──────────────────────────────────
fn relationship_grant_and_revoke() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __add := rel.add(db, "truck-1", "depot-1", "contracted", "{}")
      if rel.grants(db, "truck-1", "depot-1", "logistics.depot.handle") {
        let __rm := rel.remove(db, "truck-1", "depot-1", "contracted")
        if rel.grants(db, "truck-1", "depot-1", "logistics.depot.handle") {
          Err("removing the relationship must revoke access")
        } else {
          Ok(())
        }
      } else {
        Err("an active edge with an empty contract should grant access")
      }
    },
  }
}

fn capability_scoped_contract() -> [sql, fs_read, fs_write, random, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __add := rel.add(db, "grid-coordinator", "v2g-north", "partner", "{\"capabilities\":[\"energy.v2g.dispatch\"]}")
      if rel.grants(db, "grid-coordinator", "v2g-north", "energy.v2g.dispatch") {
        if rel.grants(db, "grid-coordinator", "v2g-north", "logistics.truck.handle") {
          Err("a scoped contract must NOT grant capabilities outside its list")
        } else {
          Ok(())
        }
      } else {
        Err("a scoped contract must grant the capability it lists")
      }
    },
  }
}

# ── 3. The gate enforced at the HTTP boundary ─────────────────────────────────
fn ping_capability() -> cap.Capability {
  cap.inbound("handle", "Reply pong.", { title: "Ping", description: "ping", fields: [sch.required_str("text", [])] })
}

fn ping_handler(_m :: msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  { next_state: tk.TSCompleted, reply: Some(msg.agent_text("pong")), artifacts: [] }
}

fn ping_def(id :: Str) -> srv.AgentDef {
  let c := card.make(id, "ping", "0.1.0", str.concat("http://localhost/agents/", id), [ping_capability()])
  srv.make_agent_def(c, [{ capability: ping_capability(), handle: ping_handler }])
}

fn demo_cfg() -> fed.FederationConfig {
  { base: "http://localhost", org: "acme", secret: bytes.from_str("s"), ttl: 3600, sign_seed: crypto.sha256(bytes.from_str("d")), pub_b64: "", require_token: false }
}

fn call_as(r :: router.Router, from_agent :: Str) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Int {
  let req := { body: "{}", method: "POST", path: "/agents/depot-1/", query: "", headers: map.from_list([("x-from-agent", from_agent), ("x-capability", "logistics.depot.handle")]) }
  let res := router.dispatch(r, req)
  res.status
}

fn http_gate_revokes_access() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let cfg := demo_cfg()
      let r := fed.mount_agent(router.new(), db, ping_def("depot-1"), "depot-1", cfg)
      let denied := call_as(r, "truck-1")
      if denied == 403 {
        let __add := rel.add(db, "truck-1", "depot-1", "contracted", "{}")
        let allowed := call_as(r, "truck-1")
        if allowed == 200 {
          let __rm := rel.remove(db, "truck-1", "depot-1", "contracted")
          let revoked := call_as(r, "truck-1")
          if revoked == 403 {
            Ok(())
          } else {
            Err(str.concat("after revoke expected 403, got ", int_str(revoked)))
          }
        } else {
          Err(str.concat("with relationship expected 200, got ", int_str(allowed)))
        }
      } else {
        Err(str.concat("no relationship should be 403, got ", int_str(denied)))
      }
    },
  }
}

fn int_str(n :: Int) -> Str {
  if n == 200 {
    "200"
  } else {
    if n == 403 {
      "403"
    } else {
      "other"
    }
  }
}

# ── 4. Federated publication / cross-domain index ─────────────────────────────
fn catalog(caps_a :: List[Str], caps_b :: List[Str]) -> jv.Json {
  let agent := fn (id :: Str, caps :: List[Str]) -> jv.Json {
    JObj([("id", JStr(id)), ("capabilities", JList(list.map(caps, fn (c :: Str) -> jv.Json {
      JStr(c)
    })))])
  }
  JObj([("agents", JList([agent("a1", caps_a), agent("a2", caps_b)]))])
}

fn caps_union_dedup() -> Result[Unit, Str] {
  let got := fed.caps_from_catalog(catalog(["energy.v2g.dispatch", "energy.balancing.frequency"], ["energy.v2g.dispatch"]))
  if same_set(got, ["energy.v2g.dispatch", "energy.balancing.frequency"]) {
    Ok(())
  } else {
    Err(str.concat("expected deduped union, got ", str.join(got, ",")))
  }
}

fn published_catalog_is_discoverable() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __d := fed.init_directory(db)
      let caps := fed.caps_from_catalog(catalog(["energy.v2g.dispatch"], ["energy.balancing.frequency"]))
      match fed.index_catalog(db, "voltgrid", "http://voltgrid/.well-known/agents.json", "", caps) {
        Err(e) => Err(e),
        Ok(_) => {
          let rows :: Result[List[{ org :: Str, capabilities :: Str }], SqlError] := sql.query(db, "SELECT org, capabilities FROM org_directory WHERE org='voltgrid'", [])
          match rows {
            Err(e) => Err(e.message),
            Ok(rs) => match list.head(rs) {
              None => Err("published org was not indexed"),
              Some(row) => if str.contains(row.capabilities, "energy.v2g.dispatch") and str.contains(row.capabilities, "energy.balancing.frequency") {
                Ok(())
              } else {
                Err(str.concat("indexed capabilities incomplete: ", row.capabilities))
              },
            },
          }
        },
      }
    },
  }
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let results := [tenant_isolation(), default_tenant_backcompat(), relationship_grant_and_revoke(), capability_scoped_contract(), http_gate_revokes_access(), caps_union_dedup(), published_catalog_is_discoverable()]
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

