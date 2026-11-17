import { readerBinary } from "../read/mb-reader.ts";
import { RequestedBuilder } from "../read/requested-builder.ts";

/// The search's candidate scopes prepared by the MoonBit builder (station/mb, src/searchscope; `binary`: the program, a
/// test's own where it gives one).
export class SearchScopeBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: { previousGone?: Promise<void>; priority?: SharedArrayBuffer } = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "search-scope", "--db", path] }, "scope", "search scope preparation");
  }

  prepare(): Promise<void> { return this.ready(["all"]); }
}
