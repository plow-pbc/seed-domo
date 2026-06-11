#!/usr/bin/env bash
# Deterministic implementation of the SEED ## Verification section's four
# STRUCTURAL prompts (README ## Purpose; root SEED.md one-H1 + canonical
# H2 grammar; tree-wide SEED.md conformance; shipped ref/ contains only
# verify.sh).
#
# The natural-language prompts in SEED.md's ## Verification section are the
# normative source; this script runs the same structural checks as bash so
# CI and non-AI callers (and the Review phase) have a deterministic exit
# code. The runtime Verification prompts (tooling present, subscription sign-in,
# calendar connector, daemon resume) are NOT covered here — they need a
# live machine and are covered by install rehearsal evidence.
#
# Usage:   bash ref/verify.sh [TARGET_DIR]
#   TARGET_DIR defaults to "." (run from the repo root: `bash ref/verify.sh`).
#
# Exit 0 iff all four structural checks pass. Any failure prints a FAIL
# line and exits non-zero. Per-check PASS/FAIL lines are printed regardless.
#
# Portability: macOS bash 3.2 + BSD/awk (no GNU-only flags — no `grep -P`,
# no `readarray`/`mapfile`, no `realpath`).

set -euo pipefail

# Target SEED tree. Default "." so `bash ref/verify.sh` from the repo root
# verifies this repo; pass a dir to verify a different tree.
TARGET="${1:-.}"
cd -- "$TARGET"

# ---------------------------------------------------------------------------
# Heading scanners. Each toggles an in/out-of-fence flag whenever a line's
# first non-space characters are a ```` ``` ```` (or `~~~`) fence delimiter,
# and only emits headings seen OUTSIDE a fence. CommonMark allows 0-3
# leading spaces before a fence/heading. Two single patterns combined with
# `||` (rather than ERE alternation inside one /.../) keep this portable
# across BSD awk and mawk.
# ---------------------------------------------------------------------------
h1s_of() {
  awk '/^ {0,3}```/ || /^ {0,3}~~~/ { f = !f; next } !f && /^# [^#]/' "$1"
}
h2s_of() {
  awk '/^ {0,3}```/ || /^ {0,3}~~~/ { f = !f; next } !f && /^## /' "$1"
}
# Body of the `# Purpose` H1: the non-blank lines between that H1 and the
# next heading, excluding fenced code blocks.
purpose_body_of() {
  awk '
    /^ {0,3}```/ || /^ {0,3}~~~/ { fence = !fence; next }
    fence { next }
    /^# Purpose$/ { in_p = 1; next }
    /^#/ { in_p = 0 }
    in_p && NF { print }
  ' "$1"
}

# Count non-empty lines on stdin (portable; avoids `echo "" | wc -l` == 1
# counting an empty string as one line).
nonblank_count() { grep -c . || true; }

# Canonical top-level H2 grammar (pipe-separated so it survives `awk -v`
# across awk variants — BSD awk rejects multi-line -v values). This MUST
# match SEED.md's "Canonical H2 grammar":
#   required, in order:  Dependencies -> Objects -> Actions -> Verification
#   the root SEED.md additionally MUST start with Normative Language
#   optional, in order, after Verification:  Feedback -> Open Items -> Non-Goals
#   any other top-level H2 is non-conforming.
CANONICAL='## Normative Language|## Dependencies|## Objects|## Actions|## Verification|## Feedback|## Open Items|## Non-Goals'

# ---------------------------------------------------------------------------
# Structural validation of one SEED.md ($1). $2 is "root" for the repo-root
# SEED.md (Normative Language REQUIRED) or "sub" for a nested one (Normative
# Language FORBIDDEN — sub-folder SEEDs inherit RFC 2119 from the root).
# Echoes one or more "  - <reason>" lines for each violation and returns 1
# on any failure; returns 0 (no output) when the file conforms.
# ---------------------------------------------------------------------------
check_seed() {
  f="$1"
  kind="$2"
  rc=0

  h1="$(h1s_of "$f")"
  h2="$(h2s_of "$f")"
  pb="$(purpose_body_of "$f")"

  # --- exactly one H1 and it is "# Purpose" ---
  h1_count="$(printf '%s\n' "$h1" | nonblank_count)"
  if [ "$h1_count" != "1" ] || [ "$h1" != "# Purpose" ]; then
    echo "  - $f: H1 must be exactly one '# Purpose' (found ${h1_count}: ${h1:-<none>})"
    rc=1
  fi

  # --- Purpose body: exactly one non-blank line, a sibling-or-ancestor
  #     README#Purpose link ---
  pb_count="$(printf '%s\n' "$pb" | nonblank_count)"
  if [ "$pb_count" != "1" ]; then
    echo "  - $f: # Purpose body must be exactly one non-blank line (found ${pb_count})"
    rc=1
  else
    # The only allowed prose decoration is the recommended
    # `> See [README#Purpose](README.md#purpose).` blockquote form; the
    # path prefix may be empty (sibling) or repeated `../` (ancestor) only.
    if printf '%s\n' "$pb" \
         | grep -Eq '^(> *)?(See *)?\[[^][]+\]\((\.\./)*README\.md#purpose\)\.?$'; then
      # Resolve the link target and require it exists with a ## Purpose H2.
      readme_rel="$(printf '%s\n' "$pb" \
        | sed -nE 's|.*\(((\.\./)*)README\.md#purpose\).*|\1README.md|p')"
      readme_target="$(dirname "$f")/$readme_rel"
      if [ ! -f "$readme_target" ]; then
        echo "  - $f: # Purpose link points to a missing README ($readme_target)"
        rc=1
      elif ! h2s_of "$readme_target" | grep -qx '## Purpose'; then
        echo "  - $f: referenced README has no '## Purpose' H2 ($readme_target)"
        rc=1
      else
        # The contract is the *closest* sibling-or-ancestor README; walk up
        # from $f's directory and require the link resolved to exactly it.
        target_abs="$(cd -- "$(dirname -- "$readme_target")" && pwd -P)/README.md"
        closest=""
        d="$(cd -- "$(dirname -- "$f")" && pwd -P)"
        while : ; do
          if [ -f "$d/README.md" ]; then closest="$d/README.md"; break; fi
          parent="$(dirname "$d")"
          [ "$parent" = "$d" ] && break
          d="$parent"
        done
        if [ "$closest" != "$target_abs" ]; then
          echo "  - $f: # Purpose link is not the closest sibling-or-ancestor README (link: $target_abs; closest: ${closest:-none})"
          rc=1
        fi
      fi
    else
      echo "  - $f: # Purpose body must be a sibling-or-ancestor README#Purpose link"
      rc=1
    fi
  fi

  # --- the four required H2s, present and in order ---
  if ! printf '%s\n' "$h2" \
        | grep -E '^## (Dependencies|Objects|Actions|Verification)$' \
        | diff - <(printf '## Dependencies\n## Objects\n## Actions\n## Verification\n') >/dev/null 2>&1; then
    echo "  - $f: required H2s (Dependencies, Objects, Actions, Verification) missing or out of order"
    rc=1
  fi

  # --- whole top-level H2 sequence is an in-order subsequence of canonical
  #     (this also rejects any non-conforming H2 and any duplicate) ---
  if ! printf '%s\n' "$h2" | awk -v canon="$CANONICAL" '
        BEGIN { n = split(canon, c, "|"); i = 1 }
        NF == 0 { next }
        {
          while (i <= n && c[i] != $0) i++
          if (i > n) exit 1
          i++
        }
      '; then
    echo "  - $f: top-level H2s are not an in-order subset of the canonical grammar (non-conforming or duplicate H2)"
    rc=1
  fi

  # --- Normative Language root/sub gate ---
  has_norm="$(printf '%s\n' "$h2" | grep -cx '## Normative Language' || true)"
  if [ "$kind" = "root" ]; then
    if [ "$has_norm" = "0" ]; then
      echo "  - $f: root SEED.md MUST contain '## Normative Language'"
      rc=1
    fi
  else
    if [ "$has_norm" != "0" ]; then
      echo "  - $f: sub-folder SEED.md MUST NOT re-declare '## Normative Language' (inherited from root)"
      rc=1
    fi
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Run the three checks. We disable `set -e`'s abort-on-nonzero around each
# check so a FAILing check still prints its PASS/FAIL line; the final exit
# code is driven by $overall.
# ---------------------------------------------------------------------------
overall=0

# --- Check 1: README.md has a ## Purpose H2 (outside fenced code blocks) ---
if [ -f README.md ] && h2s_of README.md | grep -qx '## Purpose'; then
  echo "PASS  check 1: README.md has a '## Purpose' H2"
else
  echo "FAIL  check 1: README.md missing a '## Purpose' H2 (outside fenced code blocks)"
  overall=1
fi

# --- Check 2: root SEED.md structural conformance (root grammar) ---
if [ ! -f SEED.md ]; then
  echo "FAIL  check 2: root SEED.md not found"
  overall=1
else
  set +e
  reasons2="$(check_seed SEED.md root)"
  rc2=$?
  set -e
  if [ "$rc2" = "0" ]; then
    echo "PASS  check 2: root SEED.md conforms to the canonical grammar"
  else
    echo "FAIL  check 2: root SEED.md does not conform:"
    printf '%s\n' "$reasons2"
    overall=1
  fi
fi

# --- Check 3: every SEED.md in the tree (excluding .git/) conforms ---
# Root SEED.md is validated with root rules; every nested SEED.md with sub
# rules (sub SEEDs MUST NOT contain '## Normative Language').
root_abs="$(pwd -P)/SEED.md"
tree_rc=0
tree_reasons=""
checked=0
# NUL-delimited find loop so SEED.md paths containing spaces/newlines survive.
while IFS= read -r -d '' f; do
  checked=$((checked + 1))
  this_abs="$(cd -- "$(dirname -- "$f")" && pwd -P)/SEED.md"
  if [ "$this_abs" = "$root_abs" ]; then
    kind=root
  else
    kind=sub
  fi
  set +e
  r="$(check_seed "$f" "$kind")"
  rc=$?
  set -e
  if [ "$rc" != "0" ]; then
    tree_rc=1
    tree_reasons="${tree_reasons}${r}
"
  fi
done < <(find . -path ./.git -prune -o -name SEED.md -print0)

if [ "$checked" = "0" ]; then
  echo "FAIL  check 3: no SEED.md found anywhere in the tree"
  overall=1
elif [ "$tree_rc" = "0" ]; then
  echo "PASS  check 3: all ${checked} SEED.md in the tree conform"
else
  echo "FAIL  check 3: one or more SEED.md in the tree do not conform:"
  printf '%s' "$tree_reasons"
  overall=1
fi

# --- Check 4: the shipped ref/ directory contains exactly verify.sh ---
# The root SEED.md ## Verification states ref/ contains exactly verify.sh and
# no old product scripts, installer SPA/server, channel server, bin helper,
# harness, or test double. Enforce it deterministically: any entry under ref/
# other than verify.sh fails the check.
if [ ! -d ref ]; then
  echo "FAIL  check 4: ref/ directory not found"
  overall=1
else
  extra_ref="$(find ref -mindepth 1 ! -name verify.sh 2>/dev/null)"
  if [ -z "$extra_ref" ]; then
    echo "PASS  check 4: ref/ contains only verify.sh"
  else
    echo "FAIL  check 4: ref/ contains entries other than verify.sh:"
    printf '%s\n' "$extra_ref" | sed 's/^/  - /'
    overall=1
  fi
fi

echo "----"
if [ "$overall" = "0" ]; then
  echo "OK: all structural checks passed"
else
  echo "FAILED: one or more structural checks failed"
fi
exit "$overall"
