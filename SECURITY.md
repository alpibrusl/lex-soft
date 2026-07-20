# Security policy

`lex-soft` is the engine behind cross-organisation agent coordination and
**evidence-gated settlement** — it can gate the movement of money between
counterparties. Security reports are taken seriously.

## Reporting a vulnerability

Please report privately, **not** via a public issue:

- Email **security@alpibru.com** (or `alfonso@alpibru.com`), or
- Open a GitHub private security advisory on this repository.

Include what you found, how to reproduce it, and the impact. We aim to
acknowledge within a few working days and to agree a disclosure timeline with
you. Please give us reasonable time to fix before any public disclosure.

## Supported versions

Only the current `main` is supported. Pin to a reviewed commit for production.

## Scope and known limitations

- **Load-bearing dependencies are out of scope of this repo's guarantees.** The
  actual proof, spend-cap, and cryptographic logic live in `lex-trail`,
  `lex-guard`, and `lex-crypto`. A signature-verification or spend-cap bug there
  would undercut guarantees this repo appears to provide. Those deserve their
  own review before production settlement.
- **Builds are not yet fully reproducible.** Dependencies are declared as git
  refs; the flat layout plus unpinned transitive deps means a lockfile (pinning
  the whole closure) is required for true reproducibility, and that is an
  upstream tooling gap. CI verifies the toolchain download's checksum.
- **Some routes assume an authenticating gateway in front.** Onboarding and
  discovery endpoints must be gated (signup token / proof-of-org) before being
  exposed to the internet — see `FederationConfig`.

## Hardening status

Active remediation (from the 2026-07 audit) is tracked in the issue tracker:
fail-closed verdicts, authenticated onboarding, dispatch-path revocation,
indexed tenant scoping. Do not run this against real value until the
before-deployment tier is complete.
