// The tests' MoonBit program (station/mb/src/reader_harness, `stillfail-reader-harness`): every package's harness,
// asked by `--builder harness-<package>`, kept out of the reader every station runs (src/read/mb-reader.ts). Here as
// the tests' own, src/read/ holding only the station's code: STILLFAIL_MB_HARNESS (scripts/native.ts run
// reader-harness, CI's check-station), else where station/mb/build.sh --harness puts it in a checkout for this
// machine. Never the reader: it has no harness, and a test would fail on its usage line instead of skipping.
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { mbReaderBinary } from "../src/read/mb-reader.ts";

const HOST: Record<string, string> = { "darwin-arm64": "darwin-arm64", "linux-x64": "linux-x64", "linux-arm64": "linux-arm64" };

let found: string | null | undefined;
/// The program, or null where it is not built here (a test skips, saying so).
export function mbHarnessBinary(): string | null {
  if (found !== undefined) return found;
  const host = HOST[`${process.platform}-${process.arch}`];
  const candidates = [
    process.env.STILLFAIL_MB_HARNESS,
    host ? fileURLToPath(new URL(`../mb/_build/stillfail-reader-harness-${host}`, import.meta.url)) : undefined,
  ];
  found = candidates.find((p) => p !== undefined && p !== "" && existsSync(p)) ?? null;
  return found;
}

/// The program, failing with where it comes from where it is not built.
export function harnessBinary(): string {
  const binary = mbHarnessBinary();
  if (binary === null) throw new Error("the tests' MoonBit program (stillfail-reader-harness) is not built here (station/mb/build.sh --harness, or STILLFAIL_MB_HARNESS)");
  return binary;
}

/// Why a test of a package's harness is skipped here, or false.
export const noHarness = (): string | false => (mbHarnessBinary() === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false);

let stationWrapper: string | null | undefined;
/// The frozen MoonBit whole-station binary (`stillfail-reader-harness`, which holds `station_main`), paired with
/// `STILLFAIL_MB_READER` pointing to the slimmed `stillfail-reader` so internal `--sessions`/`--builder`/`--data`
/// subprocesses spawned by `station_main` exec into the shipped reader even under `noNode()` test environments.
export function mbStationBinary(): string | null {
  if (stationWrapper !== undefined) return stationWrapper;
  const harness = mbHarnessBinary();
  const reader = mbReaderBinary();
  if (harness === null || reader === null) {
    stationWrapper = null;
    return null;
  }
  if (process.platform === "win32") {
    stationWrapper = harness;
    return stationWrapper;
  }
  const dir = mkdtempSync(join(tmpdir(), "sf-mb-station-"));
  const path = join(dir, "stillfail-reader");
  const q = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
  writeFileSync(path, `#!/bin/bash\nSTILLFAIL_MB_READER=${q(reader)} exec -a "$0" ${q(harness)} "$@"\n`, { mode: 0o755 });
  process.once("exit", () => {
    try { rmSync(dir, { recursive: true, force: true }); } catch {}
  });
  stationWrapper = path;
  return stationWrapper;
}
