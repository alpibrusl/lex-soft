# src/spend.lex — priced, capped tasks: budget tokens + spend gate (#21).
#
# lex-guard already has the spend machinery (Ed25519 budget tokens → a policy,
# a stateless+stateful cap gate, x402/AP2 settlement). This wires it into the
# platform: a task can carry a budget token; before a priced action the agent
# authorizes the spend through the gate, settles within the token's cap, and the
# spend attestation (intent → outcome | denied) is written into the SAME task
# trail as #19 — so it is part of the verifiable, re-derivable record (#20).
#
# authority is gated, not trusted: an over-cap spend is DENIED and never charged.

import "std.str" as str

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-guard/src/models" as gm

import "lex-guard/src/gate" as gate

import "lex-guard/src/token" as gtoken

import "lex-guard/src/executor" as gexec

import "lex-guard/src/release" as grel

# Build a SpendIntent for a priced action.
fn intent(merchant :: Str, amount :: Int, currency :: Str, category :: Str, memo :: Str) -> gm.SpendIntent {
  { merchant: merchant, amount: amount, currency: currency, category: category, memo: memo }
}

# The dev/test settlement rail (x402 mock). Swap a real x402/AP2 executor in at
# the call site for production; the gate + trail contract is identical.
fn mock_exec(i :: gm.SpendIntent) -> [net] Result[Str, Str] {
  gexec.mock(i)
}

# Authorize + settle a priced spend against a budget token, recording the spend
# attestation into `log` (the task's settlement trail). The token is
# Ed25519-verified to a policy; `gate.spend` enforces the caps — an over-cap
# intent is denied (spend.denied, NOT charged); within cap it settles via `exec`
# and records spend.outcome. Returns the gate's SpendOutcome.
fn authorize_spend(log :: tlog.Log, token_pub_b64 :: Str, token_raw :: Str, i :: gm.SpendIntent, exec :: (gm.SpendIntent) -> [net] Result[Str, Str]) -> [sql, time, net] Result[gm.SpendOutcome, Str] {
  match gtoken.verify(token_pub_b64, token_raw) {
    Err(e) => Err(str.concat("invalid budget token: ", e)),
    Ok(bt) => gate.spend(bt.policy, log, exec, i),
  }
}

# Convenience: authorize through the mock rail.
fn authorize_spend_mock(log :: tlog.Log, token_pub_b64 :: Str, token_raw :: Str, i :: gm.SpendIntent) -> [sql, time, net] Result[gm.SpendOutcome, Str] {
  authorize_spend(log, token_pub_b64, token_raw, i, mock_exec)
}

# Like `authorize_spend`, but ALSO pays only against PROOF. `evidence` names a
# fulfilment trail + a domain spec (lex-guard/release): before the budget check
# the gate re-derives that the outcome is intact, chained, and legal, and blocks
# the spend (spend.blocked, never charged) if it isn't. `None` is identical to
# `authorize_spend`. This is "pay against proven outcome" from the shared gate,
# so a pack no longer has to hand-roll verify-then-authorize.
fn authorize_spend_gated(log :: tlog.Log, token_pub_b64 :: Str, token_raw :: Str, i :: gm.SpendIntent, exec :: (gm.SpendIntent) -> [net] Result[Str, Str], evidence :: Option[grel.Evidence]) -> [sql, time, net] Result[gm.SpendOutcome, Str] {
  match gtoken.verify(token_pub_b64, token_raw) {
    Err(e) => Err(str.concat("invalid budget token: ", e)),
    Ok(bt) => gate.spend_gated(bt.policy, log, exec, i, evidence),
  }
}

# Convenience: authorize a proof-gated spend through the mock rail.
fn authorize_spend_gated_mock(log :: tlog.Log, token_pub_b64 :: Str, token_raw :: Str, i :: gm.SpendIntent, evidence :: Option[grel.Evidence]) -> [sql, time, net] Result[gm.SpendOutcome, Str] {
  authorize_spend_gated(log, token_pub_b64, token_raw, i, mock_exec, evidence)
}

# A budget request a task carries as a param: the budget token (raw) + the intent.
type BudgetRequest = { token :: Str, intent :: gm.SpendIntent }

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn jint(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(n)) => n,
    _ => 0,
  }
}

# Extract a budget request from a task param object:
#   { "budget_token": "...", "spend": { merchant, amount, currency, category, memo } }
# Returns None when no budget token is present (the task is unpriced).
fn parse_request(j :: jv.Json) -> Option[BudgetRequest] {
  let tok := jstr(j, "budget_token")
  if str.is_empty(tok) {
    None
  } else {
    let s := match jv.get_field(j, "spend") {
      Some(sp) => sp,
      None => JNull,
    }
    Some({ token: tok, intent: intent(jstr(s, "merchant"), jint(s, "amount"), jstr(s, "currency"), jstr(s, "category"), jstr(s, "memo")) })
  }
}

