# tms.lex — transport-management terminal sink.
#
# Receives Acknowledge / Complete / Failed from the vehicle and does
# nothing in this minimal demo. Keeps a `running` flag to demonstrate
# stateful no-ops.

import "std.list" as list

import "lex-soft/action"  as action
import "lex-soft/message" as message
import "lex-soft/gate"    as gate
import "lex-soft/runner"  as runner

type State = { running :: Bool }

fn name() -> Str { "tms" }

fn initial_state_json() -> Str { "running=true" }

fn decode(_s :: Str) -> State { { running: true } }
fn encode(_s :: State) -> Str { "running=true" }

fn dispatch_and_gate(state_json :: Str, _m :: message.Message) -> runner.DispatchOutput {
  { new_state_json: state_json, gated: [] }
}
