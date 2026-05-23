# registry.lex — agent registration and discovery.
#
# Every agent (truck, depot, tms, …) registers itself on boot, sends
# heartbeats to update last_seen_at, and can be looked up by id or kind.

import "std.sql" as sql
import "std.str" as str
import "std.time" as time
import "std.list" as list
import "lex-schema/json_value" as jv

type AgentRef = {
  id           :: Str,
  kind         :: Str,
  name         :: Str,
  inbox_url    :: Str,
  capabilities :: List[Str],
  status       :: Str,
}

fn row_to_ref(row :: List[sql.SqlValue]) -> Option[AgentRef] {
  match row {
    [SqlText(id), SqlText(kind), SqlText(name), SqlText(url), SqlText(caps), SqlText(status), _, _] => {
      let cap_list := match jv.parse(caps) {
        Ok(JArr(items)) => list.filter_map(items, fn (j :: jv.Json) -> Option[Str] {
          match j { JStr(s) => Some(s), _ => None }
        }),
        _ => [],
      }
      Some({ id: id, kind: kind, name: name, inbox_url: url, capabilities: cap_list, status: status })
    },
    _ => None,
  }
}

fn register(db :: sql.Db, id :: Str, kind :: Str, name :: Str, inbox_url :: Str, capabilities :: List[Str]) -> [sql, fs_write] Result[Unit, Str] {
  let now := time.now_iso()
  let caps_json := jv.stringify(JArr(list.map(capabilities, fn (c :: Str) -> jv.Json { JStr(c) })))
  let q := "INSERT INTO agents (id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at) \
            VALUES (?, ?, ?, ?, ?, 'active', ?, ?) \
            ON CONFLICT(id) DO UPDATE SET \
              name=excluded.name, inbox_url=excluded.inbox_url, \
              capabilities_json=excluded.capabilities_json, \
              status='active', last_seen_at=excluded.last_seen_at"
  match sql.exec(db, q, [PStr(id), PStr(kind), PStr(name), PStr(inbox_url), PStr(caps_json), PStr(now), PStr(now)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}

fn heartbeat(db :: sql.Db, id :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let now := time.now_iso()
  match sql.exec(db, "UPDATE agents SET last_seen_at=? WHERE id=?", [PStr(now), PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}

fn set_status(db :: sql.Db, id :: Str, status :: Str) -> [sql, fs_write] Result[Unit, Str] {
  let now := time.now_iso()
  match sql.exec(db, "UPDATE agents SET status=?, last_seen_at=? WHERE id=?", [PStr(status), PStr(now), PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(unit),
  }
}

fn find_by_id(db :: sql.Db, id :: Str) -> [sql, fs_read] Result[Option[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at FROM agents WHERE id=?"
  match sql.query(db, q, [PStr(id)]) {
    Err(e) => Err(e.message),
    Ok(rows) => match rows {
      []       => Ok(None),
      [r | _]  => Ok(row_to_ref(r)),
    },
  }
}

fn find_by_kind(db :: sql.Db, kind :: Str) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at FROM agents WHERE kind=? AND status='active'"
  match sql.query(db, q, [PStr(kind)]) {
    Err(e) => Err(e.message),
    Ok(rows) => Ok(list.filter_map(rows, fn (r :: List[sql.SqlValue]) -> Option[AgentRef] { row_to_ref(r) })),
  }
}

fn list_all(db :: sql.Db) -> [sql, fs_read] Result[List[AgentRef], Str] {
  let q := "SELECT id, kind, name, inbox_url, capabilities_json, status, registered_at, last_seen_at FROM agents ORDER BY kind, name"
  match sql.query(db, q, []) {
    Err(e) => Err(e.message),
    Ok(rows) => Ok(list.filter_map(rows, fn (r :: List[sql.SqlValue]) -> Option[AgentRef] { row_to_ref(r) })),
  }
}
