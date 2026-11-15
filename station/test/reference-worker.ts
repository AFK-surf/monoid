// The reads as a reader thread answered them before the MoonBit program took them (read/pool.ts MOVED, HISTORY): what
// the program's answers are compared with (`REFERENCE_WORKER`, given to a test's Readers). The station's own reader
// thread answers none of them (src/read/worker.ts).
import { ops } from "../src/read/ops.ts";
import { serveReads } from "../src/read/serve-reads.ts";

serveReads(ops);
