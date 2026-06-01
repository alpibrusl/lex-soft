# resolver.lex — intent-based peer resolution.
#
# Agents never hardcode peer IDs. Instead they declare an intent
# ("need_charging", "need_dispatch") and the resolver returns the
# list of active, authorised peers for that intent.
#
# Intent → role mapping (extensible):
#   "charging"       → roles: preferred_charger, charger
#   "dispatch"       → roles: contracted, freelance
#   "reporting"      → roles: reporting
#   "coordination"   → all active peers regardless of role
#
# If the intent is unknown the resolver falls back to returning all
# active relationships for the requesting agent.

import "std.list" as list

import "std.sql" as sql

import "./registry" as reg

import "./relationships" as rel

fn roles_for_intent(intent :: Str) -> List[Str] {
  if intent == "charging" {
    ["preferred_charger", "charger"]
  } else {
    if intent == "dispatch" {
      ["contracted", "freelance"]
    } else {
      if intent == "reporting" {
        ["reporting"]
      } else {
        []
      }
    }
  }
}

fn resolve(db :: Db, from_agent_id :: Str, intent :: Str) -> [sql, fs_read] Result[List[reg.AgentRef], Str] {
  let roles := roles_for_intent(intent)
  if list.len(roles) == 0 {
    match rel.peers_of(db, from_agent_id) {
      Err(e) => Err(e),
      Ok(rels) => Ok(rel.resolve_refs(db, rels)),
    }
  } else {
    match rel.peers_of(db, from_agent_id) {
      Err(e) => Err(e),
      Ok(all_rels) => {
        let matching := list.filter(all_rels, fn (r :: rel.Relationship) -> Bool {
          list.fold(roles, false, fn (acc :: Bool, role :: Str) -> Bool {
            acc or r.role == role
          })
        })
        Ok(rel.resolve_refs(db, matching))
      },
    }
  }
}

fn resolve_one(db :: Db, from_agent_id :: Str, intent :: Str) -> [sql, fs_read] Result[Option[reg.AgentRef], Str] {
  match resolve(db, from_agent_id, intent) {
    Err(e) => Err(e),
    Ok(refs) => Ok(list.head(refs)),
  }
}

