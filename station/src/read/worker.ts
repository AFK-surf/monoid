// The station's reader thread, only where the MoonBit program is not (read/pool.ts `start`): a checkpoint, and nothing
// else. Every read, a card's queued pages too, is the program's (read/pool.ts MOVED, HISTORY); how a reader thread
// answered them before is the tests' (test/reference-worker.ts).
import { serveReads } from "./serve-reads.ts";

serveReads({});
