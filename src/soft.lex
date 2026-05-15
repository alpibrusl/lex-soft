# soft.lex — facade.
#
# Importing this single module exposes the runtime surface the EV-fleet
# example uses. Application code can import individual modules directly
# if it wants narrower effect annotations.

import "./action"      as action
import "./message"     as message
import "./gate"        as gate
import "./trace"       as trace
import "./state_store" as state_store
import "./migrate"     as migrate
import "./a2a"         as a2a
import "./runner"      as runner
import "./agent"       as agent
