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

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [position_ids_are_unique(), pattern_ids_are_unique(), patterns_only_cite_known_positions(), every_position_names_a_primitive(), every_position_is_reachable_from_some_pattern(), unknown_ids_are_rejected()]
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

