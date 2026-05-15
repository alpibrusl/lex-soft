# runner.lex — step() dispatch loop.
#
# The runner is generic over agents. Each agent module exports a
# `dispatch_and_gate` function that takes the current state JSON + the
# incoming message, returns the new state plus a list of
# `GatedAction { action, verdict }` records. The runner persists state,
# executes Allow'd actions, and appends trace rows for every step.

import "std.list" as list
import "std.str"  as str

import "./action"      as action
import "./message"     as message
import "./gate"        as gate
import "./state_store" as state_store
import "./trace"       as trace
import "./a2a"         as a2a

type GatedAction = { action :: action.Action, verdict :: gate.Verdict }

type DispatchOutput = {
  new_state_json :: Str,
  gated :: List[GatedAction],
}

# Per-agent dispatch_and_gate signature. The agent module is free to
# parse/typecheck `state_json` and `msg.payload_json` however it likes.
type Dispatch = (Str, message.Message) -> DispatchOutput

type StepResult = { executed :: Int, denied :: Int, send_failures :: Int }

fn step(
  db :: sql.Db,
  run_id :: Str,
  agent :: Str,
  initial_state_json :: Str,
  dispatch :: Dispatch,
  peers :: List[a2a.Peer],
  msg :: message.Message,
) -> [sql, net, time, fs_write] Result[StepResult, Str] {
  match state_store.load_or_init(db, agent, initial_state_json) {
    Err(e) => Err(e),
    Ok(state_json) => {
      let _ := trace.append(db, run_id, agent, "a2a", "received",
                            msg.payload_json, "", "")
      let out := dispatch(state_json, msg)
      let _ := trace.append(db, run_id, agent, "state", "proposed",
                            out.new_state_json, "", "")
      let exec_result := list.fold(
        out.gated,
        { executed: 0, denied: 0, send_failures: 0 },
        fn (acc :: StepResult, g :: GatedAction) -> StepResult {
          match g.verdict {
            gate.Allow => {
              let outcome := a2a.send(peers, agent, g.action)
              let _ := trace.append(db, run_id, agent, "action", "executed",
                                    action.payload(g.action),
                                    "",
                                    if outcome.ok { "" } else { outcome.detail })
              if outcome.ok {
                { executed: acc.executed + 1, denied: acc.denied,
                  send_failures: acc.send_failures }
              } else {
                { executed: acc.executed, denied: acc.denied,
                  send_failures: acc.send_failures + 1 }
              }
            },
            gate.Deny({ spec, reason }) => {
              let _ := trace.append(db, run_id, agent, "gate", "denied",
                                    action.payload(g.action),
                                    str.concat(spec, str.concat(": ", reason)),
                                    reason)
              { executed: acc.executed, denied: acc.denied + 1,
                send_failures: acc.send_failures }
            },
          }
        })
      match state_store.save(db, agent, out.new_state_json) {
        Err(e) => Err(e),
        Ok(_)  => Ok(exec_result),
      }
    },
  }
}
