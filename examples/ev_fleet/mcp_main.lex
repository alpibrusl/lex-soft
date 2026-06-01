# mcp_main.lex — EV fleet MCP stdio entry point.
#
# Exposes a single fleet agent as an MCP server so Claude Desktop,
# Cursor, or any MCP-native client can call its skills directly.
#
# Usage:
#   AGENT_ID=truck-01 lex run mcp_main.lex
#   AGENT_ID=depot-north lex run mcp_main.lex
#   AGENT_ID=tms-primary lex run mcp_main.lex
#
# Environment variables (same as main.lex, plus AGENT_ID):
#   AGENT_ID         Agent to expose via MCP   (required — no default)
#   DB_PATH          SQLite file path           (default: ev_fleet.db)
#   OLLAMA_URL       Ollama base URL            (default: http://localhost:11434)
#   OLLAMA_MODEL     Model name                 (default: gemma4:latest)
#   TMS_URL          lex-tms service URL        (default: http://localhost:8200)
#   CHARGE_URL       lex-charge service URL     (default: http://localhost:8000)
#   TELEMETRY_URL    lex-telemetry URL          (default: http://localhost:8300)
#   LOGISTICS_URL    lex-logistics URL          (default: http://localhost:8400)
#   PORT             Base URL port for A2A card (default: 8100)

import "std.sql" as sql

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "lex-llm/src/providers" as providers

import "lex-agent/src/server" as srv

import "lex-soft/src/migrate" as migrate

import "lex-soft/src/cmd" as cmd

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

fn agent_base_url(port :: Int, agent_id :: Str) -> Str {
  str.concat("http://localhost:", str.concat(int.to_str(port), str.concat("/agents/", agent_id)))
}

# Identify agent kind from its ID prefix.
fn agent_kind(agent_id :: Str) -> Str {
  if str.starts_with(agent_id, "truck-") {
    "truck"
  } else {
    if str.starts_with(agent_id, "depot-") {
      "depot"
    } else {
      if str.starts_with(agent_id, "tms-") {
        "tms"
      } else {
        "unknown"
      }
    }
  }
}

fn build_agent(db :: Db, agent_id :: Str, port :: Int, t_url :: Str, c_url :: Str, tel_url :: Str, log_url :: Str, provider :: providers.Provider, model :: Str) -> Result[srv.AgentDef, Str] {
  let base := agent_base_url(port, agent_id)
  let kind := agent_kind(agent_id)
  if kind == "truck" {
    Ok(truck_agent.make_agent_def(db, agent_id, base, t_url, tel_url, log_url, provider, model))
  } else {
    if kind == "depot" {
      Ok(depot_agent.make_agent_def(db, agent_id, base, c_url, provider, model))
    } else {
      if kind == "tms" {
        Ok(tms_agent.make_agent_def(db, agent_id, base, t_url, provider, model))
      } else {
        Err(str.concat("unknown agent kind for id: ", agent_id))
      }
    }
  }
}

fn main() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent, llm, proc, crypto] Unit {
  let agent_id := get_env("AGENT_ID", "")
  if str.is_empty(agent_id) {
    let __p := io.print("error: AGENT_ID env var is required")
    let __q := io.print(cmd.platform_help("ev-fleet", "0.3.0", "EV fleet agent platform"))
    ()
  } else {
    let port    := match str.to_int(get_env("PORT", "8100")) { Some(n) => n, None => 8100 }
    let db      := sql.open(get_env("DB_PATH", "ev_fleet.db"))
    let model   := get_env("OLLAMA_MODEL", "gemma4:latest")
    let o_url   := get_env("OLLAMA_URL",   "http://localhost:11434")
    let t_url   := get_env("TMS_URL",      "http://localhost:8200")
    let c_url   := get_env("CHARGE_URL",   "http://localhost:8000")
    let tel_url := get_env("TELEMETRY_URL","http://localhost:8300")
    let log_url := get_env("LOGISTICS_URL","http://localhost:8400")
    let __p1 := io.print(str.concat("=== EV Fleet MCP server — agent: ", agent_id))
    match migrate.run(db) {
      Err(e) => io.print(str.concat("FATAL migrate: ", e)),
      Ok(_) => {
        let __seed := match seed.run(db) {
          Err(e) => io.print(str.concat("WARN seed: ", e)),
          Ok(_)  => (),
        }
        let provider := providers.ollama_at(o_url)
        match build_agent(db, agent_id, port, t_url, c_url, tel_url, log_url, provider, model) {
          Err(e) => io.print(str.concat("error: ", e)),
          Ok(agent_def) => {
            let __p2 := io.print("  MCP stdio ready — waiting for client connection")
            cmd.run_mcp(agent_def)
          },
        }
      },
    }
  }
}
