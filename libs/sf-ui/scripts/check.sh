#!/bin/bash
# still.fail's component library on its own (mbui beside it, ../mbui): the determinism lint with this module's
# detlint.json, its packages type-checked on native and js (the app's targets: its native hosts and the web), then its
# tests (CI's check-sf-ui).
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
MBUI_DIR=$(cd "$A/../mbui" && pwd)
. "$MBUI_DIR/scripts/env.sh"
"$MBUI_DIR/scripts/detlint" "$A" || exit 1
cd "$A"
for t in native js; do
  moon check --target $t --output-json 2>&1 | "$MBUI_DIR/scripts/chk" errs
  [ "${PIPESTATUS[0]}" = 0 ] || exit 1
done
# (the kinds of test program this package has none of, not built; and its test programs compiled without optimising, as
# apps/mbui/scripts/test.sh and mbui's test_native.sh compile the library's tests)
empty=""
[ -n "$(ls src/*.mbt 2>/dev/null | grep -vE '_(wb)?test\.mbt$' | xargs grep -l '^test ' 2>/dev/null)" ] || empty="$empty sf/sf.internal_test"
[ -n "$(ls src/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$')" ] || empty="$empty sf/sf.blackbox_test"
[ -n "$(ls src/*_wbtest.mbt 2>/dev/null)" ] || empty="$empty sf/sf.whitebox_test"
export MBC_EMPTY_TESTS="$empty"
export MBC_LIGHT_TESTS="sf/sf.internal_test sf/sf.blackbox_test sf/sf.whitebox_test sf/studio_pages/studio_pages.whitebox_test"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
moon_test_native -p stillfail/sf -p stillfail/sf/studio_pages > "$out" 2>&1
code=$?
tail -${LINES_OUT:-40} "$out"
# (an answer of the core's these tests asked and that is not kept beside them: AGENTS.md says where it comes from)
if grep -q 'kept-answers-ask {' "$out"; then
  grep 'kept-answers-ask {' "$out" | sort -u >&2
  echo "sf-ui: answers asked and not kept (AGENTS.md)" >&2
  exit 1
fi
exit "$code"
