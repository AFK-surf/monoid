// The station's reader thread, only where the MoonBit program is not (read/pool.ts `start`): what of the reads is
// not in a table of ops (read/serve-reads.ts), a checkpoint and a card's queued pages. Every other read, and these too
// where it is there, is the program's (read/pool.ts MOVED, HISTORY).
import { serveReads } from "./serve-reads.ts";

serveReads({});
