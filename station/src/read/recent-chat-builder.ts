import type { RecentChatScope } from "../store/chat-list-prepare.ts";
import { readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Requests share a scope's work and each unfinished scope returns to the back of the line, by the MoonBit builder
/// (station/mb, src/recent; `binary`: the program, a test's own where it gives one).
export class RecentChatBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "recent-chat", "--db", path] }, "scope", "recent chat preparation");
  }

  readyScope(scope: RecentChatScope, signal?: AbortSignal): Promise<void> {
    return this.ready([JSON.stringify([scope.ws, scope.home])], signal);
  }
}
