import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// A scope of the recent chat list: a workspace's (`ws`) as one home (`home`) sees it, `ws` null for every workspace.
export type RecentChatScope = { ws: string | null; home: string | null };

/// Requests share a scope's work and each unfinished scope returns to the back of the line, by the MoonBit builder
/// (station/mb, src/recent; `binary`: the program, a test's own where it gives one).
export class RecentChatBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("recent-chat", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "recent-chat", "--db", path] },
      "scope",
      "recent chat preparation",
    );
  }

  readyScope(scope: RecentChatScope, signal?: AbortSignal): Promise<void> {
    return this.ready([JSON.stringify([scope.ws, scope.home])], signal);
  }
}
