# Changelog

All notable changes to `lex-soft` are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this package
follows [Semantic Versioning](https://semver.org/) against the `version`
field in `lex.toml`.

No version of this package has been tagged yet — `lex.toml`'s `version`
field is the only record of "current version" today. This file exists so
that changes going forward are documented, so a first tag (whenever cut)
has a real history to publish instead of a blank slate. Consumers pinning
a commit SHA can already track breaking changes here going forward; full
history before this file existed is `git log`.

## [Unreleased]

### Added
- `federation.lex`: `caller_authorized` — tenant-ownership enforcement on
  `mount_agent`'s routes (RPC dispatch, `/activity`, `/remember`); closes a
  cross-tenant data-access gap where a valid credential for one tenant could
  read or act on another tenant's agent.
- `federation_node.lex` — a runnable federation-node entry point for
  standing up a second, independent `lex-soft` node (useful for testing
  federation without a full domain-pack deployment).
- `pack.lex`: `PackInfo`/`PersonaInfo` — the `DomainPack` agent-domain
  manifest, letting a console/catalog describe a pack's personas without
  hardcoding them.
- `ledger.lex` / genealogy (`trace/unit/:id`) — tenant-scoped
  settlement/finance view and chain-of-transformations-to-origin, both
  read straight off the trail.
- `lex-ctl` integration: the verifier now consumes `lex-soft`'s scheduler +
  outbox as a second API co-validation client.

### Fixed
- RLS: explicitly clear the tenant GUC on every non-resolving request
  (GDPR-01 follow-up) — a stale GUC could otherwise leak scope across
  requests handled by the same connection.
- Federation bootstrap writes broken by RLS (GDPR-01 follow-up).
- CI now pins `lex-lang` `v0.10.9` (was `v0.10.7`, two releases behind) so
  what CI validates matches what a fresh `lex pkg install` actually
  resolves.

### Known gaps
- Multi-tenant isolation modules (`mesh.lex`, `federation.lex`, `rls.lex`,
  `resolver.lex`, `outbox.lex`) have thin test coverage relative to how
  safety-critical they are — `caller_authorized` above added one real
  regression test; the rest remain largely unexercised.
