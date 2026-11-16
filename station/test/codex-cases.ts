// What a Codex app-server says that the station reads of it, for comparing the program's reading (station/mb/src/codex)
// with the TypeScript station's (codex-reference.ts): every kind of item, a pretty-printed call's input, every
// `codexErrorInfo` branch, the station's tools out of reach, what is cut short. `node test/codex-cases.ts` writes what
// the TypeScript says of them as station/mb/src/codex/as_typescript_said_test.mbt.
import { writeFileSync } from "node:fs";
import { classifyCodexError, codexEvents, LiveFromCodex } from "./codex-reference.ts";

type Json = any;

const long = (n: number) => Array.from({ length: n }, (_, i) => (i % 7 === 3 ? "😀" : String.fromCharCode(0x61 + (i % 26)))).join("");

/// One thread's notifications in order: [method, params].
export const NOTICES: [string, Json][] = [
  ["turn/started", { threadId: "t", turn: { id: "tu-1" } }],
  ["item/started", { threadId: "t", item: { type: "agentMessage", id: "m1" } }],
  ["item/agentMessage/delta", { threadId: "t", turnId: "tu-1", itemId: "m1", delta: "Hel" }],
  ["item/agentMessage/delta", { threadId: "t", itemId: "m1", delta: "" }],
  ["item/agentMessage/delta", { threadId: "t", itemId: "m1", delta: 5 }],
  ["item/reasoning/textDelta", { threadId: "t", itemId: "nobody", delta: "x" }],
  ["item/started", { threadId: "t", item: { type: "reasoning", id: "r1" } }],
  ["item/reasoning/summaryTextDelta", { threadId: "t", itemId: "r1", delta: "thinking…", summaryIndex: 0 }],
  ["item/reasoning/textDelta", { threadId: "t", itemId: "r1", delta: "more", contentIndex: 1 }],
  ["item/completed", { threadId: "t", item: { type: "reasoning", id: "r1" } }],
  ["item/completed", { threadId: "t", item: { type: "agentMessage", id: "m1", text: "Hel" } }],
  ["item/started", { threadId: "t", item: { type: "commandExecution", id: "c1", command: "ls -la \"x\"\n" } }],
  ["item/commandExecution/outputDelta", { threadId: "t", itemId: "c1", delta: "out\n é" }],
  ["item/completed", { threadId: "t", item: { type: "commandExecution", id: "c1" } }],
  ["item/started", { threadId: "t", item: { type: "commandExecution", id: "c2" } }],
  ["item/completed", { threadId: "t", item: { type: "commandExecution", id: "c2" } }],
  ["item/started", { threadId: "t", item: { type: "fileChange", id: "f1", changes: [{ path: "a.ts" }, { path: "b/c.ts" }, null, {}, { path: 3 }] } }],
  ["item/completed", { threadId: "t", item: { type: "fileChange", id: "f1" } }],
  ["item/started", { threadId: "t", item: { type: "fileChange", id: "f2", changes: "no" } }],
  ["item/completed", { threadId: "t", item: { type: "fileChange", id: "f2" } }],
  ["item/started", { threadId: "t", item: { type: "mcpToolCall", id: "x1", server: "stillfail", tool: "chat_post", arguments: { b: 1, a: { "2": true, "10": [1.5, "x", null, {}], "1": [] }, z: null, u: "é \"", n: -0, e: 1e21, f: 0.1 } } }],
  ["item/completed", { threadId: "t", item: { type: "mcpToolCall", id: "x1", server: "stillfail", status: "failed", error: { message: "error sending request: ECONNREFUSED 127.0.0.1:4750 " + long(400) } } }],
  ["item/started", { threadId: "t", item: { type: "mcpToolCall", id: "x2", server: "github", tool: "search", arguments: [] } }],
  ["item/completed", { threadId: "t", item: { type: "mcpToolCall", id: "x2", server: "github", status: "failed", error: { message: "connection refused" } } }],
  ["item/started", { threadId: "t", item: { type: "mcpToolCall", id: "x3", server: "stillfail", tool: "chat_state", arguments: null } }],
  ["item/completed", { threadId: "t", item: { type: "mcpToolCall", id: "x3", server: "stillfail", status: "failed", error: { message: "text is empty" } } }],
  ["item/started", { threadId: "t", item: { type: "mcpToolCall", id: "x4", server: "stillfail", tool: "chat_state" } }],
  ["item/completed", { threadId: "t", item: { type: "mcpToolCall", id: "x4", server: "stillfail", status: "completed" } }],
  ["item/completed", { threadId: "t", item: { type: "mcpToolCall", id: "x5", server: "stillfail", status: "failed", error: { message: "Failed to connect to MCP server stillfail" } } }],
  ["item/started", { threadId: "t", item: { type: "dynamicToolCall", id: 7, tool: "dyn", arguments: { "": "" } } }],
  ["item/completed", { threadId: "t", item: { type: "dynamicToolCall", id: 7 } }],
  ["item/started", { threadId: "t", item: { type: "dynamicToolCall", id: 7.5 } }],
  ["item/started", { threadId: "t", item: { type: "webSearch", id: "w1", query: "moonbit" } }],
  ["item/completed", { threadId: "t", item: { type: "webSearch", id: "w1" } }],
  ["item/started", { threadId: "t", item: { type: "plan", id: "p1" } }],
  ["item/plan/delta", { threadId: "t", itemId: "p1", delta: "1. a" }],
  ["item/plan/delta", { threadId: "t", itemId: "m1", delta: "1. a" }],
  ["item/started", { threadId: "t", item: { type: "agentMessage", id: "" } }],
  ["item/started", { threadId: "t", item: { type: "agentMessage", id: "m2" } }],
  ["item/started", { threadId: "t", item: { type: "agentMessage", id: "m2" } }],
  ["item/plan/delta", { threadId: "t", itemId: "m2", delta: "plan" }],
  ["item/started", { threadId: "t", item: { type: "contextCompaction", id: "cc" } }],
  ["item/completed", { threadId: "t", item: { type: "contextCompaction", id: "cc" } }],
  ["item/started", { threadId: "t" }],
  ["item/started", { threadId: "t", item: null }],
  ["item/completed", { threadId: "t", item: 3 }],
  ["turn/diff/updated", { threadId: "t", diff: "x" }],
  ["error", { threadId: "t", error: { message: "x" }, willRetry: true }],
  ["turn/completed", { threadId: "t", turn: { id: "tu-1", status: "failed", error: { codexErrorInfo: { responseStreamDisconnected: { httpStatusCode: null } }, message: "stream disconnected before completion" } } }],
  ["turn/started", { threadId: "t", turn: {} }],
  ["item/started", { threadId: "t", item: { type: "agentMessage", id: "m3" } }],
  ["turn/completed", { threadId: "t", turn: { status: "interrupted" } }],
  ["item/agentMessage/delta", { threadId: "t", itemId: "m3", delta: "after" }],
  ["turn/started", { threadId: "t", turn: { id: 4 } }],
  ["turn/completed", { threadId: "t", turn: { status: "completed" } }],
  ["turn/completed", { threadId: "t", turn: { status: "failed", error: { message: long(1500) } } }],
  ["turn/completed", { threadId: "t", turn: { status: "failed", error: null } }],
  ["turn/completed", { threadId: "t", turn: { status: "failed", error: { codexErrorInfo: "usageLimitExceeded", message: 3 } } }],
  ["turn/completed", { threadId: "t", turn: { status: "failed", error: { codexErrorInfo: { other: { httpStatusCode: 429 } }, message: "Too many requests" } } }],
  ["turn/completed", { threadId: "t" }],
];

/// What `classifyCodexError` is given: its `codexErrorInfo` and message.
export const ERRORS: [Json, string][] = [
  [null, ""],
  [{ serverOverloaded: null }, ""],
  [{ usageLimitExceeded: null }, ""],
  [null, "auth error: 401, auth error code: token_revoked"],
  [null, "model not supported"],
  [{ responseStreamConnectionFailed: { httpStatusCode: 403 } }, "unexpected status 403 Forbidden: Unknown error"],
  ["other", "unexpected status 403 Forbidden: "],
  [{ responseStreamConnectionFailed: { httpStatusCode: 403 } }, "unexpected status 403 Forbidden: <!DOCTYPE html><title>Just a moment...</title>"],
  [{ responseStreamConnectionFailed: { httpStatusCode: 401 } }, "unexpected status 401 Unauthorized: "],
  [{ responseStreamDisconnected: { httpStatusCode: null } }, "stream disconnected before completion"],
  [null, "stream disconnected before completion: error sending request for url (https://chatgpt.com/backend-api/codex/responses)"],
  ["contextWindowExceeded", "Codex ran out of room in the model's context window"],
  ["unauthorized", ""],
  ["rateLimitExceeded", ""],
  [{ rateLimitExceeded: { httpStatusCode: 200 } }, ""],
  [{ httpConnectionFailed: { httpStatusCode: 502 } }, "bad gateway"],
  [{ httpConnectionFailed: { httpStatusCode: 404 } }, "not found"],
  [{ httpConnectionFailed: { httpStatusCode: 500 } }, ""],
  [{ httpConnectionFailed: { httpStatusCode: "500" } }, ""],
  [{ httpConnectionFailed: [] }, ""],
  [{ httpConnectionFailed: null }, "quota exceeded"],
  [{ "1": { httpStatusCode: 429 }, unauthorized: null }, "slow down"],
  [{ other: { httpStatusCode: 429 } }, "Too many"],
  [{ other: { httpStatusCode: 529 } }, ""],
  [{ other: { httpStatusCode: 403 } }, "region is not supported"],
  [{ other: { httpStatusCode: 403 } }, "missing scope"],
  [{}, "Unauthorized!"],
  [[], "token_revoked"],
  [5, "TOKEN_REVOKED."],
  [true, "token_revokedx"],
  [null, "a_401 b"],
  [null, "x-401"],
  [null, "错误401"],
  [null, "Your Invalidated OAuth Token here"],
  [null, "your API key is wrong"],
  [null, "request not allowed"],
  [null, "Forbidden"],
  [null, "Quota exceeded"],
  [null, "context_length exceeded"],
  [null, "read ECONNRESET"],
  [null, "Connection Failed"],
  [null, "The model is OVERLOADED"],
  [null, "ok"],
  [null, "HTTP 429_x"],
  [null, "HTTP 529"],
  [null, "İ 401"],
];

if (import.meta.main) {
  const json = (v: unknown) => JSON.stringify(v).replace(/[\u007f-￿]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, "0")}`);
  const live = new LiveFromCodex();
  const lines: string[] = [];
  lines.push("// What the TypeScript station made of a Codex thread's notifications and errors (station/test/codex-reference.ts,");
  lines.push("// written by station/test/codex-cases.ts with node " + process.version + "): each notification's events with the thread's");
  lines.push("// live steps after it, and each error's reason. Do not edit: run `node test/codex-cases.ts` in station/.");
  lines.push("");
  lines.push("///|");
  lines.push("/// (method, params, events, live steps after), as node said.");
  lines.push("let notices_said : Array[(String, String, String, String)] = [");
  for (const [method, params] of NOTICES) {
    const events = codexEvents(live, method, params);
    lines.push(`  (`);
    for (const s of [method, json(params), json(events), json(live.state())]) {
      lines.push(`    (`);
      lines.push(`      #|${s}`);
      lines.push(`    ),`);
    }
    lines.push(`  ),`);
  }
  lines.push("]");
  lines.push("");
  lines.push("///|");
  lines.push("/// (codexErrorInfo, message, reason), as node said.");
  lines.push("let errors_said : Array[(String, String, String)] = [");
  for (const [info, message] of ERRORS) {
    lines.push(`  (`);
    for (const s of [json(info), json(message), classifyCodexError(info, message)]) {
      lines.push(`    (`);
      lines.push(`      #|${s}`);
      lines.push(`    ),`);
    }
    lines.push(`  ),`);
  }
  lines.push("]");
  writeFileSync(new URL("../mb/src/codex/as_typescript_said_test.mbt", import.meta.url), lines.join("\n") + "\n");
}
