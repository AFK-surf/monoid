// A video's poster is found, made and kept with no synchronous call of node:fs on the main thread (station/AGENTS.md,
// the main thread waits on nothing): GET /sessions/:key/poster held every device and agent behind its stats, its
// temporary directory and its rename. Counted as main-thread-waits.test.ts counts them.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { after, test } from "node:test";
import { poster, posterPath } from "../src/drive/posters.ts";
import { timeFiles } from "../src/ops/file-waits.ts";
import { WAITED_MS } from "../src/ops/waits.ts";
import { platform } from "../src/platform/index.ts";

const WINDOWS = process.platform === "win32";

let at = 0;
const files = timeFiles(() => (at += WAITED_MS));
after(() => files.stop());

/// The synchronous calls of node:fs `work` made on this thread.
async function waited<T>(work: () => Promise<T>): Promise<{ value: T; calls: number; by: string[] }> {
  files.take();
  const value = await work();
  const w = files.take();
  return { value, calls: w.calls, by: [...w.by.keys()] };
}

/// A machine whose only maker of posters is an ffmpeg that writes a JPEG and counts how often it ran.
function machine() {
  const dir = mkdtempSync(join(tmpdir(), "posters-"));
  const bin = join(dir, "bin");
  mkdirSync(bin);
  const runs = join(dir, "runs");
  writeFileSync(join(bin, "ffmpeg"), `#!/bin/sh\necho x >> '${runs}'\nfor last; do :; done\nprintf 'JPEG' > "$last"\n`);
  chmodSync(join(bin, "ffmpeg"), 0o755);
  const video = join(dir, "film.mp4");
  writeFileSync(video, "not really a film");
  const quickLook = platform.hasQuickLook;
  const path = process.env.PATH;
  (platform as { hasQuickLook: boolean }).hasQuickLook = false;
  process.env.PATH = `${bin}${delimiter}${path ?? ""}`;
  return {
    dir,
    video,
    thumbs: join(dir, "thumbs"),
    runs: () => (existsSync(runs) ? readFileSync(runs, "utf8").split("\n").filter(Boolean).length : 0),
    close: () => {
      (platform as { hasQuickLook: boolean }).hasQuickLook = quickLook;
      process.env.PATH = path;
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

test("a poster made, asked twice at once and found kept waits the main thread on no synchronous call of node:fs", { skip: WINDOWS && "a fake ffmpeg here is a shell script" }, async () => {
  const m = machine();
  try {
    const made = await waited(() => Promise.all([poster(m.video, m.thumbs), poster(m.video, m.thumbs)]));
    assert.deepEqual(made.value, [posterPath(m.video, m.thumbs), posterPath(m.video, m.thumbs)]);
    assert.equal(made.calls, 0, made.by.join(" | "));
    assert.equal(m.runs(), 1, "asked twice at once, made once");
    assert.equal(readFileSync(posterPath(m.video, m.thumbs), "utf8"), "JPEG");
    assert.deepEqual(readdirSync(m.thumbs).filter((f) => f.startsWith(".poster-")), [], "its work left nothing behind");

    const kept = await waited(() => poster(m.video, m.thumbs));
    assert.equal(kept.value, posterPath(m.video, m.thumbs));
    assert.equal(kept.calls, 0, kept.by.join(" | "));
    assert.equal(m.runs(), 1, "found kept, not made again");
  } finally {
    m.close();
  }
});

test("a video none can be made for, and one not there, wait the main thread on no synchronous call of node:fs", async () => {
  const m = machine();
  try {
    // No maker at all: the PATH names only an empty directory.
    process.env.PATH = join(m.dir, "none");
    const none = await waited(() => poster(m.video, m.thumbs));
    assert.equal(none.value, null);
    assert.equal(none.calls, 0, none.by.join(" | "));
    const gone = await waited(() => poster(join(m.dir, "gone.mp4"), m.thumbs));
    assert.equal(gone.value, null);
    assert.equal(gone.calls, 0, gone.by.join(" | "));
  } finally {
    m.close();
  }
});
