// A background job's log as the station reads it (the Rust station's jobs.rs `output_at`, `tail`): when it last grew
// and its last lines, off the main thread's waits (node:fs/promises). The pages' reads of jobs (GET /jobs, /jobs/:id,
// /jobs/:id/log) are the MoonBit reader's; the TypeScript that answered them before, and the synchronous reads this
// replaced, are the tests' (test/reference/jobs.ts).
import { open, stat } from "node:fs/promises";

/// How much of a log `tail` reads at most.
const LOG_BYTES = 64 * 1024;

/// output_at: when a log last grew (ms), if it has anything in it.
export async function outputAt(path: string): Promise<number | null> {
  try {
    const meta = await stat(path, { bigint: true });
    if (meta.size === 0n || meta.mtimeNs < 0n) return null;
    return Number(meta.mtimeNs / 1_000_000n);
  } catch {
    return null;
  }
}

/// tail: the last `lines` lines of a log, from at most its last LOG_BYTES; "" when it does not read. A log cut where it
/// is (ops/storage.ts `rotateInPlace`: a job's at JOB_LOG_CAP) with fewer lines than asked since is read on into what it
/// kept of before (`<log>.1`), so a log just cut still shows what led up to it.
export async function tail(path: string, lines: number): Promise<string> {
  const now = await tailLines(path);
  if (now.length >= lines) return now.slice(now.length - lines).join("\n");
  const before = await tailLines(`${path}.1`);
  const all = [...before, ...now];
  return all.slice(Math.max(0, all.length - lines)).join("\n");
}

/// The lines of at most the last LOG_BYTES of a file; none when it does not read.
async function tailLines(path: string): Promise<string[]> {
  let file: Awaited<ReturnType<typeof open>>;
  try {
    file = await open(path, "r");
  } catch {
    return [];
  }
  let bytes: Buffer;
  try {
    let size = LOG_BYTES;
    try {
      size = (await file.stat()).size;
    } catch {
      // Metadata failing: read a bounded portion from the start.
    }
    const from = Math.max(0, size - LOG_BYTES);
    const chunks: Buffer[] = [];
    const piece = Buffer.alloc(64 * 1024);
    try {
      // The job may keep writing while this is read. Stop at the end seen above; later writes are read next time.
      for (let at = from; at < size; ) {
        const { bytesRead: n } = await file.read(piece, 0, Math.min(piece.length, size - at), at);
        if (n === 0) break;
        chunks.push(Buffer.from(piece.subarray(0, n)));
        at += n;
      }
    } catch {
      // read_to_end failing keeps what it read.
    }
    bytes = Buffer.concat(chunks);
  } finally {
    await file.close().catch(() => undefined);
  }
  return rustLines(new TextDecoder("utf-8").decode(bytes));
}

/// str::lines: split at \n (a \r before it goes too); no last empty line.
export function rustLines(text: string): string[] {
  if (text === "") return [];
  const parts = text.split("\n");
  const ended = parts.at(-1) === "";
  if (ended) parts.pop();
  return parts.map((l, i) => (i < parts.length - 1 || ended) && l.endsWith("\r") ? l.slice(0, -1) : l);
}
