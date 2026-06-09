# Testing

## Structural Check

Run the committed structural verifier:

```bash
bash ref/verify.sh
```

This checks the SEED tree shape: README purpose heading, root grammar, purpose
back-references, and the `## Verification` / `## Open Items` heading grammar.

## Baseline Install Rehearsal

The current monolith remains installable through the product files in `ref/`.
End-to-end behavior is rehearsed against real local services, not the deleted
stub harness.

Implementation checkouts may keep a private, gitignored rehearsal overlay under
`docs/testing/`. That local overlay should cover:

- local Plow at `http://127.0.0.1:19004`;
- DTU inbound simulation at `http://127.0.0.1:19005/ui/inbound`;
- a stable auth'd rehearsal home for real Claude login and real Calendar checks;
- ephemeral homes only for no-auth Plow-side drills.

Published users do not need the rehearsal overlay. For a user install, the SEED
install itself is the end-to-end verification: Domo logs in with the user's real
Claude subscription, verifies the real Calendar connector, activates through
real Plow Chat, sends the ready text, and replies in the user's text thread.
