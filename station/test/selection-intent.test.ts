import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { inferSelectionIntent, IntentError, parseIntentAnswer } from "../src/sessions/selection-intent.ts";
import { newMessage } from "../src/store/store.ts";
import { FakeDriver, Rig, settle } from "./hub-fakes.ts";

test("parseIntentAnswer reads plain JSON, fenced JSON, and falls back to plain text", () => {
  assert.deepEqual(
    parseIntentAnswer('{"intent":"解释报错原因","reply":"这是因为端口被占用。"}'),
    { intent: "解释报错原因", reply: "这是因为端口被占用。" },
  );
  assert.deepEqual(
    parseIntentAnswer('```json\n{"intent":"Translate","reply":"Hello world"}\n```'),
    { intent: "Translate", reply: "Hello world" },
  );
  assert.deepEqual(
    parseIntentAnswer("直接回答：重启服务即可。"),
    { intent: "", reply: "直接回答：重启服务即可。" },
  );
  assert.equal(parseIntentAnswer("   "), null);
});

test("inferSelectionIntent uses haiku text-only Claude without disturbing a running chat agent", async () => {
  const r = new Rig();
  try {
    const [key, thread] = await newSession(r.hub, { runtime: "claude", createdBy: "a@x" });
    say(r.hub, thread.id, "a@x", "构建报错 EADDRINUSE 127.0.0.1:8787");
    await settle();
    const task = r.claude.last();
    const turn = r.store.lastTurn(key);
    assert.equal(task.busy(), true);

    const pending = inferSelectionIntent(r.hub, thread.id, [r.session(key)], {
      selection: "EADDRINUSE 127.0.0.1:8787",
      messageTs: "1.1",
      author: "a@x",
      lang: "zh",
    });
    await settle();
    const helper = r.claude.last();
    assert.notEqual(helper, task);
    assert.equal(helper.options.textOnly, true);
    assert.equal(helper.options.model, "haiku");
    assert.equal(helper.options.effort, "low");
    assert.ok(helper.prompts[0]?.includes("EADDRINUSE 127.0.0.1:8787"));

    helper.says('{"intent":"解释端口占用错误","reply":"本地 8787 端口已有进程监听，先排查占用进程或更换端口。"}');
    helper.complete();

    const result = await pending;
    assert.equal(result.intent, "解释端口占用错误");
    assert.equal(result.reply, "本地 8787 端口已有进程监听，先排查占用进程或更换端口。");
    assert.equal(result.model, "haiku");
    assert.equal(helper.disposed, true);
    assert.equal(task.busy(), true);
    assert.equal(task.steers.length, 0);
    assert.deepEqual(r.store.lastTurn(key), turn);
  } finally {
    await r.close();
  }
});

test("inferSelectionIntent prefers a station Claude haiku profile even for a Codex chat", async () => {
  const r = new Rig();
  try {
    const [key, thread] = await newSession(r.hub, { runtime: "codex", createdBy: "a@x" });
    r.store.insertMessage(newMessage(thread.id, "1.1", "agent", "agent", "CAS mismatch on expected_card_seq"));

    const pending = inferSelectionIntent(r.hub, thread.id, [r.session(key)], {
      selection: "expected_card_seq",
      lang: "en",
    });
    await settle();
    const helper = r.claude.last();
    assert.equal(helper.options.textOnly, true);
    assert.equal(helper.options.model, "haiku");
    helper.says('{"intent":"Explain expected_card_seq","reply":"It is the compare-and-swap sequence number guarding concurrent card updates."}');
    helper.complete();

    const result = await pending;
    assert.equal(result.intent, "Explain expected_card_seq");
    assert.equal(result.reply, "It is the compare-and-swap sequence number guarding concurrent card updates.");
    assert.equal(result.model, "haiku");
    assert.equal(helper.disposed, true);
  } finally {
    await r.close();
  }
});

test("inferSelectionIntent uses a keyed chat-completions provider when no Claude profile is available", async () => {
  let seen: any;
  const server = createServer(async (req, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    seen = { path: req.url, body: JSON.parse(Buffer.concat(chunks).toString()) };
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({
      choices: [{ message: { content: '{"intent":"说明概念","reply":"这是轻量模型直接给出的解释。"}' } }],
    }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = (server.address() as { port: number }).port;
    const r = new Rig();
    try {
      r.edit((raw) => {
        for (const p of raw.profiles) p.enabled = false;
        raw.profiles.push({
          id: "local-small",
          runtime: "dsh",
          home: "homes/local-small",
          model: "deepseek-v4-flash",
          access: { kind: "api-provider", provider: "ollama", endpoint: `http://127.0.0.1:${port}/v1` },
        });
      });
      const [key, thread] = await newSession(r.hub, { runtime: "dsh", profile: "local-small", createdBy: "a@x" });
      r.store.insertMessage(newMessage(thread.id, "1.1", "person", "a@x", "测试一下选区推断"));
      const result = await inferSelectionIntent(r.hub, thread.id, [r.session(key)], { selection: "选区推断" });
      assert.equal(result.intent, "说明概念");
      assert.equal(result.reply, "这是轻量模型直接给出的解释。");
      assert.equal(result.model, "deepseek-v4-flash");
      assert.equal(seen.path, "/v1/chat/completions");
      assert.equal(seen.body.model, "deepseek-v4-flash");
      assert.equal(seen.body.tools, undefined);
    } finally {
      await r.close();
    }
  } finally {
    await new Promise<void>((resolve, reject) => server.close((e) => (e ? reject(e) : resolve())));
  }
});

test("inferSelectionIntent falls back to Codex luna when no Claude profile is available", async () => {
  const r = new Rig();
  try {
    r.edit((raw) => {
      for (const p of raw.profiles) {
        if (p.runtime === "claude") p.enabled = false;
        if (p.runtime === "codex") p.models = ["gpt-6", "gpt-6-luna"];
      }
    });
    const [key, thread] = await newSession(r.hub, { runtime: "codex", createdBy: "a@x" });
    r.store.insertMessage(newMessage(thread.id, "1.1", "agent", "agent", "WAL mode enabled"));

    const pending = inferSelectionIntent(r.hub, thread.id, [r.session(key)], {
      selection: "WAL mode",
      lang: "zh",
    });
    await settle();
    const helper = r.codex.last();
    assert.equal(helper.options.textOnly, true);
    assert.equal(helper.options.model, "gpt-6-luna");
    helper.says("SQLite 的预写日志模式，允许读写并发。");
    helper.complete();

    const result = await pending;
    assert.equal(result.reply, "SQLite 的预写日志模式，允许读写并发。");
    assert.equal(result.model, "gpt-6-luna");
    assert.equal(helper.disposed, true);
  } finally {
    await r.close();
  }
});

test("inferSelectionIntent falls back to AGY hydrogen when no Claude or Codex profile is available", async () => {
  const r = new Rig();
  try {
    const agy = new FakeDriver("agy");
    r.hub.drivers.set("agy", agy);
    r.edit((raw) => {
      for (const p of raw.profiles) p.enabled = false;
      raw.profiles.push({
        id: "ag",
        runtime: "agy",
        home: "homes/ag",
        models: ["gemini-4-neon", "gemini-4-hydrogen"],
      });
    });
    const [key, thread] = await newSession(r.hub, { runtime: "agy", profile: "ag", createdBy: "a@x" });
    r.store.insertMessage(newMessage(thread.id, "1.1", "agent", "agent", "BEGIN IMMEDIATE avoids lock upgrade deadlock"));

    const pending = inferSelectionIntent(r.hub, thread.id, [r.session(key)], {
      selection: "BEGIN IMMEDIATE",
      lang: "zh",
    });
    await settle();
    const helper = agy.last();
    assert.equal(helper.options.textOnly, true);
    assert.equal(helper.options.model, "gemini-4-hydrogen");
    helper.says("事务开始时就获取写锁，避免中途升级锁导致死锁。");
    helper.complete();

    const result = await pending;
    assert.equal(result.reply, "事务开始时就获取写锁，避免中途升级锁导致死锁。");
    assert.equal(result.model, "gemini-4-hydrogen");
    assert.equal(helper.disposed, true);
  } finally {
    await r.close();
  }
});

test("inferSelectionIntent rejects empty selection and failed helper turns cleanly", async () => {
  const r = new Rig();
  try {
    const [key, thread] = await newSession(r.hub, { runtime: "claude", createdBy: "a@x" });
    await assert.rejects(
      inferSelectionIntent(r.hub, thread.id, [r.session(key)], { selection: "   " }),
      (e: unknown) => e instanceof IntentError && e.problem === "empty",
    );
    const pending = inferSelectionIntent(r.hub, thread.id, [r.session(key)], { selection: "报错" });
    await settle();
    const helper = r.claude.last();
    helper.end({ kind: "failed", reason: "network", message: "down" });
    await assert.rejects(pending, (e: unknown) => e instanceof IntentError && e.problem === "failed");
    assert.equal(helper.disposed, true);
  } finally {
    await r.close();
  }
});
