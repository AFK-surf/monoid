// Deterministic unit tests for offline station diagnostics: Mesh.diag, Link.diag, stationDiag view, and stationProblems.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { holdLanguage } from "../src/i18n.ts";
import { CONNECT_TIMEOUT_MS, LAN, Mesh, TAILNET, type CredentialSource } from "../src/mesh.ts";
import { Runner } from "../src/runtime.ts";
import { STATION_MESH } from "../src/station/mesh-wire.ts";
import { FakeHost } from "../src/testing.ts";
import { Tracer } from "../src/trace.ts";
import { stationDiagView, stationProblems } from "../src/views/views.ts";
import { Wakes } from "../src/wake.ts";
import { SimNet, SimTime } from "./sim-iroh.ts";

holdLanguage();

test("stationProblems distinguishes network, unreached, station, lock, updating and silent", () => {
  const net = stationProblems(false, false, null, true, false, false, "network");
  assert.equal(net.length, 1);
  assert.equal(net[0]!.key, "away");
  assert.equal(net[0]!.level, "red");
  assert.match(net[0]!.text, /本机无法连接/);

  const unreached = stationProblems(false, false, null, true, false, false, "unreached");
  assert.equal(unreached.length, 1);
  assert.equal(unreached[0]!.key, "away");
  assert.equal(unreached[0]!.level, "red");
  assert.match(unreached[0]!.text, /可能已离线/);

  const stationDown = stationProblems(false, false, null, true, false, false, "station");
  assert.equal(stationDown.length, 1);
  assert.match(stationDown[0]!.text, /在该机器上打开/);

  const neverSeen = stationProblems(false, false, null, false, false, false, "station");
  assert.equal(neverSeen[0]!.level, "amber");

  const lock = stationProblems(false, false, "此设备等待批准", true, false, false, "lock");
  assert.equal(lock[0]!.key, "blocked");
  assert.equal(lock[0]!.text, "此设备等待批准");

  const updating = stationProblems(false, false, null, true, true, false, "updating");
  assert.equal(updating[0]!.key, "updating");
  assert.equal(updating[0]!.level, "amber");

  const silent = stationProblems(true, true, null, true, false, false, null);
  assert.equal(silent[0]!.key, "silent");
});

test("stationDiagView formats unreached, network, station, lock, updating, error and copyText under 2 KB", () => {
  const now = Date.UTC(2026, 10, 20, 7, 50, 0);
  const clock = { now, offsetMin: 480 };
  const relayName = (host: string) => (host === "relay-tyo.still.fail" ? "东京中继" : host === "relay-sin.still.fail" ? "新加坡中继" : null);

  const unreached = stationDiagView({
    station: "ws1/st1",
    id: "st1",
    name: "Willow",
    version: "0.1.1288",
    lastSeenSec: Math.floor((now - 5 * 60_000) / 1000),
    link: { state: "offline", cause: "unreached", message: "连不上这台 station" },
    linkDiag: {
      misses: 5,
      slowBackoff: true,
      retryAt: now + 10 * 60_000,
      retryWaitMs: 10 * 60_000,
      lastEnd: "连不上这台 station",
      lastEndAt: now - 30_000,
      lastErrorCode: "mesh",
      downAt: now - 5 * 60_000,
      cloudDown: false,
    },
    peerDiag: {
      at: now - 30_000,
      relays: [
        { url: "https://relay-tyo.still.fail", connected: true },
        { url: "https://relay-sin.still.fail", connected: false },
      ],
      lan: ["192.168.1.24:41901"],
      tailnet: ["100.64.0.12:41901"],
      attempts: [
        { via: LAN, outcome: "no_answer", stage: "dial", totalMs: 10_000 },
        { via: TAILNET, outcome: "error", stage: "dial", totalMs: 320, error: "connection refused" },
        { via: "relay:relay-tyo.still.fail", outcome: "no_answer", stage: "hello", totalMs: 10_000 },
        { via: "relay:relay-sin.still.fail", outcome: "error", stage: "onto", totalMs: 1500, error: "relay unreachable" },
      ],
    },
    net: { path: "东京中继", rtt: { text: "42 ms", level: "ok" } },
    cloudDown: false,
    clock,
    relayName,
  });

  assert.equal(unreached.cause, "unreached");
  assert.match(unreached.summary, /所有路径均无法连上/);
  assert.equal(unreached.cloudStatus, "正常");
  assert.equal(unreached.lastNetText, "东京中继 · 42 ms");
  assert.deepEqual(unreached.addresses, ["192.168.1.24:41901", "100.64.0.12:41901"]);
  assert.match(unreached.retryText, /已连续失败 5 次/);
  assert.match(unreached.retryText, /16:00:00/);
  assert.match(unreached.retryText, /每 10 分钟/);
  assert.equal(unreached.ways.length, 4);
  assert.equal(unreached.ways[0]!.name, "局域网直连");
  assert.equal(unreached.ways[0]!.status, "timeout");
  assert.equal(unreached.ways[2]!.name, "东京中继");
  assert.match(unreached.copyText, /Station: Willow \(st1\) v0\.1\.1288/);
  assert.match(unreached.copyText, /Cause: unreached/);
  assert.match(unreached.copyText, /Routes:/);
  assert.ok(new TextEncoder().encode(JSON.stringify(unreached)).length < 2048);

  // Fallback to relay status when no dial attempts exist yet
  const relayFallback = stationDiagView({
    station: "ws1/st1",
    id: "st1",
    name: "Willow",
    version: null,
    lastSeenSec: null,
    link: { state: "offline", cause: "network", message: null },
    linkDiag: null,
    peerDiag: {
      at: 0,
      relays: [
        { url: "https://relay-tyo.still.fail", connected: true },
        { url: "https://relay-sin.still.fail", connected: false },
      ],
      lan: [],
      tailnet: [],
      attempts: [],
    },
    net: null,
    cloudDown: true,
    clock,
    relayName,
  });
  assert.equal(relayFallback.cause, "network");
  assert.match(relayFallback.cloudStatus, /不可达/);
  assert.equal(relayFallback.ways.length, 2);
  assert.equal(relayFallback.ways[0]!.status, "ok");
  assert.equal(relayFallback.ways[1]!.status, "down");

  // Other causes: station, lock, updating, error, silent
  for (const [link, expected] of [
    [{ state: "offline", cause: "station" }, "station"],
    [{ state: "offline", cause: "lock", message: "等待批准" }, "lock"],
    [{ state: "offline", cause: "updating" }, "updating"],
    [{ state: "error", message: "426" }, "error"],
    [{ state: "online" }, "silent"],
  ] as const) {
    const d = stationDiagView({
      station: "ws1/st1",
      id: "st1",
      name: "Willow",
      version: null,
      lastSeenSec: null,
      link,
      linkDiag: null,
      peerDiag: null,
      net: null,
      cloudDown: false,
      clock,
      relayName,
    });
    assert.equal(d.cause, expected);
  }
});

test("Mesh.diag records latest dial round attempts without recording enabled", async () => {
  const time = new SimTime();
  const net = new SimNet(time.clock, 1);
  const host = new FakeHost(time);
  const wakes = new Wakes();
  const runner = new Runner(time.clock);
  try {
    const relayUrl = net.relay("https://relay-tyo.still.fail");
    const mesh = await time.settle(
      runner.run(
        Mesh.make(
          {
            host,
            runner,
            tracer: new Tracer(host, runner, 1),
            iroh: net.iroh(),
            wakes,
            ...STATION_MESH,
          },
          [relayUrl],
        ),
      ),
    );
    const deadStation = "a".repeat(64);
    const addr = `ws1/${deadStation}`;
    const creds: CredentialSource = () => Effect.succeed({ credential: "tok-1", also: null });

    const r = await time.settle(runner.run(Effect.result(mesh.link(addr, creds))), CONNECT_TIMEOUT_MS + 10_000);
    assert.equal(r._tag, "Failure");

    const diag = mesh.diag(addr);
    assert.ok(diag.at > 0);
    assert.equal(diag.relays.length, 1);
    assert.equal(diag.attempts.length, 1);
    assert.equal(diag.attempts[0]!.via, "main");
    assert.equal(diag.attempts[0]!.outcome, "no_answer");
    assert.equal(diag.attempts[0]!.stage, "dial");
    assert.ok(diag.attempts[0]!.totalMs >= CONNECT_TIMEOUT_MS);

    await time.settle(runner.run(mesh.close()));
  } finally {
    runner.shutdown();
  }
});
