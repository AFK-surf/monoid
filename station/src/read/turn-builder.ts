import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare exact counts only for old sessions whose summaries were requested. By the MoonBit builder (station/mb,
/// src/turns), which takes the backfill permit only for its writes (`binary`: the program, a test's own where it gives
/// one).
export class TurnBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("turn-counts", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "turn-counts", "--db", path], lazy: true },
      "session",
      "old turn counts",
    );
  }
}
