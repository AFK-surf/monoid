// The reads as a reader thread answered them before the MoonBit program took them (read/pool.ts MOVED, HISTORY), and a
// card's queued pages (`internalCardEditPage`, `internalCardMessagePage`, outside `ops` as a device may not ask them):
// what the program's answers are compared with (`REFERENCE_WORKER`, given to a test's Readers). The station's own
// reader thread answers none of them (src/read/worker.ts).
import { ops } from "../src/read/ops.ts";
import { serveReads } from "../src/read/serve-reads.ts";
import { cardEditPage, cardMessagePage } from "../src/store/card-outbox.ts";

serveReads(ops, {
  internalCardEditPage: (db, a) => cardEditPage(db, a.thread, a.target, a.before),
  internalCardMessagePage: (db, a) => cardMessagePage(db, a.thread, a.target, a.before),
});
