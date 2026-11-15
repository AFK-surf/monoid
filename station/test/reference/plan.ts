// The tools an agent keeps its checklist with, whose calls a transcript keeps whole (transcript.ts here): a tool that
// says the list whole (Claude Code's TodoWrite, Codex's update_plan), and Claude Code's task tools, which change it an
// item at a time (TaskCreate, TaskUpdate). The list itself is read from their calls by the live view
// (mb/src/reader/live.mbt `read_plan`).

/// The calls a checklist is kept with: read whole, never cut short (transcript.ts here).
export const isPlanTool = (tool: string) => tool === "TodoWrite" || tool === "update_plan" || tool === "TaskCreate" || tool === "TaskUpdate";
