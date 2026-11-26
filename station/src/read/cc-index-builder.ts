import type { BackfillOptions } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare requested copy destinations, chat names and latest conversations with the same builder, the MoonBit one
/// (station/mb, src/cc; `binary`: the program, a test's own where it gives one).
export class CcIndexBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { select: { mode: "cc-index", options: { binary, config: options.readers, logAt: "readers" } }, args: ["--builder", "cc-index", "--db", path] },
      "session",
      "session conversation preparation",
      (key, cancel) => ({
        session: key.slice(1), ...(key[0] === "n" ? { name: true } : {}),
        ...(key[0] === "l" ? { latest: true } : {}), ...(cancel ? { cancel: true } : {}),
      }),
    );
  }

  override ready(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    return super.ready(sessions.map((session) => `c${session}`), signal);
  }

  readyNames(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    return super.ready(sessions.map((session) => `n${session}`), signal);
  }

  readyLatest(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    return super.ready(sessions.map((session) => `l${session}`), signal);
  }
}
