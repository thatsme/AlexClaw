#!/bin/sh
# The one way to run the whole elixir suite: a gate (.claude/rules/20-tests.md) —
# once when a stage is done, before a deploy, before a push. The log says GATE.
# On macOS the run holds off idle and system sleep (caffeinate): a sleeping Mac
# freezes the containers and the run is stopped at its time limit, though no
# test hung. A closed lid on battery still sleeps.
cd "$(dirname "$0")/.." || exit 1
if [ "$(uname -s)" = Darwin ] && command -v caffeinate >/dev/null 2>&1; then
  GATE=1 exec caffeinate -dimsu ./scripts/test-elixir.sh
fi
GATE=1 exec ./scripts/test-elixir.sh
