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
moon test --target native --release -p liquid-glass/lg -p liquid-glass/pages 2>&1 | tail -${LINES_OUT:-40}
exit "${PIPESTATUS[0]}"
