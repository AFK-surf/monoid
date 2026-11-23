// What DeepSeek Harness' driver plugin, Cursor's bridge and the ACP runtimes say that the station reads of them, for
// comparing the program's reading (station/mb/src/dsh, mb/src/cursor, mb/src/acp) with the TypeScript station's
// (test/reference/live.ts): every message of each, a call's input pretty-printed and cut short, the station's tools out
// of reach, each failure's reason, a prompt refused, a turn put in the running one, subagents, what is kept of a
// transcript, and what a crash reads again. `node test/runtime-cases.ts` writes what the TypeScript says of them as
// station/mb/src/{dsh,cursor,acp}/as_typescript_said_test.mbt; test/mb-dsh.test.ts, mb-cursor.test.ts and
// mb-acp.test.ts hold those files to what it says now.
import { writeFileSync } from "node:fs";
import { AcpReference, CursorReference, DshReference, LiveFromCursor, LiveFromDsh } from "./reference/live.ts";

type Json = any;

/// What a case's words are made of past what a test would write out: `<<long:N>>` is N characters of letters and
/// emoji, the same in the program's test (as_typescript_said_test.mbt's `expand`).
export const long = (n: number) => Array.from({ length: n }, (_, i) => (i % 7 === 3 ? "😀" : String.fromCharCode(0x61 + (i % 26)))).join("");

export function expand(v: Json): Json {
  if (typeof v === "string") {
    const m = /^<<long:(\d+)>>$/.exec(v);
    return m ? long(Number(m[1])) : v;
  }
  if (Array.isArray(v)) return v.map(expand);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, expand(x)]));
  return v;
}

/// What is compared of a value: a string past 512 code units as its length and a hash of them (FNV-1a), so the file
/// stays small (the same in the program's test: `folded`).
export function folded(v: Json): Json {
  if (typeof v === "string") {
    if (v.length <= 512) return v;
    let h = 0x811c9dc5;
    for (let i = 0; i < v.length; i++) h = Math.imul(h ^ v.charCodeAt(i), 0x01000193) >>> 0;
    return `<<${v.length}:${h.toString(16)}>>`;
  }
  if (Array.isArray(v)) return v.map(folded);
  if (v !== null && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, folded(x)]));
  return v;
}

/// The clock a case runs on (when a call starts).
export const NOW = 1_700_000_000_000;

const error = (code: string, message: string) => ({ ev: "event", type: "turn/end", data: { reason: { kind: "error", error: { code, message } } } });
const chunk = (attemptId: string, c: Json) => ({ ev: "stream", frame: { attemptId, type: "chunk", chunk: c } });

/// DeepSeek Harness' lines, in order (`$new`: a session afresh; `$prompt`: one given it; `$cut`: its process gone).
export const DSH: Json[] = [
  { $new: {} },
  { id: "open", session: "s1" },
  { $prompt: true },
  { ev: "event", type: "turn/start", data: {} },
  { ev: "stream", frame: { attemptId: "a1", type: "start" } },
  chunk("a1", { type: "block-start", index: 0, blockType: "reasoning" }),
  chunk("a1", { type: "reasoning-delta", index: 0, text: "thinking " }),
  chunk("a1", { type: "reasoning-delta", index: 0, text: "" }),
  chunk("a1", { type: "block-end", index: 0 }),
  chunk("a1", { type: "block-start", index: 1, blockType: "text" }),
  chunk("a1", { type: "text-delta", index: 1, text: "Hé😀" }),
  chunk("a1", { type: "text-delta", index: 9, text: "nobody" }),
  chunk("a1", { type: "block-end", index: 1 }),
  chunk("a1", { type: "block-start", index: 2, blockType: "image" }),
  chunk("a1", { type: "tool-call-delta", index: 2, id: "c1", name: "bash", argumentsDelta: '{"command":' }),
  chunk("a1", { type: "tool-call-delta", index: 2, argumentsDelta: '"ls"}' }),
  chunk("a1", { type: "tool-call-delta", index: 2, argumentsDelta: "" }),
  chunk("a1", { type: "block-end", index: 2 }),
  { ev: "stream", frame: { attemptId: "a1", type: "end", outcome: { kind: "committed" } } },
  { ev: "event", type: "tool/call", data: { callId: "c1", name: "bash", arguments: '{"command":"ls"}' } },
  { ev: "event", type: "tool/result", data: { message: { toolCallId: "c1", content: [{ type: "text", text: "a\nb" }, { type: "image" }, { text: "" }, { text: "c" }] } } },
  { ev: "event", type: "tool/call", data: { callId: "c2", name: "mcp__stillfail__chat_post", arguments: '{"text":"hi","n":[1,2.5,{"x":null}],"é":"😀"}' } },
  { ev: "event", type: "tool/result", data: { message: { toolCallId: "c2", isError: true, content: [{ text: "fetch failed: ECONNREFUSED 127.0.0.1:4750 " }, { text: "<<long:400>>" }, { image: 1 }] } } },
  { ev: "event", type: "tool/call", data: { callId: "c3", name: "stillfail__chat_state", arguments: "not json" } },
  { ev: "event", type: "tool/result", data: { message: { toolCallId: "c3", isError: true, content: [{ text: "text is empty" }] } } },
  { ev: "event", type: "tool/call", data: { callId: "c4", name: "write", arguments: '{"text":"<<long:300000>>"}' } },
  { ev: "event", type: "tool/call", data: { callId: "c4", name: "write", arguments: "{}" } },
  { ev: "event", type: "tool/call", data: { callId: "c5", name: 7, arguments: "null" } },
  { ev: "event", type: "tool/call", data: { callId: "", name: "x" } },
  { ev: "event", type: "tool/call", data: null },
  { ev: "event", type: "tool/result", data: { message: "c5" } },
  { ev: "event", type: "tool/result", data: { message: { toolCallId: "c5" } } },
  { ev: "stream", frame: { attemptId: "a2", type: "start" } },
  chunk("a2", { type: "block-start", index: 0, blockType: "text" }),
  chunk("a2", { type: "text-delta", index: 0, text: "retried" }),
  chunk("a2", { type: "tool-call-delta", index: 1, id: "c6", name: "read", argumentsDelta: "{" }),
  { ev: "stream", frame: { attemptId: "a2", type: "end", outcome: { kind: "failed" } } },
  { ev: "stream", frame: { attemptId: "a3", type: "chunk", chunk: 0 } },
  { ev: "stream", frame: { attemptId: "a3", type: "chunk", chunk: "" } },
  { ev: "stream", frame: { attemptId: "a3", type: "chunk", chunk: { type: "block-start", index: "x", blockType: "text" } } },
  { ev: "stream", frame: null },
  { ev: "stream" },
  { ev: "event", type: "turn/end", data: { reason: { kind: "completed" } } },
  { ev: "event", type: "turn/start" },
  { ev: "event", type: "turn/end", data: { reason: { kind: "aborted" } } },
  { $prompt: true },
  { id: "prompt:p1", error: "the turn is " + "long ".repeat(300) },
  { id: "prompt:p2", error: "not prompted" },
  { id: "steer:x", error: "no" },
  { id: "open", session: "s2" },
  { id: 5 },
  5,
  null,
  [],
  { ev: null },
  { ev: "other", type: "turn/start" },
  { $prompt: true },
  { ev: "event", type: "turn/start" },
  error("AUTH", "invalid api key"),
  { ev: "event", type: "turn/start" },
  error("missing_credential", "none"),
  { ev: "event", type: "turn/start" },
  error("RATE_LIMIT", "insufficient balance"),
  { ev: "event", type: "turn/start" },
  error("", "HTTP 429 Too Many Requests"),
  { ev: "event", type: "turn/start" },
  { ev: "event", type: "turn/end", data: { reason: { kind: "error", error: { code: 401 } } } },
  { ev: "event", type: "turn/start" },
  { ev: "event", type: "turn/end", data: { reason: { kind: "error", error: "a string" } } },
  { ev: "event", type: "turn/start" },
  { ev: "event", type: "turn/end", data: { reason: { kind: "error" } } },
  { ev: "event", type: "turn/start" },
  error("CONTEXT_WINDOW_EXCEEDED", "context overflow " + "x".repeat(1200)),
  { ev: "event", type: "turn/start" },
  { ev: "event", type: "tool/call", data: { callId: "c9", name: "bash", arguments: "{}" } },
  { $cut: true },
];

const message = (m: Json) => ({ ev: "message", message: m });

/// Cursor's bridge's lines, in order.
export const CURSOR: Json[] = [
  { $new: {} },
  { id: "open", session: "agent-1" },
  { $prompt: true },
  message({ type: "status", status: "RUNNING" }),
  message({ type: "thinking", text: "", run_id: "r1" }),
  message({ type: "thinking", text: "thinking ", run_id: "r1" }),
  message({ type: "thinking", text: "it over", run_id: "r1" }),
  message({ type: "assistant", message: { content: [{ type: "text", text: "hel" }, { type: "image", text: "x" }, { type: "text", text: 5 }] }, run_id: "r1" }),
  message({ type: "assistant", message: { content: [{ type: "text", text: "lo" }] } }),
  message({ type: "assistant", message: { content: "no" } }),
  message({ type: "tool_call", call_id: "c1", name: "shell", status: "running", args: { command: "ls", é: ["😀", 1e21, -0] } }),
  message({ type: "tool_call", call_id: "c1", name: "shell", status: "running", args: { command: "ls" } }),
  message({ type: "tool_call", call_id: "c1", name: "shell", status: "completed", result: { status: "success", value: { stdout: "a\n", stderr: "" } } }),
  message({ type: "tool_call", call_id: "c2", name: "mcp", status: "running", args: { providerIdentifier: "stillfail", toolName: "chat_post", args: { text: "hi" } } }),
  message({ type: "tool_call", call_id: "c2", name: "mcp", status: "error", result: { status: "error", error: "fetch failed: connect ECONNREFUSED 127.0.0.1:4750" } }),
  message({ type: "tool_call", call_id: "c3", name: "mcp", status: "running", args: { providerIdentifier: "stillfail", toolName: "chat_state" } }),
  message({ type: "tool_call", call_id: "c3", name: "mcp", status: "error" }),
  message({ type: "tool_call", call_id: "c4", name: "mcp", status: "running", args: { providerIdentifier: "github", toolName: "search", args: null } }),
  message({ type: "tool_call", call_id: "c4", name: "mcp", status: "error", result: "socket hang up" }),
  message({ type: "tool_call", call_id: "c5", name: "mcp", status: "running", args: { providerIdentifier: "stillfail", toolName: "chat_post" } }),
  message({ type: "tool_call", call_id: "c5", name: "mcp", status: "error", result: "fetch failed " + "<<long:500>>" }),
  message({ type: "tool_call", call_id: "c6", name: "read", status: "completed", args: { path: "a" }, result: '{"value":{"content":[{"text":{"text":"A"}},{"text":"B"},{"x":1}]}}' }),
  message({ type: "tool_call", call_id: "c7", status: "completed", result: "not json" }),
  message({ type: "tool_call", call_id: "c8", name: "edit", status: "completed", result: '"a json string"' }),
  message({ type: "tool_call", call_id: "c9", name: "edit", status: "completed", result: 42 }),
  message({ type: "tool_call", call_id: "c10", name: "edit", status: "completed", result: { error: "denied" } }),
  message({ type: "tool_call", call_id: "c11", name: "edit", status: "completed", result: null }),
  message({ type: "tool_call", call_id: "c12", name: "write", status: "running", args: { text: "<<long:300000>>" } }),
  message({ type: "tool_call", call_id: "c12", name: "write", status: "completed", result: "<<long:270000>>" }),
  message({ type: "tool_call", call_id: "", status: "running" }),
  message({ type: "user" }),
  message({ type: "assistant", message: { content: [{ type: "text", text: "after" }] }, run_id: "r1" }),
  { ev: "end", status: "finished" },
  message({ type: "assistant", message: { content: [{ type: "text", text: "unasked" }] } }),
  { ev: "end", status: "error", error: { code: "rate_limited", message: "Too many requests" } },
  { $prompt: true },
  { $aborting: true },
  { ev: "end", status: "error", error: { message: "stopped" } },
  { $prompt: true },
  { $aborting: true },
  { ev: "end", status: "finished" },
  { ev: "end", status: "cancelled" },
  { ev: "end", status: "weird" },
  { ev: "end" },
  { ev: "end", status: 3, error: { code: 401, message: 7 } },
  { $prompt: true },
  { id: "prompt:p1", error: "no key", code: "unauthenticated" },
  { $prompt: true },
  { id: "prompt:p2", error: "a model it does not have" },
  { id: "prompt:p3", error: "nothing runs" },
  { id: "steer:s1", delivered: true },
  { ev: "log", text: "x" },
  { id: 5 },
  7,
  null,
  { $prompt: true },
  message({ type: "tool_call", call_id: "c20", name: "shell", status: "running", args: {} }),
  { $cut: true },
];

const update = (sessionId: string, u: Json) => ({ jsonrpc: "2.0", method: "session/update", params: { sessionId, update: u } });
const text = (k: "agent_message_chunk" | "agent_thought_chunk", t: Json) => ({ sessionUpdate: k, content: { type: "text", text: t } });
const answer = (id: string, result: Json) => ({ jsonrpc: "2.0", id, result });
const failed = (id: string, error: Json) => ({ jsonrpc: "2.0", id, error });

/// The ACP runtimes' lines, in order (`$new` says which, and whether the station keeps its transcript; `$session`,
/// `$opened`: what Node says of the session it opened; `$prompt`, `$inject`: a prompt given, one put in the turn).
export const ACP: Json[] = [];
for (const [flavor, kept] of [["grok", false], ["agy", true], ["devin", true], ["hermes", true]] as const) {
  const S = `s-${flavor}`;
  ACP.push(
    { $new: { flavor, kept } },
    update(S, { sessionUpdate: "plan", entries: [{ content: "Survey", status: "completed" }, { content: "Ship" }, { status: "pending" }, { content: 5 }] }),
    update(S, text("agent_message_chunk", "loaded past")),
    answer("init", { protocolVersion: 1 }),
    { $session: S },
    answer("open", { sessionId: S }),
    { $opened: true },
    update(S, text("agent_message_chunk", "no turn")),
    update(S, { sessionUpdate: "usage_update", used: 10, size: 100 }),
    { $prompt: { owner: "prompt:p1", text: "hello" } },
    update(S, text("agent_thought_chunk", "thinking ")),
    update(S, text("agent_thought_chunk", "it over")),
    update(S, { sessionUpdate: "agent_thought_chunk", content: { type: "content", content: { text: "nested" } } }),
    update(S, text("agent_message_chunk", "Hé😀 ")),
    update(S, text("agent_message_chunk", "")),
    update(S, { sessionUpdate: "agent_message_chunk", content: { text: 5 } }),
    update(S, { sessionUpdate: "tool_call", toolCallId: "c1", title: "Run mcp_stillfail_chat_post", status: "pending", rawInput: { text: "hi" }, _meta: {} }),
    update(S, { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "in_progress" }),
    update(S, { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "failed", content: [{ type: "content", content: { type: "text", text: "fetch failed: ECONNREFUSED" } }, { text: 5 }, { text: "" }, { content: { text: null }, text: "outer" }, {}] }),
    update(S, { sessionUpdate: "tool_call", toolCallId: "c2", title: "use_tool", rawInput: { tool_name: "stillfail__chat_state", tool_input: { state: "all_done" } }, _meta: { "x.ai/tool": { name: "use_tool" } } }),
    { jsonrpc: "2.0", id: "perm-1", method: "session/request_permission", params: { sessionId: S, options: [{ optionId: "allow", kind: "allow_once" }] } },
    { jsonrpc: "2.0", id: 7, method: "fs/read_text_file", params: {} },
    { jsonrpc: "2.0", method: "_x.ai/session_notification", params: { sessionId: S, update: { sessionUpdate: "subagent_spawned", child_session_id: "k1" } } },
    update("k1", { sessionUpdate: "tool_call", toolCallId: "k-c1", title: "read_file", rawInput: { path: "a" }, _meta: { "x.ai/tool": { name: "read_file" } } }),
    update("k1", text("agent_message_chunk", "found A")),
    update("k1", { sessionUpdate: "plan", entries: [{ content: "child plan" }] }),
    { jsonrpc: "2.0", method: "_x.ai/session_notification", params: { sessionId: S, update: { sessionUpdate: "subagent_spawned", child_session_id: "k2" } } },
    update("k2", text("agent_thought_chunk", "child thinks")),
    { jsonrpc: "2.0", method: "_x.ai/session_notification", params: { sessionId: S, update: { sessionUpdate: "subagent_finished", child_session_id: "k1" } } },
    { jsonrpc: "2.0", method: "_x.ai/session_notification", params: { sessionId: "other", update: { sessionUpdate: "subagent_spawned", child_session_id: "k3" } } },
    update(S, { sessionUpdate: "tool_call_update", toolCallId: "c2", status: "completed", content: [{ type: "content", content: { type: "text", text: "ok" } }] }),
    update(S, { sessionUpdate: "tool_call", toolCallId: "c3", title: "hermes_tool: its input preview", rawInput: { a: 1 }, _meta: { "cognition.ai/inferenceToolName": "mcp__stillfail__chat_post" } }),
    update(S, { sessionUpdate: "tool_call", toolCallId: "c4", title: "mcp__editor_stillfail_0a1b2c3d__chat_post: words", rawInput: { text: "<<long:300000>>" } }),
    update(S, { sessionUpdate: "tool_call_update", toolCallId: "c4", status: "failed", content: [{ content: { text: "Unable to connect " } }, { content: { text: "<<long:600>>" } }] }),
    update(S, { sessionUpdate: "tool_call_update", toolCallId: "c3", status: "completed", content: [{ type: "content", content: { type: "text", text: "<<long:30000>>" } }] }),
    update(S, { sessionUpdate: "tool_call", toolCallId: "", title: "x" }),
    update(S, { sessionUpdate: "tool_call", toolCallId: 5, title: "x" }),
    update(S, { sessionUpdate: "usage_update", used: 500, size: 1000, cost: { amount: 1 } }),
    update(S, text("agent_message_chunk", "⚠ Individual quota reached. Please upgrade your subscription.")),
    answer("prompt:other", { stopReason: "end_turn" }),
    answer("prompt:p1", { stopReason: "end_turn", _meta: { usage: { inputTokens: 5 } } }),
    update(S, text("agent_message_chunk", "after the turn")),
    { $prompt: { owner: "prompt:p2", text: "steer me" } },
    update(S, text("agent_message_chunk", "working")),
    { $inject: { id: "steer:i1", takeOver: flavor === "agy", text: "and this" } },
    update(S, text("agent_message_chunk", " more")),
    answer("steer:i1", { stopReason: "end_turn" }),
    answer("prompt:p2", { stopReason: "end_turn" }),
    { $inject: { id: "steer:late", takeOver: false, text: "late" } },
    update(S, text("agent_message_chunk", "a turn of its own")),
    answer("steer:late", { stopReason: "end_turn" }),
    answer("prompt:p2", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p3", text: "fail" } },
    update(S, { sessionUpdate: "tool_call", toolCallId: "c9", title: "shell", rawInput: null }),
    failed("prompt:p3", { code: -32603, message: "Internal error: 401 Unauthorized", data: { details: "sign in again" } }),
    { $prompt: { owner: "prompt:p4", text: "fail" } },
    failed("prompt:p4", { code: -32603, message: "Internal error: authentication required", data: "please log in" }),
    { $prompt: { owner: "prompt:p5", text: "fail" } },
    failed("prompt:p5", { code: 1, data: { message: "quota" } }),
    { $prompt: { owner: "prompt:p6", text: "fail" } },
    failed("prompt:p6", null),
    { $prompt: { owner: "prompt:p7", text: "refused" } },
    answer("prompt:p7", { stopReason: "refusal" }),
    { $prompt: { owner: "prompt:p8", text: "cancel" } },
    { $aborting: true },
    failed("prompt:p8", { message: "cancelled" }),
    { $prompt: { owner: "prompt:p9", text: "cancel" } },
    answer("prompt:p9", { stopReason: "cancelled" }),
    { $prompt: { owner: "prompt:p10", text: "said a notice" } },
    update(S, text("agent_message_chunk", "  ⚠ Authentication expired. Please log back in.  ")),
    answer("prompt:p10", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p10b", text: "said an executor notice after partial text" } },
    update(S, text("agent_message_chunk", "partial\n⚠ Agent execution terminated due to error.\n")),
    answer("prompt:p10b", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p10c", text: "said an unauthenticated notice after partial text" } },
    update(S, text("agent_message_chunk", "partial\n⚠ UNAUTHENTICATED (code 401): Request had invalid authentication credentials.\n")),
    answer("prompt:p10c", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p10d", text: "said verification required" } },
    update(S, text("agent_message_chunk", "⚠ Verification Required")),
    answer("prompt:p10d", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p10e", text: "said verification required after partial text" } },
    update(S, text("agent_message_chunk", "partial\n⚠ Verification Required\n")),
    answer("prompt:p10e", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p10f", text: "said vertex iam permission denied" } },
    update(S, text("agent_message_chunk", "⚠ Permission 'aiplatform.endpoints.predict' denied on resource '//aiplatform.googleapis.com/projects/p/locations/global/publishers/google/models/gemini-4-carbon' (or it may not exist).")),
    answer("prompt:p10f", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p11", text: "said a notice, two lines" } },
    update(S, text("agent_message_chunk", "⚠ Check the quota:\nit is low.")),
    answer("prompt:p11", { stopReason: "end_turn" }),
    { $prompt: { owner: "prompt:p12", text: "exit" } },
    update(S, text("agent_message_chunk", "cut")),
    update(S, { sessionUpdate: "tool_call", toolCallId: "c10", title: "shell", rawInput: {} }),
    { $cut: true },
    { notAnything: true },
    null,
    42,
  );
}
// agy resumed via session/load: ghost history replay discarded on first prompt, resent once without duplicate user line.
ACP.push(
  { $new: { flavor: "agy", kept: true } },
  { $session: "s-agy-resumed" },
  { $opened: { resumed: true } },
  { $prompt: { owner: "prompt:r1", text: "real ask" } },
  update("s-agy-resumed", { sessionUpdate: "tool_call", toolCallId: "g1", title: "view_file", status: "in_progress", rawInput: { path: "/old" } }),
  update("s-agy-resumed", { sessionUpdate: "tool_call_update", toolCallId: "g1", status: "completed", content: [{ type: "content", content: { type: "text", text: "old output" } }] }),
  update("s-agy-resumed", text("agent_message_chunk", "old replayed text")),
  answer("prompt:r1", { stopReason: "end_turn" }),
  { $resend: { owner: "prompt:r2" } },
  update("s-agy-resumed", text("agent_message_chunk", "fresh real answer")),
  answer("prompt:r2", { stopReason: "end_turn", usage: { inputTokens: 100, outputTokens: 20 } }),
);

/// What a crash reads again of an output: the lines, and what the session it read is new with.
export const DSH_REPLAYS: Json[][] = [
  [{ id: "open", session: "s1" }, { ev: "event", type: "turn/start" }, chunk("a", { type: "block-start", index: 0, blockType: "text" }), chunk("a", { type: "text-delta", index: 0, text: "hi" })],
  [{ id: "open", session: "s1" }, { ev: "event", type: "turn/start" }, { ev: "event", type: "turn/end", data: {} }, { id: "open", session: 5 }],
  [],
];
export const CURSOR_REPLAYS: Json[][] = [
  [{ id: "open", session: "agent-1" }, message({ type: "assistant", message: { content: [{ type: "text", text: "hi" }] }, run_id: "r" }), message({ type: "tool_call", call_id: "c1", status: "running", name: "shell", args: {} })],
  [{ id: "open", session: "agent-1" }, message({ type: "assistant", message: { content: [{ type: "text", text: "hi" }] } }), { ev: "end", status: "finished" }],
];
/// Each with the runtime ([flavor, kept, resume]) first.
export const ACP_REPLAYS: Json[][] = [
  [["grok", false, ""], answer("open", { sessionId: "g1", models: { currentModelId: "m" } }), update("g1", text("agent_message_chunk", "hel")), update("g1", { sessionUpdate: "tool_call", toolCallId: "c1", title: "read", rawInput: { p: 1 } }), update("g1", { sessionUpdate: "usage_update", used: 3 })],
  [["devin", true, "d1"], update("d1", text("agent_message_chunk", "before open")), answer("open", {}), update("d1", { sessionUpdate: "usage_update", used: 3 }), update("d1", text("agent_message_chunk", "said ")), update("d1", text("agent_message_chunk", "this")), update("x", text("agent_message_chunk", "other")), update("d1", { sessionUpdate: "tool_call", toolCallId: "c1", title: "read", rawInput: {} }), update("d1", { sessionUpdate: "tool_call_update", toolCallId: "c1", status: "completed", content: [{ content: { text: "ok" } }] }), update("d1", text("agent_thought_chunk", "now thinking"))],
  [["agy", true, ""], answer("open", { sessionId: "a1" }), update("a1", text("agent_message_chunk", "hi")), answer("steer:s1", {}), update("a1", { sessionUpdate: "usage_update", used: 9 })],
  [["hermes", true, ""], answer("open", { sessionId: "h1" }), update("h1", { sessionUpdate: "tool_call", toolCallId: "c1", title: "terminal: ls", rawInput: {} }), answer("prompt:x", {}), update("h1", { sessionUpdate: "plan", entries: [] })],
];

type Step = [string, string, string, string, string];

/// What the TypeScript says of each line of `lines` (DSH, CURSOR, ACP): [the line, its events, whether Node reads it,
/// the turn after, the session's state after].
export function said(kind: "dsh" | "cursor" | "acp", lines: Json[]): Step[] {
  let s: DshReference | CursorReference | AcpReference = new DshReference();
  const out: Step[] = [];
  const state = () => (s instanceof AcpReference ? s.state() : s.live.state());
  for (const raw of lines) {
    const line = expand(raw);
    let events: Json[] = [];
    let node = false;
    if (line?.$new !== undefined) {
      s = kind === "dsh" ? new DshReference() : kind === "cursor" ? new CursorReference() : new AcpReference(line.$new.flavor, line.$new.kept, () => NOW);
    } else if (line?.$prompt !== undefined) events = s instanceof AcpReference ? s.prompted(line.$prompt.owner, line.$prompt.text) : s.prompted();
    else if (line?.$resend !== undefined) events = (s as AcpReference).resent(line.$resend.owner);
    else if (line?.$inject !== undefined) events = (s as AcpReference).injected(line.$inject.id, line.$inject.takeOver, line.$inject.text);
    else if (line?.$session !== undefined) (s as AcpReference).session = line.$session;
    else if (line?.$opened !== undefined) (s as AcpReference).opened(line.$opened?.resumed === true);
    else if (line?.$aborting !== undefined) s.turn.aborting = true;
    else if (line?.$cut !== undefined) events = cutShort(s);
    else ({ events, node } = s.line(line));
    out.push([JSON.stringify(raw), JSON.stringify(folded(events)), String(node), JSON.stringify(s.turn), JSON.stringify(folded(state()))]);
  }
  return out;
}

/// What its process going away during a turn ends (dsh.ts, cursor.ts, acp.ts `cutShort`).
function cutShort(s: DshReference | CursorReference | AcpReference): Json[] {
  const live = (e: Json) => ({ type: "live", event: e });
  if (s instanceof DshReference) return s.turn.busy || s.turn.prompted ? s.live.ended().map(live) : [];
  if (s instanceof CursorReference) return s.turn.busy ? s.live.ended().map(live) : [];
  return s.cutShort();
}

/// What a crash reads again of an output comes to (dsh.ts, cursor.ts `crashed`; acp.ts `replay`).
export function replayed(kind: "dsh" | "cursor" | "acp", raw: Json[]): [string, string] {
  const lines = expand(raw);
  let result: Json;
  if (kind === "dsh") {
    const turn = { busy: false, prompted: false, aborting: false };
    const live = new LiveFromDsh();
    let session: string | null = null;
    for (const message of lines) {
      if (message.id === "open" && typeof message.session === "string") session = message.session;
      if (message.ev === "event" && message.type === "turn/start") turn.busy = true;
      if (message.ev === "event" && message.type === "turn/end") turn.busy = false;
      live.feed(message);
    }
    result = { session, turn, live: live.state() };
  } else if (kind === "cursor") {
    const turn = { busy: false, aborting: false };
    const live = new LiveFromCursor();
    let session: string | null = null;
    for (const message of lines) {
      if (message.id === "open" && typeof message.session === "string") session = message.session;
      if (message.ev === "message") {
        turn.busy = true;
        live.feed(message.message);
      } else if (message.ev === "end") {
        turn.busy = false;
        live.ended();
      }
    }
    result = { session, turn, live: live.state() };
  } else {
    const [[flavor, kept, resume], ...rest] = lines;
    result = new AcpReference(flavor, kept, () => NOW).replay(rest, resume);
  }
  return [JSON.stringify(raw), JSON.stringify(folded(result))];
}

/// The file of what the TypeScript said, for the program's tests in mb/src/<kind>.
export function written(kind: "dsh" | "cursor" | "acp"): string {
  const json = (s: string) => s.replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
  const steps = said(kind, kind === "dsh" ? DSH : kind === "cursor" ? CURSOR : ACP);
  const replays = (kind === "dsh" ? DSH_REPLAYS : kind === "cursor" ? CURSOR_REPLAYS : ACP_REPLAYS).map((r) => replayed(kind, r));
  const lines: string[] = [];
  lines.push(`// What the TypeScript station made of ${kind === "dsh" ? "DeepSeek Harness'" : kind === "cursor" ? "Cursor's bridge's" : "the ACP runtimes'"} lines (station/test/reference/live.ts, written by`);
  lines.push("// station/test/runtime-cases.ts): each line's events, whether Node reads it, the turn and the session's state after it,");
  lines.push("// and what a crash reads again of an output. Do not edit: run `node test/runtime-cases.ts` in station/.");
  lines.push("");
  lines.push("///|");
  lines.push("/// (line, events, read by Node, turn after, state after), as node said.");
  lines.push("let steps_said : Array[(String, String, String, String, String)] = [");
  for (const step of steps) {
    lines.push("  (");
    for (const s of step) {
      lines.push("    (");
      lines.push(`      #|${json(s)}`);
      lines.push("    ),");
    }
    lines.push("  ),");
  }
  lines.push("]");
  lines.push("");
  lines.push("///|");
  lines.push("/// (lines, what they come to), as node said.");
  lines.push("let replays_said : Array[(String, String)] = [");
  for (const step of replays) {
    lines.push("  (");
    for (const s of step) {
      lines.push("    (");
      lines.push(`      #|${json(s)}`);
      lines.push("    ),");
    }
    lines.push("  ),");
  }
  lines.push("]");
  return lines.join("\n") + "\n";
}

export const said_file = (kind: "dsh" | "cursor" | "acp") => new URL(`../mb/src/${kind}/as_typescript_said_test.mbt`, import.meta.url);

if (import.meta.main) {
  for (const kind of ["dsh", "cursor", "acp"] as const) writeFileSync(said_file(kind), written(kind));
}
