# positions.lex — the vocabulary a domain pack is described in.
#
# A coordination flow is a set of parties who each occupy a POSITION. The
# position says what a party does structurally; the domain says what that party
# is called. "Shipper", "client", "applicant" and "buyer" are four names for one
# position — the party that creates the obligation the flow exists to discharge.
#
# The positions here are not invented taxonomy: each one names the party a core
# primitive already serves, which is why this vocabulary lives in the engine and
# not in any product. custody serves the custodian, verdict serves the attestor,
# settlement serves the settler, the audit surface serves the observer. If a
# proposed position has no primitive behind it, it does not belong in this list.
#
# A PATTERN is a reusable flow shape: the set of positions a kind of arrangement
# needs, independent of industry. Milestone-release describes a building
# contract, a research grant and a freelance engagement equally well. A new
# domain is normally a pattern plus a vocabulary, not new code — which is the
# point of naming them.
#
# Both lists are pure data with no I/O, so a host, a console or an onboarding
# agent can read them without opening a database.

import "std.list" as list

import "lex-schema/json_value" as jv

# `primitive` is the core module whose guarantees this position depends on —
# the reason the position is real rather than editorial.
type Position = { id :: Str, title :: Str, summary :: Str, primitive :: Str }

type Pattern = { id :: Str, title :: Str, summary :: Str, positions :: List[Str] }

fn all() -> List[Position] {
  [{ id: "originator", title: "Originator", summary: "Creates the obligation the flow exists to discharge — the order, request, commission or opening that everything downstream answers to.", primitive: "trail" }, { id: "coordinator", title: "Coordinator", summary: "Matches, schedules or routes between the other parties without performing the work or holding the subject.", primitive: "matchmaking" }, { id: "executor", title: "Executor", summary: "Performs the work the obligation calls for, and whose performance is what the evidence is about.", primitive: "arm" }, { id: "custodian", title: "Custodian", summary: "Holds the subject for one stretch of the flow and hands it on. The handoff, signed by both sides, is the record.", primitive: "custody" }, { id: "attestor", title: "Attestor", summary: "Produces or checks the evidence the other parties rely on, without performing the work itself — an inspection, a reading, a document check.", primitive: "verdict" }, { id: "settler", title: "Settler", summary: "Releases value once the evidence is proven, and refuses when it is not.", primitive: "settlement" }, { id: "observer", title: "Observer", summary: "Reads the trail without acting in the flow — an auditor, a regulator, a counterparty performing due diligence.", primitive: "audit" }]
}

# The flow shapes a domain can be assembled from. `positions` lists the
# positions the shape needs; a domain may leave optional ones unfilled.
fn patterns() -> List[Pattern] {
  [{ id: "custody_chain", title: "Custody chain", summary: "Responsibility for a subject passes hand to hand, each handoff countersigned, so any later claim can be attributed to whoever held it at the time.", positions: ["originator", "custodian", "executor", "attestor", "observer"] }, { id: "milestone_release", title: "Milestone release", summary: "An engagement is split into milestones; each one releases value only once its required evidence is on the trail and re-verifies.", positions: ["originator", "executor", "attestor", "settler", "observer"] }, { id: "title_transfer", title: "Title transfer", summary: "An exclusive title moves between holders under sole control — only the current holder can endorse it onward, so it cannot be in two places.", positions: ["originator", "custodian", "attestor", "settler", "observer"] }, { id: "provenance_trace", title: "Provenance trace", summary: "Every unit chains back through its transformations to a declared origin, so a downstream claim about it can be traced to source.", positions: ["executor", "custodian", "attestor", "observer"] }, { id: "dwell_terms", title: "Dwell terms", summary: "A subject is allowed free time at a location, after which a per-period charge accrues, computed from the custody record rather than asserted.", positions: ["custodian", "coordinator", "attestor", "observer"] }, { id: "capacity_tender", title: "Capacity tender", summary: "Offered capacity is tendered, committed, then delivered, with metered evidence closing the loop before value moves.", positions: ["originator", "executor", "attestor", "settler"] }]
}

fn find(id :: Str) -> Option[Position] {
  list.head(list.filter(all(), fn (p :: Position) -> Bool {
    p.id == id
  }))
}

fn find_pattern(id :: Str) -> Option[Pattern] {
  list.head(list.filter(patterns(), fn (p :: Pattern) -> Bool {
    p.id == id
  }))
}

# Whether `id` names a known position — the check a manifest validator runs so a
# pack cannot introduce a private position word by typo.
fn is_position(id :: Str) -> Bool {
  match find(id) {
    None => false,
    Some(_) => true,
  }
}

fn is_pattern(id :: Str) -> Bool {
  match find_pattern(id) {
    None => false,
    Some(_) => true,
  }
}

fn position_json(p :: Position) -> jv.Json {
  JObj([("id", JStr(p.id)), ("title", JStr(p.title)), ("summary", JStr(p.summary)), ("primitive", JStr(p.primitive))])
}

fn pattern_json(p :: Pattern) -> jv.Json {
  JObj([("id", JStr(p.id)), ("title", JStr(p.title)), ("summary", JStr(p.summary)), ("positions", JList(list.map(p.positions, fn (s :: Str) -> jv.Json {
    JStr(s)
  })))])
}

# The whole vocabulary as one document — what a console or an onboarding agent
# fetches once to learn how domains are described here.
fn vocabulary_json() -> jv.Json {
  JObj([("positions", JList(list.map(all(), position_json))), ("patterns", JList(list.map(patterns(), pattern_json)))])
}

