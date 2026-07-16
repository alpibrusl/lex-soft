# migrate.lex — full DDL for the lex-soft platform.
#
# Tables:
#   agents        — registered agents (truck, depot, tms, …)
#   relationships — directed graph: who is authorised to talk to whom
#   agent_state   — per-agent JSON state blob
#   traces        — append-only audit log

import "std.sql" as sql

import "lex-jobs/src/jobs" as jobs

fn ddl_agents() -> Str {
  "CREATE TABLE IF NOT EXISTS agents (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, inbox_url TEXT NOT NULL, capabilities_json TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL DEFAULT 'active', tenant TEXT NOT NULL DEFAULT 'default', registered_at TEXT NOT NULL, last_seen_at TEXT NOT NULL)"
}

fn ddl_agents_tenant_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_agents_tenant ON agents(tenant, kind)"
}

fn ddl_relationships() -> Str {
  "CREATE TABLE IF NOT EXISTS relationships (id TEXT PRIMARY KEY, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, role TEXT NOT NULL, contract_json TEXT NOT NULL DEFAULT '{}', active BIGINT NOT NULL DEFAULT 1, created_at TEXT NOT NULL)"
}

fn ddl_rel_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_rel_from ON relationships(from_agent, active)"
}

fn ddl_agent_state() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_state (agent_id TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at TEXT NOT NULL)"
}

fn ddl_traces() -> Str {
  "CREATE TABLE IF NOT EXISTS traces (id TEXT NOT NULL PRIMARY KEY, run_id TEXT NOT NULL, agent_id TEXT NOT NULL, event_kind TEXT NOT NULL, data_json TEXT, ts TEXT NOT NULL)"
}

fn ddl_traces_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_traces_agent_ts ON traces(agent_id, ts)"
}

# Durable per-agent memory: facts the agent should remember across conversations
# (preferences, assignments, lessons), recalled into the system prompt each turn.
#
# Columns beyond the original (id, agent_id, fact, ts) implement the 2026 agent-
# memory patterns adapted to our lightweight (no-vector-DB) case:
#   mkey       — structured key for keyed upsert (e.g. "home_depot"); '' = keyless
#   mtype      — semantic | episodic | procedural (memory typing)
#   importance — high | medium | low (recall ordering, no embeddings needed)
#   scope      — composable scope (e.g. tenant/subject); 'global' = all contexts
#   superseded — 1 when replaced by a newer keyed value (temporal supersession:
#                keep history for "what was true when", recall only current)
#   expires_at — optional ISO ts; expired facts drop out of recall (staleness)
#   updated_at — last write time
fn ddl_agent_memory() -> Str {
  "CREATE TABLE IF NOT EXISTS agent_memory (id TEXT NOT NULL PRIMARY KEY, agent_id TEXT NOT NULL, fact TEXT NOT NULL, ts TEXT NOT NULL, mkey TEXT NOT NULL DEFAULT '', mtype TEXT NOT NULL DEFAULT 'semantic', importance TEXT NOT NULL DEFAULT 'medium', scope TEXT NOT NULL DEFAULT 'global', superseded BIGINT NOT NULL DEFAULT 0, expires_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '')"
}

fn ddl_agent_memory_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_agent_memory_agent ON agent_memory(agent_id, ts)"
}

fn ddl_agent_memory_key_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_agent_memory_key ON agent_memory(agent_id, scope, mkey, superseded)"
}

# Control-plane identity (#59): the persistent customer principal and the agent
# credentials it issues. `accounts.org` is the mesh/registry join key (#26);
# `credentials.jti` mirrors the minted conn-token jti so a presented token
# resolves back to its account (identity.resolve_subject).
fn ddl_accounts() -> Str {
  "CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY, org TEXT NOT NULL, name TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'active', plan TEXT NOT NULL DEFAULT 'free', created_at TEXT NOT NULL)"
}

fn ddl_accounts_org_idx() -> Str {
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_accounts_org ON accounts(org)"
}

fn ddl_credentials() -> Str {
  "CREATE TABLE IF NOT EXISTS credentials (id TEXT PRIMARY KEY, account TEXT NOT NULL, org TEXT NOT NULL, agent_id TEXT NOT NULL, scope TEXT NOT NULL DEFAULT '', jti TEXT NOT NULL, revoked BIGINT NOT NULL DEFAULT 0, created_at TEXT NOT NULL)"
}

fn ddl_credentials_jti_idx() -> Str {
  "CREATE UNIQUE INDEX IF NOT EXISTS idx_credentials_jti ON credentials(jti)"
}

fn ddl_credentials_account_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_credentials_account ON credentials(account)"
}

# Onboarding rate limit (#62): a fixed-window (hour-bucket) counter per
# requesting org, bumped on every POST /connections. Best-effort protection,
# not a security boundary — see federation.rate_limited.
fn ddl_connection_rate() -> Str {
  "CREATE TABLE IF NOT EXISTS connection_rate (org TEXT NOT NULL, \"window\" TEXT NOT NULL, count BIGINT NOT NULL DEFAULT 0, PRIMARY KEY (org, \"window\"))"
}

# Notification bus (#64): per-account delivery channels + an outbox. A serve
# handler ENQUEUES (sql only); a sidecar delivers (outbound http, like the
# scheduler). Channels are account-scoped so a customer only ever configures
# and sees its own; each notification carries its account so delivery can look
# up that account's channels and /notifications can scope by the credential.
fn ddl_notify_channels() -> Str {
  "CREATE TABLE IF NOT EXISTS notify_channels (id TEXT PRIMARY KEY, account TEXT NOT NULL, ctype TEXT NOT NULL DEFAULT 'webhook', target TEXT NOT NULL, active BIGINT NOT NULL DEFAULT 1, created_at TEXT NOT NULL)"
}

fn ddl_notify_channels_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_notify_channels_account ON notify_channels(account, active)"
}

fn ddl_notifications() -> Str {
  "CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY, account TEXT NOT NULL, event_type TEXT NOT NULL, payload_json TEXT NOT NULL DEFAULT '{}', status TEXT NOT NULL DEFAULT 'pending', attempts BIGINT NOT NULL DEFAULT 0, response_code BIGINT NOT NULL DEFAULT 0, created_at TEXT NOT NULL, delivered_at TEXT NOT NULL DEFAULT '')"
}

fn ddl_notifications_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_notifications_pending ON notifications(status, created_at)"
}

fn ddl_notifications_acct_idx() -> Str {
  "CREATE INDEX IF NOT EXISTS idx_notifications_account ON notifications(account, created_at)"
}

fn exec_ddl(db :: Db, stmt :: Str) -> [sql, fs_write] Result[Unit, Str] {
  match sql.exec(db, stmt, []) {
    Err(e) => Err(e.message),
    Ok(_) => Ok(()),
  }
}

fn exec_ddl_tolerant(db :: Db, stmt :: Str) -> [sql, fs_write] Unit {
  let __ignore := sql.exec(db, stmt, [])
  ()
}

fn run(db :: Db) -> [sql, fs_write] Result[Unit, Str] {
  match exec_ddl(db, ddl_agents()) {
    Err(e) => Err(e),
    Ok(_) => match exec_ddl(db, ddl_relationships()) {
      Err(e) => Err(e),
      Ok(_) => match exec_ddl(db, ddl_rel_idx()) {
        Err(e) => Err(e),
        Ok(_) => match exec_ddl(db, ddl_agent_state()) {
          Err(e) => Err(e),
          Ok(_) => match exec_ddl(db, ddl_traces()) {
            Err(e) => Err(e),
            Ok(_) => match exec_ddl(db, ddl_traces_idx()) {
              Err(e) => Err(e),
              Ok(_) => {
                let __tenant := exec_ddl_tolerant(db, "ALTER TABLE agents ADD COLUMN tenant TEXT NOT NULL DEFAULT 'default'")
                let __tenant_idx := exec_ddl_tolerant(db, ddl_agents_tenant_idx())
                let __m := exec_ddl_tolerant(db, "ALTER TABLE traces ADD COLUMN run_id TEXT NOT NULL DEFAULT ''")
                let __mem := exec_ddl_tolerant(db, ddl_agent_memory())
                let __memi := exec_ddl_tolerant(db, ddl_agent_memory_idx())
                let __mc1 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN mkey TEXT NOT NULL DEFAULT ''")
                let __mc2 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN mtype TEXT NOT NULL DEFAULT 'semantic'")
                let __mc3 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN importance TEXT NOT NULL DEFAULT 'medium'")
                let __mc4 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN scope TEXT NOT NULL DEFAULT 'global'")
                let __mc5 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN superseded BIGINT NOT NULL DEFAULT 0")
                let __mc6 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN expires_at TEXT NOT NULL DEFAULT ''")
                let __mc7 := exec_ddl_tolerant(db, "ALTER TABLE agent_memory ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''")
                let __memk := exec_ddl_tolerant(db, ddl_agent_memory_key_idx())
                let __acc := exec_ddl_tolerant(db, ddl_accounts())
                let __acci := exec_ddl_tolerant(db, ddl_accounts_org_idx())
                let __cred := exec_ddl_tolerant(db, ddl_credentials())
                let __credi := exec_ddl_tolerant(db, ddl_credentials_jti_idx())
                let __credai := exec_ddl_tolerant(db, ddl_credentials_account_idx())
                let __connrate := exec_ddl_tolerant(db, ddl_connection_rate())
                let __nchan := exec_ddl_tolerant(db, ddl_notify_channels())
                let __nchani := exec_ddl_tolerant(db, ddl_notify_channels_idx())
                let __notif := exec_ddl_tolerant(db, ddl_notifications())
                let __notifi := exec_ddl_tolerant(db, ddl_notifications_idx())
                let __notifai := exec_ddl_tolerant(db, ddl_notifications_acct_idx())
                jobs.init_schema(db)
              },
            },
          },
        },
      },
    },
  }
}

