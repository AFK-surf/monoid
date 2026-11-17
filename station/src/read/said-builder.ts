import { readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// The requested chats alone; concurrent sidebar and archive reads share each chat's progress. By the MoonBit builder
/// (station/mb, src/said, on a store with the legacy lookup too), which takes the backfill permit only for its writes
/// (`binary`: the program, a test's own where it gives one).
export class SaidBuilder extends RequestedBuilder<number> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "said", "--db", path], lazy: true }, "thread", "sidebar said state");
  }
}
