// A heap snapshot of the running station, asked for from the command line (`stillfail heap`): what its main thread's
// memory holds, to be opened in Chrome's DevTools (Memory). The command leaves a request in <data>/run; the station,
// which watches that directory, writes the snapshot beside it and says where in an answer. It holds whatever the
// station holds (tokens too), so it is the owner's alone (0600), and only the latest is kept. Taking it holds the
// station for a few seconds.
//
// What a directory's watcher says is not counted on (macOS's FSEvents coalesces a file written and renamed into an
// event named after either, and one that starts a moment after a file came does not tell of it): any event makes the
// station look for a request, and the command touches its request until it is taken and reads its answer as it waits.
import { type FSWatcher, createWriteStream, watch } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, stat, utimes } from "node:fs/promises";
import { join } from "node:path";
import { pipeline } from "node:stream/promises";
import { getHeapSnapshot } from "node:v8";
import { writePrivateSoon } from "./files.ts";
import { log } from "./log.ts";
import { wall } from "./fibers.ts";

const REQUEST = "heap.request";
const ANSWER = "heap.answer";
const SNAPSHOT = /^heap-.*\.heapsnapshot$/;
/// How long the command waits for the station's answer.
const WAIT_MS = 120_000;
/// How often the command looks for its answer, and touches its request while it is not taken.
const LOOK_MS = 250;

export type HeapAnswer = { path: string; bytes: number; ms: number } | { error: string };

const runDir = (data: string) => join(data, "run");

/// Takes a snapshot each time one is asked for, as long as the station runs; how to stop. Every look at the directory
/// is off the main thread and one at a time: what the watcher says while one runs makes one more look after it.
/// `openWatch` is the watcher (tests give one that fails); not persistent, it does not keep the process alive.
export function answerHeapRequests(
  data: string,
  openWatch: (dir: string, listener: () => void) => FSWatcher = (d, listener) => watch(d, { persistent: false }, listener),
): () => void {
  const dir = runDir(data);
  let stopped = false;
  let watcher: FSWatcher | null = null;
  let looking: Promise<void> = Promise.resolve();
  let asked = false;
  const look = () => {
    if (stopped || asked) return;
    asked = true;
    looking = looking.then(async () => {
      asked = false;
      if (stopped) return;
      // One asked for while this one was being taken.
      if (await take()) look();
    });
  };
  const take = async (): Promise<boolean> => {
    // Claimed by renaming it: two station processes (a handover) see it, one takes it.
    const claimed = join(dir, `${REQUEST}.${process.pid}`);
    try {
      await rename(join(dir, REQUEST), claimed);
    } catch {
      return false;
    }
    await rm(claimed, { force: true }).catch(() => {});
    const path = join(dir, `heap-${new Date(wall.now()).toISOString().replace(/[:.]/g, "-")}.heapsnapshot`);
    const started = wall.now();
    let answer: HeapAnswer;
    try {
      for (const name of await readdir(dir)) if (SNAPSHOT.test(name)) await rm(join(dir, name), { force: true });
      await pipeline(getHeapSnapshot(), createWriteStream(path, { mode: 0o600 }));
      answer = { path, bytes: (await stat(path)).size, ms: wall.now() - started };
      log.info("heap", "heap snapshot written", answer);
    } catch (error) {
      await rm(path, { force: true }).catch(() => {});
      answer = { error: (error as Error).message };
      log.warn("heap", "heap snapshot not written", answer);
    }
    await writePrivateSoon(join(dir, ANSWER), JSON.stringify(answer)).catch((error) => log.warn("heap", "heap snapshot's answer not written", { error: (error as Error).message }));
    return true;
  };
  const notWatching = (error: unknown) => log.warn("heap", "not watching for heap snapshot requests", { error: String(error) });
  // Whatever goes wrong here is told, never thrown: an unhandled rejection would end the station (`fs.watch` throws
  // EMFILE at once when Linux's inotify instances run out).
  void mkdir(dir, { recursive: true })
    .then(() => {
      if (stopped) return;
      try {
        const w = openWatch(dir, look);
        watcher = w;
        w.on("error", (error) => {
          notWatching(error);
          if (watcher === w) watcher = null;
          w.close();
        });
      } catch (error) {
        // Not watched: a request is still taken when the station starts, and the command's touches are not seen.
        notWatching(error);
      }
      // One asked for while no station ran.
      look();
    })
    .catch(notWatching);
  return () => {
    stopped = true;
    watcher?.close();
    watcher = null;
  };
}

/// `stillfail-station heap`: asks the running station for a snapshot and waits for its answer; the exit code.
export async function heapCommand(data: string, waitMs = WAIT_MS): Promise<number> {
  const dir = runDir(data);
  const request = join(dir, REQUEST);
  const answerPath = join(dir, ANSWER);
  await rm(answerPath, { force: true });
  await writePrivateSoon(request, String(process.pid));
  let answer: HeapAnswer | null = null;
  for (const until = wall.now() + waitMs; wall.now() < until; ) {
    const said = await readFile(answerPath, "utf8").catch(() => null);
    if (said !== null) {
      answer = JSON.parse(said) as HeapAnswer;
      break;
    }
    // Not taken yet: told again (a station whose watcher missed it, or started after it); taken, it is gone.
    const now = new Date(wall.now());
    await utimes(request, now, now).catch(() => {});
    await wall.sleep(LOOK_MS);
  }
  await rm(answerPath, { force: true });
  if (answer === null) {
    await rm(request, { force: true });
    console.error("the station did not answer: is it running on this data directory?");
    return 1;
  }
  if ("error" in answer) {
    console.error(`the station could not write a heap snapshot: ${answer.error}`);
    return 1;
  }
  console.log(`${answer.path} (${Math.round(answer.bytes / 1048576)} MB, ${answer.ms} ms)`);
  return 0;
}
