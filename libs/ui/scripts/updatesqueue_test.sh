#!/bin/sh
# Android's update worker (android/app/.../UpdatesQueue.java: the app's threads touch no file and no Binder, what the
# person sees at once, every end of a fetch handing over to the build asked for meanwhile, the installer's session kept):
# android/updates/UpdatesQueueTest.java, plain Java, no Android. Needs a JDK (javac, java).
set -eu
cd "$(dirname "$0")/.."
OUT=${TMPDIR:-/tmp}/updatesqueue.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
javac -Xlint:all -Werror -d "$OUT" android/app/src/main/java/dev/mbui/UpdatesQueue.java android/updates/UpdatesQueueTest.java
java -cp "$OUT" dev.mbui.UpdatesQueueTest
