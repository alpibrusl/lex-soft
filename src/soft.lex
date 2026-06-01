# soft.lex — public facade for the lex-soft platform.
#
# Import this file to get the full platform surface:
#   migrate, registry, relationships, resolver, a2a, state_store, trace, runner.

import "./migrate" as migrate

import "./registry" as registry

import "./relationships" as relationships

import "./resolver" as resolver

import "./a2a" as a2a

import "./state_store" as state_store

import "./trace" as trace

import "./runner" as runner

import "./cmd" as cmd

# Re-export key types for convenience.
type AgentRef = registry.AgentRef

type Relationship = relationships.Relationship

type AgentConfig = runner.AgentConfig

