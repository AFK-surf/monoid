import type { BackfillOptions } from "../read/mb-reader.ts";
import { RequestedBuilder } from "../read/requested-builder.ts";

/// The search's candidate scopes prepared by the MoonBit builder (station/mb, src/searchscope; `binary`: the program, a
/// test's own where it gives one).
export class SearchScopeBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { select: { mode: "search-scope", options: { binary, config: options.readers, logAt: "readers" } }, args: ["--builder", "search-scope", "--db", path] },
      "scope",
      "search scope preparation",
    );
  }

  prepare(): Promise<void> { return this.ready(["all"]); }
}
