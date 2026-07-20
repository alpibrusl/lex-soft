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

import "std.str" as str

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

# ── Pack manifests ────────────────────────────────────────────────────────────
# A manifest is how a domain declares itself in the vocabulary above: which
# pattern it follows, and what it calls each position. It is what an onboarding
# surface reads instead of hardcoding one industry's role list.
#
# `field` is the payload or column key the party binds to on the wire, so a
# caller can go from "this domain calls the originator a shipper" to the actual
# request field without reading the pack's source.
type PartySlot = { position :: Str, name :: Str, title :: Str, field :: Str, required :: Bool }

# How one party stands to another. Kept to a small shared list rather than
# per-domain words: relationship roles are what peer discovery filters on, so a
# domain inventing its own vocabulary would make its edges invisible to every
# generic query. Each role is the position pairing that produces it.
fn edge_roles() -> List[Str] {
  ["contracted", "dispatch", "custody", "reporting", "attestation", "settlement"]
}

fn is_edge_role(id :: Str) -> Bool {
  not list.is_empty(list.filter(edge_roles(), fn (r :: Str) -> Bool {
    r == id
  }))
}

# A standing relationship between two PARTIES of a domain — "the shipper tenders
# to the carrier" — named by party, not by tenant. It is a TEMPLATE: onboarding
# creates the edge only between agents that actually exist, so an org playing
# one side gets nothing until its counterparty is known. Cross-org edges are
# formed after discovery, not assumed here.
type PartyEdge = { from :: Str, to :: Str, role :: Str, label :: Str }

# `subject` is what the flow is about in this domain's words, and
# `subject_ref_field` the key that identifies one. `custody_ref_field` is
# recorded separately and deliberately: a domain may address its subject by one
# name in its own API while the shared custody chain keys it by another, and a
# manifest that hid that difference would send integrators to the wrong field.
# Empty means the domain has no custody chain.
type PackManifest = { id :: Str, title :: Str, tagline :: Str, pattern :: Str, subject :: Str, subject_ref_field :: Str, custody_ref_field :: Str, parties :: List[PartySlot], relationships :: List[PartyEdge], event_kinds :: List[Str], evidence_kinds :: List[Str], settles :: Bool, route_prefix :: Str }

fn party_json(p :: PartySlot) -> jv.Json {
  JObj([("position", JStr(p.position)), ("name", JStr(p.name)), ("title", JStr(p.title)), ("field", JStr(p.field)), ("required", JBool(p.required))])
}

fn strs_json(xs :: List[Str]) -> jv.Json {
  JList(list.map(xs, fn (s :: Str) -> jv.Json {
    JStr(s)
  }))
}

fn edge_json(e :: PartyEdge) -> jv.Json {
  JObj([("from", JStr(e.from)), ("to", JStr(e.to)), ("role", JStr(e.role)), ("label", JStr(e.label))])
}

fn manifest_json(m :: PackManifest) -> jv.Json {
  JObj([("id", JStr(m.id)), ("title", JStr(m.title)), ("tagline", JStr(m.tagline)), ("pattern", JStr(m.pattern)), ("subject", JStr(m.subject)), ("subject_ref_field", JStr(m.subject_ref_field)), ("custody_ref_field", JStr(m.custody_ref_field)), ("parties", JList(list.map(m.parties, party_json))), ("relationships", JList(list.map(m.relationships, edge_json))), ("event_kinds", strs_json(m.event_kinds)), ("evidence_kinds", strs_json(m.evidence_kinds)), ("settles", JBool(m.settles)), ("route_prefix", JStr(m.route_prefix))])
}

# Each repeated name reported ONCE, not once per occurrence — three slots
# sharing a name is one fault to fix, not three.
fn dupe_party_names(ps :: List[PartySlot]) -> List[Str] {
  list.fold(ps, [], fn (acc :: List[Str], p :: PartySlot) -> List[Str] {
    let repeated := list.len(list.filter(ps, fn (o :: PartySlot) -> Bool {
      o.name == p.name
    })) > 1
    let seen := not list.is_empty(list.filter(acc, fn (n :: Str) -> Bool {
      n == p.name
    }))
    if repeated and not seen {
      list.concat(acc, [p.name])
    } else {
      acc
    }
  })
}

fn has_party(m :: PackManifest, name :: Str) -> Bool {
  not list.is_empty(list.filter(m.parties, fn (p :: PartySlot) -> Bool {
    p.name == name
  }))
}

# Every way a manifest can be wrong, as a list of messages — empty means valid.
# Returning all of them rather than the first lets a pack author fix a manifest
# in one pass, and lets a host assert the whole catalogue in a single test.
fn validate(m :: PackManifest) -> List[Str] {
  let base := if str.is_empty(m.id) or str.is_empty(m.title) or str.is_empty(m.route_prefix) {
    ["id, title and route_prefix are required"]
  } else {
    []
  }
  let pat := if is_pattern(m.pattern) {
    []
  } else {
    [str.concat("unknown pattern: ", m.pattern)]
  }
  let empty := if list.is_empty(m.parties) {
    ["a pack must name at least one party"]
  } else {
    []
  }
  let unknown := list.map(list.filter(m.parties, fn (p :: PartySlot) -> Bool {
    not is_position(p.position)
  }), fn (p :: PartySlot) -> Str {
    str.join([p.name, " occupies unknown position ", p.position], "")
  })
  let unnamed := list.map(list.filter(m.parties, fn (p :: PartySlot) -> Bool {
    str.is_empty(p.name) or str.is_empty(p.title)
  }), fn (_p :: PartySlot) -> Str {
    "every party needs a name and a title"
  })
  let dupes := list.map(dupe_party_names(m.parties), fn (n :: Str) -> Str {
    str.concat("duplicate party name: ", n)
  })
  let edges := list.fold(m.relationships, [], fn (acc :: List[Str], e :: PartyEdge) -> List[Str] {
    let bad_from := if has_party(m, e.from) {
      []
    } else {
      [str.join(["relationship from unknown party '", e.from, "'"], "")]
    }
    let bad_to := if has_party(m, e.to) {
      []
    } else {
      [str.join(["relationship to unknown party '", e.to, "'"], "")]
    }
    let bad_role := if is_edge_role(e.role) {
      []
    } else {
      [str.join(["relationship '", e.from, "->", e.to, "' has unknown role '", e.role, "'"], "")]
    }
    let self_edge := if e.from == e.to {
      [str.join(["relationship '", e.from, "' points at itself"], "")]
    } else {
      []
    }
    list.concat(acc, list.concat(bad_from, list.concat(bad_to, list.concat(bad_role, self_edge))))
  })
  list.concat(base, list.concat(pat, list.concat(empty, list.concat(unknown, list.concat(unnamed, list.concat(dupes, edges))))))
}

fn is_valid(m :: PackManifest) -> Bool {
  list.is_empty(validate(m))
}

# The parties of one pack that occupy a given position — how an onboarding
# surface answers "what would I be called here?" for a chosen position.
fn parties_at(m :: PackManifest, position :: Str) -> List[PartySlot] {
  list.filter(m.parties, fn (p :: PartySlot) -> Bool {
    p.position == position
  })
}

# The catalogue as one document: the shared vocabulary plus every domain
# described in it. This is the whole discovery payload.
fn catalogue_json(ms :: List[PackManifest]) -> jv.Json {
  JObj([("positions", JList(list.map(all(), position_json))), ("patterns", JList(list.map(patterns(), pattern_json))), ("packs", JList(list.map(ms, manifest_json)))])
}

