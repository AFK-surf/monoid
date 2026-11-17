// The station's MoonBit program given to what starts it (a builder, a backfill) as a script that stands for it at a
// path of the test's: one that ends at its first start (the program's process dying under its builder), one that ends
// every time, one that counts its starts, each else the program itself. A script, as the program is a process of its
// own: the tests run where a shell is (CI's Linux, a Mac).
import { chmodSync, renameSync, writeFileSync } from "node:fs";
import { readerBinary } from "../src/read/mb-reader.ts";

const quoted = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;

/// The script at `path` that does `body`, written whole in place of what was there (a process started from it before
/// goes on as it was).
function script(path: string, body: string): string {
  writeFileSync(`${path}.new`, `#!/bin/sh\n${body}\n`);
  chmodSync(`${path}.new`, 0o755);
  renameSync(`${path}.new`, path);
  return path;
}

/// The program, as the scripts run it with what they were given.
const program = () => `exec ${quoted(readerBinary())} "$@"`;

/// The program at `path`, but that its first start ends at once (status 1), writing `marker`.
export function endsOnce(path: string, marker: string): string {
  return script(path, `if [ ! -e ${quoted(marker)} ]; then : > ${quoted(marker)}; exit 1; fi\n${program()}`);
}

/// A program at `path` that ends at once (status 1) each time it is started.
export function endsAlways(path: string): string {
  return script(path, "exit 1");
}

/// The program at `path`, each start counted as an `x` written to `starts`.
export function counted(path: string, starts: string): string {
  return script(path, `printf x >> ${quoted(starts)}\n${program()}`);
}

/// The program itself at `path`.
export function theProgram(path: string): string {
  return script(path, program());
}
