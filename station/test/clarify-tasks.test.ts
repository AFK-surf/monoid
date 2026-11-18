// A 待派发 draft's words turned into subtasks (sessions/clarify-tasks.ts): the model's answer read whatever it wraps it
// in, and the one-off session it is asked in, which makes no chat and has no tools or project.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { test } from "node:test";
import { chooseClarifier, ClarifyError, clarifyPrompt, clarifyTasks, MAX_TASK_CHARS, MAX_TASKS, parseClarifyTasks } from "../src/sessions/clarify-tasks.ts";
import type { Profile } from "../src/sessions/config.ts";
import { Rig, settle } from "./hub-fakes.ts";

const refused = (problem: string) => (e: unknown) => e instanceof ClarifyError && e.problem === problem;

test("a plain JSON array is read as it is", () => {
  assert.deepEqual(parseClarifyTasks(`[{"text":"加导出","after":[]},{"text":"加导入"},{"text":"补测试","after":[0,1]}]`), [
    { text: "加导出" },
    { text: "加导入" },
    { text: "补测试", after: [0, 1] },
  ]);
});

test("code fences and prose around the array are put aside", () => {
  const raw = "Here are the subtasks:\n```json\n[{\"text\": \"Add export\"}, {\"text\": \"Test it\", \"after\": [0]}]\n```\nHope this helps [really].";
  assert.deepEqual(parseClarifyTasks(raw), [{ text: "Add export" }, { text: "Test it", after: [0] }]);
});

test("an object with tasks is read too, and bare strings count as items", () => {
  assert.deepEqual(parseClarifyTasks(`{"tasks": ["one", {"text": "two", "after": [0]}]}`), [{ text: "one" }, { text: "two", after: [0] }]);
});

test("a bracket in prose before the array does not hide it", () => {
  assert.deepEqual(parseClarifyTasks(`Note [a] then {broken: } and [{"text":"x"}]`), [{ text: "x" }]);
});

test("after keeps only earlier items: not itself, not later ones, no fractions or strings, each once", () => {
  const raw = JSON.stringify([
    { text: "a", after: [0, 1] },
    { text: "b", after: [1, 2, -1, 0.5, "0", 0, 0] },
    { text: "c", after: [2, 1, 0, 9] },
  ]);
  assert.deepEqual(parseClarifyTasks(raw), [{ text: "a" }, { text: "b", after: [0] }, { text: "c", after: [0, 1] }]);
});

test("a cycle cannot be made: forward references are dropped", () => {
  const raw = JSON.stringify([{ text: "a", after: [1] }, { text: "b", after: [0] }]);
  assert.deepEqual(parseClarifyTasks(raw), [{ text: "a" }, { text: "b", after: [0] }]);
});

test("dropped items are left out of after, and the rest re-indexed", () => {
  const raw = JSON.stringify([{ text: "a" }, { text: "  " }, { nope: 1 }, { text: "a" }, { text: "d", after: [0, 1, 2, 3] }, { text: "e", after: [4, 0] }]);
  assert.deepEqual(parseClarifyTasks(raw), [{ text: "a" }, { text: "d", after: [0] }, { text: "e", after: [0, 1] }]);
});

test("texts are trimmed, their spaces made one, and capped", () => {
  const long = "x".repeat(MAX_TASK_CHARS + 50);
  const [one, two] = parseClarifyTasks(JSON.stringify([{ text: "  加\n 导出  " }, { text: long }]));
  assert.equal(one!.text, "加 导出");
  assert.equal([...two!.text].length, MAX_TASK_CHARS);
});

test("at most six are kept", () => {
  const raw = JSON.stringify(Array.from({ length: 9 }, (_, i) => ({ text: `t${i}`, after: i > 0 ? [i - 1] : [] })));
  const tasks = parseClarifyTasks(raw);
  assert.equal(tasks.length, MAX_TASKS);
  assert.deepEqual(tasks.at(-1), { text: "t5", after: [4] });
});

test("an answer with no task in it is refused", () => {
  assert.throws(() => parseClarifyTasks("[]"), refused("empty"));
  assert.throws(() => parseClarifyTasks(`[{"text": ""}, {"x": 1}]`), refused("empty"));
  assert.throws(() => parseClarifyTasks("I can't help with that."), refused("failed"));
  assert.throws(() => parseClarifyTasks(""), refused("failed"));
});

test("the prompt asks for JSON only, in the task's language, one item for a single task", () => {
  const { instructions, input } = clarifyPrompt("修登录页");
  assert.match(instructions, /only a JSON array/);
  assert.match(instructions, /language the task is written in/);
  assert.match(instructions, /exactly one item/);
  assert.deepEqual(JSON.parse(input), { task: "修登录页" });
});

const profile = (id: string, runtimes: string[], access?: Record<string, unknown>): Profile =>
  ({ id, runtime: runtimes[0], runtimes, home: `/h/${id}`, name: id, models: [], named: [], backgroundOnMessage: true, ...(access ? { access } : {}) }) as unknown as Profile;

test("a Claude Code account is chosen first, on its small model; else Codex at low effort; else none", () => {
  assert.deepEqual(chooseClarifier([profile("cx", ["codex"]), profile("cc", ["claude"])]), { profile: profile("cc", ["claude"]), runtime: "claude", model: "haiku", effort: undefined });
  assert.equal(chooseClarifier([profile("go", ["claude"], { kind: "opencode-go" })])?.model, "claude-haiku-5-5");
  assert.equal(chooseClarifier([profile("kimi", ["claude"], { kind: "api-provider", provider: "kimi" })])?.model, undefined);
  assert.deepEqual(chooseClarifier([profile("cx", ["codex"])]), { profile: profile("cx", ["codex"]), runtime: "codex", model: undefined, effort: "low" });
  assert.equal(chooseClarifier([profile("dsh", ["dsh"])]), null);
});

test("a draft is clarified in a text-only session of its own that makes no chat and is let go after", async () => {
  const r = new Rig();
  try {
    const sessions = r.claude.count();
    const result = clarifyTasks(r.hub, null, "给设置页加导出对话记录，同时把导入也做了，顺便补测试");
    await settle();
    assert.equal(r.claude.count(), sessions + 1);
    const helper = r.claude.last();
    assert.equal(helper.options.textOnly, true);
    assert.equal(helper.options.mcpToken, "");
    assert.equal(helper.options.mcpUrl, "");
    assert.equal(helper.options.model, "haiku");
    assert.match(helper.options.cwd, /stillfail-clarify-/);
    assert.ok(existsSync(helper.options.cwd));
    assert.deepEqual(JSON.parse(helper.prompts[0]!), { task: "给设置页加导出对话记录，同时把导入也做了，顺便补测试" });
    helper.says('```json\n[{"text":"给设置页加导出对话记录"},{"text":"给设置页加导入对话记录"},{"text":"为导出和导入补测试","after":[0,1]}]\n```');
    helper.complete();
    assert.deepEqual(await result, [
      { text: "给设置页加导出对话记录" },
      { text: "给设置页加导入对话记录" },
      { text: "为导出和导入补测试", after: [0, 1] },
    ]);
    await settle();
    assert.equal(helper.disposed, true);
    assert.equal(existsSync(helper.options.cwd), false);
    // no chat and no session row was made for it
    assert.equal(r.store.getThread(1), null);
    assert.equal(r.store.getSession(helper.options.key), null);
    assert.equal(r.codex.count(), 0);
  } finally { await r.close(); }
});

test("a session that uses a tool, or says nothing to read, fails in words", async () => {
  const r = new Rig();
  try {
    const tooled = clarifyTasks(r.hub, null, "do a thing");
    await settle();
    const a = r.claude.last();
    a.events({ type: "live", event: { kind: "start", id: "t1", step: "tool" } } as never);
    a.says(`[{"text":"x"}]`);
    a.complete();
    await assert.rejects(tooled, refused("failed"));
    const empty = clarifyTasks(r.hub, null, "do a thing");
    await settle();
    const b = r.claude.last();
    b.says("[]");
    b.complete();
    await assert.rejects(empty, refused("empty"));
    await assert.rejects(clarifyTasks(r.hub, null, "   "), refused("empty"));
  } finally { await r.close(); }
});
