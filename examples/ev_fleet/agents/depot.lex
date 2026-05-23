# depot.lex — LLM-driven charging depot agent definition.
#
# A depot manages a set of chargers. When a truck sends a
# charging_request it decides whether to accept or deny based on
# current charger availability and the truck's contract.

import "std.str" as str
import "std.list" as list
import "std.http" as http
import "std.bytes" as bytes
import "lex-schema/json_value" as jv
import "lex-llm/src/tool" as t
import "lex-llm/src/providers" as providers
import "lex-soft/src/runner" as runner

fn http_get_json(url :: Str) -> [net, io, proc] jv.Json {
  match http.get(url) {
    Err(_) => JObj([("error", JStr("unreachable"))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j)  => j,
      },
    },
  }
}

fn make_tools(charge_url :: Str) -> List[t.Tool] {
  [
    t.define(
      "get_available_chargers",
      "List chargers at this depot that are currently free.",
      { title: "GetAvailableChargers", description: "No parameters.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        Ok(http_get_json(str.concat(charge_url, "/api/v1/chargers?status=available")))
      }
    ),
    t.define(
      "reserve_charger",
      "Reserve a charger for an incoming truck. Returns session_id or error.",
      { title: "ReserveCharger", description: "Reservation parameters.", fields: [
        { name: "vin",              type: "string",  required: true,  description: "Truck VIN.",               constraints: [] },
        { name: "charger_id",       type: "string",  required: true,  description: "Charger to reserve.",      constraints: [] },
        { name: "target_soc_pct",   type: "number",  required: true,  description: "Target SoC percent.",      constraints: [] },
        { name: "available_minutes", type: "number", required: true,  description: "Max session duration.",    constraints: [] },
      ] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let body := jv.stringify(args)
        match http.post(str.concat(charge_url, "/api/v1/charge-schedule"), bytes.from_str(body), "application/json") {
          Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
          Ok(resp) => match bytes.to_str(resp.body) {
            Err(_) => Ok(JObj([("error", JStr("decode error"))])),
            Ok(b)  => match jv.parse(b) { Err(_) => Ok(JStr(b)), Ok(j) => Ok(j) },
          },
        }
      }
    ),
    t.define(
      "get_grid_load",
      "Get the current power draw (kW) and budget cap for this depot.",
      { title: "GetGridLoad", description: "No parameters.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        Ok(http_get_json(str.concat(charge_url, "/api/v1/grid-status")))
      }
    ),
  ]
}

fn system_prompt(depot_id :: Str) -> Str {
  str.concat(
    "You are an autonomous charging depot agent with ID ",
    str.concat(depot_id,
    ". You manage a set of EV chargers and respond to charging requests from trucks. \
When you receive a charging_request message, check get_available_chargers and get_grid_load \
before deciding. If capacity allows, call reserve_charger and reply with topic='charging_grant' \
including the session_id. If capacity is insufficient, reply with topic='charging_deny' and a reason. \
Track active sessions in your state. Prioritise contracted trucks over freelance ones. \
Never accept more sessions than you have chargers.")
  )
}

fn make_def(depot_id :: Str, charge_url :: Str, provider :: providers.Provider, model_name :: Str) -> runner.AgentDef {
  {
    id:            depot_id,
    kind:          "depot",
    system_prompt: system_prompt(depot_id),
    model_name:    model_name,
    provider:      provider,
    tools:         make_tools(charge_url),
  }
}
