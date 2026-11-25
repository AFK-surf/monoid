import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// An old binding index is shared by readers while they need it, and stops when none do. Built by the MoonBit builder
/// (station/mb, src/bindings; `binary`: the program, a test's own where it gives one).
export class SessionBindingsBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("session-bindings", { binary, config: options.readers, logAt: "readers" }), args: ["--builder", "session-bindings", "--db", path] },
      "scope",
      "session binding preparation",
    );
  }

  readyIndex(signal?: AbortSignal): Promise<void> { return this.ready(["all"], signal); }
}
