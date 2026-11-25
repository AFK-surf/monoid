import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare old archive marks on request, sharing the work and stopping when no archive check needs it, by the MoonBit
/// builder (station/mb, src/marks; `binary`: the program, a test's own where it gives one).
export class ArchiveMarkBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("archive-marks", { binary, config: options.readers, logAt: "readers" }), args: ["--builder", "archive-marks", "--db", path] },
      "scope",
      "archive mark preparation",
    );
  }

  readyIndex(signal?: AbortSignal): Promise<void> { return this.ready(["all"], signal); }
}
