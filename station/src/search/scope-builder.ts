import { type BackfillOptions, resolveReaderSelection } from "../read/mb-reader.ts";
import { RequestedBuilder } from "../read/requested-builder.ts";

/// The search's candidate scopes prepared by the MoonBit builder (station/mb, src/searchscope; `binary`: the program, a
/// test's own where it gives one).
export class SearchScopeBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("search-scope", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "search-scope", "--db", path] },
      "scope",
      "search scope preparation",
    );
  }

  prepare(): Promise<void> { return this.ready(["all"]); }
}
