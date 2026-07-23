# Building a domain agent

A **domain pack** ([DOMAIN-PACKS.md](DOMAIN-PACKS.md)) is the bundle a vertical
mounts on the core. This document zooms into one piece of that bundle: the
**agent** — the thing that receives an A2A `tasks/send`, does work, and leaves an
auditable trail. Three kinds, cheapest first:

| You have… | Use | You get |
|---|---|---|
| An LLM persona (prompt + domain tools) | the **runner** kit | trail + trace + platform tools, no glue |
| Deterministic logic (a gateway, a bridge) | a **plain handler** | full control, you record what matters |
| A third-party A2A endpoint you don't own | the **external adapter** | audited interactions without touching their code |

Every agent is a `srv.AgentDef` mounted with
`fed.mount_agent(r, db, def, id, cfg)`. The core never inspects the domain — it
routes, authenticates (`cfg.require_token` / HS256), gates on the
relationship graph (`x-from-agent` × `x-capability`), and — since #224 — records
the routed interaction to the trail if the handler didn't. So the *only* thing
you write is the `AgentDef`.

## 1. LLM agent — the runner kit

An LLM-backed agent is ~15 lines: an `AgentConfig` and a `card`. The runner
supplies the handler.

```lex
import "lex-soft/src/runner" as runner
import "lex-agent/src/server" as srv
import "lex-agent/src/agent_card" as card
import "lex-spec/capability" as cap
import "lex-schema/schema" as sch

fn quote_capability() -> cap.Capability {
  cap.inbound("logistics.quote.handle", "Quote a shipment lane.",
    { title: "Quote", description: "quote a lane", fields: [sch.required_str("text", [])] })
}

fn make_agent_def(db :: Db, id :: Str, base_url :: Str, backend_url :: Str,
                  provider :: Str, provider_url :: Str, provider_key :: Str, model :: Str) -> srv.AgentDef {
  let cfg := { id: id, kind: "quoter", system_prompt: quote_prompt(),
    model_name: model, provider_name: provider, provider_url: provider_url, provider_key: provider_key,
    backends: [{ key: "quotes", url: backend_url }],   # opaque key→url pairs, threaded to your tools
    intent_roles: [],                                  # your find_peers vocabulary (empty = match any)
    tools: [] }                                        # domain tools; see below
  let c := card.make(id, "Lane quoting agent", "0.1.0", base_url, [quote_capability()])
  srv.make_agent_def(c, [{ capability: quote_capability(), handle: runner.make_handler(db, cfg) }])
}
```

Drop it into a `Persona` and the pack mounts it:

```lex
let quoter :: pack.Persona := { ids: ["quote-01"], build: fn (d :: Db, id :: Str) -> srv.AgentDef {
  make_agent_def(d, id, agent_base_url(port, id), quotes_url, provider, provider_url, provider_key, model)
} }
```

**What the runner does per turn** (`runner.make_handler`, `runner.lex:335`):

1. loads agent state + the *conversation's* recent history (keyed on the A2A
   `contextId` — turns from other conversations never leak in),
2. builds the system prompt (persona + state + durable memory),
3. runs the lex-llm tool loop in a subprocess, with two platform tools injected
   into **every** agent — `find_peers(intent)` (registry × relationship graph)
   and `send_message(to, topic, payload)` (A2A `tasks/send`),
4. writes trace events (`received` → `llm_start` → `tool_call*` → `llm_done`),
5. records the run to the settlement trail (`settlement.record_run`) and returns
   the reply plus a **`trail_id` artifact** the requester can verify and pay
   against.

**Domain tools** are `[net, io, proc]` closures over plain strings that speak
HTTP to *your* backends (never SQL). They're built in `make_agent_def` (card
metadata) **and** rebuilt per turn in your host's `llm_call.lex`
`tools_for_kind` — both call sites must agree on the signature (see the "two
call sites" rule in [DOMAIN-PACKS.md](DOMAIN-PACKS.md)).

### Local vs remote backend

`runner.make_handler(db, cfg)` reads state and peers straight from the local
`Db`. For a distributed deployment where state and discovery live behind the
platform HTTP API, use `runner.make_handler_remote(client, local_db, cfg)`
(`runner.lex:348`) instead — same handler, but state/peers go through
`platform/client` and outbound messages are durably queued in `local_db`
(`outbox.flush_loop`). Trace is always local. Boot order:

```
outbox.init(local_db)
conc.spawn(fn () { outbox.flush_loop(local_db, platform_url, 500) })
pclient.register(client, id, kind, name, inbox_url, capabilities)
# then mount the handler as usual
```

## 2. Plain handler — deterministic agents

When there's no model, write the handler yourself: a
`(msg.Message) -> HandlerOutcome` closure. The human-approval gateway
(`human_gateway.lex`) is the reference — it's a normal AgentDef whose "runtime"
is a person. The shape:

```lex
fn make_handler(db :: Db) -> (msg.Message) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] srv.HandlerOutcome {
  fn (m :: msg.Message) -> [ ... ] srv.HandlerOutcome {
    # ... do the work, record what matters to the trail ...
    { next_state: tk.TSCompleted, reply: Some(msg.agent_text(reply)), artifacts: [] }
  }
}
```

Return `tk.TSInputRequired` (with an escalation artifact) when you need a human
in the loop; `tk.TSFailed` on error. If your handler doesn't record a trail
itself, the node records the interaction for you (#224) — so a plain agent is
audited by default.

## 3. External agent — the audit adapter

A third party runs their own A2A agent (Google-A2A, LangGraph, an OpenAI-SDK
app). You can register it as a **registry-only** peer
(`fed.register_peer_json`, `kind: "external"`) — that makes it discoverable and
routable, but callers reach *their* inbox directly, so the exchange is invisible
to `/audit`. That's the external-inbox blind spot noted in #224.

The **external adapter** (`external_agent.lex`) closes it without asking the
third party to change anything. You mount a normal AgentDef on the platform
whose handler **proxy-records**: record `received` → forward the task to their
inbox (synchronous A2A, `Authorization: Bearer` when you supply a token) →
record the interaction to the trail → return their reply.

```lex
import "lex-soft/src/external_agent" as ext

let ec := { id: "acme-quoter", inbox_url: "https://acme.example/a2a",
  skill: "quote", forward_token: connection_token,
  description: "Acme's external quoting agent", version: "0.1.0",
  card_url: agent_base_url(port, "acme-quoter") }

let r2 := fed.mount_agent(r, db, ext.make_agent_def(db, ec), ec.id, cfg)
```

Now `acme-quoter` is a first-class platform agent: it appears in discovery, is
capability-gated, is metered, and every call shows up in
`/audit/interactions` — while Acme's endpoint runs untouched. Because the
adapter embeds a `trail_id` artifact (like the runner), the node-side recorder
sees it and doesn't double-count.

**Onboarding in "adapter mode"** is therefore: take the external endpoint's
`{id, inbox_url, skill}`, build an `ExternalConfig`, and mount it — instead of
registering it registry-only. Use registry-only when you just need routing; use
the adapter when you need the interaction audited.

## The hosted-agent pool

Hosts that can't mount agents at request time **pre-mount a pool** and let
customers claim from it (`pool.lex`). Personas are seeded into a holding tenant
with `reg.register_pooled` (`status = 'pooled'`, invisible to discovery). A
customer with a valid platform credential claims them:

```
POST /pool/claim   { "kind": "truck", "count": 2, "name": "Acme truck" }
  -> { "claimed": 2, "ids": ["pool-truck-01", "pool-truck-02"] }
```

**Tenant-stamping**: claiming re-points the row's `tenant` column to the
caller's org (`reg.claim_pooled`) — the id stays, `tenant` + `status` flip to
the new owner + `active`. The tenant-stamped tool path (the proxy stamps the
org header your backend understands) picks the new org up on the next request,
so a pooled agent becomes the customer's without a redeploy. The pool may run
short: `claimed < count` is normal.

## Checklist for a new agent

1. Pick the kind (LLM → runner; deterministic → plain handler; external →
   adapter).
2. Capability with a namespaced skill id; register its schema
   (`sr.from_capability`) so third parties can discover the wire shape.
3. For LLM agents: add the kind branch to your host's `tools_for_kind`
   (`llm_call.lex`) — same tool signature as `make_agent_def`.
4. Wrap in a `Persona`, add to your `DomainPack`, `mount_pack` in main.lex.
5. Seed registry rows (`pack.seed`); demo values live in seeds, never code.
6. `lex fmt` + `lex check` every file; run the host's test suite.

The rules that bite (two tool call sites, effect-row unification, SQLite ⋂
Postgres SQL, payloads carrying `agent`/`from_agent` for the audit slice) are
shared with packs — see [DOMAIN-PACKS.md](DOMAIN-PACKS.md).
