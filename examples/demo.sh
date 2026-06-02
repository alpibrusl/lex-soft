#!/usr/bin/env bash
# demo.sh — seeds the running platform server with EV-fleet demo data.
#
# Usage: ./examples/demo.sh [PLATFORM_URL]
# Default PLATFORM_URL: http://localhost:9000

set -euo pipefail

BASE="${1:-http://localhost:9000}"

ok()  { printf "\033[32m✓\033[0m  %s\n" "$1"; }
hdr() { printf "\n\033[34m▶ %s\033[0m\n" "$1"; }
post() {
  curl -sf -X POST -H "Content-Type: application/json" -d "$2" "$BASE$1"
}
get() {
  curl -sf "$BASE$1"
}

hdr "Registering agents"

post /v1/agents '{"id":"tms-primary","kind":"tms","name":"TMS Primary","inbox_url":"http://localhost:8120","capabilities":["dispatch"]}' > /dev/null && ok "tms-primary"
post /v1/agents '{"id":"tms-secondary","kind":"tms","name":"TMS Secondary","inbox_url":"http://localhost:8121","capabilities":["dispatch"]}' > /dev/null && ok "tms-secondary"
post /v1/agents '{"id":"depot-north","kind":"depot","name":"Depot North","inbox_url":"http://localhost:8110","capabilities":["charging"]}' > /dev/null && ok "depot-north"
post /v1/agents '{"id":"depot-south","kind":"depot","name":"Depot South","inbox_url":"http://localhost:8111","capabilities":["charging"]}' > /dev/null && ok "depot-south"
post /v1/agents '{"id":"depot-east","kind":"depot","name":"Depot East","inbox_url":"http://localhost:8112","capabilities":["charging"]}' > /dev/null && ok "depot-east"
post /v1/agents '{"id":"depot-west","kind":"depot","name":"Depot West","inbox_url":"http://localhost:8113","capabilities":["charging"]}' > /dev/null && ok "depot-west"

for n in $(seq -w 01 20); do
  post /v1/agents "{\"id\":\"truck-$n\",\"kind\":\"truck\",\"name\":\"Truck $n\",\"inbox_url\":\"\",\"capabilities\":[\"transport\"]}" > /dev/null && ok "truck-$n"
done

hdr "Sending heartbeats"

for id in tms-primary tms-secondary depot-north depot-south depot-east depot-west; do
  post "/v1/agents/$id/heartbeat" '{}' > /dev/null && ok "$id"
done
for n in $(seq -w 01 20); do
  post "/v1/agents/truck-$n/heartbeat" '{}' > /dev/null
done
ok "trucks 01-20"

hdr "Simulating message traffic"

post /v1/messages '{"from":"truck-01","to":"tms-primary","topic":"dispatch_request","body":"{\"load\":\"LDN-AMS-001\",\"eta\":\"2026-06-02T18:00Z\"}"}' > /dev/null && ok "truck-01 → tms-primary (dispatch_request)"
post /v1/messages '{"from":"truck-07","to":"depot-south","topic":"charge_request","body":"{\"soc\":18,\"target_soc\":90}"}' > /dev/null && ok "truck-07 → depot-south (charge_request)"
post /v1/messages '{"from":"tms-primary","to":"truck-03","topic":"assignment","body":"{\"job\":\"JOB-882\",\"pickup\":\"Rotterdam\"}"}' > /dev/null && ok "tms-primary → truck-03 (assignment)"
post /v1/messages '{"from":"truck-15","to":"depot-east","topic":"charge_request","body":"{\"soc\":9,\"target_soc\":80}"}' > /dev/null && ok "truck-15 → depot-east (charge_request)"
post /v1/messages '{"from":"depot-north","to":"tms-secondary","topic":"capacity_report","body":"{\"free_bays\":4}"}' > /dev/null && ok "depot-north → tms-secondary (capacity_report)"
post /v1/messages '{"from":"truck-12","to":"tms-secondary","topic":"dispatch_request","body":"{\"load\":\"AMS-BER-007\"}"}' > /dev/null && ok "truck-12 → tms-secondary (dispatch_request)"

hdr "Saving some state blobs"

post /v1/state/truck-01 '{"state":"{\"soc\":72,\"location\":\"51.5074,-0.1278\",\"status\":\"en_route\"}"}' > /dev/null && ok "truck-01 state"
post /v1/state/truck-07 '{"state":"{\"soc\":18,\"location\":\"48.8566,2.3522\",\"status\":\"charging\"}"}' > /dev/null && ok "truck-07 state"
post /v1/state/tms-primary '{"state":"{\"active_jobs\":14,\"pending\":3}"}' > /dev/null && ok "tms-primary state"

hdr "Done — open http://localhost:9000/ to see the dashboard"
