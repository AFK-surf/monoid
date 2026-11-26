#!/bin/sh
# MBRAWPRE header parser, bounds validator, and targetSize clamping on Android (android/app/.../RawPremul.java):
# android/mail/RawPremulTest.java, plain Java, no Android SDK required. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/rawpremul.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/RawPremul.java android/mail/RawPremulTest.java
java -cp "$OUT" dev.mbui.RawPremulTest
