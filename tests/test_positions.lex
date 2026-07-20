# tests/test_positions.lex — the domain vocabulary is internally consistent.
#
# These are the invariants a pack manifest validator leans on: a pattern may
# only cite positions that exist, and ids must be unique, or a typo becomes a
# position no party can ever be onboarded into.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "../src/positions" as pos

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

fn dupes(ids :: List[Str]) -> List[Str] {
  list.filter(ids, fn (id :: Str) -> Bool {
    list.len(list.filter(ids, fn (other :: Str) -> Bool {
      other == id
    })) > 1
  })
}

fn position_ids_are_unique() -> Result[Unit, Str] {
  let ids := list.map(pos.all(), fn (p :: pos.Position) -> Str {
    p.id
  })
  assert_true(list.is_empty(dupes(ids)), str.concat("duplicate position id: ", str.join(dupes(ids), ",")))
}

fn pattern_ids_are_unique() -> Result[Unit, Str] {
  let ids := list.map(pos.patterns(), fn (p :: pos.Pattern) -> Str {
    p.id
  })
  assert_true(list.is_empty(dupes(ids)), str.concat("duplicate pattern id: ", str.join(dupes(ids), ",")))
}

# The load-bearing one: every position a pattern cites must exist.
fn patterns_only_cite_known_positions() -> Result[Unit, Str] {
  let bad := list.fold(pos.patterns(), [], fn (acc :: List[Str], p :: pos.Pattern) -> List[Str] {
    list.concat(acc, list.map(list.filter(p.positions, fn (id :: Str) -> Bool {
      not pos.is_position(id)
    }), fn (id :: Str) -> Str {
      str.join([p.id, " cites unknown position ", id], "")
    }))
  })
  assert_true(list.is_empty(bad), str.join(bad, "; "))
}

# Each position names the core primitive that justifies it (see the header of
# positions.lex — a position with no primitive behind it is editorial).
fn every_position_names_a_primitive() -> Result[Unit, Str] {
  let bare := list.filter(pos.all(), fn (p :: pos.Position) -> Bool {
    str.is_empty(p.primitive) or str.is_empty(p.summary)
  })
  assert_true(list.is_empty(bare), "every position needs a primitive and a summary")
}

fn every_position_is_reachable_from_some_pattern() -> Result[Unit, Str] {
  let orphans := list.filter(pos.all(), fn (p :: pos.Position) -> Bool {
    list.is_empty(list.filter(pos.patterns(), fn (pat :: pos.Pattern) -> Bool {
      not list.is_empty(list.filter(pat.positions, fn (id :: Str) -> Bool {
        id == p.id
      }))
    }))
  })
  assert_true(list.is_empty(orphans), str.concat("position no pattern uses: ", str.join(list.map(orphans, fn (p :: pos.Position) -> Str {
    p.id
  }), ",")))
}

fn unknown_ids_are_rejected() -> Result[Unit, Str] {
  assert_true(not pos.is_position("shipper") and not pos.is_pattern("insurance_claim") and pos.is_position("custodian") and pos.is_pattern("custody_chain"), "a domain word must not pass as a position or pattern id")
}

fn slot(position :: Str, name :: Str) -> pos.PartySlot {
  { position: position, name: name, title: name, field: name, required: true }
}

fn sample() -> pos.PackManifest {
  { id: "claims", title: "Claims", tagline: "Loss adjusted, then paid.", pattern: "milestone_release", subject: "claim", subject_ref_field: "claim_ref", custody_ref_field: "", parties: [slot("originator", "policyholder"), slot("attestor", "adjuster"), slot("settler", "insurer")], relationships: [{ from: "policyholder", to: "adjuster", role: "reporting", label: "claim submitted for assessment" }, { from: "insurer", to: "policyholder", role: "settlement", label: "claim paid once assessed" }], event_kinds: ["claims.opened"], evidence_kinds: ["report"], settles: true, route_prefix: "/claims" }
}

fn a_well_formed_manifest_validates() -> Result[Unit, Str] {
  assert_true(pos.is_valid(sample()), str.concat("sample manifest rejected: ", str.join(pos.validate(sample()), "; ")))
}

# validate must report EVERY fault at once, not just the first, so a pack author
# fixes a manifest in one pass. Three independent faults => three messages.
fn validate_reports_every_fault() -> Result[Unit, Str] {
  let m := sample()
  let broken := { id: m.id, title: m.title, tagline: m.tagline, pattern: "no_such_pattern", subject: m.subject, subject_ref_field: m.subject_ref_field, custody_ref_field: m.custody_ref_field, parties: [slot("originator", "dup"), slot("not_a_position", "dup")], relationships: [], event_kinds: m.event_kinds, evidence_kinds: m.evidence_kinds, settles: m.settles, route_prefix: m.route_prefix }
  let faults := pos.validate(broken)
  assert_true(not pos.is_valid(broken) and list.len(faults) == 3, str.concat("expected 3 faults (pattern, position, duplicate name), got: ", str.join(faults, " | ")))
}

fn an_empty_manifest_is_rejected() -> Result[Unit, Str] {
  let m := sample()
  let bare := { id: "", title: "", tagline: "", pattern: "custody_chain", subject: "", subject_ref_field: "", custody_ref_field: "", parties: [], relationships: [], event_kinds: [], evidence_kinds: [], settles: false, route_prefix: "" }
  assert_true(not pos.is_valid(bare) and pos.is_valid(m), "a manifest with no id and no parties must be rejected")
}

fn parties_at_selects_by_position() -> Result[Unit, Str] {
  let settlers := pos.parties_at(sample(), "settler")
  let none := pos.parties_at(sample(), "custodian")
  assert_true(list.len(settlers) == 1 and list.is_empty(none), "parties_at must select exactly the slots at a position")
}

fn with_edges(es :: List[pos.PartyEdge]) -> pos.PackManifest {
  let m := sample()
  { id: m.id, title: m.title, tagline: m.tagline, pattern: m.pattern, subject: m.subject, subject_ref_field: m.subject_ref_field, custody_ref_field: m.custody_ref_field, parties: m.parties, relationships: es, event_kinds: m.event_kinds, evidence_kinds: m.evidence_kinds, settles: m.settles, route_prefix: m.route_prefix }
}

# An edge naming a party that does not exist would silently never materialise —
# the worst kind of fault, because onboarding would look like it worked.
fn edges_must_name_real_parties() -> Result[Unit, Str] {
  let m := with_edges([{ from: "policyholder", to: "loss-assessor", role: "reporting", label: "x" }])
  assert_true(not pos.is_valid(m) and list.len(pos.validate(m)) == 1, str.concat("expected one unknown-party fault, got: ", str.join(pos.validate(m), " | ")))
}

# Roles are what peer discovery filters on, so a domain-invented word would make
# the edge invisible to generic queries.
fn edge_roles_come_from_the_shared_vocabulary() -> Result[Unit, Str] {
  let m := with_edges([{ from: "policyholder", to: "adjuster", role: "assesses", label: "x" }])
  assert_true(not pos.is_valid(m) and pos.is_edge_role("custody") and not pos.is_edge_role("assesses"), str.join(pos.validate(m), " | "))
}

fn self_edges_are_rejected() -> Result[Unit, Str] {
  let m := with_edges([{ from: "adjuster", to: "adjuster", role: "reporting", label: "x" }])
  assert_true(not pos.is_valid(m), "a party must not relate to itself")
}

fn the_sample_edges_validate() -> Result[Unit, Str] {
  assert_true(pos.is_valid(sample()), str.join(pos.validate(sample()), " | "))
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [edges_must_name_real_parties(), edge_roles_come_from_the_shared_vocabulary(), self_edges_are_rejected(), the_sample_edges_validate(), position_ids_are_unique(), pattern_ids_are_unique(), patterns_only_cite_known_positions(), every_position_names_a_primitive(), every_position_is_reachable_from_some_pattern(), unknown_ids_are_rejected(), a_well_formed_manifest_validates(), validate_reports_every_fault(), an_empty_manifest_is_rejected(), parties_at_selects_by_position()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __show := list.fold(failures, (), fn (_a :: Unit, m :: Str) -> [io] Unit {
      io.print(str.concat("FAIL: ", str.concat(m, "\n")))
    })
    let __boom := 1 / 0
    ()
  }
}

