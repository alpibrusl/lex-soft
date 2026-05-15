# agent.lex — AgentDef record + lex-web mounting helper.
#
# `mount(router, def, deps)` adds two routes per agent:
#   POST /agents/<name>/inbox  — receive A2A message, run step()
#   GET  /agents/<name>/state  — debug: read current state JSON
#
# `deps` carries the SQL handle, peer table, run_id (per process), and
# the dispatch function. They're closure-captured so the handler
# remains pure-arg.

import "lex-web/ctx"       as ctx
import "lex-web/response"  as resp
import "lex-web/router"    as router
import "lex-web/body"      as body
import "std.str"           as str
import "std.int"           as int

import "./message"     as message
import "./runner"      as runner
import "./state_store" as state_store
import "./a2a"         as a2a

type AgentDef = {
  name :: Str,
  initial_state_json :: Str,
  dispatch :: runner.Dispatch,
}

type Deps = {
  db :: sql.Db,
  run_id :: Str,
  peers :: List[a2a.Peer],
}

fn inbox_path(name :: Str) -> Str {
  str.concat("/agents/", str.concat(name, "/inbox"))
}

fn state_path(name :: Str) -> Str {
  str.concat("/agents/", str.concat(name, "/state"))
}

fn make_inbox_handler(def :: AgentDef, deps :: Deps) ->
  (ctx.Ctx) -> [io, time, sql, net, fs_write] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, sql, net, fs_write] resp.Response {
    match body.json_body(c) {
      Err(r) => r,
      Ok(j)  => {
        let env := message.new(
          ctx.json_field_str_or(j, "from",         "unknown"),
          ctx.json_field_str_or(j, "topic",        ""),
          ctx.json_field_str_or(j, "payload_json", ""))
        match runner.step(deps.db, deps.run_id, def.name,
                          def.initial_state_json, def.dispatch,
                          deps.peers, env) {
          Err(e) => resp.internal_error_msg(e),
          Ok(r)  =>
            resp.json(str.concat("{\"executed\":", str.concat(int.to_str(r.executed),
                       str.concat(",\"denied\":", str.concat(int.to_str(r.denied),
                       str.concat(",\"send_failures\":", str.concat(int.to_str(r.send_failures),
                       "}"))))))),
        }
      },
    }
  }
}

fn make_state_handler(def :: AgentDef, deps :: Deps) ->
  (ctx.Ctx) -> [io, time, sql, fs_write] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, sql, fs_write] resp.Response {
    match state_store.load_or_init(deps.db, def.name, def.initial_state_json) {
      Err(e)         => resp.internal_error_msg(e),
      Ok(state_json) => resp.json(state_json),
    }
  }
}

fn mount(
  r :: router.Router,
  def :: AgentDef,
  deps :: Deps,
) -> router.Router {
  r |> fn (rr :: router.Router) -> router.Router {
         router.route(rr, "POST", inbox_path(def.name),
                      make_inbox_handler(def, deps))
       }
    |> fn (rr :: router.Router) -> router.Router {
         router.route(rr, "GET", state_path(def.name),
                      make_state_handler(def, deps))
       }
}
