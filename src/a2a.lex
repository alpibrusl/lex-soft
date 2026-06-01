# a2a.lex — outgoing agent-to-agent messages via A2A tasks/send.
#
# send() resolves the target's inbox_url from the registry and calls
# lex-agent/client.send_task with a proper JSON-RPC envelope.
# The topic becomes the `skill` field in SendOpts so the receiving
# agent's skill router dispatches to the right handler.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-agent/src/message" as msg

import "lex-agent/src/client" as client

import "./registry" as reg

fn send(db :: Db, from_id :: Str, to_id :: Str, topic :: Str, payload_json :: Str) -> [sql, fs_read, net, crypto, random] Result[Unit, Str] {
  match reg.find_by_id(db, to_id) {
    Err(e) => Err(e),
    Ok(None) => Err(str.concat("agent not found: ", to_id)),
    Ok(Some(peer)) => {
      let m    := msg.user_text(payload_json)
      let opts := { task_id: str.concat("a2a-", to_id), context_id: from_id, skill: topic }
      match client.send_task(peer.inbox_url, m, opts) {
        Err(_) => Err("a2a send failed"),
        Ok(_)  => Ok(()),
      }
    },
  }
}

fn broadcast(db :: Db, from_id :: Str, to_ids :: List[Str], topic :: Str, payload_json :: Str) -> [sql, fs_read, net, crypto, random] List[Result[Unit, Str]] {
  list.map(to_ids, fn (to_id :: Str) -> [sql, fs_read, net, crypto, random] Result[Unit, Str] {
    send(db, from_id, to_id, topic, payload_json)
  })
}
