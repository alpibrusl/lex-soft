# tests/test_external_agent.lex — acceptance tests for the external-agent audit
# adapter (#225). Asserts:
#   - reply_text pulls the agent's answer out of an A2A `tasks/send` result
#     (the lex-agent Task shape, with the reply under `message.parts`),
#   - make_agent_def builds a one-skill AgentDef whose card is named for the id,
#   - invoking the adapter handler records a VERIFIABLE settlement trail and
#     returns a `trail_id` artifact — even when the external inbox is
#     unreachable — so the interaction is audited and the node-side recorder
#     (#224) sees the trail_id and skips its own record (no double count).

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-agent/src/server" as srv

import "lex-agent/src/message" as msg

import "lex-agent/src/task" as tk

import "../src/external_agent" as ext

import "../src/settlement" as settlement

# An unreachable inbox: a closed localhost port. mesh.post_a2a maps the
# connection refusal to a non-delivery (never a hang), so the handler still runs
# its record path — exactly the "external handler produced no trail" case the
# adapter exists to cover.
fn sample_cfg() -> ext.ExternalConfig {
  { id: "ext-quote-bot", inbox_url: "http://127.0.0.1:59999/agents/ext-quote-bot/", skill: "quote", forward_token: "", description: "External quoting agent", version: "0.1.0", card_url: "http://localhost/agents/ext-quote-bot" }
}

# reply_text extracts the reply from a lex-agent Task result envelope.
fn reply_text_extracts() -> Result[Unit, Str] {
  let result := JObj([("kind", JStr("task")), ("id", JStr("t1")), ("status", JObj([("state", JStr("completed"))])), ("artifacts", JList([])), ("history", JList([])), ("message", JObj([("kind", JStr("message")), ("role", JStr("agent")), ("parts", JList([JObj([("type", JStr("text")), ("text", JStr("EUR 1200 SFO->JFK"))])]))]))])
  let got := ext.reply_text(result)
  if got == "EUR 1200 SFO->JFK" {
    Ok(())
  } else {
    Err(str.concat("reply_text should read message.parts text, got: ", got))
  }
}

# make_agent_def yields a card named for the id and exactly one skill.
fn agent_def_shape() -> [sql, fs_read, fs_write, time] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let def := ext.make_agent_def(db, sample_cfg())
      if def.card.name == "ext-quote-bot" and list.len(def.skills) == 1 {
        Ok(())
      } else {
        Err("make_agent_def should build a one-skill def named for the id")
      }
    },
  }
}

# Pull the trail_id out of a handler outcome's first data artifact.
fn outcome_trail_id(o :: srv.HandlerOutcome) -> Str {
  match list.head(o.artifacts) {
    None => "",
    Some(a) => match list.head(a.parts) {
      Some(DataPart(d)) => match jv.get_field(d, "trail_id") {
        Some(JStr(s)) => s,
        _ => "",
      },
      _ => "",
    },
  }
}

# Invoking the adapter records a verifiable trail + returns a trail_id artifact,
# even with the external inbox down.
fn records_even_when_unreachable() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let handler := ext.make_handler(db, sample_cfg())
      let outcome := handler(msg.user_text("quote SFO->JFK"))
      let tid := outcome_trail_id(outcome)
      if str.is_empty(tid) {
        Err("adapter must return a trail_id artifact")
      } else {
        if settlement.verify(settlement.trail_on(db), tid) {
          Ok(())
        } else {
          Err("the recorded adapter trail should verify")
        }
      }
    },
  }
}

fn run_all() -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] Unit {
  let results := [reply_text_extracts(), agent_def_shape(), records_even_when_unreachable()]
  let failures := list.fold(results, [], fn (acc :: List[Str], r :: Result[Unit, Str]) -> List[Str] {
    match r {
      Ok(_) => acc,
      Err(m) => list.concat(acc, [m]),
    }
  })
  if list.is_empty(failures) {
    ()
  } else {
    let __boom := 1 / 0
    ()
  }
}

