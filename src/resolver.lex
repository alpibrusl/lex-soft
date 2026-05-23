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
import "std.str" as str
import "std.sql" as sql
import "./registry" as reg
import "./relationships" as rel

fn roles_for_intent(intent :: Str) -> List[Str] {
  if str.eq(intent, "charging") {
    ["preferred_charger", "charger"]
  } else {
    if str.eq(intent, "dispatch") {
      ["contracted", "freelance"]
    } else {
      if str.eq(intent, "reporting") {
        ["reporting"]
      } else {
        []
      }
    }
  }
}

fn resolve(db :: sql.Db, from_agent_id :: Str, intent :: Str) -> [sql, fs_read] Result[List[reg.AgentRef], Str] {
  let roles := roles_for_intent(intent)
  if list.is_empty(roles) {
    match rel.peers_of(db, from_agent_id) {
      Err(e) => Err(e),
      Ok(rels) => Ok(rel.resolve_refs(db, rels)),
    }
  } else {
    match rel.peers_of(db, from_agent_id) {
      Err(e) => Err(e),
      Ok(all_rels) => {
        let matching := list.filter(all_rels, fn (r :: rel.Relationship) -> Bool {
          list.any(roles, fn (role :: Str) -> Bool { str.eq(r.role, role) })
        })
        Ok(rel.resolve_refs(db, matching))
      },
    }
  }
}

fn resolve_one(db :: sql.Db, from_agent_id :: Str, intent :: Str) -> [sql, fs_read] Result[Option[reg.AgentRef], Str] {
  match resolve(db, from_agent_id, intent) {
    Err(e) => Err(e),
    Ok(refs) => match refs {
      []       => Ok(None),
      [r | _]  => Ok(Some(r)),
    },
  }
}
