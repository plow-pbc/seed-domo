# Testing

## Structural Check

Run the committed structural verifier:

```bash
bash ref/verify.sh
```

This is the only automated check shipped in the repo. It verifies the SEED tree
shape: README purpose heading, root grammar, purpose back-references, and the
`## Verification` / `## Open Items` heading grammar.

## Install Rehearsal

End-to-end behavior is verified by a private install rehearsal, not committed
test harnesses. The local overlay is `docs/testing/e2e-rehearsal.md` in working
checkouts that are doing implementation work. It uses:

- local Plow at `http://127.0.0.1:19004`;
- DTU inbound simulation at `http://127.0.0.1:19005/ui/inbound`;
- a stable auth'd rehearsal home for real Claude login and real Calendar checks;
- ephemeral baked homes only for no-auth Plow-side drills.

Published users do not need the rehearsal overlay. For a user install, the SEED
install itself is the end-to-end verification: Domo logs in with the user's real
Claude subscription, verifies the real Calendar connector, activates through
real Plow Chat, sends the ready text, and replies in the user's text thread.
