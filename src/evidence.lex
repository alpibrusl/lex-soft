# src/evidence.lex — record domain evidence on the trail (lex-ev-fleet#226/#227).
#
# The in-process face of the Documents / Evidence module (the lex-docs service
# is the out-of-process face). A pack that proves custody — a presented LC
# document, an inspection with a photo hash, a temperature excursion, a certified
# origin — records an evidence event onto the settlement trail.
#
# Done by hand with `tlog.append` this was easy to get subtly wrong: an event
# whose payload names no `agent`/`from_agent` is INVISIBLE to its own tenant's
# `/audit` (the audit slice scopes actor='' rows by exactly those two payload
# keys — see audit.agent_where). Trade-finance documents and agri-food origins
# shipped with that bug. `record` guarantees the audit-shaped custody-event
# shape — actor-stamped, `agent`/`from_agent` present — while preserving the
# caller's `kind` and `parent`, so existing per-subject chains and settlement
# re-verification (`settlement.verify`) are byte-for-byte unaffected in
# structure; only now the evidence is auditable.

import "std.str" as str

import "std.list" as list

import "std.crypto" as crypto

import "lex-schema/json_value" as jv

import "lex-trail/log" as tlog

import "lex-trail/event" as ev

# SHA-256 of a document's bytes — the content address a hashed-document evidence
# event carries. Callers holding the blob hash it here; callers already holding
# the digest (a client that uploaded the hash) pass it straight through.
fn content_hash(content :: Str) -> Str {
  crypto.sha256_str(content)
}

# Does `fields` already bind `key`?
fn has_field(fields :: List[(Str, jv.Json)], key :: Str) -> Bool {
  list.fold(fields, false, fn (acc :: Bool, kv :: (Str, jv.Json)) -> Bool {
    match kv {
      (k, _) => acc or k == key,
    }
  })
}

# Ensure the audit-scoping keys are present. `/audit` includes an actor='' event
# only when its payload names an org agent under `agent` or `from_agent`; we set
# both to `actor` when the caller hasn't already bound them, so the evidence
# lands in the recording agent's tenant slice. A caller that already carries a
# distinct `agent`/`from_agent` (e.g. a counterparty) is left untouched.
fn with_actor_keys(actor :: Str, fields :: List[(Str, jv.Json)]) -> List[(Str, jv.Json)] {
  let f1 := if has_field(fields, "agent") {
    fields
  } else {
    list.concat(fields, [("agent", JStr(actor))])
  }
  if has_field(f1, "from_agent") {
    f1
  } else {
    list.concat(f1, [("from_agent", JStr(actor))])
  }
}

# Record an evidence event: audit-shaped, actor-stamped (so the audit fast-path
# actor-column filter matches too), keyed to the caller's `kind` and `parent`.
# `fields` is the domain payload; the recorder only ADDS the audit keys, never
# rewrites the caller's own. Returns the appended event (its content-addressed
# id is the evidence's trail id), or an error string on failure.
fn record(log :: tlog.Log, kind :: Str, actor :: Str, parent :: Option[Str], fields :: List[(Str, jv.Json)]) -> [sql, time] Result[ev.Event, Str] {
  let payload := jv.stringify(JObj(with_actor_keys(actor, fields)))
  tlog.append_actor(log, kind, actor, parent, payload)
}

