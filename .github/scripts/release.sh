#!/bin/sh
# Tag and publish the version in mix.exs — run by CI only after format, Credo
# and the test suite have passed on this exact commit.
#
# v0.3.32 was tagged and published by hand from a commit whose CI run then
# failed the format check, before any test ran. A release is now something CI
# makes, from a commit it has just passed, and never something made beside it.
#
# A version is released when both hold: its tag does not exist yet, and its
# notes are committed at .github/release-notes/v<version>.md. The notes' first
# line, without its leading "# ", is the release title; the rest is the body.
# A version bump without notes is not a release, so work can land between
# releases without publishing anything.
set -e

version=$(grep -oE '@version "[^"]+"' mix.exs | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$version" ] || { echo "no @version found in mix.exs" >&2; exit 2; }

tag="v$version"
notes=".github/release-notes/$tag.md"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "$tag already exists; nothing to release"
  exit 0
fi

if [ ! -f "$notes" ]; then
  echo "no $notes; $tag is not released"
  exit 0
fi

title=$(head -n 1 "$notes" | sed 's/^# //')
body=$(mktemp)
tail -n +2 "$notes" > "$body"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$tag" -m "$title" "${GITHUB_SHA:?}"
git push origin "$tag"

gh release create "$tag" --title "$title" --notes-file "$body" --verify-tag
echo "released $tag at $GITHUB_SHA"
