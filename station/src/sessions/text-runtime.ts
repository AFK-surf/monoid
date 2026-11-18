// One text-only turn of a Claude Code or Codex profile, for what asks a model for text alone: a chat's new title
// (regenerate-title.ts), a station app's completion (apps/completion.ts). It is a runtime session of its own, opened
// `textOnly` (the drivers': Claude Code with no tools, no MCP server and no session kept; Codex's thread ephemeral, in a
// read-only sandbox, with no shell and its MCP servers off), on the profile's own login. The chat's agent, its turn
// and its files are not touched.
import type { AgentDriver, AgentSession, OpenOptions, RuntimeEvent } from "../agents/runtime.ts";
import { wall } from "../ops/fibers.ts";

/// The most of an answer's text kept, in characters.
export const SAID_MOST = 256_000;

/// Why no text came: its turn failed (`detail`: what the runtime said), it used a tool, its process went away, it said
/// more than it may, or the caller called it off.
export class RuntimeTextError extends Error {
  readonly problem: "failed" | "tool" | "closed" | "too large" | "aborted";
  readonly detail: string;
  constructor(problem: RuntimeTextError["problem"], detail = "") {
    super(`text-only turn ${problem}${detail === "" ? "" : `: ${detail}`}`);
    this.problem = problem;
    this.detail = detail;
  }
}

/// `input` asked of a session opened on `driver` with `options` (made text-only here), its answer's text returned.
/// Aborted by `signal`, or once it has answered or failed, the session is interrupted and disposed (its process ended,
/// for Claude Code; its thread let go, for Codex's shared app-server), then `after` runs (a working directory removed).
export async function runtimeText(
  driver: AgentDriver,
  options: OpenOptions,
  input: string,
  signal: AbortSignal,
  after?: () => Promise<unknown>,
  most = SAID_MOST,
): Promise<string> {
  let said = "";
  let textId = "";
  let usedTool = false;
  let complete!: (text: string) => void;
  let failed!: (error: Error) => void;
  const ended = new Promise<string>((resolve, reject) => { complete = resolve; failed = reject; });
  void ended.catch(() => {});
  const events = (event: RuntimeEvent) => {
    if (event.type === "live") {
      const step = event.event;
      if (step.kind === "start" && step.step === "tool") usedTool = true;
      if (step.kind === "start" && step.step === "text" && !step.subagent && step.parent === undefined) { textId = step.id; said = ""; }
      if (step.kind === "delta" && step.field === "text" && step.id === textId) {
        said += step.text;
        if (said.length > most) failed(new RuntimeTextError("too large"));
      }
    } else if (event.type === "turnEnded") {
      if (usedTool) failed(new RuntimeTextError("tool"));
      else if (event.outcome.kind === "failed") failed(new RuntimeTextError("failed", event.outcome.message));
      else if (event.outcome.kind === "aborted") failed(new RuntimeTextError("aborted"));
      else complete(said);
    } else if (event.type === "closed") failed(new RuntimeTextError("closed", event.why));
  };
  let finished = false;
  let agent: AgentSession | null = null;
  let afterRun = false;
  const runAfter = () => {
    if (afterRun || after === undefined) return;
    afterRun = true;
    void after().catch(() => {});
  };
  const end = (session: AgentSession) => {
    void (async () => {
      if (session.busy()) await Promise.race([session.abort().catch(() => {}), wall.sleep(2000)]);
      await session.dispose().catch(() => {});
      runAfter();
    })();
  };
  const onAbort = () => failed(new RuntimeTextError("aborted"));
  if (signal.aborted) onAbort();
  else signal.addEventListener("abort", onAbort, { once: true });
  const opening = driver.open({ ...options, textOnly: true }, events);
  // One opened once this has ended is ended at once; one that failed to open has nothing to end.
  opening.then((session) => { agent = session; if (finished) end(session); }, () => { if (finished) runAfter(); });
  try {
    const session = await Promise.race([opening, ended.then(() => { throw new RuntimeTextError("closed", "it ended before it was asked"); })]);
    await Promise.race([session.prompt(input), ended]);
    return await ended;
  } finally {
    finished = true;
    signal.removeEventListener("abort", onAbort);
    if (agent !== null) end(agent);
    else void opening.catch(() => runAfter());
  }
}
