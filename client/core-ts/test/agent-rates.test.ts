import assert from "node:assert/strict";
import { test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import { agentRates, RATE_ROWS } from "../src/views/agent-rates.ts";

holdLanguage();

const source = (address: string, online: boolean, supported: boolean, items: unknown[]) => ({
  address, name: address, value: { online, supported, items },
  named: (key: string) => ({ title: key, model: "model", chat: key }),
});

test("the total covers every connected supported station and every active session", () => {
  const live = Array.from({ length: RATE_ROWS + 3 }, (_, i) => ({ key: `a${i}`, rate: i + 1 }));
  const view = agentRates([
    source("one", true, true, live),
    source("two", true, true, [{ key: "b", rate: 9 }, { key: "stopped", rate: 0 }]),
    source("offline", false, true, [{ key: "stale", rate: 1000 }]),
    source("old", true, false, [{ key: "old", rate: 1000 }]),
  ]);
  assert.equal(view.total, "≈ 285 token/s");
  assert.equal(view.rows.length, RATE_ROWS);
  assert.equal(view.rows[0]?.title, "a22");
  assert.equal(view.more, "另有 4 个会话计入合计");
  assert.equal(view.notes.length, 2);
});

test("an unsupported or disconnected fleet does not present stale data as zero", () => {
  const stale = source("one", false, true, [{ key: "a", rate: 12 }]);
  const old = source("two", true, false, [{ key: "b", rate: 12 }]);
  assert.equal(agentRates([stale, old]).total, "—");
  const connected = source("three", true, true, []);
  assert.equal(agentRates([stale, old, connected]).total, "≈ 0 token/s");
  assert.deepEqual(agentRates([stale, old]).rows, []);
});

test("invalid speeds are ignored and ties have a stable station and session order", () => {
  const view = agentRates([
    source("b", true, true, [{ key: "z", rate: 1 }, { key: "bad", rate: NaN }, { key: "negative", rate: -1 }]),
    source("a", true, true, [{ key: "y", rate: 1 }, { key: "x", rate: 1 }, { key: "infinite", rate: Infinity }]),
  ]);
  assert.equal(view.total, "≈ 3 token/s");
  assert.deepEqual(view.rows.map((row) => row.title), ["x", "y", "z"]);
});
