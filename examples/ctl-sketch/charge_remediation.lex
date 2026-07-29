# examples/ctl-sketch/charge_remediation.lex — API co-validation, not a
# shipped pack (soft#106 task 1; feeds lex-loom#126's kernel-API freeze).
#
# lex-ctl (github.com/alpibrusl/lex-ctl) is loom's Operate-loop kernel,
# extracted so a SECOND, unrelated consumer can prove the API carries no
# host vocabulary before it freezes. This file is that proof: one pack
# action — a charge-management agent restarting a stalled EV charging
# session — sketched entirely against contract / verify / tier /
# stability / incident. Paper exercise: nothing here calls a real
# backend, mounts a route, or touches SQL. Every function is pure and
# carries its own `examples{}`, so `lex check` is the whole test.
#
# What this proves for #106/#126:
#
#   - The five kernel modules compose for a domain with nothing in
#     common with loom's server-ops vocabulary (no sprints, no
#     iterations, no build/QA/digest) — same imports loom's
#     effects.lex/actuation.lex already use together, now driving a
#     charger restart instead of a service restart.
#   - Real milliseconds work directly. loom has no wall clock yet, so
#     it repurposes its between-iteration `idx` counter as the kernel's
#     `_ms` fields (see lex-loom's operate-loop.md). soft already has
#     `std.time.now_ms()` (device_http.lex, dsr.lex, federation.lex) —
#     `deadline_ms`/`held_until_ms`/`opened_at_ms` are used here as
#     actual milliseconds, no substitution needed. Stronger evidence
#     the API is domain-agnostic than loom's own usage, which needed
#     the idx workaround.
#   - The bare-constructor collision discipline from lex-ctl#2
#     (`OnFalsify.Escalate` vs. `Tier.Escalate`) generalizes: `Decision`
#     below wraps `ktier.Tier` (`Cleared(ktier.Tier)`) instead of
#     redeclaring Auto/Propose/Escalate as its own variants, exactly
#     the pattern loom's actuation.lex uses for the same reason.
#
# Not attempted here (later #106 tasks, not this one): `mount_ctl`
# wiring to soft's scheduler/outbox, routing Propose/Escalate through
# `escalation`/`human_gateway`, or the verdict/contract-disposition
# interplay. `on_falsify: Handoff` below is exactly the seam those
# later tasks would use — this file stops at naming it.

import "lex-ctl/src/contract" as kct

import "lex-ctl/src/verify" as kverify

import "lex-ctl/src/tier" as ktier

import "lex-ctl/src/stability" as kstab

import "lex-ctl/src/incident" as kinc

# ── The action, classified (lex-ctl/tier) ────────────────────────────────────
# Restarting a charger's session is idempotent (retrying is safe — the
# charger just re-negotiates with the vehicle) and its blast radius is a
# single instance (this charger, this session), so it structurally
# ceilings at Auto. Dwell: don't restart the same charger again inside
# 5 minutes of a prior restart.
fn action_class() -> ktier.ActionClass
  examples {
    action_class() => { key: "restart_session", reversibility: Idempotent, blast: Instance, dwell_ms: 300000 }
  }
{
  { key: "restart_session", reversibility: Idempotent, blast: Instance, dwell_ms: 300000 }
}

fn class_ceiling() -> ktier.Tier
  examples {
    class_ceiling() => Auto
  }
{
  ktier.ceiling(action_class())
}

fn promotion_policy() -> ktier.Policy
  examples {
    promotion_policy() => { min_samples: 20, min_hit_rate_pct: 75, breaker_misses: 3 }
  }
{
  { min_samples: 20, min_hit_rate_pct: 75, breaker_misses: 3 }
}

# ── The predicted effect (lex-ctl/contract) ──────────────────────────────────
# Signal: the charger's real-time power draw, in milli-kW (the kernel's
# integer-milli convention — 500 milli = 0.5 kW). A stalled session reads
# near-zero; a successful restart should show real power flowing again.
fn stalled_power_predicate() -> kct.Predicate
  examples {
    stalled_power_predicate() => { signal: "charger_power_kw_milli", cmp: Above, threshold_milli: 500 }
  }
{
  { signal: "charger_power_kw_milli", cmp: Above, threshold_milli: 500 }
}

fn remediation_deadline_ms() -> Int
  examples {
    remediation_deadline_ms() => 120000
  }
{
  120000
}

fn confidence_pct() -> Int
  examples {
    confidence_pct() => 85
  }
{
  85
}

# on_falsify: Handoff, not Rollback — there is no "undo" for a session
# restart, and silently retrying a physical charger fault is how a
# controller becomes the thing it's supposed to be watching. A falsified
# contract hands off to a human (the seam `escalation`/`human_gateway`
# would fill in a real integration).
fn make_contract(action_id :: Str, charger_id :: Str, restarted_at_ms :: Int) -> kct.EffectContract
  examples {
    make_contract("act-1", "charger-07", 1000000) => kct.make("act-1", "restart_session", "charger-07", stalled_power_predicate(), 1120000, 85, Handoff)
  }
{
  kct.make(action_id, action_class().key, charger_id, stalled_power_predicate(), restarted_at_ms + remediation_deadline_ms(), confidence_pct(), Handoff)
}

# ── The verifier's judgement (lex-ctl/verify), on a real schedule ───────────
# `now_ms` here is the scheduler tick's actual wall-clock time (soft has
# `std.time.now_ms()`; a real lex-jobs scheduled job would pass it in).
fn verdict_after_restart(c :: kct.EffectContract, observed_power_milli :: Option[Int], now_ms :: Int, other_actions_on_charger :: Int) -> kverify.Outcome
  examples {
    verdict_after_restart(make_contract("act-1", "charger-07", 0), Some(7200), 60000, 0) => Pending,
    verdict_after_restart(make_contract("act-1", "charger-07", 0), Some(7200), 120000, 0) => Materialised,
    verdict_after_restart(make_contract("act-1", "charger-07", 0), Some(0), 120000, 0) => Falsified,
    verdict_after_restart(make_contract("act-1", "charger-07", 0), Some(7200), 120000, 1) => Ambiguous
  }
{
  kverify.judge(c, observed_power_milli, now_ms, other_actions_on_charger)
}

# ── The measured tier (lex-ctl/tier), never confidence — a fresh class
# starts at Propose no matter how clean the code looks, and only reaches
# Auto once it has earned a real record.
fn tier_for_record(stats :: ktier.ClassStats) -> ktier.Tier
  examples {
    tier_for_record(ktier.empty_stats()) => Propose,
    tier_for_record(ktier.record(ktier.empty_stats(), true)) => Propose
  }
{
  ktier.effective(action_class(), stats, promotion_policy())
}

# ── Structural gate (lex-ctl/stability) — dwell + a depot-wide cap ─────────
# 3 concurrent remediations across the whole depot, independent of how
# many stalled-session incidents happen to be open at once — the same
# reasoning as the kernel's own design note (correlated incidents produce
# correlated actions).
fn global_concurrency_cap() -> Int
  examples {
    global_concurrency_cap() => 3
  }
{
  3
}

fn structurally_clear(charger_id :: Str, locks :: List[kstab.DwellLock], now_ms :: Int, other_in_flight :: Int) -> Bool
  examples {
    structurally_clear("charger-07", [], 0, 0) => true,
    structurally_clear("charger-07", [{ subsystem: "charger-07", held_until_ms: 100000 }], 5000, 0) => false,
    structurally_clear("charger-07", [], 0, 3) => false
  }
{
  kstab.can_act(locks, charger_id, now_ms, other_in_flight, global_concurrency_cap())
}

# ── The whole gate, one call — the actual thing a mount_ctl integration
# would run before executing a restart. Wraps `ktier.Tier` rather than
# redeclaring its variants (see file header): a sibling sum type with its
# own bare Auto/Propose/Escalate would collide with this exact import,
# the same bug lex-ctl#2 fixed and loom's actuation.lex deliberately
# avoided by wrapping.
type Decision = Cleared(ktier.Tier) | Blocked(Str)

fn decide(charger_id :: Str, stats :: ktier.ClassStats, locks :: List[kstab.DwellLock], now_ms :: Int, other_in_flight :: Int) -> Decision
  examples {
    decide("charger-07", ktier.empty_stats(), [], 0, 0) => Cleared(Propose),
    decide("charger-07", ktier.record(ktier.empty_stats(), true), [{ subsystem: "charger-07", held_until_ms: 100000 }], 5000, 0) => Cleared(Propose),
    decide("charger-07", { hits: 20, misses: 0, consecutive_misses: 0 }, [], 0, 0) => Cleared(Auto),
    decide("charger-07", { hits: 20, misses: 0, consecutive_misses: 0 }, [{ subsystem: "charger-07", held_until_ms: 100000 }], 5000, 0) => Blocked("dwell_or_concurrency")
  }
{
  match tier_for_record(stats) {
    Auto => if structurally_clear(charger_id, locks, now_ms, other_in_flight) {
      Cleared(Auto)
    } else {
      Blocked("dwell_or_concurrency")
    },
    Propose => Cleared(Propose),
    Escalate => Cleared(Escalate),
  }
}

# ── The incident (lex-ctl/incident) — the pack agent's working set ─────────
fn evidence_budget_cap_milli() -> Int
  examples {
    evidence_budget_cap_milli() => 2000
  }
{
  2000
}

fn open_stalled_session_incident(id :: Str, opened_at_ms :: Int) -> kinc.Incident
  examples {
    open_stalled_session_incident("inc-1", 0) => { id: "inc-1", opened_at_ms: 0, symptoms: ["power_draw_stalled"], hypotheses: [], evidence: [], budget: { spent_milli: 0, cap_milli: 2000 }, actions: [], pending_effects: [], status: Triage }
  }
{
  { id: id, opened_at_ms: opened_at_ms, symptoms: ["power_draw_stalled"], hypotheses: [], evidence: [], budget: { spent_milli: 0, cap_milli: evidence_budget_cap_milli() }, actions: [], pending_effects: [], status: Triage }
}

# Two candidate causes, posteriors from prior sessions on this connector
# type — a vehicle-side pause resolves itself; a connector fault needs
# the restart this file is about.
fn diagnosed(i :: kinc.Incident) -> kinc.Incident
  examples {
    diagnosed(open_stalled_session_incident("inc-1", 0)) => { id: "inc-1", opened_at_ms: 0, symptoms: ["power_draw_stalled"], hypotheses: [{ cause: "connector_fault", p_pct: 65, evidence_for: ["power_draw_stalled"], evidence_against: [] }, { cause: "vehicle_paused_charging", p_pct: 35, evidence_for: [], evidence_against: [] }], evidence: [], budget: { spent_milli: 0, cap_milli: 2000 }, actions: [], pending_effects: [], status: Triage }
  }
{
  { id: i.id, opened_at_ms: i.opened_at_ms, symptoms: i.symptoms, hypotheses: [{ cause: "connector_fault", p_pct: 65, evidence_for: ["power_draw_stalled"], evidence_against: [] }, { cause: "vehicle_paused_charging", p_pct: 35, evidence_for: [], evidence_against: [] }], evidence: i.evidence, budget: i.budget, actions: i.actions, pending_effects: i.pending_effects, status: i.status }
}

fn confident_enough_to_act(i :: kinc.Incident) -> Bool
  examples {
    confident_enough_to_act(open_stalled_session_incident("inc-1", 0)) => false,
    confident_enough_to_act(diagnosed(open_stalled_session_incident("inc-1", 0))) => false
  }
{
  kinc.confident(i.hypotheses, 80)
}

