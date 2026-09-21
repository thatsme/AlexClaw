#!/bin/sh
# Runs the Elixir suite in the test stack, with a watchdog for a run that hangs
# before any test starts.
#
# The suite prints "Running ExUnit with seed" once the first test is about to
# run. If that line has not appeared within TEST_WATCHDOG_SECONDS (default 120)
# of the container starting, every BEAM in the container is sent SIGUSR1, which
# makes it write a crash dump and halt. The dump is written straight to
# local-docs/erl_crash-<timestamp>.dump on the host (a bind mount, so it
# survives the container), and the run is stopped.
#
# Exit status: the suite's own, or 124 when the watchdog stopped the run.

set -u

COMPOSE="docker compose -f docker-compose.test.yml"
CONTAINER="alexclaw-test-run-$$"
LIMIT="${TEST_WATCHDOG_SECONDS:-120}"
LOG="$(mktemp)"
DUMP_DIR="local-docs"
DUMP_NAME="erl_crash-$(date +%Y%m%d-%H%M%S).dump"

cleanup() {
  rm -f "$LOG"
  $COMPOSE down >/dev/null 2>&1
}
trap cleanup EXIT

stop_tailer() {
  kill "$tailer" 2>/dev/null
  wait "$tailer" 2>/dev/null
}

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
      echo "Crash dump saved to $target"
      return 0
    fi
    last=$size
    sleep 1
  done
  echo "No crash dump appeared at $target" >&2
  return 1
}

watchdog_fired() {
  echo "Watchdog: no test started within ${LIMIT}s. Dumping the BEAM and stopping the run." >&2
  pids=$(beam_pids)
  if [ -z "$pids" ]; then
    echo "Watchdog: no BEAM is running in $CONTAINER." >&2
  else
    for pid in $pids; do docker exec "$CONTAINER" kill -USR1 "$pid"; done
    collect_dump
  fi
  docker stop "$CONTAINER" >/dev/null 2>&1
}

mkdir -p "$DUMP_DIR"
$COMPOSE build --quiet test-elixir || exit 1
$COMPOSE run --rm --name "$CONTAINER" \
  -v "$PWD/$DUMP_DIR:/dumps" -e "ERL_CRASH_DUMP=/dumps/$DUMP_NAME" \
  test-elixir >"$LOG" 2>&1 &
run=$!
tail -f "$LOG" &
tailer=$!

waited=0
while kill -0 "$run" 2>/dev/null && ! grep -q "Running ExUnit with seed" "$LOG"; do
  if [ "$waited" -ge "$LIMIT" ]; then
    watchdog_fired
    stop_tailer
    wait "$run" 2>/dev/null
    exit 124
  fi
  sleep 1
  waited=$((waited + 1))
done

wait "$run"
status=$?
sleep 1
stop_tailer
exit "$status"
