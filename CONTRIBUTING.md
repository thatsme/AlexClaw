# Contributing to AlexClaw

Thank you for your interest in contributing to AlexClaw. This document explains
how to contribute and what to expect from the process.

---

## Before You Start

AlexClaw is a personal AI agent built on Elixir/OTP. Contributions are welcome,
but please understand the project's philosophy before proposing changes:

- **Lean over feature-rich** — we deliberately avoid complexity
- **Code over config** — skills are Elixir modules, not markdown files
- **BEAM-native** — OTP supervision, not workarounds
- **Auditable** — no unvetted external skill registries
- **Observable** — everything is measurable via telemetry

If your contribution aligns with these principles, it's likely a good fit.

---

## Contributor License Agreement (CLA)

**All contributors must agree to the CLA before their code can be merged.**

By submitting a pull request, you automatically agree to the CLA for minor
contributions (documentation, typos, small fixes).

For significant contributions (new skills, architectural changes, new providers),
you must explicitly sign the CLA by including this statement in your PR:

> I have read the AlexClaw CLA and agree to its terms.
> My GitHub username is [username] and my legal name is [full name].

Read the full CLA in [CLA.md](CLA.md).

**Why the CLA includes a relicensing clause:** The CLA allows the project to be
relicensed in the future without requiring permission from every contributor. This
is standard practice for projects that may evolve commercially, and does not affect
your right to use your own contributions however you wish.

---

## What We Welcome

- **New skills** — RSS sources, web scrapers, research tools, notification filters
- **New LLM providers** — additional free-tier integrations for the router
- **Bug fixes** — especially around rate limit handling and retry logic
- **Documentation** — architecture explanations, usage examples
- **Observability** — new telemetry events, Grafana dashboard definitions
- **Docker improvements** — deployment ergonomics

## What We Don't Want

- External skill registries or marketplaces
- Dependencies that require running services outside the compose stack
- Skills that send internal/sensitive data to external providers without explicit opt-in
- Complexity for its own sake

---

## How to Contribute

1. **Fork** the repository
2. **Create a branch** — `git checkout -b feature/my-skill` or `fix/router-fallback`
3. **Write your code** — follow the existing patterns in `lib/alex_claw/`
4. **Add tests** — skills should have unit tests; use `ExUnit`
5. **Run the suite** — `make test-elixir`
6. **Open a pull request** — describe what you built and why

Tests run in the container defined by `docker-compose.test.yml`, against an
isolated test database. Running `mix test` directly on the host is not
supported — it connects to the wrong database or none at all. The test stack is
its own compose project and publishes no ports, so it can run while the
production containers are up.

`make test-elixir` runs `scripts/test-elixir.sh` and `make test-python` runs
`scripts/test-python.sh`. Both run under a hard time limit for the whole run,
build included (`TEST_TIME_LIMIT`, default 2400 seconds), write the full output
to a log that is kept (`local-docs/test-logs/<suite>-<timestamp>.log`, or
`TEST_LOG_DIR`), print its path at the start and the end, and print a progress
line every 30 seconds. A run past the time limit is stopped, and the script
exits with status 124. The Elixir script also watches for a run that hangs
before any test starts: if none has started within 120 seconds
(`TEST_WATCHDOG_SECONDS`), the run is stopped the same way. In both cases it
first has the BEAM write a crash dump to `local-docs/erl_crash-<timestamp>.dump`.

Targeted runs go through the same script and the same limits:

| Command | Runs |
|---|---|
| `make test-elixir` | the whole suite, on a freshly built test image |
| `make test-elixir FILES="test/a_test.exs test/b_test.exs"` | only those files |
| `make test-failed` | only the tests that failed in the previous run (`mix test --failed`) |
| `make test-stale` | only the tests affected by modules changed since the last passing whole or stale run (`mix test --stale`) |

`--failed` and `--stale` read records of the previous run, so the build
directory is kept between runs in `.test-cache/elixir` (untracked). A whole-suite
run replaces it with the image's build and its records. Targeted runs reuse it,
so only changed modules compile again. `rm -rf .test-cache` resets it.

### Skill Contributions

New skills must implement the `AlexClaw.Skill` behaviour:

```elixir
defmodule AlexClaw.Skills.MySkill do
  @moduledoc "One-line description of what this skill does."
  @behaviour AlexClaw.Skill

  @impl true
  def description, do: "Short description for the skill registry"

  # Optional: declare branches for conditional workflow routing.
  # Default is [:on_success, :on_error] if not implemented.
  @impl true
  def routes, do: [:on_results, :on_empty, :on_error]

  @impl true
  def run(args) do
    # args[:input] — output from previous workflow step
    # args[:config] — step configuration from the workflow editor
    # args[:resources] — attached resources

    # Return triple tuple with branch name for conditional routing:
    {:ok, result, :on_results}

    # Or on empty/error:
    # {:ok, "No results found.", :on_empty}
    # {:error, reason}  — implicit :on_error
  end
end
```

The LLM tier (`:light`, `:medium`, `:heavy`, `:local`) is set per workflow step
in the admin UI, not in the skill module. If your skill calls `AlexClaw.LLM.complete/2`,
prefer `:light` unless genuinely necessary — the router will thank you.

**External skills:** If your skill fetches data from external sources (HTTP requests,
APIs, RSS feeds), you must declare `def external, do: true` in the module. This
enables automatic content sanitization in the workflow engine. For dynamic skills,
the registry AST-scans the source at load time — if it detects calls to HTTP/socket
libraries (`Req`, `HTTPoison`, `Finch`, `Tesla`, `:gen_tcp`, `SkillAPI.http_*`)
without `external/0`, the skill is **rejected**.

---

## Continuous Integration

Every push and pull request runs the format check and the full test suite in
the same container image used locally, so a green run locally means a green
run on CI. An unformatted file fails the build, so `mix format` is not
optional. Run it on the host rather than inside a container, which rewrites
line endings.

---

## Code Style

- Standard Elixir formatting — run `mix format` before committing; CI rejects unformatted code
- No unnecessary abstractions
- Pattern match explicitly — avoid generic catch-alls where possible
- Log with structured metadata: `Logger.info("event", skill: :my_skill, duration: ms)`

---

## Questions

Open an issue or start a discussion on GitHub. The project owner (Alessio Battistutta)
reviews contributions personally.

---

*AlexClaw — The BEAM-native personal AI agent. 🦇*
*Copyright 2026 Alessio Battistutta — Apache License 2.0*
