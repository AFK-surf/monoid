// Shared contract for importing conversations from external tools on this station's machine (T3 Code first).
import type { RuntimeKind } from "../agents/runtime.ts";
import type { Hub } from "../sessions/hub.ts";
import type { Roots as MachineRoots } from "../read/machine.ts";

/// Summary of one external session source probed on this station.
export type ImportSourceSummary = {
  id: string;
  name: string;
  available: boolean;
  dataPath: string | null;
  activeCount: number;
  archivedCount: number;
  importedCount: number;
  error: string | null;
};

/// One conversation discovered in an external source, shown in Settings > Import.
export type ImportCandidate = {
  source: string;
  id: string;
  title: string;
  project: string | null;
  cwd: string | null;
  provider: string | null;
  runtime: RuntimeKind | null;
  model: string | null;
  effort: string | null;
  messageCount: number;
  updatedAt: number;
  createdAt: number;
  archived: boolean;
  nativeResumable: boolean;
  /// Existing still.fail session key if this external thread is already imported.
  session: string | null;
};

/// One user or assistant message read from an external thread.
export type ImportMessage = {
  role: "user" | "assistant";
  text: string;
  at: number;
};

/// Full external thread payload loaded when importing one session.
export type ImportThreadDetail = ImportCandidate & {
  /// Native runtime conversation/thread ID (e.g. agy conversation UUID, claude session UUID, codex rollout ID).
  nativeId: string | null;
  /// Directory or file holding the native runtime state on disk, when detected.
  nativePath: string | null;
  messages: ImportMessage[];
};

export type ImportRunRequest = {
  /// Specific external thread IDs to import. When omitted, imports all unimported active threads (plus archived when `includeArchived` is true).
  ids?: string[];
  /// Include archived external threads when running a one-click batch import without explicit `ids`.
  includeArchived?: boolean;
};

export type ImportItemOutcome = {
  id: string;
  title: string;
  status: "imported" | "skipped" | "failed";
  session?: string;
  thread?: number;
  resumed?: boolean;
  error?: string;
};

export type ImportRunResult = {
  source: string;
  imported: number;
  skipped: number;
  failed: number;
  items: ImportItemOutcome[];
};

/// Overridable paths for tests and custom station environments.
export type ImportOptions = {
  t3DataDir?: string;
  machineRoots?: MachineRoots;
};

export type PrepareNativeInput = {
  detail: ImportThreadDetail;
  runtime: RuntimeKind;
  profileHome: string;
  dataDir: string;
  cwd: string;
  options?: ImportOptions;
};

/// One pluggable external session importer (register new sources in `service.ts`).
export interface ImportSource {
  readonly id: string;
  readonly name: string;
  probe(options?: ImportOptions): Promise<Omit<ImportSourceSummary, "importedCount">>;
  list(opts?: { includeArchived?: boolean }, options?: ImportOptions): Promise<ImportCandidate[]>;
  read(id: string, options?: ImportOptions): Promise<ImportThreadDetail | null>;
  prepareNative?(input: PrepareNativeInput): Promise<boolean>;
}

export type ImportRunnerContext = {
  hub: Hub;
  createdBy: string;
  ws: string | null;
  options?: ImportOptions;
};
