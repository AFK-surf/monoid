#!/bin/sh
# Ensure the pinned Pion toolchain (pionc, qbe, libpionrt.a, pion_rt.c/h) is installed and verified.
# Reads the pinned AFK-surf/pion commit SHA from pion/station/TOOLCHAIN and verifies local cache
# integrity with SHA256SUMS across all required toolchain artifacts.
#
# Environment:
#   PIONC              Override path to an existing pionc binary (sibling qbe/libpionrt.a validated;
#                      PION_BUILD_SHA is tagged override(...) instead of claiming TOOLCHAIN's SHA).
#   PION_TOOLCHAIN_DIR Override install/cache directory (default: $XDG_CACHE_HOME/pion-station-toolchain/<sha>).
#   PION_REPO_URL      Override upstream git URL (default: https://github.com/AFK-surf/pion.git).
#   PION_DEPLOY_KEY    Optional SSH private key for private AFK-surf/pion.
#   PION_TOKEN         Optional GitHub token for private AFK-surf/pion.
#
# Usage:
#   sh pion/station/scripts/ensure-pionc.sh [--print-path | --print-env]
set -eu

MODE="summary"
while [ $# -gt 0 ]; do
  case "$1" in
    --print-path) MODE="path"; shift ;;
    --print-env) MODE="env"; shift ;;
    -h|--help)
      echo "usage: sh pion/station/scripts/ensure-pionc.sh [--print-path | --print-env]"
      exit 0
      ;;
    *)
      echo "ensure-pionc.sh: unknown option: $1" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
STATION_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
TOOLCHAIN_FILE="$STATION_DIR/TOOLCHAIN"
PINNED_SHA="$(sed -n 's/[[:space:]]*#.*$//; /^[[:space:]]*$/d; p; q' "$TOOLCHAIN_FILE" | tr -d '[:space:]')"
if [ "${#PINNED_SHA}" -ne 40 ]; then
  echo "ensure-pionc.sh: invalid commit SHA in $TOOLCHAIN_FILE: '$PINNED_SHA'" >&2
  exit 1
fi

REQUIRED_FILES="bin/pionc bin/qbe lib/libpionrt.a share/pion/runtime/pion_rt.c share/pion/runtime/pion_rt.h"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sums() {
  dir="$1"
  sums="$dir/SHA256SUMS"
  [ -s "$sums" ] || return 1
  for req in $REQUIRED_FILES; do
    [ -f "$dir/$req" ] || return 1
    want="$(awk -v target="$req" '$2 == target { print $1; exit }' "$sums")"
    if [ "${#want}" -ne 64 ]; then
      echo "ensure-pionc.sh: missing or malformed checksum entry for $req in $sums" >&2
      return 1
    fi
    got="$(sha256_file "$dir/$req")"
    if [ "$got" != "$want" ]; then
      echo "ensure-pionc.sh: checksum mismatch for $dir/$req (got $got, expected $want)" >&2
      return 1
    fi
  done
  return 0
}

write_sums() {
  dir="$1"
  tmp="$dir/SHA256SUMS.tmp.$$"
  : > "$tmp"
  for rel in $REQUIRED_FILES; do
    if [ ! -f "$dir/$rel" ]; then
      rm -f "$tmp"
      echo "ensure-pionc.sh: missing installed artifact $dir/$rel" >&2
      return 1
    fi
    printf '%s  %s\n' "$(sha256_file "$dir/$rel")" "$rel" >> "$tmp"
  done
  mv -f "$tmp" "$dir/SHA256SUMS"
}

emit_result() {
  pionc_bin="$1"
  tc_dir="$2"
  rt_dir="$3"
  build_sha="$4"
  case "$MODE" in
    path)
      printf '%s\n' "$pionc_bin"
      ;;
    env)
      printf 'export PIONC=%s\n' "'$pionc_bin'"
      printf 'export PION_TOOLCHAIN_DIR=%s\n' "'$tc_dir'"
      printf 'export PION_RT_DIR=%s\n' "'$rt_dir'"
      printf 'export PION_PINNED_SHA=%s\n' "'$PINNED_SHA'"
      printf 'export PION_BUILD_SHA=%s\n' "'$build_sha'"
      printf 'export PATH="%s:%s"\n' "$(dirname "$pionc_bin")" '$PATH'
      ;;
    summary)
      echo "pionc=$pionc_bin build_sha=$build_sha rt=$rt_dir" >&2
      "$pionc_bin" --version >&2 || true
      ;;
  esac
}

if [ -n "${PIONC:-}" ]; then
  if [ ! -x "$PIONC" ]; then
    echo "ensure-pionc.sh: PIONC=$PIONC is not executable" >&2
    exit 1
  fi
  bin_dir="$(CDPATH= cd -- "$(dirname -- "$PIONC")" && pwd)"
  tc_dir="${PION_TOOLCHAIN_DIR:-$(CDPATH= cd -- "$bin_dir/.." && pwd)}"
  rt_dir="${PION_RT_DIR:-$tc_dir/share/pion/runtime}"
  if [ ! -x "$bin_dir/qbe" ] && [ ! -x "$tc_dir/bin/qbe" ]; then
    echo "ensure-pionc.sh: PIONC override missing sibling qbe in $bin_dir or $tc_dir/bin" >&2
    exit 1
  fi
  if [ ! -f "$tc_dir/lib/libpionrt.a" ]; then
    echo "ensure-pionc.sh: PIONC override missing $tc_dir/lib/libpionrt.a" >&2
    exit 1
  fi
  if [ ! -f "$rt_dir/pion_rt.c" ] || [ ! -f "$rt_dir/pion_rt.h" ]; then
    echo "ensure-pionc.sh: PIONC override missing runtime headers/source in $rt_dir" >&2
    exit 1
  fi
  if [ "$(cat "$tc_dir/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && verify_sums "$tc_dir"; then
    emit_result "$PIONC" "$tc_dir" "$rt_dir" "$PINNED_SHA"
  else
    emit_result "$PIONC" "$tc_dir" "$rt_dir" "override($PIONC)"
  fi
  exit 0
fi

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-toolchain"
TOOLCHAIN_DIR="${PION_TOOLCHAIN_DIR:-$CACHE_BASE/$PINNED_SHA}"
REPO_URL="${PION_REPO_URL:-https://github.com/AFK-surf/pion.git}"

if [ -x "$TOOLCHAIN_DIR/bin/pionc" ] && \
   [ "$(cat "$TOOLCHAIN_DIR/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
   verify_sums "$TOOLCHAIN_DIR"; then
  emit_result "$TOOLCHAIN_DIR/bin/pionc" "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/share/pion/runtime" "$PINNED_SHA"
  exit 0
fi

if [ -z "${PION_TOOLCHAIN_DIR:-}" ] && \
   [ -x "$HOME/.pion/bin/pionc" ] && \
   [ "$(cat "$HOME/.pion/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
   verify_sums "$HOME/.pion"; then
  emit_result "$HOME/.pion/bin/pionc" "$HOME/.pion" "$HOME/.pion/share/pion/runtime" "$PINNED_SHA"
  exit 0
fi

# Serialize concurrent bootstraps for the same TOOLCHAIN_DIR with a mkdir lock (never rm -rf an active install).
mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
LOCK_DIR="${TOOLCHAIN_DIR}.lock"
WORK_DIR=""
HELD_LOCK=0
cleanup() {
  [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" || true
  [ "$HELD_LOCK" -eq 1 ] && rm -rf "$LOCK_DIR" || true
}
trap cleanup EXIT

pid_gone() {
  [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null && ! kill -0 "$1" 2>/dev/null && ! ps -p "$1" >/dev/null 2>&1
}

while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)"
  if pid_gone "$holder"; then
    rm -rf "$LOCK_DIR"
    continue
  fi
  sleep 0.2
done
HELD_LOCK=1
echo "$$" > "$LOCK_DIR/pid"

# Re-check after acquiring lock: another process may have finished installing cleanly.
if [ -x "$TOOLCHAIN_DIR/bin/pionc" ] && \
   [ "$(cat "$TOOLCHAIN_DIR/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
   verify_sums "$TOOLCHAIN_DIR"; then
  emit_result "$TOOLCHAIN_DIR/bin/pionc" "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/share/pion/runtime" "$PINNED_SHA"
  exit 0
fi

echo "ensure-pionc.sh: bootstrapping AFK-surf/pion @ $PINNED_SHA into $TOOLCHAIN_DIR" >&2
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pion-bootstrap.XXXXXX")"
SRC_DIR="$WORK_DIR/pion-src"
STAGE_DIR="$(mktemp -d "$(dirname "$TOOLCHAIN_DIR")/.stage-$PINNED_SHA.XXXXXX")"
mkdir -p "$SRC_DIR"

git -C "$SRC_DIR" init -q
if [ -n "${PION_DEPLOY_KEY:-}" ]; then
  umask 077
  printf '%s\n' "$PION_DEPLOY_KEY" > "$WORK_DIR/pion_deploy_key"
  export GIT_SSH_COMMAND="ssh -i '$WORK_DIR/pion_deploy_key' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
  FETCHED=0
  for url in "git@github.com:AFK-surf/pion.git" "ssh://git@ssh.github.com:443/AFK-surf/pion.git"; do
    git -C "$SRC_DIR" remote remove origin 2>/dev/null || true
    git -C "$SRC_DIR" remote add origin "$url"
    if git -C "$SRC_DIR" fetch --depth 1 origin "$PINNED_SHA" >&2; then
      FETCHED=1
      break
    fi
  done
  if [ "$FETCHED" -ne 1 ]; then
    rm -rf "$STAGE_DIR"
    echo "ensure-pionc.sh: failed to fetch $PINNED_SHA via PION_DEPLOY_KEY" >&2
    exit 1
  fi
elif [ -n "${PION_TOKEN:-}" ] && [ "${REPO_URL#https://}" != "$REPO_URL" ]; then
  AUTH_B64="$(printf 'x-access-token:%s' "$PION_TOKEN" | base64 | tr -d '\n\r')"
  git -C "$SRC_DIR" remote add origin "$REPO_URL"
  git -C "$SRC_DIR" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $AUTH_B64" \
    fetch --depth 1 origin "$PINNED_SHA" >&2
else
  git -C "$SRC_DIR" remote add origin "$REPO_URL"
  git -C "$SRC_DIR" fetch --depth 1 origin "$PINNED_SHA" >&2
fi
git -C "$SRC_DIR" checkout -q FETCH_HEAD

GOT_SHA="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [ "$GOT_SHA" != "$PINNED_SHA" ]; then
  rm -rf "$STAGE_DIR"
  echo "ensure-pionc.sh: checked out SHA $GOT_SHA != pinned $PINNED_SHA" >&2
  exit 1
fi

(
  cd "$SRC_DIR"
  sh scripts/install.sh --prefix "$STAGE_DIR" >&2
)

printf '%s\n' "$PINNED_SHA" > "$STAGE_DIR/TOOLCHAIN_SHA"
write_sums "$STAGE_DIR"

# If an incomplete/corrupted directory existed, move it aside rather than deleting a live valid tree.
if [ -e "$TOOLCHAIN_DIR" ]; then
  mv "$TOOLCHAIN_DIR" "${TOOLCHAIN_DIR}.old.$$"
  mv "$STAGE_DIR" "$TOOLCHAIN_DIR"
  rm -rf "${TOOLCHAIN_DIR}.old.$$"
else
  mv "$STAGE_DIR" "$TOOLCHAIN_DIR"
fi

emit_result "$TOOLCHAIN_DIR/bin/pionc" "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/share/pion/runtime" "$PINNED_SHA"
