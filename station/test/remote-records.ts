// A remote task's record written as a test's fixture (the station's records are the MoonBit program's to write:
// mb/src/reader/remote_files.mbt `write_json`): whole, renamed into place, there once this returns.
import { randomBytes } from "node:crypto";
import { renameSync, writeFileSync } from "node:fs";
import type { Json } from "../src/store/store.ts";

export function writeJson(path: string, value: Json): Promise<void> {
  const temp = `${path}.${randomBytes(8).toString("hex")}.tmp`;
  writeFileSync(temp, JSON.stringify(value), { mode: 0o600 });
  renameSync(temp, path);
  return Promise.resolve();
}
