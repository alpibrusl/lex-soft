# EV fleet — pure-lex port

Port of `soft/agents/{vehicle,depot,pv,tms}` and `soft/agents/{depot,vehicle}.spec`.
All four agents run in one `lex serve` process; A2A is HTTP (POST to
`/agents/<name>/inbox`); state and trace live in SQLite.

## Differences from the original

| In `soft`                          | Here                                       |
|------------------------------------|--------------------------------------------|
| Each agent had a separate process  | One process, one router per agent          |
| `.spec` files parsed by Rust       | `specs.lex` — pure-lex predicate functions |
| `--tick Tick=2s` runner flag       | `POST /agents/pv/tick` (manual for v1)     |
| Mailbox loop in `soft-runner`      | `lex serve` request handler                |
| `lex-store` JSON trace tree        | SQLite `traces` table                      |

## Run

```bash
# From this directory:
lex run --allow-effects io,net,time,sql,fs_write main.lex main

# In another terminal:
curl -X POST http://localhost:8080/agents/vehicle/inbox \
     -H 'content-type: application/json' \
     -d '{"from":"ops","topic":"Dispatch","payload_json":"{}"}'
curl http://localhost:8080/agents/vehicle/state
curl http://localhost:8080/traces?agent=vehicle
```

## Adversarial scenarios

The gate denies when its predicate is false:

```bash
# Force depot to deny by exceeding budget. The depot's seeded state has
# current_kw=180, budget_kw=200, pv_kw=10 — so a 50 kW request is over.
curl -X POST http://localhost:8080/agents/depot/inbox \
     -H 'content-type: application/json' \
     -d '{"from":"vehicle","topic":"RequestSession","payload_json":"{\"vehicle_id\":\"v-1\",\"power_kw\":50}"}'
# → handler proposes GrantSession; gate runs `depot_grid_budget`; verdict Deny.
#   The action is NOT sent; the trace records `gate.denied`.
```

The vehicle falls over to a second depot after the first denial — see
`agents/vehicle.lex`. After two denials it sends `Failed` to tms.
