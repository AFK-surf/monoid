import { type BackfillOptions, resolveReaderSelection } from "./mb-reader.ts";
import { RequestedBuilder } from "./requested-builder.ts";

/// Prepare only the sessions an archive check needs; several checks share each session's work. By the MoonBit builder
/// (station/mb, src/upjobs; `binary`: the program, a test's own where it gives one).
export class SessionUpJobsBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("session-up-jobs", { binary, config: options.readers, logAt: "readers" }), args: ["--builder", "session-up-jobs", "--db", path] },
      "session",
      "session up jobs preparation",
    );
  }
}

/// A requested own chat's first member for its job's name after handover (`[owner, thread]` as JSON a key), sharing and
/// cancelling its bounded batches, by the same MoonBit builder (src/upjobs `job_name_first_step`).
export class JobNameFirstBuilder extends RequestedBuilder<string> {
  constructor(path: string, options: BackfillOptions = {}, binary?: string) {
    super(
      options,
      { binary: () => resolveReaderSelection("session-up-jobs", { binary, config: options.readers, logAt: "readers" }), args: ["--builder", "session-up-jobs", "--db", path] },
      "scope",
      "job name first member",
      (key, cancel) => { const [session, first] = JSON.parse(key) as [string, number]; return { session, first, ...(cancel ? { cancel: true } : {}) }; },
    );
  }
}
