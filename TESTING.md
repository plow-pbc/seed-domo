# Testing

## Structural Check

Run the committed structural verifier:

```bash
bash ref/verify.sh
```

This checks the SEED tree shape: README purpose heading, root grammar, purpose
back-references, and the `## Verification` / `## Open Items` heading grammar.

## Install Rehearsal

End-to-end behavior is rehearsed against real services. The published SEED does
not ship test doubles, local service scripts, or an installer UI server.

For a user install, the SEED install itself is the end-to-end verification: Domo
logs in with the user's real Claude subscription, verifies the real Calendar
connector, activates through real Plow Chat, sends the ready text, and replies
in the user's text thread.
