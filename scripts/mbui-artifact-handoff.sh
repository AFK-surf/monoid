#!/usr/bin/env bash
# Stage or restore an mbui-check test-binary directory through Cloudflare R2 (scripts/native-handoff.mjs).
#
# Producer (self-hosted non-main pipeline runs only):
#   bash scripts/mbui-artifact-handoff.sh put <part> <dir> <commit>
#   Packs <dir> (when non-empty) into mbui-<slug>-<24hex>.tar.gz, uploads it via native-handoff.mjs put,
#   and replaces <dir> with only natives.r2.json (~1 KB) so actions/upload-artifact@v4 does not push
#   68+ MB to Azure Blob Storage over congested self-hosted egress.
#
# Consumer (every runner):
#   bash scripts/mbui-artifact-handoff.sh get <dir> <commit>
#   When <dir>/natives.r2.json is present, downloads and SHA-256-verifies the tarball via native-handoff.mjs get,
#   unpacks it into <dir>, and removes the manifest and tarball. Otherwise exits 0 unchanged (direct artifact).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
op="${1:-}"

case "$op" in
  put)
    part="${2:?usage: mbui-artifact-handoff.sh put <part> <dir> <commit>}"
    dir="${3:?usage: mbui-artifact-handoff.sh put <part> <dir> <commit>}"
    commit="${4:?usage: mbui-artifact-handoff.sh put <part> <dir> <commit>}"
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
      echo "mbui-artifact-handoff: invalid commit sha: $commit" >&2
      exit 1
    fi
    if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir")" ]; then
      exit 0
    fi
    slug="${part//_/-}"
    if [[ ! "$slug" =~ ^[a-z0-9-]+$ ]]; then
      echo "mbui-artifact-handoff: invalid part name: $part" >&2
      exit 1
    fi
    archive="mbui-${slug}-${commit:0:24}.tar.gz"
    stage="$(mktemp -d "${RUNNER_TEMP:-/tmp}/mbui-handoff-stage.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    if command -v pigz >/dev/null 2>&1; then
      tar -cf - -C "$dir" . | pigz -1 > "$stage/$archive"
    else
      GZIP=-1 tar -czf "$stage/$archive" -C "$dir" .
    fi
    GITHUB_SHA="$commit" node "$repo_root/scripts/native-handoff.mjs" put "$stage" "$stage/natives.r2.json"
    if [ ! -s "$stage/natives.r2.json" ]; then
      echo "mbui-artifact-handoff: native-handoff.mjs did not write natives.r2.json" >&2
      exit 1
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    mv "$stage/natives.r2.json" "$dir/natives.r2.json"
    ;;
  get)
    dir="${2:?usage: mbui-artifact-handoff.sh get <dir> <commit>}"
    commit="${3:?usage: mbui-artifact-handoff.sh get <dir> <commit>}"
    if [ ! -f "$dir/natives.r2.json" ]; then
      exit 0
    fi
    if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
      echo "mbui-artifact-handoff: invalid commit sha: $commit" >&2
      exit 1
    fi
    STILLFAIL_NATIVE_CACHE="" node "$repo_root/scripts/native-handoff.mjs" get "$dir" "$commit"
    names="$(node -e '
      const fs = require("node:fs");
      const entries = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      if (!Array.isArray(entries) || entries.length === 0) throw new Error("empty manifest");
      for (const e of entries) {
        if (typeof e?.name !== "string" || !/^mbui-[a-z0-9-]+-[0-9a-f]{24}\.tar\.gz$/.test(e.name)) {
          throw new Error("unexpected mbui archive name: " + String(e?.name));
        }
        console.log(e.name);
      }
    ' "$dir/natives.r2.json")"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      tar -xzf "$dir/$name" -C "$dir"
      rm -f "$dir/$name"
    done <<< "$names"
    rm -f "$dir/natives.r2.json"
    ;;
  *)
    echo "Usage: mbui-artifact-handoff.sh put <part> <dir> <commit> | get <dir> <commit>" >&2
    exit 1
    ;;
esac
