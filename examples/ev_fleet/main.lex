# main.lex — EV fleet demo boot.
#
# Starts one lex-web server; each agent is mounted at two routes:
#   GET  /agents/:id/.well-known/agent.json  — A2A AgentCard discovery
#   POST /agents/:id/                         — A2A JSON-RPC dispatch
#
# Environment variables:
#   DB_PATH          SQLite file path        (default: ev_fleet.db)
#   OLLAMA_URL       Ollama base URL          (default: http://localhost:11434)
#   OLLAMA_MODEL     Model name               (default: gemma4:latest)
#   TMS_URL          lex-tms service URL      (default: http://localhost:8200)
#   CHARGE_URL       lex-charge service URL   (default: http://localhost:8000)
#   TELEMETRY_URL    lex-telemetry URL         (default: http://localhost:8300)
#   LOGISTICS_URL    lex-logistics URL         (default: http://localhost:8400)
#   PORT             HTTP listen port         (default: 8100)

import "std.net" as net

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.env" as env

import "std.io" as io

import "std.map" as map

import "lex-schema/json_value" as jv

import "lex-web/middleware" as mw

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-log/exporter" as exp

import "lex-llm/src/providers" as providers

import "lex-agent/src/server" as srv

import "lex-soft/src/migrate" as migrate

import "./seed" as seed

import "./agents/truck" as truck_agent

import "./agents/depot" as depot_agent

import "./agents/tms" as tms_agent

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => if str.is_empty(str.trim(v)) { default } else { v },
    None => default,
  }
}

fn db_path()       -> [env] Str { get_env("DB_PATH",       "ev_fleet.db") }
fn ollama_url()    -> [env] Str { get_env("OLLAMA_URL",    "http://localhost:11434") }
fn model_name()    -> [env] Str { get_env("OLLAMA_MODEL",  "gemma4:latest") }
fn tms_url()       -> [env] Str { get_env("TMS_URL",       "http://localhost:8200") }
fn charge_url()    -> [env] Str { get_env("CHARGE_URL",    "http://localhost:8000") }
fn telemetry_url() -> [env] Str { get_env("TELEMETRY_URL", "http://localhost:8300") }
fn logistics_url() -> [env] Str { get_env("LOGISTICS_URL", "http://localhost:8400") }

fn serve_port() -> [env] Int {
  match str.to_int(get_env("PORT", "8100")) {
    Some(n) => n,
    None    => 8100,
  }
}

fn agent_base_url(port :: Int, agent_id :: Str) -> Str {
  str.concat("http://localhost:", str.concat(int.to_str(port), str.concat("/agents/", agent_id)))
}

# Mount an agent onto the router at /agents/:id/.well-known/agent.json
# (GET, pure) and /agents/:id/ (POST, effectful A2A dispatch).
fn mount_agent(r :: router.Router, agent_def :: srv.AgentDef, agent_id :: Str) -> router.Router {
  let card_path := str.concat("/agents/", str.concat(agent_id, "/.well-known/agent.json"))
  let rpc_path  := str.concat("/agents/", str.concat(agent_id, "/"))
  let card_body := srv.agent_card_response(agent_def)
  let with_card := router.route(r, "GET", card_path, fn (_c :: ctx.Ctx) -> resp.Response {
    { status: 200, body: card_body, headers: map.from_list([("content-type", "application/json")]) }
  })
  router.route_effectful(with_card, "POST", rpc_path, fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    if str.is_empty(c.body) {
      resp.bad_request("{\"error\":\"empty body\"}")
    } else {
      resp.json(srv.dispatch_request(agent_def, c.body))
    }
  })
}

fn main() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent, llm, proc, crypto] Unit {
  let port     := serve_port()
  let db       := sql.open(db_path())
  let model    := model_name()
  let o_url    := ollama_url()
  let t_url    := tms_url()
  let c_url    := charge_url()
  let tel_url  := telemetry_url()
  let log_url  := logistics_url()
  let __p1 := io.print("=== EV Fleet Platform (lex-soft v0.3 / lex-agent A2A) ===")
  let __p2 := io.print(str.concat("  port:        ", int.to_str(port)))
  let __p3 := io.print(str.concat("  model:       ", model))
  let __p4 := io.print(str.concat("  tms:         ", t_url))
  let __p5 := io.print(str.concat("  charge:      ", c_url))
  let __p6 := io.print(str.concat("  telemetry:   ", tel_url))
  let __p7 := io.print(str.concat("  logistics:   ", log_url))
  match migrate.run(db) {
    Err(e) => io.print(str.concat("FATAL migrate: ", e)),
    Ok(_) => {
      match seed.run(db) {
        Err(e) => io.print(str.concat("WARN seed: ", e)),
        Ok(_)  => io.print("  registry seeded."),
      }
      let provider := providers.ollama_at(o_url)
      let truck_nums := list.range(1, 21)
      let truck_defs := list.map(truck_nums, fn (n :: Int) -> srv.AgentDef {
        let truck_id := str.concat("truck-", if n < 10 { str.concat("0", int.to_str(n)) } else { int.to_str(n) })
        truck_agent.make_agent_def(db, truck_id, agent_base_url(port, truck_id), t_url, tel_url, log_url, provider, model)
      })
      let depot_ids := ["depot-north", "depot-south", "depot-east", "depot-west"]
      let depot_defs := list.map(depot_ids, fn (depot_id :: Str) -> srv.AgentDef {
        depot_agent.make_agent_def(db, depot_id, agent_base_url(port, depot_id), c_url, provider, model)
      })
      let tms_ids := ["tms-primary", "tms-secondary"]
      let tms_defs := list.map(tms_ids, fn (tms_id :: Str) -> srv.AgentDef {
        tms_agent.make_agent_def(db, tms_id, agent_base_url(port, tms_id), t_url, provider, model)
      })
      let all_defs := list.concat(truck_defs, list.concat(depot_defs, tms_defs))
      let all_ids := list.concat(
        list.map(truck_nums, fn (n :: Int) -> Str {
          str.concat("truck-", if n < 10 { str.concat("0", int.to_str(n)) } else { int.to_str(n) })
        }),
        list.concat(depot_ids, tms_ids)
      )
      let zipped := list.zip(all_defs, all_ids)
      let r := list.fold(zipped, router.new(), fn (acc :: router.Router, pair :: (srv.AgentDef, Str)) -> router.Router {
        let (def, id) := pair
        mount_agent(acc, def, id)
      })
      let otlp_url := match env.get("OTLP_URL") {
        Some(u) => u,
        None    => "",
      }
      let otel_cfg := if str.is_empty(otlp_url) {
        exp.stdout_config("lex-soft")
      } else {
        exp.otlp_config(otlp_url, "lex-soft")
      }
      let r := router.use_mw(r, mw.otel(otel_cfg))
      let __p8 := io.print(str.concat("  agents:  ", int.to_str(list.len(all_defs))))
      let __p9 := io.print("  ready — A2A endpoints at /agents/:id/")
      let handler := fn (req :: Request) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, crypto] Response {
        let raw    := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
        let result := router.dispatch(r, raw)
        { status: result.status, body: BodyStr(result.body), headers: result.headers }
      }
      net.serve_fn(port, handler)
    },
  }
}
