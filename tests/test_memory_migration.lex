# tests/test_memory_migration.lex — lex-soft#136: agent_memory's columns
# moved from (fact, mkey) to lex-agent/src/memory's (content, key) naming, via
# migrate.lex's rename_agent_memory_columns. Every other test in this suite
# opens a FRESH `:memory:` db, so migrate.run's CREATE TABLE always produces
# the new shape directly — the RENAME path is never actually exercised. This
# file simulates a real pre-#136 production table (old column names, real
# data already in it), runs today's migrate.run against it, and proves the
# data survives the rename and is readable through the new trace.lex API —
# the one thing a fresh-db test suite structurally cannot catch.

import "std.sql" as sql

import "std.str" as str

import "std.list" as list

import "../src/migrate" as migrate

import "../src/trace" as trace

import "../src/dsr" as dsr

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(label)
  }
}

# The exact pre-#136 shape (see this repo's history: ddl_agent_memory before
# the lex-soft#136 migration), seeded with one row the way a real deployment
# would have it — including a non-empty `mkey`, so the RENAME must carry
# real keyed-fact data, not just an empty default.
fn seed_legacy_table(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, "CREATE TABLE agent_memory (id TEXT NOT NULL PRIMARY KEY, agent_id TEXT NOT NULL, fact TEXT NOT NULL, ts TEXT NOT NULL, mkey TEXT NOT NULL DEFAULT '', mtype TEXT NOT NULL DEFAULT 'semantic', importance TEXT NOT NULL DEFAULT 'medium', scope TEXT NOT NULL DEFAULT 'global', superseded BIGINT NOT NULL DEFAULT 0, expires_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '')", []) {
    Err(e) => Err(e.message),
    Ok(_) => match sql.exec(db, "INSERT INTO agent_memory (id, agent_id, fact, ts, mkey, mtype, importance, scope, superseded, expires_at, updated_at) VALUES ('m1', 'legacy-agent', 'prefers depot north', '2020-01-01T00:00:00Z', 'depot-pref', 'semantic', 'high', 'global', 0, '', '2020-01-01T00:00:00Z')", []) {
      Err(e) => Err(e.message),
      Ok(_) => Ok(()),
    },
  }
}

fn migration_preserves_and_renames_legacy_row() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match seed_legacy_table(db) {
      Err(e) => Err(e),
      Ok(_) => match migrate.run(db) {
        Err(e) => Err(e),
        Ok(_) => {
          let text := trace.recall_facts_text(db, "legacy-agent", 10)
          if str.contains(text, "depot-pref: prefers depot north") {
            let js := trace.recall_memory_json(db, "legacy-agent", 10)
            if str.contains(js, "prefers depot north") and str.contains(js, "depot-pref") {
              Ok(())
            } else {
              Err(str.concat("recall_memory_json lost the legacy row after migration: ", js))
            }
          } else {
            Err(str.concat("recall_facts_text lost the legacy row after migration: ", text))
          }
        },
      },
    },
  }
}

# A fresh write through the new API must coexist correctly with the
# migrated legacy row — same table, same agent, both readable together.
fn new_writes_coexist_with_migrated_legacy_rows() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match seed_legacy_table(db) {
      Err(e) => Err(e),
      Ok(_) => match migrate.run(db) {
        Err(e) => Err(e),
        Ok(_) => {
          let __w := trace.remember_kv(db, "legacy-agent", "global", "new-fact", "also prefers morning shifts", "semantic", "medium", "")
          let text := trace.recall_facts_text(db, "legacy-agent", 10)
          if str.contains(text, "depot-pref: prefers depot north") and str.contains(text, "new-fact: also prefers morning shifts") {
            Ok(())
          } else {
            Err(str.concat("legacy row and a fresh write did not coexist: ", text))
          }
        },
      },
    },
  }
}

# The keyed-upsert contract (supersede, not duplicate) must still hold for a
# key that was ALREADY present in the legacy row, post-migration — proves the
# renamed `key` column, not a stale `mkey`, is what store_kv's upsert lookup
# actually matches against.
fn upsert_against_a_migrated_key_supersedes_it() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match seed_legacy_table(db) {
      Err(e) => Err(e),
      Ok(_) => match migrate.run(db) {
        Err(e) => Err(e),
        Ok(_) => {
          let __w := trace.remember_kv(db, "legacy-agent", "global", "depot-pref", "now prefers depot south", "semantic", "high", "")
          let text := trace.recall_facts_text(db, "legacy-agent", 10)
          if str.contains(text, "depot-pref: now prefers depot south") and str.contains(text, "prefers depot north") == false {
            Ok(())
          } else {
            Err(str.concat("upsert against the migrated key did not supersede the legacy value: ", text))
          }
        },
      },
    },
  }
}

# dsr.lex's own SQL (subject_memory) must read the migrated table correctly
# too — it's a second, independent caller of the renamed columns.
fn dsr_subject_memory_reads_migrated_rows() -> [sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match sql.open(":memory:") {
    Err(_) => Err("db open failed"),
    Ok(db) => match seed_legacy_table(db) {
      Err(e) => Err(e),
      Ok(_) => match migrate.run(db) {
        Err(e) => Err(e),
        Ok(_) => {
          let rows := dsr.subject_memory(db, "legacy-agent")
          match list.head(rows) {
            None => Err("dsr.subject_memory found nothing after migration"),
            Some(r) => assert_true(r.content == "prefers depot north" and r.key == "depot-pref", str.concat("dsr.subject_memory misread the migrated row: content=", str.concat(r.content, str.concat(" key=", r.key)))),
          }
        },
      },
    },
  }
}

fn run_all() -> [sql, fs_read, fs_write, time, random, crypto] Unit {
  let results := [migration_preserves_and_renames_legacy_row(), new_writes_coexist_with_migrated_legacy_rows(), upsert_against_a_migrated_key_supersedes_it(), dsr_subject_memory_reads_migrated_rows()]
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

