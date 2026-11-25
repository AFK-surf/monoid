// Workspace project & tag summaries and single-project detail views (`projects`, `project`, `tags` topics).
import { opt, struct, vec, type Shape } from "./dsl.ts";

export const PROJECT_SHAPES: Record<string, Shape> = {
  ProjectSummary: struct([
    ["name", "String"],
    ["chatCount", "i64", { client: "I54" }],
    ["runningCount", "i64", { client: "I54" }],
    ["latestActiveAt", "i64", { client: "I54" }],
    ["hasInfo", "bool", { doc: "True when PROJECTS.jsonl holds metadata (note or refs) for this project." }],
  ], { doc: "Compact summary row of one project in the paginated `projects` topic (no long note/refs)." }),
  ProjectsView: struct([
    ["items", vec("ProjectSummary")],
    ["total", "i64", { client: "I54" }],
    ["unclassifiedCount", "i64", { client: "I54" }],
    ["crossCount", "i64", { client: "I54" }],
    ["nextCursor", opt("String"), { doc: "Opaque pagination cursor for the next page; absent on the last page." }],
    ["staleCursor", opt("bool"), { doc: "True when the requested pagination cursor expired or was evicted; caller should restart from page 1." }],
  ], { doc: "Byte-budgeted (<= 32 KB) paginated summary of workspace projects (local SQLite aggregation + cached PROJECTS.jsonl)." }),
  ProjectDetailView: struct([
    ["name", "String"],
    ["note", opt("String")],
    ["refs", vec("String"), { default: true }],
    ["chatCount", "i64", { client: "I54" }],
    ["runningCount", "i64", { client: "I54" }],
    ["latestActiveAt", "i64", { client: "I54" }],
    ["hasInfo", "bool"],
    ["infoRevision", opt("String"), { doc: "Deterministic 16-char content fingerprint of normalized note + ordered refs shared across all pages of a snapshot." }],
    ["nextCursor", opt("String"), { doc: "Opaque pagination cursor for the next page of `refs`; absent on the last page." }],
  ], { doc: "Byte-budgeted (<= 32 KB) detail view for a single project (`project` topic), loaded on demand for settings and preset editors." }),
  TagSummary: struct([
    ["name", "String"],
    ["chatCount", "i64", { client: "I54" }],
  ], { doc: "Compact summary row of one tag in the paginated `tags` topic." }),
  TagsView: struct([
    ["items", vec("TagSummary")],
    ["total", "i64", { client: "I54" }],
    ["nextCursor", opt("String"), { doc: "Opaque pagination cursor for the next page; absent on the last page." }],
    ["staleCursor", opt("bool"), { doc: "True when the requested pagination cursor expired or was evicted; caller should restart from page 1." }],
  ], { doc: "Byte-budgeted (<= 32 KB) paginated summary of workspace tags aggregated from `chat_tag`." }),
};
