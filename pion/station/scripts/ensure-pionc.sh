#!/bin/sh
# Ensure the pinned Pion toolchain (pionc, qbe, libpionrt.a, pion_rt.c/h) is installed and verified.
# Reads the pinned AFK-surf/pion commit SHA from pion/station/TOOLCHAIN.
#
# Environment:
#   PIONC              Override path to an existing pionc binary (still checked for executability).
#   PION_TOOLCHAIN_DIR Override install/cache directory (default: $XDG_CACHE_HOME/pion-station-toolchain/<sha>).
#   PION_REPO_URL      Override upstream git URL (default: https://github.com/AFK-surf/pion.git).
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
  [ -f "$sums" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    want="$(printf '%s\n' "$line" | awk '{print $1}')"
    rel="$(printf '%s\n' "$line" | awk '{print $2}')"
    [ -f "$dir/$rel" ] || return 1
    got="$(sha256_file "$dir/$rel")"
    if [ "$got" != "$want" ]; then
      echo "ensure-pionc.sh: checksum mismatch for $dir/$rel (got $got, expected $want)" >&2
      return 1
    fi
  done < "$sums"
  return 0
}

write_sums() {
  dir="$1"
  tmp="$dir/SHA256SUMS.tmp.$$"
  : > "$tmp"
  for rel in bin/pionc bin/qbe lib/libpionrt.a share/pion/runtime/pion_rt.c share/pion/runtime/pion_rt.h; do
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
  case "$MODE" in
    path)
      printf '%s\n' "$pionc_bin"
      ;;
    env)
      printf 'export PIONC=%s\n' "'$pionc_bin'"
      printf 'export PION_TOOLCHAIN_DIR=%s\n' "'$tc_dir'"
      printf 'export PION_RT_DIR=%s\n' "'$rt_dir'"
      printf 'export PION_PINNED_SHA=%s\n' "'$PINNED_SHA'"
      printf 'export PATH="%s:%s"\n' "$(dirname "$pionc_bin")" '$PATH'
      ;;
    summary)
      echo "pionc=$pionc_bin sha=$PINNED_SHA rt=$rt_dir" >&2
      "$pionc_bin" --version >&2 || true
      ;;
  esac
}

if [ -n "${PIONC:-}" ]; then
  if [ ! -x "$PIONC" ]; then
    echo "ensure-pionc.sh: PIONC=$PIONC is not executable" >&2
    exit 1
  fi
  tc_dir="${PION_TOOLCHAIN_DIR:-$(CDPATH= cd -- "$(dirname -- "$PIONC")/.." && pwd)}"
  rt_dir="${PION_RT_DIR:-$tc_dir/share/pion/runtime}"
  if [ ! -f "$rt_dir/pion_rt.c" ] && [ -f "$HOME/.pion/share/pion/runtime/pion_rt.c" ]; then
    rt_dir="$HOME/.pion/share/pion/runtime"
  fi
  emit_result "$PIONC" "$tc_dir" "$rt_dir"
  exit 0
fi

CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/pion-station-toolchain"
TOOLCHAIN_DIR="${PION_TOOLCHAIN_DIR:-$CACHE_BASE/$PINNED_SHA}"
REPO_URL="${PION_REPO_URL:-https://github.com/AFK-surf/pion.git}"

if [ -x "$TOOLCHAIN_DIR/bin/pionc" ] && \
   [ "$(cat "$TOOLCHAIN_DIR/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
   verify_sums "$TOOLCHAIN_DIR"; then
  emit_result "$TOOLCHAIN_DIR/bin/pionc" "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/share/pion/runtime"
  exit 0
fi

# Check if ~/.pion already has the exact matching pinned SHA + verified sums.
if [ -z "${PION_TOOLCHAIN_DIR:-}" ] && \
   [ -x "$HOME/.pion/bin/pionc" ] && \
   [ "$(cat "$HOME/.pion/TOOLCHAIN_SHA" 2>/dev/null || true)" = "$PINNED_SHA" ] && \
   verify_sums "$HOME/.pion"; then
  emit_result "$HOME/.pion/bin/pionc" "$HOME/.pion" "$HOME/.pion/share/pion/runtime"
  exit 0
fi

echo "ensure-pionc.sh: bootstrapping AFK-surf/pion @ $PINNED_SHA into $TOOLCHAIN_DIR" >&2
mkdir -p "$(dirname "$TOOLCHAIN_DIR")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pion-bootstrap.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

SRC_DIR="$WORK_DIR/pion-src"
STAGE_DIR="$WORK_DIR/install"
mkdir -p "$SRC_DIR" "$STAGE_DIR"

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
  echo "ensure-pionc.sh: checked out SHA $GOT_SHA != pinned $PINNED_SHA" >&2
  exit 1
fi

(
  cd "$SRC_DIR"
  sh scripts/install.sh --prefix "$STAGE_DIR" >&2
)

printf '%s\n' "$PINNED_SHA" > "$STAGE_DIR/TOOLCHAIN_SHA"
write_sums "$STAGE_DIR"

TMP_TARGET="${TOOLCHAIN_DIR}.tmp.$$"
rm -rf "$TMP_TARGET"
mv "$STAGE_DIR" "$TMP_TARGET"
rm -rf "$TOOLCHAIN_DIR"
mv "$TMP_TARGET" "$TOOLCHAIN_DIR"

emit_result "$TOOLCHAIN_DIR/bin/pionc" "$TOOLCHAIN_DIR" "$TOOLCHAIN_DIR/share/pion/runtime"
