#!/bin/sh
# Runs the web automator's Python suite in the test stack, under the limits in
# scripts/test-limits.sh: a hard time limit (TEST_TIME_LIMIT, default 2400 s),
# a log kept in TEST_LOG_DIR (default local-docs/test-logs) and a progress line
# every 30 seconds.
#
# An argument, when given, replaces the command the container's `sh -c` runs
# (for example `scripts/test-python.sh 'cd /app && python -m pytest tests/test_x.py'`).
#
# Exit status: the suite's own, or 124 when the time limit stopped the run.

set -u

cd "$(dirname "$0")/.." || exit 1
. scripts/test-limits.sh

COMPOSE="docker compose -f docker-compose.test.yml"
CONTAINER="alexclaw-test-python-run-$$"

cleanup() {
  stop_tailer
  $COMPOSE down >/dev/null 2>&1
}
trap cleanup EXIT

open_log python

$COMPOSE build --quiet test-python >>"$LOG" 2>&1 &
build=$!
supervise "$build"
status=$?
if [ "$status" -eq 124 ]; then
  time_limit_reached
  kill "$build" 2>/dev/null
  close_log 124
  exit 124
fi
if [ "$status" -ne 0 ]; then
  note "The test image did not build."
  close_log "$status"
  exit "$status"
fi

$COMPOSE run --rm --name "$CONTAINER" test-python "$@" >>"$LOG" 2>&1 &
run=$!
supervise "$run"
status=$?
if [ "$status" -eq 124 ]; then
  time_limit_reached
  stop_run "$CONTAINER" "$run"
fi

close_log "$status"
exit "$status"
