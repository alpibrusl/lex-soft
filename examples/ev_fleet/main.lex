# main.lex — boot the EV-fleet.
#
# Wires lex-web + lex-soft + four agents into one `lex serve`.
#
# Run:
#   lex run --allow-effects io,net,time,sql,fs_write main.lex main

import "std.net"      as net
import "std.io"       as io
import "std.sql"      as sql
import "std.str"      as str
import "std.int"      as int
import "std.datetime" as datetime
import "std.crypto"   as crypto

import "lex-web/ctx"      as ctx
import "lex-web/response" as resp
import "lex-web/router"   as router
import "lex-web/body"     as body

import "lex-soft/agent"        as soft_agent
import "lex-soft/runner"       as runner
import "lex-soft/migrate"      as migrate
import "lex-soft/state_store"  as state_store
import "lex-soft/trace"        as trace
import "lex-soft/message"      as message
import "lex-soft/a2a"          as a2a

import "./peers"             as peers
import "./agents/vehicle"    as vehicle
import "./agents/depot"      as depot
import "./agents/pv"         as pv
import "./agents/tms"        as tms

fn agent_defs() -> List[soft_agent.AgentDef] {
  [
    { name: vehicle.name(),
      initial_state_json: vehicle.initial_state_json(),
      dispatch: vehicle.dispatch_and_gate },
    { name: depot.name(),
      initial_state_json: depot.initial_state_json(),
      dispatch: depot.dispatch_and_gate },
    { name: pv.name(),
      initial_state_json: pv.initial_state_json(),
      dispatch: pv.dispatch_and_gate },
    { name: tms.name(),
      initial_state_json: tms.initial_state_json(),
      dispatch: tms.dispatch_and_gate },
  ]
}

# A second depot peer (with smaller budget) for the fallback path.
fn depot2_def() -> soft_agent.AgentDef {
  { name: "depot2",
    initial_state_json: "current_kw=180.0;budget_kw=200.0;pv_kw=5.0;requested_kw=50.0",
    dispatch: depot.dispatch_and_gate }
}

fn new_run_id() -> [time, rand] Str {
  # 16 hex chars from a SHA-256 of (now, random) — opaque, sortable enough
  let now := datetime.now_ms()
  let h   := crypto.sha256_hex(str.concat("run-", int.to_str(now)))
  str.substring(h, 0, 16)
}

fn build_router(deps :: soft_agent.Deps) -> router.Router {
  let r0 := router.new()
  let r1 := list.fold(agent_defs(), r0, fn (r :: router.Router, d :: soft_agent.AgentDef) -> router.Router {
    soft_agent.mount(r, d, deps)
  })
  let r2 := soft_agent.mount(r1, depot2_def(), deps)
  r2 |> fn (r :: router.Router) -> router.Router {
          router.route(r, "POST", "/agents/pv/tick", make_tick_handler(deps))
        }
     |> fn (r :: router.Router) -> router.Router {
          router.route(r, "GET", "/traces", make_traces_handler(deps))
        }
     |> fn (r :: router.Router) -> router.Router {
          router.route(r, "GET", "/health", fn (_c :: ctx.Ctx) -> resp.Response {
            resp.json("{\"ok\":true}")
          })
        }
}

fn make_tick_handler(deps :: soft_agent.Deps) ->
  (ctx.Ctx) -> [io, time, sql, net, fs_write] resp.Response {
  fn (_c :: ctx.Ctx) -> [io, time, sql, net, fs_write] resp.Response {
    let msg := message.new("runner", "Tick", "{}")
    match runner.step(deps.db, deps.run_id, pv.name(),
                      pv.initial_state_json(), pv.dispatch_and_gate,
                      deps.peers, msg) {
      Err(e) => resp.internal_error_msg(e),
      Ok(_)  => resp.json("{\"ticked\":true}"),
    }
  }
}

fn make_traces_handler(deps :: soft_agent.Deps) ->
  (ctx.Ctx) -> [io, time, sql, fs_write] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, sql, fs_write] resp.Response {
    let agent := ctx.query_param_or(c, "agent", "vehicle")
    match trace.for_agent(deps.db, agent, 100) {
      Err(e)   => resp.internal_error_msg(e),
      Ok(rows) => resp.json(serialize_rows(rows)),
    }
  }
}

fn serialize_rows(
  rows :: List[{ ts_ms :: Int, kind :: Str, target :: Str, input_json :: Str, output_json :: Str, error :: Str }],
) -> Str {
  let body := list.fold(rows, "", fn (acc :: Str, r) -> Str {
    let row := str.concat("{\"ts_ms\":", int.to_str(r.ts_ms))
               |> fn (s :: Str) -> Str { str.concat(s, ",\"kind\":\"") }
               |> fn (s :: Str) -> Str { str.concat(s, r.kind) }
               |> fn (s :: Str) -> Str { str.concat(s, "\",\"target\":\"") }
               |> fn (s :: Str) -> Str { str.concat(s, r.target) }
               |> fn (s :: Str) -> Str { str.concat(s, "\"}") }
    if str.is_empty(acc) { row } else { str.concat(acc, str.concat(",", row)) }
  })
  str.concat("[", str.concat(body, "]"))
}

fn dispatch_request(
  rtr :: router.Router,
  req :: ctx.RawRequest,
) -> [io, time, sql, net, fs_write] resp.Response {
  router.dispatch(rtr, req)
}

fn main() -> [net, io, time, sql, fs_write, rand] Nil {
  match sql.open("lex-soft.sqlite") {
    Err(e) => io.print(str.concat("failed to open db: ", sql.error_msg(e))),
    Ok(db) => {
      match migrate.run(db) {
        Err(e) => io.print(str.concat("migration failed: ", sql.error_msg(e))),
        Ok(_)  => {
          let deps := { db: db,
                        run_id: new_run_id(),
                        peers: peers.local() }
          let rtr := build_router(deps)
          let _ := io.print("lex-soft listening on :8080")
          net.serve_fn(8080, fn (req :: ctx.RawRequest) -> [io, time, sql, net, fs_write] resp.Response {
            dispatch_request(rtr, req)
          })
        },
      }
    },
  }
}
