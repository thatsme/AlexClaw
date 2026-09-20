#!/bin/sh
# Refuse a tag that does not name the version the release will report.
#
# v0.3.28 was tagged while mix.exs still said 0.3.27. The artifact boots from
# releases/0.3.27 and reports 0.3.27, while the tag, the deploy checklist and
# the release notes all say 0.3.28. Only the label was wrong — but the label is
# what anyone reads first when asking which version is running.
#
# In a script rather than inline in the workflow so the logic can be run, and
# broken, without pushing a tag.
set -e

tag="$1"
[ -n "$tag" ] || { echo "usage: $0 <tag>" >&2; exit 2; }

expected="${tag#v}"
actual=$(grep -oE '@version "[^"]+"' mix.exs | head -1 | sed 's/.*"\(.*\)"/\1/')

[ -n "$actual" ] || { echo "no @version found in mix.exs" >&2; exit 2; }

if [ "$expected" != "$actual" ]; then
  echo "tag $tag expects @version \"$expected\", mix.exs says \"$actual\"" >&2
  echo "Bump @version in mix.exs, or tag the version that is actually there." >&2
  exit 1
fi

echo "tag $tag matches @version \"$actual\""
