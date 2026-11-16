// What the TypeScript station made of a Codex app-server's thread notifications before the MoonBit program read them
// (station/mb/src/codex, mb/src/reader/agents_codex.mbt): live.ts `LiveFromCodex`, codex.ts `classifyCodexError`,
// `codexToolsLost`, `codexCompacted` and the outcome `CodexSession.sink` made of `turn/completed`, as they were. Only
// the tests' now: what the program says is compared with what these say of the same notifications.
import { chars } from "../src/agents/live.ts";
import { TOOL_SERVERS, failureOf, unreachable, type FailureReason, type LiveEvent, type RuntimeEvent, type TurnOutcome } from "../src/agents/runtime.ts";

type Json = any;
type Phase = "starting" | "requesting" | "responding" | "working";
type Step = "text" | "thinking" | "tool";

const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

function start(id: string, step: Step, tool?: string, input?: string): LiveEvent {
  const event: LiveEvent = { kind: "start", id, step };
  if (tool !== undefined) event.tool = tool;
  if (input !== undefined) event.input = input;
  return event;
}

const TOOL_ITEMS = ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"];

export type CodexLiveState = { open: string[]; phase: Phase | null };

/// Rust's serde_json::to_string_pretty: two-space indent, "key": value.
const pretty = (v: unknown) => JSON.stringify(v ?? {}, null, 2) ?? "{}";

/// The app-server's item notifications as live steps: an item starts, grows by deltas (the reply, reasoning, a
/// command's output as it runs) and completes.
export class LiveFromCodex {
  private open = new Set<string>();
  private phase: Phase | null = null;

  constructor(state?: CodexLiveState) {
    if (state) {
      this.open = new Set(state.open);
      this.phase = state.phase;
    }
  }

  state(): CodexLiveState {
    return { open: [...this.open], phase: this.phase };
  }

  feed(method: string, params: Json): LiveEvent[] {
    const out: LiveEvent[] = [];
    const to = (next: Phase) => {
      if (this.phase !== next) {
        this.phase = next;
        out.push({ kind: "phase", phase: next });
      }
    };
    const itemType = str(params?.item?.type) ?? "";
    if (method === "turn/started") to("requesting");
    else if (method === "turn/completed") this.phase = null;
    else if (method === "item/agentMessage/delta" || method.startsWith("item/reasoning/")) to("responding");
    else if (method === "item/started" && TOOL_ITEMS.includes(itemType)) to("working");
    else if (method === "item/completed" && TOOL_ITEMS.includes(itemType)) to("requesting");

    const text = (v: unknown) => str(v) ?? "";
    if (method === "item/started") {
      const item = params?.item ?? null;
      const id = typeof item?.id === "string" ? item.id : typeof item?.id === "number" ? String(item.id) : "";
      let begun: [Step, string | undefined, string | undefined] | undefined;
      if (itemType === "agentMessage") begun = ["text", undefined, undefined];
      else if (itemType === "reasoning") begun = ["thinking", undefined, undefined];
      else if (itemType === "commandExecution") begun = ["tool", "shell", text(item.command)];
      else if (itemType === "fileChange")
        begun = ["tool", "apply_patch", (Array.isArray(item.changes) ? item.changes : []).map((c: Json) => text(c?.path)).join("\n")];
      else if (itemType === "mcpToolCall") begun = ["tool", `${text(item.server)}.${text(item.tool)}`, pretty(item.arguments)];
      else if (itemType === "dynamicToolCall") begun = ["tool", text(item.tool), pretty(item.arguments)];
      else if (itemType === "webSearch") begun = ["tool", "web_search", text(item.query)];
      if (id !== "" && begun) {
        this.open.add(id);
        out.push(start(id, begun[0], begun[1], begun[2]));
      }
    } else if (
      method === "item/agentMessage/delta" ||
      method === "item/reasoning/textDelta" ||
      method === "item/reasoning/summaryTextDelta" ||
      method === "item/plan/delta" ||
      method === "item/commandExecution/outputDelta"
    ) {
      const id = text(params?.itemId);
      const delta = text(params?.delta);
      if (this.open.has(id) && delta !== "") {
        out.push({ kind: "delta", id, field: method === "item/commandExecution/outputDelta" ? "output" : "text", text: delta });
      }
    } else if (method === "item/completed") {
      const id = text(params?.item?.id);
      if (this.open.delete(id)) out.push({ kind: "end", id });
    }
    return out;
  }
}

/// Why a Codex turn failed, from its error's `codexErrorInfo` (a code, or a code with the HTTP status it came with) and
/// message: the code first, then the status, then what the message says (`failureOf`).
export function classifyCodexError(info: unknown, message = ""): FailureReason {
  const code = typeof info === "string" ? info : info && typeof info === "object" && !Array.isArray(info) ? Object.keys(info)[0] : undefined;
  if (code === "unauthorized") return "auth";
  if (code === "usageLimitExceeded" || code === "rateLimitExceeded") return "rate_limit";
  if (code === "serverOverloaded") return "overloaded";
  if (code === "contextWindowExceeded") return "context";
  const held = code !== undefined && info && typeof info === "object" ? (info as Record<string, unknown>)[code] : undefined;
  const status = held && typeof held === "object" ? (held as { httpStatusCode?: unknown }).httpStatusCode : undefined;
  if (typeof status === "number" && [401, 403, 429, 529].includes(status)) return failureOf(`${status} ${message}`);
  // Some versions report the HTTP refusal in the message without an unauthorized codexErrorInfo.
  if (/\b(?:401|unauthorized|token_revoked)\b|invalidated oauth token/i.test(message)) return "auth";
  // The request not made, or its answer cut off, with no status that says more: the way to the provider.
  if (["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected"].includes(code ?? "") && (typeof status !== "number" || status >= 500)) return "network";
  return failureOf(message);
}

/// What a thread's notification says of the station's tools being out of reach (null: nothing): a call to one of them
/// that failed as unreachable.
export function codexToolsLost(method: string, params: Json): string | null {
  const item = params?.item;
  if (method !== "item/completed" || item?.type !== "mcpToolCall" || !TOOL_SERVERS.includes(item.server) || item.status !== "failed") return null;
  const error = typeof item.error?.message === "string" ? item.error.message : "";
  return unreachable(error) ? chars(error, 300) : null;
}

/// Whether a thread's notification says it compacted its context, on its own as it filled or by thread/compact/start:
/// a contextCompaction item done.
export const codexCompacted = (method: string, params: Json) => method === "item/completed" && params?.item?.type === "contextCompaction";

/// A turn's outcome as its `turn/completed` says it (CodexSession.sink).
export function codexOutcome(params: Json): TurnOutcome {
  const turn = params?.turn ?? null;
  const status = turn?.status;
  if (status === "interrupted") return { kind: "aborted" };
  if (status === "failed") {
    const error = turn?.error ?? null;
    return {
      kind: "failed",
      reason: classifyCodexError(error?.codexErrorInfo ?? null, typeof error?.message === "string" ? error.message : ""),
      message: chars(typeof error?.message === "string" ? error.message : "turn failed", 1000),
    };
  }
  return { kind: "completed" };
}

/// The events CodexSession.sink made of a notification, its live steps fed (its turn's start whether or not it was
/// running: the program says each, its session tells it once).
export function codexEvents(live: LiveFromCodex, method: string, params: Json): Json[] {
  const out: Json[] = live.feed(method, params).map((event) => ({ type: "live", event }) as RuntimeEvent);
  const lost = codexToolsLost(method, params);
  if (lost !== null) out.push({ type: "toolsLost", why: lost });
  if (codexCompacted(method, params)) out.push({ type: "compacted" });
  if (method === "turn/started") out.push(typeof params?.turn?.id === "string" ? { type: "turnStarted", turnId: params.turn.id } : { type: "turnStarted" });
  else if (method === "turn/completed") out.push({ type: "turnEnded", outcome: codexOutcome(params) });
  return out;
}
