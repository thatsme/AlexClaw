#!/bin/sh
# Runs the Elixir suite in the test stack, under the limits in
# scripts/test-limits.sh: a hard time limit (TEST_TIME_LIMIT, default 2400 s),
# a log kept in TEST_LOG_DIR (default local-docs/test-logs) and a progress line
# every 30 seconds.
#
# Arguments, when given, replace the test container's command (for example
# `scripts/test-elixir.sh mix test test/some_test.exs`).
#
# A run that hangs before any test starts is caught earlier: the suite prints
# "Running ExUnit with seed" once the first test is about to run, and if that
# line has not appeared within TEST_WATCHDOG_SECONDS (default 120) of the
# container starting, the run is stopped. On that watchdog and on the time
# limit, every BEAM in the container is first sent SIGUSR1, which makes it
# write a crash dump and halt. The dump is written straight to
# local-docs/erl_crash-<timestamp>.dump on the host (a bind mount, so it
# survives the container).
#
# Exit status: the suite's own, or 124 when the watchdog or the time limit
# stopped the run.

set -u

cd "$(dirname "$0")/.." || exit 1
. scripts/test-limits.sh

COMPOSE="docker compose -f docker-compose.test.yml"
CONTAINER="alexclaw-test-run-$$"
WATCHDOG="${TEST_WATCHDOG_SECONDS:-120}"
DUMP_DIR="local-docs"
DUMP_NAME="erl_crash-$(date +%Y%m%d-%H%M%S).dump"

cleanup() {
  stop_tailer
  $COMPOSE down >/dev/null 2>&1
}
trap cleanup EXIT

beam_pids() {
  docker exec "$CONTAINER" ps -o pid,comm 2>/dev/null | awk '$2 == "beam.smp" { print $1 }'
}

# Waits for the dump to exist and stop growing.
collect_dump() {
  target="$DUMP_DIR/$DUMP_NAME"
  last=-1
  for _ in $(seq 1 120); do
    size=$(wc -c <"$target" 2>/dev/null || echo -1)
    if [ "$size" -gt 0 ] && [ "$size" = "$last" ]; then
      note "Crash dump saved to $target"
      return 0
    fi
    last=$size
    sleep 1
  done
  note "No crash dump appeared at $target"
  return 1
}

dump_beams() {
  pids=$(beam_pids)
  if [ -z "$pids" ]; then
    note "No BEAM is running in $CONTAINER: no crash dump."
    return 0
  fi
  for pid in $pids; do docker exec "$CONTAINER" kill -USR1 "$pid"; done
  collect_dump
}

# Passes until the pre-test watchdog's time is up without a test having started.
tests_started=no
test_started_in_time() {
  [ "$tests_started" = yes ] && return 0
  if grep -q "Running ExUnit with seed" "$LOG"; then
    tests_started=yes
    return 0
  fi
  [ $(($(date +%s) - run_started)) -lt "$WATCHDOG" ]
}

stopped() {
  dump_beams
  stop_run "$CONTAINER" "$run"
  close_log 124
  exit 124
}

open_log elixir
mkdir -p "$DUMP_DIR"

$COMPOSE build --quiet test-elixir >>"$LOG" 2>&1 &
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

$COMPOSE run --rm --name "$CONTAINER" \
  -v "$PWD/$DUMP_DIR:/dumps" -e "ERL_CRASH_DUMP=/dumps/$DUMP_NAME" \
  test-elixir "$@" >>"$LOG" 2>&1 &
run=$!
run_started=$(date +%s)

supervise "$run" test_started_in_time
status=$?
case "$status" in
  124)
    time_limit_reached
    stopped
    ;;
  125)
    note "WATCHDOG: no test started within ${WATCHDOG}s. Dumping the BEAM and stopping the run."
    stopped
    ;;
esac

close_log "$status"
exit "$status"
