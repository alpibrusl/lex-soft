# ledger.lex — tenant-scoped settlement/finance view over the trail (#228).
#
# lex-soft already MOVES money: `settlement.record_chargeback[_dec]` writes a
# `settlement.chargeback` event for every transfer, and the packs settle against
# evidence (`tradefinance.lc.settled`, `construction.milestone.released`,
# `flex.delivered`, `coldchain.custody_fee.settled`) and open obligations
# (`tradefinance.lc.opened`, `flex.committed`). This exposes that money layer as
# a CUSTOMER-facing finance surface — a per-tenant ledger, a settled/pending
# summary, and the invoice-like settlement documents — read straight from the
# real trail. No new store: the trail is the system of record.
#
#   GET /ledger/entries[?before_ts_ms=]   — this org's money movements (chargebacks)
#   GET /ledger/summary                    — settled totals per currency (in/out/net)
#   GET /ledger/invoices[?before_ts_ms=]   — settlement + open-obligation documents
#
# Scoping is IDENTICAL to /audit (audit.scoped_ids → audit.agent_where): an
# account sees only the money events naming one of its own org's agents as
# `agent`/`from_agent`/`to_agent`. Reusing that one tenant boundary keeps the
# finance view exactly as tenant-safe as the audit view.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "./identity" as identity

import "./audit" as audit

# The event kind of a money TRANSFER — the ledger's spine (every settlement
# records one, so counting these never double-counts a business document).
fn chargeback_kind() -> Str {
  "settlement.chargeback"
}

# Settlement documents (an amount was paid) and open obligations (an amount is
# owed but not yet settled) — the invoice view. `settled`/`pending` per kind.
fn invoice_kinds() -> List[{ kind :: Str, status :: Str, from_field :: Str, to_field :: Str }] {
  [{ kind: "tradefinance.lc.settled", status: "settled", from_field: "from_agent", to_field: "to_agent" }, { kind: "tradefinance.lc.opened", status: "pending", from_field: "applicant", to_field: "beneficiary" }, { kind: "construction.milestone.released", status: "settled", from_field: "from_agent", to_field: "to_agent" }, { kind: "flex.delivered", status: "settled", from_field: "from_agent", to_field: "to_agent" }, { kind: "flex.committed", status: "pending", from_field: "buyer", to_field: "seller" }, { kind: "coldchain.custody_fee.settled", status: "settled", from_field: "from_agent", to_field: "to_agent" }]
}

# The ledger's tenant boundary is BROADER than audit's: an account is a party to
# a money event when one of its agents is the actor, the PAYER (`from_agent`) OR
# the PAYEE (`to_agent`) — a payee never "acted", so audit.agent_where (actor /
# agent / from_agent only) would hide its incoming payments. Same org-agent id
# set (audit.scoped_ids), one extra `to_agent` arm.
fn money_where(ids :: List[Str]) -> audit.WhereClause {
  let in_marks := str.join(list.map(ids, fn (_id :: Str) -> Str {
    "?"
  }), ", ")
  let in_params := list.map(ids, fn (id :: Str) -> SqlParam {
    PStr(id)
  })
  let like_parts := list.map(ids, fn (_id :: Str) -> Str {
    "(payload_json LIKE ? OR payload_json LIKE ?)"
  })
  let like_params := list.fold(ids, [], fn (acc :: List[SqlParam], id :: Str) -> List[SqlParam] {
    list.concat(acc, [PStr(str.join(["%\"from_agent\":\"", id, "\"%"], "")), PStr(str.join(["%\"to_agent\":\"", id, "\"%"], ""))])
  })
  let clause := str.join(["(actor IN (", in_marks, ") OR ", str.join(like_parts, " OR "), ")"], "")
  { clause: clause, params: list.concat(in_params, like_params) }
}

fn pstr_field(payload_json :: Str, key :: Str) -> Str {
  audit.payload_field(payload_json, key)
}

fn pfloat_field(payload_json :: Str, key :: Str) -> Float {
  match jv.parse(payload_json) {
    Err(_) => 0.0,
    Ok(j) => match jv.get_field(j, key) {
      Some(JFloat(f)) => f,
      Some(JInt(n)) => int.to_float(n),
      _ => 0.0,
    },
  }
}

# Scoped, newest-first events of ONE kind for a set of agents, with a
# `before_ts_ms` cursor. (audit.query_events only exposes one-kind queries too;
# this mirrors it against the ledger's kinds.)
fn query_kind(db :: Db, ids :: List[Str], kind :: Str, before_ts_ms :: Option[Int]) -> [sql, fs_read] List[audit.EvRow] {
  if list.is_empty(ids) {
    []
  } else {
    let aw := money_where(ids)
    let cursor_clause := match before_ts_ms {
      None => "",
      Some(ts) => str.join([" AND ts_ms < ", int.to_str(ts)], ""),
    }
    let q := str.join(["SELECT id, kind, COALESCE(parent, '') AS parent, payload_json, ts_ms FROM events WHERE ", aw.clause, " AND kind=?", cursor_clause, " ORDER BY ts_ms DESC LIMIT ", int.to_str(audit.page_size())], "")
    let rows :: Result[List[audit.EvRow], SqlError] := sql.query(db, q, list.concat(aw.params, [PStr(kind)]))
    match rows {
      Err(_) => [],
      Ok(rs) => rs,
    }
  }
}

# One ledger line, from the org's point of view: an incoming credit when an org
# agent is the payee, an outgoing debit when it is the payer.
fn entry_json(ids :: List[Str], r :: audit.EvRow) -> jv.Json {
  let from_agent := pstr_field(r.payload_json, "from_agent")
  let to_agent := pstr_field(r.payload_json, "to_agent")
  let incoming := audit.in_set(ids, to_agent)
  let direction := if incoming {
    "in"
  } else {
    "out"
  }
  let counterparty := if incoming {
    from_agent
  } else {
    to_agent
  }
  JObj([("trail_id", JStr(r.id)), ("ts_ms", JInt(r.ts_ms)), ("ref", JStr(pstr_field(r.payload_json, "ref"))), ("from_agent", JStr(from_agent)), ("to_agent", JStr(to_agent)), ("direction", JStr(direction)), ("counterparty", JStr(counterparty)), ("amount_dec", JStr(pstr_field(r.payload_json, "amount_dec"))), ("amount", JFloat(pfloat_field(r.payload_json, "amount"))), ("currency", JStr(pstr_field(r.payload_json, "currency")))])
}

# A running per-currency total (incoming/outgoing sums of the display `amount`;
# each entry keeps its authoritative `amount_dec`).
type CurrencyTotal = { currency :: Str, incoming :: Float, outgoing :: Float, count :: Int }

fn bump(totals :: List[CurrencyTotal], currency :: Str, incoming :: Bool, amount :: Float) -> List[CurrencyTotal] {
  let found := list.fold(totals, false, fn (acc :: Bool, t :: CurrencyTotal) -> Bool {
    acc or t.currency == currency
  })
  if found {
    list.map(totals, fn (t :: CurrencyTotal) -> CurrencyTotal {
      if t.currency == currency {
        { currency: t.currency, incoming: t.incoming + if incoming {
          amount
        } else {
          0.0
        }, outgoing: t.outgoing + if incoming {
          0.0
        } else {
          amount
        }, count: t.count + 1 }
      } else {
        t
      }
    })
  } else {
    list.concat(totals, [{ currency: currency, incoming: if incoming {
      amount
    } else {
      0.0
    }, outgoing: if incoming {
      0.0
    } else {
      amount
    }, count: 1 }])
  }
}

fn summarize(ids :: List[Str], rows :: List[audit.EvRow]) -> List[CurrencyTotal] {
  list.fold(rows, [], fn (acc :: List[CurrencyTotal], r :: audit.EvRow) -> List[CurrencyTotal] {
    let cur := pstr_field(r.payload_json, "currency")
    let incoming := audit.in_set(ids, pstr_field(r.payload_json, "to_agent"))
    bump(acc, cur, incoming, pfloat_field(r.payload_json, "amount"))
  })
}

fn total_json(t :: CurrencyTotal) -> jv.Json {
  JObj([("currency", JStr(t.currency)), ("incoming", JFloat(t.incoming)), ("outgoing", JFloat(t.outgoing)), ("net", JFloat(t.incoming - t.outgoing)), ("count", JInt(t.count))])
}

# Resolve the requesting subject and scope to its org's agents. Shared by every
# response so the tenant boundary is applied exactly once.
fn with_scope(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx, k :: (Str, Str, List[Str]) -> [sql, fs_read, time] resp.Response) -> [sql, fs_read, time] resp.Response {
  match ctx.bearer_token(c) {
    None => resp.unauthorized("{\"error\":\"missing bearer token\"}"),
    Some(tok) => match identity.resolve_subject_in(db, secrets, tok) {
      Err(_) => resp.json_status(500, "{\"error\":\"ledger lookup failed\"}"),
      Ok(None) => resp.unauthorized("{\"error\":\"unrecognised credential\"}"),
      Ok(Some(subj)) => match audit.scoped_ids(db, subj.org, c) {
        Err(_) => resp.json_status(500, "{\"error\":\"ledger scope lookup failed\"}"),
        Ok(ids) => k(subj.org, subj.account, ids),
      },
    },
  }
}

fn entries_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  with_scope(db, secrets, c, fn (org :: Str, account :: Str, ids :: List[Str]) -> [sql, fs_read, time] resp.Response {
    let rows := query_kind(db, ids, chargeback_kind(), audit.parse_cursor(c))
    let cursor_j := match audit.next_cursor(rows) {
      None => JNull,
      Some(ts) => JInt(ts),
    }
    resp.json(jv.stringify(JObj([("org", JStr(org)), ("account", JStr(account)), ("count", JInt(list.len(rows))), ("next_cursor", cursor_j), ("entries", JList(list.map(rows, fn (r :: audit.EvRow) -> jv.Json {
      entry_json(ids, r)
    })))])))
  })
}

fn summary_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  with_scope(db, secrets, c, fn (org :: Str, account :: Str, ids :: List[Str]) -> [sql, fs_read, time] resp.Response {
    let rows := query_kind(db, ids, chargeback_kind(), None)
    let totals := summarize(ids, rows)
    resp.json(jv.stringify(JObj([("org", JStr(org)), ("account", JStr(account)), ("movements", JInt(list.len(rows))), ("by_currency", JList(list.map(totals, total_json)))])))
  })
}

# One invoice row, projected from a settlement/obligation event.
fn invoice_json(ids :: List[Str], spec :: { kind :: Str, status :: Str, from_field :: Str, to_field :: Str }, r :: audit.EvRow) -> jv.Json {
  let payer := pstr_field(r.payload_json, spec.from_field)
  let payee := pstr_field(r.payload_json, spec.to_field)
  let incoming := audit.in_set(ids, payee)
  let ref_val := {
    let a := pstr_field(r.payload_json, "ref")
    if str.is_empty(a) {
      let b := pstr_field(r.payload_json, "lc_ref")
      if str.is_empty(b) {
        let d := pstr_field(r.payload_json, "contract_ref")
        if str.is_empty(d) {
          pstr_field(r.payload_json, "tender_ref")
        } else {
          d
        }
      } else {
        b
      }
    } else {
      a
    }
  }
  JObj([("trail_id", JStr(r.id)), ("ts_ms", JInt(r.ts_ms)), ("kind", JStr(r.kind)), ("status", JStr(spec.status)), ("ref", JStr(ref_val)), ("payer", JStr(payer)), ("payee", JStr(payee)), ("direction", JStr(if incoming {
    "in"
  } else {
    "out"
  })), ("amount_dec", JStr(pstr_field(r.payload_json, "amount_dec"))), ("currency", JStr(pstr_field(r.payload_json, "currency")))])
}

fn invoices_response(db :: Db, secrets :: List[Bytes], c :: ctx.Ctx) -> [sql, fs_read, time] resp.Response {
  with_scope(db, secrets, c, fn (org :: Str, account :: Str, ids :: List[Str]) -> [sql, fs_read, time] resp.Response {
    let before := audit.parse_cursor(c)
    let rows := list.fold(invoice_kinds(), [], fn (acc :: List[jv.Json], spec :: { kind :: Str, status :: Str, from_field :: Str, to_field :: Str }) -> [sql, fs_read] List[jv.Json] {
      let evs := query_kind(db, ids, spec.kind, before)
      list.concat(acc, list.map(evs, fn (r :: audit.EvRow) -> jv.Json {
        invoice_json(ids, spec, r)
      }))
    })
    resp.json(jv.stringify(JObj([("org", JStr(org)), ("account", JStr(account)), ("count", JInt(list.len(rows))), ("invoices", JList(rows))])))
  })
}

# Host opt-in: mount the tenant-scoped ledger routes. `secrets` is the same
# federation keyring /audit is mounted with (identity.resolve_subject).
fn mount(r :: router.Router, db :: Db, secrets :: List[Bytes]) -> router.Router {
  let r_ent := router.route_effectful(r, "GET", "/ledger/entries", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    entries_response(db, secrets, c)
  })
  let r_sum := router.route_effectful(r_ent, "GET", "/ledger/summary", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    summary_response(db, secrets, c)
  })
  router.route_effectful(r_sum, "GET", "/ledger/invoices", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    invoices_response(db, secrets, c)
  })
}

