// A fake `pi --mode rpc` (src/agents/pi.ts): its answers and its session's events as Pi 1.5 writes them, keeping the
// session in the file `--session` names, as Pi does (a header, then its entries: each message with its usage). A
// prompt's text says what the turn does:
//   say:<text>    a thought, then a reply                fail:auth   the model's answer fails as a refused key does
//   cmd           a bash call with its output, then a reply           refuse      the prompt is refused
//   tools         a call to the station's tools that fails as unreachable
//   hold          (or a prompt with test-hold in it, as the hub words one) a reply, then waits: a steer is answered in
//                 the same run (`steer:<text>`, then it settles), an abort settles it aborted
//   exit          exits 4 in the middle of the turn
//   gate:<name>   a reply's first part; the rest once FAKE_DUMP.<name>.a (a fifo) is written, then FAKE_DUMP.<name>.said
//                 made; the settling once FAKE_DUMP.<name>.b is (what the test lets happen when, not a time)
// FAKE_DUMP: its argv and env are appended there as a JSON line, and every line of stdin to FAKE_DUMP.stdin. Its version
// (`--version`) is 1.5.2. An extension's dialog is asked once a turn says `ask` (the answer is dumped to stdin's file).
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";

if (process.argv[2] === "--version") {
  console.log("1.5.2");
  process.exit(0);
}
const dump = process.env.FAKE_DUMP;
if (dump) fs.appendFileSync(dump, JSON.stringify({ argv: process.argv.slice(2), env: process.env, cwd: process.cwd(), pid: process.pid }) + "\n");
const arg = (name) => (process.argv.includes(name) ? process.argv[process.argv.indexOf(name) + 1] : undefined);
const file = arg("--session");
const model = arg("--model") ?? "default";

const say = (msg) => fs.writeSync(1, JSON.stringify(msg) + "\n");
const gate = async (at) => {
  while (process.platform === "win32" && !fs.existsSync(at)) await new Promise((r) => setTimeout(r, 10));
  return fs.promises.readFile(at);
};

let seq = 0;
let parent = null;
let time = 1_800_000_000_000;
/// An entry of the session as Pi keeps it (its header first, once there is something to keep).
function keep(message) {
  if (!fs.existsSync(file)) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify({ type: "session", version: 3, id: "0199a1b2-fake", timestamp: new Date(time).toISOString(), cwd: process.cwd() }) + "\n");
  } else if (parent === null) {
    // Taken up: the entries go on after the last one there.
    const lines = fs.readFileSync(file, "utf8").trim().split("\n");
    parent = JSON.parse(lines[lines.length - 1]).id ?? null;
    seq = lines.length;
  }
  const id = `e${++seq}`;
  fs.appendFileSync(file, JSON.stringify({ type: "message", id, parentId: parent, timestamp: new Date(++time).toISOString(), message }) + "\n");
  parent = id;
}
const usage = { input: 100, output: 7, cacheRead: 20, cacheWrite: 0, totalTokens: 127, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const none = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

/// One answer of the model: a thought (when given), words (when given), a call (when given), streamed block by block.
function answer({ thought, words, call, stopReason = "stop", errorMessage }) {
  const content = [];
  const base = { role: "assistant", api: "openai-completions", provider: "stillfail", model, usage: none, stopReason: "pending", timestamp: time };
  say({ type: "message_start", message: { ...base, content: [] } });
  const update = (e) => say({ type: "message_update", usage, assistantMessageEvent: e });
  if (thought !== undefined) {
    const i = content.length;
    update({ type: "thinking_start", contentIndex: i });
    update({ type: "thinking_delta", contentIndex: i, delta: thought });
    update({ type: "thinking_end", contentIndex: i, content: thought });
    content.push({ type: "thinking", thinking: thought });
  }
  for (const part of words === undefined ? [] : Array.isArray(words) ? words : [words]) {
    const i = content.length;
    update({ type: "text_start", contentIndex: i });
    update({ type: "text_delta", contentIndex: i, delta: part });
    update({ type: "text_end", contentIndex: i, content: part });
    content.push({ type: "text", text: part });
  }
  if (call !== undefined) {
    const i = content.length;
    update({ type: "toolcall_start", contentIndex: i, id: call.id, toolName: call.name });
    update({ type: "toolcall_delta", contentIndex: i, delta: JSON.stringify(call.args) });
    const toolCall = { type: "toolCall", id: call.id, name: call.name, arguments: call.args };
    update({ type: "toolcall_end", contentIndex: i, toolCall });
    content.push(toolCall);
  }
  const message = { ...base, content, usage: errorMessage === undefined ? usage : none, stopReason, ...(errorMessage === undefined ? {} : { errorMessage }) };
  say({ type: "message_end", message });
  keep(message);
  return message;
}

/// A call run: its start, its end with what it gave back, and its result kept.
function run(call, text, isError = false) {
  say({ type: "tool_execution_start", toolCallId: call.id, toolName: call.name, args: call.args });
  const result = { content: [{ type: "text", text }] };
  say({ type: "tool_execution_end", toolCallId: call.id, toolName: call.name, result, isError, durationMs: 3 });
  const message = { role: "toolResult", toolCallId: call.id, toolName: call.name, content: result.content, isError, timestamp: time };
  say({ type: "message_start", message });
  say({ type: "message_end", message });
  keep(message);
}

function user(text) {
  const message = { role: "user", content: [{ type: "text", text }], timestamp: time };
  say({ type: "message_start", message });
  say({ type: "message_end", message });
  keep(message);
}

/// The running run: { steers, wake, aborted }, or null.
let running = null;
let calls = 0;

async function turn(text) {
  running = { steers: [], wake: null, aborted: false };
  say({ type: "agent_start" });
  say({ type: "turn_start" });
  user(text);
  const hold = text === "hold" || text.includes("test-hold");
  if (text.startsWith("say:")) {
    answer({ thought: "thinking it over", words: text.slice(4) });
  } else if (text === "cmd" || text === "tools") {
    const call = text === "cmd" ? { id: `call_${++calls}`, name: "bash", args: { command: "ls" } } : { id: `call_${++calls}`, name: "mcp__stillfail__chat_post", args: { text: "hi" } };
    answer({ words: "Let me look.", call, stopReason: "toolUse" });
    say({ type: "turn_end", message: {}, toolResults: [] });
    say({ type: "turn_start" });
    if (text === "cmd") run(call, "a\n");
    else run(call, "fetch failed: connect ECONNREFUSED 127.0.0.1:4750", true);
    answer({ words: "done" });
  } else if (text === "fail:auth") {
    answer({ stopReason: "error", errorMessage: '401: {"message":"Incorrect API key provided","code":"invalid_api_key"}' });
  } else if (text === "exit") {
    answer({ words: "going" });
    process.exit(4);
  } else if (text === "ask") {
    say({ type: "extension_ui_request", id: "ui-1", method: "confirm", title: "Sure?", message: "Really?" });
    answer({ words: "asked" });
  } else if (text.startsWith("gate:")) {
    const name = text.slice(5);
    say({ type: "message_start", message: { role: "assistant", content: [], stopReason: "pending" } });
    say({ type: "message_update", usage, assistantMessageEvent: { type: "text_start", contentIndex: 0 } });
    say({ type: "message_update", usage, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "first " } });
    await gate(`${dump}.${name}.a`);
    say({ type: "message_update", usage, assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "second" } });
    say({ type: "message_update", usage, assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "first second" } });
    const message = { role: "assistant", content: [{ type: "text", text: "first second" }], provider: "stillfail", model, usage, stopReason: "stop" };
    say({ type: "message_end", message });
    keep(message);
    fs.writeFileSync(`${dump}.${name}.said`, "");
    await gate(`${dump}.${name}.b`);
  } else if (hold) {
    answer({ words: "holding" });
    // Waits for a steer or an abort.
    while (running.steers.length === 0 && !running.aborted) await new Promise((r) => (running.wake = r));
    for (const steer of running.steers.splice(0)) {
      say({ type: "turn_end", message: {}, toolResults: [] });
      say({ type: "turn_start" });
      say({ type: "queue_update", steering: [], followUp: [] });
      user(steer);
      answer({ words: `steer:${steer}` });
    }
  } else {
    answer({ words: text });
  }
  say({ type: "turn_end", message: {}, toolResults: [] });
  say({ type: "agent_end", messages: [], willRetry: false });
  const aborted = running.aborted;
  running = null;
  say({ type: "agent_settled", aborted });
}

const lines = readline.createInterface({ input: process.stdin });
lines.on("line", (line) => {
  if (dump) fs.appendFileSync(`${dump}.stdin`, line + "\n");
  const m = JSON.parse(line);
  const respond = (extra = {}) => say({ ...(m.id === undefined ? {} : { id: m.id }), type: "response", command: m.type, success: true, ...extra });
  if (m.type === "get_state") return respond({ data: { sessionFile: file, sessionId: "0199a1b2-fake", isStreaming: running !== null } });
  if (m.type === "prompt") {
    if (running !== null || m.message === "refuse") return say({ id: m.id, type: "response", command: "prompt", success: false, error: "Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message." });
    respond({ data: { disposition: "started" } });
    void turn(m.message);
    return;
  }
  if (m.type === "steer") {
    if (running === null) return say({ id: m.id, type: "response", command: "steer", success: false, error: "Agent is not running" });
    running.steers.push(m.message);
    say({ type: "queue_update", steering: [...running.steers], followUp: [] });
    respond({ data: { disposition: "queued" } });
    running.wake?.();
    return;
  }
  if (m.type === "abort") {
    if (running !== null) {
      running.aborted = true;
      running.wake?.();
    }
    return respond();
  }
  if (m.type === "extension_ui_response") return;
  say({ id: m.id, type: "response", command: m.type, success: false, error: `Unknown command: ${m.type}` });
});
lines.on("close", () => process.exit(0));
