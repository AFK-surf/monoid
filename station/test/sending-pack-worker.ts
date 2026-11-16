// A file of tens of MB packed and unpacked in a worker of a small heap (sending-pack.test.ts): what of memory the pack
// and its taking held at most, as they went.
import { setFlagsFromString } from "node:v8";
import { runInNewContext } from "node:vm";
import { parentPort, workerData } from "node:worker_threads";
import type { Bytes } from "../src/mesh/bus.ts";
import { type PackEntry, packBytes, receivePack } from "../src/replica/sending.ts";

const { entry, there } = workerData as { entry: PackEntry; there: string };
/// What is held now, the garbage collected first: what is kept alive, not what V8 has yet to collect, which is when it
/// gets to it (16.1 MiB once for this file in CI). (A worker takes no --expose-gc: the flag set here, gc taken from a
/// context made after it.)
setFlagsFromString("--expose-gc");
const gc = runInNewContext("gc") as () => void;
const live = () => {
  gc();
  return process.memoryUsage();
};
const at = live();
let heap = 0;
let buffers = 0;
let sent = 0;
const took: PackEntry[] = [];
async function* measured(bytes: Bytes): Bytes {
  for await (const piece of bytes) {
    sent += piece.length;
    const m = live();
    heap = Math.max(heap, m.heapUsed);
    buffers = Math.max(buffers, m.arrayBuffers);
    yield piece;
  }
}
await receivePack(there, measured(packBytes([entry], true, took)), { strict: true, name: entry.hash, count: 1 });
parentPort!.postMessage({ heap, buffers, before: { heap: at.heapUsed, buffers: at.arrayBuffers }, sent, took: took.length });
