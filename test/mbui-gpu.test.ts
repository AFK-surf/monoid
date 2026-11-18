import assert from "node:assert/strict";
import test from "node:test";
import { browserOf, chineseFor, guideFor, hasWebgl2 } from "../web/src/mbui/gpu.ts";

/** A canvas as the probe sees one: what it was asked, and whether its context was let go. */
function canvas(gives: boolean) {
  const asked: string[] = [];
  let lost = 0;
  const c = {
    asked,
    lost: () => lost,
    getContext(kind: "webgl2") {
      asked.push(kind);
      return gives ? { getExtension: (name: string) => (name === "WEBGL_lose_context" ? { loseContext: () => { lost++; } } : null) } : null;
    },
  };
  return c;
}

test("the probe asks a canvas of its own, never the app's, and lets its context go", () => {
  const app = canvas(true);
  const made: ReturnType<typeof canvas>[] = [];
  const ok = hasWebgl2(() => {
    const c = canvas(true);
    made.push(c);
    return c;
  });
  assert.equal(ok, true);
  assert.equal(made.length, 1);
  assert.deepEqual(made[0]!.asked, ["webgl2"]);
  assert.equal(made[0]!.lost(), 1);
  // the app's canvas is asked nothing: mbui's host asks it first, with its own attributes (host.js setupGL)
  assert.deepEqual(app.asked, []);
});

test("no WebGL 2, or a canvas that throws, is no WebGL 2", () => {
  assert.equal(hasWebgl2(() => canvas(false)), false);
  assert.equal(hasWebgl2(() => { throw new Error("no canvas"); }), false);
});

const UA = {
  chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",
  edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0",
  opera: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 OPR/120.0.0.0",
  firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:145.0) Gecko/20100101 Firefox/145.0",
  safari: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15",
  android: "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36",
  iosChrome: "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/142.0 Mobile/15E148 Safari/604.1",
};

test("each browser is told its own way to turn acceleration on", () => {
  assert.deepEqual(browserOf(UA.chrome), { kind: "chromium", name: "Chrome", scheme: "chrome" });
  assert.deepEqual(browserOf(UA.chrome, true), { kind: "chromium", name: "Brave", scheme: "brave" });
  assert.deepEqual(browserOf(UA.edge), { kind: "chromium", name: "Edge", scheme: "edge" });
  assert.deepEqual(browserOf(UA.opera), { kind: "chromium", name: "Opera", scheme: "opera" });
  assert.deepEqual(browserOf(UA.firefox), { kind: "firefox" });
  assert.deepEqual(browserOf(UA.safari), { kind: "safari" });
  // a phone's Chromium has no settings page for it
  assert.deepEqual(browserOf(UA.android), { kind: "other" });
  assert.deepEqual(browserOf(UA.iosChrome), { kind: "other" });

  for (const zh of [true, false]) {
    assert.equal(guideFor(browserOf(UA.edge), zh).steps[0]!.address, "edge://settings/system");
    assert.equal(guideFor(browserOf(UA.chrome, true), zh).steps[0]!.address, "brave://settings/system");
    assert.equal(guideFor(browserOf(UA.firefox), zh).steps[0]!.address, "about:preferences#general");
    for (const ua of Object.values(UA)) {
      const g = guideFor(browserOf(ua), zh);
      assert.ok(g.steps.length > 0 && g.retry.length > 0, ua);
      // every way ends with what to press here once it is done: never a dead end
      assert.match(JSON.stringify(g.steps.at(-1)), zh ? /重试/ : /Retry/, ua);
      // the words people read never name an app by device (apps/mbui/AGENTS.md, the terms)
      assert.doesNotMatch(JSON.stringify(g), /电脑版|手机版|桌面端|移动端|触屏设备/, ua);
    }
  }
});

test("the page speaks the language the app was set to here, else the browser's", () => {
  assert.equal(chineseFor("en-US", null), false);
  assert.equal(chineseFor("zh-CN", null), true);
  assert.equal(chineseFor("en-US", JSON.stringify({ language: "zh" })), true);
  assert.equal(chineseFor("zh-CN", JSON.stringify({ language: "en" })), false);
  assert.equal(chineseFor("zh-TW", "not json"), true);
  assert.equal(chineseFor("en-GB", JSON.stringify({ language: "system" })), false);
});
