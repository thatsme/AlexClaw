#!/bin/sh
# Runs the Elixir suite in the test stack, under the limits in
# scripts/test-limits.sh: a hard time limit (TEST_TIME_LIMIT, default 2400 s),
# a log kept in TEST_LOG_DIR (default local-docs/test-logs) and a progress line
# every 30 seconds.
#
# Without arguments it runs the whole suite on the freshly built test image.
# The run records the failed tests and, when none failed, the baseline for
# `mix test --stale`. It then keeps the image's build directory with those
# records in .test-cache/elixir (untracked).
#
# With arguments it is a targeted run: the arguments go to `mix test` (test
# files, `--failed`, `--stale`), and the build directory comes from
# .test-cache/elixir, so only the modules changed since compile again and
# `--failed` / `--stale` see the previous run's records. The cache starts from
# the image's build when empty. `rm -rf .test-cache` resets it.
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
CACHE_DIR=".test-cache/elixir"

# The cache is mounted at the same depth as _build/test, so the relative links
# mix keeps in a build directory (a dependency's priv/ into deps/) resolve the
# same way; MIX_BUILD_PATH points mix at it for targeted runs.
CACHE_MOUNT="/app/_build/cached"

# The whole suite. With no stale manifest in a fresh build, `--stale` runs
# every test and, when none fails, writes the baseline. The cache is emptied on
# the host before the run; the container only copies into it.
FULL_RUN='mix ecto.create && mix ecto.migrate && mix test --stale; rc=$?
cp -a _build/test/. '"$CACHE_MOUNT"'/
exit $rc'

# A targeted run on the cached build directory.
TARGETED_RUN='if [ ! -f '"$CACHE_MOUNT"'/lib/alex_claw/.mix/compile.elixir ]; then
  cp -a _build/test/. '"$CACHE_MOUNT"'/
fi
export MIX_BUILD_PATH='"$CACHE_MOUNT"'
mix ecto.create && mix ecto.migrate && mix test "$@"'

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
mkdir -p "$DUMP_DIR" "$CACHE_DIR"
if [ "$#" -eq 0 ]; then
  note "Whole suite on the fresh image; its build is kept in $CACHE_DIR."
  rm -rf "${CACHE_DIR:?}" && mkdir -p "$CACHE_DIR"
  set -- sh -c "$FULL_RUN"
else
  note "Targeted run on the build in $CACHE_DIR: mix test $*"
  set -- sh -c "$TARGETED_RUN" targeted "$@"
fi

# openbao-test-init too: its image holds init.sh, and so the policy.
$COMPOSE build --quiet test-elixir openbao-test-init >>"$LOG" 2>&1 &
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
  -v "$PWD/$CACHE_DIR:$CACHE_MOUNT" \
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
