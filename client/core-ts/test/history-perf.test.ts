// A history kept between makings (history.ts `presentHistory`) is the one made afresh (`presentHistoryUncached`),
// step by step as a long transcript streams in, and makes again only what changed.
import assert from "node:assert/strict";
import { test } from "node:test";
import { historyMade, presentHistory, presentHistoryUncached, type Context } from "../src/history.ts";
import { holdLanguage, setCurrent } from "../src/i18n.ts";
import { markdown, mdKey, olderMdKeys, refreshMarkdown, type MdStore } from "../src/markdown.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

/// A deterministic run of numbers (mulberry32).
function rand(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let x = a;
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

function freeze<T>(v: T): T {
  if (v !== null && typeof v === "object" && !Object.isFrozen(v)) {
    Object.freeze(v);
    for (const k of Object.keys(v)) freeze((v as J)[k]);
  }
  return v;
}

const T0 = Date.UTC(2026, 10, 17, 9, 0, 0);
const filler = (n: number, word: string) => Array.from({ length: n }, (_, i) => `${word} ${i} lorem ipsum dolor sit amet`).join("\n");

/// The entries of one turn of an agent's work, much as a real transcript has them: a prompt (a person, a Slack
/// person, another chat's agent, a station's notice, a task's end), thoughts, calls of every kind with big inputs,
/// results by id (some later, some failed, some cut short), its words, a post and how its turn ends.
function turn(r: number, rnd: () => number, big: boolean): J[] {
  const out: J[] = [];
  let k = 0;
  const at = () => new Date(T0 + r * 4 * 3_600_000 + k++ * 6_000).toISOString();
  const id = (n: number) => `c${r}_${n}`;
  const call = (n: number, tool: string, input: J, extra: J = {}) => out.push({ kind: "tool_call", tool, callId: id(n), text: typeof input === "string" ? input : JSON.stringify(input), at: at(), ...extra });
  const result = (n: number, text: string, extra: J = {}) => out.push({ kind: "tool_result", callId: id(n), ok: true, text, at: at(), ...extra });
  const prompts = [
    `<message via="web" thread="CHAT/1.0" from="Ada (ada@x)" ts="${r}.1">\n第 ${r} 轮：请看一下 **history** 的问题\n</message>`,
    `<message via="slack" thread="C1/1.000200" from="Bob (U1)" ts="${r}.2">\n<@UBOT> round ${r}\n</message>`,
    `<message via="web" thread="CHAT/1.0" from="Claude Code" bot ts="${r}.3">\n**结论** ${r}：\`moves_in\` 已改\n\n- a\n- b\n</message>`,
    `<message via="station" thread="CHAT/1.0" from="station" ts="${r}.4">\nJob "build ${r}" (j${r}) ended with exit code ${r % 3}.\nIts last lines:\n\`\`\`\nok ${r}\n\`\`\`\n</message>`,
    `<task-notification>\n<task-id>bg${r}</task-id>\n<status>completed</status>\n<summary>Agent "Helper ${r}" finished</summary>\n<result>## Found ${r}\n\nThe answer is **${r}**.</result>\n</task-notification>`,
  ];
  out.push({ kind: "user", text: prompts[r % prompts.length], at: at() });
  out.push({ kind: "thinking", text: r % 4 === 0 ? "Thinking..." : `**Plan** ${r}\n\nLook at the files, then change them.`, at: at() });
  let n = 0;
  const calls = 14 + Math.floor(rnd() * 6);
  for (let c = 0; c < calls; c++, n++) {
    const pick = Math.floor(rnd() * 12);
    if (pick === 0) {
      call(n, "Read", { file_path: `/repo/src/f${c % 3}.ts`, offset: c * 10, limit: 40 });
      result(n, filler(big ? 60 : 4, "line"));
    } else if (pick === 1) {
      call(n, "Grep", { pattern: `needle${c}`, path: "/repo/src" });
      result(n, filler(big ? 30 : 2, "match"));
    } else if (pick === 2) {
      call(n, "Bash", { command: `rg -n "x${c}" src | head`, description: `Search ${c}` });
      result(n, filler(big ? 20 : 2, "hit"));
    } else if (pick === 3) {
      call(n, "Bash", { command: `npm test -- --grep t${c}` });
      result(n, `Created At: ${new Date(T0).toISOString()}\nCompleted At: ${new Date(T0 + 4_000).toISOString()}\nfailed`, { ok: c % 2 === 0 });
    } else if (pick === 4) {
      call(n, "Edit", { file_path: `/repo/src/f${c % 2}.ts`, old_string: filler(big ? 120 : 3, "old"), new_string: filler(big ? 120 : 3, "new") });
      result(n, "ok");
    } else if (pick === 5) {
      call(n, "Write", { file_path: `/repo/src/w${c}.ts`, content: filler(big ? 400 : 5, "content") });
      result(n, "written");
    } else if (pick === 6) {
      call(n, "mcp__stillfail__station_task", { station: "st1aaaaaaaa", action: c % 2 === 0 ? "start" : "get", key: `k${r}` });
      result(n, '{"state":"running"}');
    } else if (pick === 7) {
      call(n, "SendMessage", { to: `worker${r}abc`, message: `go ${c}` });
      result(n, "sent");
    } else if (pick === 8) {
      call(n, "thinking-call", "not json at all");
      out.push({ kind: "thinking", text: `Next: step ${c} of ${r}`, at: at() });
    } else if (pick === 9) {
      call(n, "exec", `for (const f of files) { await tools.read(f) }`, {});
      call(n + 100, "read_file", { Path: `/repo/a${c}.ts` }, { callId: `${id(n)}#1` });
      call(n + 200, "read_file", { Path: `/repo/b${c}.ts` }, { callId: `${id(n)}#2` });
      result(n, "", { inScript: true });
    } else if (pick === 10) {
      call(n, "mcp__stillfail__job_start", { command: `sleep ${c}`, name: `job ${c}` });
      result(n, "started");
    } else {
      call(n, "WebSearch", { query: `how to ${c}` });
      result(n, filler(big ? 10 : 1, "web"));
    }
  }
  // A call whose result comes in the next turn.
  call(999, "Bash", { command: `sleep 100 # turn ${r}` });
  const said = `第 ${r} 轮完成：**改好了**\n\n| a | b |\n|---|---|\n| ${r} | x |`;
  out.push({ kind: "assistant", text: said, at: at() });
  call(n++, "mcp__stillfail__chat_post", { to: "CHAT/1.0", text: said, ...(r % 3 === 0 ? { kind: "all_done", done: "ok" } : {}) });
  result(n - 1, "Posted");
  if (r % 3 === 1) call(n++, "mcp__stillfail__chat_state", { kind: "waiting", for: `build ${r}`, seconds: 600 });
  else if (r % 3 === 2) call(n++, "mcp__stillfail__chat_state", { kind: "need_human", need: `决定 ${r}` });
  if (r > 0) out.push({ kind: "tool_result", callId: `c${r - 1}_999`, ok: true, text: "slept", at: at() });
  return out;
}

function transcript(turns: number, seed: number, big: boolean): J[] {
  const rnd = rand(seed);
  const all: J[] = [];
  for (let r = 0; r < turns; r++) all.push(...turn(r, rnd, big).map(freeze));
  return all;
}

/// A device's kept trees of Markdown (data.ts's, in memory): some texts kept only in an older reading, read again in
/// the background (`refresh`) as the app does.
function store(): MdStore & { asked: string[] } {
  const kept = new Map<string, string>();
  const asked: string[] = [];
  return {
    asked,
    has: (key) => kept.has(key),
    get: (key) => kept.get(key) ?? null,
    put: (key, json, replaces) => {
      if (replaces !== undefined) kept.delete(replaces);
      kept.set(key, json);
    },
    refresh: (text) => asked.push(text),
    // An older reading of `text` kept (its tree another's, so that a stale one shows).
    ...{ older: (text: string, tree: unknown) => kept.set(olderMdKeys(mdKey(text))[0], JSON.stringify(tree)) },
  } as MdStore & { asked: string[] };
}

const cx = (over: Partial<Context> = {}): Context => ({
  threads: [{ surface: "slack:T1", channel: "C1", threadTs: "1.000200", channelName: "ops", sessions: [{ session: "s1" }] }],
  members: [{ id: "ada@x", name: "Ada" }],
  slackUsers: ["U9"],
  botUserId: "UBOT",
  botName: "ds-ember",
  slackNames: [["U1", "Bob"]],
  runtime: "claude",
  started: true,
  offsetMin: 480,
  workspaces: new Map([["T1", { name: "Acme", url: "https://acme.slack.com/" }]]),
  now: T0 + 3_600_000,
  stations: new Map([["st1aaaaaaaa", "Host-1"]]),
  ...over,
});

const steps = (k: number) => [{ id: `s${k}`, step: k % 2 === 0 ? "thinking" : "text" }, { id: `t${k}`, step: "tool", tool: "Bash" }];

test("a_kept_history_is_the_one_made_afresh_at_every_step_of_a_stream", () => {
  const all = transcript(30, 7, false);
  assert.ok(all.length >= 500, `${all.length} entries`);
  const rnd = rand(11);
  let shown = 440;
  let first = 0;
  let threads = cx().threads;
  let stations = cx().stations!;
  let now = T0 + 3_600_000;
  const md = store();
  const later: string[] = [];
  let usage = { modelCalls: 1, inputTokens: 100, cachedTokens: 50, outputTokens: 10 };
  const kinds = new Map<string, number>();
  for (let k = 0; k < 100; k++) {
    const what = k < 3 ? "same" : ["steps", "steps", "steps", "append", "append", "md", "page", "context", "names", "day"][Math.floor(rnd() * 10)];
    kinds.set(what, (kinds.get(what) ?? 0) + 1);
    if (what === "append") shown = Math.min(all.length, shown + 1 + Math.floor(rnd() * 2));
    if (what === "steps") usage = { ...usage, modelCalls: usage.modelCalls + 1, outputTokens: usage.outputTokens + 7 };
    if (what === "page") first = first === 0 ? 37 : 0;
    if (what === "context") threads = [{ ...threads[0], channelName: `ops${k}` }];
    if (what === "names") stations = new Map([["st1aaaaaaaa", `Host-${k}`]]);
    if (what === "day") now += 24 * 3_600_000;
    if (what === "md") {
      // A text's tree read in the background replaces the older one shown.
      const text = later.shift();
      if (text !== undefined) refreshMarkdown(text, md, olderMdKeys(mdKey(text))[0]);
      else {
        const fresh = `**新的** ${k} ${"段落 ".repeat(k)}`;
        (md as J).older(fresh, markdown(`older ${k}`));
        later.push(fresh);
        shown = Math.min(all.length, shown + 1);
        all.splice(shown - 1, 0, freeze({ kind: "assistant", text: fresh, at: new Date(T0 + k).toISOString() }));
      }
    }
    const live = {
      loaded: true,
      first,
      timeline: all.slice(first, shown),
      steps: steps(k),
      phase: { phase: k % 2 === 0 ? "thinking" : "responding", since: k },
      rate: k,
      usage,
    };
    const c = cx({ threads, stations, now, md });
    const kept = presentHistory(live, c);
    const afresh = presentHistoryUncached(live, c);
    assert.deepStrictEqual(kept, afresh, `step ${k} (${what})`);
  }
  for (const w of ["steps", "append", "md", "page", "context", "names", "day"]) assert.ok((kinds.get(w) ?? 0) > 0, `${w} happened`);
});

test("names_found_later_and_results_come_later_change_the_items_that_read_them", () => {
  const head: J[] = freeze([
    { kind: "user", text: "go", at: new Date(T0).toISOString() },
    { kind: "tool_call", tool: "SendMessage", callId: "m1", text: JSON.stringify({ to: "worker7abc", message: "hi" }) },
    { kind: "tool_result", callId: "m1", text: "sent" },
    { kind: "tool_call", tool: "mcp__stillfail__station_task", callId: "s1", text: JSON.stringify({ station: "st1aaaaaaaa", action: "start", key: "kk" }) },
    { kind: "tool_call", tool: "exec", callId: "x1", text: "await tools.read('a')" },
    { kind: "assistant", text: "完成了" },
    { kind: "tool_call", tool: "mcp__stillfail__chat_state", callId: "w1", text: JSON.stringify({ kind: "waiting", for: "ci" }), at: new Date(T0 + 1000).toISOString() },
  ]);
  const tail: J[] = freeze([
    // The task's result, its name prepared, the agent's name, an inner call of the script, the post the words go with,
    // and what ends the wait: each changes an item before it.
    { kind: "tool_result", callId: "s1", text: "{}" },
    { kind: "tool_call", tool: "mcp__stillfail__station_task", callId: "s2", text: JSON.stringify({ station: "st1aaaaaaaa", action: "prepare", key: "kk", name: "Run the suite" }) },
    { kind: "tool_call", tool: "Agent", callId: "a1", text: JSON.stringify({ description: "Worker seven", prompt: "x" }) },
    { kind: "tool_result", callId: "a1", text: "agentId: worker7abc" },
    { kind: "tool_call", tool: "read_file", callId: "x1#1", text: JSON.stringify({ Path: "/a" }) },
    { kind: "tool_call", tool: "mcp__stillfail__chat_post", callId: "p1", text: JSON.stringify({ to: "CHAT/1.0", text: "完成了" }) },
    { kind: "user", text: "back", at: new Date(T0 + 61_000).toISOString() },
    { kind: "tool_call", tool: "mcp__stillfail__chat_post", callId: "m1", text: JSON.stringify({ to: "CHAT/1.0", text: "steals m1's result" }) },
  ]);
  const c = cx();
  for (let n = 0; n <= tail.length; n++) {
    const live = { loaded: true, timeline: head.concat(tail.slice(0, n)) };
    assert.deepStrictEqual(presentHistory(live, c), presentHistoryUncached(live, c), `with ${n} more`);
  }
});

test("a_stream_makes_again_only_what_changed", () => {
  const all = transcript(24, 3, true);
  const c = cx();
  const at = 500;
  let live: J = { loaded: true, timeline: all.slice(0, at), steps: steps(0), usage: { modelCalls: 1 } };
  const before = presentHistory(live, c);
  // Its steps in flight, its phase and its usage: the items are those shown, nothing made.
  let made = historyMade.items;
  for (let k = 1; k <= 30; k++) {
    live = { ...live, steps: steps(k), phase: { phase: "thinking", since: k }, usage: { modelCalls: k } };
    const h = presentHistory(live, c);
    assert.equal(h.items, before.items);
  }
  assert.equal(historyMade.items - made, 0);
  // An entry more: the item it joins is made again, and the others are the objects they were.
  made = historyMade.items;
  const grown = presentHistory({ ...live, timeline: all.slice(0, at + 1) }, c);
  assert.ok(historyMade.items - made <= 2, `${historyMade.items - made} made`);
  const same = grown.items.filter((it: J, i: number) => it === before.items[i]).length;
  assert.ok(same >= before.items.length - 2, `${same} of ${before.items.length} the same`);
  // In another language, every item is said again.
  setCurrent("en");
  try {
    const en = presentHistory({ ...live, timeline: all.slice(0, at + 1) }, c);
    assert.deepStrictEqual(en, presentHistoryUncached({ ...live, timeline: all.slice(0, at + 1) }, c));
    assert.notDeepStrictEqual(en.items, grown.items);
  } finally {
    holdLanguage();
  }
});

/// What a history of 600 entries with big inputs costs to make, kept and afresh (printed, not held: history.test.ts
/// holds what is made, not how long it takes).
test("what_a_long_history_costs_to_make", (t) => {
  const all = transcript(24, 5, true);
  const at = 600 - 60;
  const c = cx();
  const ms = (f: () => void) => {
    const t0 = performance.now();
    f();
    return Math.round(performance.now() - t0);
  };
  const run = (make: (live: J, cx: Context) => J) => {
    let live: J = { loaded: true, timeline: all.slice(0, at), steps: steps(0) };
    make(live, c);
    const streaming = ms(() => {
      for (let k = 1; k <= 30; k++) {
        live = { ...live, steps: steps(k), phase: { phase: "thinking", since: k }, usage: { modelCalls: k } };
        make(live, c);
      }
    });
    let end = at;
    const growing = ms(() => {
      for (let k = 0; k < 30; k++) {
        end = Math.min(all.length, end + 2);
        make({ ...live, timeline: all.slice(0, end) }, c);
      }
    });
    return { streaming, growing };
  };
  const afresh = run(presentHistoryUncached);
  const kept = run(presentHistory);
  t.diagnostic(`${all.slice(0, at).length} entries, ${Math.round(JSON.stringify(all).length / 1024)} KB; 30 refreshes of steps: ${afresh.streaming} ms afresh, ${kept.streaming} ms kept; 30 entries grown by two: ${afresh.growing} ms afresh, ${kept.growing} ms kept`);
});
