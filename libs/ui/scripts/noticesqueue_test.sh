#!/bin/sh
# Android's asynchronous notification queue & permission cache state machine (android/app/.../NoticesQueue.java):
# android/notices/NoticesQueueTest.java, plain Java, no Android. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/noticesqueue.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/NoticesQueue.java android/notices/NoticesQueueTest.java
java -cp "$OUT" dev.mbui.NoticesQueueTest
