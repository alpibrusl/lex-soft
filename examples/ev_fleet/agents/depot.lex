# depot.lex — LLM-driven charging depot agent (lex-agent A2A + lex-llm).
#
# Responds to charging_request messages from trucks. Checks charger
# availability and grid load via lex-charge before granting or denying.
# Prioritises contracted trucks over freelance based on relationship roles.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_get_json(url :: Str) -> [net] jv.Json {
  match http.get(url) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn depot_capability() -> cap.Capability {
  cap.inbound("handle", "Accept charging requests from trucks. Grant or deny based on capacity and grid load.", { title: "DepotMessage", description: "Inbound message for a depot agent.", fields: [sch.required_str("text", [])] })
}

fn make_tools(charge_url :: Str) -> List[t.Tool] {
  [t.define("get_available_chargers", "List chargers at this depot that are currently free and ready.", { title: "GetAvailableChargers", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    Ok(http_get_json(str.concat(charge_url, "/api/v1/chargers?status=available")))
  }), t.define("get_charger_sessions", "List currently active charging sessions at this depot.", { title: "GetChargerSessions", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    Ok(http_get_json(str.concat(charge_url, "/api/v1/chargers?status=occupied")))
  }), t.define("get_grid_load", "Get current power draw (kW) and budget cap for this depot's grid connection.", { title: "GetGridLoad", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    Ok(http_get_json(str.concat(charge_url, "/api/v1/grid-status")))
  }), t.define("reserve_charger", "Reserve a specific charger for an incoming truck. Returns session_id on success.", { title: "ReserveCharger", description: "Charger reservation parameters.", fields: [sch.required_str("vin", []), sch.required_str("charger_id", []), sch.required_float("target_soc_pct", []), sch.required_float("available_minutes", [])] }, fn (args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    let body := jv.stringify(args)
    match http.post(str.concat(charge_url, "/api/v1/charge-schedule"), bytes.from_str(body), "application/json") {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  })]
}

fn system_prompt(depot_id :: Str) -> Str {
  str.join(["You are autonomous charging depot agent ", depot_id, ". You manage a set of EV chargers. When you receive a charging_request message:", " 1. Call get_available_chargers to see free slots.", " 2. Call get_grid_load to check power budget.", " 3. If capacity allows, call reserve_charger and reply with topic='charging_grant' including session_id.", " 4. If at capacity, reply with topic='charging_deny' and a reason.", " Prioritise contracted trucks over freelance (check relationship roles in peer list).", " Track sessions via your state. Never accept more sessions than available chargers.", " Call find_peers(intent='reporting') to send status summaries to TMS."], "")
}

fn make_agent_def(db :: Db, depot_id :: Str, base_url :: Str, charge_url :: Str, provider :: prov.Provider, model_name :: Str) -> srv.AgentDef {
  let capability := depot_capability()
  let cfg := { id: depot_id, kind: "depot", system_prompt: system_prompt(depot_id), model_name: model_name, provider: provider, tools: make_tools(charge_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(depot_id, str.concat("Charging depot agent ", depot_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

