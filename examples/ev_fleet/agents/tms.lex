# tms.lex — LLM-driven transport-management system agent.
#
# A TMS agent manages fleet assignments. It receives route requests,
# selects available trucks from its relationship graph, and dispatches
# loads. Trucks can be contracted (exclusive) or freelance.

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
      "get_pending_loads",
      "Get loads waiting to be assigned to a truck.",
      { title: "GetPendingLoads", description: "No parameters.", fields: [] },
      fn (_args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        Ok(http_get_json(str.concat(tms_url, "/api/v1/loads?status=pending")))
      }
    ),
    t.define(
      "get_load_details",
      "Get full details for a specific load including origin, destination, weight, deadlines.",
      { title: "GetLoadDetails", description: "Load lookup.", fields: [
        { name: "load_id", type: "string", required: true, description: "Load identifier.", constraints: [] },
      ] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let id := match jv.get_field(args, "load_id") { Some(JStr(s)) => s, _ => "" }
        Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/loads/", id))))
      }
    ),
    t.define(
      "assign_load",
      "Assign a load to a truck. Returns the assignment record.",
      { title: "AssignLoad", description: "Load assignment.", fields: [
        { name: "load_id",  type: "string", required: true, description: "Load to assign.",        constraints: [] },
        { name: "truck_id", type: "string", required: true, description: "Truck agent ID.",        constraints: [] },
      ] },
      fn (args :: jv.Json) -> [net, io, proc, sql, fs_read, fs_write, time, crypto, random, concurrent] Result[jv.Json, Errors] {
        let body := jv.stringify(args)
        match http.post(str.concat(tms_url, "/api/v1/assignments"), bytes.from_str(body), "application/json") {
          Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
          Ok(resp) => match bytes.to_str(resp.body) {
            Err(_) => Ok(JObj([("error", JStr("decode error"))])),
            Ok(b)  => match jv.parse(b) { Err(_) => Ok(JStr(b)), Ok(j) => Ok(j) },
          },
        }
      }
    ),
  ]
}

fn system_prompt(tms_id :: Str) -> Str {
  str.concat(
    "You are a transport management system agent with ID ",
    str.concat(tms_id,
    ". You manage load assignments across a fleet of trucks. \
When asked to plan or dispatch, call get_pending_loads, then use find_peers with intent='dispatch' \
to discover available trucks (contracted and freelance). Prefer contracted trucks for priority loads; \
use freelance trucks for overflow. For each load, call assign_load once you have identified the best truck, \
then send_message to the truck with topic='load_assigned' and the load details as payload. \
Track assignments in your state to avoid double-booking. \
When a truck reports completion (topic='load_completed'), update your state and mark the load done.")
  )
}

fn make_def(tms_id :: Str, tms_url :: Str, provider :: providers.Provider, model_name :: Str) -> runner.AgentDef {
  {
    id:            tms_id,
    kind:          "tms",
    system_prompt: system_prompt(tms_id),
    model_name:    model_name,
    provider:      provider,
    tools:         make_tools(tms_url),
  }
}
