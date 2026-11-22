// What the machine a station runs on looks like (GET /host), ported from the Rust station's host.rs: for people deciding
// where work goes and whether a station is struggling. How each machine is read (memory, CPU time, uptime, its OS) is
// the platform's (platform/: macOS's sysctl and vm_stat, Linux's /proc, what Node's os says on Windows), its commands and
// files not waited on; disk is the file system holding the station's data directory. Read on the main thread (the
// station's own memory is this process's) and kept here: given again within ten seconds, the CPU ticks last seen kept
// across reads. GET /host, the events' `host` samples and what other stations are told of this one's load
// (station_list, jobs/load.ts) share it. Once it has read the machine, nothing waits on it more than a moment
// (INFO_WAIT_MS, GPU_SAMPLE_MS): what was read last stands in for what is slow to come, which is kept when it comes. A
// busy machine's sysctl and ioreg took over a second, and station_list said the station's load unknown (2026-11-15).
import { statfs } from "node:fs/promises";
import { availableParallelism, hostname as osHostname, loadavg } from "node:os";
import type { Lang } from "../ops/i18n.ts";
import { wall } from "../ops/fibers.ts";
import { platform } from "../platform/index.ts";
import { cpuShare, type Ticks } from "../platform/cpu-share.ts";
import { type Gpu, Gpus } from "../jobs/gpu.ts";
import type { EgressLook } from "./egress.ts";

export type { Ticks };
/// The ticks last seen, and when.
export type Seen = { at: number; ticks: Ticks } | null;

/// hostname, without a `.local`.
function hostname(): string {
  const name = osHostname();
  return name.endsWith(".local") ? name.slice(0, -".local".length) : name;
}

/// cpu_busy: how busy the CPUs have been since the last look, if that was within a minute; otherwise over the next
/// moment. If they have not moved yet, return the first sample and let the caller ask again later.
async function cpuBusy(last: Seen): Promise<[busy: number | null, seen: Seen, needsTicks: boolean]> {
  const now = await platform.host.cpuTicks();
  const before = last !== null && wall.now() - last.at < 60_000 ? last.ticks : null;
  if (now === null) return [null, last, false];
  const busy = before === null ? null : cpuShare(before, now);
  return [busy === null ? null : Math.round(busy * 100) / 100, { at: wall.now(), ticks: now }, busy === null];
}

/// disk: the file system holding `path`: its size and what is free for the station.
async function disk(path: string) {
  try {
    const st = await statfs(path);
    return { path, totalBytes: st.blocks * st.bsize, freeBytes: st.bavail * st.bsize };
  } catch {
    return { path, totalBytes: 0, freeBytes: 0 };
  }
}

/// host_info (without its ten-second cache, which the caller keeps): the machine's state now, and the ticks seen.
export async function hostInfo(dataDir: string, last: Seen): Promise<{ info: any; seen: Seen; needsTicks: boolean }> {
  // The isolated app recording station must not put its host machine's identity and resource state in fixtures.
  if (process.env.STILLFAIL_TEST_HOST === "1") {
    return { info: {
      hostname: "test-station", os: "Test OS", arch: "arm64", cpus: 4, cpuModel: "Test CPU", load: 0.25,
      loadAvg: [1, 1, 1], cpuBusy: 0.25, uptimeSec: 3600,
      memory: { totalBytes: 8_000_000_000, usedBytes: 4_000_000_000, swapUsedBytes: 0 },
      disk: { path: "/test-station/data", totalBytes: 100_000_000_000, freeBytes: 50_000_000_000 },
      stationRssBytes: 100_000_000, checkedAt: wall.now(),
    }, seen: null, needsTicks: false };
  }
  const [sample, space, [busy, seen, needsTicks]] = await Promise.all([platform.host.sample(), disk(dataDir), cpuBusy(last)]);
  const n = availableParallelism();
  const info = {
    hostname: hostname(),
    os: sample.osName,
    arch: process.arch,
    cpus: n,
    cpuModel: sample.cpuModel,
    load: Math.round((loadavg()[0]! / Math.max(n, 1)) * 100) / 100,
    // The run queue over 1, 5 and 15 minutes as `uptime` says it (Windows has none: Node says zeros).
    loadAvg: platform.os === "windows" ? null : loadavg().map((l) => Math.round(l * 100) / 100),
    cpuBusy: busy,
    uptimeSec: sample.uptimeSec,
    memory: sample.memory,
    disk: space,
    stationRssBytes: sample.ownRss,
    // Clients from before the name need this field, and refuse the whole station list without it.
    emberRssBytes: sample.ownRss,
    checkedAt: wall.now(),
  };
  return { info, seen, needsTicks };
}

/// How often the CPUs' ticks are noted for their recent average, and over how long that is.
export const CPU_EVERY_MS = 15_000;
export const CPU_SPAN_MS = 60_000;

/// The CPUs' ticks noted every CPU_EVERY_MS for the last CPU_SPAN_MS or so: how busy they have been over about a minute
/// (not a moment's sample), on the main thread (the ticks are os.cpus, or /proc/stat read off it).
export class CpuWindow {
  private seen: { at: number; ticks: Ticks }[] = [];

  note(at: number, ticks: Ticks | null): void {
    if (ticks === null) return;
    this.seen.push({ at, ticks });
    // The oldest kept is the last one at least a span old, so a span is always covered once there has been one.
    while (this.seen.length > 1 && at - this.seen[1]!.at >= CPU_SPAN_MS) this.seen.shift();
  }

  /// The ticks noted last, for a read that would otherwise wait a moment to see them move.
  latest(): Seen {
    return this.seen.at(-1) ?? null;
  }

  /// How busy the CPUs have been since the oldest ticks noted (at most a span and a beat ago) until `ticks` now, and
  /// over how many seconds; null before there is anything to compare with (or the ticks have not moved).
  busy(at: number, ticks: Ticks | null): { busy: number; seconds: number } | null {
    const first = this.seen.find((s) => at - s.at <= CPU_SPAN_MS + CPU_EVERY_MS);
    if (ticks === null || first === undefined || at - first.at < 1000) return null;
    const [b0, t0] = first.ticks;
    const [b1, t1] = ticks;
    if (t1 <= t0) return null;
    return { busy: Math.round(Math.min(Math.max((b1 - b0) / (t1 - t0), 0), 1) * 100) / 100, seconds: Math.round((at - first.at) / 1000) };
  }
}

/// How long a read waits for a fresh look at the machine where it has one under STALE_MS old (a busy machine's commands
/// take seconds): then that one, the fresh one kept as it comes.
export const INFO_WAIT_MS = 400;
/// How old a look at the machine may be given while a fresh one is slow.
export const STALE_MS = 60_000;
/// How long a sample waits for the GPUs (their commands GPU_WAIT_MS each, jobs/gpu.ts) before it gives what they said
/// last, the new answer kept as it comes.
export const GPU_SAMPLE_MS = 400;

/// `what`, or `otherwise()` if it is not settled within `ms` (it goes on, nothing waiting on it: what it throws then
/// is taken here).
function soon<T>(what: Promise<T>, ms: number, otherwise: () => T): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    // timer: a deadline (a slow look at the machine stood in for by the last)
    const stop = wall.after(ms, () => resolve(otherwise()));
    what.then((v) => { stop(); resolve(v); }, (e) => { stop(); reject(e); });
  });
}

export class Host {
  private dataDir: string;
  readonly gpus: Pick<Gpus, "read"> & { cached?(): Gpu[] | null };
  private cached: { at: number; info: any } | null = null;
  private seen: Seen = null;
  private reading: Promise<any> | null = null;
  private sampling: Promise<any> | null = null;
  private cpu = new CpuWindow();

  private read: typeof hostInfo;
  private egress: Pick<EgressLook, "now" | "follow"> | null;

  /// `dataDir`: where the station keeps its data (the disk it is on is said); `read`, how the machine is read;
  /// `egress`, where its traffic is seen leaving for the internet (api/egress.ts; none: not said).
  constructor(dataDir: string, gpus: Pick<Gpus, "read"> & { cached?(): Gpu[] | null } = new Gpus(), read: typeof hostInfo = hostInfo, egress: Pick<EgressLook, "now" | "follow"> | null = null) {
    this.dataDir = dataDir;
    this.gpus = gpus;
    this.read = read;
    this.egress = process.env.STILLFAIL_TEST_HOST === "1" ? null : egress;
  }

  /// Notes the CPUs' ticks now and every CPU_EVERY_MS after, until the returned function is called. Ticks read off the
  /// main thread (/proc/stat) are noted as they come, one read at a time: a beat that finds one still out lets it be,
  /// and one that comes after the stop is not noted. Where its traffic leaves is followed as long (EgressLook.follow).
  follow(): () => void {
    const stopEgress = this.egress?.follow() ?? (() => {});
    let stopped = false;
    let reading = false;
    const note = () => {
      if (reading) return;
      const ticks = platform.host.cpuTicks();
      if (!(ticks instanceof Promise)) return this.cpu.note(wall.now(), ticks);
      reading = true;
      void ticks.then((read) => { if (!stopped) this.cpu.note(wall.now(), read); }, () => {}).finally(() => (reading = false));
    };
    note();
    const stop = wall.every(CPU_EVERY_MS, note); // timer: a sample of this machine (its CPUs)
    return () => {
      stopped = true;
      stop();
      stopEgress();
    };
  }

  /// How busy the CPUs have been over about the last minute (follow), null until it has looked twice.
  async recentBusy(): Promise<{ busy: number; seconds: number } | null> {
    const ticks = await platform.host.cpuTicks();
    return this.cpu.busy(wall.now(), ticks);
  }

  /// The machine sample and its GPUs, one at a time however many ask. GPU failures do not prevent the other
  /// measurements from being shown, nor do slow GPU commands hold them up: past GPU_SAMPLE_MS the GPUs said last.
  sample(lang: Lang = "zh"): Promise<any> {
    this.sampling ??= Promise.all([
      this.info(lang),
      process.env.STILLFAIL_TEST_HOST === "1"
        ? Promise.resolve([{ name: "Test GPU", cores: 4, busy: 0.25 }])
        : soon(this.gpus.read().catch(() => null), GPU_SAMPLE_MS, () => this.gpus.cached?.() ?? null),
    ])
      .then(([info, gpus]) => {
        const egress = this.egress?.now() ?? null;
        return egress === null ? { ...info, gpus } : { ...info, gpus, egress };
      })
      .finally(() => (this.sampling = null));
    return this.sampling;
  }

  /// At most ten seconds old; one read at a time however many ask. Where it read one under STALE_MS old, a read that
  /// takes over INFO_WAIT_MS gives that one meanwhile.
  private info(lang: Lang): Promise<any> {
    if (this.cached !== null && wall.now() - this.cached.at < 10_000) return Promise.resolve(this.cached.info);
    const stale = this.cached !== null && wall.now() - this.cached.at < STALE_MS ? this.cached.info : null;
    const reading = this.fresh();
    return stale === null ? reading : soon(reading, INFO_WAIT_MS, () => stale);
  }

  /// A fresh look at the machine, kept (`cached`) as it comes; one at a time however many ask.
  private fresh(): Promise<any> {
    // Ticks the last read saw over a minute ago would make it wait a moment for them to move: those followed are newer.
    const last = this.seen !== null && wall.now() - this.seen.at < 60_000 ? this.seen : (this.cpu.latest() ?? this.seen);
    this.reading ??= this.read(this.dataDir, last)
      .then(async (parsed) => {
        const { info, needsTicks } = parsed;
        let { seen } = parsed;
        if (needsTicks && seen !== null) {
          // macOS can leave ticks unchanged for 500 ms or more: wait, then look at the ticks alone. As before, give up
          // after two seconds.
          const first = seen.ticks;
          const start = wall.now();
          await wall.sleep(500);
          for (;;) {
            const ticks = await platform.host.cpuTicks();
            if (ticks === null) { seen = last; break; }
            const busy = cpuShare(first, ticks);
            if (busy !== null) {
              info.cpuBusy = Math.round(busy * 100) / 100;
              seen = { at: wall.now(), ticks };
              break;
            }
            if (wall.now() - start >= 2_000) { seen = last; break; }
            await wall.sleep(100);
          }
          info.checkedAt = wall.now();
        }
        this.seen = seen;
        this.cached = { at: info.checkedAt, info };
        return info;
      })
      .finally(() => (this.reading = null));
    return this.reading;
  }
}
