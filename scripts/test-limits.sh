# Shared by scripts/test-elixir.sh and scripts/test-python.sh; sourced, not run.
#
# Every test run gets:
#   - a hard time limit for the whole run, build included: TEST_TIME_LIMIT
#     seconds (default 2400). Past it the run is stopped and the script exits
#     with status 124;
#   - a log that is kept: $TEST_LOG_DIR/<suite>-<timestamp>.log (default
#     local-docs/test-logs, untracked), its path printed at the start and the end;
#   - a progress line every 30 seconds of wall-clock time, with the elapsed
#     time and the log's last line, so a run that hangs shows as a hang.
#
# The caller runs each long step in the background with its output appended to
# "$LOG" and waits for it with `supervise`.

TEST_TIME_LIMIT="${TEST_TIME_LIMIT:-2400}"
TEST_LOG_DIR="${TEST_LOG_DIR:-local-docs/test-logs}"
PROGRESS_EVERY=30

# Prints to the terminal and the log. Used while no tailer is showing the log.
banner() {
  [ -s "$LOG" ] && [ -n "$(tail -c 1 "$LOG")" ] && printf '\n' >>"$LOG"
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" | tee -a "$LOG"
}

# Appends to the log on a line of its own (ExUnit's dots leave the last line
# open); the tailer shows it on the terminal.
note() {
  [ -n "$(tail -c 1 "$LOG")" ] && printf '\n' >>"$LOG"
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >>"$LOG"
}

# open_log SUITE: creates the log, starts the clock and the tailer.
open_log() {
  mkdir -p "$TEST_LOG_DIR"
  LOG="$TEST_LOG_DIR/$1-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG"
  STARTED=$(date +%s)
  NEXT_PROGRESS=$((STARTED + PROGRESS_EVERY))
  banner "Log: $LOG (time limit ${TEST_TIME_LIMIT}s, TEST_TIME_LIMIT to change it)"
  tail -n 0 -f "$LOG" &
  TAILER=$!
}

# close_log STATUS: stops the tailer and prints how the run ended and where its log is.
close_log() {
  sleep 1
  stop_tailer
  banner "Finished with exit status $1 after $(($(date +%s) - STARTED))s. Log kept: $LOG"
}

stop_tailer() {
  [ -n "${TAILER:-}" ] || return 0
  kill "$TAILER" 2>/dev/null
  wait "$TAILER" 2>/dev/null
  TAILER=""
}

last_line() {
  tail -c 2000 "$LOG" | grep -v '^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] ' | tail -n 1 | cut -c1-120
}

# Once a second while a step runs: a progress line when one is due. Fails once
# the time limit has passed.
tick() {
  now=$(date +%s)
  if [ "$now" -ge "$NEXT_PROGRESS" ]; then
    NEXT_PROGRESS=$((NEXT_PROGRESS + PROGRESS_EVERY))
    note "progress: $((now - STARTED))s of ${TEST_TIME_LIMIT}s; last output: $(last_line)"
  fi
  [ $((now - STARTED)) -lt "$TEST_TIME_LIMIT" ]
}

# supervise PID [CHECK]: waits for PID, ticking once a second. Returns PID's
# exit status; 124 when the time limit passed; 125 when CHECK, a function run
# once a second, failed. On 124 and 125 PID is still running: the caller stops it.
supervise() {
  pid=$1
  check=${2:-}
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    tick || return 124
    if [ -n "$check" ] && ! "$check"; then return 125; fi
  done
  wait "$pid"
}

# stop_run CONTAINER PID: stops the run's container and the compose client
# that started it.
stop_run() {
  docker stop "$1" >/dev/null 2>&1
  kill "$2" 2>/dev/null
  wait "$2" 2>/dev/null
}

time_limit_reached() {
  note "TIME LIMIT: ${TEST_TIME_LIMIT}s reached. Stopping the run; its log is kept."
}
