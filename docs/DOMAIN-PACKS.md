# Building a domain pack

The core is mechanism, never policy: a **domain pack** is everything a
vertical adds — personas, capability schemas, tools, seeds — mounted on an
unchanged core. The logistics pack (trucks, dispatch, trailers, custody,
relay, CO2) shipped this way with zero core changes; this document turns
that experience into the recipe.

## The pack contract

A pack is a `pack.DomainPack` value in the HOST program (your product's
main.lex):

```lex
let my_pack :: pack.DomainPack := { name: "energy", personas: [
  { ids: ["site-ems-01"], build: fn (d :: Db, id :: Str) -> srv.AgentDef {
    ems_agent.make_agent_def(d, id, agent_base_url(port, id), ems_url, …)
  } },
] }
…
let __seed := pack.seed_pack(db, my_pack)        # registry rows
let r2 := pack.mount_pack(r, db, my_pack, cfg)   # A2A endpoints
```

Each persona module supplies four things:

1. **A capability** — `cap.Capability` with a namespaced skill id
   (`energy.ems.handle`). Register its schema with
   `sr.from_capability("energy.ems.handle", "1.0.0", ems_capability())` so
   third parties can discover the wire shape.
2. **Tools** — `make_tools(backend_url, tenant, …) -> List[t.Tool]`.
   Tools are `[net, io, proc]` closures over plain strings: they speak HTTP
   to YOUR domain services (the "backends"), never SQL. Tenant scoping is a
   header your backend understands (the host's proxy can stamp it).
3. **A system prompt** — the persona's playbook. State each inbound message
   type and the exact tool sequence; forbid invented facts ("use
   get_fleet_status for your ACTUAL fleet").
4. **`make_agent_def`** — assembles AgentConfig: `backends` is a list of
   opaque `{key, url}` pairs the core serializes verbatim; `intent_roles`
   is YOUR vocabulary (`resolver.IntentRoles` list — empty means find_peers
   matches any peer).

## The rules that bite (learned the hard way)

- **Two tool call sites.** Tools are built in `make_agent_def` (card
  metadata) AND rebuilt per turn in the host's `llm_call.lex`
  `tools_for_kind`. Changing a `make_tools` signature without updating BOTH
  kills every scheduled turn with `arity_mismatch` — and because llm_call
  is one module, it kills EVERY persona's turns, not just yours.
- **Effect rows unify by equality.** A new effect in one tool widens the
  whole chain. Tool execute is pinned `[net, io, proc]` — reach state via
  HTTP endpoints you mount, never directly.
- **Demo values are seed data, never code defaults.** Sites, tariffs,
  fleets, prices live in seed scripts and compose env. Product POLICY
  (e.g. your price catalog) lives in your main.lex; core takes it as data.
- **SQL must run on SQLite AND Postgres**: no reserved words unquoted
  (`window`!), qualify upsert counters (`tbl.count + 1`), BIGINT not
  INTEGER for parameterized ints, uuid params as `($1 || '')::uuid`.
- **Long-running loops die on the cumulative step budget** (lex-lang#721):
  every in-container sidecar needs a shell `keepalive` wrapper, and big
  JSON payloads (route shapes) need compact variants for agent turns.
- **Payloads carry `agent`/`from_agent`** — the audit slice scopes by
  those keys; events missing them are invisible to their own tenant.
- **New chained records**: parent trail events for per-entity chains
  (custody pattern), Ed25519-sign the content-addressed event id, verify
  before admitting external signatures.

## Checklist for a new pack

1. Copy `pack-template/persona.lex`; rename capability + tools.
2. Add the kind branch to your host's `tools_for_kind` (llm_call.lex).
3. Wire the DomainPack in main.lex; counts/URLs from env.
4. Seed script: tenant, backend fixtures, mesh registrations,
   relationships, schedules — all values there.
5. Deterministic probe (tool.execute in-container) before any LLM demo.
6. `lex fmt` + `lex check` every file; run the host's test suite.
