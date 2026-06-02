# platform/server.lex — lex-soft platform HTTP server.
#
# Exposes the coordination API that all agents call instead of touching
# a local SQLite. Backed by Postgres (or SQLite for local dev).
# Runs as a standalone service in cloud / on-premise.
#
# Routes:
#   POST   /v1/agents                    register or refresh an agent
#   GET    /v1/agents/:id               lookup agent by id
#   GET    /v1/agents/:id/peers         peer discovery (intent query param)
#   POST   /v1/agents/:id/heartbeat     liveness ping
#   GET    /v1/state/:id                load agent state blob
#   POST   /v1/state/:id                save agent state blob
#   POST   /v1/messages                 deliver a message → routes to inbox
#   GET    /v1/messages/:id/pull        edge agent polls its inbox
#
# Background workers (started via conc.spawn in main):
#   push_worker  — drains the "push" queue, delivers to cloud agents
#
# Environment variables:
#   DB_URL         Postgres DSN          (default: platform.db / SQLite dev)
#   PORT           HTTP listen port      (default: 9000)

import "std.net" as net

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "std.map" as map

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "../registry" as reg

import "../relationships" as rel

import "../state_store" as state

import "../migrate" as migrate

import "./inbox" as inbox

# ---- Route handlers (pure — no effects) -------------------------
fn handle_lookup(db :: Db, c :: ctx.Ctx) -> [sql, fs_read] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(id) => match reg.find_by_id(db, id) {
      Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
      Ok(None) => resp.not_found(),
      Ok(Some(ref)) => resp.json(jv.stringify(JObj([("id", JStr(ref.id)), ("kind", JStr(ref.kind)), ("name", JStr(ref.name)), ("inbox_url", JStr(ref.inbox_url)), ("status", JStr(ref.status))]))),
    },
  }
}

fn handle_state_load(db :: Db, c :: ctx.Ctx) -> [sql, fs_read] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(id) => {
      let s := state.load(db, id)
      resp.json(jv.stringify(JObj([("state", JStr(s))])))
    },
  }
}

# ---- Route handlers (effectful) ---------------------------------
fn handle_register(db :: Db, c :: ctx.Ctx) -> [sql, fs_write, time] resp.Response {
  match jv.parse(c.body) {
    Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
    Ok(j) => {
      let id := str_field(j, "id")
      let kind := str_field(j, "kind")
      let name := str_field(j, "name")
      let inbox_url := str_field(j, "inbox_url")
      let caps := list_str_field(j, "capabilities")
      if str.is_empty(id) {
        resp.bad_request("{\"error\":\"id required\"}")
      } else {
        match reg.register(db, id, kind, name, inbox_url, caps) {
          Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
          Ok(_) => resp.json("{\"ok\":true}"),
        }
      }
    },
  }
}

fn handle_peers(db :: Db, c :: ctx.Ctx) -> [sql, fs_read] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(agent_id) => {
      let intent := ctx.query_param_or(c, "intent", "coordination")
      match rel.peers_of(db, agent_id) {
        Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
        Ok(rels) => {
          let filtered := filter_by_intent(rels, intent)
          let peer_jsons := list.fold(filtered, [], fn (acc :: List[jv.Json], r :: rel.Relationship) -> [sql, fs_read] List[jv.Json] {
            match reg.find_by_id(db, r.to_agent) {
              Ok(Some(ref)) => list.concat(acc, [JObj([("id", JStr(ref.id)), ("kind", JStr(ref.kind)), ("name", JStr(ref.name)), ("inbox_url", JStr(ref.inbox_url)), ("role", JStr(r.role))])]),
              _ => acc,
            }
          })
          resp.json(jv.stringify(JList(peer_jsons)))
        },
      }
    },
  }
}

fn handle_heartbeat(db :: Db, c :: ctx.Ctx) -> [sql, fs_write, time] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(id) => match reg.heartbeat(db, id) {
      Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
      Ok(_) => resp.json("{\"ok\":true}"),
    },
  }
}

fn handle_state_save(db :: Db, c :: ctx.Ctx) -> [sql, fs_write, time] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(id) => match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let state_json := str_field(j, "state")
        match state.save(db, id, state_json) {
          Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
          Ok(_) => resp.json("{\"ok\":true}"),
        }
      },
    },
  }
}

fn handle_send(db :: Db, c :: ctx.Ctx) -> [sql, fs_read, fs_write, time] resp.Response {
  match jv.parse(c.body) {
    Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
    Ok(j) => {
      let to_id := str_field(j, "to")
      if str.is_empty(to_id) {
        resp.bad_request("{\"error\":\"to required\"}")
      } else {
        match inbox.deliver(db, to_id, c.body) {
          Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
          Ok(_) => resp.json("{\"queued\":true}"),
        }
      }
    },
  }
}

fn handle_pull(db :: Db, c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent] resp.Response {
  match ctx.path_param(c, "id") {
    None => resp.bad_request("{\"error\":\"missing id\"}"),
    Some(agent_id) => match inbox.pull_next(db, agent_id) {
      Err(e) => resp.json(jv.stringify(JObj([("error", JStr(e))]))),
      Ok(None) => resp.json("{\"payload\":null}"),
      Ok(Some(payload)) => resp.json(jv.stringify(JObj([("payload", JStr(payload))]))),
    },
  }
}

# ---- Router setup -----------------------------------------------
fn build_router(db :: Db) -> router.Router {
  let r0 := router.new()
  let r1 := router.route_effectful(r0, "GET", "/v1/agents/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_lookup(db, c)
  })
  let r2 := router.route_effectful(r1, "GET", "/v1/state/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_state_load(db, c)
  })
  let r3 := router.route_effectful(r2, "POST", "/v1/agents", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_register(db, c)
  })
  let r4 := router.route_effectful(r3, "GET", "/v1/agents/:id/peers", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_peers(db, c)
  })
  let r5 := router.route_effectful(r4, "POST", "/v1/agents/:id/heartbeat", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_heartbeat(db, c)
  })
  let r6 := router.route_effectful(r5, "POST", "/v1/state/:id", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_state_save(db, c)
  })
  let r7 := router.route_effectful(r6, "POST", "/v1/messages", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_send(db, c)
  })
  router.route_effectful(r7, "GET", "/v1/messages/:id/pull", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    handle_pull(db, c)
  })
}

# ---- Entry point ------------------------------------------------
fn main() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent, llm, proc, crypto] Unit {
  let port := match str.to_int(match env.get("PORT") {
    Some(p) => p,
    None => "9000",
  }) {
    Some(n) => n,
    None => 9000,
  }
  let db_path := match env.get("DB_PATH") {
    Some(p) => p,
    None => "platform.db",
  }
  let __p1 := io.print("=== lex-soft platform server ===")
  let __p2 := io.print(str.concat("  port:    ", int.to_str(port)))
  let __p3 := io.print(str.concat("  db:      ", db_path))
  match sql.open(db_path) {
    Err(e) => io.print(str.concat("FATAL: db open: ", e.message)),
    Ok(db) => match migrate.run(db) {
      Err(e) => io.print(str.concat("FATAL: migrate: ", e)),
      Ok(_) => {
        let __p4 := io.print("  migrations ok")
        let r := build_router(db)
        let __p5 := io.print("  ready")
        let handler := fn (req :: Request) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, crypto] Response {
          let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
          let result := router.dispatch(r, raw)
          { status: result.status, body: BodyStr(result.body), headers: result.headers }
        }
        net.serve_fn(port, handler)
      },
    },
  }
}

# ---- Helpers ----------------------------------------------------
fn str_field(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn list_str_field(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(items)) => list.fold(items, [], fn (acc :: List[Str], item :: jv.Json) -> List[Str] {
      match item {
        JStr(s) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
}

fn filter_by_intent(rels :: List[rel.Relationship], intent :: Str) -> List[rel.Relationship] {
  let roles := if intent == "charging" {
    ["preferred_charger", "charger"]
  } else {
    if intent == "dispatch" {
      ["contracted", "freelance"]
    } else {
      if intent == "reporting" {
        ["reporting"]
      } else {
        []
      }
    }
  }
  if list.is_empty(roles) {
    rels
  } else {
    list.filter(rels, fn (r :: rel.Relationship) -> Bool {
      list.fold(roles, false, fn (acc :: Bool, role :: Str) -> Bool {
        acc or r.role == role
      })
    })
  }
}

