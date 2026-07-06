# resolver.lex — intent-based peer resolution.
#
# Agents never hardcode peer IDs. Instead they declare an intent and the
# resolver returns the list of active, authorised peers for that intent.
#
# The intent → role mapping is DOMAIN DATA, not core logic: the host supplies a
# `List[IntentRoles]` (e.g. a logistics pack maps "charging" → [charger, …]) and
# the core stays product-independent. An intent absent from the map (or an empty
# map) matches all active peers — the generic "coordination" fallback.

import "std.list" as list

import "std.sql" as sql

import "./registry" as reg

import "./relationships" as rel

# A host-supplied intent → relationship-roles entry. The core never hardcodes
# these; a domain pack provides the vocabulary (was the EV-coupled lex-soft#34).
type IntentRoles = { intent :: Str, roles :: List[Str] }

# Roles the host mapped an intent to; empty = no role constraint (any peer).
fn roles_for(map :: List[IntentRoles], intent :: Str) -> List[Str] {
  list.fold(map, [], fn (acc :: List[Str], ir :: IntentRoles) -> List[Str] {
    if ir.intent == intent {
      list.concat(acc, ir.roles)
    } else {
      acc
    }
  })
}

# The intents the host defined — used to describe the find_peers tool to agents.
fn intents_of(map :: List[IntentRoles]) -> List[Str] {
  list.map(map, fn (ir :: IntentRoles) -> Str {
    ir.intent
  })
}

fn resolve(db :: Db, from_agent_id :: Str, intent :: Str, map :: List[IntentRoles]) -> [sql, fs_read] Result[List[reg.AgentRef], Str] {
  let roles := roles_for(map, intent)
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

fn resolve_one(db :: Db, from_agent_id :: Str, intent :: Str, map :: List[IntentRoles]) -> [sql, fs_read] Result[Option[reg.AgentRef], Str] {
  match resolve(db, from_agent_id, intent, map) {
    Err(e) => Err(e),
    Ok(refs) => Ok(list.head(refs)),
  }
}

