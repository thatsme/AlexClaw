# Release notes

A file here named `v<version>.md`, committed together with the matching
`@version` in `mix.exs`, is what makes CI publish that version: once format,
Credo and the test suite pass on the commit, the `release` job tags it and
creates the GitHub release. The first line, without its leading `# `, is the
release title; the rest is the body.

A version whose tag already exists is never published again, so a notes file
can stay here after its release.
