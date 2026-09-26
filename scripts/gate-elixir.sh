#!/bin/sh
# The one way to run the whole elixir suite: a gate (.claude/rules/20-tests.md) —
# once when a stage is done, before a deploy, before a push. The log says GATE.
cd "$(dirname "$0")/.." || exit 1
GATE=1 exec ./scripts/test-elixir.sh
