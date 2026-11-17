// The console's 中继 page (`adminRelays`): how loaded still.fail's relays are, from what still.fail cloud worked out of
// their counters (GET /v1/admin/relays, cloud/src/relay-load-view.ts): the numbers now, and a chart over a day or a week.
// And a card of the same shape for still.fail cloud's Directory, of what it counts of itself (cloud/src/directory.ts
// adminLoad): its calls an hour, all of them and by what they serve, the sockets still on it, its storage.
import * as format from "../format.ts";
import { t } from "../i18n.ts";
import { arr as arrU, get as getU } from "../util.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const arr = (v: unknown): J[] => arrU(v) ?? [];
const get = (v: unknown, k: string): J => getU(v, k);
const num = (v: unknown, k: string): number | null => (typeof get(v, k) === "number" && Number.isFinite(get(v, k)) ? get(v, k) : null);
const values = (v: unknown, k: string): (number | null)[] => arr(get(v, k)).map((x) => (typeof x === "number" && Number.isFinite(x) ? x : null));

/** Sampled within this long: shown as up. */
const FRESH = 300;
/** A share of packets dropped from which it is pointed at. */
const DROPPED_AMBER = 0.05;
const DROPPED_RED = 0.2;

export const RANGES = ["day", "week"] as const;
export type Range = (typeof RANGES)[number];

const rate = (bytes: number) => `${format.bytes(bytes)}/s`;
const percent = (share: number) => `${format.fixed1(share * 100)}%`;
const peak = (series: (number | null)[][]) => Math.max(0, ...series.flat().filter((v): v is number => v !== null));

/** Where its x axis is marked: every six hours over a day, every midnight over a week, in local time. */
function ticks(start: number, step: number, count: number, range: Range, offsetMin: number): { index: number; label: string }[] {
  const out: { index: number; label: string }[] = [];
  for (let i = 0; i < count; i++) {
    const ms = (start + i * step) * 1000;
    const [, month, day, , hour, minute] = format.local(ms, offsetMin);
    if (minute !== 0) continue;
    if (range === "day" && hour % 6 === 0) out.push({ index: i, label: format.clock(ms, offsetMin) });
    if (range === "week" && hour === 0) out.push({ index: i, label: `${month}/${day}` });
  }
  return out;
}

/** A URL as compared: without a trailing slash (cloud/src/relays.ts sameUrl). */
const same = (url: string) => url.replace(/\/+$/, "");
const host = (url: string) => (URL.canParse(url) ? new URL(url).host : url);

/** What the operator does with a relay (the cloud's list, cloud/src/relay-registry.ts relayList): whether it can be
 * taken off (the cloud's own cannot), how it came onto the list (its parts, each kept whole on a narrow page), and the
 * ways into it, each of which can be taken off. */
function keeping(url: string, registry: J) {
  if (registry === null || typeof registry !== "object") return { removable: false, how: null, entries: [] };
  const rows = arr(get(registry, "relays"));
  const row = rows.find((l) => typeof get(l, "url") === "string" && same(l.url) === same(url) && !get(l, "target"));
  const entries = rows
    .filter((l) => typeof get(l, "url") === "string" && typeof get(l, "target") === "string" && same(l.target) === same(url))
    .map((l) => ({ url: String(l.url), name: typeof get(l, "name") === "string" && l.name !== "" ? String(l.name) : host(String(l.url)), host: host(String(l.url)), target: url }));
  // The cloud's own is never taken off, though the operator named it (a row of its own on the list then).
  if (same(String(get(registry, "own") ?? "")) === same(url)) return { removable: false, how: [t("core-views.admin.relay.how.own")], entries };
  if (row === undefined) return { removable: false, how: null, entries };
  const by = String(get(row, "added_by") ?? "");
  const came = by === "config" ? t("core-views.admin.relay.how.config")
    : by === "admin-token" ? t("core-views.admin.relay.how.api")
    : by.startsWith("token") ? t("core-views.admin.relay.how.token")
    : by === "" ? null : t("core-views.admin.relay.how.by", { email: by });
  const how = [host(url), came, get(row, "enrolled") === true ? null : t("core-views.admin.relay.how.byAddress")].filter((x): x is string => x !== null);
  return { removable: true, how, entries };
}

/** The probes' networks, as the page groups them (cloud/src/probes.ts LOCATIONS): each carrier's, Hong Kong, China's other. */
const NETWORKS: [string, (line: J) => boolean][] = [
  ["mobile", (l) => /mobile/i.test(String(get(l, "probe_network") ?? ""))],
  ["telecom", (l) => /telecom|chinanet/i.test(String(get(l, "probe_network") ?? ""))],
  ["unicom", (l) => /unicom/i.test(String(get(l, "probe_network") ?? ""))],
  ["hk", (l) => get(l, "probe_country") === "HK"],
  ["cn", (l) => get(l, "probe_country") === "CN"],
];

/** What the latest probes found of a relay (cloud/src/relay-load.ts recordProbes): each network's round trip and loss, on average. */
function probed(r: J, now: number, offsetMin: number) {
  const p = get(r, "probes");
  const lines = arr(get(p, "lines"));
  const at = num(p, "at");
  if (lines.length === 0 || at === null) return undefined;
  const taken = new Set<J>();
  const items: { label: string; value: string; tone?: "amber" | "red" }[] = [];
  for (const [id, of] of NETWORKS) {
    const mine = lines.filter((l) => !taken.has(l) && of(l));
    for (const l of mine) taken.add(l);
    if (mine.length === 0) continue;
    const avg = (key: string) => {
      const v = mine.map((l) => num(l, key)).filter((x): x is number => x !== null);
      return v.length === 0 ? null : v.reduce((a, b) => a + b, 0) / v.length;
    };
    const rtt = avg("rtt_avg"), loss = avg("loss");
    const value = rtt === null ? t("core-views.admin.relay.probe.none") : loss !== null && loss > 0 ? t("core-views.admin.relay.probe.value_loss", { ms: Math.round(rtt), loss: format.fixed1(loss) }) : t("core-views.admin.relay.probe.value", { ms: Math.round(rtt) });
    const tone = rtt === null || (loss !== null && loss >= 20) ? "red" : (loss !== null && loss >= 5) || rtt >= 300 ? "amber" : undefined;
    items.push({ label: t(`core-views.admin.relay.probe.${id}`), value, ...(tone ? { tone } : {}) });
  }
  return { seen: t("core-views.admin.relay.probe.seen", { when: format.relativeTime(at * 1000, now * 1000, offsetMin) }), items };
}

function relay(r: J, range: Range, now: number, offsetMin: number, registry: J) {
  const url = String(get(r, "url") ?? ""), name = String(get(r, "name") ?? get(r, "url") ?? "");
  // (named anew from here where it is on the cloud's list as a relay of its own: the cloud's own too)
  const listed = registry !== null && typeof registry === "object" && (same(String(get(registry, "own") ?? "")) === same(url) || arr(get(registry, "relays")).some((l) => typeof get(l, "url") === "string" && same(l.url) === same(url) && !get(l, "target")));
  const kept = { ...keeping(url, registry), editable: listed };
  const at = num(r, "at");
  // Never heard from (its timer not set up yet): nothing to show but that.
  const probes = probed(r, now, offsetMin);
  if (at === null) return { url, name, ...kept, ...(probes ? { probes } : {}), state: "error", seen: t("core-views.admin.relay.never"), numbers: [], charts: [], ticks: [] };
  const state = now - at <= FRESH ? "online" : "offline";
  const seen = t("core-views.admin.relay.seen", { when: format.relativeTime(at * 1000, now * 1000, offsetMin) });
  const current = get(r, "now");
  const numbers: { label: string; value: string; tone?: "amber" | "red" }[] = [];
  const sent = num(current, "sent"), recv = num(current, "recv");
  numbers.push({ label: t("core-views.admin.relay.sent"), value: sent === null ? "–" : rate(sent) });
  numbers.push({ label: t("core-views.admin.relay.recv"), value: recv === null ? "–" : rate(recv) });
  const open = num(r, "open");
  numbers.push({ label: t("core-views.admin.relay.open"), value: open === null ? "–" : String(open) });
  const dropped = num(current, "dropped");
  numbers.push({
    label: t("core-views.admin.relay.dropped"),
    value: dropped === null ? "–" : percent(dropped),
    ...(dropped !== null && dropped >= DROPPED_RED ? { tone: "red" as const } : dropped !== null && dropped >= DROPPED_AMBER ? { tone: "amber" as const } : {}),
  });
  const rx = num(current, "rx"), tx = num(current, "tx");
  if (rx !== null && tx !== null) numbers.push({ label: t("core-views.admin.relay.card"), value: t("core-views.admin.relay.card_value", { out: rate(tx), in: rate(rx) }) });
  const load1 = num(r, "load1");
  if (load1 !== null) numbers.push({ label: t("core-views.admin.relay.load"), value: load1.toFixed(2) });
  // still.fail's own, held to a budget a day (cloud/src/relay.ts).
  const limits = get(r, "limits");
  const bytesLimit = num(limits, "bytes"), framesLimit = num(limits, "frames");
  if (bytesLimit !== null && framesLimit !== null) {
    const bytes = num(get(r, "today"), "bytes") ?? 0, frames = num(get(r, "today"), "frames") ?? 0;
    const used = Math.max(bytes / bytesLimit, frames / framesLimit);
    numbers.push({
      label: t("core-views.admin.relay.today"),
      value: t("core-views.admin.relay.today_value", { used: format.bytes(bytes), limit: format.bytes(bytesLimit), percent: Math.round(used * 100) }),
      ...(used >= 1 ? { tone: "red" as const } : used >= 0.8 ? { tone: "amber" as const } : {}),
    });
  }
  const s = get(r, range);
  const start = num(s, "start") ?? 0, step = num(s, "step") ?? 1;
  const sentSeries = values(s, "sent"), recvSeries = values(s, "recv"), openSeries = values(s, "open");
  const droppedSeries = values(s, "dropped");
  return {
    url,
    name,
    ...kept,
    ...(probes ? { probes } : {}),
    state,
    seen,
    numbers,
    charts: [
      {
        id: "rate",
        label: t("core-views.admin.relay.chart_rate"),
        peak: t("core-views.admin.relay.peak", { value: rate(peak([sentSeries, recvSeries])) }),
        series: [
          { id: "sent", label: t("core-views.admin.relay.sent"), values: sentSeries },
          { id: "recv", label: t("core-views.admin.relay.recv"), values: recvSeries },
        ],
      },
      {
        id: "open",
        label: t("core-views.admin.relay.open"),
        peak: t("core-views.admin.relay.peak", { value: String(peak([openSeries])) }),
        series: [{ id: "open", label: t("core-views.admin.relay.open"), values: openSeries }],
      },
      // The share of packets it dropped over the range (none charted where nothing was sampled).
      ...(droppedSeries.some((v) => v !== null) ? [{
        id: "dropped",
        label: t("core-views.admin.relay.dropped"),
        peak: t("core-views.admin.relay.peak", { value: percent(peak([droppedSeries])) }),
        series: [{ id: "dropped", label: t("core-views.admin.relay.dropped"), values: droppedSeries.map((v) => (v === null ? null : v * 100)) }],
      }] : []),
    ],
    ticks: ticks(start, step, sentSeries.length, range, offsetMin),
  };
}

/** What the Directory's calls serve, in the order they are charted (cloud/src/directory.ts FAMILIES). */
const FAMILIES = ["workspaces", "me", "signin", "sockets", "stations", "push", "beta", "broadcast", "admin", "other"];

/** The Directory's card: its calls over the last day or week (an hour a point), and what it holds now. */
function directory(d: J, range: Range, now: number, offsetMin: number) {
  const calls = get(d, "calls");
  const step = num(calls, "step") ?? 3600;
  const hours = range === "day" ? 24 : 7 * 24;
  const families = get(calls, "families");
  const total = Math.max(0, ...FAMILIES.map((id) => values(families, id).length));
  const sum = (v: (number | null)[]) => v.reduce<number>((n, x) => n + (x ?? 0), 0);
  // Those with calls in what is shown, the most first: a chart each, as ten lines in one cannot be told apart.
  const series = FAMILIES.map((id) => ({ id, label: t(`core-views.admin.directory.family.${id}`), values: values(families, id).slice(-hours) }))
    .filter((f) => sum(f.values) > 0)
    .sort((a, b) => sum(b.values) - sum(a.values));
  const shown = Math.min(hours, total);
  /** All of its calls in each hour: what the object carries. */
  const all = Array.from({ length: shown }, (_, i) => sum(series.map((f) => f.values[i] ?? null)));
  const lastHour = all.at(-1) ?? 0;
  const chart = (id: string, label: string, v: (number | null)[]) => ({ id, label, peak: t("core-views.admin.relay.peak", { value: String(peak([v])) }), series: [{ id, label, values: v }] });
  const start = (num(calls, "start") ?? now) + Math.max(0, total - hours) * step;
  const devices = num(get(d, "held"), "devices") ?? 0, stations = num(get(d, "held"), "stations") ?? 0;
  const at = num(d, "at");
  return {
    url: "directory",
    name: t("core-views.admin.directory.name"),
    removable: false,
    editable: false,
    how: null,
    entries: [],
    state: at !== null && now - at <= FRESH ? "online" : "offline",
    seen: at === null ? t("core-views.admin.relay.never") : t("core-views.admin.relay.seen", { when: format.relativeTime(at * 1000, now * 1000, offsetMin) }),
    numbers: [
      { label: t("core-views.admin.directory.calls"), value: String(lastHour) },
      // Those from before their objects: none once every device and station has reconnected.
      { label: t("core-views.admin.directory.held"), value: t("core-views.admin.directory.held_value", { devices, stations }), ...(devices + stations > 0 ? { tone: "amber" as const } : {}) },
      { label: t("core-views.admin.directory.live"), value: t("core-views.admin.directory.live_value", { accounts: num(get(d, "live"), "accounts") ?? 0, stations: num(get(d, "live"), "stations") ?? 0 }) },
      { label: t("core-views.admin.directory.waiting"), value: String(num(d, "waiting") ?? 0), ...((num(d, "waiting") ?? 0) > 0 ? { tone: "amber" as const } : {}) },
      { label: t("core-views.admin.directory.storage"), value: format.bytes(num(d, "bytes") ?? 0) },
    ],
    charts: [chart("calls", t("core-views.admin.directory.chart"), all), ...series.map((f) => chart(f.id, f.label, f.values))],
    ticks: ticks(start, step, shown, range, offsetMin),
  };
}

/** A relay's name as the page lists it, by its URL (its host where it has none). */
function nameOn(v: J, url: string): string {
  const r = arr(get(v, "relays")).find((x) => typeof get(x, "url") === "string" && same(x.url) === same(url));
  return r !== undefined && typeof get(r, "name") === "string" && r.name !== "" ? String(r.name) : host(url);
}

/** The page, from what /v1/admin/relays answered; `now` in seconds. */
export function relays(v: J, range: string | null, now: number, offsetMin: number) {
  const shown: Range = range === "week" ? "week" : "day";
  const d = get(v, "directory");
  // (a still.fail cloud from before says nothing of its list: nothing to keep from here then)
  const registry = get(v, "registry");
  const listed = registry !== null && typeof registry === "object";
  return {
    range: shown,
    ranges: RANGES.map((id) => ({ id, label: t(`core-views.admin.relay.range.${id}`) })),
    manage: listed,
    // The tokens made for relays not used yet: what each will be called, at what URL, till when.
    tokens: arr(get(registry, "tokens")).map((k, i) => {
      const at = num(k, "expires_at");
      const where = typeof get(k, "url") === "string" ? host(String(k.url)) : t("core-views.admin.relay.token.anyUrl");
      // An entry's: what relay it is a way into, by that relay's name.
      const target = typeof get(k, "target") === "string" ? String(k.target) : null;
      const into = target === null ? null : t("core-views.admin.relay.token.entry", { name: nameOn(v, target) });
      const parts = [into, where, at === null ? null : t("core-views.admin.relay.token.expires", { until: format.timeUntil(at * 1000, now * 1000) })].filter((x): x is string => x !== null);
      return { key: `${i}:${String(get(k, "name") ?? "")}`, id: typeof get(k, "id") === "string" ? String(k.id) : null, name: String(get(k, "name") ?? ""), line: parts.join(" · ") };
    }),
    // (a still.fail cloud from before says nothing of its Directory)
    relays: [...arr(get(v, "relays")).map((r) => relay(r, shown, now, offsetMin, registry)), ...(d !== null && typeof d === "object" ? [directory(d, shown, now, offsetMin)] : [])],
  };
}
