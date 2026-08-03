# src/pack.lex — the domain-pack plugin model.
#
# A DomainPack is a self-contained, mountable bundle of agents for one domain
# (logistics, energy, robotics, …). The platform core mounts a pack without
# knowing anything about the domain — adding a domain never edits the core.
# This is the seam that sits on top of the federation core (federation.lex):
# `mount_federation` exposes the wire surface; `mount_pack` mounts a domain's
# agents onto it.
#
# A pack provides:
#   - personas: groups of agent ids sharing one AgentDef builder. The builder is
#     pure — (db, agent_id) -> AgentDef — and closes over the pack's tool URLs /
#     provider / model. Each AgentDef already bundles its skills + tools, so the
#     pack's "tools" and "specs/gates" ride inside the personas it builds.
#   - seed: the registry rows for the pack's agents (run once at boot).
# (The typed capability vocabulary is tracked separately — see lex-ev-fleet#16.)

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-agent/src/server" as srv

import "./federation" as fed

# A persona: a set of agent ids that share one AgentDef builder. `build` is pure
# — (db, agent_id) -> AgentDef — closing over the pack's configuration.
type Persona = { ids :: List[Str], build :: (Db, Str) -> srv.AgentDef }

# A domain pack: a named bundle the core mounts. `seed` populates the registry
# rows for the pack's agents.
type DomainPack = { name :: Str, personas :: List[Persona], seed :: (Db) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] }

# Mount every persona of a pack onto the router via the federation core. The
# core never inspects the pack's domain — it only iterates personas and ids and
# delegates each agent to `fed.mount_agent`. Adding a new domain is a new
# DomainPack value passed here; no edit to this function is required.
fn mount_pack(r :: router.Router, db :: Db, pack :: DomainPack, cfg :: fed.FederationConfig) -> router.Router {
  list.fold(pack.personas, r, fn (acc :: router.Router, p :: Persona) -> router.Router {
    list.fold(p.ids, acc, fn (acc2 :: router.Router, id :: Str) -> router.Router {
      fed.mount_agent(acc2, db, p.build(db, id), id, cfg)
    })
  })
}

# Run a pack's registry seed.
fn seed_pack(db :: Db, pack :: DomainPack) -> [sql, fs_write, crypto, random, time] Result[Unit, Str] {
  pack.seed(db)
}

# Total number of agents a pack mounts (sum of persona id counts).
fn agent_count(pack :: DomainPack) -> Int {
  list.fold(pack.personas, 0, fn (acc :: Int, p :: Persona) -> Int {
    acc + list.len(p.ids)
  })
}

# ── Pack info: the agent-domain manifest ──────────────────────────────────────
# The DomainPack counterpart of pos.PackManifest: a structural "here is my
# vocabulary" declaration for an AGENT-persona pack, so consoles can render a
# domain's personas (labels, taglines, starter prompts) from the catalogue
# instead of hand-authoring per-kind tables. Additive — DomainPack itself is
# unchanged, and a pack that publishes no PackInfo still mounts fine; its
# personas just render with generic labels downstream.
# One persona kind as a console should present it. `kind` matches the agent
# kind the pack's registry seed writes (and the deployment's role provisioning
# uses); `suggested_prompts` are starter messages a console may offer — the
# persona must handle them, so they live with the pack, not the frontend.
type PersonaInfo = { kind :: Str, title :: Str, tagline :: Str, suggested_prompts :: List[Str] }

# The whole agent-domain, catalogue-ready. `name` matches DomainPack.name.
type PackInfo = { name :: Str, title :: Str, tagline :: Str, personas :: List[PersonaInfo] }

fn persona_info_json(p :: PersonaInfo) -> jv.Json {
  JObj([("kind", JStr(p.kind)), ("title", JStr(p.title)), ("tagline", JStr(p.tagline)), ("suggested_prompts", JList(list.map(p.suggested_prompts, fn (s :: Str) -> jv.Json {
    JStr(s)
  })))])
}

fn info_json(i :: PackInfo) -> jv.Json {
  JObj([("name", JStr(i.name)), ("title", JStr(i.title)), ("tagline", JStr(i.tagline)), ("personas", JList(list.map(i.personas, persona_info_json)))])
}

fn infos_json(is :: List[PackInfo]) -> jv.Json {
  JList(list.map(is, info_json))
}

