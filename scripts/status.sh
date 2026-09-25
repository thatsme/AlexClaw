#!/bin/sh
# Shows what is running for this checkout:
#   - the production compose project's containers (expected to run);
#   - the test stack's containers (compose project alexclaw-test);
#   - stray containers from this repository's images that compose did not
#     create (a `docker run` whose caller was stopped keeps running);
#   - make, mix, docker and test-script processes whose working directory is
#     this checkout.
#
# Exit status: 0 when nothing but production is running, 1 otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROD_PROJECT="alexclaw"
TEST_PROJECT="alexclaw-test"
left=0

containers() {
  docker ps -a --filter "label=com.docker.compose.project=$1" \
    --filter "label=com.docker.compose.config-hash" --format '{{.Names}}\t{{.Status}}\t{{.Image}}' | sed 's/^/  /'
}

section() {
  printf '%s\n' "$1"
  if [ -n "$2" ]; then printf '%s\n' "$2"; else echo "  none"; fi
}

section "Production ($PROD_PROJECT):" "$(containers "$PROD_PROJECT")"

test_stack=$(containers "$TEST_PROJECT")
section "Test stack ($TEST_PROJECT):" "$test_stack"
[ -n "$test_stack" ] && left=1

# Compose-created containers carry a config hash; a `docker run` of an image that
# compose built inherits the image's project label but not the hash.
strays=$(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.config-hash"}}' |
  awk -F '\t' -v p="$PROD_PROJECT" -v t="$TEST_PROJECT" \
    '$3 ~ /^alexclaw/ && ($5 == "" || ($4 != p && $4 != t)) { print "  " $1 "\t" $2 "\t" $3 }')
section "Stray containers from this repository's images:" "$strays"
[ -n "$strays" ] && left=1

procs=""
for pid in $(pgrep -f 'make|mix|docker|test-elixir\.sh|run_limited\.sh'); do
  [ "$pid" = "$$" ] && continue
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
  case "$cwd" in
    "$ROOT" | "$ROOT"/*)
      procs="$procs$(ps -o pid=,lstart=,command= -p "$pid" | cut -c1-160 | sed 's/^/  /')
"
      ;;
  esac
done
procs=$(printf '%s' "$procs" | grep -v -e 'scripts/status.sh' -e 'make status')
section "Background processes started from $ROOT:" "$procs"
[ -n "$procs" ] && left=1

if [ "$left" -eq 0 ]; then echo "Nothing left running besides production."; fi
exit "$left"
