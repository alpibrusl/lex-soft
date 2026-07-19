# examples/agents/charge/agent.lex — example charge agent for the lex-soft runner.
#
# Illustrative only: shows how to turn a set of HTTP tools into a live A2A agent
# with runner.make_handler + srv.make_agent_def. Wraps lex-charge REST endpoints
# as LLM tools. The maintained product version lives in lex-ev-fleet/agents.
#
# Environment (passed in by the host that mounts this agent):
#   CHARGE_URL   lex-charge base URL  (default: http://localhost:8000)

import "std.str" as str

import "lex-schema/schema" as sch

import "lex-spec/capability" as cap

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "../../../src/runner" as runner

import "./tools" as tools

fn charge_capability() -> cap.Capability {
  cap.inbound("handle", "Accept charging requests from other agents: schedule and manage charging sessions.", { title: "ChargeMessage", description: "Inbound message for a charge agent.", fields: [sch.required_str("text", [])] })
}

fn system_prompt() -> Str {
  str.join(["You are an EV charge management agent. Your job is to help schedule and", "manage charging sessions for electric vehicles at depot chargers.", "Use get_available_chargers to check what is free, get_charger_status to", "inspect a specific charger, and schedule_charge to book a session.", "Always verify a charger is available before scheduling.", "When asked by another agent, extract the VIN, target SoC, and available", "minutes from their message and call schedule_charge directly. Be concise."], " ")
}

fn make_agent_def(db :: Db, id :: Str, base_url :: Str, charge_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := charge_capability()
  let cfg := { id: id, kind: "charge_agent", system_prompt: system_prompt(), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "charge_url", url: charge_url }], intent_roles: [], tools: tools.make_tools(charge_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Charge agent ", id), "0.2.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

