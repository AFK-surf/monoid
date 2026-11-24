import { type BackfillOptions, readerBinary } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare the old threads whose widget sources are needed by a delivery, by the MoonBit builder (station/mb,
/// src/widgets; `binary`: the program, a test's own where it gives one).
export class WidgetSourcesBuilder extends RequestedBuilder<number> {
  constructor(path: string, options: BackfillOptions = {}, binary = readerBinary()) {
    super(options, { binary, args: ["--builder", "widget-sources", "--db", path] }, "thread", "widget source preparation");
  }
}
