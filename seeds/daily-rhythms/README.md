# daily-rhythms

## Purpose

`daily-rhythms` is a behavioral contract for what a household agent does on a
rhythm: a cadence table of recurring behaviors declared as data, each behavior
contracted as a Gather → Filter → Compose → Privacy → Deliver pipeline over
abstract inputs and outputs. It defines WHAT runs and what makes each run safe
— zero-signal suppression, the privacy boundary, untrusted calendar data —
independent of what fires it, which tools read for it, or where anything is
deployed. A consuming host supplies those bindings and proves this contract
live in its own Verification.
