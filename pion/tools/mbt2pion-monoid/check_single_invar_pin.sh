#!/bin/sh
# CI gate: verify every AFK-surf/invar dependency across all pion/*/pion.toml files
# is pinned to the exact same single 40-char commit SHA.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

FOUND=0
for toml in "$REPO_ROOT"/pion/*/pion.toml; do
  [ -f "$toml" ] || continue
  REL="${toml#"$REPO_ROOT"/}"
  # Extract every line referencing AFK-surf/invar.git
  grep -n 'AFK-surf/invar\.git' "$toml" > /dev/null 2>&1 || continue
  while IFS= read -r line; do
    FOUND=$((FOUND + 1))
    REV="$(printf '%s\n' "$line" | sed -n 's/.*rev *= *"\([0-9a-f]\{40\}\)".*/\1/p')"
    if [ -z "$REV" ]; then
      echo "ERROR: $REL has an AFK-surf/invar dependency without a 40-char hex rev:" >&2
      echo "  $line" >&2
      exit 1
    fi
    printf '%s %s\n' "$REV" "$REL" >> "$TMP_FILE"
  done <<EOF
$(grep 'AFK-surf/invar\.git' "$toml")
EOF
done

if [ "$FOUND" -eq 0 ]; then
  echo "ERROR: no AFK-surf/invar dependencies found in pion/*/pion.toml" >&2
  exit 1
fi

UNIQUE_REVS="$(awk '{print $1}' "$TMP_FILE" | sort -u)"
COUNT="$(printf '%s\n' "$UNIQUE_REVS" | wc -l | tr -d ' ')"

if [ "$COUNT" -ne 1 ]; then
  echo "ERROR: multiple AFK-surf/invar pins detected across pion/*/pion.toml:" >&2
  cat "$TMP_FILE" >&2
  exit 1
fi

echo "OK: all $FOUND AFK-surf/invar dependencies pinned to single rev $UNIQUE_REVS"
