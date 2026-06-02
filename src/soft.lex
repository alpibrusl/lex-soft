# soft.lex — public facade for the lex-soft platform.
#
# Import this file to get the full platform surface:
#   migrate, registry, relationships, resolver, a2a, state_store, trace, runner,
#   outbox, platform/client, platform/server.
#
# Run the coordination API server (port $PORT, db $DB_PATH):
#   lex run --allow-effects net,io,env,time,random,sql,fs_read,fs_write,concurrent,llm,proc,crypto \
#     src/soft.lex start_platform

import "./migrate" as migrate

import "./registry" as registry

import "./relationships" as relationships

import "./resolver" as resolver

import "./a2a" as a2a

import "./state_store" as state_store

import "./trace" as trace

import "./runner" as runner

import "./cmd" as cmd

import "./outbox" as outbox

import "./platform/client" as platform_client

import "./platform/server" as platform_server

# Re-export key types for convenience.
type AgentRef = registry.AgentRef

type Relationship = relationships.Relationship

type AgentConfig = runner.AgentConfig

type PlatformClient = platform_client.PlatformClient

type Backend = runner.Backend

# Entry point — start the coordination API HTTP server.
# Reads PORT (default 9000) and DB_PATH from environment.
fn start_platform() -> [net, io, env, time, random, sql, fs_read, fs_write, concurrent, llm, proc, crypto] Unit {
  platform_server.main()
}

