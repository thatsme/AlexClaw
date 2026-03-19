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
5. **Open a pull request** — describe what you built and why

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

---

## Code Style

- Standard Elixir formatting — run `mix format` before committing
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
