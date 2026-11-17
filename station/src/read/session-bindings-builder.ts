import { readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// An old binding index is shared by readers while they need it, and stops when none do. Built by the MoonBit builder
/// (station/mb, src/bindings; `binary`: the program, a test's own where it gives one).
export class SessionBindingsBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "session-bindings", "--db", path] }, "scope", "session binding preparation");
  }

  readyIndex(signal?: AbortSignal): Promise<void> { return this.ready(["all"], signal); }
}
