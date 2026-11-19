// How loaded still.fail's relays are, for the admin's console (its 中继 page, GET /v1/admin/relays): each relay's
// counters (relay-metrics.ts Load) about a minute apart, kept a week. The relays on machines of their own send theirs
// (POST /v1/relays/load, relay-load.sh run by a timer there: receiveLoad says which each is); Cloudflare's is read by this Worker's cron from the
// relay process (index.ts). What is shown is worked out from the counters when asked (relay-load-view.ts). What each did
// in the minute between two samples goes to Cloud Logging as well (a `relay minute` log line), beside the
// devices' and stations' records of the same minutes.
import { DurableObject } from "cloudflare:workers";
import { bearerToken, digest, nowSeconds, reply } from "./auth";
import type { Directory, DirectoryLoad } from "./directory";
import type { Env } from "./env";
import { LIMITS } from "./limits";
import type { BudgetStanding, RelayBudget } from "./relay";
import { relayConns, relayLoad, type Load } from "./relay-metrics";
import { GAP, relayLoadView, relayMinute, type RelayLoadView, type RelayMinute } from "./relay-load-view";
import { relayToTelemetry } from "./tracing";
import { ownRelay, relayName, relayUrls } from "./relays";
import type { ProbeLine } from "./probes";

/** How long samples are kept: the week the console shows, and a day more. */
const KEEP = 8 * 86_400;

/** Every relay's samples, in one object ("primary"). */
export class RelayLoad extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS samples (relay TEXT NOT NULL, at INTEGER NOT NULL, load TEXT NOT NULL, PRIMARY KEY (relay, at))");
    // What the latest probes from China's carriers and Hong Kong found of each relay (probes.ts, index.ts probeAndSay).
    ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS probes (relay TEXT PRIMARY KEY, at INTEGER NOT NULL, lines TEXT NOT NULL)");
  }

  /** What the probes found now, by relay: each relay's latest kept, those older than KEEP gone. */
  recordProbes(found: Record<string, ProbeLine[]>): void {
    const now = nowSeconds();
    for (const [relay, lines] of Object.entries(found)) {
      if (lines.length > 0) this.ctx.storage.sql.exec("INSERT OR REPLACE INTO probes (relay, at, lines) VALUES (?, ?, ?)", relay, now, JSON.stringify(lines));
    }
    this.ctx.storage.sql.exec("DELETE FROM probes WHERE at < ?", now - KEEP);
  }

  /** A relay's counters now; what it did since its sample before (relay-load-view.ts `relayMinute`). */
  record(relay: string, load: Load): RelayMinute | null {
    const now = nowSeconds();
    const before = this.ctx.storage.sql.exec<{ at: number; load: string }>("SELECT at, load FROM samples WHERE relay = ? ORDER BY at DESC LIMIT 1", relay).toArray()[0];
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO samples (relay, at, load) VALUES (?, ?, ?)", relay, now, JSON.stringify(load));
    this.ctx.storage.sql.exec("DELETE FROM samples WHERE relay = ? AND at < ?", relay, now - KEEP);
    return relayMinute(before ? { at: before.at, load: JSON.parse(before.load) as Load } : null, { at: now, load });
  }

  /** What a relay has carried since midnight UTC, as its budget counts (relay.ts): from its samples since then. */
  today(relay: string): { bytes: number; frames: number } {
    const now = nowSeconds();
    const midnight = Math.floor(now / 86_400) * 86_400;
    const rows = this.ctx.storage.sql.exec<{ at: number; load: string }>("SELECT at, load FROM samples WHERE relay = ? AND at >= ? ORDER BY at", relay, midnight - GAP).toArray();
    return relayLoadView(relay, rows.map((r) => ({ at: r.at, load: JSON.parse(r.load) as Load })), now).today;
  }

  /** When a relay's counters last came (status.ts); null: never, or none kept. */
  lastSampled(relay: string): number | null {
    return this.ctx.storage.sql.exec<{ at: number }>("SELECT at FROM samples WHERE relay = ? ORDER BY at DESC LIMIT 1", relay).toArray()[0]?.at ?? null;
  }

  /** The relays' views, in the order given; with the latest probes of each probed (none said of one not). */
  view(relays: string[]): (RelayLoadView & { probes?: { at: number; lines: ProbeLine[] } })[] {
    const now = nowSeconds();
    const probed = new Map(this.ctx.storage.sql.exec<{ relay: string; at: number; lines: string }>("SELECT relay, at, lines FROM probes WHERE at >= ?", now - KEEP).toArray().map((r) => [r.relay, r] as const));
    return relays.map((url) => {
      const rows = this.ctx.storage.sql.exec<{ at: number; load: string }>("SELECT at, load FROM samples WHERE relay = ? AND at >= ? ORDER BY at", url, now - 7 * 86_400 - GAP).toArray();
      const view = relayLoadView(url, rows.map((r) => ({ at: r.at, load: JSON.parse(r.load) as Load })), now);
      const p = probed.get(url);
      return p ? { ...view, probes: { at: p.at, lines: JSON.parse(p.lines) as ProbeLine[] } } : view;
    });
  }
}

/** At most this much of a relay's metrics is read (iroh-relay's are a few kilobytes). */
const MAX_METRICS = 256 * 1024;

/**
 * A relay's counters, from relay-load.sh on its machine: its metrics as iroh-relay gives them, with node_rx, node_tx and
 * node_load1 lines for the machine's. Which relay of the cloud's list it is (relay-registry.ts): the one whose secret it
 * comes with (`authorization: Bearer`, given as it enrolled); else, one listed with no secret, the one
 * `x-stillfail-relay` names, believed when Cloudflare saw the request come from its own address (those the deploy's
 * config listed, named by their IP, which is where they send from).
 */
export async function receiveLoad(request: Request, env: Env): Promise<Response> {
  const supplied = bearerToken(request);
  let url: string;
  try {
    url = await env.DIRECTORY.getByName("primary").relayHeard(supplied ? await digest(supplied) : null, request.headers.get("x-stillfail-relay") ?? "", request.headers.get("cf-connecting-ip"));
  } catch (error) {
    const code = error instanceof Error ? error.message : "";
    if (code === "unknown_relay") return reply({ error: code }, 400);
    if (code === "invalid_secret" || code === "not_from_relay") return reply({ error: code }, 403);
    throw error;
  }
  if (Number(request.headers.get("content-length") ?? 0) > MAX_METRICS) return reply({ error: "too_large" }, 413);
  const text = await request.text();
  if (text.length > MAX_METRICS) return reply({ error: "too_large" }, 413);
  const minute = await env.RELAY_LOAD.getByName("primary").record(url, relayLoad(text));
  await relayToTelemetry(env, url, minute, relayConns(text).map((fields) => ({ what: "relay conn", fields })));
  return reply({ ok: true });
}

/**
 * still.fail's own relay's counters (the cron's, a minute apart): none while its process is not running. Its minute in
 * Cloud Logging says how near it is to each of its budget's limits (relay.ts admit: LIMITS), and which it has reached
 * (`full`): 2026-10-30 it answered every new connection 429 from 12:22 in Beijing, and nothing said whether the day's
 * bytes or the connections held had run out. Said while the process is not running too (the budget run out stops it).
 * Gives those it has reached, for still.fail/status (status.ts).
 *
 * The day's traffic is the budget's own count (relay.ts `standing`) where it is more than the samples here: the budget
 * reads the process between two of them, and once it ran out and stopped it no sample comes again, the samples' sum
 * left just under the limit (2026-11-14 to 11-18, four days of five said `none` while every connect was refused).
 */
export async function sampleOwnRelay(env: Env): Promise<string[]> {
  if (!env.RELAY || env.RELAY_URL) return [];
  const text = await env.RELAY.getByName("primary").metrics().catch(() => null);
  const url = ownRelay(env);
  const loads = env.RELAY_LOAD.getByName("primary");
  const load = text === null ? null : relayLoad(text);
  const minute = load === null ? null : await loads.record(url, load);
  const budget = env.RELAY_BUDGET ? await budgetStanding(env.RELAY_BUDGET.getByName("primary"), text !== null) : null;
  const sampled = await loads.today(url);
  const limitBytes = budget?.limitBytes ?? LIMITS.bytesPerDay;
  const limitFrames = budget?.limitFrames ?? LIMITS.framesPerDay;
  const today = { bytes: Math.max(sampled.bytes, budget?.bytes ?? 0), frames: Math.max(sampled.frames, budget?.frames ?? 0) };
  const open = load === null ? 0 : Math.max(0, load.accepts - load.disconnects);
  const connects = minute === null ? null : Math.round((minute.accepts * 60) / minute.secs);
  const spent = [
    ...(today.bytes >= limitBytes ? ["bytes"] : []),
    ...(today.frames >= limitFrames ? ["frames"] : []),
  ];
  // The budget says it ran out though neither count reached its limit here (a limit of its own, a count at the edge):
  // the nearer of the two is what ran out.
  if (budget?.exhausted && spent.length === 0) spent.push(today.bytes / limitBytes >= today.frames / limitFrames ? "bytes" : "frames");
  const full = [
    ...spent,
    ...(open >= LIMITS.connections ? ["connections"] : []),
    ...(connects !== null && connects >= LIMITS.connectsPerMinute ? ["connects"] : []),
  ];
  await relayToTelemetry(env, url, {
    ...(minute ?? {}),
    running: text !== null,
    open,
    today_bytes: today.bytes,
    today_frames: today.frames,
    limit_bytes: limitBytes,
    limit_frames: limitFrames,
    limit_connections: LIMITS.connections,
    limit_connects: LIMITS.connectsPerMinute,
    full: full.join(",") || "none",
  });
  return full;
}

/**
 * What the budget counted today (relay.ts `standing`). The relay's Worker is deployed by hand, after this one: one from
 * before has no `standing`, and holds the limits it was deployed with. With its process stopped, what it refuses a
 * connect for says as much (`admit`, which starts nothing): refused with no connection held nor too many connects, it
 * ran out; a count under this Worker's limits ran out under its own, which is then that count. Running, it is not asked
 * (an admitted connect counts as one).
 */
async function budgetStanding(budget: DurableObjectStub<RelayBudget>, running: boolean): Promise<BudgetStanding | null> {
  return budget.standing().catch(async () => {
    if (running) return null;
    const refused = await budget.admit().catch(() => null);
    if (!refused) return null;
    const ranOut = refused.open + refused.dialing < LIMITS.connections && refused.connects < LIMITS.connectsPerMinute;
    return {
      bytes: refused.bytes,
      frames: refused.frames,
      limitBytes: LIMITS.bytesPerDay,
      limitFrames: ranOut && refused.bytes < LIMITS.bytesPerDay && refused.frames < LIMITS.framesPerDay ? refused.frames : LIMITS.framesPerDay,
      exhausted: ranOut,
    };
  });
}

type RelayRegistry = ReturnType<Directory["relayList"]>;

/**
 * The console's 中继 page: every relay, named, still.fail's own with the budget it is held to (relay.ts); and how loaded
 * the Directory itself is (directory.ts adminLoad), which the same minute's event has the page read again.
 */
export async function relaysLoad(env: Env): Promise<{ relays: (RelayLoadView & { name: string; limits?: { bytes: number; frames: number } })[]; directory: DirectoryLoad; registry: RelayRegistry }> {
  const dir = env.DIRECTORY.getByName("primary");
  const listed = await dir.relaysNow();
  const urls = relayUrls(listed);
  const [views, directory, registry] = await Promise.all([env.RELAY_LOAD.getByName("primary").view(urls), dir.adminLoad(), dir.relayList()]);
  return {
    directory,
    // The list as its operator keeps it (relay-registry.ts), for the page to put relays on it and take them off.
    registry,
    relays: views.map((v, i) => ({
      ...v,
      name: relayName(listed, v.url),
      ...(i === 0 && !env.RELAY_URL ? { limits: { bytes: LIMITS.bytesPerDay, frames: LIMITS.framesPerDay } } : {}),
    })),
  };
}
