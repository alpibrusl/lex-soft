# src/verdict.lex — domain-agnostic re-derived verdict contract (#20).
#
# lex-games proves the pattern: a run's trail is a *submission*, and the referee
# RE-DERIVES the verdict instead of trusting a reported score — "authority is
# re-derived, not trusted." This promotes that referee shape into a service the
# platform offers for any domain: given a settlement trail (#19) + the
# capability's spec, return a verdict {intact, linked, legal, score, reason}.
#
#   intact — every event's content hash recomputes (tamper-evident)
#   linked — the chain is unbroken (each event's parent is the next event's id)
#   legal  — the capability's lex-spec precondition holds over the recorded
#            outcome (parameterized by a DOMAIN SPEC, not domain code)
#   verified = intact ∧ linked ∧ legal
#
# Ordering/DQ reuses the shared lex-games arena rule (rank.key) so verified rows
# sort by score and disqualified ones sink — one source of truth, no drift.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-trail/event" as ev

import "lex-trail/log" as tlog

import "lex-trail/replay" as replay

import "lex-trail/export" as txport

import "lex-trail/kinds" as kinds

import "lex-spec/spec" as sp

import "lex-spec/eval" as speval

import "lex-games/src/arena/rank" as rank

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "std.str" as str

import "./settlement" as settlement

# `spec_applied` distinguishes "the legality spec passed" from "no legality spec
# was checked" — so a consumer can never mistake integrity-only for a full
# verdict. The /verify endpoint fails CLOSED when money is gated and no spec is
# registered (H-1); `verify` itself stays the mechanism (internal callers may
# legitimately pass None for an integrity-only re-derivation).
type Verdict = { intact :: Bool, linked :: Bool, legal :: Bool, verified :: Bool, spec_applied :: Bool, score :: Int, reason :: Str }

# ---- JSON → SpecValue (a recorded outcome becomes spec bindings) ----
fn to_specvalue(j :: jv.Json) -> sp.SpecValue {
  match j {
    JNull => VNull,
    JBool(b) => VBool(b),
    JInt(n) => VInt(n),
    JFloat(f) => VFloat(f),
    JStr(s) => VStr(s),
    JList(xs) => VList(list.map(xs, fn (x :: jv.Json) -> sp.SpecValue {
      to_specvalue(x)
    })),
    JObj(fields) => VRecord({ name: "outcome", fields: list.map(fields, fn (kv :: (Str, jv.Json)) -> (Str, sp.SpecValue) {
      match kv {
        (k, v) => (k, to_specvalue(v)),
      }
    }) }),
  }
}

# ---- chain integrity ----
# `linked` holds when, in the tip→root chain returned by walk_chain, each event's
# parent equals the next event's id (an unbroken hash chain).
fn linked_go(events :: List[ev.Event]) -> Bool {
  match list.head(events) {
    None => true,
    Some(h) => match list.head(list.tail(events)) {
      None => true,
      Some(next) => match h.parent {
        Some(pid) => if pid == next.id {
          linked_go(list.tail(events))
        } else {
          false
        },
        None => false,
      },
    },
  }
}

fn linked(events :: List[ev.Event]) -> Bool {
  if list.is_empty(events) {
    false
  } else {
    linked_go(events)
  }
}

# ---- recorded outcome ----
fn find_kind(events :: List[ev.Event], k :: Str) -> Option[ev.Event] {
  list.fold(events, None, fn (acc :: Option[ev.Event], e :: ev.Event) -> Option[ev.Event] {
    match acc {
      Some(_) => acc,
      None => if e.kind == k {
        Some(e)
      } else {
        None
      },
    }
  })
}

# The outcome bound for the legal check is the completed event's payload.
fn outcome_of(events :: List[ev.Event]) -> sp.SpecValue {
  match find_kind(events, kinds.cap_completed()) {
    None => VNull,
    Some(e) => match jv.parse(e.payload_json) {
      Ok(j) => to_specvalue(j),
      Err(_) => VNull,
    },
  }
}

# ---- legality (parameterized by a domain spec) ----
fn legal(spec :: Option[sp.Spec], binding :: Str, outcome :: sp.SpecValue) -> Bool {
  match spec {
    None => true,
    Some(s) => match speval.eval(s, [(binding, outcome)]) {
      Allow => true,
      _ => false,
    },
  }
}

fn reason_of(i :: Bool, l :: Bool, lg :: Bool) -> Str {
  if not i {
    "tampered: an event's content hash does not recompute"
  } else {
    if not l {
      "broken chain: a parent link is missing or wrong"
    } else {
      if not lg {
        "illegal: the capability spec denied the recorded outcome"
      } else {
        "verified"
      }
    }
  }
}

# Re-derive a verdict over a settlement trail. `spec` is the capability's
# precondition (domain data); `binding` names the record the predicate quantifies
# over (e.g. "outcome").
fn verify(log :: tlog.Log, trail_id :: Str, spec :: Option[sp.Spec], binding :: Str) -> [sql] Verdict {
  let events := replay.walk_chain(log, trail_id)
  let i := if list.is_empty(events) {
    false
  } else {
    txport.all_valid(events)
  }
  let l := linked(events)
  let lg := legal(spec, binding, outcome_of(events))
  let v := i and l and lg
  let sc := if v {
    1
  } else {
    0
  }
  let applied := match spec {
    Some(_) => true,
    None => false,
  }
  { intact: i, linked: l, legal: lg, verified: v, spec_applied: applied, score: sc, reason: reason_of(i, l, lg) }
}

# Shared arena ordering key (verified by score; DQ sinks) — see lex-games rank.
fn rank_key(v :: Verdict) -> Int {
  rank.key(v.verified, v.score)
}

fn verdict_json(v :: Verdict) -> Str {
  jv.stringify(JObj([("intact", JBool(v.intact)), ("linked", JBool(v.linked)), ("legal", JBool(v.legal)), ("verified", JBool(v.verified)), ("spec_applied", JBool(v.spec_applied)), ("score", JInt(v.score)), ("reason", JStr(v.reason))]))
}

# ── /verify endpoint ──────────────────────────────────────────────────────────
# A capability's legality spec, supplied by the host (a domain pack). `binding`
# is the record name the predicate quantifies over (e.g. "outcome").
type CapSpec = { capability_id :: Str, spec :: sp.Spec, binding :: Str }

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn find_spec(specs :: List[CapSpec], cid :: Str) -> Option[CapSpec] {
  list.fold(specs, None, fn (acc :: Option[CapSpec], cs :: CapSpec) -> Option[CapSpec] {
    match acc {
      Some(_) => acc,
      None => if cs.capability_id == cid {
        Some(cs)
      } else {
        None
      },
    }
  })
}

# Build a fail-closed verdict from an integrity-only re-derivation: report the
# real intact/linked, but `verified:false` because no legality spec was applied.
fn no_spec_verdict(base :: Verdict, cid :: Str) -> Verdict {
  { intact: base.intact, linked: base.linked, legal: false, verified: false, spec_applied: false, score: 0, reason: str.concat("no legality spec registered for capability ", cid) }
}

# Mount POST /verify — body `{trail_id, capability_id}` → re-derived verdict.
# FAILS CLOSED (H-1): when a capability_id is given but no spec is registered for
# it, the verdict is `verified:false` (integrity may still be reported), never a
# silent integrity-only pass. `capability_id` is required unless the caller
# explicitly asks for integrity-only with `{"mode":"integrity_only"}`.
fn mount_verify(r :: router.Router, db :: Db, specs :: List[CapSpec]) -> router.Router {
  router.route_effectful(r, "POST", "/verify", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let trail_id := jstr(j, "trail_id")
        let cid := jstr(j, "capability_id")
        let mode := jstr(j, "mode")
        if str.is_empty(trail_id) {
          resp.bad_request("{\"error\":\"trail_id is required\"}")
        } else {
          if str.is_empty(cid) and mode != "integrity_only" {
            resp.bad_request("{\"error\":\"capability_id is required (or set mode=integrity_only to check chain integrity without a legality spec)\"}")
          } else {
            let log := settlement.trail_on(db)
            if mode == "integrity_only" {
              resp.json(verdict_json(verify(log, trail_id, None, "outcome")))
            } else {
              match find_spec(specs, cid) {
                Some(cs) => resp.json(verdict_json(verify(log, trail_id, Some(cs.spec), cs.binding))),
                None => resp.json(verdict_json(no_spec_verdict(verify(log, trail_id, None, "outcome"), cid))),
              }
            }
          }
        }
      },
    }
  })
}

