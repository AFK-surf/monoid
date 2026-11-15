import { readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare old archive marks on request, sharing the work and stopping when no archive check needs it, by the MoonBit
/// builder (station/mb, src/marks; `binary`: the program, a test's own where it gives one).
export class ArchiveMarkBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "archive-marks", "--db", path] }, "scope", "archive mark preparation");
  }

  readyIndex(signal?: AbortSignal): Promise<void> { return this.ready(["all"], signal); }
}
