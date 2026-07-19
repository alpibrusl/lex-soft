# examples/agents/tms/agent.lex — example TMS agent for the lex-soft runner.
#
# Illustrative only: shows how to turn a set of HTTP tools into a live A2A agent
# with runner.make_handler + srv.make_agent_def. Wraps lex-tms, lex-logistics,
# lex-routing and lex-telemetry as LLM tools; charging is delegated via the
# platform's send_message tool. The maintained product version lives in
# lex-ev-fleet/agents.
#
# Environment (passed in by the host that mounts this agent):
#   TMS_URL         lex-tms base URL        (default: http://localhost:8200)
#   LOGISTICS_URL   lex-logistics base URL   (default: http://localhost:8300)
#   ROUTING_URL     lex-routing base URL     (default: http://localhost:8400)
#   TELEMETRY_URL   lex-telemetry base URL   (default: http://localhost:8500)

import "std.str" as str

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "../../../src/runner" as runner

import "./tools" as tools

fn tms_capability() -> cap.Capability {
  cap.inbound("handle", "Accept dispatch and coordination requests from other agents.", { title: "TmsMessage", description: "Inbound message for a TMS agent.", fields: [sch.required_str("text", [])] })
}

fn system_prompt() -> Str {
  str.join(["You are a transport management system agent. You plan and dispatch freight", "orders across a fleet of electric trucks.", "For a new dispatch request: list pending orders, list available vehicles and", "drivers, check HOS compliance, compute a route plan, run a range_check using", "live telemetry (get_vehicle_telemetry), and call compute_caw if charging is", "needed before departure. If charging is required, use find_peers with", "intent='charging' and send_message to the charge-agent with topic='charging_request'", "and a JSON payload containing vin, target_soc_pct, and available_minutes.", "Only then call dispatch_order once all conditions are met.", "Track assignments in your state to avoid double-booking.", "When a truck reports completion (topic='load_completed'), mark the order done."], " ")
}

fn make_agent_def(db :: Db, id :: Str, base_url :: Str, tms_url :: Str, logistics_url :: Str, routing_url :: Str, telemetry_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := tms_capability()
  let cfg := { id: id, kind: "tms_agent", system_prompt: system_prompt(), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "tms_url", url: tms_url }, { key: "logistics_url", url: logistics_url }, { key: "routing_url", url: routing_url }, { key: "telemetry_url", url: telemetry_url }], intent_roles: [], tools: tools.make_tools(tms_url, logistics_url, routing_url, telemetry_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("TMS agent ", id), "0.2.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

