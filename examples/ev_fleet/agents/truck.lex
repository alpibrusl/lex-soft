# truck.lex — LLM-driven truck agent (lex-agent A2A + lex-llm).
#
# Exposes one inbound A2A capability ("handle") that accepts any
# operational message (dispatch, charging grant/deny, status query).
# Domain tools: lex-telemetry (SoC + live readings), lex-tms (orders,
# assignments, status), lex-logistics (CAW energy estimation).
# Platform tools (find_peers, send_message via A2A) are injected by
# runner.make_handler.

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

fn truck_capability() -> cap.Capability {
  cap.inbound("handle", "Accept operational messages: dispatch, charging grant/deny, status requests.", { title: "TruckMessage", description: "Inbound message for a truck agent.", fields: [sch.required_str("text", [])] })
}

fn make_tools(truck_id :: Str, tms_url :: Str, telemetry_url :: Str, logistics_url :: Str) -> List[t.Tool] {
  [t.define("get_telemetry", "Get live telemetry (SoC%, odometer, speed, status) for this vehicle.", { title: "GetTelemetry", description: "No parameters needed.", fields: [] }, fn (_args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    Ok(http_get_json(str.concat(telemetry_url, str.concat("/vehicles/", str.concat(truck_id, "/telemetry")))))
  }), t.define("get_pending_orders", "Get orders pending assignment or currently assigned to this truck from TMS.", { title: "GetPendingOrders", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders?status=pending&assigned_to=", truck_id))))
  }), t.define("estimate_route_energy", "Estimate energy (kWh) needed for a route using the logistics CAW model.", { title: "EstimateRouteEnergy", description: "Route energy estimation.", fields: [sch.required_str("origin", []), sch.required_str("destination", [])] }, fn (args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    let origin := match jv.get_field(args, "origin") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let dest := match jv.get_field(args, "destination") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let body := jv.stringify(JObj([("vin", JStr(truck_id)), ("origin", JStr(origin)), ("destination", JStr(dest))]))
    match http.post(str.concat(logistics_url, "/api/v1/caw/compute"), bytes.from_str(body), "application/json") {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  }), t.define("report_status", "Report truck status to TMS (available, on_route, charging, breakdown).", { title: "ReportStatus", description: "Status update.", fields: [sch.required_str("status", []), sch.optional(sch.required_str("notes", []))] }, fn (args :: jv.Json) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[jv.Json, Errors] {
    let status := match jv.get_field(args, "status") {
      Some(JStr(s)) => s,
      _ => "available",
    }
    let notes := match jv.get_field(args, "notes") {
      Some(JStr(s)) => s,
      _ => "",
    }
    let body := jv.stringify(JObj([("truck_id", JStr(truck_id)), ("status", JStr(status)), ("notes", JStr(notes))]))
    match http.post(str.concat(tms_url, "/api/v1/vehicles/status"), bytes.from_str(body), "application/json") {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(_) => Ok(JObj([("ok", JBool(true))])),
    }
  })]
}

fn system_prompt(truck_id :: Str) -> Str {
  str.join(["You are autonomous truck agent ", truck_id, ". Decisions: accept/decline loads, request charging when SoC < 20%,", " report status changes to TMS, coordinate with depots.", " Use get_telemetry for live SoC and position.", " Use get_pending_orders to check your load queue.", " Use estimate_route_energy before accepting a long haul.", " Use find_peers(intent='charging') to discover depots; send_message with", " topic='charging_request' and payload JSON including vin, soc_pct, available_minutes.", " Use find_peers(intent='dispatch') to reach your TMS providers.", " Call report_status before and after major state changes."], "")
}

fn make_agent_def(db :: Db, truck_id :: Str, base_url :: Str, tms_url :: Str, telemetry_url :: Str, logistics_url :: Str, provider :: prov.Provider, model_name :: Str) -> srv.AgentDef {
  let capability := truck_capability()
  let cfg := { id: truck_id, kind: "truck", system_prompt: system_prompt(truck_id), model_name: model_name, provider: provider, tools: make_tools(truck_id, tms_url, telemetry_url, logistics_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(truck_id, str.concat("Autonomous truck agent ", truck_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

