# Testing

## Structural Check

Run the committed structural verifier:

```bash
bash ref/verify.sh
```

This runs four structural checks over the SEED tree shape: the README
`## Purpose` heading; the root `SEED.md` one-H1 + canonical H2 grammar;
tree-wide `SEED.md` conformance (purpose back-references included); and that the
shipped `ref/` directory contains exactly `verify.sh` and nothing else.

## Install Rehearsal

End-to-end behavior is rehearsed against real services. The published SEED does
not ship test doubles, local service scripts, or an installer UI server.

For a user install, the SEED install itself is the end-to-end verification: Domo
logs in with the user's real Claude subscription, verifies the real Calendar
connector, activates through real Plow Chat, sends the ready text, and replies
in the user's text thread.
