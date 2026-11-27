// The Rust core's changelog.rs tests, ported.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { Changelog, item } from "../src/changelog.ts";
import { holdLanguage } from "../src/i18n.ts";
import { setup } from "./views-rig.ts";

holdLanguage();
const entry = (version: number, parts: string[]) => ({ version, commit: "c", at: 1_790_000_000, text: ["修复：一件事"], fixes: [], parts });

test("a_change_says_whether_this_app_has_it", () => {
  const released = { android: 1340, web: 1330, station: null, desktop: null };
  const had = item(entry(1320, ["android"]), "android", 1323, released);
  assert.deepEqual([had.has, had.note], [true, ""]);
  const update = item(entry(1335, ["android", "web"]), "android", 1323, released);
  assert.deepEqual([update.has, update.note], [false, "更新到 0.1.1335 后可用"]);
  assert.equal(item(entry(1345, ["android"]), "android", 1323, released).note, "未发布");
  assert.equal(item(entry(1325, ["web"]), "web", 1323, released).note, "刷新页面后可用");
  // Another part's, in this app's tab and in its own: only what is not out is said.
  const station = item(entry(1320, ["station"]), "android", 1323, released);
  assert.deepEqual([station.has, station.note, station.mine], [null, "", false]);
  assert.deepEqual([item(entry(1320, ["station"]), "android", 1323, released, "station").note, item(entry(1320, ["station", "android"]), "web", 1, released, "android").note], ["未发布", ""]);
  assert.equal(item(entry(1350, ["cloud"]), "web", 1, released).note, "");
  assert.equal(item(entry(1320, ["web"]), "desktop", 1323, released).has, true);
  assert.equal(item({ version: 1, text: [], parts: [] }, "web", null, released), null);
});

test("a_line_has_its_kind_apart", () => {
  const lines = item({ version: 1, text: ["修复：一件事", "新增: 一样东西", "优化：快了", "安卓：别的", "修复："], parts: ["web"] }, "web", 1, {}).lines;
  assert.deepEqual(lines, [
    { kind: "fix", label: "修复", text: "一件事" },
    { kind: "new", label: "新功能", text: "一样东西" },
    { kind: "improve", label: "改进", text: "快了" },
    { label: "", text: "安卓：别的" },
    { label: "", text: "修复：" },
  ]);
});

test("desktop availability follows the device OS as each build is released", () => {
  const { host, store, data } = setup();
  const changelog = new Changelog(host, store, data);
  const entries = [entry(1335, ["desktop"])];
  data.put("changelog", "feed", { entries, released: { desktop: 1329, macos: 1329, windows: 1340 } });
  const note = (userAgent: string) => {
    changelog.device({ app: "desktop", build: "0.1.1300", userAgent });
    return changelog.value().tabs[0].days[0].entries[0].note;
  };
  assert.equal(note("Windows"), "更新到 0.1.1335 后可用");
  assert.equal(note("Macintosh; Mac OS X"), "未发布");
  assert.equal(note(""), "未发布");
  data.put("changelog", "feed", { entries, released: { desktop: 1340 } });
  assert.equal(note("Macintosh; Mac OS X"), "更新到 0.1.1335 后可用");
});

test("a changelog read again with the ETag it was read with is not sent, parsed nor written again while unchanged", async () => {
  const { host, store, data } = setup();
  const changelog = new Changelog(host, store, data);
  const feed = (version: number) => ({ entries: [entry(version, ["web"])], released: { web: version } });
  const said: { status: number; etag?: string; body?: unknown }[] = [];
  host.onFetch(() => {
    const { status, etag, body } = said.shift()!;
    return { status, headers: etag ? [["ETag", etag]] : [], body: new TextEncoder().encode(body === undefined ? "" : JSON.stringify(body)) };
  });
  let changed = 0;
  const invalidateAll = store.invalidateAll.bind(store);
  store.invalidateAll = (pick) => {
    changed++;
    invalidateAll(pick);
  };
  const puts: string[] = [];
  const put = data.put.bind(data);
  data.put = (table, key, value, confirmed) => {
    puts.push(`${table}.${key}`);
    put(table, key, value, confirmed);
  };
  const read = async () => {
    const before = host.requests.length;
    await Effect.runPromise(changelog.read());
    return host.requests.slice(before).map((r) => r.headers.find(([k]) => k === "if-none-match")?.[1] ?? null);
  };

  said.push({ status: 200, etag: ' "a" ', body: feed(1) });
  assert.deepEqual(await read(), [null]);
  assert.deepEqual([data.record("changelog", "etag"), changed, puts], [{ etag: '"a"', origin: host.cloudOrigin(), channel: "" }, 1, ["changelog.feed", "changelog.etag"]]);
  const kept = data.record("changelog", "feed");

  // Unchanged: a 304, the feed kept as it was, nothing written nor told.
  said.push({ status: 304, etag: '"a"' });
  assert.deepEqual(await read(), ['"a"']);
  assert.deepEqual([data.record("changelog", "feed"), changed, puts.length], [kept, 1, 2]);

  // Failed once, a 304 after says it is read again.
  said.push({ status: 503 });
  await read();
  assert.equal(changed, 2);
  said.push({ status: 304, etag: '"a"' });
  assert.deepEqual(await read(), ['"a"']);
  assert.deepEqual([changed, puts.length], [3, 2]);

  // Changed: the new feed and its ETag; one without an ETag forgets the old.
  said.push({ status: 200, etag: '"b"', body: feed(2) });
  await read();
  assert.deepEqual([(data.record("changelog", "feed") as any).entries[0].version, (data.record("changelog", "etag") as any).etag], [2, '"b"']);
  said.push({ status: 200, body: feed(3) });
  assert.deepEqual(await read(), ['"b"']);
  assert.deepEqual([(data.record("changelog", "feed") as any).entries[0].version, data.record("changelog", "etag")], [3, undefined]);
  said.push({ status: 200, etag: '"c"', body: feed(4) });
  assert.deepEqual(await read(), [null]);

  // Another channel or another origin asks for it whole.
  host.isBeta = true;
  said.push({ status: 200, etag: '"d"', body: feed(5) });
  assert.deepEqual(await read(), [null]);
  assert.deepEqual(data.record("changelog", "etag"), { etag: '"d"', origin: host.cloudOrigin(), channel: "beta" });
  const origin = host.origin;
  host.origin = "https://elsewhere.example";
  said.push({ status: 200, etag: '"e"', body: feed(6) });
  assert.deepEqual(await read(), [null]);
  said.push({ status: 304 });
  assert.deepEqual(await read(), ['"e"']);

  // No feed kept: its ETag is not said, and a 304 for it forgets the ETag and fails.
  data.forgetRecord("changelog", "feed");
  said.push({ status: 304 });
  assert.deepEqual(await read(), [null]);
  assert.equal(data.record("changelog", "etag"), undefined);
  assert.equal(typeof changelog.value().error, "string");
  host.origin = origin;
});
