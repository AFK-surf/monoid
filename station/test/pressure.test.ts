import assert from "node:assert/strict";
import { test } from "node:test";
import { pressureSince, stallTotal, vmStalls } from "../src/ops/pressure.ts";

const cpu = "some avg10=12.47 avg60=15.23 avg300=42.93 total=8218464412\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
const memory = "some avg10=0.86 avg60=0.46 avg300=0.48 total=300817784\nfull avg10=0.86 avg60=0.43 avg300=0.22 total=225218514\n";

test("a pressure file's totals and vmstat's stalls are read as Linux writes them", () => {
  assert.equal(stallTotal(cpu, "some"), 8218464412);
  assert.equal(stallTotal(memory, "full"), 225218514);
  assert.equal(stallTotal("some avg10=0.00\n", "full"), null);
  assert.deepEqual(vmStalls("pgmajfault 300295\nallocstall_dma 1\nallocstall_normal 3665\nallocstall_movable 169951\ncompact_stall 225906\ncompact_fail 206889\n"), { compactStalls: 225906, allocStalls: 173617 });
});

test("a held thread's window says what the machine went short of in it, and nothing where it cannot say", () => {
  const before = { cpuSome: 1_000_000, memorySome: 2_000_000, memoryFull: 500_000, compactStalls: 10, allocStalls: 4 };
  const after = { cpuSome: 5_300_000, memorySome: 2_900_400, memoryFull: 1_400_000, compactStalls: 52, allocStalls: 9 };
  assert.deepEqual(pressureSince(before, after), { windowCpuWaitMs: 4300, windowMemoryWaitMs: 900, windowMemoryStallMs: 900, windowCompactStalls: 42, windowAllocStalls: 5 });
  assert.deepEqual(pressureSince(null, after), {});
  assert.deepEqual(pressureSince(before, null), {});
});
