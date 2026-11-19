// `stillfail status` (cli.ts `status`): its last line says the station works normally only where it runs, its process
// said so of itself lately (<data>/run/health.json, ops/health.ts), its link to the front holds and it hears the cloud;
// else what is wrong. It said "normal" under "not running" and under "online: no" before.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { status } from "../src/cli.ts";
import { HEALTH_FRESH_MS, type Health, healthOf, workingOf } from "../src/ops/health.ts";

const NOW = 1_800_000_000_000;
/// A pid no process has (past every system's highest).
const GONE = 99_999_999;

function station(files: { running: boolean; presence?: { online: boolean; error?: string; conflict?: boolean } | null; health?: Partial<Health> | null }): string {
  const data = mkdtempSync(join(tmpdir(), "cli-status-"));
  mkdirSync(join(data, "run"));
  mkdirSync(join(data, "mesh"));
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "https://still.fail", station: "s".repeat(64), workspace: "w1", workspace_name: "Team", name: "mac", key: "k" }));
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: files.running ? process.pid : GONE, startedAt: 1, version: "0.1.2" }));
  if (files.presence) writeFileSync(join(data, "run", "presence.json"), JSON.stringify({ online: files.presence.online, at: 1_700_000_000, error: files.presence.error ?? null, ...(files.presence.conflict === undefined ? {} : { conflict: files.presence.conflict }) }));
  if (files.health) writeFileSync(join(data, "run", "health.json"), JSON.stringify({ pid: process.pid, updatedAt: NOW - 5_000, heldMaxMs: 12, front: "ok", presenceOnline: true, ...files.health }));
  try {
    return status(data, NOW);
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
}

const last = (text: string) => text.split("\n").at(-1)!;

test("a station not running is said stopped, never working normally", () => {
  const text = station({ running: false, presence: { online: true }, health: {} });
  assert.match(text, /station：未运行/);
  assert.match(last(text), /^工作：已停止/);
  assert.doesNotMatch(text, /工作：正常/);
});

test("one running, saying it lately, linked to its front and heard by the cloud works normally", () => {
  const text = station({ running: true, presence: { online: true }, health: {} });
  assert.match(text, /在线：是/);
  assert.equal(last(text), "工作：正常（已连接 Slack，运行 agent 和任务）");
});

test("one the cloud does not hear is limited", () => {
  for (const presence of [{ online: false, error: "connect ECONNREFUSED" }, null]) {
    const text = station({ running: true, presence, health: {} });
    assert.match(last(text), /^工作：受限/, JSON.stringify(presence));
  }
});

test("one whose link to the front is gone is failing, though the cloud hears it", () => {
  const text = station({ running: true, presence: { online: true }, health: { front: "reconnecting" } });
  assert.match(last(text), /^工作：异常（本机 mesh front 断开/);
});

test("one whose process said nothing for longer than a minute is failing, however the rest reads", () => {
  const text = station({ running: true, presence: { online: true }, health: { updatedAt: NOW - HEALTH_FRESH_MS - 60_000 } });
  assert.match(last(text), /^工作：异常（station 进程已 120 秒没有响应/);
  // At the edge: not yet.
  assert.equal(last(station({ running: true, presence: { online: true }, health: { updatedAt: NOW - HEALTH_FRESH_MS } })), "工作：正常（已连接 Slack，运行 agent 和任务）");
});

test("what a process that ended said is not its successor's: the cloud's word stands alone, as for a release from before health.json", () => {
  assert.match(last(station({ running: true, presence: { online: true }, health: { pid: GONE, updatedAt: 0, front: "reconnecting" } })), /^工作：正常/);
  assert.match(last(station({ running: true, presence: { online: true }, health: null })), /^工作：正常/);
  assert.match(last(station({ running: true, presence: { online: false }, health: null })), /^工作：受限/);
});

test("one whose key another station uses is failing, said why and what to do, offline or online between replacements", () => {
  for (const online of [false, true]) {
    const text = station({ running: true, presence: { online, error: "another station is using this station's key", conflict: true }, health: {} });
    assert.equal(last(text), "工作：异常（另一台机器或进程正在用这个 station 的同一份密钥，两边轮流把对方的连接顶掉，设备时连时断；请停掉另一处的 station，或在其中一台上重新注册成新的 station）", `online ${online}`);
  }
  assert.deepEqual(workingOf({ running: true, health: null, healthAlive: false, online: true, conflict: true, now: NOW }), { is: "conflict" });
  // A relay holding its endpoint inactive for another of its key (health.json), the cloud hearing it all the while.
  assert.match(last(station({ running: true, presence: { online: true }, health: { relayConflict: true } })), /^工作：异常（另一台机器或进程正在用这个 station 的同一份密钥/);
  assert.deepEqual(healthOf({ pid: 1, updatedAt: 2, front: "ok", relayConflict: true })?.relayConflict, true);
  // Its process silent is said first: the conflict is the cloud's word, which a hung process cannot change.
  assert.match(last(station({ running: true, presence: { online: true, conflict: true }, health: { updatedAt: NOW - HEALTH_FRESH_MS - 60_000 } })), /^工作：异常（station 进程已/);
});

test("health.json reads only as a whole", () => {
  assert.equal(healthOf(null), null);
  assert.equal(healthOf({ pid: 1, updatedAt: 2, front: "sideways" }), null);
  assert.deepEqual(healthOf({ pid: 1, updatedAt: 2, front: "direct" }), { pid: 1, updatedAt: 2, heldMaxMs: 0, front: "direct", presenceOnline: false });
  // Its descriptors and memory as they come, none where a release from before said none or where they are not numbers.
  assert.deepEqual(healthOf({ pid: 1, updatedAt: 2, front: "ok", openFds: 42, rssBytes: 123_456_789 }), { pid: 1, updatedAt: 2, heldMaxMs: 0, front: "ok", presenceOnline: false, openFds: 42, rssBytes: 123_456_789 });
  assert.deepEqual(healthOf({ pid: 1, updatedAt: 2, front: "ok", openFds: "42", rssBytes: -1 }), { pid: 1, updatedAt: 2, heldMaxMs: 0, front: "ok", presenceOnline: false });
  assert.deepEqual(healthOf({ pid: 1, updatedAt: 2, front: "ok", openFds: 4.5, rssBytes: null }), { pid: 1, updatedAt: 2, heldMaxMs: 0, front: "ok", presenceOnline: false });
  assert.deepEqual(workingOf({ running: true, health: null, healthAlive: false, online: true, now: NOW }), { is: "normal" });
});
