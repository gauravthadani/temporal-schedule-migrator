#!/usr/bin/env bash
# Create a matrix of schedules on the local Temporal server to exercise the
# migration script — focused on payload and spec variations.
#
# Usage: ./seed_schedules.sh [--clean]
#   --clean   delete every schedule whose ID starts with "demo-"

set -euo pipefail

ADDR="${LOCAL_ADDRESS:-localhost:7233}"
NS="${LOCAL_NAMESPACE:-default}"
T=( temporal --address "$ADDR" --namespace "$NS" )
TQ="demo-task-queue"
WF="DemoWorkflow"

mk() {
  local id="$1"; shift
  echo "creating $id"
  # Best-effort delete first so seeding is idempotent. `temporal schedule
  # delete` has no --yes flag — it deletes without confirmation and errors
  # with "not found" if the schedule isn't there, which we swallow.
  local del_out
  if ! del_out=$("${T[@]}" schedule delete --schedule-id "$id" 2>&1); then
    if ! grep -qi "not found\|no such\|does not exist" <<<"$del_out"; then
      echo "  (delete warning: $del_out)" >&2
    fi
  fi
  "${T[@]}" schedule create \
    --schedule-id "$id" \
    --type "$WF" --task-queue "$TQ" \
    "$@"
}

if [[ "${1:-}" == "--clean" ]]; then
  "${T[@]}" schedule list -o json \
    | jq -r 'if type=="array" then .[] else . end | .scheduleId // .ScheduleId' \
    | grep '^demo-' \
    | xargs -I{} "${T[@]}" schedule delete --schedule-id {} || true
  exit 0
fi

# ---------- payload variations ----------

# no input
mk demo-payload-none --interval 1h

# single string input
mk demo-payload-string --interval 1h --input '"hello world"'

# single integer input
mk demo-payload-int --interval 1h --input '42'

# single object input
mk demo-payload-object --interval 1h \
  --input '{"user":"alice","roles":["admin","dev"],"active":true}'

# multiple positional inputs (mix of types)
mk demo-payload-multi --interval 1h \
  --input '{"id":1}' \
  --input '"second"' \
  --input '3.14'

# deeply nested object
mk demo-payload-nested --interval 1h \
  --input '{"a":{"b":{"c":{"d":[1,2,3],"e":null}}}}'

# array as top-level input
mk demo-payload-array --interval 1h \
  --input '[{"k":"v"},{"k":"v2"}]'

# ---------- spec variations ----------

# plain interval
mk demo-spec-interval --interval 30m

# interval with phase offset
mk demo-spec-interval-phased --interval 1h/10m

# multiple intervals
mk demo-spec-interval-multi --interval 30m --interval 45m

# cron string
mk demo-spec-cron --cron "0 9 * * MON-FRI"

# named cron shortcut
mk demo-spec-cron-shortcut --cron "@hourly"

# single JSON calendar
mk demo-spec-calendar --calendar '{"dayOfWeek":"Fri","hour":"17","minute":"30"}'

# multiple calendars
mk demo-spec-calendar-multi \
  --calendar '{"dayOfWeek":"Mon","hour":"9"}' \
  --calendar '{"dayOfWeek":"Wed","hour":"9"}' \
  --calendar '{"dayOfWeek":"Fri","hour":"9"}'

# calendar with timezone
mk demo-spec-calendar-tz \
  --calendar '{"hour":"9","minute":"0"}' \
  --time-zone "America/Toronto"

# calendar + jitter
mk demo-spec-calendar-jitter \
  --calendar '{"hour":"12"}' \
  --jitter 5m

# mixed: cron + interval + calendar on the same schedule
mk demo-spec-mixed \
  --cron "0 6 * * *" \
  --interval 4h \
  --calendar '{"dayOfWeek":"Sun","hour":"3"}'

# ---------- extras that exercise the round-trip ----------

# non-default overlap policy + catchup window + timeouts
mk demo-policy-buffer \
  --interval 1h \
  --overlap-policy BufferOne \
  --catchup-window 1h \
  --execution-timeout 10m \
  --run-timeout 5m

# memo + schedule-memo + notes + pause-on-failure
mk demo-metadata \
  --interval 1h \
  --input '{"note":"metadata smoke test"}' \
  --memo 'source="seed"' \
  --schedule-memo 'purpose="migration-test"' \
  --notes "Seeded by seed_schedules.sh" \
  --pause-on-failure

# ---------- cross-cluster migration edge cases ----------

# paused on creation — verifies state.paused survives round-trip
mk demo-state-paused --interval 1h --paused

# limited actions — verifies remaining_actions carries over
mk demo-state-limited --interval 15m --remaining-actions 5

# time-bounded window (future) — verifies start_time / end_time
FUTURE_START=$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')
FUTURE_END=$(date -u -v+8d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '+8 days' '+%Y-%m-%dT%H:%M:%SZ')
mk demo-window-bounded \
  --interval 1h \
  --start-time "$FUTURE_START" \
  --end-time "$FUTURE_END"

# non-default overlap policies beyond BufferOne
mk demo-overlap-cancel   --interval 30m --overlap-policy CancelOther
mk demo-overlap-allow-all --interval 30m --overlap-policy AllowAll

# custom workflow_id template — verifies id template survives
mk demo-workflow-id-template \
  --interval 1h \
  --workflow-id 'demo-{{.ScheduledStartTime}}'

# workflow-level search attribute — biggest real-world failure mode.
# Register the SA on the source (idempotent — swallow the "already exists" error).
# REMEMBER to also register it on the target namespace BEFORE migrating:
#   temporal operator search-attribute create --name CustomKeywordField --type Keyword
echo "registering CustomKeywordField search attribute on source"
"${T[@]}" operator search-attribute create \
  --name CustomKeywordField --type Keyword 2>/dev/null || true
mk demo-workflow-search-attr \
  --interval 1h \
  --search-attribute 'CustomKeywordField="migrator-test"'

# schedule-level memo only — currently silently dropped by the migrator
mk demo-schedule-memo-only \
  --interval 1h \
  --schedule-memo 'kind="schedule-level"'

# cron with inline CRON_TZ prefix — server parses timezone from the string
mk demo-cron-tz-prefix \
  --cron 'CRON_TZ=America/New_York 0 9 * * MON-FRI'

echo
echo "Seeded. Current schedules:"
"${T[@]}" schedule list
