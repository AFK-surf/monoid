// Gate #1: Real `apps/mbui/e2e/traces/` core end-to-end 0-diff replay through
// the compiled native Pion `core_runtime` (`core_api.h` + real Rust `libstillfail_shell` SQLite WAL +
// real loopback HTTP/SSE station + real keyed deltas).
//
// Replays the 3 core traces:
// 1. `agent-reply.trace`   — chat.send -> optimistic outbox -> SSE echo + agent reply -> chat/chats 0-diff
// 2. `answer-option.trace` — interactive options card -> decision.answer (`quotes: [{ ts }]`) -> chat.read -> 0-diff
// 3. `draft-restart.trace` — chat.draft persisted to SQLite -> full core_runtime restart -> compact chat + draft 0-diff

import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import * as collectionsTs from "../../../client/core-ts/src/collections.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../../..");
const pioncBin = process.env.PIONC || path.join(os.homedir(), ".pion/bin/pionc");
const pionRtDir = process.env.PION_RT_DIR || path.join(os.homedir(), ".pion/share/pion/runtime");

function loadTraceBaselines(traceFile) {
  const fullPath = path.join(repoRoot, "apps/mbui/e2e/traces", traceFile);
  const lines = fs.readFileSync(fullPath, "utf8").trim().split("\n");
  const subs = new Map();
  const state = new Map();
  const history = {};
  const calls = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    const obj = JSON.parse(line);
    if (obj.out?.subscribe) subs.set(obj.out.id, obj.out.subscribe);
    if (obj.out?.call) calls.push(obj.out);
    if (obj.in) {
      const sub = subs.get(obj.in.id);
      if (!sub) continue;
      if (obj.in.value !== undefined) {
        state.set(obj.in.id, obj.in.value);
        (history[sub.topic] ||= []).push(structuredClone(obj.in.value));
      } else if (obj.in.delta !== undefined && state.has(obj.in.id)) {
        const next = collectionsTs.applyKeyed(structuredClone(state.get(obj.in.id)), obj.in.delta);
        state.set(obj.in.id, next);
        (history[sub.topic] ||= []).push(structuredClone(next));
      }
    }
  }
  return { history, calls };
}

function findShellLib() {
  const candidates = [
    { lib: path.join(repoRoot, "client/target/debug/libstillfail_shell.so"), libsFile: null },
    { lib: path.join(repoRoot, "client/target/debug/libstillfail_shell.dylib"), libsFile: null },
    {
      lib: path.join(repoRoot, "apps/mbui/out/core/aarch64-apple-darwin/libstillfail_shell.a"),
      libsFile: path.join(repoRoot, "apps/mbui/out/core/shell-aarch64-apple-darwin.libs"),
    },
    {
      lib: path.join(repoRoot, "apps/mbui/out/core/x86_64-unknown-linux-gnu/libstillfail_shell.a"),
      libsFile: path.join(repoRoot, "apps/mbui/out/core/shell-x86_64-unknown-linux-gnu.libs"),
    },
  ];
  for (const c of candidates) {
    if (fs.existsSync(c.lib)) return c;
  }
  // Fallback to prebuilt native cache via `scripts/native.ts`
  try {
    const kind = process.platform === "darwin" ? "shell-apple" : "shell";
    const arch = process.arch === "arm64" ? "arm64" : "x64";
    const target = `${process.platform === "darwin" ? "darwin" : "linux"}-${arch}`;
    const dir = execFileSync(process.execPath, ["scripts/native.ts", "path", kind, target], {
      cwd: repoRoot,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
    const libName = process.platform === "darwin" ? "libstillfail_shell.a" : "libstillfail_shell.so";
    const lib = path.join(dir, libName);
    if (fs.existsSync(lib)) {
      const libsFile = path.join(dir, "libstillfail_shell.libs");
      return { lib, libsFile: fs.existsSync(libsFile) ? libsFile : null };
    }
  } catch {}
  throw new Error(
    "libstillfail_shell not found; run `sh apps/mbui/scripts/pion-core.sh build darwin-arm64` first",
  );
}

let buildDir = null;
let driverBin = null;
let shellLibDir = null;

before(() => {
  buildDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-sfreplay-core-"));
  const { lib: shellLib, libsFile: extraLibsFile } = findShellLib();
  shellLibDir = path.dirname(shellLib);
  let extraLibs = [];
  if (shellLib.endsWith(".a") && process.platform === "darwin") {
    if (extraLibsFile && fs.existsSync(extraLibsFile)) {
      extraLibs = fs.readFileSync(extraLibsFile, "utf8").trim().split(/\s+/).filter(Boolean);
    } else {
      extraLibs = ["-framework", "Security", "-framework", "CoreFoundation", "-framework", "SystemConfiguration", "-liconv", "-lresolv"];
    }
  }

  const staticLib = path.join(buildDir, "libpion_core_runtime.a");
  execFileSync(pioncBin, ["build", "--no-main", "--emit-staticlib", staticLib, "pion/client-core/packages/core_runtime"], {
    cwd: repoRoot,
    stdio: "pipe",
  });

  const compileC = (src, out, flags = []) => {
    execFileSync("cc", ["-O2", ...flags, "-c", src, "-o", out], { cwd: repoRoot, stdio: "pipe" });
  };
  const pionRtO = path.join(buildDir, "pion_rt.o");
  const shellO = path.join(buildDir, "shell_pion.o");
  const coreO = path.join(buildDir, "core_pion.o");
  const bridgeO = path.join(buildDir, "core_runtime_bridge.o");
  const stdioO = path.join(buildDir, "core_runtime_stdio.o");

  compileC(path.join(pionRtDir, "pion_rt.c"), pionRtO, [`-I${pionRtDir}`]);
  compileC(path.join(repoRoot, "pion/base/packages/shell/native/shell_pion.c"), shellO, ["-Wall", "-Wextra", "-Werror"]);
  compileC(path.join(repoRoot, "pion/client-core/packages/core_abi/native/core_pion.c"), coreO, [
    "-Wall", "-Wextra", "-Werror", `-I${path.join(repoRoot, "apps/mbui/src/host")}`, `-I${pionRtDir}`,
  ]);
  compileC(path.join(repoRoot, "pion/client-core/packages/core_runtime/native/core_runtime_bridge.c"), bridgeO, [
    "-Wall", "-Wextra", "-Werror", `-I${path.join(repoRoot, "apps/mbui/src/host")}`,
  ]);
  compileC(path.join(repoRoot, "pion/client-core/packages/core_runtime/native/core_runtime_stdio.c"), stdioO, [
    "-Wall", "-Wextra", "-Werror", `-I${path.join(repoRoot, "apps/mbui/src/host")}`,
  ]);

  driverBin = path.join(buildDir, "core_runtime_stdio");
  execFileSync(
    "cc",
    ["-O2", stdioO, bridgeO, coreO, shellO, staticLib, pionRtO, shellLib, ...extraLibs, "-lpthread", "-lm", "-ldl", "-o", driverBin],
    { cwd: repoRoot, stdio: "pipe" },
  );
  assert.ok(fs.existsSync(driverBin), "core_runtime_stdio binary was not created");
});

after(() => {
  if (buildDir && fs.existsSync(buildDir)) {
    fs.rmSync(buildDir, { recursive: true, force: true });
  }
});

class CoreRuntimeDriver {
  constructor(dataDir, origin) {
    // Seed a signed-in TS StoredAccount so Slice 2B-1 account-owned DB lifecycle opens an authenticated account DB.
    const accountsPath = path.join(dataDir, "accounts");
    if (!fs.existsSync(accountsPath)) {
      fs.writeFileSync(
        accountsPath,
        JSON.stringify([
          {
            sub: "u-trace",
            email: "alice@still.fail",
            name: "Alice",
            picture: "",
            access: "tok-trace",
            refresh: "ref-trace",
            access_expires: 1900000000,
            session: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
          },
        ]),
        "utf8",
      );
    }
    const libDirs = [path.join(repoRoot, "client/target/debug"), ...(shellLibDir ? [shellLibDir] : [])].join(":");
    this.proc = spawn(driverBin, [dataDir, origin], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        DYLD_LIBRARY_PATH: `${libDirs}${process.env.DYLD_LIBRARY_PATH ? `:${process.env.DYLD_LIBRARY_PATH}` : ""}`,
        LD_LIBRARY_PATH: `${libDirs}${process.env.LD_LIBRARY_PATH ? `:${process.env.LD_LIBRARY_PATH}` : ""}`,
      },
    });
    this.buf = "";
    this.messages = [];
    this.waiters = [];
    this.stderr = "";
    this.proc.stderr.on("data", (d) => {
      this.stderr += d.toString("utf8");
    });
    this.proc.stdout.on("data", (chunk) => {
      this.buf += chunk.toString("utf8");
      let nl;
      while ((nl = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, nl).trim();
        this.buf = this.buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        this.messages.push(msg);
        for (let i = this.waiters.length - 1; i >= 0; i--) {
          if (this.waiters[i].pred(msg)) {
            const w = this.waiters.splice(i, 1)[0];
            clearTimeout(w.timer);
            w.resolve(msg);
          }
        }
      }
    });
  }

  send(obj) {
    this.proc.stdin.write(`${JSON.stringify(obj)}\n`);
  }

  waitFor(pred, label = "message", timeoutMs = 5000) {
    const existing = this.messages.find(pred);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.waiters.findIndex((w) => w.timer === timer);
        if (idx >= 0) this.waiters.splice(idx, 1);
        reject(new Error(`Timeout waiting for ${label}. stderr=${this.stderr} msgs=${JSON.stringify(this.messages.slice(-8))}`));
      }, timeoutMs);
      this.waiters.push({ pred, resolve, timer });
    });
  }

  async stop() {
    this.proc.stdin.end();
    await new Promise((resolve) => {
      if (this.proc.exitCode !== null) return resolve();
      this.proc.once("exit", resolve);
      setTimeout(() => {
        try {
          this.proc.kill();
        } catch {}
        resolve();
      }, 2000);
    });
  }
}

function startMockStation(handler) {
  const sseClients = new Set();
  const requests = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const rawBody = Buffer.concat(chunks).toString("utf8");
      const jsonBody = rawBody ? (() => { try { return JSON.parse(rawBody); } catch { return rawBody; } })() : null;
      requests.push({ method: req.method, url: req.url, body: jsonBody });

      if (req.method === "GET" && req.url === "/events") {
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });
        res.write(": connected\n\n");
        sseClients.add(res);
        res.on("close", () => sseClients.delete(res));
        return;
      }
      if (handler(req, res, jsonBody, sseClients)) return;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end("{}");
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      resolve({
        origin: `http://127.0.0.1:${addr.port}`,
        requests,
        pushSse(event, data, id) {
          const payload = `${id ? `id: ${id}\n` : ""}event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
          for (const res of sseClients) res.write(payload);
        },
        close() {
          for (const res of sseClients) res.end();
          return new Promise((r) => server.close(r));
        },
      });
    });
  });
}

function entryFromTraceMsg(msg, station, threadId, extra = {}) {
  return {
    id: msg.seq,
    n: msg.seq,
    thread: threadId,
    kind: "message",
    ts: msg.ts,
    authorKind: msg.authorKind,
    author: msg.author,
    authorName: msg.authorName ?? msg.by?.name ?? msg.author,
    text: msg.text,
    attachments: msg.attachments ?? [],
    quotes: msg.quotes ?? [],
    at: msg.createdAt,
    ...(msg.card ? { card: msg.card } : {}),
    ...(msg.declared ? { declared: msg.declared } : {}),
    ...(msg.ending ? { ending: msg.ending } : {}),
    ...extra,
  };
}

function projectKeyChatSnapshot(chatView) {
  return {
    archived: chatView.archived,
    messages: (chatView.messages || []).map((m) => ({
      seq: m.seq,
      authorKind: m.authorKind,
      text: m.text,
      hasCard: Boolean(m.card),
      ...(m.card?.type === "options"
        ? {
            cardType: m.card.type,
            cardOptions: m.card.options.map((o) => o.label),
          }
        : {}),
    })),
  };
}

test("Gate #1 Trace 1: agent-reply.trace full-pipeline 0-diff replay in Pion core_runtime", async () => {
  const { history, calls } = loadTraceBaselines("agent-reply.trace");
  const traceChatsFinal = history.chats[history.chats.length - 1];
  const traceChatFirst = history.chat[0];
  const traceChatFinal = history.chat[history.chat.length - 1];
  const traceRow = traceChatsFinal.days[0].items[0];
  const traceSendCall = calls.find((c) => c.call === "chat.send");
  assert.ok(traceSendCall, "agent-reply.trace must have chat.send");

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-trace-agent-reply-"));
  const initialMsgs = traceChatFirst.messages; // seq 1, 2
  const sentMsg = traceChatFinal.messages[2]; // seq 3
  const replyMsg = traceChatFinal.messages[3]; // seq 4

  const mock = await startMockStation((req, res, body) => {
    if (req.method === "GET" && req.url === "/chats") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          chats: [
            {
              id: traceRow.id,
              session: traceRow.session,
              thread: traceRow.thread,
              title: traceRow.title,
              lastActiveAt: traceRow.lastActiveAt ?? replyMsg.createdAt,
              unread: false,
              mine: true,
            },
          ],
        }),
      );
      return true;
    }
    if (req.method === "GET" && req.url === "/lock") {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end("{}");
      return true;
    }
    if (req.method === "POST" && req.url === "/threads/1/messages") {
      const ck = body?.clientKey || body?.idem;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, n: 3, clientKey: ck }));
      // Push echoed seq 3 (reconciling outbox) + agent reply seq 4 over live SSE!
      setTimeout(() => {
        mock.pushSse(
          "thread",
          {
            id: 1,
            entries: [
              entryFromTraceMsg(sentMsg, "st-local", 1, { clientKey: ck }),
              entryFromTraceMsg(replyMsg, "st-local", 1),
            ],
          },
          "ev-3-4",
        );
      }, 20);
      return true;
    }
    return false;
  });

  const core = new CoreRuntimeDriver(dataDir, mock.origin);
  try {
    core.send({ id: 1, call: "station.connect", params: { station: "st-local" } });
    await core.waitFor((m) => m.id === 1 && m.ok?.connecting === true, "station.connect");
    await core.waitFor((m) => m.event === "connection" && m.state === "connected", "SSE connected");
    await core.waitFor((m) => m.event === "chats.changed", "initial chats snapshot");

    // Push station overview + initial seq 1 & seq 2 from trace via SSE
    mock.pushSse("overview", { id: "st-local", name: "willow", online: true }, "ev-ov");
    mock.pushSse(
      "thread",
      {
        id: 1,
        entries: [
          entryFromTraceMsg(initialMsgs[0], "st-local", 1),
          entryFromTraceMsg(initialMsgs[1], "st-local", 1),
        ],
      },
      "ev-1-2",
    );
    await core.waitFor((m) => m.event === "entry" && m.n === 2, "initial entries 1..2");

    // Subscribe to `chats` and `chat` (keyed: true)
    core.send({ id: 10, subscribe: { topic: "chats", scope: "" }, keyed: true });
    const chatsInit = await core.waitFor((m) => m.id === 10 && m.value !== undefined, "chats value");
    let pionChats = chatsInit.value;

    core.send({ id: 11, subscribe: { topic: "chat", station: "st-local", thread: 1 }, keyed: true });
    const chatInit = await core.waitFor((m) => m.id === 11 && m.value !== undefined, "chat value");
    let pionChat = chatInit.value;

    // Replay the exact `chat.send` from `agent-reply.trace`
    core.send({
      id: 12,
      call: "chat.send",
      params: {
        station: "st-local",
        thread: 1,
        text: traceSendCall.params.text,
        author: "alice@example.test",
        clientKey: "ck-trace-agent-reply-3",
      },
    });
    await core.waitFor((m) => m.id === 12 && m.ok?.queued === true, "chat.send queued");

    // Wait for agent reply seq 4 SSE event AND live keyed delta on sub 11 (`chat`)
    await core.waitFor((m) => m.event === "entry" && m.n === 4, "agent reply seq 4");
    await core.waitFor(
      (m) => m.id === 11 && Array.isArray(m.delta) && JSON.stringify(m.delta).includes('"seq":4'),
      "chat keyed delta seq 4",
    );

    // Apply all keyed deltas received on sub 11 (`chat`) and re-subscribe fresh to verify exact state
    for (const msg of core.messages) {
      if (msg.id === 11 && msg.delta) {
        pionChat = collectionsTs.applyKeyed(structuredClone(pionChat), msg.delta);
      }
      if (msg.id === 10 && msg.delta) {
        pionChats = collectionsTs.applyKeyed(structuredClone(pionChats), msg.delta);
      }
    }

    // Also verify fresh projection matches delta-reconstructed projection with 0 diffs
    core.send({ id: 13, subscribe: { topic: "chat", station: "st-local", thread: 1 }, keyed: true });
    const chatFresh = await core.waitFor((m) => m.id === 13 && m.value !== undefined, "chat fresh value");

    assert.deepEqual(
      projectKeyChatSnapshot(chatFresh.value),
      projectKeyChatSnapshot(traceChatFinal),
      "agent-reply.trace: Pion core_runtime chat snapshot must have 0 diffs vs trace baseline",
    );
    assert.equal(pionChat.messages.length, traceChatFinal.messages.length, "keyed delta chat message count matches");
    assert.equal(pionChat.messages[3].text, replyMsg.text, "keyed delta delivered exact agent reply text");

    const pionItems = pionChats.days.flatMap((d) => d.items);
    assert.equal(pionItems.length, 1);
    assert.deepEqual(
      { id: pionItems[0].id, thread: pionItems[0].thread, title: pionItems[0].title },
      { id: traceRow.id, thread: traceRow.thread, title: traceRow.title },
      "agent-reply.trace: Pion chats row must have 0 diffs vs trace baseline",
    );
  } finally {
    await core.stop();
    await mock.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Gate #1 Trace 2: answer-option.trace interactive card + decision.answer 0-diff replay in Pion core_runtime", async () => {
  const { history, calls } = loadTraceBaselines("answer-option.trace");
  const traceChatsFinal = history.chats[history.chats.length - 1];
  const traceChatFinal = history.chat[history.chat.length - 1];
  const traceRow = traceChatsFinal.days[0].items[0];
  const traceAnswerCall = calls.find((c) => c.call === "decision.answer");
  assert.ok(traceAnswerCall, "answer-option.trace must have decision.answer");

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-trace-answer-option-"));
  const msgs = traceChatFinal.messages; // seq 1..6 (seq 4 has options card!)

  let capturedAnswerPost = null;
  const mock = await startMockStation((req, res, body) => {
    if (req.method === "GET" && req.url === "/chats") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          chats: [
            {
              id: traceRow.id,
              session: traceRow.session,
              thread: traceRow.thread,
              title: traceRow.title,
              lastActiveAt: msgs[5].createdAt,
              unread: true,
              mine: true,
            },
          ],
        }),
      );
      return true;
    }
    if (req.method === "GET" && req.url === "/lock") {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end("{}");
      return true;
    }
    if (req.method === "POST" && req.url === "/threads/1/messages") {
      capturedAnswerPost = body;
      const ck = body?.clientKey || body?.idem;
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, n: 5, clientKey: ck }));
      setTimeout(() => {
        mock.pushSse(
          "thread",
          {
            id: 1,
            entries: [
              entryFromTraceMsg(msgs[4], "st-local", 1, { clientKey: ck }),
              entryFromTraceMsg(msgs[5], "st-local", 1),
            ],
          },
          "ev-5-6",
        );
      }, 20);
      return true;
    }
    if (req.method === "PUT" && req.url === "/threads/1/read") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return true;
    }
    return false;
  });

  const core = new CoreRuntimeDriver(dataDir, mock.origin);
  try {
    core.send({ id: 1, call: "station.connect", params: { station: "st-local" } });
    await core.waitFor((m) => m.id === 1 && m.ok?.connecting === true, "station.connect");
    await core.waitFor((m) => m.event === "connection" && m.state === "connected", "SSE connected");
    await core.waitFor((m) => m.event === "chats.changed", "initial chats snapshot");

    // Push station overview + seq 1..4 (including the interactive options card at seq 4)
    mock.pushSse("overview", { id: "st-local", name: "willow", online: true }, "ev-ov");
    mock.pushSse(
      "thread",
      {
        id: 1,
        entries: [0, 1, 2, 3].map((i) => entryFromTraceMsg(msgs[i], "st-local", 1)),
      },
      "ev-1-4",
    );
    await core.waitFor((m) => m.event === "entry" && m.n === 4, "card entry seq 4");

    // Verify projected interactive card before answering
    core.send({ id: 20, subscribe: { topic: "chat", station: "st-local", thread: 1 }, keyed: true });
    const chatBefore = await core.waitFor((m) => m.id === 20 && m.value !== undefined, "chat before answer");
    const pionCardMsg = chatBefore.value.messages.find((m) => m.seq === 4);
    assert.ok(pionCardMsg?.card, "seq 4 must project interactive card");
    assert.deepEqual(
      pionCardMsg.card.options.map((o) => o.label),
      msgs[3].card.options.map((o) => o.label),
      "answer-option.trace: card options order (recommended last) must have 0 diffs",
    );

    // Replay `decision.answer` from trace
    core.send({
      id: 21,
      call: "decision.answer",
      params: {
        station: "st-local",
        thread: 1,
        seq: traceAnswerCall.params.seq,
        option: traceAnswerCall.params.option,
      },
    });
    await core.waitFor((m) => m.id === 21 && m.ok?.option === traceAnswerCall.params.option, "decision.answer ok");
    await core.waitFor((m) => m.event === "entry" && m.n === 6, "follow-up entry seq 6");

    // Verify station received `quotes: [{ ts: card.ts }]` and exact option text
    assert.ok(capturedAnswerPost, "decision.answer must POST to /threads/1/messages");
    assert.equal(capturedAnswerPost.text, traceAnswerCall.params.option);
    assert.equal(capturedAnswerPost.quotes?.[0]?.ts, msgs[3].ts, "decision.answer must quote card ts");

    // Mark read to seq 6 matching final trace state
    core.send({ id: 22, call: "chat.read", params: { station: "st-local", thread: 1, seq: 6, unread: 0 } });
    await core.waitFor((m) => m.id === 22 && m.ok?.read === 6, "chat.read ok");

    core.send({ id: 23, subscribe: { topic: "chat", station: "st-local", thread: 1 }, keyed: true });
    const chatAfter = await core.waitFor((m) => m.id === 23 && m.value !== undefined, "chat final value");
    assert.deepEqual(
      projectKeyChatSnapshot(chatAfter.value),
      projectKeyChatSnapshot(traceChatFinal),
      "answer-option.trace: Pion core_runtime final chat snapshot must have 0 diffs vs trace baseline",
    );

    core.send({ id: 24, subscribe: { topic: "chats", scope: "" }, keyed: true });
    const chatsAfter = await core.waitFor((m) => m.id === 24 && m.value !== undefined, "chats final value");
    const row = chatsAfter.value.days.flatMap((d) => d.items)[0];
    assert.deepEqual(
      { id: row.id, thread: row.thread, title: row.title, unread: row.unread },
      { id: traceRow.id, thread: traceRow.thread, title: traceRow.title, unread: traceRow.unread },
      "answer-option.trace: Pion chats row must have 0 diffs vs trace baseline",
    );
  } finally {
    await core.stop();
    await mock.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});

test("Gate #1 Trace 3: draft-restart.trace SQLite draft persistence across restart + compact chat 0-diff replay", async () => {
  const { history, calls } = loadTraceBaselines("draft-restart.trace");
  const traceChatsFinal = history.chats[history.chats.length - 1];
  const traceChatFinal = history.chat[history.chat.length - 1];
  const traceComposerInit = history.composer[0];
  const traceComposerFinal = history.composer[history.composer.length - 1];
  const traceRow = traceChatsFinal.days[0].items[0];
  const clearCall = calls.find((c) => c.call === "composer.text");
  assert.ok(traceComposerInit.text.length > 0, "draft-restart.trace must start with non-empty draft");
  assert.equal(clearCall?.params?.text, "", "draft-restart.trace must clear draft");

  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "pion-trace-draft-restart-"));
  const mock = await startMockStation((req, res) => {
    if (req.method === "GET" && req.url === "/chats") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          chats: [
            {
              id: traceRow.id,
              session: traceRow.session,
              thread: traceRow.thread,
              title: traceRow.title,
              lastActiveAt: traceChatFinal.messages[1].createdAt,
              unread: false,
              mine: true,
            },
          ],
        }),
      );
      return true;
    }
    if (req.method === "GET" && req.url === "/lock") {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end("{}");
      return true;
    }
    return false;
  });

  // Phase 1: ingest chat + entries and persist the trace's exact draft, then stop cleanly.
  const core1 = new CoreRuntimeDriver(dataDir, mock.origin);
  try {
    core1.send({ id: 1, call: "station.connect", params: { station: "st-local" } });
    await core1.waitFor((m) => m.id === 1 && m.ok?.connecting === true, "phase1 station.connect");
    await core1.waitFor((m) => m.event === "connection" && m.state === "connected", "phase1 SSE connected");

    mock.pushSse("overview", { id: "st-local", name: "willow", online: true }, "ev-ov");
    mock.pushSse(
      "thread",
      {
        id: 1,
        entries: [
          entryFromTraceMsg(traceChatFinal.messages[0], "st-local", 1),
          entryFromTraceMsg(traceChatFinal.messages[1], "st-local", 1),
        ],
      },
      "ev-1-2",
    );
    await core1.waitFor((m) => m.event === "entry" && m.n === 2, "phase1 entries 1..2");

    core1.send({
      id: 2,
      call: "chat.draft",
      params: { chat: traceRow.id, text: traceComposerInit.text, updatedAt: 1794100060000 },
    });
    await core1.waitFor((m) => m.id === 2 && m.ok?.saved === true, "phase1 chat.draft saved");
  } finally {
    await core1.stop();
  }

  // Phase 2: full process restart on the SAME SQLite `dataDir`!
  const core2 = new CoreRuntimeDriver(dataDir, "https://app.still.fail");
  try {
    core2.send({ id: 30, call: "chat.draft", params: { chat: traceRow.id } });
    const draftAfterRestart = await core2.waitFor((m) => m.id === 30 && m.ok !== undefined, "phase2 chat.draft get");
    assert.equal(
      draftAfterRestart.ok?.draft?.text ?? "",
      traceComposerInit.text,
      "draft-restart.trace: draft must survive full core_runtime restart with 0 diffs",
    );

    // Subscribe to `chat` with `session` + `compact: true` (exact subscription shape from draft-restart.trace!)
    core2.send({
      id: 31,
      subscribe: { topic: "chat", station: "st-local", session: traceRow.session, compact: true },
      keyed: true,
    });
    const compactChat = await core2.waitFor((m) => m.id === 31 && m.value !== undefined, "phase2 compact chat");
    assert.deepEqual(
      projectKeyChatSnapshot(compactChat.value),
      projectKeyChatSnapshot(traceChatFinal),
      "draft-restart.trace: compact chat snapshot after restart must have 0 diffs vs trace baseline",
    );

    // Clear draft matching trace's `composer.text { text: "" }`
    core2.send({
      id: 32,
      call: "chat.draft",
      params: { chat: traceRow.id, text: clearCall.params.text, updatedAt: 1794100061000 },
    });
    await core2.waitFor((m) => m.id === 32 && (m.ok?.cleared === true || m.ok?.saved === true), "phase2 clear draft");

    core2.send({ id: 33, call: "chat.draft", params: { chat: traceRow.id } });
    const clearedDraft = await core2.waitFor((m) => m.id === 33 && m.ok !== undefined, "phase2 draft cleared get");
    assert.equal(
      clearedDraft.ok?.draft?.text ?? "",
      traceComposerFinal.text,
      "draft-restart.trace: cleared draft must match trace final composer text (0 diffs)",
    );

    core2.send({ id: 34, subscribe: { topic: "chats", scope: "" }, keyed: true });
    const chatsAfterRestart = await core2.waitFor((m) => m.id === 34 && m.value !== undefined, "phase2 chats");
    const row = chatsAfterRestart.value.days.flatMap((d) => d.items)[0];
    assert.deepEqual(
      { id: row.id, thread: row.thread, title: row.title, unread: row.unread },
      { id: traceRow.id, thread: traceRow.thread, title: traceRow.title, unread: traceRow.unread },
      "draft-restart.trace: chats row after restart must have 0 diffs vs trace baseline",
    );
  } finally {
    await core2.stop();
    await mock.close();
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});
