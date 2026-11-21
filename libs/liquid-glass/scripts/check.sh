#!/bin/bash
# The liquid glass library on its own (mbui beside it, ../mbui): the determinism lint with this module's detlint.json,
# its packages type-checked on native and js, then its tests, the library's and the gallery's (CI's check-liquid-glass;
# here as well, they take seconds).
D="$(cd "$(dirname "$0")" && pwd)"
A=$(cd "$D/.." && pwd)
MBUI_DIR=$(cd "$A/../mbui" && pwd)
. "$MBUI_DIR/scripts/env.sh"
"$MBUI_DIR/scripts/detlint" "$A" || exit 1
cd "$A"
moon check --target native --output-json 2>&1 | "$MBUI_DIR/scripts/chk" errs
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
moon check --target js --output-json 2>&1 | "$MBUI_DIR/scripts/chk" errs
[ "${PIPESTATUS[0]}" = 0 ] || exit 1
# (the kinds of test program a package has none of, not built; and its test programs compiled without optimising, as
# libs/sf-ui/scripts/check.sh and mbui's test_native.sh compile library tests)
empty=""
light=""
for p in lg pages; do
  d="src/$p"
  [ -n "$(ls "$d"/*.mbt 2>/dev/null | grep -vE '_(wb)?test\.mbt$' | xargs grep -l '^test ' 2>/dev/null)" ] || empty="$empty $p/$p.internal_test"
  [ -n "$(ls "$d"/*_test.mbt 2>/dev/null | grep -v '_wbtest\.mbt$')" ] || empty="$empty $p/$p.blackbox_test"
  [ -n "$(ls "$d"/*_wbtest.mbt 2>/dev/null)" ] || empty="$empty $p/$p.whitebox_test"
  light="$light $p/$p.internal_test $p/$p.blackbox_test $p/$p.whitebox_test"
done
export MBC_EMPTY_TESTS="$empty"
export MBC_LIGHT_TESTS="$light"
moon_test_native -p liquid-glass/lg -p liquid-glass/pages 2>&1 | tail -${LINES_OUT:-40}
exit "${PIPESTATUS[0]}"
