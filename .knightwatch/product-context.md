# Product context

This is a **SEED-convention repo**: `SEED.md` and `README.md` (RFC-2119
prose) are the authoritative artifacts; `ref/` is a single-operator
reference implementation of that prose. Review for **convention conformance
and prose↔ref drift**, not for product-scale hardening.

Operating point (org default):

- **Stage:** pre-PMF, early. Iteration speed > hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions,
  flags, parallel modes, and defensive edge-case handling sized for
  thousands of users are over-engineering here, not robustness.
- **Spec rigidity:** the SEED prose IS the contract; a handled edge case the
  spec never asked for is a cost, not a feature.

**This repo's `ref/` payload:** exactly `ref/verify.sh` (the deterministic structural verifier) — nothing else. Post-decomposition, everything that used to ship here (the `domo` orchestrator CLI, expect PTY helpers, the TypeScript/Bun MCP chat-channel server) is GENERATED at install from the SEED prose, not shipped; the published tree ships zero runnable product code beyond `verify.sh`, and `verify.sh`'s check 4 enforces it.
