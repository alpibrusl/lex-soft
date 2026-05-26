# lex-soft

**Pure-lex agent runtime.** A re-architecture of [`soft`](https://github.com/alpibrusl/soft)
where every layer — agent handlers, mailbox, spec gate, audit trace, A2A
transport — is written in [lex-lang](https://github.com/alpibrusl/lex-lang).
The original `soft` split agent code (lex) from runtime (Rust); lex-soft
moves the runtime into lex too, using [lex-web](https://github.com/alpibrusl/lex-web)
for HTTP, `std.sql` for persistence, and `std.http` for inter-agent calls.

> **v0.1 — scaffold.** Shape is in place; the EV-fleet demo is ported
> from `soft/agents/`. Some stdlib signatures (`std.http`, `std.sql`,
> `lex-schema/json_value`) are pinned to what's in the public README of
> each upstream — if a call doesn't compile against your local toolchain,
> the surface needs a one-line fix, not a redesign. Requires lex-lang
> 0.9.3+, lex-web 0.2+, lex-schema 0.1+.

## What's here

| Path | What |
|------|------|
| `src/action.lex`      | `Action` ADT — `SendA2a`, `NoOp` (`CallMcp`/`LocalLlm`/`CloudLlm` deferred — pure-lex doesn't host those yet) |
| `src/message.lex`     | A2A envelope + lex-schema validator |
| `src/state_store.lex` | SQL-backed per-agent state (JSON column keyed by agent name) |
| `src/trace.lex`       | SQL-backed audit log — one row per `received` / `proposed` / `gate` / `executed` / `error` event |
| `src/gate.lex`        | `Verdict = Allow \| Deny(reason) \| Inconclusive` + `check()` runner |
| `src/a2a.lex`         | HTTP A2A sender (`std.http.post` against the peer URL map) |
| `src/runner.lex`      | `step()` — load state → dispatch handler → run gate → execute action → save state + trace |
| `src/agent.lex`       | `AgentDef` record + `mount(router, agent)` helper for lex-web |
| `src/migrate.lex`     | SQL migrations for `agent_state` + `traces` |
| `src/soft.lex`        | Facade re-exporting common types |
| `examples/ev_fleet/`  | Port of `soft/agents/{vehicle,depot,pv,tms}` + the two `.spec` files as pure predicate functions |
| `tests/`              | Pure-effect tests for gate + runner |

## Architecture (1 page)

```
┌──────────────────────────── lex serve (one process) ─────────────────────────┐
│                                                                              │
│  lex-web Router                                                              │
│  ├─ POST /agents/vehicle/inbox   ─►  runner.step(vehicle_agent, msg)         │
│  ├─ POST /agents/depot/inbox     ─►  runner.step(depot_agent,   msg)         │
│  ├─ POST /agents/pv/inbox        ─►  runner.step(pv_agent,      msg)         │
│  ├─ POST /agents/tms/inbox       ─►  runner.step(tms_agent,     msg)         │
│  ├─ POST /agents/pv/tick         ─►  synthetic Tick message for pv           │
│  └─ GET  /traces                 ─►  audit log readout                       │
│                                                                              │
│      runner.step                                                             │
│      ──────────                                                              │
│      1. state_store.load(db, agent)                ─[sql]                    │
│      2. agent.dispatch(state_json, msg)            (pure handler)            │
│      3. for action in proposed:                                              │
│           gate.check(spec_fns, state, action)      (pure)                    │
│           if Allow:                                                          │
│              a2a.send(peer_url, action.payload)    ─[net]                    │
│              trace.append(db, "executed")          ─[sql]                    │
│           else:                                                              │
│              trace.append(db, "gate.denied")       ─[sql]                    │
│      4. state_store.save(db, agent, new_state)     ─[sql]                    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

The original soft runtime is replaced piece-by-piece:

| soft (Rust)                              | lex-soft (pure lex)                        |
|------------------------------------------|--------------------------------------------|
| `soft-agent::Runner` mailbox loop        | `src/runner.lex` + lex-web request handler |
| `soft-a2a` HTTP server (`tiny_http`)     | lex-web `net.serve_fn`                     |
| `soft-agent::Action` enum                | `src/action.lex` ADT                       |
| `gate::evaluate_gate_compiled`           | `src/gate.lex` + pure predicate functions  |
| `lex_store::Store` (filesystem trace)    | `src/trace.lex` (SQL trace table)          |
| `.spec` parser + `spec_checker` crate    | predicates as ordinary lex `fn`s            |
| `serde_json::Value` agent state          | JSON `Str` column in SQLite                |

## Specs as predicates, not a separate DSL

The original `soft` had a `.spec` mini-DSL parsed by `spec_checker`. In
lex-soft, a spec is just a pure lex function:

```lex
# Original (soft/agents/depot.spec):
spec depot_grid_budget {
  forall s :: { current_kw :: Float, budget_kw :: Float, pv_kw :: Float },
         a :: { power_kw :: Float }:
    s.current_kw + a.power_kw <= s.budget_kw + s.pv_kw
}

# lex-soft (examples/ev_fleet/specs.lex):
fn depot_grid_budget(
  s :: { current_kw :: Float, budget_kw :: Float, pv_kw :: Float },
  a :: { power_kw :: Float },
) -> Bool {
  s.current_kw + a.power_kw <= s.budget_kw + s.pv_kw
}
```

`gate.check` calls these predicate functions over each proposed action's
payload. No parser, no FFI, no extra crate — and you still get `lex spec`
property-checking for free since they're regular lex functions.

## Running the EV fleet demo

```bash
# From examples/ev_fleet/:
lex run --allow-effects io,net,time,sql,fs_write,rand main.lex main

# Send a Dispatch to the vehicle:
curl -X POST http://localhost:8080/agents/vehicle/inbox \
  -H 'content-type: application/json' \
  -d '{"from":"ops","topic":"Dispatch","payload_json":"{}"}'

# Tick the PV agent:
curl -X POST http://localhost:8080/agents/pv/tick

# Read the audit trace:
curl http://localhost:8080/traces
```

## Status

| Capability | Status | Notes |
|---|---|---|
| Agent runtime (dispatch / gate / trace / state) in pure lex | **Scaffold** | EV-fleet end-to-end ported; v1 SQLite backend |
| Spec gate as pure predicate fns | **Scaffold** | Replaces `.spec` DSL + spec-checker crate |
| A2A over HTTP (`std.http` + lex-web) | **Scaffold** | One sub-router per agent |
| `CallMcp` / `LocalLlm` / `CloudLlm` actions | **Deferred** | `soft-runner` provided these; pure-lex needs MCP-over-HTTP first |
| Content-addressed audit graph (`lex-store` parity) | **Deferred** | v1 uses SQL trace; structural-merge audit deferred |
| lex-orm persistence (replace direct `std.sql`) | **Pending repo access** | wire-up planned for v0.2 |
| Tick scheduler (replace `--tick Tick=2s` in soft-runner) | **Deferred** | v1 uses manual `POST /agents/pv/tick`; lifespan-backed background loop coming |

## Why not just port `lex-store` to lex too?

The structural-merge / Operation-log / SigId surface in `lex-store` is
large and load-bearing for the *language* — it deserves its own lex
port rather than being grown inside lex-soft. v1 here uses a flat SQL
trace table; once `lex-store` has a pure-lex implementation, swap
`src/trace.lex` for it.

## License

EUPL-1.2 (matches the rest of the lex ecosystem).

---

Built under the principles of [Trust Without Comprehension](https://alpibru.com/manifesto).
