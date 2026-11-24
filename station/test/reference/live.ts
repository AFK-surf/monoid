// What the TypeScript station made of each runtime's output before the MoonBit program read it (station/mb/src/claude,
// mb/src/dsh, mb/src/cursor, mb/src/acp; mb/src/reader/agents_own.mbt): live.ts's `LiveFrom*`, claude.ts `turnAfter`,
// and what dsh.ts, cursor.ts and acp.ts (with agy.ts, grok.ts, hermes.ts) did of a line as it was heard and of a
// crash's lines read again, as they were, with what acp.ts's KeptTranscript wrote told as the program tells it
// (`kept`). The tests hold the program to them (test/runtime-cases.ts writes what these say of each case as
// station/mb/src/{dsh,cursor,acp}/as_typescript_said_test.mbt; test/mb-dsh.test.ts, mb-cursor.test.ts, mb-acp.test.ts
// hold that file to these).
import type { LiveEvent } from "../../src/agents/runtime.ts";
import { TOOL_SERVERS, failureOf, stationTool, unreachable, type FailureReason, type PlanItem, type TurnOutcome } from "../../src/agents/runtime.ts";
import { chars } from "../../src/agents/live.ts";
import { wall } from "../../src/ops/fibers.ts";

type Json = any;
type Phase = "starting" | "requesting" | "responding" | "working";
type Step = "text" | "thinking" | "tool";

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const nonEmpty = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);

/// Claude Code's step event, as LiveEvent::Start serializes: fields that are none left out.
function start(id: string, step: Step, tool?: string, input?: string, subagent?: boolean, parent?: string): LiveEvent {
  const event: LiveEvent = { kind: "start", id, step };
  if (tool !== undefined) event.tool = tool;
  if (input !== undefined) event.input = input;
  if (subagent !== undefined) event.subagent = subagent;
  if (parent !== undefined) event.parent = parent;
  return event;
}

/// The most of a call's input kept as it streams in (a file written whole can be large; past this it is cut short).
const INPUT_MOST = 256 * 1024;

type Block = { id: string; step: Step; tool?: string; input?: string; subagent?: string };
export type ClaudeLiveState = { message: string; blocks: [number, Block][]; tools: string[] };

/// Claude Code's partial messages (--include-partial-messages) as live steps. Each content block of a model response is
/// a step: text and thinking end with their block; a tool call ends when its result comes back, which also carries the
/// output (Claude Code does not stream tool output).
export class LiveFromClaude {
  private message = "";
  private blocks = new Map<number, Block>();
  private tools = new Set<string>();

  constructor(state?: ClaudeLiveState) {
    if (state) {
      this.message = state.message;
      this.blocks = new Map(state.blocks);
      this.tools = new Set(state.tools);
    }
  }

  state(): ClaudeLiveState {
    return { message: this.message, blocks: [...this.blocks.entries()], tools: [...this.tools] };
  }

  feed(frame: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const kind = str(frame?.type) ?? "";
    if (kind === "system" && frame.subtype === "status" && frame.status === "requesting") {
      out.push({ kind: "phase", phase: "requesting" });
    } else if (kind === "stream_event") {
      const e = frame.event ?? null;
      // A sub-agent's steps name the tool call (Task/Agent) that started it.
      const parent = nonEmpty(frame.parent_tool_use_id);
      const event = str(e?.type) ?? "";
      if (event === "message_stop" && parent === undefined) out.push({ kind: "phase", phase: "working" });
      const index = Number.isInteger(e?.index) ? (e.index as number) : -1;
      if (event === "message_start") {
        this.message = str(e?.message?.id) ?? String(wall.now());
        this.blocks.clear();
        if (parent === undefined) out.push({ kind: "phase", phase: "responding" });
      } else if (event === "content_block_start") {
        const b = e?.content_block ?? null;
        const type = str(b?.type);
        const step: Step | undefined = type === "text" ? "text" : type === "thinking" ? "thinking" : type === "tool_use" ? "tool" : undefined;
        if (step === undefined) return out;
        const id = step === "tool" && typeof b?.id === "string" ? (b.id as string) : `${this.message}:${index}`;
        const tool = step === "tool" ? (str(b?.name) ?? "tool") : undefined;
        if (step === "tool") this.tools.add(id);
        out.push(start(id, step, tool, undefined, parent !== undefined ? true : undefined, parent));
        this.blocks.set(index, { id, step, tool, input: tool !== undefined ? "" : undefined, subagent: parent });
      } else if (event === "content_block_delta") {
        const block = this.blocks.get(index);
        if (!block) return out;
        const d = e?.delta ?? null;
        const type = str(d?.type);
        if (type === "text_delta") {
          const t = nonEmpty(d.text);
          if (t !== undefined) out.push({ kind: "delta", id: block.id, field: "text", text: t });
        } else if (type === "thinking_delta") {
          const t = nonEmpty(d.thinking);
          if (t !== undefined) out.push({ kind: "delta", id: block.id, field: "text", text: t });
          // Thinking the API leaves out of the stream (its display omitted, as Claude Code asks of newer models) comes
          // as empty deltas, each saying about how many tokens were thought since the last: the only pace there is.
          else if (typeof d.estimated_tokens === "number" && d.estimated_tokens > 0)
            out.push({ kind: "delta", id: block.id, field: "text", text: "", tokens: d.estimated_tokens });
        } else if (type === "input_json_delta") {
          const partial = nonEmpty(d.partial_json);
          if (partial !== undefined) {
            // A call's input streams in after it starts; kept whole (its start, a moment before, came without it), for
            // what says what it runs may come after a long command (sessions/live.ts briefInput).
            if (block.input !== undefined && block.input.length < INPUT_MOST) block.input += partial;
            out.push({ kind: "delta", id: block.id, field: "input", text: partial });
          }
        }
      } else if (event === "content_block_stop") {
        const block = this.blocks.get(index);
        if (block) {
          if (block.step !== "tool") out.push({ kind: "end", id: block.id });
          else if (block.input !== undefined && block.input !== "") {
            // Its input complete, the call starts again with it: what it runs can be said now.
            out.push(start(block.id, "tool", block.tool, block.input, block.subagent !== undefined ? true : undefined, block.subagent));
          }
        }
      }
    } else if (kind === "user") {
      const content = Array.isArray(frame.message?.content) ? frame.message.content : [];
      for (const c of content) {
        const id = str(c?.tool_use_id) ?? "";
        if (c?.type !== "tool_result" || !this.tools.has(id)) continue;
        const text =
          typeof c.content === "string"
            ? c.content
            : Array.isArray(c.content)
              ? c.content.map((x: Json) => str(x?.text) ?? "").join("\n")
              : "";
        if (text !== "") out.push({ kind: "delta", id, field: "output", text: chars(text, 8000) });
        out.push({ kind: "end", id });
        this.tools.delete(id);
      }
    }
    return out;
  }
}

/// Rust's serde_json::to_string_pretty: two-space indent, "key": value.
const pretty = (v: unknown) => JSON.stringify(v ?? {}, null, 2) ?? "{}";

export type DshLiveState = { open: [string, Step][]; calls: [string, string][]; phase: Phase | null };

/// DeepSeek Harness's output as the station's driver plugin sends it (agents/dsh-bridge.mjs) as live steps: the model's
/// stream (`stream`: a block of text, thinking or a call's input starts, grows and ends) and the session's events
/// (`event`: a call runs from tool/call until its tool/result, which carries the output; the turn's end ends all).
export class LiveFromDsh {
  /// Steps started and not ended, with what they are.
  private open = new Map<string, Step>();
  /// A stream block's call: attempt#index → the call's id (its deltas after the first name only the index).
  private calls = new Map<string, string>();
  private phase: Phase | null = null;

  constructor(state?: DshLiveState) {
    if (state) {
      this.open = new Map(state.open);
      this.calls = new Map(state.calls);
      this.phase = state.phase;
    }
  }

  state(): DshLiveState {
    return { open: [...this.open.entries()], calls: [...this.calls.entries()], phase: this.phase };
  }

  private to(next: Phase, out: LiveEvent[]) {
    if (this.phase !== next) {
      this.phase = next;
      out.push({ kind: "phase", phase: next });
    }
  }

  private end(id: string, out: LiveEvent[]) {
    if (this.open.delete(id)) out.push({ kind: "end", id });
  }

  /// A prompt was given: the turn is with the model.
  prompted(): LiveEvent[] {
    const out: LiveEvent[] = [];
    this.to("requesting", out);
    return out;
  }

  feed(message: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    if (message?.ev === "stream") this.stream(message.frame, out);
    else if (message?.ev === "event") this.event(str(message.type) ?? "", message.data ?? {}, out);
    return out;
  }

  private stream(frame: Json, out: LiveEvent[]) {
    const attempt = str(frame?.attemptId) ?? "";
    if (frame?.type === "start") return this.to("requesting", out);
    if (frame?.type === "end") {
      // An attempt that did not commit (cancelled, failed, retried): what it said so far ends with it.
      if (frame.outcome?.kind !== "committed") for (const [id, step] of [...this.open]) if (step !== "tool" && id.startsWith(`${attempt}#`)) this.end(id, out);
      return;
    }
    const chunk = frame?.chunk;
    if (frame?.type !== "chunk" || !chunk) return;
    const block = `${attempt}#${typeof chunk.index === "number" ? chunk.index : ""}`;
    const kind = str(chunk.type) ?? "";
    if (kind === "block-start" && (chunk.blockType === "text" || chunk.blockType === "reasoning")) {
      this.open.set(block, chunk.blockType === "text" ? "text" : "thinking");
      out.push(start(block, chunk.blockType === "text" ? "text" : "thinking"));
    } else if (kind === "text-delta" || kind === "reasoning-delta") {
      const text = str(chunk.text) ?? "";
      if (!this.open.has(block) || text === "") return;
      this.to("responding", out);
      out.push({ kind: "delta", id: block, field: "text", text });
    } else if (kind === "tool-call-delta") {
      let call = this.calls.get(block);
      const id = nonEmpty(chunk.id);
      if (call === undefined && id !== undefined) {
        call = id;
        this.calls.set(block, id);
        this.open.set(id, "tool");
        this.to("responding", out);
        out.push(start(id, "tool", str(chunk.name) ?? "", ""));
      }
      const delta = str(chunk.argumentsDelta) ?? "";
      if (call !== undefined && delta !== "") out.push({ kind: "delta", id: call, field: "input", text: delta });
    } else if (kind === "block-end") {
      // A call goes on until its result.
      if (this.open.get(block) !== undefined) this.end(block, out);
      this.calls.delete(block);
    }
  }

  private event(type: string, data: Json, out: LiveEvent[]) {
    if (type === "tool/call") {
      const id = nonEmpty(data.callId);
      if (id === undefined) return;
      this.to("working", out);
      // One not seen streaming (taken up after it streamed): started with its input whole.
      if (!this.open.has(id)) {
        this.open.set(id, "tool");
        let input = str(data.arguments) ?? "";
        try {
          input = pretty(JSON.parse(input));
        } catch {}
        out.push(start(id, "tool", str(data.name) ?? "", chars(input, INPUT_MOST)));
      }
    } else if (type === "tool/result") {
      const result = data.message ?? {};
      const id = nonEmpty(result.toolCallId);
      if (id === undefined || !this.open.has(id)) return;
      const output = (Array.isArray(result.content) ? result.content : []).map((c: Json) => str(c?.text) ?? "").filter((t: string) => t !== "").join("\n");
      if (output !== "") out.push({ kind: "delta", id, field: "output", text: output });
      this.end(id, out);
      if (![...this.open.values()].includes("tool")) this.to("requesting", out);
    } else if (type === "turn/end") {
      out.push(...this.ended());
    }
  }

  /// The turn ended: whatever is still open ends with it.
  ended(): LiveEvent[] {
    const out: LiveEvent[] = [...this.open.keys()].map((id) => ({ kind: "end", id }) as LiveEvent);
    this.open.clear();
    this.calls.clear();
    this.phase = null;
    return out;
  }
}

export type AcpLiveState = { open: string[]; said: string | null; n: number; phase: Phase | null; background?: string[] };

/// What a content block of an ACP update says (its text; anything else nothing).
const acpText = (content: Json): string => {
  if (typeof content?.text === "string") return content.text;
  if (content?.type === "content") return acpText(content.content);
  return "";
};

/// A call as it is named and given: Grok Build reaches an MCP server's tools through its `use_tool` (the tool's full
/// name, server__tool, and its input inside), named here as the tool itself, as Claude Code names one
/// (mcp__server__tool).
export function acpCall(name: string, input: Json): [string, Json] {
  if (name === "use_tool" && typeof input?.tool_name === "string") return [`mcp__${input.tool_name}`, input.tool_input ?? {}];
  return [name, input];
}

/// A call an ACP update starts, as the station names and gives it: Grok Build names it in its own _meta, Devin in its own
/// (an MCP tool's as mcp__<server>__<tool>), the others in its title.
export const acpNamed = (update: Json): [string, Json] =>
  acpCall(str(update?._meta?.["x.ai/tool"]?.name) ?? str(update?._meta?.["cognition.ai/inferenceToolName"]) ?? str(update?.title) ?? "", update?.rawInput ?? null);

/// An ACP agent's `session/update`s as live steps (Grok Build's). What the model says streams in chunks with no id of
/// their own: a run of chunks of one kind is a step, which ends when something else begins (a thought, a call) or the
/// turn ends; a call starts with `tool_call` and ends with the update that says it completed or failed, which carries
/// its output.
export class LiveFromAcp {
  private open = new Set<string>();
  private background = new Set<string>();
  /// The step what is being said goes into (text or thinking), and how many steps were made.
  private said: string | null = null;
  private n = 0;
  private phase: Phase | null = null;

  constructor(state?: AcpLiveState) {
    if (state) {
      this.open = new Set(state.open);
      this.background = new Set((state.background ?? []).filter((id) => this.open.has(id)));
      this.said = state.said;
      this.n = state.n;
      this.phase = state.phase;
    }
  }

  state(): AcpLiveState {
    return {
      open: [...this.open],
      said: this.said,
      n: this.n,
      phase: this.phase,
      ...(this.background.size > 0 ? { background: [...this.background] } : {}),
    };
  }

  backgroundOpen() {
    for (const id of this.open) {
      if (id.startsWith("call:")) this.background.add(id);
    }
  }

  private to(next: Phase, out: LiveEvent[]) {
    if (this.phase !== next) {
      this.phase = next;
      out.push({ kind: "phase", phase: next });
    }
  }

  /// Ends the step of what was being said (a call keeps going until its result).
  private endSaid(out: LiveEvent[]) {
    if (this.said === null) return;
    this.open.delete(this.said);
    out.push({ kind: "end", id: this.said });
    this.said = null;
  }

  /// A prompt was given: the turn is with the model.
  prompted(): LiveEvent[] {
    const out: LiveEvent[] = [];
    this.to("requesting", out);
    return out;
  }

  /// The call that started last of those still running (what a subagent spawned now was spawned by).
  openCall(): string | undefined {
    return [...this.open].filter((id) => id.startsWith("call:")).at(-1);
  }

  feed(update: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const kind = str(update?.sessionUpdate) ?? "";
    if (kind === "agent_message_chunk" || kind === "agent_thought_chunk") {
      const step: Step = kind === "agent_message_chunk" ? "text" : "thinking";
      const text = acpText(update.content);
      if (text === "") return out;
      this.backgroundOpen();
      this.to("responding", out);
      if (this.said === null || !this.said.endsWith(`/${step}`)) {
        this.endSaid(out);
        this.n += 1;
        this.said = `said:${this.n}/${step}`;
        this.open.add(this.said);
        out.push(start(this.said, step));
      }
      out.push({ kind: "delta", id: this.said, field: "text", text });
    } else if (kind === "tool_call") {
      const callId = nonEmpty(update.toolCallId);
      if (callId === undefined) return out;
      const id = `call:${callId}`;
      this.endSaid(out);
      this.to("working", out);
      if (!this.open.has(id)) {
        this.open.add(id);
        const [name, input] = acpNamed(update);
        out.push(start(id, "tool", name, chars(pretty(input), INPUT_MOST)));
      }
      this.result(id, update, out);
    } else if (kind === "tool_call_update") {
      const callId = nonEmpty(update.toolCallId);
      if (callId !== undefined && this.open.has(`call:${callId}`)) this.result(`call:${callId}`, update, out);
    }
    return out;
  }

  /// A call's output once it is done, and its end.
  private result(id: string, update: Json, out: LiveEvent[]) {
    if (update.status !== "completed" && update.status !== "failed") return;
    const output = (Array.isArray(update.content) ? update.content : []).map(acpText).filter((t: string) => t !== "").join("\n");
    if (output !== "") out.push({ kind: "delta", id, field: "output", text: chars(output, INPUT_MOST) });
    this.open.delete(id);
    this.background.delete(id);
    out.push({ kind: "end", id });
    if (![...this.open].some((o) => o.startsWith("call:") && !this.background.has(o))) this.to("requesting", out);
  }

  /// The turn ended: whatever is still open ends with it.
  ended(): LiveEvent[] {
    const out: LiveEvent[] = [...this.open].map((id) => ({ kind: "end", id }) as LiveEvent);
    this.open.clear();
    this.background.clear();
    this.said = null;
    this.phase = null;
    return out;
  }
}

export type CursorLiveState = { open: [string, Step][]; said: string | null; n: number; phase: Phase | null };

/// A call of Cursor's as the station names it: the station's tools (and any MCP server's) as Claude Code names an MCP
/// tool, mcp__<server>__<tool>, with the tool's own input; the others by Cursor's name (shell, read, edit…).
export function cursorCall(name: string, args: Json): [string, Json] {
  if (name === "mcp" && typeof args?.providerIdentifier === "string" && typeof args?.toolName === "string") return [`mcp__${args.providerIdentifier}__${args.toolName}`, args.args ?? {}];
  return [name, args ?? {}];
}

/// What a call of Cursor's gave back, as text: a command's output, an MCP tool's content, else as it is.
export function cursorOutput(result: unknown): string {
  let r: Json = result;
  if (typeof r === "string") {
    try {
      r = JSON.parse(r);
    } catch {
      return r as string;
    }
  }
  const v = r?.value ?? r;
  if (typeof v?.stdout === "string" || typeof v?.stderr === "string") return [str(v.stdout) ?? "", str(v.stderr) ?? ""].filter((t) => t !== "").join("\n");
  if (Array.isArray(v?.content)) return v.content.map((c: Json) => str(c?.text?.text) ?? str(c?.text) ?? "").filter((t: string) => t !== "").join("\n");
  if (typeof r?.error === "string") return r.error;
  return r === null || r === undefined ? "" : typeof r === "string" ? r : JSON.stringify(r);
}

/// Cursor's SDK messages (as agents/cursor-bridge.mjs sends them) as live steps: the model's text and thoughts come in
/// pieces with no id of their own (a step lasts until something else comes), a call starts running and comes back done.
export class LiveFromCursor {
  private open = new Map<string, Step>();
  /// The text or thoughts step under way.
  private said: string | null = null;
  private n = 0;
  private phase: Phase | null = null;

  constructor(state?: CursorLiveState) {
    if (state) {
      this.open = new Map(state.open);
      this.said = state.said;
      this.n = state.n;
      this.phase = state.phase;
    }
  }

  state(): CursorLiveState {
    return { open: [...this.open.entries()], said: this.said, n: this.n, phase: this.phase };
  }

  private to(next: Phase, out: LiveEvent[]) {
    if (this.phase !== next) {
      this.phase = next;
      out.push({ kind: "phase", phase: next });
    }
  }

  private end(id: string, out: LiveEvent[]) {
    if (this.open.delete(id)) out.push({ kind: "end", id });
  }

  /// The text or thoughts under way ends: something else came.
  private stopSaying(out: LiveEvent[]) {
    if (this.said !== null) this.end(this.said, out);
    this.said = null;
  }

  /// A prompt was given: the turn is with the model.
  prompted(): LiveEvent[] {
    const out: LiveEvent[] = [];
    this.to("requesting", out);
    return out;
  }

  feed(message: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const type = str(message?.type) ?? "";
    if (type === "status" && message.status === "RUNNING") this.to("requesting", out);
    else if (type === "thinking" || type === "assistant") {
      const step: Step = type === "thinking" ? "thinking" : "text";
      const text = type === "thinking" ? (str(message.text) ?? "") : (Array.isArray(message.message?.content) ? message.message.content : []).map((c: Json) => (c?.type === "text" ? (str(c.text) ?? "") : "")).join("");
      if (this.said === null || this.open.get(this.said) !== step) {
        if (text === "") return out;
        this.stopSaying(out);
        this.said = `${str(message.run_id) ?? "cursor"}:${this.n++}`;
        this.open.set(this.said, step);
        out.push(start(this.said, step));
      }
      if (step === "text") this.to("responding", out);
      if (text !== "") out.push({ kind: "delta", id: this.said, field: "text", text });
    } else if (type === "tool_call") {
      const id = nonEmpty(message.call_id);
      if (id === undefined) return out;
      this.stopSaying(out);
      if (message.status === "running") {
        if (this.open.has(id)) return out;
        const [name, input] = cursorCall(str(message.name) ?? "tool", message.args);
        this.open.set(id, "tool");
        this.to("working", out);
        out.push(start(id, "tool", name, chars(pretty(input), INPUT_MOST)));
        return out;
      }
      if (!this.open.has(id)) {
        // One done that this station did not see start (taken up after it started): started with its input whole.
        const [name, input] = cursorCall(str(message.name) ?? "tool", message.args);
        this.open.set(id, "tool");
        out.push(start(id, "tool", name, chars(pretty(input), INPUT_MOST)));
      }
      const output = cursorOutput(message.result);
      if (output !== "") out.push({ kind: "delta", id, field: "output", text: chars(output, INPUT_MOST) });
      this.end(id, out);
      if (![...this.open.values()].includes("tool")) this.to("requesting", out);
    } else if (type === "user") {
      // A message put in the turn: what the model says next is a step of its own.
      this.stopSaying(out);
    }
    return out;
  }

  /// The turn ended: whatever is still open ends with it.
  ended(): LiveEvent[] {
    const out: LiveEvent[] = [...this.open.keys()].map((id) => ({ kind: "end", id }) as LiveEvent);
    this.open.clear();
    this.said = null;
    this.phase = null;
    return out;
  }
}

// ── claude.ts ──────────────────────────────────────────────────────────────────────────────────────────────────────

type Turn = { busy: boolean; aborting: boolean; authFailure: string | null; closed: boolean; renews?: boolean; renewed?: boolean; tasks?: Record<string, Json>; compacting?: boolean; compactError?: string | null };
const ENDED = new Set(["completed", "failed", "killed", "stopped"]);
const RENEW_ATTEMPTS = 2;

/// Where the turn stands after a frame, as a station reads again what the one before it had handled when it crashed
/// (`crashed`): what the frames say as they come (the turn's events, its outcome) is the MoonBit program's to tell
/// (mb/src/claude `on_frame`), none of it here. `now`: when a task it tells of starts.
export function turnAfter(frame: Json, turn: Turn, now: () => number = wall.now) {
  const kind = typeof frame?.type === "string" ? frame.type : "";
  const subtype = typeof frame?.subtype === "string" ? frame.subtype : "";
  if (kind === "system" && subtype === "init") {
    turn.busy = true;
  } else if (kind === "system" && subtype === "api_retry") {
    const status = Number.isInteger(frame.error_status) ? (frame.error_status as number) : 0;
    const attempt = Number.isInteger(frame.attempt) ? (frame.attempt as number) : 1;
    // A token renewed while it runs asks for a new one (RENEWED); stopped only when that one fails too.
    const renewing = status === 401 && turn.renews === true && turn.renewed !== true && attempt <= RENEW_ATTEMPTS;
    if ((status === 401 || status === 403) && turn.authFailure === null && !renewing) {
      const error = frame.error === undefined ? "authentication failed" : typeof frame.error === "string" ? frame.error : JSON.stringify(frame.error);
      turn.authFailure = `${status} ${error}`;
      turn.aborting = true;
    }
  } else if (kind === "system" && subtype === "task_started" && typeof frame.task_id === "string" && frame.owned_by_subagent !== true) {
    const description = typeof frame.description === "string" ? frame.description : "";
    turn.tasks = { ...turn.tasks, [frame.task_id]: { id: frame.task_id, kind: frame.task_type === "local_agent" ? "agent" : "command", description, background: frame.is_backgrounded === true, startedAt: now() } };
  } else if (kind === "system" && (subtype === "task_notification" || subtype === "task_updated") && typeof frame.task_id === "string" && turn.tasks?.[frame.task_id]) {
    const status = subtype === "task_notification" ? frame.status : frame.patch?.status;
    const { [frame.task_id]: task, ...rest } = turn.tasks;
    if (subtype === "task_notification" || ENDED.has(status)) turn.tasks = rest;
    else if (frame.patch?.is_backgrounded === true) turn.tasks = { ...rest, [frame.task_id]: { ...task!, background: true } };
  } else if (kind === "system" && subtype === "status" && turn.compacting === true && frame.compact_result === "failed") {
    // `/compact` that compacted nothing still ends in a result of success: only this says so (2.1.289).
    turn.compactError = typeof frame.compact_error === "string" && frame.compact_error !== "" ? frame.compact_error : "compaction failed";
  } else if (kind === "result") {
    turn.busy = false;
    turn.aborting = false;
    turn.authFailure = null;
    turn.renewed = false;
    turn.compacting = false;
    turn.compactError = null;
    // What it waited on in the turn has ended with it; what goes on is in the background.
    if (turn.tasks) turn.tasks = Object.fromEntries(Object.entries(turn.tasks).filter(([, t]) => t.background));
  }
}

// ── what a line did to a session, as the drivers heard it ───────────────────────────────────────────────────────

/// What a line of a session's output came to: the runtime's events, and whether the driver read it as an answer of its
/// own (a line the program gives Node: mb agents_own.mbt).
export type Said = { events: Json[]; node: boolean };

const live = (event: LiveEvent): Json => ({ type: "live", event });

/// dsh.ts `classifyFailure`, `outcomeOf`.
export const dshClassify = (code: string, text: string): FailureReason =>
  failureOf(`${code} ${text}`, { authCodes: ["auth", "missing_credential", "invalid_credential"], limit: ["insufficient balance"] });
export function dshOutcome(reason: Json): TurnOutcome {
  const kind = reason?.kind;
  if (kind === "aborted") return { kind: "aborted" };
  if (kind === "error") {
    const error = reason.error ?? {};
    const message = typeof error.message === "string" ? error.message : JSON.stringify(error);
    return { kind: "failed", reason: dshClassify(String(error.code ?? ""), message), message: chars(message, 1000) };
  }
  return { kind: "completed" };
}

/// dsh.ts `DshSession` as it heard a line (`heard`, `toolsLost`) and a prompt (`prompt`).
export class DshReference {
  turn = { busy: false, prompted: false, aborting: false };
  live = new LiveFromDsh();
  private calls = new Set<string>();

  line(message: Json): Said {
    const events: Json[] = [];
    if (message?.ev === undefined) {
      if (typeof message?.error === "string" && String(message.id).startsWith("prompt:") && this.turn.prompted) {
        this.turn.prompted = false;
        events.push({ type: "turnEnded", outcome: { kind: "failed", reason: "other", message: chars(message.error, 1000) } });
      }
      return { events, node: true };
    }
    if (message.ev === "event" && message.type === "turn/start") {
      const ours = this.turn.prompted;
      this.turn.prompted = false;
      this.turn.busy = true;
      if (!ours) events.push({ type: "turnStarted" });
    }
    for (const e of this.live.feed(message)) events.push(live(e));
    const lost = this.toolsLost(message);
    if (lost !== null) events.push({ type: "toolsLost", why: lost });
    if (message.ev === "event" && message.type === "turn/end") {
      this.turn.busy = false;
      this.turn.aborting = false;
      events.push({ type: "turnEnded", outcome: dshOutcome(message.data?.reason) });
    }
    return { events, node: false };
  }

  private toolsLost(message: Json): string | null {
    if (message.ev !== "event") return null;
    const data = message.data ?? {};
    if (message.type === "tool/call" && typeof data.callId === "string" && stationTool(String(data.name ?? ""))) this.calls.add(data.callId);
    if (message.type !== "tool/result") return null;
    const result = data.message ?? {};
    if (!this.calls.delete(String(result.toolCallId ?? "")) || result.isError !== true) return null;
    const text = (Array.isArray(result.content) ? result.content : []).map((c: Json) => (typeof c?.text === "string" ? c.text : "")).join("\n");
    return unreachable(text) ? chars(text, 300) : null;
  }

  prompted(): Json[] {
    this.turn.prompted = true;
    return this.live.prompted().map(live);
  }
}

/// cursor.ts `classifyFailure`, `outcomeOf`.
export function cursorOutcome(end: Json): TurnOutcome {
  if (end?.status === "cancelled") return { kind: "aborted" };
  if (end?.status === "finished") return { kind: "completed" };
  const message = typeof end?.error?.message === "string" ? end.error.message : `the run ended ${String(end?.status ?? "without saying how")}`;
  return { kind: "failed", reason: failureOf(`${String(end?.error?.code ?? "")} ${message}`), message: chars(message, 1000) };
}

/// cursor.ts `CursorSession` as it heard a line (`heard`, `toolsLost`) and a prompt (`prompt`).
export class CursorReference {
  turn = { busy: false, aborting: false };
  live = new LiveFromCursor();
  private calls = new Set<string>();

  line(message: Json): Said {
    const events: Json[] = [];
    if (message?.ev === "message") {
      if (!this.turn.busy) {
        this.turn.busy = true;
        events.push({ type: "turnStarted" });
      }
      for (const e of this.live.feed(message.message)) events.push(live(e));
      const lost = this.toolsLost(message.message);
      if (lost !== null) events.push({ type: "toolsLost", why: lost });
      return { events, node: false };
    }
    if (message?.ev === "end") {
      const outcome = this.turn.aborting && message.status !== "finished" ? ({ kind: "aborted" } as TurnOutcome) : cursorOutcome(message);
      if (!this.turn.busy) events.push({ type: "turnStarted" });
      this.turn.busy = false;
      this.turn.aborting = false;
      this.calls.clear();
      for (const e of this.live.ended()) events.push(live(e));
      events.push({ type: "turnEnded", outcome });
      return { events, node: false };
    }
    if (typeof message?.error === "string" && String(message.id).startsWith("prompt:") && this.turn.busy) {
      this.turn.busy = false;
      this.turn.aborting = false;
      for (const e of this.live.ended()) events.push(live(e));
      events.push({ type: "turnEnded", outcome: cursorOutcome({ status: "error", error: { message: message.error, code: message.code } }) });
    }
    return { events, node: true };
  }

  private toolsLost(message: Json): string | null {
    if (message?.type !== "tool_call" || typeof message.call_id !== "string") return null;
    const provider = String(message.args?.providerIdentifier ?? "");
    if (message.status === "running" && message.name === "mcp" && TOOL_SERVERS.includes(provider)) this.calls.add(message.call_id);
    if (message.status === "running" || !this.calls.delete(message.call_id) || message.status !== "error") return null;
    const text = typeof message.result === "string" ? message.result : JSON.stringify(message.result ?? "");
    return unreachable(text) ? chars(text, 300) : null;
  }

  prompted(): Json[] {
    this.turn.busy = true;
    return this.live.prompted().map(live);
  }
}

/// acp.ts `planOfAcp`, `turnStep`, `acpOutcome`.
export function planOfAcp(update: Json): PlanItem[] | null {
  if (!Array.isArray(update?.entries)) return null;
  return update.entries
    .filter((e: Json) => typeof e?.content === "string")
    .map((e: Json): PlanItem => ({ text: e.content, status: typeof e.status === "string" ? e.status : "pending" }));
}
export const turnStep = (update: Json) => ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].includes(update?.sessionUpdate);
function errorText(error: Json): string {
  const text = typeof error?.message === "string" ? error.message.replace(/^Internal error: /, "") : JSON.stringify(error);
  const data = typeof error?.data === "string" ? `: ${error.data}` : typeof error?.data?.message === "string" ? `: ${error.data.message}` : typeof error?.data?.details === "string" ? `: ${error.data.details}` : "";
  return `${text}${data}`;
}
export function acpOutcome(answer: Json, classify: (text: string) => FailureReason): TurnOutcome {
  if (answer?.error !== undefined) {
    const said = errorText(answer.error);
    return { kind: "failed", reason: classify(said), message: chars(said, 1000) };
  }
  const stop = answer?.result?.stopReason;
  if (stop === "cancelled") return { kind: "aborted" };
  if (stop === "refusal") return { kind: "failed", reason: "model", message: "the model refused" };
  return { kind: "completed" };
}

/// Each ACP runtime's `classifyFailure` (agy.ts, grok.ts, devin.ts, hermes.ts), agy.ts `noticeFailure`.
export function acpClassify(flavor: string, text: string): FailureReason {
  if (flavor === "grok") return failureOf(text, { auth: ["access token", "subscription"] });
  if (flavor === "agy")
    return failureOf(text, { auth: ["authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant", "unauthenticated", "token expired", "verification required"], limit: ["resource_exhausted", "quota"] });
  return failureOf(text);
}
const AGY_TERMINATED = "⚠ agent execution terminated due to error.";
const AGY_EXECUTOR_ERROR = "⚠ agent executor error:";
const AGY_UNAUTHENTICATED = "⚠ unauthenticated (code 401):";
const AGY_VERIFICATION_REQUIRED = "⚠ verification required";
const AGY_PERMISSION_DENIED = "⚠ permission '";
const AGY_UNABLE_TO_SUBMIT = "⚠ unable to submit request";
export function noticeFailure(said: string): FailureReason | null {
  const text = said.trim();
  const last = text.slice(text.lastIndexOf("\n") + 1).trim();
  const lower = last.toLowerCase();
  if (lower === AGY_TERMINATED) return "other";
  if (lower.startsWith(AGY_EXECUTOR_ERROR)) {
    const reason = acpClassify("agy", last);
    return reason === "model" ? "other" : reason;
  }
  if (lower.startsWith(AGY_UNAUTHENTICATED)) return "auth";
  if (lower.startsWith(AGY_VERIFICATION_REQUIRED)) return "auth";
  if (!text.startsWith("⚠") || text.includes("\n")) return null;
  if (lower.startsWith(AGY_PERMISSION_DENIED) && lower.includes("denied")) return "auth";
  if (lower.startsWith(AGY_UNABLE_TO_SUBMIT)) return "other";
  const reason = acpClassify("agy", text);
  return reason === "model" ? null : reason;
}

/// agy.ts `agyUpdate`, hermes.ts `hermesUpdate`.
export function agyUpdate(update: Json): Json {
  if (update?.sessionUpdate !== "tool_call" || typeof update.title !== "string") return update;
  for (const server of TOOL_SERVERS) {
    const prefix = `Run mcp_${server}_`;
    if (update.title.startsWith(prefix)) return { ...update, title: `mcp__${server}__${update.title.slice(prefix.length)}` };
  }
  return update;
}
export function hermesUpdate(update: Json): Json {
  if (update?.sessionUpdate !== "tool_call" || typeof update.title !== "string") return update;
  const name = update.title.split(": ", 1)[0]!;
  const title = name.replace(/^mcp__editor_stillfail_[0-9a-f]{8}__/, "mcp__stillfail__");
  return { ...update, title };
}

/// grok.ts `underParent`.
function underParent(event: LiveEvent, child: string, parent: string | undefined): LiveEvent {
  if (event.kind === "phase" || event.kind === "tasks" || event.kind === "plan") return event;
  const id = `sub:${child}:${event.id}`;
  if (event.kind !== "start") return { ...event, id };
  return { ...event, id, subagent: true, ...(parent !== undefined ? { parent } : {}) };
}

type Call = { name: string; input: Json; startedAt?: number };
type Done = Call & { id: string; failed: boolean; text: string };

function hasTurnUsage(answer: Json): boolean {
  const u = answer?.result?.usage;
  if (u === null || typeof u !== "object") return false;
  const pos = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);
  return pos(u.inputTokens) + pos(u.cachedReadTokens) + pos(u.cachedWriteTokens) + pos(u.outputTokens) > 0;
}

/// acp.ts `AcpSession` (with agy.ts's, grok.ts's and hermes.ts's own) as it heard a line (`onMessage`) and was given a
/// prompt (`prompt`, `injectPrompt`); its KeptTranscript's lines told as `kept`, a prompt's answer for the driver as
/// `answered`, an update of usage as `usage` (what agy.ts and devin.ts read of it).
export class AcpReference {
  turn: { busy: boolean; aborting: boolean; owner: string | null; steering: string[] } = { busy: false, aborting: false, owner: null, steering: [] };
  session = "";
  loading = true;
  private loadReplayGuard = false;
  private guardStartedAt: number | null = null;
  private stagedKept: Json[] = [];
  live = new LiveFromAcp();
  private calls = new Map<string, Call>();
  private saidLast = "";
  private said: { type: "assistant" | "thinking"; text: string } | null = null;
  private children = new Map<string, { live: LiveFromAcp; parent: string | undefined }>();
  readonly flavor: string;
  readonly kept: boolean;
  readonly now: () => number;

  constructor(flavor: string, kept: boolean, now: () => number) {
    this.flavor = flavor;
    this.kept = kept;
    this.now = now;
  }

  opened(resumed = false) {
    if (this.loading && this.flavor === "agy" && resumed) this.loadReplayGuard = true;
    this.loading = false;
  }

  private emitKept(line: Json, events: Json[]) {
    if (this.loadReplayGuard && this.guardStartedAt !== null) this.stagedKept.push({ type: "kept", line });
    else events.push({ type: "kept", line });
  }

  private flushStaged(events: Json[]) {
    for (const e of this.stagedKept) events.push(e);
    this.stagedKept = [];
    this.loadReplayGuard = false;
    this.guardStartedAt = null;
  }

  private normalized(update: Json) {
    return this.flavor === "agy" ? agyUpdate(update) : this.flavor === "hermes" ? hermesUpdate(update) : update;
  }

  private endsTurn(id: unknown): id is string {
    return typeof id === "string" && (id.startsWith("prompt:") || ((this.flavor === "agy" || this.flavor === "devin") && id.startsWith("steer:")));
  }

  line(message: Json): Said {
    const events: Json[] = [];
    const id = message?.id;
    if (message?.method === "session/update") {
      this.update(message.params, events);
      return { events, node: false };
    }
    if (message?.method !== undefined) {
      if (id !== undefined) return { events, node: true };
      this.notified(message, events);
      return { events, node: false };
    }
    if (!this.endsTurn(id)) return { events, node: true };
    const at = this.turn.steering.indexOf(id);
    if (at >= 0) {
      this.turn.steering.splice(at, 1);
      if (this.turn.busy) this.live.backgroundOpen();
      events.push({ type: "answered", id, answer: message });
      return { events, node: false };
    }
    if (this.turn.owner !== null && id !== this.turn.owner) return { events, node: false };
    this.end(id, message, events);
    return { events, node: false };
  }

  private update(params: Json, events: Json[]) {
    const update = this.normalized(params?.update);
    const from = params?.sessionId;
    if (update?.sessionUpdate === "plan" && (this.session === "" || typeof from !== "string" || from === this.session)) {
      const plan = planOfAcp(update);
      if (plan !== null) events.push(live({ kind: "plan", plan }));
      return;
    }
    if (this.loading) return;
    if (this.session !== "" && typeof from === "string" && from !== this.session) {
      const child = this.flavor === "grok" ? this.children.get(from) : undefined;
      if (child) for (const event of child.live.feed(update)) events.push(live(underParent(event, from, child.parent)));
      return;
    }
    if (!this.turn.busy && turnStep(update) && !this.unprompted(events)) return;
    if (this.loadReplayGuard) {
      if (this.guardStartedAt !== null && this.now() - this.guardStartedAt >= 5000) this.flushStaged(events);
      else if (this.guardStartedAt === null && this.turn.busy) this.guardStartedAt = this.now();
      if (update?.sessionUpdate === "usage_update") this.flushStaged(events);
    }
    const done = this.track(update);
    if (update?.sessionUpdate === "agent_message_chunk") {
      if (typeof update.content?.text === "string") this.saidLast += update.content.text;
    } else if (turnStep(update)) this.saidLast = "";
    this.take(update, done, events);
    for (const event of this.live.feed(update)) events.push(live(event));
    if (update?.sessionUpdate === "usage_update") events.push({ type: "usage", update, owner: this.turn.owner });
    if (done !== null && done.failed && stationTool(done.name) && unreachable(done.text)) events.push({ type: "toolsLost", why: chars(done.text, 300) });
  }

  private unprompted(events: Json[]): boolean {
    if (this.turn.steering.length === 0) return false;
    this.turn.owner = this.turn.steering.shift()!;
    this.turn.busy = true;
    this.saidLast = "";
    events.push({ type: "turnStarted" });
    return true;
  }

  track(update: Json): Done | null {
    const kind = update?.sessionUpdate;
    const id = typeof update?.toolCallId === "string" ? update.toolCallId : null;
    if ((kind !== "tool_call" && kind !== "tool_call_update") || id === null) return null;
    if (kind === "tool_call" && !this.calls.has(id)) {
      const [name, input] = acpNamed(update);
      this.calls.set(id, { name, input, startedAt: this.now() });
    }
    const call = this.calls.get(id);
    if (call === undefined || (update.status !== "completed" && update.status !== "failed")) return null;
    this.calls.delete(id);
    const text = (Array.isArray(update.content) ? update.content : []).map((c: Json) => c?.content?.text ?? c?.text ?? "").filter((t: string) => t !== "").join("\n");
    return { id, ...call, failed: update.status === "failed", text };
  }

  take(update: Json, done: Done | null, events: Json[]) {
    if (!this.kept) return;
    const kind = update?.sessionUpdate;
    if (kind === "agent_message_chunk" || kind === "agent_thought_chunk") {
      const type = kind === "agent_message_chunk" ? "assistant" : "thinking";
      const text = typeof update.content?.text === "string" ? update.content.text : "";
      if (this.said !== null && this.said.type !== type) this.flush(events);
      this.said ??= { type, text: "" };
      this.said.text += text;
      return;
    }
    if ((kind !== "tool_call" && kind !== "tool_call_update") || typeof update.toolCallId !== "string") return;
    this.flush(events);
    if (done !== null) this.emitKept({ type: "tool", id: done.id, name: done.name, status: done.failed ? "error" : "completed", ...(done.startedAt !== undefined ? { startedAt: done.startedAt } : {}), args: done.input, result: chars(done.text, 20_000) }, events);
  }

  private flush(events: Json[]) {
    if (this.said === null) return;
    if (this.said.text.trim() !== "") this.emitKept({ type: this.said.type, text: this.said.text }, events);
    this.said = null;
  }

  private notified(message: Json, events: Json[]) {
    if (this.flavor !== "grok" || message.method !== "_x.ai/session_notification" || message.params?.sessionId !== this.session) return;
    const update = message.params?.update;
    const child = typeof update?.child_session_id === "string" ? update.child_session_id : null;
    if (child === null) return;
    if (update?.sessionUpdate === "subagent_spawned") this.children.set(child, { live: new LiveFromAcp(), parent: this.live.openCall() });
    if (update?.sessionUpdate === "subagent_finished") this.endChild(child, events);
  }

  private endChild(id: string, events: Json[]) {
    const child = this.children.get(id);
    if (!child) return;
    this.children.delete(id);
    for (const event of child.live.ended()) events.push(live(underParent(event, id, child.parent)));
  }

  private end(id: string, answer: Json, events: Json[]) {
    let outcome = this.turn.aborting && answer.error !== undefined ? ({ kind: "aborted" } as TurnOutcome) : acpOutcome(answer, (text) => acpClassify(this.flavor, text));
    const said = this.saidLast.trim();
    this.saidLast = "";
    const failed = this.flavor === "agy" && outcome.kind === "completed" && said !== "" ? noticeFailure(said) : null;
    if (failed !== null) outcome = { kind: "failed", reason: failed, message: chars(said.slice(said.lastIndexOf("\n") + 1).trim(), 1000) };
    if (this.flavor === "agy" && this.loadReplayGuard && !this.turn.aborting && this.turn.steering.length === 0 && outcome.kind === "completed" && !hasTurnUsage(answer)) {
      this.loadReplayGuard = false;
      this.guardStartedAt = null;
      this.stagedKept = [];
      this.said = null;
      this.calls.clear();
      for (const event of this.live.ended()) events.push(live(event));
      for (const event of this.live.prompted()) events.push(live(event));
      this.turn.busy = true;
      events.push({ type: "loadReplay", id });
      return;
    }
    if (!this.turn.busy) events.push({ type: "turnStarted" });
    this.turn.busy = false;
    this.turn.aborting = false;
    this.turn.owner = null;
    this.flush(events);
    this.flushStaged(events);
    events.push({ type: "answered", id, answer, outcome });
    if (this.flavor === "grok") for (const child of [...this.children.keys()]) this.endChild(child, events);
    if (this.kept) events.push({ type: "kept", line: { type: "end", status: outcome.kind === "completed" ? "finished" : outcome.kind === "aborted" ? "cancelled" : "error", ...(outcome.kind === "failed" ? { error: { message: outcome.message } } : {}) } });
    this.calls.clear();
    for (const event of this.live.ended()) events.push(live(event));
    events.push({ type: "turnEnded", outcome });
  }

  prompted(owner: string, text: string): Json[] {
    const events: Json[] = [];
    this.turn.busy = true;
    this.saidLast = "";
    this.turn.owner = owner;
    this.user(text, false, events);
    if (this.loadReplayGuard) this.guardStartedAt = this.now();
    for (const event of this.live.prompted()) events.push(live(event));
    return events;
  }

  resent(owner: string): Json[] {
    const events: Json[] = [];
    this.turn.busy = true;
    this.saidLast = "";
    this.turn.owner = owner;
    for (const event of this.live.prompted()) events.push(live(event));
    return events;
  }

  injected(id: string, takeOver: boolean, text: string): Json[] {
    const events: Json[] = [];
    this.flushStaged(events);
    const add = (s: string) => {
      if (!this.turn.steering.includes(s)) this.turn.steering.push(s);
    };
    if (takeOver) {
      if (this.turn.owner !== null) add(this.turn.owner);
      this.turn.owner = id;
    } else add(id);
    this.user(text, true, events);
    return events;
  }

  private user(text: string, steered: boolean, events: Json[]) {
    if (!this.kept) return;
    this.flush(events);
    events.push({ type: "kept", line: steered ? { type: "user", text, steered: true } : { type: "user", text } });
  }

  /// Its process went away during a turn: what was being said written, its steps ended (acp.ts `cutShort`, the end of
  /// the turn in the transcript its driver's).
  cutShort(): Json[] {
    const events: Json[] = [];
    if (!this.turn.busy) return events;
    this.flush(events);
    this.flushStaged(events);
    this.calls.clear();
    for (const event of this.live.ended()) events.push(live(event));
    return events;
  }

  /// acp.ts `replay`: what a station that crashed had handled of its output, read again silently: the session, whether
  /// a turn runs, what the turn had said and called so far; what it was opened with and its updates of usage.
  replay(lines: Json[], resume: string): Json {
    this.session = resume;
    let open = false;
    let opened: Json = null;
    let partial: Json[] = [];
    for (const message of lines) {
      if (message?.id === "open") {
        open = true;
        if (typeof message.result?.sessionId === "string") this.session = message.result.sessionId;
        if (message.result !== undefined) opened = message.result;
      } else if (open && message?.method === "session/update" && (this.session === "" || message.params?.sessionId === this.session)) {
        const update = this.normalized(message.params?.update);
        if (turnStep(update)) {
          this.turn.busy = true;
          this.live.feed(update);
          partial.push(update);
        } else if (this.turn.busy || update?.sessionUpdate === "usage_update") {
          partial.push(update);
        }
      } else if (this.endsTurn(message?.id)) {
        this.turn.busy = false;
        this.live.ended();
        partial = [];
      }
    }
    this.loading = false;
    const usages: Json[] = [];
    for (const update of partial) {
      const done = this.track(update);
      this.take(update, done, []);
      if (update?.sessionUpdate === "usage_update") usages.push(update);
    }
    return { session: this.session, turn: this.turn, live: this.state(), opened, usages };
  }

  /// What a station taking it up goes on from (mb/src/acp `Session::state`).
  state(): Json {
    return {
      live: this.live.state(),
      said: this.said,
      calls: [...this.calls],
      saidLast: this.saidLast,
      children: [...this.children].map(([id, c]) => [id, { live: c.live.state(), parent: c.parent ?? null }]),
      loading: this.loading,
      session: this.session,
    };
  }
}
