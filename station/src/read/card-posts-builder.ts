import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare the old threads' posts that carry a card or options, by the MoonBit builder (station/mb, src/cards;
/// `binary`: the program, a test's own where it gives one).
export class CardPostsBuilder extends RequestedBuilder<number> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("card-posts", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "card-posts", "--db", path] },
      "thread",
      "card post preparation",
    );
  }
}

/// The old closed-card lookup, on its own queue, by the MoonBit builder (station/mb, src/lookups).
export class ClosedCardsBuilder extends RequestedBuilder<number> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("closed-cards", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "closed-cards", "--db", path] },
      "thread",
      "closed card preparation",
      (thread, cancel) => ({ thread, cancel, closed: true }),
    );
  }
}

/// Prepare the people-time lookup for only the old chats a read needs, by the MoonBit builder (station/mb,
/// src/lookups).
export class PeopleSinceBuilder extends RequestedBuilder<number> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("people-since", { binary, config: options.readers, logAt: "readers" }).primaryBinary, args: ["--builder", "people-since", "--db", path] },
      "thread",
      "people-time preparation",
      (thread, cancel) => ({ thread, cancel, people: true }),
    );
  }
}
