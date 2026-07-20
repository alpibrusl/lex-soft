# lex-soft

<!--
  EXTERNAL NAME — the public/product name appears in exactly ONE place: the
  tagline line directly below. The repo, package (`lex-soft` in lex.toml),
  imports and module names are the stable technical identity and do not carry a
  marketing name. When a public name is chosen, edit that single line; nothing
  else in this repo needs to change.
-->
**The integration fabric for autonomous B2B agents.** One company's agents
discover, connect to, and coordinate work with another company's agents across
the org boundary — and because every step is provable, they can settle payment
on evidence, not on trust.

`lex-soft` is the domain-agnostic **engine**. It provides *mechanism*, never
policy: identity, the cross-org agent mesh, discovery, trust, audit, metering,
and evidence-gated settlement all live here. What the agents actually *do*
(logistics, charging, cold-chain, construction, energy, …) lives in domain
**packs** built on top — the core never names or depends on any one of them.
Written entirely in [lex-lang](https://github.com/alpibrusl/lex-lang).

## The model

Three things happen across the boundary between two companies:

1. **Register & discover.** Each org publishes its agents and capabilities to a
   federated directory; counterparties find each other by *capability*, not by a
   hardcoded URL or a bespoke EDI integration.
2. **Connect & coordinate.** Agents authenticate, form scoped relationships
   (who may ask whom to do what), and run work agent-to-agent — dispatch,
   custody handoffs, replenishment, approvals, whatever a pack defines.
3. **Prove & settle.** Every action lands on a hash-chained, tamper-evident
   trail. Settlement is **evidence-gated**: money moves only when the trail
   re-verifies that the work was actually done. This is the flagship capability
   — the reason it is safe to let cross-org coordination run autonomously.

Integration and coordination are the category; evidence-gated settlement is the
capability that makes automating it trustworthy.

## Capabilities (mechanism, host-mounted)

Everything is a host-opt-in `mount_*(router, db, …)` module — a host wires in
only what it needs, and supplies its own policy and data. The core ships no
product vocabulary.

| Modules | What it provides |
|---|---|
| `identity`, `partner_auth`, `conn_token` | Signed org/agent identity, partner authentication, scoped connection tokens |
| `mesh`, `a2a`, `registry`, `federation`, `matchmaking`, `schema_registry` | Cross-org agent mesh: register, discover by capability, message over A2A, federate between nodes |
| `relationships`, `arm`, `trust`, `resolver` | Agent relationship management: scoped roles, trust profiles, intent→role resolution (host-supplied vocab) |
| `verdict`, `settlement`, `spend` | Evidence-gated settlement: re-derive proof over the trail, then gate spend on it |
| `audit`, `trace`, `observability` | Tenant-scoped audit API, hash-chained interaction trace, observability |
| `metering` | Usage metering + billing preview against host-supplied plans |
| `notifications`, `escalation`, `human_gateway` | Alerting bus and human-in-the-loop approvals for actions agents can't decide alone |
| `scheduler`, `outbox` | Recurring agent prompts and reliable outbound delivery |
| `pack` | The domain-pack SDK — `mount_pack(...)` adds a vertical without touching the core |
| `dsr` | Data-subject-rights (GDPR) export/erase |
| `device_http` | Signed device ingest for edge readings |
| `pool`, `platform/*`, `a2a_dashboard` | Hosted-agent pool, platform server/inbox/client, and an operator dashboard |

See `src/soft.lex` for the facade re-exporting the common types.

## Domain packs (built on top, not in here)

A **pack** is a self-contained vertical mounted via `mount_pack` — its own
tables, endpoints, capabilities and settlement rules, with zero core changes.
Packs live in their own repos, never in `lex-soft`. Examples that consume this
engine: EV-fleet logistics, charging/roaming, cold-chain custody, intermodal
container custody, agri-food traceability, construction milestones, and energy
flexibility. Each is one product on the same engine — swap the pack, keep the
identity/mesh/trust/settlement machinery underneath.

## Open core

The **mechanism** is public — this repo plus the shared libraries it builds on
([lex-web](https://github.com/alpibrusl/lex-web),
[lex-schema](https://github.com/alpibrusl/lex-schema),
[lex-agent](https://github.com/alpibrusl/lex-agent),
[lex-trail](https://github.com/alpibrusl/lex-trail),
[lex-guard](https://github.com/alpibrusl/lex-guard),
[lex-device-identity](https://github.com/alpibrusl/lex-device-identity),
[lex-crypto](https://github.com/alpibrusl/lex-crypto)). The **products** (the
packs and their consoles) are separate. Nothing product-specific — no URL field,
role vocabulary, plan tier, or integration name — belongs in this repo.

## Build on it

A host process composes the capabilities it wants and mounts its packs:

```lex
# host main.lex (sketch)
let r0 := router.new()
let r1 := identity.mount(r0, db, sign_seed, admin_key)   # signed identity
let r2 := mesh.mount(r1, db)                              # register + discover
let r3 := audit.mount(r2, db, org, version, admin_key)   # tenant-scoped audit
let r4 := metering.mount(r3, db, secret, plan_catalog)   # usage + billing
let r5 := pack.mount_pack(r4, db, my_pack, fed_cfg)      # a vertical
net.serve_fn(r5, port)
```

Signatures vary per module — check each `src/<module>.lex` header. The bundled
`examples/demo.sh` exercises a minimal end-to-end node; `tests/` holds
pure-effect tests per capability (`lex test`).

## Status

The engine is well past scaffold: identity, the cross-org mesh + federation,
ARM/trust, audit, metering, alerting, human-gateway approvals, the pack SDK, and
evidence-gated settlement are all implemented and exercised by real product
packs. It is still evolving — treat module signatures as the source of truth
over prose, and expect the surface to grow. Requires lex-lang 0.10.6+.

## License

EUPL-1.2 (matches the rest of the lex ecosystem).

---

Built under the principles of [Trust Without Comprehension](https://lexlang.org/manifesto).
