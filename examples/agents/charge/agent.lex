# agents/charge/agent.lex — charge-agent definition for the lex-soft platform.
#
# Wraps lex-charge REST endpoints as LLM tools. Registered in the platform
# registry under kind="charge_agent" so trucks can find it via find_peers.
#
# Environment variables (read by the platform boot, passed in here):
#   CHARGE_URL   lex-charge base URL  (default: http://localhost:8000)

import "std.str" as str
import "lex-llm/src/providers" as providers
import "lex-soft/src/runner" as runner
import "./tools" as tools

fn system_prompt() -> Str {
  "You are an EV charge management agent. Your job is to help schedule and \
manage charging sessions for electric vehicles at depot chargers. \
Use get_available_chargers to check what is free, get_charger_status to \
inspect a specific charger, and schedule_charge to book a session. \
Always verify a charger is available before scheduling. \
When asked by another agent, extract the VIN, target SoC, and available \
minutes from their message and call schedule_charge directly. Be concise."
}

fn make_def(charge_url :: Str, provider :: providers.Provider, model_name :: Str) -> runner.AgentDef {
  {
    id:            "charge-agent",
    kind:          "charge_agent",
    system_prompt: system_prompt(),
    model_name:    model_name,
    provider:      provider,
    tools:         tools.make_tools(charge_url),
  }
}
