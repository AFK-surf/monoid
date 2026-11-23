// How short of CPU and memory the machine was while the main thread was held (main.ts "the main thread was held"): a
// hold with little of the thread's own CPU in it was the machine's, not the station's. One station's 8 cores, its
// agents' work on all of them and its memory short, held its thread for seconds while the thread was 75% idle: tasks
// waited for a CPU 43% of the time, and the kernel had stalled allocations to compact memory 225,906 times. Linux's
// pressure stall information (/proc/pressure) and its vmstat counters say so; elsewhere nothing is said.
import { readFile } from "node:fs/promises";
import { platform } from "../platform/index.ts";

/// The machine's counters at one time: the µs some task (`some`) or every task (`full`) waited, and the stalls.
export type Pressure = { cpuSome: number; memorySome: number; memoryFull: number; compactStalls: number; allocStalls: number };

/// `total=` of the `some` or `full` line of a /proc/pressure file (µs), none where it has no such line.
export function stallTotal(text: string, which: "some" | "full"): number | null {
  const line = text.split("\n").find((l) => l.startsWith(`${which} `));
  const total = line?.match(/\btotal=(\d+)/)?.[1];
  return total === undefined ? null : Number(total);
}

/// /proc/vmstat's direct compaction stalls and direct reclaim stalls (`allocstall_*` summed).
export function vmStalls(text: string): { compactStalls: number; allocStalls: number } {
  let compactStalls = 0;
  let allocStalls = 0;
  for (const line of text.split("\n")) {
    const [name, value] = line.split(" ");
    if (name === "compact_stall") compactStalls = Number(value);
    else if (name?.startsWith("allocstall_")) allocStalls += Number(value);
  }
  return { compactStalls, allocStalls };
}

/// The counters now; none where the system keeps none (not Linux, or a kernel without pressure stall information).
export async function pressureNow(): Promise<Pressure | null> {
  if (platform.os !== "linux") return null;
  try {
    const [cpu, memory, vmstat] = await Promise.all(["/proc/pressure/cpu", "/proc/pressure/memory", "/proc/vmstat"].map((p) => readFile(p, "utf8")));
    const cpuSome = stallTotal(cpu!, "some");
    const memorySome = stallTotal(memory!, "some");
    const memoryFull = stallTotal(memory!, "full");
    if (cpuSome === null || memorySome === null || memoryFull === null) return null;
    return { cpuSome, memorySome, memoryFull, ...vmStalls(vmstat!) };
  } catch {
    return null;
  }
}

/// What the machine's counters went up by from `before` to `after`, as the held thread's log says it: the ms some task
/// waited for a CPU (`windowCpuWaitMs`), some or every task waited on memory (`windowMemoryWaitMs`,
/// `windowMemoryStallMs`), and the allocations stalled to compact or reclaim memory. Nothing where either is missing.
export function pressureSince(before: Pressure | null, after: Pressure | null): Record<string, number> {
  if (before === null || after === null) return {};
  const ms = (a: number, b: number) => Math.max(0, Math.round((b - a) / 1000));
  return {
    windowCpuWaitMs: ms(before.cpuSome, after.cpuSome),
    windowMemoryWaitMs: ms(before.memorySome, after.memorySome),
    windowMemoryStallMs: ms(before.memoryFull, after.memoryFull),
    windowCompactStalls: Math.max(0, after.compactStalls - before.compactStalls),
    windowAllocStalls: Math.max(0, after.allocStalls - before.allocStalls),
  };
}
