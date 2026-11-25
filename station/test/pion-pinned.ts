// The Pion reader a test run was given (`native.ts run pion-reader` sets STILLFAIL_PION_READER), or none. A run given
// none has STILLFAIL_PION_READER set to UNPINNED_PION by setup-env.mjs, a path where nothing is: mb-reader.ts
// `pionBinary()` takes a set path as the only one, so no test picks up a `stillfail-pion` it was not given (a
// developer's `pion/station/_build/` one, of whatever source). A dual test asks `pinnedPion()` whether it was given one
// (and fails when that one is not there) or skips, naming what is missing.
import { resolve } from "node:path";

export const UNPINNED_PION = resolve("/stillfail-pion-unpinned-sentinel/stillfail-pion");

export function pinnedPion(): string | undefined {
  const set = process.env.STILLFAIL_PION_READER?.trim();
  return set && resolve(set) !== UNPINNED_PION ? set : undefined;
}
