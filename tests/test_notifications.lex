# tests/test_notifications.lex — the per-account notification bus (#64).
#
# Covers the serve-safe half (enqueue + channel config + tenant scoping) and
# the delivery bookkeeping that does NOT require outbound HTTP (a notification
# for an account with no channel resolves to `no_channel` and records a trail
# event, rather than retrying forever). Live webhook delivery is a smoke test.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "std.bytes" as bytes

import "std.crypto" as crypto

import "../src/migrate" as migrate

import "../src/notifications" as notifications

fn seed() -> Bytes {
  crypto.sha256(bytes.from_str("notify-test-seed"))
}

# enqueue records a pending notification visible to its own account only.
fn enqueue_is_account_scoped() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __a := notifications.enqueue(db, "acct-a", "quota.breach", "{\"org\":\"acct-a\"}")
      let __b := notifications.enqueue(db, "acct-b", "escalation.raised", "{}")
      let a_list := notifications.list_notifications(db, "acct-a")
      let b_list := notifications.list_notifications(db, "acct-b")
      if list.len(a_list) == 1 and list.len(b_list) == 1 {
        match list.head(a_list) {
          Some(n) => if n.event_type == "quota.breach" and n.status == "pending" {
            Ok(())
          } else {
            Err(str.concat("acct-a notification wrong: ", str.concat(n.event_type, str.concat("/", n.status))))
          },
          None => Err("no notification for acct-a"),
        }
      } else {
        Err("notification counts not isolated per account")
      }
    },
  }
}

# Channel config is account-scoped: acct-a never sees acct-b's channel.
fn channels_are_account_scoped() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __ca := notifications.configure_channel(db, "acct-a", "webhook", "https://a.example/hook")
      let __cb := notifications.configure_channel(db, "acct-b", "webhook", "https://b.example/hook")
      let a_chans := notifications.list_channels(db, "acct-a")
      let b_chans := notifications.list_channels(db, "acct-b")
      if list.len(a_chans) == 1 and list.len(b_chans) == 1 {
        match list.head(a_chans) {
          Some(ch) => if ch.target == "https://a.example/hook" {
            Ok(())
          } else {
            Err(str.concat("acct-a channel target wrong: ", ch.target))
          },
          None => Err("no channel for acct-a"),
        }
      } else {
        Err("channels not isolated per account")
      }
    },
  }
}

# Delivering a notification whose account has NO channel marks it no_channel
# (terminal — not left pending to retry forever) and records a trail event.
fn no_channel_is_terminal() -> [io, net, sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __e := notifications.enqueue(db, "acct-lonely", "quota.breach", "{}")
      let __d := notifications.deliver_pending(db, seed(), "pub")
      let remaining := notifications.list_notifications(db, "acct-lonely")
      match list.head(remaining) {
        Some(n) => if n.status == "no_channel" {
          Ok(())
        } else {
          Err(str.concat("expected no_channel, got: ", n.status))
        },
        None => Err("notification vanished"),
      }
    },
  }
}

# A signed webhook body carries the event, an ed25519 signature, and the key.
fn signed_body_is_verifiable_shape() -> [sql, fs_read, fs_write, time, random] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => {
      let __m := migrate.run(db)
      let __e := notifications.enqueue(db, "acct-s", "quota.breach", "{\"org\":\"acct-s\"}")
      match list.head(notifications.list_notifications(db, "acct-s")) {
        None => Err("no notification"),
        Some(n) => {
          let body := notifications.signed_body(n, seed(), "the-pub-key")
          if str.contains(body, "ed25519") and str.contains(body, "the-pub-key") and str.contains(body, "quota.breach") {
            Ok(())
          } else {
            Err(str.concat("signed body missing fields: ", body))
          }
        },
      }
    },
  }
}

fn run_all() -> [io, sql, fs_read, fs_write, time, crypto, random, net, concurrent, llm, proc] Unit {
  let results := [enqueue_is_account_scoped(), channels_are_account_scoped(), no_channel_is_terminal(), signed_body_is_verifiable_shape()]
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

