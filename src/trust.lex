# trust.lex — the trust ladder: named contract presets for relationships.
#
# Four strictness regimes the platform already enforces piecemeal, named and
# stored AS DATA in the relationship's contract_json (never code):
#
#   L0 coordination     — intent-role authz + trail; no money gates
#   L1 internal market  — same-account metered settlement (chargeback) at an
#                         internal price; no token gating between the parties
#   L2 contracted       — connection token, capability-scoped contract,
#                         spend cap, pay-on-proof settlement
#   L3 spot             — + ARM trust-score gate, tight budget, human
#                         escalation on first interactions
#
# Promotion/demotion is a CONTRACT UPDATE (e.g. ARM-driven L3→L2 after N
# verified interactions) — data, not code. This module is domain-agnostic:
# it names gate combinations; hosts decide which edges get which level.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

type TrustPreset = { level :: Str, name :: Str, description :: Str, requires_conn_token :: Bool, spend_gate :: Bool, arm_gate :: Bool, escalate_first :: Bool, settlement :: Str }

fn presets() -> List[TrustPreset] {
  [{ level: "L0", name: "coordination", description: "intent-role authorization and trail only; no money gates", requires_conn_token: false, spend_gate: false, arm_gate: false, escalate_first: false, settlement: "none" }, { level: "L1", name: "internal market", description: "same-account metered settlement (chargeback) at an internal price", requires_conn_token: false, spend_gate: false, arm_gate: false, escalate_first: false, settlement: "chargeback" }, { level: "L2", name: "contracted", description: "connection token, capability-scoped contract, spend cap, pay-on-proof", requires_conn_token: true, spend_gate: true, arm_gate: false, escalate_first: false, settlement: "pay_on_proof" }, { level: "L3", name: "spot", description: "ARM trust-score gate, tight budget, human escalation on first interactions", requires_conn_token: true, spend_gate: true, arm_gate: true, escalate_first: true, settlement: "pay_on_proof" }]
}

fn preset(level :: Str) -> Option[TrustPreset] {
  list.fold(presets(), None, fn (acc :: Option[TrustPreset], p :: TrustPreset) -> Option[TrustPreset] {
    match acc {
      Some(x) => Some(x),
      None => if p.level == level {
        Some(p)
      } else {
        None
      },
    }
  })
}

fn is_valid_level(level :: Str) -> Bool {
  match preset(level) {
    Some(_) => true,
    None => false,
  }
}

# Tenancy picks the default: agents of the same account coordinate (L0);
# cross-account edges start contracted (L2). L1/L3 are explicit choices.
fn default_level(same_account :: Bool) -> Str {
  if same_account {
    "L0"
  } else {
    "L2"
  }
}

# The stored form: a contract carries {"trust_level": "L2", ...}. Absent or
# unknown reads as L0 — the weakest gates, matching pre-preset contracts.
fn level_of(contract_json :: Str) -> Str {
  match jv.parse(contract_json) {
    Err(_) => "L0",
    Ok(j) => match jv.get_field(j, "trust_level") {
      Some(JStr(v)) => if is_valid_level(v) {
        v
      } else {
        "L0"
      },
      _ => "L0",
    },
  }
}

# Merge a level into an existing contract (idempotent; invalid level = no-op).
fn with_level(contract_json :: Str, level :: Str) -> Str {
  if not is_valid_level(level) {
    contract_json
  } else {
    match jv.parse(contract_json) {
      Err(_) => jv.stringify(JObj([("trust_level", JStr(level))])),
      Ok(JObj(fields)) => {
        let kept := list.filter(fields, fn (f :: (Str, jv.Json)) -> Bool {
          match f {
            (k, _) => k != "trust_level",
          }
        })
        jv.stringify(JObj(list.concat(kept, [("trust_level", JStr(level))])))
      },
      Ok(_) => jv.stringify(JObj([("trust_level", JStr(level))])),
    }
  }
}

# Contract skeleton for a fresh edge at a level. L1 carries the internal
# price the chargeback settles at; L2/L3 carry a spend cap. Values are
# placeholders the host overrides — the SHAPE is the preset.
fn contract_skeleton(level :: Str) -> Str {
  match preset(level) {
    None => "{}",
    Some(p) => {
      let base := [("trust_level", JStr(p.level)), ("settlement", JStr(p.settlement)), ("requires_conn_token", JBool(p.requires_conn_token)), ("arm_gate", JBool(p.arm_gate)), ("escalate_first", JBool(p.escalate_first))]
      let extra := if p.level == "L1" {
        [("internal_price", JFloat(0.0)), ("price_unit", JStr(""))]
      } else {
        if p.spend_gate {
          [("spend_cap", JInt(0))]
        } else {
          []
        }
      }
      jv.stringify(JObj(list.concat(base, extra)))
    },
  }
}

