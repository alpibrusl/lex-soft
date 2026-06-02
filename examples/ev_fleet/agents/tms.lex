# tms.lex — LLM-driven transport management system agent (lex-agent A2A + lex-llm).
#
# Manages load assignments across the fleet. Receives route requests,
# queries lex-tms for pending orders, dispatches to contracted trucks
# first then freelance for overflow.

import "std.str" as str

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

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

fn tms_capability() -> cap.Capability {
  cap.inbound("handle", "Accept fleet events: dispatch requests, load completions, truck status updates.", { title: "TmsMessage", description: "Inbound message for a TMS agent.", fields: [sch.required_str("text", [])] })
}

fn make_tools(tms_url :: Str) -> List[t.Tool] {
  [t.define("get_pending_orders", "Get orders waiting to be assigned to a truck.", { title: "GetPendingOrders", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/orders?status=pending")))
  }), t.define("get_order_details", "Get full details for a specific order: origin, destination, weight, deadlines.", { title: "GetOrderDetails", description: "Order lookup.", fields: [sch.required_str("order_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let id := match jv.get_field(args, "order_id") {
      Some(JStr(s)) => s,
      _ => "",
    }
    Ok(http_get_json(str.concat(tms_url, str.concat("/api/v1/orders/", id))))
  }), t.define("assign_order", "Assign an order to a specific truck. Returns the assignment record.", { title: "AssignOrder", description: "Order assignment.", fields: [sch.required_str("order_id", []), sch.required_str("truck_id", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let body := jv.stringify(args)
    match http.post(str.concat(tms_url, "/api/v1/assignments"), bytes.from_str(body), "application/json") {
      Err(_) => Ok(JObj([("error", JStr("unreachable"))])),
      Ok(resp) => match bytes.to_str(resp.body) {
        Err(_) => Ok(JObj([("error", JStr("decode error"))])),
        Ok(b) => match jv.parse(b) {
          Err(_) => Ok(JStr(b)),
          Ok(j) => Ok(j),
        },
      },
    }
  }), t.define("get_fleet_status", "Get status summary for all vehicles in the fleet.", { title: "GetFleetStatus", description: "No parameters.", fields: [] }, fn (_args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(tms_url, "/api/v1/vehicles")))
  })]
}

fn system_prompt(tms_id :: Str) -> Str {
  str.join(["You are transport management system agent ", tms_id, ". You manage load assignments across a fleet of trucks.", " When dispatching: call get_pending_orders, then find_peers(intent='dispatch') to", " discover available trucks (contracted and freelance). Prefer contracted trucks for", " priority orders; use freelance for overflow. For each order, call assign_order then", " send_message to the truck with topic='load_assigned' and order details as payload.", " Track assignments in your state to avoid double-booking.", " When a truck sends topic='load_completed', update state and mark the order done.", " Call get_fleet_status for situational awareness."], "")
}

fn make_agent_def(db :: Db, tms_id :: Str, base_url :: Str, tms_url :: Str, provider :: prov.Provider, model_name :: Str) -> srv.AgentDef {
  let capability := tms_capability()
  let cfg := { id: tms_id, kind: "tms", system_prompt: system_prompt(tms_id), model_name: model_name, provider: provider, tools: make_tools(tms_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(tms_id, str.concat("Transport management system agent ", tms_id), "0.3.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

