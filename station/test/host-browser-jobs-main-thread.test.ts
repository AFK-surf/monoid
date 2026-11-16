// What the station's main thread waits on as it measures its machine (api/host.ts `Host`: GET /host, the events' host
// samples, station_list's load), says whether there is a Chrome here and starts one (browser/chrome.ts `chromeHost`),
// starts an agent's runner (agents/runner.ts `startRunner`), asks whether Codex's update is the station's own
// (agents/codex.ts `updateMatchesStation`), follows a job an earlier station started to its end (jobs/jobs.ts
// `leaderGone`) and starts one (`spawn`, its shell found by `posixShellSoon`): none of node:fs's or
// node:child_process's synchronous calls (station/AGENTS.md, the main thread waits on nothing). Each ran on every sample
// (Linux's /proc/stat read on the thread), every overview (each place a Chrome may be looked at), every runner started
// (PATH walked), every second of a job taken up (its exit file looked for) and every job started on Windows (Git's sh
// looked for on disk).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, mock, test } from "node:test";
import { Host } from "../src/api/host.ts";
import { chromeHost } from "../src/browser/chrome.ts";
import { CodexDriver } from "../src/agents/codex.ts";
import { CommandMissing, startRunner } from "../src/agents/runner.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { wall } from "../src/ops/fibers.ts";
import { platform, WINDOWS } from "../src/platform/index.ts";
import { Store } from "../src/store/store.ts";
import { channelOf, releaseChannel } from "../src/updates/versions.ts";
import { syncCalls } from "./main-thread-sync.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
/// A directory of its own for a test (short: a runner's socket lives under it on macOS).
function scratch(): string {
  const d = mkdtempSync(join(WINDOWS ? tmpdir() : "/tmp", "hbj-"));
  dirs.push(d);
  return d;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/// Waits for what a real process does (it has no event here), looking every 5 ms. No deadline: it comes, however slow
/// the machine, or the test hangs.
async function until(check: () => boolean) {
  while (!check()) await sleep(5);
}

test("the machine's CPUs sampled, followed and averaged wait on no file and no process", async () => {
  const host = new Host(scratch(), { read: async () => null });
  let ticks: unknown;
  let recent: unknown;
  let sample: { cpuBusy?: unknown } | undefined;
  const calls = await syncCalls(async () => {
    const read = platform.host.cpuTicks();
    // Linux's are /proc/stat, read off the thread; macOS's and Windows' the system's counters, at once.
    if (process.platform === "linux") assert.ok(read instanceof Promise, "/proc/stat is read off the main thread");
    ticks = await read;
    const stop = host.follow();
    try {
      recent = await host.recentBusy();
      sample = await host.sample("en");
    } finally {
      stop();
    }
  });
  assert.deepEqual(calls, []);
  assert.ok(ticks === null || (Array.isArray(ticks) && ticks.length === 2), "busy and total, or none");
  assert.ok(recent === null || typeof recent === "object");
  assert.ok(sample?.cpuBusy === null || typeof sample?.cpuBusy === "number");
});

test("ticks read off the main thread are noted as they come, one read at a time, and none after the follow stops", async () => {
  const answers: ((t: [number, number]) => void)[] = [];
  const ticks = mock.method(platform.host, "cpuTicks", () => new Promise<[number, number]>((resolve) => answers.push(resolve)));
  const beats: (() => void)[] = [];
  const every = mock.method(wall, "every", (_ms: number, beat: () => void) => {
    beats.push(beat);
    return () => {};
  });
  let clock = 1_000;
  const now = mock.method(wall, "now", () => clock);
  try {
    const host = new Host("/data", { read: async () => null });
    const stop = host.follow();
    assert.equal(answers.length, 1, "the first look at once");
    beats[0]!();
    assert.equal(answers.length, 1, "a beat that finds a read still out lets it be");
    answers[0]!([10, 20]);
    await new Promise((r) => setImmediate(r));
    clock += 30_000;
    beats[0]!();
    assert.equal(answers.length, 2);
    answers[1]!([20, 40]);
    await new Promise((r) => setImmediate(r));
    const busy = host.recentBusy();
    clock += 1;
    answers[2]!([20, 40]);
    assert.deepEqual(await busy, { busy: 0.5, seconds: 30 }, "the window's first ticks to the last");
    beats[0]!();
    stop();
    // A minute and more on: only what is noted from now on is within the window.
    clock = 200_000;
    answers[3]!([1_000, 1_000]);
    await new Promise((r) => setImmediate(r));
    const later = host.recentBusy();
    clock = 201_500;
    answers[4]!([1_100, 1_200]);
    assert.equal(await later, null, "what came after the stop was not noted");
  } finally {
    ticks.mock.restore();
    every.mock.restore();
    now.mock.restore();
  }
});

test("whether there is a Chrome here is said from memory, looked for again and as it starts off the main thread", async () => {
  const dir = scratch();
  // (as the station starts, before it serves: looked for once)
  const host = chromeHost({ dir, headless: true });
  let looks = 0;
  const soon = mock.method(platform, "browsersSoon", async () => {
    looks++;
    return [];
  });
  let clock = wall.now();
  const now = mock.method(wall, "now", () => clock);
  let failed: unknown;
  try {
    const calls = await syncCalls(async () => {
      for (let i = 0; i < 5; i++) host.installed!();
      assert.equal(looks, 0, "within its time, the look made as it started is the answer");
      clock += 60_000;
      host.installed!();
      host.installed!();
      assert.equal(looks, 1, "past it, looked for again once however many ask");
      await new Promise((r) => setImmediate(r));
      assert.equal(host.installed!(), false, "the new look is the answer");
      failed = await host.launch().catch((e: Error) => e.message);
    });
    assert.deepEqual(calls, []);
    assert.equal(looks, 2, "a start looks for itself");
    assert.match(String(failed), /no Chrome on this machine/);
  } finally {
    soon.mock.restore();
    now.mock.restore();
  }
});

test("a runner's missing command and whether Codex's update is the station's own are looked for off the main thread", { skip: WINDOWS && "a POSIX script stands for Codex" }, async () => {
  const dir = scratch();
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(bin, "codex"), "#!/bin/sh\necho codex-cli\n", { mode: 0o755 });
  const skills = join(dir, "skills");
  mkdirSync(skills);
  const driver = new CodexDriver({ data: dir, hostSkills: skills, caBundle: join(dir, "cert.pem"), env: { PATH: bin } });
  const profile = { id: "cx", runtime: "codex" as const, home: join(dir, "home"), access: { kind: "opencode-go", key: "k" }, env: { PATH: bin } };
  let missing: unknown;
  let same: unknown;
  try {
    const calls = await syncCalls(async () => {
      missing = await startRunner(dir, "missing", "no-such-command-here", [], { PATH: bin }, dir).catch((e: unknown) => e);
      same = await driver.updateMatchesStation(profile as never);
    });
    assert.deepEqual(calls, []);
    assert.ok(missing instanceof CommandMissing, String(missing));
    assert.equal(same, true, "the same codex on both PATHs");
  } finally {
    await driver.shutdown();
  }
});

test("a job an earlier station started is followed to its end, its exit file looked for off the main thread", { skip: WINDOWS && "a fifo stands for the job's gate" }, async () => {
  const dir = scratch();
  const work = join(dir, "work");
  mkdirSync(work);
  const store = Store.open(":memory:");
  const gate = join(dir, "gate");
  execFileSync("mkfifo", [gate]);
  const before = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const job = await before.start("s1", "build", `cat '${gate}' >/dev/null; exit 3`, work, null, false);
  await before.shutdown();
  // (as the next station starts, before it serves)
  const told: string[] = [];
  const next = new Jobs({ store, data: dir, notify: (_session, text) => void told.push(text), link: () => null });
  try {
    await next.relaunch();
    assert.equal(store.getJob(job.id)!.state, "running", "taken up, not started again");
    const calls = await syncCalls(async () => {
      // Off the main thread: opening a fifo to write waits for its reader.
      await writeFile(gate, "go");
      await until(() => store.getJob(job.id)!.state === "exited");
      await until(() => told.length > 0);
    });
    assert.deepEqual(calls, []);
    assert.equal(store.getJob(job.id)!.exitCode, 3, "how it ended, from what its shell wrote");
    assert.ok(told[0]!.includes("ended with exit code 3"), told[0]);
  } finally {
    await next.shutdown();
    store.close();
  }
});

test("a job started and followed to its end waits on no file and no process, its shell found off the main thread", { skip: WINDOWS && "a POSIX command" }, async () => {
  const dir = scratch();
  const work = join(dir, "work");
  mkdirSync(work);
  const store = Store.open(":memory:");
  // (as the station starts, before it serves: its stillfail-job made)
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  // What finds the shell on the station's thread is for that alone (on Windows it looks on disk).
  const shell = mock.method(platform, "posixShell", () => {
    throw new Error("the shell found on the main thread");
  });
  try {
    let id = "";
    const calls = await syncCalls(async () => {
      id = (await jobs.start("s1", "build", "echo built; exit 4", work, null, false)).id;
      await until(() => store.getJob(id)!.state === "exited");
    });
    assert.deepEqual(calls, []);
    assert.equal(shell.mock.callCount(), 0);
    assert.equal(store.getJob(id)!.exitCode, 4);
    assert.equal(readFileSync(store.getJob(id)!.log, "utf8"), "built\n");
  } finally {
    shell.mock.restore();
    await jobs.shutdown();
    store.close();
  }
});

test("a release from before channels is read once: its sessions' pages and the move's switch ask it of memory", async () => {
  const app = scratch();
  // (as Updates is made, before the station serves)
  assert.equal(releaseChannel(app), null, "its installer wrote no CHANNEL");
  const calls = await syncCalls(async () => {
    for (let i = 0; i < 5; i++) assert.equal(channelOf({}, app), "stable");
  });
  assert.deepEqual(calls, []);
});
