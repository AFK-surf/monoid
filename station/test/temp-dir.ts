import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// A test directory with a short, caller-chosen prefix (the runner's sockets have a 104-byte limit on macOS).
export function tempDir(prefix: string): string {
  const data = mkdtempSync(prefix);
  // Node may exit successfully while an async after hook is waiting on an unref'd timer. Remove the directory even then.
  process.once("exit", () => rmSync(data, { recursive: true, force: true, maxRetries: 3 }));
  return data;
}

/// A database file of its own, for a test whose store's old data is built by the MoonBit program's builders (they
/// read the store's file: one in memory has no step in TypeScript to fall back to).
export const dbFile = (prefix: string): string => join(tempDir(join(tmpdir(), prefix)), "station.db");
