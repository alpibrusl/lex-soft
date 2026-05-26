# main.lex — EV fleet demo boot.
#
# Starts one lex-web server per agent kind (or all on one port for demo).
# Each agent's inbox is mounted at POST /agents/:agent_id/inbox.
#
# Environment variables:
#   DB_PATH         SQLite file path        (default: ev_fleet.db)
#   OLLAMA_URL      Ollama base URL          (default: http://localhost:11434)
#   OLLAMA_MODEL    Model name               (default: gemma4:latest)
#   TMS_URL         lex-tms service URL      (default: http://localhost:8200)
#   CHARGE_URL      lex-charge service URL   (default: http://localhost:8000)
#   PORT            HTTP listen port         (default: 8100)

import "std.net" as net

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-web/middleware" as mw

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-log/exporter" as exp

import "lex-llm/src/providers" as providers

import "lex-soft/src/migrate" as migrate

import "lex-soft/src/runner" as runner

import "./seed" as seed

import "./agents/truck" as truck_agent

import "./agents/depot" as depot_agent

import "./agents/tms" as tms_agent

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => if str.is_empty(str.trim(v)) {
      default
    } else {
      v
    },
    None => default,
  }
}

fn db_path() -> [env] Str {
  get_env("DB_PATH", "ev_fleet.db")
}

fn ollama_url() -> [env] Str {
  get_env("OLLAMA_URL", "http://localhost:11434")
}

fn model_name() -> [env] Str {
  get_env("OLLAMA_MODEL", "gemma4:latest")
}

fn tms_url() -> [env] Str {
  get_env("TMS_URL", "http://localhost:8200")
}

fn charge_url() -> [env] Str {
  get_env("CHARGE_URL", "http://localhost:8000")
}

fn serve_port() -> [env] Int {
  match str.to_int(get_env("PORT", "8100")) {
    Some(n) => n,
    None => 8100,
  }
}

fn mount_agent(r :: router.Router, db :: sql.Db, def :: runner.AgentDef) -> router.Router {
  let path := str.concat("/agents/", str.concat(def.id, "/inbox"))
  router.route_effectful(r, "POST", path, fn (c :: ctx.Ctx) -> [io, time, sql, concurrent, net, random, fs_read, fs_write] resp.Response {
    if str.is_empty(c.body) {
      resp.bad_request("empty body")
    } else {
      let answer := runner.step(db, def, c.body)
      resp.json(jv.stringify(JObj([("reply", JStr(answer))])))
    }
  })
}

fn main() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent] Unit {
  let port := serve_port()
  let db := sql.open(db_path())
  let model := model_name()
  let o_url := ollama_url()
  let t_url := tms_url()
  let c_url := charge_url()
  let __lex_discard_1 := io.print("=== EV Fleet Platform ===")
  let __lex_discard_2 := io.print(str.concat("  port:    ", int.to_str(port)))
  let __lex_discard_3 := io.print(str.concat("  model:   ", model))
  let __lex_discard_4 := io.print(str.concat("  tms:     ", t_url))
  let __lex_discard_5 := io.print(str.concat("  charge:  ", c_url))
  match migrate.run(db) {
    Err(e) => io.print(str.concat("FATAL migrate: ", e)),
    Ok(_) => {
      match seed.run(db) {
        Err(e) => io.print(str.concat("WARN seed: ", e)),
        Ok(_) => io.print("  registry seeded."),
      }
      let provider := providers.ollama_at(o_url)
      let truck_defs := list.map(list.range(1, 21), fn (n :: Int) -> runner.AgentDef {
        truck_agent.make_def(str.concat("truck-", if n < 10 {
          str.concat("0", int.to_str(n))
        } else {
          int.to_str(n)
        }), t_url, provider, model)
      })
      let depot_defs := [depot_agent.make_def("depot-north", c_url, provider, model), depot_agent.make_def("depot-south", c_url, provider, model), depot_agent.make_def("depot-east", c_url, provider, model), depot_agent.make_def("depot-west", c_url, provider, model)]
      let tms_defs := [tms_agent.make_def("tms-primary", t_url, provider, model), tms_agent.make_def("tms-secondary", t_url, provider, model)]
      let all_defs := list.concat(truck_defs, list.concat(depot_defs, tms_defs))
      let r := list.fold(all_defs, router.new(), fn (acc :: router.Router, def :: runner.AgentDef) -> router.Router {
        mount_agent(acc, db, def)
      })
      let otlp_url := match env.get("OTLP_URL") {
        Some(u) => u,
        None => "",
      }
      let otel_cfg := if str.is_empty(otlp_url) {
        exp.stdout_config("lex-soft")
      } else {
        exp.otlp_config(otlp_url, "lex-soft")
      }
      let r := router.use_mw(r, mw.otel(otel_cfg))
      let __lex_discard_6 := io.print(str.concat("  agents:  ", int.to_str(list.len(all_defs))))
      let __lex_discard_7 := io.print("  ready.")
      let handler := fn (req :: Request) -> [io, time, sql, concurrent, net, random, fs_read, fs_write] Response {
        let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
        let result := router.dispatch(r, raw)
        { status: result.status, body: BodyStr(result.body), headers: result.headers }
      }
      net.serve_fn(port, handler)
    },
  }
}

