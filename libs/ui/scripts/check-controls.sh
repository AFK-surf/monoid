#!/bin/bash
# ui.monoid controls, liquid glass, and Live Studio check: the determinism lint with this module's
# detlint.json, zero raw .glass( guard in src/controls, native + js typecheck, and controls/glass/studio tests.
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
. "$A/scripts/env.sh"
"$A/scripts/detlint" "$A" || exit 1
# Enforce zero raw .glass( / Glass::liquid( / Glass::frosted( in controls non-test sources (all liquid glass must
# go through @glass; image_reveal_node.mbt is the sole progressive-decode frosted blur exception).
raw_glass=$(grep -rnE '\.glass\(|Glass::liquid\(|Glass::frosted\(' "$A/src/controls" --include='*.mbt' | grep -vE '_(wb)?test\.mbt:' | grep -v '/image_reveal_node\.mbt:' || true)
if [ -n "$raw_glass" ]; then
  echo "ui/controls: raw .glass(/Glass::liquid(/Glass::frosted( outside @glass (delegate to libs/ui/src/glass):" >&2
  echo "$raw_glass" >&2
  exit 1
fi
cd "$A"
for t in native js; do
  moon check --target $t --output-json 2>&1 | "$A/scripts/chk" errs
  [ "${PIPESTATUS[0]}" = 0 ] || exit 1
done
# (the kinds of test program this package has none of, not built; and its test programs compiled without optimising, as
# apps/mbui/scripts/test.sh and ui's test_native.sh compile the library's tests)
empty=""
[ -n "$(ls src/controls/*.mbt 2>/dev/null | grep -vE '_(wb)?test\.mbt$' | xargs grep -l '^test ' 2>/dev/null)" ] || empty="$empty controls/controls.internal_test"
[ -n "$(ls src/controls/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$')" ] || empty="$empty controls/controls.blackbox_test"
[ -n "$(ls src/controls/*_wbtest.mbt 2>/dev/null)" ] || empty="$empty controls/controls.whitebox_test"
export MBC_EMPTY_TESTS="$empty"
export MBC_LIGHT_TESTS="controls/controls.internal_test controls/controls.blackbox_test controls/controls.whitebox_test glass/glass.whitebox_test studio_pages/studio_pages.whitebox_test"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
moon_test_native -p ui/controls -p ui/glass -p ui/studio_pages > "$out" 2>&1
code=$?
tail -${LINES_OUT:-40} "$out"
# (an answer of the core's these tests asked and that is not kept beside them: AGENTS.md says where it comes from)
if grep -q 'kept-answers-ask {' "$out"; then
  grep 'kept-answers-ask {' "$out" | sort -u >&2
  echo "ui/controls: answers asked and not kept (AGENTS.md)" >&2
  exit 1
fi
exit "$code"
