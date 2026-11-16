// The Profile overview's pools (the `profilesOverview` view): the workspace's subscriptions put together by the models
// they serve (Claude, Fable, Codex, Gemini and each other vendor's), each pool's allowance left as a share of what all
// its accounts hold, hour by hour from two days back to a week on, and how fast it goes, an hour at a time.
//
// The past is each account's own hours as its stations kept them (GET /profiles/pace, station accounts/pace.ts): what
// its allowance said at each hour, and between those what its calls spent hour by hour, so an hour nobody worked is
// flat and one an agent ran in falls; before a station kept hours, the window's percent used so far spread over its
// hours by what they spent (evenly where nothing was counted). The future is an hourly simulation: each hour's demand
// leans from the last hours' pace (an exponential weighting) to the week's, shaped by the hour of the day people work
// at, and is taken from the account whose week resets soonest that has room in both its week and its five hours; a
// week refills at its reset, five hours at theirs, and what no account can take is the pool going without.
const HOUR_MS = 3_600_000;

// deno-lint-ignore no-explicit-any
type J = any;

/// The hours drawn back from now, and on.
export const PAST_HOURS = 48;
export const FUTURE_HOURS = 168;
/// How far back a pool's pace is read (the station keeps 192 hours).
const HISTORY_HOURS = 168;
/// The hours a pace is weighed over, and the decay of their weights (an hour `a` back weighs e^(-a/τ)).
const RECENT_HOURS = 12;
const RECENT_TAU = 6;
/// How fast the demand leans from the last hours' pace to the week's (`w = e^(-h/LEAN_HOURS)`).
const LEAN_HOURS = 12;
/// The day's shape: each hour's share of the day against an even prior of so many hours of each (two days), held
/// between these.
const DIURNAL_PRIOR = 2;
const DIURNAL_MIN = 0.25;
const DIURNAL_MAX = 2.4;
/// What a full five hours is of its week, in percent, where an account's hours do not tell (about eight a week).
const SHORT_OF_LONG = 12;

export type OverviewPool = {
  title: string;
  ready: number;
  total: number;
  nowPct: number;
  exhaustHours: number | null;
  currentBurnPerHour: number;
  sustainablePerHour: number;
  /// What it spends an hour now against what it could (sustainablePerHour − currentBurnPerHour, %/h): over it, or going
  /// without within the week, negative.
  netPerHour: number;
  overPace: boolean;
  /// The pool's percent left (whole), an hour apart: PAST_HOURS back (0) to now (PAST_HOURS) to FUTURE_HOURS on.
  traj: number[];
  /// The hours on it goes without, as spans: each pair the first hour (0: the next) and the one after the last.
  starveSpans: number[];
  /// Each hour's pace against what it could keep up (sustainablePerHour − what it spent, %/h, to a tenth): the last 24
  /// (0..23), then the next 24 as foreseen (24..47), what it would ask of them (an hour going without, negative).
  hourlyNet: number[];
};

/// One window of an account's allowance, as its station or an hour of it says it.
type Win = { label: string; scope: string; used: number; resetsAt: number | null; minutes: number | null; mark: string };
type Kind = "long" | "short";
/// An hour an account's allowance was read in: when, and its windows.
type Snap = { at: number; windows: Win[] };
/// An account's hours as its stations said them (members' together: a borrowed account's calls spend the same).
type Hours = { snaps: Snap[]; spend: Map<string, Map<number, number>> };

/// An account as a pool takes it.
type Slot = {
  weight: number;
  broken: boolean;
  ready: boolean;
  long: Win | null;
  short: Win | null;
  /// Not to be used before this many hours on (Fable's while its account's week is spent).
  lockedHours: number;
  /// What its calls count against (a window's `scope`; "" the account's own).
  scope: string;
  hours: Hours;
};

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown): string => (typeof v === "string" ? v : "");
const isObject = (v: unknown): v is Record<string, J> => v !== null && typeof v === "object" && !Array.isArray(v);
const round = (v: number, places: number) => {
  const f = 10 ** places;
  const r = Math.round(v * f) / f;
  // (never -0: it goes out as 0 and comes back 0, a value that would not be the one it was)
  return r === 0 ? 0 : r;
};
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

function winOf(w: J): Win | null {
  if (!isObject(w)) return null;
  // (as a station said it, or as the list's rows keep it: what is left, whole percent)
  const left = num(w.left);
  const used = num(w.usedPercent) ?? (left === null ? null : 100 - left);
  if (used === null) return null;
  return { label: str(w.label), scope: str(w.scope), used: clamp(used, 0, 100), resetsAt: num(w.resetsAt), minutes: num(w.minutes), mark: str(w.mark) };
}

/// Whether a window is a week's (or a month's) or a few hours'.
function kindOf(w: Win): Kind {
  if (w.minutes !== null) return w.minutes >= 1440 ? "long" : "short";
  if (w.mark === "W" || w.mark === "M") return "long";
  if (w.mark === "5H" || w.mark === "2H" || w.mark === "3D") return "short";
  const l = w.label.toLowerCase();
  if (l.includes("小时") || l.includes("hour") || /\b\d+h\b/.test(l)) return "short";
  return "long";
}

/// A long window's cycle in hours.
function cycleOf(w: Win): number {
  if (w.minutes !== null && w.minutes >= 1440) return w.minutes / 60;
  const l = w.label.toLowerCase();
  return w.mark === "M" || l.includes("每月") || l.includes("month") ? 720 : 168;
}
const shortHoursOf = (w: Win) => (w.minutes !== null && w.minutes > 0 && w.minutes < 1440 ? w.minutes / 60 : 5);

const find = (ws: Win[], scope: string, kind: Kind) => ws.find((w) => w.scope === scope && kindOf(w) === kind) ?? null;

function windowsOf(item: J): Win[] {
  const q = item?.profile?.quota;
  if (!isObject(q) || q.state !== "ok") return [];
  return [...(Array.isArray(q.windows) ? q.windows : []), ...(Array.isArray(q.scoped) ? q.scoped : [])].flatMap((w) => winOf(w) ?? []);
}

const needsFix = (item: J) => item?.look === true || item?.state?.tone === "red" || item?.profile?.checkTone === "red";

/// How much of a pool an account is, by its plan (a Max 20x Claude twenty of a Pro's).
function planWeight(item: J): number {
  const g = str(item?.group);
  const plan = str(item?.profile?.planText);
  if (g === "claude") return plan.includes("20x") ? 20 : plan.includes("5x") ? 5 : 1;
  if (g === "chatgpt") return plan.includes("200") || plan.includes("Pro") ? 10 : plan.includes("Team") ? 2 : 1;
  if (g === "agy") return plan.includes("Ultra") ? 5 : 1;
  return 1;
}

/// An account's hours read as a station said them, kept by what it said (the same object until it is read again: the
/// pools made again as an account's row changes read none of them anew).
const snapsRead = new WeakMap<object, Snap[]>();
function snapsOf(quotas: J[]): Snap[] {
  const kept = snapsRead.get(quotas);
  if (kept !== undefined) return kept;
  const snaps: Snap[] = [];
  for (const q of quotas) {
    const at = num(q?.at);
    if (at === null) continue;
    snaps.push({ at, windows: (Array.isArray(q.windows) ? q.windows : []).flatMap((w: J) => winOf(w) ?? []) });
  }
  snapsRead.set(quotas, snaps);
  return snaps;
}

/// An account's hours, its members' together (each station's of its profile there).
function hoursOf(item: J, pace: (station: string) => J): Hours {
  const snaps: Snap[] = [];
  const spend = new Map<string, Map<number, number>>();
  let most = -1;
  for (const m of Array.isArray(item?.members) ? item.members : []) {
    const said = pace(str(m?.station))?.profiles?.[str(m?.profileId)];
    if (!isObject(said)) continue;
    // (the allowance as the member that read it most often kept it: each reads the same account)
    const quotas = Array.isArray(said.quotas) ? said.quotas : [];
    if (quotas.length > most) {
      most = quotas.length;
      snaps.length = 0;
      snaps.push(...snapsOf(quotas));
    }
    for (const s of Array.isArray(said.spend) ? said.spend : []) {
      const hour = num(s?.hour);
      const weight = num(s?.weight);
      if (hour === null || weight === null || weight <= 0) continue;
      const byHour = spend.get(str(s.scope)) ?? new Map<number, number>();
      byHour.set(hour, (byHour.get(hour) ?? 0) + weight);
      spend.set(str(s.scope), byHour);
    }
  }
  snaps.sort((a, b) => a.at - b.at);
  return { snaps, spend };
}

type PoolSpec = { title: string; slots: Slot[] };

/// A window as the list's rows keep it (what is left, whole; no length) made exact by its account's hour kept within
/// the last two (the same window, the same left): its length and its percent as read. None kept: as the row has it.
function exact(w: Win | null, hours: Hours, now: number): Win | null {
  if (w === null || w.minutes !== null) return w;
  for (let i = hours.snaps.length - 1; i >= 0; i--) {
    const snap = hours.snaps[i]!;
    if (snap.at < now - 2 * HOUR_MS) break;
    const sw = snap.windows.find((x) => x.scope === w.scope && kindOf(x) === kindOf(w) && Math.round(100 - x.used) === Math.round(100 - w.used));
    if (sw !== undefined) return { ...w, minutes: sw.minutes, used: sw.used };
  }
  return w;
}

function slot(item: J, hours: Hours, now: number, scope: string, long: Win | null, short: Win | null, o: { weight?: number; lockedHours?: number; usable?: boolean } = {}): Slot {
  const broken = needsFix(item) || item?.profile?.quota?.state === "blocked";
  const usable = o.usable ?? item?.usable === true;
  const lockedHours = o.lockedHours ?? 0;
  const ready = !broken && usable && (long === null || long.used < 100) && (short === null || short.used < 100) && lockedHours <= 0;
  return { weight: o.weight ?? planWeight(item), broken, ready, long: exact(long, hours, now), short: exact(short, hours, now), lockedHours, scope, hours };
}

/// Each pool's accounts.
function poolSpecs(items: J[], pace: (station: string) => J, now: number): PoolSpec[] {
  const hours = new Map<J, Hours>(items.map((i) => [i, hoursOf(i, pace)]));
  const h = (i: J) => hours.get(i)!;
  const main = (i: J): [Win | null, Win | null] => {
    const ws = windowsOf(i);
    return [find(ws, "", "long"), find(ws, "", "short")];
  };
  const groupOf = (i: J) => str(i?.group);
  const agyPart = (i: J, scope: string) => {
    const ws = windowsOf(i);
    return [find(ws, scope, "long"), find(ws, scope, "short")] as const;
  };
  const specs: PoolSpec[] = [];
  const claudeLike = (group: string, title: string) => {
    const slots: Slot[] = [];
    for (const i of items) {
      if (groupOf(i) === group) {
        const [long, short] = main(i);
        slots.push(slot(i, h(i), now, "", long, short));
      } else if (groupOf(i) === "agy") {
        const [long, short] = agyPart(i, "Claude / GPT");
        if (long !== null) slots.push(slot(i, h(i), now, "Claude / GPT", long, short));
      }
    }
    specs.push({ title, slots });
  };
  claudeLike("claude", "Claude");
  // Fable: a model's own week, on accounts whose week of their own must have room too.
  const fable: Slot[] = [];
  for (const i of items) {
    const ws = windowsOf(i);
    const own = ws.find((w) => w.scope === "Fable" || w.scope === "fable") ?? null;
    if (own === null && !(groupOf(i) === "claude" && needsFix(i))) continue;
    const [week, short] = main(i);
    const locked = week !== null && week.used >= 100 ? Math.max(0, ((week.resetsAt ?? now) - now) / HOUR_MS) : 0;
    fable.push(slot(i, h(i), now, "Fable", own, short, { lockedHours: locked }));
  }
  if (fable.length > 0) specs.push({ title: "Fable", slots: fable });
  claudeLike("chatgpt", "Codex");
  const gemini: Slot[] = [];
  for (const i of items) {
    if (groupOf(i) !== "agy") continue;
    const [long, short] = agyPart(i, "Gemini");
    gemini.push(slot(i, h(i), now, "Gemini", long, short));
  }
  specs.push({ title: "Gemini", slots: gemini });
  for (const [group, title] of [["grok", "SuperGrok"], ["kimi", "Kimi Code"], ["opencode", "OpenCode Go"], ["cursor", "Cursor"], ["devin", "Devin"]] as const) {
    const slots = items.filter((i) => groupOf(i) === group).map((i) => {
      const [long, short] = main(i);
      return slot(i, h(i), now, "", long, short, { weight: 1 });
    });
    specs.push({ title, slots });
  }
  return specs.filter((s) => s.slots.length > 0);
}

/// An account's long window through the hours: its percent used `k` hours back (k = 0..HISTORY_HOURS), and in each hour
/// what it used (a reset's refill not counted).
type Past = { used: number[]; burn: number[]; known: number };

/// Its spending between two moments (hours from now, `a` < `b`), each hour's taken by how much of it falls between: of
/// running sums over the hours it may be asked of, made once (a reckoning asks it of every hour back, and of spans).
function spending(spend: Map<number, number> | undefined, nowHourF: number): (a: number, b: number) => number {
  if (spend === undefined || spend.size === 0) return () => 0;
  const first = Math.floor(nowHourF) - HISTORY_HOURS - 800;
  const n = Math.floor(nowHourF) - first + 2;
  const sums = new Array<number>(n + 1).fill(0);
  for (let i = 0; i < n; i++) sums[i + 1] = sums[i]! + (spend.get(first + i) ?? 0);
  const at = (x: number) => {
    const i = Math.floor(x) - first;
    if (i < 0) return 0;
    if (i >= n) return sums[n]!;
    return sums[i]! + (spend.get(first + i) ?? 0) * (x - Math.floor(x));
  };
  return (a, b) => (b <= a ? 0 : at(nowHourF + b) - at(nowHourF + a));
}

function pastOf(s: Slot, now: number): Past {
  const used = new Array<number>(HISTORY_HOURS + 1).fill(0);
  const burn = new Array<number>(HISTORY_HOURS).fill(0);
  const w = s.long;
  if (w === null) return { used, burn, known: 0 };
  const nowHourF = now / HOUR_MS;
  const spentBetween = spending(s.hours.spend.get(s.scope), now / HOUR_MS);
  const spend = s.hours.spend.get(s.scope);
  const cycle = cycleOf(w);
  const r = w.resetsAt !== null ? (w.resetsAt - now) / HOUR_MS : cycle / 2;
  // The end of the cycle a moment `t` (hours from now) is in.
  const endOf = (t: number) => r - cycle * Math.floor((r - t) / cycle);
  // What is known of it: each hour kept (of this window: its scope, its kind), and now.
  const points: { t: number; used: number; end: number }[] = [];
  for (const snap of s.hours.snaps) {
    const t = (snap.at - now) / HOUR_MS;
    if (t >= 0 || t < -HISTORY_HOURS - cycle) continue;
    const sw = snap.windows.find((x) => x.scope === w.scope && kindOf(x) === "long");
    if (sw === undefined) continue;
    const end = sw.resetsAt !== null ? (sw.resetsAt - now) / HOUR_MS : endOf(t);
    points.push({ t, used: sw.used, end });
  }
  points.push({ t: 0, used: w.used, end: endOf(0) });
  points.sort((a, b) => a.t - b.t);
  const sameCycle = (a: number, b: number) => Math.abs(a - b) < 3;
  const ofCycle = new Map<number, typeof points>();
  // Percent used per dollar spent and per hour, as this cycle went so far (what an hour of an earlier one without
  // points is reckoned by).
  const start0 = endOf(0) - cycle;
  const spentNow = spentBetween(start0, 0);
  const perDollar = spentNow > 0 ? w.used / spentNow : null;
  const perHour = w.used / Math.max(1, -start0);
  const along = (a: number, b: number, t: number) => {
    // How far a moment `t` is from `a` to `b`, by what was spent between (by the time where nothing was).
    const all = spentBetween(a, b);
    return all > 0 ? spentBetween(a, t) / all : b > a ? (t - a) / (b - a) : 1;
  };
  for (let k = 0; k <= HISTORY_HOURS; k++) {
    const t = -k;
    const end = endOf(t);
    const start = end - cycle;
    let mine = ofCycle.get(end);
    if (mine === undefined) {
      mine = points.filter((p) => sameCycle(p.end, end));
      ofCycle.set(end, mine);
    }
    // (points in order of time: the first at or after `t`, the last at or before it)
    const newer = mine.find((p) => p.t >= t);
    let older: (typeof points)[number] | undefined;
    for (const p of mine) if (p.t <= t) older = p;
    let u: number;
    if (newer !== undefined && older !== undefined) {
      u = newer.t === older.t ? newer.used : older.used + (newer.used - older.used) * along(older.t, newer.t, t);
    } else if (newer !== undefined) {
      // (before the first hour kept of this cycle: from nothing at its start)
      u = newer.used * along(start, newer.t, t);
    } else if (older !== undefined) {
      const more = perDollar !== null ? perDollar * spentBetween(older.t, t) : perHour * (t - older.t);
      u = older.used + more;
    } else {
      u = perDollar !== null ? perDollar * spentBetween(start, t) : perHour * (t - start);
    }
    used[k] = clamp(u, 0, 100);
  }
  for (let k = 1; k <= HISTORY_HOURS; k++) {
    // The hour from k back to k - 1: what it used, a refill between them not counted.
    const reset = !sameCycle(endOf(-k), endOf(-(k - 1)));
    burn[k - 1] = Math.max(0, reset ? used[k - 1]! : used[k - 1]! - used[k]!);
  }
  // How far back what it says is the account's own, not a reckoning: its first hour kept or counted, or its cycle's start.
  const firstSnap = points.length > 1 ? -points[0]!.t : 0;
  let firstSpend = 0;
  if (spend !== undefined) for (const hour of spend.keys()) firstSpend = Math.max(firstSpend, nowHourF - hour);
  const known = Math.min(HISTORY_HOURS, Math.max(firstSnap, firstSpend, w.used > 0 ? -start0 : 0));
  return { used, burn, known };
}

/// Whether an account's five hours were spent `k` hours back, as its kept hours say (none kept: not).
function shortSpentAt(s: Slot, now: number, k: number): boolean {
  if (s.short === null) return false;
  if (k === 0) return s.short.used >= 100;
  const t = now - k * HOUR_MS;
  let last: Win | null = null;
  for (const snap of s.hours.snaps) {
    if (snap.at > t) break;
    if (t - snap.at > 5 * HOUR_MS) continue;
    last = snap.windows.find((x) => x.scope === s.short!.scope && kindOf(x) === "short") ?? last;
  }
  return last !== null && last.used >= 100 && (last.resetsAt === null || last.resetsAt > t);
}

/// Percent of its week a full five hours of an account is, as its kept hours tell (what both rose by, hour to hour
/// within one of each), or SHORT_OF_LONG.
function shortOfLong(s: Slot): number {
  if (s.short === null || s.long === null) return SHORT_OF_LONG;
  let dl = 0;
  let ds = 0;
  for (let i = 1; i < s.hours.snaps.length; i++) {
    const a = s.hours.snaps[i - 1]!;
    const b = s.hours.snaps[i]!;
    const la = a.windows.find((x) => x.scope === s.long!.scope && kindOf(x) === "long");
    const lb = b.windows.find((x) => x.scope === s.long!.scope && kindOf(x) === "long");
    const sa = a.windows.find((x) => x.scope === s.short!.scope && kindOf(x) === "short");
    const sb = b.windows.find((x) => x.scope === s.short!.scope && kindOf(x) === "short");
    if (!la || !lb || !sa || !sb || lb.used < la.used || sb.used < sa.used || sa.resetsAt !== sb.resetsAt) continue;
    dl += lb.used - la.used;
    ds += sb.used - sa.used;
  }
  return ds >= 20 && dl > 0 ? clamp((dl / ds) * 100, 2, 100) : SHORT_OF_LONG;
}

/// An account in the simulation.
type Tank = {
  share: number;
  left: number;
  resetIn: number;
  cycle: number;
  lockedTill: number;
  short: { used: number; resetIn: number | null; hours: number; ofLong: number } | null;
};

function tanksOf(slots: Slot[], shares: number[], now: number): Tank[] {
  return slots.map((s, i) => {
    const share = shares[i]!;
    const cycle = s.long !== null ? cycleOf(s.long) : 168;
    let resetIn = s.long?.resetsAt != null ? (s.long.resetsAt - now) / HOUR_MS : cycle / 2;
    while (resetIn <= 0) resetIn += cycle;
    const left = s.long !== null ? (share * (100 - s.long.used)) / 100 : share;
    const short = s.short === null ? null : {
      used: s.short.used,
      resetIn: s.short.used > 0 && s.short.resetsAt !== null ? Math.max(0, (s.short.resetsAt - now) / HOUR_MS) : null,
      hours: shortHoursOf(s.short),
      ofLong: shortOfLong(s),
    };
    return { share, left, resetIn, cycle, lockedTill: s.lockedHours, short };
  });
}

/// Each hour on (1..FUTURE_HOURS) given `demand(h)`: what is left to use at its end, what was taken, what went
/// without.
function simulate(start: Tank[], demand: (h: number) => number): { avail: number[]; taken: number[]; unmet: number[] } {
  const tanks = start.map((t) => ({ ...t, short: t.short === null ? null : { ...t.short } }));
  const avail: number[] = [];
  const taken: number[] = [];
  const unmet: number[] = [];
  const order = tanks.map((_, i) => i);
  let reordered = true;
  for (let h = 1; h <= FUTURE_HOURS; h++) {
    for (const t of tanks) {
      if (t.resetIn <= h) {
        t.left = t.share;
        t.resetIn += t.cycle;
        reordered = true;
      }
      if (t.short !== null && t.short.resetIn !== null && t.short.resetIn <= h) {
        t.short.used = 0;
        t.short.resetIn = null;
      }
    }
    // (soonest week's refill first: its order changes only as one refills)
    if (reordered) order.sort((a, b) => tanks[a]!.resetIn - tanks[b]!.resetIn);
    reordered = false;
    let want = Math.max(0, demand(h));
    let took = 0;
    for (const i of order) {
      if (want <= 1e-9) break;
      const t = tanks[i]!;
      if (t.left <= 1e-9 || h <= t.lockedTill || t.share <= 0) continue;
      let room = t.left;
      if (t.short !== null) room = Math.min(room, ((100 - t.short.used) * t.share * t.short.ofLong) / 1e4);
      const take = Math.min(want, room);
      if (take <= 0) continue;
      t.left -= take;
      if (t.short !== null) {
        t.short.used = Math.min(100, t.short.used + (take * 1e4) / (t.share * t.short.ofLong));
        if (t.short.resetIn === null) t.short.resetIn = h - 1 + t.short.hours;
      }
      want -= take;
      took += take;
    }
    let a = 0;
    for (const t of tanks) if (h > t.lockedTill && (t.short === null || t.short.used < 99.9)) a += t.left;
    avail.push(a);
    taken.push(took);
    unmet.push(want);
  }
  return { avail, taken, unmet };
}

const starves = (s: { avail: number[]; unmet: number[] }, h: number) => s.unmet[h]! > 0.05 || s.avail[h]! <= 0.3;

function poolOf(spec: PoolSpec, now: number, offsetMin: number): OverviewPool {
  const total = spec.slots.length;
  const ready = spec.slots.filter((s) => s.ready).length;
  const active = spec.slots.filter((s) => !s.broken && s.weight > 0);
  const weight = active.reduce((a, s) => a + s.weight, 0);
  if (active.length === 0 || weight <= 0) {
    return {
      title: spec.title, ready: 0, total, nowPct: 0, exhaustHours: 0, currentBurnPerHour: 0, sustainablePerHour: 0, netPerHour: 0, overPace: true,
      traj: new Array(PAST_HOURS + 1 + FUTURE_HOURS).fill(0), starveSpans: [0, FUTURE_HOURS], hourlyNet: new Array(48).fill(0),
    };
  }
  const shares = active.map((s) => (s.weight / weight) * 100);
  const pasts = active.map((s) => pastOf(s, now));
  // The past: what each account had left, where it could be used then.
  const traj: number[] = [];
  for (let k = PAST_HOURS; k >= 1; k--) {
    let v = 0;
    active.forEach((s, i) => {
      if (shortSpentAt(s, now, k)) return;
      v += (shares[i]! * (100 - pasts[i]!.used[k]!)) / 100;
    });
    traj.push(clamp(v, 0, 100));
  }
  const tanks = tanksOf(active, shares, now);
  let nowAvail = 0;
  for (const t of tanks) if (t.lockedTill <= 0 && (t.short === null || t.short.used < 100)) nowAvail += t.left;
  traj.push(clamp(nowAvail, 0, 100));
  // What the pool spent each hour back (0: the last).
  const pastBurn: number[] = [];
  for (let j = 0; j < HISTORY_HOURS; j++) {
    let b = 0;
    active.forEach((_, i) => (b += (shares[i]! * pasts[i]!.burn[j]!) / 100));
    pastBurn.push(b);
  }
  // The last hours' pace, and the week's.
  let wsum = 0;
  let recent = 0;
  for (let j = 0; j < RECENT_HOURS; j++) {
    const wj = Math.exp(-j / RECENT_TAU);
    wsum += wj;
    recent += wj * pastBurn[j]!;
  }
  recent /= wsum;
  const known = Math.max(1, Math.round(Math.max(...pasts.map((p) => p.known))));
  const meanKnown = pastBurn.slice(0, known).reduce((a, b) => a + b, 0) / known;
  let cycleAvg = 0;
  active.forEach((s, i) => {
    if (s.long === null) return;
    const cycle = cycleOf(s.long);
    const r = s.long.resetsAt !== null ? (s.long.resetsAt - now) / HOUR_MS : cycle / 2;
    let left = r;
    while (left <= 0) left += cycle;
    while (left > cycle) left -= cycle;
    const elapsed = Math.max(1, cycle - left);
    cycleAvg += (shares[i]! * s.long.used) / 100 / elapsed;
  });
  const base = known >= 24 ? meanKnown : (known * meanKnown + (24 - known) * cycleAvg) / 24;
  // The day's shape, by the viewer's hours.
  const localHour = (ms: number) => (((Math.floor((ms + offsetMin * 60_000) / HOUR_MS) % 24) + 24) % 24);
  const sums = new Array<number>(24).fill(0);
  const counts = new Array<number>(24).fill(0);
  for (let j = 0; j < known; j++) {
    const lh = localHour(now - (j + 0.5) * HOUR_MS);
    sums[lh]! += pastBurn[j]!;
    counts[lh]! += 1;
  }
  const mean = known > 0 ? pastBurn.slice(0, known).reduce((a, b) => a + b, 0) / known : 0;
  let diurnal = sums.map((s, lh) => (mean > 0 ? clamp((s + DIURNAL_PRIOR * mean) / (counts[lh]! + DIURNAL_PRIOR) / mean, DIURNAL_MIN, DIURNAL_MAX) : 1));
  const dm = diurnal.reduce((a, b) => a + b, 0) / 24;
  diurnal = diurnal.map((d) => d / dm);
  const demand = (h: number) => {
    const w = Math.exp(-h / LEAN_HOURS);
    return w * recent + (1 - w) * base * diurnal[localHour(now + (h - 0.5) * HOUR_MS)]!;
  };
  const sim = simulate(tanks, demand);
  for (let h = 0; h < FUTURE_HOURS; h++) traj.push(clamp(sim.avail[h]!, 0, 100));
  const willStarve = sim.avail.map((_, h) => starves(sim, h));
  const first = willStarve.findIndex((x) => x);
  const exhaustHours = nowAvail <= 0.3 ? 0 : first >= 0 ? first + 1 : null;
  // The most it could spend an hour, evenly, and never go without for the week.
  // (no more than all it holds and gets back in the week spread over it: searched to a hundredth of a percent an hour)
  let held = 0;
  for (const t of tanks) held += t.left + t.share * Math.max(0, Math.floor((FUTURE_HOURS - t.resetIn) / t.cycle) + (t.resetIn <= FUTURE_HOURS ? 1 : 0));
  let lo = 0;
  let hi = held / FUTURE_HOURS + 0.01;
  while (hi - lo > 0.005) {
    const mid = (lo + hi) / 2;
    const s = simulate(tanks, () => mid);
    if (s.avail.some((_, h) => s.unmet[h]! > 0.05)) hi = mid;
    else lo = mid;
  }
  const sustainable = Math.max(0.01, lo);
  // Each hour against the pace it could keep up: the last 24 what was spent, the next 24 what they ask (taken or not:
  // an hour going without asks what it cannot have), one going without never at or over it.
  const hourlyNet: number[] = [];
  for (let j = 23; j >= 0; j--) hourlyNet.push(round(sustainable - pastBurn[j]!, 1));
  for (let h = 0; h < 24; h++) {
    const asked = sim.taken[h]! + sim.unmet[h]!;
    const net = sustainable - asked;
    hourlyNet.push(round(willStarve[h] && net >= -0.05 ? -Math.max(0.1, asked) : net, 1));
  }
  const starveSpans: number[] = [];
  for (let h = 0; h < FUTURE_HOURS; h++) {
    if (!willStarve[h] || (h > 0 && willStarve[h - 1])) continue;
    let end = h;
    while (end < FUTURE_HOURS && willStarve[end]) end++;
    starveSpans.push(h, end);
  }
  const overPace = recent > sustainable || exhaustHours !== null;
  // (over it, or going without within the week: said against the faster of now's pace and the week's, never above
  // -0.1, so it falls as either rises)
  const net = sustainable - recent;
  return {
    title: spec.title,
    ready,
    total,
    nowPct: Math.round(clamp(nowAvail, 0, 100)),
    exhaustHours,
    currentBurnPerHour: round(Math.max(0, recent), 2),
    sustainablePerHour: round(sustainable, 2),
    netPerHour: round(overPace ? Math.min(-0.1, sustainable - Math.max(recent, base)) : net, 1),
    overPace,
    traj: traj.map((v) => Math.round(v)),
    starveSpans,
    hourlyNet,
  };
}

/// The overview's pools of the workspace's accounts (`profilesWhole`'s items), with their stations' hours (`pace`,
/// by a station's address: what it said of GET /profiles/pace; nothing said, none), at `now` in the viewer's offset.
export function profilesOverview(items: J[], pace: (station: string) => J, now: number, offsetMin: number): { pools: OverviewPool[] } {
  return { pools: poolSpecs(items, pace, now).map((spec) => poolOf(spec, now, offsetMin)) };
}
