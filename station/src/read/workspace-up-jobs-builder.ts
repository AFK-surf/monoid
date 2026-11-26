import type { BackfillOptions } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare the old station-wide up-job lookup in bounded batches after handover, by the MoonBit builder (station/mb,
/// src/upjobs `workspace_step`; `binary`: the program, a test's own where it gives one).
export class WorkspaceUpJobsBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { select: { mode: "workspace-up-jobs", options: { binary, config: options.readers, logAt: "readers" } }, args: ["--builder", "workspace-up-jobs", "--db", path] },
      "scope",
      "workspace up jobs preparation",
    );
  }
}
