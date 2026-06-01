# cmd.lex — CLI surface and transport launcher for lex-soft platforms.
#
# Two responsibilities:
#
#   1. `platform_cli(name, version, description)` — returns a CliDef that
#      documents the standard lex-soft CLI surface. Use it with
#      `acli.introspect(cli)` to emit the ACLI JSON command tree, or with
#      `help.render(cli)` to print --help text. No argv parsing is done here
#      because Lex entry points receive config via env vars; the CliDef is
#      the machine-readable spec of what those env vars map to.
#
#   2. `run_mcp(agent_def)` — runs a single AgentDef as an MCP stdio server.
#      Blocks on the stdin loop; call from a dedicated mcp_main.lex entry
#      point, not from the HTTP serve path.
#
# Standard env vars recognised by lex-soft entry points:
#   DB_PATH        SQLite file path        (default: platform.db)
#   PORT           HTTP listen port        (default: 8100)
#   AGENT_ID       Agent to expose via MCP (mcp_main.lex only)
#   OLLAMA_URL     Ollama base URL         (default: http://localhost:11434)
#   OLLAMA_MODEL   LLM model name          (default: gemma4:latest)

import "lex-cli/src/arg" as arg

import "lex-cli/src/acli" as acli

import "lex-cli/src/help" as help

import "lex-mcp/src/server" as mcp_server

import "lex-agent/src/server" as srv

import "lex-schema/json_value" as jv

# Returns the canonical CliDef for a lex-soft platform binary.
# Callers use this for --help rendering and ACLI introspection;
# actual config is read from env vars inside each entry point.
fn platform_cli(name :: Str, version :: Str, description :: Str) -> arg.CliDef {
  { name: name, version: version, description: description, flags: [arg.flag_str("db", "d", "SQLite database file path", "platform.db"), arg.flag_str("port", "p", "HTTP listen port (serve mode)", "8100"), arg.flag_str("model", "m", "LLM model name", "gemma4:latest"), arg.flag_str("ollama-url", "", "Ollama base URL", "http://localhost:11434"), arg.flag_str("agent", "a", "Agent ID to expose (mcp subcommand)", ""), arg.flag_str("output", "o", "Output format: text | json", "text")], positionals: [], subcommands: [arg.subcommand("serve", "Start HTTP A2A server with all agents mounted", [], []), arg.subcommand("mcp", "Run a single agent as MCP stdio server", [], []), arg.subcommand("introspect", "Print the CLI command tree as ACLI JSON", [], [])] }
}

# Render --help text for the platform CLI.
fn platform_help(name :: Str, version :: Str, description :: Str) -> Str {
  help.render(platform_cli(name, version, description))
}

# Emit the ACLI introspect JSON for the platform CLI.
fn platform_introspect(name :: Str, version :: Str, description :: Str) -> jv.Json {
  acli.introspect(platform_cli(name, version, description))
}

# Run `agent_def` as an MCP stdio server. Blocks until stdin closes.
# Call this from a dedicated mcp_main.lex; do not mix with net.serve_fn.
fn run_mcp(agent_def :: srv.AgentDef) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Nil {
  mcp_server.run(agent_def)
}

