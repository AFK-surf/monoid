import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// A requested old index is shared by the readers waiting for it; abandoned requests stop scheduling more batches. By
/// the MoonBit builder (station/mb, src/sessions; `binary`: the program, a test's own where it gives one).
export class SessionListBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("session-list", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "session-list", "--db", path] },
      "scope",
      "session list preparation",
    );
  }

  readyIndex(signal?: AbortSignal): Promise<void> { return this.ready(["all"], signal); }
  readySearch(signal?: AbortSignal): Promise<void> { return this.ready(["search"], signal); }
}
