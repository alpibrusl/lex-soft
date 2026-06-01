# agents/tms/agent.lex — tms-agent definition for the lex-soft platform.
#
# Wraps lex-tms, lex-logistics, lex-routing, and lex-telemetry as LLM tools.
# Charging is delegated via the platform's send_message tool to charge-agent
# (no hardcoded A2A envelope — the platform resolver handles routing).
#
# Environment variables (passed in by the platform boot):
#   TMS_URL         lex-tms base URL        (default: http://localhost:8200)
#   LOGISTICS_URL   lex-logistics base URL   (default: http://localhost:8300)
#   ROUTING_URL     lex-routing base URL     (default: http://localhost:8400)
#   TELEMETRY_URL   lex-telemetry base URL   (default: http://localhost:8500)

import "std.str" as str
import "lex-llm/src/providers" as providers
import "lex-soft/src/runner" as runner
import "./tools" as tools

fn system_prompt() -> Str {
  "You are a transport management system agent. You plan and dispatch freight \
orders across a fleet of electric trucks. \
For a new dispatch request: list pending orders, list available vehicles and \
drivers, check HOS compliance, compute a route plan, run a range_check using \
live telemetry (get_vehicle_telemetry), and call compute_caw if charging is \
needed before departure. If charging is required, use find_peers with \
intent='charging' and send_message to the charge-agent with topic='charging_request' \
and a JSON payload containing vin, target_soc_pct, and available_minutes. \
Only then call dispatch_order once all conditions are met. \
Track assignments in your state to avoid double-booking. \
When a truck reports completion (topic='load_completed'), mark the order done."
}

fn make_def(
  tms_url       :: Str,
  logistics_url :: Str,
  routing_url   :: Str,
  telemetry_url :: Str,
  provider      :: providers.Provider,
  model_name    :: Str,
) -> runner.AgentDef {
  {
    id:            "tms-agent",
    kind:          "tms_agent",
    system_prompt: system_prompt(),
    model_name:    model_name,
    provider:      provider,
    tools:         tools.make_tools(tms_url, logistics_url, routing_url, telemetry_url),
  }
}
