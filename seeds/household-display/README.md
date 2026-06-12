# household-display

## Purpose

`household-display` is a behavioral contract for a shared household display:
one always-on HTML page showing the household's upcoming events and four typed
card slots, fed by a replace-per-type bearer-auth message feed. It defines what
the display IS — surface, feed, and compose grammars — independent of where it
runs, who serves it, or how its data travels. A consuming host supplies those
bindings and proves this contract live in its own Verification.
