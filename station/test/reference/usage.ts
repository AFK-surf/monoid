// The TypeScript reads the station answered before its reader moved to the MoonBit program, kept for the tests
// to compare the program with; what the station itself still runs of it is station/src/read/usage.ts's.
//
// What the agents spent, as the usage page reads it (GET /usage): admin/views.rs `usage` over usage.rs `summary`,
// `price_table`, `price`, `cost` and store/usage.rs, with the same JSON field for field.
//
// The counting itself (src/usage/counter.ts, usage.rs `Usage::read`: the transcripts read into the `usage` table) is
// the running station's, not a read: what was counted is read here as it is in the database. `reading` is what the
// counter has in its memory (`readingAll`), given by the asker; not given, it is true (nothing read yet).
import { knownChannel, slackCreator } from "./slack-known.ts";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Lang } from "../../src/ops/i18n.ts";
import { type Json, STILLFAIL_SURFACE, type Store, REMOTE_RUNS_PENDING, USAGE_CHATS_PENDING, remoteRunCount, remoteRunsSince, sessionThreads, usageChatTotals, usageGroups, usageSince, usageThreads } from "./store.ts";
import { usageCardOutcomesComplete } from "../../src/store/usage-chat-stats.ts";
import { type InWorkspace, sees } from "../../src/store/rows.ts";
import { HISTORY_AFTER, HISTORY_DAYS, HISTORY_SCOPES, HISTORY_TOTAL, hasUsage15m, quarter, usage15mSince } from "../../src/store/usage-15m.ts";
import { shownTitleOf } from "./views.ts";
import { profileRuntimes } from "../../src/agents/profiles.ts";
import { log } from "../../src/ops/log.ts";
import { key as modelKey, splitAgyTier } from "../../../client/core-ts/src/shapes/model.ts";
import { STILLFAIL_CONNECT } from "../../src/store/rows.ts";
import { PRICES, price, cost } from "../../src/read/usage.ts";

export * from "../../src/read/usage.ts";
export { modelKey, splitAgyTier, PRICES, price, cost };

/// price_table: the very same prices `cost` uses, for inspecting a station's calculation from the usage page: those of the
/// station's own table and of the `models` its rows name.
export function priceTable(lang: Lang, models: (string | null)[] = []): Json {
  const keys = [...new Set([...PRICES.map(([model]) => model), ...models.flatMap((m) => (m === null ? [] : [modelKey(m).split("[")[0]!]))])];
  // (what the table's numbers mean said by the client: core-ts views/usage.ts)
  return {
    rows: keys.flatMap((model) => {
      const p = price(model);
      if (p === null) return [];
      return [{
        model, input: p.input, cacheRead: p.cacheRead,
        cacheWrite: model.startsWith("claude-") ? p.input * 1.25 : null,
        cacheWriteLong: model.startsWith("claude-") ? p.input * 2.0 : null, output: p.output,
      }];
    }),
  };
}

/// What a model is, however it is spelled (the core's, client/core-ts/src/shapes/model.ts `key`).

/// Usage::summary: every day's calls from `from` until `to`, by thread, person, profile and model (UsageRow).
function summary(s: Store, from: bigint, to: bigint, utcOffsetMin: bigint, viewer: InWorkspace | null): Json[] {
  return usageGroups(s, from, to, utcOffsetMin, viewer).map((g) => ({
    day: g.day, session: g.session, thread: g.thread, person: g.person, profile: g.profile, runtime: g.runtime, model: g.model,
    calls: g.calls, input: g.input, cacheRead: g.cacheRead, cacheWrite: g.cacheWrite + g.cacheWriteLong, output: g.output, cost: cost(g),
  }));
}

// ── the config's profiles (config.rs parse_config, what usage shows of them) ──

/// config.rs parse_config, the profiles' ids, names and runtimes: a name is trimmed (else the id); the runtime is the
/// first the account runs (runtimes_for), Claude's in name for one that runs neither. No config: none. An account no
/// longer in config.json (shared away, moved to another station) goes by the name it was known by as it went
/// (`<data>/move/accounts-known.json`, move/station.ts), with its runtime where that says one, so the calls it made
/// keep its name.
export function configProfiles(dataDir: string): Record<string, Json> {
  const out: Record<string, Json> = {};
  let raw: Json = null;
  try {
    raw = JSON.parse(readFileSync(join(dataDir, "config.json"), "utf8"));
  } catch {}
  for (const p of Array.isArray(raw?.profiles) ? raw.profiles : []) {
    if (typeof p?.id !== "string") continue;
    const runtimes = profileRuntimes({ id: p.id, home: "", runtime: p.runtime, access: p.access });
    const name = typeof p.name === "string" && p.name.trim() !== "" ? p.name.trim() : p.id;
    out[p.id] = { name, runtime: runtimes[0] ?? "claude" };
  }
  let known: Json = null;
  try {
    known = JSON.parse(readFileSync(join(dataDir, "move", "accounts-known.json"), "utf8"));
  } catch {}
  if (known !== null && typeof known === "object" && !Array.isArray(known)) {
    for (const [id, k] of Object.entries(known as Record<string, Json>)) {
      if (Object.hasOwn(out, id) || k === null || typeof k !== "object" || Array.isArray(k)) continue;
      if (typeof k.name !== "string" || k.name.trim() === "") continue;
      out[id] = { name: k.name.trim(), runtime: typeof k.runtime === "string" && k.runtime !== "" ? k.runtime : "claude" };
    }
  }
  return out;
}

// ── people (as views.ts has it) ──

/// A creator reference in words. No Slack connection knows anyone: a Slack user goes by their id, with no email.
function creator(s: Store, lang: Lang, reference: string): Json {
  if (reference === "local") return { id: "local", name: null, email: null, via: "local" };
  const slack = slackCreator(s, reference);
  if (slack !== null) return slack;
  return { id: reference, name: s.names.get(reference) ?? reference, email: reference, via: "cloud" };
}

/// Rust's String order (bytes of UTF-8), for a BTreeSet's.
const byBytes = (a: string, b: string) => Buffer.compare(Buffer.from(a), Buffer.from(b));

/// admin/views.rs `usage`: what the agents spent from `from` until `to` (ms), by day in the asker's time zone
/// (`utcOffsetMin`), with the threads, people and profiles the rows name. `from`/`to` are i64s, written as such.
/// `reading`: whether the counter is still reading everything for the first time (UsageCounter.readingAll). `viewer`:
/// only the calls of their workspace's chats (those of a session gone, where it was); all of them for a read made for
/// no one. `remoteFrom`: from when the tasks other stations' chats ran here are told (`from` where not given).
export function usage(s: Store, lang: Lang, from: bigint, to: bigint, utcOffsetMin: bigint, reading = true, viewer: InWorkspace | null = null, history = false,
  options: { remoteRuns?: boolean; remoteFrom?: bigint; historyRange?: { from: bigint; to: bigint }; metadata?: boolean } = {}): Json {
  const includeRemoteRuns = options.remoteRuns !== false;
  // A program's usage export needs the rows and their costs, but constructs its own people and does not send the
  // usage page's chat titles, price table or profile details.
  const includeMetadata = options.metadata !== false;
  const started = performance.now();
  const rows = summary(s, from, to, utcOffsetMin, viewer);
  const wanted = includeMetadata ? [...new Set(rows.map((r) => r.thread).filter((t): t is number => t !== null))] : [];
  const threads: Record<string, Json> = {};
  for (const [t, first] of usageThreads(s, wanted)) {
    // A Slack channel's name, as far as known (`known_channel`).
    const title = shownTitleOf(t, first, t.surface === STILLFAIL_SURFACE ? null : knownChannel(s, threadConnect(s, t.id), t.channel));
    threads[String(t.id)] = { title, surface: t.surface, home: t.home, archived: t.hiddenAt !== null };
  }
  const refs = includeMetadata ? [...new Set(rows.map((r) => r.person).filter((p): p is string => p !== null))].sort(byBytes) : [];
  const people: Record<string, Json> = {};
  for (const r of refs) people[r] = creator(s, lang, r);
  const i64 = (n: bigint) => (JSON as any).rawJSON(String(n));
  const since = usageSince(s);
  const detailSince = includeMetadata ? usage15mSince(s.db) : null;
  const prices = includeMetadata ? priceTable(lang, rows.map((r) => r.model)) : undefined;
  const profiles = includeMetadata ? configProfiles(s.dataDir) : undefined;
  // An older station may not have complete historical statistics. Leave the unavailable part absent so clients can
  // still show the complete details and distinguish missing history from an actual zero.
  let remoteRuns: Json | undefined = [];
  if (includeRemoteRuns) {
    try { remoteRuns = remoteRunsSince(s, options.remoteFrom ?? from, to, utcOffsetMin, viewer); }
    catch (error) {
      if (!(error instanceof Error) || error.message !== REMOTE_RUNS_PENDING) throw error;
      remoteRuns = undefined;
    }
  }
  const historyResult = history ? usageHistory(s, utcOffsetMin, viewer, options.historyRange) : null;
  const answer = {
    from: i64(from),
    to: i64(to),
    since,
    ...(detailSince !== null ? { detailSince } : {}),
    reading,
    ...(includeMetadata ? { prices } : {}),
    rows,
    ...(includeMetadata ? { threads, people, profiles } : {}),
    // the tasks the viewer's workspace's chats on other stations ran here (the card's 跨设备执行), a day and chat a
    // row: the workspace their key names (`remote:<workspace>:…`)
    ...(remoteRuns !== undefined ? { remoteRuns } : {}),
    ...(historyResult !== null ? { history: historyResult } : {}),
    ...(history && historyResult === null ? { historyUnavailable: true } : {}),
  };
  const ms = Math.round(performance.now() - started);
  if (ms >= 1_000) log.warn("readers", "a usage read went slowly", { ms, rows: rows.length });
  return answer;
}

/// What the viewer's chats did on this station since it began counting (the usage page's summary): the tokens by day
/// in the asker's time zone (`utcOffsetMin`) over the page's year (`requested`, ms: its first local midnight until the
/// one after today; absent, an older client's: every day), and in all before the year's end; the chats of each place
/// (still.fail's, Slack, Feishu) and how many were archived; the tasks other stations' chats ran here (one device's
/// chat working on another); the decision cards asked and those answered by an option pressed. GET /usage?history=1.
/// The tokens are read from each workspace's quarters (store/usage-15m.ts usage_quarter_totals): those of the year's
/// days and no more; in all, from its total (usage_scope_totals). `since`: from when the station counts every call
/// (ms; absent, from its first). Null where the quarters are not installed (a database no station of these opened).
export function validHistoryRange(requested: { from: bigint; to: bigint } | undefined, utcOffsetMin: bigint): boolean {
  const day = 86_400_000n;
  return requested !== undefined && requested.from <= requested.to && requested.to - requested.from <= 370n * day
    && requested.from % 60_000n === 0n && requested.to % 60_000n === 0n
    && (requested.to + utcOffsetMin * 60_000n) % day === 0n
    && requested.to + utcOffsetMin * 60_000n >= -8_640_000_000_000_000n
    && requested.to + utcOffsetMin * 60_000n <= 8_640_000_000_000_000n;
}

export function usageHistory(s: Store, utcOffsetMin: bigint, viewer: InWorkspace | null,
  requested?: { from: bigint; to: bigint }): Json | null {
  if (!hasUsage15m(s.db)) return null;
  const range = validHistoryRange(requested, utcOffsetMin) ? requested! : undefined;
  // Whose quarters the viewer sees (rows.ts `sees`): their workspace's, and the home one's ('') where it is theirs.
  const scopes = viewer === null ? (s.db.prepare(HISTORY_SCOPES).all() as Json[]).map((r) => String(r.scope))
    : viewer.home !== false ? [viewer.workspace, ""] : [viewer.workspace];
  const from = range === undefined ? -(2n ** 62n) : quarter(range.from);
  const to = range === undefined ? 2n ** 62n : quarter(range.to);
  const days = new Map<string, { day: string; runtime: string; model: null; tokens: number; calls: number }>();
  let tokens = 0;
  for (const scope of scopes) {
    for (const r of s.db.prepare(HISTORY_DAYS).all(scope, from, to, utcOffsetMin) as Json[]) {
      const d = days.get(r.day) ?? { day: r.day, runtime: "", model: null, tokens: 0, calls: 0 };
      d.tokens += Number(r.tokens);
      d.calls += Number(r.calls);
      days.set(r.day, d);
    }
    // In all before the year's end: the workspace's total, less what came after (a clock ahead; none, as a rule).
    if (range !== undefined) tokens += Number((s.db.prepare(HISTORY_TOTAL).get(scope) as Json)?.tokens ?? 0) - Number((s.db.prepare(HISTORY_AFTER).get(scope, to) as Json)?.tokens ?? 0);
  }
  const since = usage15mSince(s.db);
  // the chats of each place (still.fail's own, a Slack workspace's, a Feishu one's), those archived and the decision
  // cards, as their own statistics hold them (none said while those are still being filled)
  let chats: ReturnType<typeof usageChatTotals> | null = null;
  try { chats = usageChatTotals(s, viewer, { allowIncompleteCards: true }); }
  catch (error) { if (!(error instanceof Error) || error.message !== USAGE_CHATS_PENDING) throw error; }
  // the tasks the viewer's chats on other stations ran here, as long as they are kept (remote_runs: 90 days)
  let remoteRuns: number | null = null;
  try { remoteRuns = remoteRunCount(s, viewer); }
  catch (error) { if (!(error instanceof Error) || error.message !== REMOTE_RUNS_PENDING) throw error; }
  return {
    days: [...days.values()].sort((a, b) => (a.day < b.day ? -1 : a.day > b.day ? 1 : 0)),
    ...(range !== undefined ? { tokens, beforeDay: new Date(Number(range.to + utcOffsetMin * 60_000n)).toISOString().slice(0, 10) } : {}),
    ...(since !== null ? { since } : {}),
    ...(chats === null || !usageCardOutcomesComplete(s.db) ? { cardsIncomplete: true } : { cards: chats.cards, picked: chats.picked }),
    ...(chats === null ? { chatsIncomplete: true, places: {} } : { places: chats.places, archived: chats.archived }),
    ...(remoteRuns === null ? {} : { remoteRuns }),
  };
}

/// The chats of the resources page (GET /resources): each session's latest thread and its title; null for one `viewer` does
/// not see (another workspace's).
export function resourceChats(s: Store, sessions: string[], viewer: InWorkspace | null): Record<string, Json> {
  // A resource snapshot names a few running chats, not the station's entire history. Check each one's workspace by
  // its key rather than loading every session for each snapshot (which is refreshed repeatedly).
  const workspace = viewer === null ? null : s.db.prepare("SELECT ws FROM sessions WHERE key = ?");
  const out: Record<string, Json> = {};
  for (const key of sessions) {
    const ws = workspace?.get(key) as { ws: string | null } | undefined;
    if (viewer !== null && !sees(viewer, ws?.ws ?? null)) {
      out[key] = null;
      continue;
    }
    const thread = sessionThreads(s, key, null, 1)[0] ?? null;
    const [, first] = thread !== null ? (usageThreads(s, [thread.id])[0] ?? [thread, null]) : [null, null];
    const title = thread !== null ? shownTitleOf(thread, first, thread.surface === STILLFAIL_SURFACE ? null : knownChannel(s, threadConnect(s, thread.id), thread.channel)) : null;
    out[key] = { thread: thread?.id ?? null, title };
  }
  return out;
}

/// The connect a Slack thread came in through: the first of its sessions' that is not the station's own.
function threadConnect(s: Store, thread: number): string | null {
  const row = s.db.prepare(`SELECT connect FROM thread_sessions WHERE thread = ? AND connect != '${STILLFAIL_CONNECT}' ORDER BY joined_at, rowid LIMIT 1`).get(thread) as { connect: string } | undefined;
  return row?.connect ?? null;
}
