# Changelog

Release notes are published once, as the **[GitHub releases](https://github.com/thatsme/AlexClaw/releases)**, each version with what changed and anything an upgrade needs.

From 0.3.33 on, each version's notes are committed with the release in `.github/release-notes/v<version>.md`, and CI publishes them after the release commit passes its checks. The releases page is the only place they are listed, so there is no second copy here to fall behind.

Upgrades that need manual steps have their own guides:

- [Upgrading to 0.3.34](../deployment/upgrade-0.3.34.md) — separate database roles
- [Rotating SECRET_KEY_BASE](../deployment/rotate-secret-key-base.md)

## A version without a release

v0.3.10 was tagged but never published as a GitHub release, so its notes live only here.

### v0.3.10 — Coding Conventions Enforcement

- Giulia analysis report integration
- 195 convention violations fixed
- `enforce_keys` on all structs
