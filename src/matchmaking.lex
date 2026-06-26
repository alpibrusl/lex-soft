# src/matchmaking.lex — typed capability matchmaking for the federation directory.
#
# Replaces substring (SQL `LIKE '%"cap"%'`) capability search with structured
# matching. Orgs advertise namespaced, typed capability OFFERS — `{id, attrs}`,
# e.g. `{ "id": "logistics.freight.reefer", "attrs": { "region": "EU-south",
# "max_hours": 48, "price_eur": 1200 } }`. A discovery QUERY names an exact
# (namespaced) capability id plus typed CONSTRAINTS over attributes; an offer
# matches iff its id equals the query's id AND every constraint holds. Namespaced
# ids (dotted, like `logistics.freight.reefer`) keep two domains from colliding.
#
# Pure module (no effects) — the federation routes load org rows and call `find`.
# Legacy plain-string capabilities (`"logistics.freight.reefer"`) still parse, as
# offers with empty attrs, so `?capability=` exact-id lookups stay compatible.

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "lex-schema/json_value" as jv

# A typed constraint over an offer attribute. op ∈ {eq, ne, lte, gte, lt, gt}.
# eq/ne compare strings, bools or numbers; the ordered ops require numbers.
type Constraint = { attr :: Str, op :: Str, value :: jv.Json }

# A structured discovery query: an exact capability id + attribute constraints.
type Query = { capability :: Str, constraints :: List[Constraint] }

# An advertised capability offer.
type Offer = { id :: Str, attrs :: jv.Json }

# A ranked match: which org, which capability id, and a specificity score
# (how many attributes the matching offer carried — richer offers rank higher).
type Match = { org :: Str, capability :: Str, score :: Int }

# ---- value helpers ----
fn as_num(j :: jv.Json) -> Option[Float] {
  match j {
    JInt(n) => Some(int.to_float(n)),
    JFloat(f) => Some(f),
    _ => None,
  }
}

fn json_eq(a :: jv.Json, b :: jv.Json) -> Bool {
  match a {
    JStr(x) => match b {
      JStr(y) => x == y,
      _ => false,
    },
    JBool(x) => match b {
      JBool(y) => x == y,
      _ => false,
    },
    _ => match as_num(a) {
      Some(x) => match as_num(b) {
        Some(y) => x == y,
        None => false,
      },
      None => false,
    },
  }
}

# ---- constraint evaluation ----
fn eval_constraint(attrs :: jv.Json, c :: Constraint) -> Bool {
  match jv.get_field(attrs, c.attr) {
    None => false,
    Some(v) => if c.op == "eq" {
      json_eq(v, c.value)
    } else {
      if c.op == "ne" {
        not json_eq(v, c.value)
      } else {
        match as_num(v) {
          None => false,
          Some(a) => match as_num(c.value) {
            None => false,
            Some(b) => if c.op == "lte" {
              a <= b
            } else {
              if c.op == "gte" {
                a >= b
              } else {
                if c.op == "lt" {
                  a < b
                } else {
                  if c.op == "gt" {
                    a > b
                  } else {
                    false
                  }
                }
              }
            },
          },
        }
      }
    },
  }
}

# ---- offers ----
# Parse an org's advertised `capabilities` JSON into typed offers. Accepts both
# the legacy flat-string form and the typed `{id, attrs}` object form.
fn parse_offers(caps :: jv.Json) -> List[Offer] {
  match caps {
    JList(items) => list.fold(items, [], fn (acc :: List[Offer], it :: jv.Json) -> List[Offer] {
      match it {
        JStr(s) => list.concat(acc, [{ id: s, attrs: JObj([]) }]),
        _ => match jv.get_field(it, "id") {
          Some(JStr(id)) => {
            let attrs := match jv.get_field(it, "attrs") {
              Some(a) => a,
              None => JObj([]),
            }
            list.concat(acc, [{ id: id, attrs: attrs }])
          },
          _ => acc,
        },
      }
    }),
    _ => [],
  }
}

fn attr_count(attrs :: jv.Json) -> Int {
  match attrs {
    JObj(fields) => list.len(fields),
    _ => 0,
  }
}

fn offer_satisfies(o :: Offer, q :: Query) -> Bool {
  if o.id == q.capability {
    list.fold(q.constraints, true, fn (acc :: Bool, c :: Constraint) -> Bool {
      acc and eval_constraint(o.attrs, c)
    })
  } else {
    false
  }
}

# The best (most specific) satisfying offer score for one org's capabilities,
# or None if none of its offers match the query.
fn best_score(caps :: jv.Json, q :: Query) -> Option[Int] {
  list.fold(parse_offers(caps), None, fn (acc :: Option[Int], o :: Offer) -> Option[Int] {
    if offer_satisfies(o, q) {
      let s := attr_count(o.attrs)
      match acc {
        None => Some(s),
        Some(cur) => if s > cur {
          Some(s)
        } else {
          Some(cur)
        },
      }
    } else {
      acc
    }
  })
}

# ---- ranking ----
fn insert_ranked(m :: Match, sorted :: List[Match]) -> List[Match] {
  match list.head(sorted) {
    None => [m],
    Some(h) => if m.score > h.score {
      list.cons(m, sorted)
    } else {
      list.cons(h, insert_ranked(m, list.tail(sorted)))
    },
  }
}

# One org's directory entry as seen by matchmaking: its id + advertised
# capabilities JSON. (The federation route projects org_directory rows into these.)
type OrgCaps = { org :: Str, caps :: jv.Json }

# Filter + rank: returns the orgs whose advertised capabilities satisfy the
# query, ranked by specificity (score) descending.
fn find(entries :: List[OrgCaps], q :: Query) -> List[Match] {
  list.fold(entries, [], fn (acc :: List[Match], entry :: OrgCaps) -> List[Match] {
    match best_score(entry.caps, q) {
      None => acc,
      Some(s) => insert_ranked({ org: entry.org, capability: q.capability, score: s }, acc),
    }
  })
}

# ---- request/response JSON ----
fn parse_query(j :: jv.Json) -> Query {
  let capf := match jv.get_field(j, "capability") {
    Some(JStr(s)) => s,
    _ => "",
  }
  let cons := match jv.get_field(j, "constraints") {
    Some(JList(items)) => list.fold(items, [], fn (acc :: List[Constraint], it :: jv.Json) -> List[Constraint] {
      let attr := match jv.get_field(it, "attr") {
        Some(JStr(s)) => s,
        _ => "",
      }
      let op := match jv.get_field(it, "op") {
        Some(JStr(s)) => s,
        _ => "eq",
      }
      let val := match jv.get_field(it, "value") {
        Some(v) => v,
        None => JNull,
      }
      if str.is_empty(attr) {
        acc
      } else {
        list.concat(acc, [{ attr: attr, op: op, value: val }])
      }
    }),
    _ => [],
  }
  { capability: capf, constraints: cons }
}

# An exact-id query with no constraints — the backward-compatible `?capability=`.
fn exact_query(capability :: Str) -> Query {
  { capability: capability, constraints: [] }
}

fn match_to_json(m :: Match) -> jv.Json {
  JObj([("org", JStr(m.org)), ("capability", JStr(m.capability)), ("score", JInt(m.score))])
}

