#!/bin/sh
# Builds StillfailLockedUse.bundle (the SecurityAgent mechanism) into $1 (default: .build/plugin). Signing and
# notarizing are the release's (.github/sign-station.sh): an unsigned bundle is for reading, never for installing.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-"$here/../.build/plugin"}
bundle="$out/StillfailLockedUse.bundle"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
clang -bundle -O2 -Wall -Wextra -Werror -fvisibility=hidden -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
  -framework CoreFoundation -framework Security -lbsm \
  -o "$bundle/Contents/MacOS/StillfailLockedUse" "$here/StillfailLockedUse.c"
cp "$here/Info.plist" "$bundle/Contents/Info.plist"
echo "$bundle"
