# truck.lex — LLM-driven truck agent definition.
#
# Each truck instance is created by calling make_def/2 with its ID and
# the platform provider. Domain tools call lex-tms for load/route data.

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

fn make_tools(tms_url :: Str) -> List[t.Tool] {
  [
    t.define(
      "get_current_load",
      "Get the current load assignment for this truck from TMS.",
      { title: "GetCurrentLoad", description: "No parameters.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        Ok(http_get_json(str.concat(tms_url, "/api/v1/loads/current")))
      }
    ),
    t.define(
      "get_soc",
      "Get the current battery state-of-charge (%) for this truck.",
      { title: "GetSoc", description: "No parameters.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        Ok(http_get_json(str.concat(tms_url, "/api/v1/vehicle/soc")))
      }
    ),
    t.define(
      "report_status",
      "Report truck status (available, on_route, charging, breakdown) to TMS.",
      { title: "ReportStatus", description: "Status update.", fields: [
        { name: "status", type: "string", required: true, description: "New status.", constraints: [] },
        { name: "notes",  type: "string", required: false, description: "Optional notes.", constraints: [] },
      ] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let status := match jv.get_field(args, "status") { Some(JStr(s)) => s, _ => "available" }
        let notes  := match jv.get_field(args, "notes")  { Some(JStr(s)) => s, _ => "" }
        let body   := jv.stringify(JObj([("status", JStr(status)), ("notes", JStr(notes))]))
        match http.post(str.concat(tms_url, "/api/v1/vehicle/status"), bytes.from_str(body), "application/json") {
          Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
          Ok(_)  => Ok(JObj([("ok", JBool(true))])),
        }
      }
    ),
  ]
}

fn system_prompt(truck_id :: Str) -> Str {
  str.concat(
    "You are an autonomous truck agent with ID ",
    str.concat(truck_id,
    ". Your job is to manage your own operational decisions: accept or decline loads, \
request charging when your SOC is below 20%, report status changes to your TMS providers, \
and coordinate with depots for charging. \
Use find_peers to discover your authorised TMS providers and depots. \
Never contact agents not in your peer list. \
When you need charging, use find_peers with intent='charging', pick the nearest available depot, \
and send_message with topic='charging_request' and a JSON payload including your vin, soc_pct, \
and available_minutes. Always report your status before and after major actions.")
  )
}

fn make_def(truck_id :: Str, tms_url :: Str, provider :: providers.Provider, model_name :: Str) -> runner.AgentDef {
  {
    id:            truck_id,
    kind:          "truck",
    system_prompt: system_prompt(truck_id),
    model_name:    model_name,
    provider:      provider,
    tools:         make_tools(tms_url),
  }
}
