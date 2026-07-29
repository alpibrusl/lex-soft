# API co-validation: lex-ctl as a second consumer (#106, task 1)

Counterpart to lex-loom's Operate-loop v1 epic
([lex-loom#118](https://github.com/alpibrusl/lex-loom/issues/118)) and its
kernel-extraction task
([lex-loom#126](https://github.com/alpibrusl/lex-loom/issues/126)).
lex-loom built [lex-ctl](https://github.com/alpibrusl/lex-ctl) — the
controller kernel (`contract` / `verify` / `tier` / `stability` /
`incident`) — and is the API's first, driving consumer. Before that API
freezes, soft is meant to co-validate it as a **second, unrelated**
consumer: the one whose domain shares nothing with loom's, and whose
job is to catch any loom vocabulary that snuck into the "mechanism, not
policy" boundary.

This is that co-validation. It is a **paper exercise** — the first
checklist item on
[soft#106](https://github.com/alpibrusl/lex-soft/issues/106), scoped
explicitly to "sketch one pack action... confirm it type-checks... no
implementation." The sketch lives at
[`examples/ctl-sketch/charge_remediation.lex`](../../examples/ctl-sketch/charge_remediation.lex)
and passes `lex check --strict` + `lex fmt --check` on its own — every
function is pure with an inline `examples{}` block, so the type-checker
run *is* the test, per this toolchain's own idiom (no `tests/`
boilerplate needed, same as `examples/agents/` and `pack-template/`
being excluded from the test suite as illustrative-only).

## The scenario

A charge-management pack agent's remediation action: a charging
session's power draw has stalled, so the agent restarts the session on
its charger. The predicted effect: real power draw resumes above a
floor within a deadline. Structurally identical in shape to loom's own
worked example (restart a server, predict `p99_ms` recovers) — chosen
deliberately so the only thing that changes between consumers is the
domain vocabulary, which is exactly what this exercise needs to isolate.

| lex-ctl concept | loom's instance | soft's instance (this sketch) |
|---|---|---|
| `ActionClass` | `restart` a server process | `restart_session` on a charger |
| `subsystem` | a service name | a charger id |
| `Predicate` | `p99_ms` below a threshold | `charger_power_kw_milli` above a floor |
| `on_falsify` | `Rollback` | `Handoff` (no undo for a physical restart) |
| clock unit | loom's `idx` reused as `_ms` (no wall clock yet) | soft's real `std.time.now_ms()` |

## Findings

**The five kernel modules compose cleanly for a domain with nothing in
common with loom's.** No sprints, no iterations, no build/QA/digest —
the same import set loom's `effects.lex`/`actuation.lex` already use
together, driving a charger instead of a server, with zero changes to
lex-ctl itself.

**Real milliseconds work directly — a stronger signal than loom's own
usage.** loom has no wall-clock scheduler yet, so it repurposes its
between-iteration `idx` counter as the kernel's `deadline_ms` /
`held_until_ms` fields (see lex-loom's `operate-loop.md`). soft already
calls `std.time.now_ms()` in several modules (`device_http.lex`,
`dsr.lex`, `federation.lex`); this sketch's `verdict_after_restart`
takes `now_ms` as a genuine wall-clock value with no substitution. That
loom — the API's own author — needed a clock workaround while soft
doesn't is good evidence the `_ms` fields are actually milliseconds in
the API's contract, not an implicit "loom's clock" leak.

**The bare-constructor collision discipline generalizes.** lex-ctl#2
fixed a real bug: `contract.OnFalsify.Escalate` collided with
`tier.Tier.Escalate` the moment both were imported into the same file
(Lex resolves sum-type constructors in a flat namespace across
everything visible in a file). loom's `actuation.lex` avoids
reintroducing this by wrapping rather than redeclaring
(`type Decision = Cleared(ktier.Tier) | Blocked(Str)`). This sketch's
`decide` hits the identical shape — a decision that needs to carry
`ktier.Tier` plus a structural-block case — and applies the same
wrapping discipline. A second, independent consumer needing the exact
same workaround is a good sign the fix (renaming to `Handoff`) was the
right one, not evidence a second fix is owed here.

**Nothing here required a change to lex-ctl.** No new field, no new
module, no widened effect signature.

## Conclusion

No changes requested to the kernel API from this second consumer. This
checklist item is unblocked and complete;
[lex-loom#126](https://github.com/alpibrusl/lex-loom/issues/126) can
treat soft's co-validation as satisfied for the current API shape.

## Explicitly out of scope here (soft#106's remaining tasks)

This sketch stops at naming the seams; none of the following are
attempted:

- `mount_ctl(router, db, …)` — the real host-opt-in module wiring the
  kernel verifier to soft's scheduler (`lex-jobs`) and outbox.
- Routing `Propose`/`Escalate` outcomes through `escalation` /
  `human_gateway` — the sketch's `on_falsify: Handoff` names this seam
  but doesn't call into it.
- `verdict` ↔ contract-disposition interplay — a falsified effect
  contract as first-class evidence in settlement verdicts.

Each is its own task on #106 and depends on real backend wiring this
paper exercise deliberately has none of.
