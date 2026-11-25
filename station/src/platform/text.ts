// Reading what a machine's commands and files say (api/host.ts's, for every machine): Rust's str methods as host.rs
// uses them.

/// Rust's str::trim (char::is_whitespace).
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM = new RegExp(`^[${WS}]+|[${WS}]+$`, "g");
export const trim = (s: string) => s.replace(TRIM, "");
const SPLIT = new RegExp(`[${WS}]+`);
export const firstWord = (s: string) => s.split(SPLIT).find((w) => w !== "") ?? "";
export const splitWords = (s: string) => s.split(SPLIT).filter((w) => w !== "");

/// str::parse::<u64>: digits (a `+` before them at most); none otherwise.
export const parseU64 = (s: string): number | null => (/^\+?[0-9]+$/.test(s) ? Number(s) : null);
/// str::parse::<f64> for what these commands write (no inf or nan here).
export const parseF64 = (s: string): number | null => (/^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/.test(s) ? Number(s) : null);

/// What a system's memory left says of its pressure (where it has no level of its own): under a tenth available is high,
/// under 4% critical.
export function pressureOfAvailable(available: number | null, total: number | null): "normal" | "high" | "critical" | null {
  if (available === null || total === null || !(total > 0) || !(available >= 0) || available > total) return null;
  const share = available / total;
  return share < 0.04 ? "critical" : share < 0.1 ? "high" : "normal";
}

/// macOS's kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical. Warn is high only while the memory left
/// says so too (available and total, as pressureOfAvailable; high where they cannot be read): macOS warns while its
/// free pages are low, which it keeps them with file cache and the compressor, and a machine stayed in warn over 40
/// minutes with a quarter of its memory available, every task held back (#4355).
export function pressureOfLevel(level: string, available: number | null = null, total: number | null = null): "normal" | "high" | "critical" | null {
  switch (trim(level)) {
    case "1":
      return pressureOfAvailable(available, total) ?? "normal";
    case "2":
      return pressureOfAvailable(available, total) ?? "high";
    case "4":
      return "critical";
    default:
      return null;
  }
}

/// What the swap says of the memory's pressure (macOS): what the memory used counts leaves out what was swapped out, so a
/// machine paging hard can read as having memory left (2026-11-23: 66 GiB swapped on a 64 GiB machine, load 246, read
/// normal until it was too late). High while a quarter of the memory's size is swapped out and pages still go out,
/// critical at half; swap kept from before while nothing goes out says nothing. `outPerSecond`: pages swapped out a
/// second since the last look (null on the first).
export const SWAPPING_PAGES_PER_SECOND = 256;
export function pressureOfSwap(swapUsed: number | null, total: number | null, outPerSecond: number | null): "normal" | "high" | "critical" | null {
  if (swapUsed === null || total === null || !(total > 0) || !(swapUsed >= 0) || outPerSecond === null) return null;
  if (outPerSecond < SWAPPING_PAGES_PER_SECOND) return "normal";
  return swapUsed >= total / 2 ? "critical" : swapUsed >= total / 4 ? "high" : "normal";
}

/// `avg10=` of the `some` or `full` line of a Linux `/proc/pressure/*` file (percentage of wall time stalled over the
/// last 10 s); null where absent or malformed.
export function psiAvg10(text: string | null, which: "some" | "full"): number | null {
  if (text === null) return null;
  const line = text.split("\n").find((l) => l.startsWith(`${which} `));
  const raw = line?.match(/\bavg10=([0-9]+(?:\.[0-9]+)?)/)?.[1];
  if (raw === undefined) return null;
  const value = parseF64(raw);
  return value === null || !Number.isFinite(value) || value < 0 ? null : value;
}

/// What Linux `/proc/pressure/memory` (PSI) says of memory pressure: `MemAvailable` counts active file cache that is
/// refaulting under thrashing, so a swapless Linux station can freeze in direct reclaim and hit the kernel OOM killer
/// while `MemAvailable` stays between 4% and 10% (2026-11-25: pvg-office-1 hit 41-71% `full` stall and OOM-killed the
/// station while `MemAvailable` stayed in `high`). When `available/total` is below `PSI_TIGHT_SHARE` (or unknown),
/// `full avg10` >= 10% is high and >= 20% is critical; >= 50% `full avg10` is critical unconditionally.
export const PSI_FULL_HIGH = 10;
export const PSI_FULL_CRITICAL = 20;
export const PSI_FULL_SEVERE = 50;
export const PSI_TIGHT_SHARE = 0.25;
export function pressureOfMemoryPsi(text: string | null, available: number | null = null, total: number | null = null): "normal" | "high" | "critical" | null {
  const full = psiAvg10(text, "full");
  if (full === null) return null;
  if (full >= PSI_FULL_SEVERE) return "critical";
  const tight = available === null || total === null || !(total > 0) || !(available >= 0) || available > total
    ? true
    : available / total < PSI_TIGHT_SHARE;
  if (!tight) return "normal";
  return full >= PSI_FULL_CRITICAL ? "critical" : full >= PSI_FULL_HIGH ? "high" : "normal";
}

const RANK = { normal: 0, high: 1, critical: 2 } as const;
/// The worse of two readings (one unknown: the other).
export function worsePressure(a: "normal" | "high" | "critical" | null, b: "normal" | "high" | "critical" | null): "normal" | "high" | "critical" | null {
  if (a === null) return b;
  if (b === null) return a;
  return RANK[a] >= RANK[b] ? a : b;
}

/// `vm_stat`'s "Swapouts" (pages swapped out since the machine started); null where it does not say.
export function swapoutsOf(vm: string | null): number | null {
  if (vm === null) return null;
  const m = vm.match(/^Swapouts:\s+(\d+)\.?\s*$/m);
  return m ? Number(m[1]) : null;
}

/// `sysctl -n vm.swapusage` ("total = 2048.00M  used = 657.06M  free = …"): the swap used (bytes); null where it does
/// not say.
export function swapUsedOf(text: string | null): number | null {
  const m = text?.match(/used = ([0-9.]+)M/);
  if (!m) return null;
  const mb = parseF64(m[1]!);
  return mb === null ? null : Math.round(mb * 1024 * 1024);
}

/// `ps -axo pid=,ppid=,pgid=,rss=,comm=`: each process with its resident memory (bytes).
export function parsePs(text: string): { pid: number; ppid: number; pgid: number; bytes: number; command: string }[] {
  const out: { pid: number; ppid: number; pgid: number; bytes: number; command: string }[] = [];
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s?(.*)$/);
    if (!m) continue;
    out.push({ pid: Number(m[1]), ppid: Number(m[2]), pgid: Number(m[3]), bytes: Number(m[4]) * 1024, command: trim(m[5] ?? "") });
  }
  return out;
}

/// `top -l 1 -stats pid,mem`: each process's footprint (bytes) as top says it (27M, 3056K, 1.2G, a + or - after it).
export function parseTopMem(text: string): Map<number, number> {
  const out = new Map<number, number>();
  const unit: Record<string, number> = { B: 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 };
  for (const line of text.split("\n")) {
    const m = line.match(/^\s*(\d+)\s+([\d.]+)([BKMGT])[+-]?\s*$/);
    if (m) out.set(Number(m[1]), Math.round(Number(m[2]) * unit[m[3]!]!));
  }
  return out;
}

/// The number after `label:` in `text` (vm_stat and /proc/meminfo); null if absent or unreadable.
export function fieldOrNull(text: string, label: string): number | null {
  for (const line of text.split("\n")) {
    if (!line.startsWith(`${label}:`)) continue;
    return parseU64(firstWord(trim(line.slice(label.length + 1)).replace(/\.+$/, "")));
  }
  return null;
}

/// proc_stat_ticks: CPU time from /proc/stat's first line; waiting on disks (iowait) counts as idle, as top counts it.
export function procStatTicks(stat: string): [busy: number, total: number] | null {
  const line = stat.split("\n").find((l) => l.startsWith("cpu "));
  if (line === undefined) return null;
  const v = splitWords(line).slice(1, 9).map(parseU64).filter((n): n is number => n !== null);
  if (v.length < 4) return null;
  const total = v.reduce((a, b) => a + b, 0);
  const idle = v[3]! + (v[4] ?? 0);
  return [total - idle, total];
}

/// lsof -Fn's names of the sockets listening at `port`: `n127.0.0.1:8085`, `n[::1]:8085`, `n*:8085` → the addresses.
export function parseLsof(text: string, port: number): string[] {
  const found: string[] = [];
  for (const line of text.split("\n")) {
    if (!line.startsWith("n")) continue;
    const name = line.slice(1).trim();
    const at = name.lastIndexOf(":");
    if (at < 0 || Number(name.slice(at + 1)) !== port) continue;
    const address = name.slice(0, at).replace(/^\[|\]$/g, "");
    if (!found.includes(address)) found.push(address);
  }
  return found;
}

/// How long the input has been idle (ms) by what `ioreg -c IOHIDSystem -r -k HIDIdleTime` says (its first
/// HIDIdleTime, in ns); none when it says none.
export function idleOfIoreg(text: string): number | null {
  const m = /"HIDIdleTime"\s*=\s*([0-9]+)/.exec(text);
  return m === null ? null : Number(m[1]) / 1e6;
}

/// The mount points `mount` lists (macOS: `<what> on <where> (<type>, <flags>)`) besides the machine's own volumes: its
/// root, the system's volumes under /System/Volumes, its devices.
export function parseMounts(out: string): string[] {
  const found: string[] = [];
  for (const line of out.split("\n")) {
    const at = / on (\/.*?) \([^()]*\)$/.exec(line)?.[1];
    if (at === undefined || at === "/" || at === "/dev" || at.startsWith("/System/Volumes/")) continue;
    found.push(at);
  }
  return found;
}

/// Whether a Linux kernel command line marks a Monoid Machine station VM (`monoid.vm=station` as a whole word).
export function isMonoidStationVm(cmdline: string): boolean {
  return splitWords(cmdline).includes("monoid.vm=station");
}

/// Whether `answer` is a well-formed dom0 elastic memory response (`boot`, `plugged`, `max` finite byte counts).
export function isDom0MemAnswer(answer: unknown): answer is { boot: number; plugged: number; max: number } {
  if (typeof answer !== "object" || answer === null) return false;
  const { boot, plugged, max } = answer as { boot?: unknown; plugged?: unknown; max?: unknown };
  return (
    typeof boot === "number" &&
    typeof plugged === "number" &&
    typeof max === "number" &&
    Number.isFinite(boot) &&
    Number.isFinite(plugged) &&
    Number.isFinite(max) &&
    boot > 0 &&
    plugged >= 0
  );
}

/// Applies dom0's elastic memory answer (`boot`, `plugged`, `max` in bytes) to meminfo memory: adds unplugged headroom
/// (`max - (boot + plugged)`) to `totalBytes` while keeping `usedBytes` and other fields unchanged.
export function elasticMemory<T extends { totalBytes: number; usedBytes: number; known?: boolean }>(memory: T, answer: unknown): T {
  if (memory.known === false || !isDom0MemAnswer(answer)) return memory;
  const held = answer.boot + answer.plugged;
  if (!(answer.max > held)) return memory;
  return { ...memory, totalBytes: memory.totalBytes + (answer.max - held) };
}
