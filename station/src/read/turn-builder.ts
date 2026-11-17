import { readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare exact counts only for old sessions whose summaries were requested. By the MoonBit builder (station/mb,
/// src/turns), which takes the backfill permit only for its writes (`binary`: the program, a test's own where it gives
/// one).
export class TurnBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "turn-counts", "--db", path], lazy: true }, "session", "old turn counts");
  }
}
