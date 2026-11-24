#!/bin/sh
# CI gate: verify EVERY AFK-surf/invar dependency across ALL pion/**/pion.toml and
# pion/**/pion.lock files (including workspace member packages) is pinned to the
# exact same single 40-char commit SHA, matching `manifest.toml`'s `invar_lock_sha`.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MANIFEST="$REPO_ROOT/pion/tools/mbt2pion-monoid/manifest.toml"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

FOUND_TOML=0
for toml in $(find "$REPO_ROOT/pion" -name 'pion.toml' -type f | sort); do
  REL="${toml#"$REPO_ROOT"/}"
  grep -q 'AFK-surf/invar\.git' "$toml" 2>/dev/null || continue
  while IFS= read -r line; do
    FOUND_TOML=$((FOUND_TOML + 1))
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

FOUND_LOCK=0
for lock in $(find "$REPO_ROOT/pion" -name 'pion.lock' -type f | sort); do
  REL="${lock#"$REPO_ROOT"/}"
  grep -q 'AFK-surf/invar\.git' "$lock" 2>/dev/null || continue
  # Parse [[package]] / [[git]] blocks referencing AFK-surf/invar.git and extract their rev
  LOCK_REVS="$(awk '
    /AFK-surf\/invar\.git/ { in_invar = 1; next }
    /^\[/ { in_invar = 0 }
    in_invar && /rev *= *"/ {
      if (match($0, /"[0-9a-f]{40}"/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
      } else {
        print "INVALID"
      }
      in_invar = 0
    }
  ' "$lock")"
  for rev in $LOCK_REVS; do
    FOUND_LOCK=$((FOUND_LOCK + 1))
    if [ "$rev" = "INVALID" ] || [ "${#rev}" -ne 40 ]; then
      echo "ERROR: $REL has an AFK-surf/invar lock entry without a 40-char hex rev" >&2
      exit 1
    fi
    printf '%s %s\n' "$rev" "$REL" >> "$TMP_FILE"
  done
done

if [ "$FOUND_TOML" -eq 0 ] || [ "$FOUND_LOCK" -eq 0 ]; then
  echo "ERROR: expected AFK-surf/invar entries in both pion.toml ($FOUND_TOML) and pion.lock ($FOUND_LOCK)" >&2
  exit 1
fi

UNIQUE_REVS="$(awk '{print $1}' "$TMP_FILE" | sort -u)"
COUNT="$(printf '%s\n' "$UNIQUE_REVS" | wc -l | tr -d ' ')"

if [ "$COUNT" -ne 1 ]; then
  echo "ERROR: multiple AFK-surf/invar pins detected across pion/**/pion.{toml,lock}:" >&2
  cat "$TMP_FILE" >&2
  exit 1
fi

if [ -f "$MANIFEST" ]; then
  MANIFEST_SHA="$(sed -n 's/^invar_lock_sha *= *"\([0-9a-f]\{40\}\)".*/\1/p' "$MANIFEST" | head -n 1)"
  if [ -z "$MANIFEST_SHA" ] || [ "$MANIFEST_SHA" != "$UNIQUE_REVS" ]; then
    echo "ERROR: manifest.toml invar_lock_sha ($MANIFEST_SHA) != workspace pin ($UNIQUE_REVS)" >&2
    exit 1
  fi
fi

echo "OK: all $FOUND_TOML pion.toml + $FOUND_LOCK pion.lock AFK-surf/invar entries + manifest.toml pinned to single rev $UNIQUE_REVS"
