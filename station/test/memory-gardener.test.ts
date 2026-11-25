// Deterministic, offline tests for autonomous background memory compaction (`src/share/memory-gardener.ts`)
// and its event-driven wiring from `MemorySync` (`onSettled`).
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { LINE_MOST, MEMORY_MOST, SKILL_MOST } from "../src/agents/instructions.ts";
import { Cloud } from "../src/cloud/state.ts";
import { MemorySync, type MemorySettledEvent } from "../src/share/memory.ts";
import {
  COOLDOWN_MS,
  DEBOUNCE_MS,
  MemoryGardener,
  NO_PROGRESS_GROWTH_BYTES,
  NO_PROGRESS_WINDOW_MS,
  TIMEOUT_MS,
  inspectMemoryHealth,
  isAllowedDeletePath,
  isAllowedWritePath,
  isGardenerLeader,
  parseCompactionOutput,
  preserveConcurrentLines,
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
  peers?: any[];
  rigs?: any[];
  rigSelf?: any;
  workspace?: string;
}): Cloud {
  const ws = opts.workspace ?? "ws-1";
  const peers = opts.peers ?? [{ id: opts.station, name: "alpha" }];
  const rigs = opts.rigs ?? [];
  return Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
    peersCurrent: true,
    lock: null,
    get state() {
      return {
        station: opts.station,
        name: "alpha",
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

const writeRel = (dir: string, rel: string, content: string) => {
  const full = join(dir, ...rel.split("/"));
  mkdirSync(join(full, ".."), { recursive: true });
  writeFileSync(full, content, "utf8");
};

const readRel = (dir: string, rel: string) => {
  const full = join(dir, ...rel.split("/"));
  return existsSync(full) ? readFileSync(full, "utf8") : null;
};

const settledEvent = (dir: string, conflictMerged = false, ws = "ws-1"): MemorySettledEvent => ({
  workspace: ws,
  dir,
  conflictMerged,
  files: {},
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

test("inspectMemoryHealth: triggers on MEMORY.md > 8 KB, long line > 1500 B, oversized SKILL.md, conflict files, conflictMerged, legacy markers", async () => {
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

  // Conflict file present
  const dir4 = tempDir();
  writeRel(dir4, "MEMORY.md", "# Memory\n- ok\n");
  writeRel(dir4, "skills/proj/SKILL.md", "---\nname: proj\ndescription: d\n---\nmain\n");
  writeRel(dir4, "skills/proj/SKILL.conflict-Studio.md", "other station version\n");
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

// ── 2. Deterministic single-station leader election ──

test("isGardenerLeader: elects rank-0 full station, excludes rigs and offline peers", async () => {
  const peers = [
    { id: B, name: "beta" },
    { id: A, name: "alpha" },
    { id: C, name: "gamma" },
  ];
  // A < B < C: only A is leader
  assert.equal(isGardenerLeader(makeCloud({ station: A, peers }), "ws-1"), true);
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers }), "ws-1"), false);
  assert.equal(isGardenerLeader(makeCloud({ station: C, peers }), "ws-1"), false);

  // If A is a rig, B becomes rank-0 full station
  const rigs = [{ id: A, name: "alpha-rig", owner: "u1", owner_email: "a@b.c", owner_name: "u" }];
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers, rigs }), "ws-1"), true);
  assert.equal(isGardenerLeader(makeCloud({ station: C, peers, rigs }), "ws-1"), false);

  // If this station itself is a rig, never runs
  assert.equal(
    isGardenerLeader(makeCloud({ station: A, peers, rigSelf: { owner: "u1", owner_email: "a@b.c", owner_name: "u", person: "p" } }), "ws-1"),
    false,
  );

  // If A is explicitly offline, B becomes leader
  const peersWithOffline = [
    { id: A, name: "alpha", online: false },
    { id: B, name: "beta", online: true },
    { id: C, name: "gamma" },
  ];
  assert.equal(isGardenerLeader(makeCloud({ station: B, peers: peersWithOffline }), "ws-1"), true);
  assert.equal(isGardenerLeader(makeCloud({ station: C, peers: peersWithOffline }), "ws-1"), false);
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

  // Once a profile becomes available, next event runs immediately (no backoff penalty was recorded).
  available = true;
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);
  assert.equal(readRel(dir, "MEMORY.md"), "# Compact\n- rule\n");
});

// ── 3. Hysteresis, cooldown, fingerprint dedup, and exponential backoff ──

test("MemoryGardener: cooldown prevents re-runs within 30m and stops after compacting below threshold", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule line\n".repeat(900));
  const { clock, advance } = makeClock();
  let calls = 0;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async () => {
      calls++;
      return { memoryMd: `# Memory\n${"- compact\n".repeat(500)}` }; // ~5 KB <= 8 KB
    },
  });
  gardeners.push(g);

  // Burst of events debounced into one run
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS / 2);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS / 2);
  await g.idle();
  assert.equal(calls, 0, "still debouncing after second event");

  await advance(DEBOUNCE_MS / 2);
  await g.idle();
  assert.equal(calls, 1);
  assert.ok(Buffer.byteLength(readRel(dir, "MEMORY.md")!, "utf8") < MEMORY_MOST);

  // Another settled event after compaction (now healthy ~5 KB) does not trigger even after cooldown
  await advance(COOLDOWN_MS + 1000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // Overgrow again within cooldown -> skipped; after cooldown -> runs
  writeRel(dir, "MEMORY.md", "- overgrown again\n".repeat(700));
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 2);

  // Immediate re-overgrow within 30m cooldown -> blocked
  writeRel(dir, "MEMORY.md", "- overgrown third\n".repeat(700));
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 2);

  // After cooldown passes -> runs
  await advance(COOLDOWN_MS);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 3);
});

test("MemoryGardener: fingerprint hysteresis prevents infinite loops on unshrinkable memory until >=2KB growth or new conflict", async () => {
  const dir = tempDir();
  const hardRules = "- hard rule that cannot shrink\n".repeat(320); // ~9.9 KB > 8 KB
  writeRel(dir, "MEMORY.md", hardRules);
  const { clock, advance } = makeClock();
  let calls = 0;

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (input) => {
      calls++;
      // Returns same size -> no substantive progress
      return { memoryMd: input.memoryMd };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // Even after cooldown, same fingerprint inside 24h window is skipped
  await advance(COOLDOWN_MS + 1000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // Adding a new conflict file breaks hysteresis and triggers compaction
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "conflicting line\n");
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 2);

  // Remove conflict and test >= 2 KB growth breaking hysteresis
  rmSync(join(dir, "skills/proj/SKILL.conflict-Studio.md"), { force: true });
  await advance(COOLDOWN_MS + 1000);
  writeRel(dir, "MEMORY.md", hardRules + `${"- extra rule\n".repeat(Math.ceil((NO_PROGRESS_GROWTH_BYTES + 200) / 13))}`);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 3);

  // After 24h hysteresis window expires, same fingerprint may run again
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

  // At 29m -> still in backoff
  await advance(COOLDOWN_MS - DEBOUNCE_MS - 1000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 1);

  // At 30m -> 2nd attempt (hang -> hard timeout at 90s -> 60m backoff)
  mode = "hang";
  await advance(2000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
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

  // At +60m -> succeeds
  await advance(16 * 60_000);
  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();
  assert.equal(calls, 3);
  assert.equal(readRel(dir, "MEMORY.md"), "# Clean\n- rule\n");
});

// ── 4. Safety validation gates ──

test("validation gates: path whitelist, delete whitelist, non-empty MEMORY.md, fenced JSON, substantive progress", async () => {
  // Path whitelist
  assert.equal(isAllowedWritePath("MEMORY.md"), true);
  assert.equal(isAllowedWritePath("skills/machines/pvg.md"), true);
  assert.equal(isAllowedWritePath("skills/people/alice.md"), true);
  assert.equal(isAllowedWritePath("PROJECTS.jsonl"), false);
  assert.equal(isAllowedWritePath("skills/stillfail-jobs/SKILL.md"), false);
  assert.equal(isAllowedWritePath("../escape.md"), false);
  assert.equal(isAllowedWritePath("/etc/passwd"), false);
  assert.equal(isAllowedWritePath("skills/proj/SKILL.conflict-A.md"), false);

  // Delete whitelist: only *.conflict-*
  assert.equal(isAllowedDeletePath("skills/proj/SKILL.conflict-Studio.md"), true);
  assert.equal(isAllowedDeletePath("MEMORY.md"), false);
  assert.equal(isAllowedDeletePath("skills/proj/SKILL.md"), false);
  assert.equal(isAllowedDeletePath("PROJECTS.jsonl"), false);
  assert.equal(isAllowedDeletePath("skills/stillfail-jobs/foo.conflict-A.md"), false);

  // Fenced JSON parsing
  const parsed = parseCompactionOutput("```json\n{\"memoryMd\":\"# Ok\\n- a\\n\"}\n```");
  assert.deepEqual(parsed, { memoryMd: "# Ok\n- a\n" });

  const dir = tempDir();
  writeRel(dir, "MEMORY.md", "- rule\n".repeat(1500));
  const report = await inspectMemoryHealth(dir);

  // Reject blanking non-empty MEMORY.md
  const blankRes = validateCompactionOutput({ memoryMd: "   \n" }, report);
  assert.equal(blankRes.ok, false);

  // Reject writing PROJECTS.jsonl
  const projRes = validateCompactionOutput({ writes: [{ path: "PROJECTS.jsonl", content: "{}" }] }, report);
  assert.equal(projRes.ok, false);

  // Reject writing builtin skill
  const builtinRes = validateCompactionOutput({ writes: [{ path: "skills/stillfail-jobs/SKILL.md", content: "x" }] }, report);
  assert.equal(builtinRes.ok, false);

  // Reject deleting real skill
  const delRes = validateCompactionOutput({ deletes: ["skills/proj/SKILL.md"] }, report);
  assert.equal(delRes.ok, false);

  // No substantive progress when MEMORY.md did not shrink and no conflict/skill was improved
  const sameRes = validateCompactionOutput({ memoryMd: report.memoryMd }, report);
  assert.equal(sameRes.ok, true);
  if (sameRes.ok) assert.equal(sameRes.meaningfulProgress, false);
});

// ── 5. Concurrent-edit preservation (core safety invariant) ──

test("MemoryGardener: preserves new rule written concurrently during compaction without re-introducing deleted bloat", async () => {
  const dir = tempDir();
  const bloat = Array.from({ length: 400 }, (_, i) => `- obsolete status note #${i}: build running`).join("\n");
  const initial = `# Global Memory\n- Durable rule A.\n${bloat}\n`;
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
        memoryMd: "# Global Memory\n- Durable rule A.\n",
      };
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await started.promise;

  // Meanwhile, a live agent appends a brand-new durable rule to MEMORY.md while compaction is in flight.
  const concurrentRule = "- Brand new critical rule added during compaction.";
  writeRel(dir, "MEMORY.md", `${initial}${concurrentRule}\n`);

  release.resolve();
  await g.idle();

  const afterText = readRel(dir, "MEMORY.md")!;
  assert.ok(afterText.includes("- Durable rule A."), "kept compacted durable rule");
  assert.ok(afterText.includes(concurrentRule), "preserved concurrent live addition 100%");
  assert.ok(!afterText.includes("obsolete status note #0"), "did NOT re-introduce deleted bloat via 3-way merge");
  assert.ok(Buffer.byteLength(afterText, "utf8") < 1024);

  // Unit check of preserveConcurrentLines directly
  const merged = preserveConcurrentLines("a\nb\nc\n", "a\nb\nc\nd\n", "a\n");
  assert.equal(merged, "a\nd\n");
});

// ── 6. Migration to skills/machines & skills/people + conflict cleanup ──

test("MemoryGardener: migrates machine/people facts to skills/ with 0644 mode and deletes resolved *.conflict-* files", async () => {
  const dir = tempDir();
  writeRel(dir, "MEMORY.md", `# Memory\n${"- pvg-office-2: overlay root\n".repeat(400)}`);
  writeRel(dir, "skills/proj/SKILL.md", "---\nname: proj\ndescription: Project\n---\n- main rule\n");
  writeRel(dir, "skills/proj/SKILL.conflict-Studio.md", "- studio rule\n");
  const { clock, advance } = makeClock();

  const g = new MemoryGardener({
    cloud: makeCloud({ station: A }),
    clock,
    compact: async (input: CompactionInput): Promise<string> => {
      assert.equal(input.conflictFiles.length, 1);
      return JSON.stringify({
        memoryMd: "# Memory\n- Global rule only.\n",
        writes: [
          { path: "skills/machines/SKILL.md", content: "---\nname: machines\ndescription: Machine notes\n---\n- pvg-office-2.md\n" },
          { path: "skills/machines/pvg-office-2.md", content: "- overlay root resets apt on reboot\n" },
          { path: "skills/people/SKILL.md", content: "---\nname: people\ndescription: People prefs\n---\n- alice.md\n" },
          { path: "skills/people/alice.md", content: "- Prefers concise Chinese summaries\n" },
          { path: "skills/proj/SKILL.md", content: "---\nname: proj\ndescription: Project\n---\n- main rule\n- studio rule\n" },
        ],
        deletes: ["skills/proj/SKILL.conflict-Studio.md"],
      });
    },
  });
  gardeners.push(g);

  g.onSettled(settledEvent(dir));
  await advance(DEBOUNCE_MS);
  await g.idle();

  assert.equal(readRel(dir, "MEMORY.md"), "# Memory\n- Global rule only.\n");
  assert.equal(readRel(dir, "skills/machines/pvg-office-2.md"), "- overlay root resets apt on reboot\n");
  assert.equal(readRel(dir, "skills/people/alice.md"), "- Prefers concise Chinese summaries\n");
  assert.ok(readRel(dir, "skills/proj/SKILL.md")!.includes("- studio rule"));
  assert.equal(readRel(dir, "skills/proj/SKILL.conflict-Studio.md"), null, "conflict file deleted");

  // Verify 0644 shared permissions so MemorySync replicates them
  const mode = statSync(join(dir, "skills/machines/pvg-office-2.md")).mode & 0o777;
  assert.equal(mode, 0o644);
});

// ── 7. Clean stop() of in-flight compaction ──

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
  assert.equal(readRel(dir, "MEMORY.md"), original, "must not write after stop()");
});

// ── 8. End-to-end wiring: MemorySync #look / #take -> onSettled -> MemoryGardener ──

test("MemorySync onSettled drives MemoryGardener on #look and cross-station #take conflict merge", async () => {
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
  const cloudA = makeCloud({ station: A, peers });
  const cloudB = makeCloud({ station: B, peers });
  const { clock, advance } = makeClock();

  const eventsA: MemorySettledEvent[] = [];
  let compactCalls = 0;

  const gardenerA = new MemoryGardener({
    cloud: cloudA,
    clock,
    compact: async (input) => {
      compactCalls++;
      // Strip [ccvm]/[Studio] tags produced by originless merge
      const cleaned = input.memoryMd
        .replace(/^- \[[^\]]+\]\s+/gm, "- ")
        .trim() + "\n";
      return { memoryMd: cleaned };
    },
  });
  gardeners.push(gardenerA);

  let syncB!: MemorySync;
  const syncA = new MemorySync({
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

  // Both stations have independent initial MEMORY.md -> cross-station merge produces conflictMerged=true and [station] tags
  writeRel(homeA, "MEMORY.md", "# Memory\n- Rule from A.\n");
  writeRel(homeB, "MEMORY.md", "# Memory\n- Rule from B.\n");

  await syncA.levelNow();
  assert.ok(eventsA.some((e) => e.conflictMerged === true), "expected conflictMerged=true settled event from #take");

  await advance(DEBOUNCE_MS);
  await gardenerA.idle();

  assert.equal(compactCalls, 1);
  const compactedA = readRel(homeA, "MEMORY.md")!;
  assert.ok(compactedA.includes("- Rule from A."));
  assert.ok(compactedA.includes("- Rule from B."));
  assert.ok(!compactedA.includes("[ccvm]") && !compactedA.includes("[Studio]"), "stripped station merge tags");
});
