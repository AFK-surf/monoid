// What changed, for people (scripts/changelog.ts): the changelog CI makes from main's history (scripts/changelog.ts) and
// keeps in the releases bucket as changelog.json, with what each part has released on a channel, so a client can say
// what its version has and what is still to come. Bug reports an entry fixes (`Fixes: FB-<n>`) are marked fixed with
// it, and once the fix is out on the channel the report came on, the station that sent it is told (POST
// /v1/feedback/fixed), for its agent to tell the person who reported it.
import { readText, reply } from "./auth";
import { betaOrigin, header } from "./compat";
import type { Env } from "./env";
import { sharedRelease } from "./install.ts";
import { retryRead, unavailable, type ReleaseBucket } from "./releases";
import { stationSender } from "./tracing";

export type Part = "station" | "web" | "android" | "desktop" | "cloud";
export type Channel = "stable" | "beta";

/** One commit's lines (scripts/changelog.ts). */
export interface ChangelogEntry {
  version: number;
  commit: string;
  at: number;
  text: string[];
  fixes: number[];
  /** Empty: it needs no release. */
  parts: Part[];
}

/** The build each part has out on a channel (0.1.<n>: n), null where there is none to read. still.fail cloud is the one deployed: all of it. */
export type Released = Record<Exclude<Part, "cloud">, number | null>;

/** A fixed report, as its station is told it. */
export interface FixedReport {
  id: string;
  number: number;
  title: string;
  /** The version the fix came in, and the parts it is in, with what each has out on the report's channel. */
  version: number;
  parts: Part[];
  released: Released;
  /** The session and thread it was reported from (the station's context). */
  session: string | null;
  thread: string | null;
}

type PlatformReleases = Released & { macos: number | null; windows: number | null };

type Bucket = ReleaseBucket | undefined;

/**
 * Told of a file that could not be read, which is not one that is not there. Only logged where nobody asks: the reports'
 * marks (fixedFor, api.ts markFixed) go without it on purpose, as no entries unmark nothing and a station is told later.
 */
type Failed = (file: string, error: unknown) => void;
const logged: Failed = (file, error) => console.error(`changelog ${file} unavailable:`, error);

/**
 * A file of the bucket; with `upstream` (RELEASES_UPSTREAM), one of still.fail's it lacks read there, as index.ts serves
 * it. One that cannot be read (`retryRead` failed twice, or still.fail's not reached) is null as one not there is, and
 * `failed` is told.
 */
async function read(bucket: Bucket, key: string, upstream?: string, failed: Failed = logged): Promise<string | null> {
  const got = await retryRead(async () => {
    const object = await bucket?.get(key);
    return object ? await new Response(object.body).text() : null;
  });
  if (!got.ok) {
    failed(key, got.error);
    return null;
  }
  if (got.value !== null) return got.value;
  if (!upstream || !sharedRelease(key)) return null;
  try {
    const answer = await fetch(`${upstream.replace(/\/+$/, "")}/${key}`);
    if (answer.ok) return await answer.text();
    await answer.body?.cancel().catch(() => {});
    if (answer.status >= 500) failed(key, new Error(`upstream ${answer.status}`));
  } catch (error) {
    failed(key, new Error("upstream unreachable", { cause: error }));
  }
  return null;
}

/**
 * The changelog as CI last put it; empty before it has. The test channel's (changelog.json) is a commit an entry, and
 * is what reports are marked fixed by; the stable channel's (changelog-stable.json) a release an entry, as written for
 * it (docs/releases): read for the stable channel's apps, with the test channel's until there is one.
 */
export async function changelog(bucket: Bucket, channel: Channel = "beta", failed: Failed = logged): Promise<ChangelogEntry[]> {
  if (channel === "stable") {
    let stableFailed = false;
    const written = await entries(bucket, "changelog-stable.json", (file, error) => {
      stableFailed = true;
      failed(file, error);
    });
    // (one that could not be read is not one there is none of)
    if (written.length || stableFailed) return written;
  }
  return entries(bucket, "changelog.json", failed);
}

async function entries(bucket: Bucket, key: string, failed: Failed = logged): Promise<ChangelogEntry[]> {
  try {
    const value = JSON.parse((await read(bucket, key, undefined, failed)) ?? "[]") as unknown;
    return Array.isArray(value) ? (value as ChangelogEntry[]).filter((e) => Number.isSafeInteger(e?.version) && Array.isArray(e.text) && Array.isArray(e.parts)) : [];
  } catch {
    return [];
  }
}

/** n of a version said as 0.<m>.<n> (or a bare n). */
function build(said: unknown): number | null {
  const m = /^(?:0\.\d+\.)?(\d+)$/.exec(typeof said === "number" || typeof said === "string" ? String(said).trim() : "");
  return m ? Number(m[1]) : null;
}
const json = (text: string | null): Record<string, unknown> => {
  try {
    return (JSON.parse(text ?? "{}") as Record<string, unknown>) ?? {};
  } catch {
    return {};
  }
};

/**
 * What each part has out on a channel, from the feeds the updaters read (scripts/release.sh) and the web app's (deploy.py);
 * the station's from `upstream` where the bucket has none (monoid's cloud: its station is still.fail's, index.ts).
 */
export async function released(bucket: Bucket, channel: Channel, upstream?: string, failed: Failed = logged): Promise<PlatformReleases> {
  const beta = channel === "beta";
  const [station, android, mac, win, web] = await Promise.all([
    read(bucket, beta ? "station-beta.json" : "station.json", upstream, failed),
    read(bucket, beta ? "android/beta/latest.json" : "android/latest.json", undefined, failed),
    // (the Mac app's own updater's feed, which every product's has: monoid's never had electron-updater's .yml)
    read(bucket, beta ? "mac/beta/latest.json" : "mac/latest.json", undefined, failed),
    read(bucket, beta ? "win/beta/latest.json" : "win/latest.json", undefined, failed),
    read(bucket, beta ? "web-beta.json" : "web.json", undefined, failed),
  ]);
  const macos = build(json(mac).versionCode);
  const windows = build(json(win).versionCode);
  return {
    station: build(json(station).build ?? json(station).version),
    android: build(json(android).versionCode),
    macos, windows,
    desktop: macos !== null && windows !== null ? Math.min(macos, windows) : null,
    web: build(json(web).build ?? json(web).version),
  };
}

/** Whether all of a fix is out: each part it is in has released its version or a later one. */
export function out(entry: { version: number; parts: Part[] }, have: Released): boolean {
  return entry.parts.every((part) => part === "cloud" || (have[part] ?? 0) >= entry.version);
}

const channelOf = (request: Request, env: Env): Channel => (new URL(request.url).origin === betaOrigin(env) || header(request, "channel") === "beta" ? "beta" : "stable");

/** GET /v1/changelog: { entries, released } on the channel of the host (or x-stillfail-channel). Anyone may read it. Unavailable while any of it cannot be read: a client keeps what a 200 says in place of what it has (client/core-ts/src/changelog.ts). */
export async function serveChangelog(request: Request, env: Env): Promise<Response> {
  const channel = channelOf(request, env);
  let failure = null as { file: string; error: unknown } | null;
  const failed: Failed = (file, error) => {
    failure ??= { file, error };
  };
  const [list, have] = await Promise.all([changelog(env.RELEASES, channel, failed), released(env.RELEASES, channel, env.RELEASES_UPSTREAM, failed)]);
  if (failure) return unavailable(failure.file, failure.error);
  return reply({ entries: list, released: have }, 200, { "cache-control": "public, max-age=300" });
}

/** Marks the reports the changelog fixes, and gives what has been fixed of a station's reports and is out on their channel. */
export async function fixedFor(env: Env, station: string, told: string[]): Promise<FixedReport[]> {
  const dir = env.DIRECTORY.getByName("primary");
  const entries = await changelog(env.RELEASES);
  await dir.markFixed(entries.flatMap((e) => e.fixes.map((number) => ({ number, version: e.version, parts: e.parts }))));
  if (told.length) await dir.toldFixed(station, told);
  const reports = await dir.fixedUntold(station);
  const have: Partial<Record<Channel, PlatformReleases>> = {};
  const fixed: FixedReport[] = [];
  for (const report of reports) {
    have[report.channel] ??= await released(env.RELEASES, report.channel, env.RELEASES_UPSTREAM);
    const { desktopPlatform, ...details } = report;
    const { macos, windows, ...parts } = have[report.channel]!;
    if (desktopPlatform === "macos") parts.desktop = macos;
    if (desktopPlatform === "windows") parts.desktop = windows;
    if (out(details, parts)) fixed.push({ ...details, released: parts });
  }
  return fixed;
}

/**
 * POST /v1/feedback/fixed, from a station, signed like its reports (tag station-feedback-fixed-v1): { told?: [id] } →
 * { fixed: FixedReport[] }: its reports fixed and out, but those it says it has told.
 */
export async function serveFixed(request: Request, env: Env): Promise<Response> {
  let raw: string;
  try {
    raw = await readText(request, 64 * 1024);
  } catch {
    return reply({ error: "too_large" }, 413);
  }
  const station = await stationSender(request, env, raw, "station-feedback-fixed-v1");
  if (!station) return reply({ error: "invalid_session" }, 401);
  let told: string[] = [];
  try {
    const value = JSON.parse(raw || "{}") as { told?: unknown };
    told = Array.isArray(value.told) ? value.told.filter((t): t is string => typeof t === "string" && /^[0-9A-Z]{26}$/.test(t)).slice(0, 100) : [];
  } catch {
    return reply({ error: "invalid_request" }, 400);
  }
  return reply({ fixed: await fixedFor(env, station, told) });
}
