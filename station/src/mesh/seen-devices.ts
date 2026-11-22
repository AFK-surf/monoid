// The members' devices that came to this station with a credential, by workspace: what a lock's owner checks
// when turning it on (which devices to name), and when each device was last used. The cloud kept this from the
// credentials it was asked for; it is the station's now (the root AGENTS.md, The cloud is the account system): a
// device reads it of the stations it reaches (GET /lock/devices), each of which knows those that came to it. Kept on
// disk, those of the last SEEN_SECS.
import { readFileSync } from "node:fs";
import { PrivateFile } from "../ops/files.ts";
import { log } from "../ops/log.ts";

/// How long a device that came is kept (as the cloud listed them: the last 31 days).
export const SEEN_SECS = 31 * 86400;
/// A device seen again within this long is not written again (each connection would write the file).
const AGAIN_SECS = 3600;
/// At most this many kept: the least lately seen go.
export const SEEN_MOST = 4096;

/// One device (an endpoint) of a member's in a workspace, as the cloud's GET /devices said one.
export type Seen = { workspace: string; sub: string; email: string; role?: string; device: string; base: string | null; kind: string | null; label: string | null; first_seen: number; last_seen: number };

export class SeenDevices {
  /// Written off the station's thread: a device's connection waits on no disk.
  readonly #file: PrivateFile | null;
  #rows = new Map<string, Seen>();
  /// Who asked the vault of each workspace here (`remember`), by sub: their email and role, as their credential said it.
  /// Only in memory: a device asking again says it again.
  readonly #viewers = new Map<string, Map<string, { email: string; role?: string }>>();
  /// Moves on whenever who is known in a workspace may have changed (`members`, `roles`).
  #version = 0;

  constructor(path: string | null = null) {
    this.#file = path === null ? null : new PrivateFile(path);
    if (path === null) return;
    try {
      const kept = JSON.parse(readFileSync(path, "utf8")) as Seen[]; // sync: read once, before the station serves (mesh.ts makes it before the first hello)
      for (const r of kept) if (typeof r?.device === "string" && typeof r.sub === "string" && typeof r.workspace === "string") this.#rows.set(key(r), r);
    } catch {}
  }

  /// A device came with a credential (`at`: unix seconds): kept, or its last use moved on. `said`: what it says of
  /// itself in its hello (its lock proof's `kind` and `label`), its base key from its lock proof.
  saw(at: number, who: { workspace: string; sub: string; email: string; role?: string }, device: string, base: string | null, said: unknown): void {
    const kind = (said as { kind?: unknown } | null)?.kind;
    const label = (said as { label?: unknown } | null)?.label;
    const was = this.#rows.get(`${who.workspace}\0${who.sub}\0${device}`);
    const role = typeof who.role === "string" && who.role !== "" ? who.role : was?.role;
    if (typeof who.role === "string" && who.role !== "") {
      const viewer = this.#viewers.get(who.workspace)?.get(who.sub);
      if (viewer !== undefined && viewer.role !== who.role) {
        viewer.role = who.role;
        this.#version++;
      }
    }
    const next: Seen = {
      workspace: who.workspace, sub: who.sub, email: who.email, ...(role !== undefined ? { role } : {}), device,
      base: base ?? was?.base ?? null,
      kind: kind === "app" || kind === "web" ? kind : (was?.kind ?? null),
      label: typeof label === "string" ? label.slice(0, 120) : (was?.label ?? null),
      first_seen: was?.first_seen ?? at,
      last_seen: at,
    };
    if (was !== undefined && at - was.last_seen < AGAIN_SECS && was.base === next.base && was.kind === next.kind && was.label === next.label && was.email === next.email && was.role === next.role) return;
    this.#rows.delete(key(next));
    this.#rows.set(key(next), next);
    this.#version++;
    for (const [k, r] of this.#rows) if (r.last_seen < at - SEEN_SECS) this.#rows.delete(k);
    for (const k of [...this.#rows.keys()].slice(0, Math.max(0, this.#rows.size - SEEN_MOST))) this.#rows.delete(k);
    this.#write();
  }

  /// Those of workspace `ws` seen in the last SEEN_SECS before `at`: everyone's for its owners and admins
  /// (`manages`), else `sub`'s own; each person's latest first.
  of(ws: string, at: number, sub: string, manages: boolean): Seen[] {
    return [...this.#rows.values()]
      .filter((r) => r.workspace === ws && r.last_seen >= at - SEEN_SECS && (manages || r.sub === sub))
      .sort((a, b) => (a.sub < b.sub ? -1 : a.sub > b.sub ? 1 : b.last_seen - a.last_seen));
  }

  /// A member who asked the vault here (api/routes/vault.ts), whose email and role their credential said: known by
  /// `members` and `roles` even where no hello of theirs came (a local admin port, a test).
  remember(ws: string, sub: string, email: string, role?: string): void {
    if (ws === "" || sub === "" || email === "") return;
    let of = this.#viewers.get(ws);
    if (of === undefined) this.#viewers.set(ws, (of = new Map()));
    const was = of.get(sub);
    const nextRole = typeof role === "string" && role !== "" ? role : was?.role;
    if (was !== undefined && was.email === email && was.role === nextRole) return;
    of.set(sub, { email, ...(nextRole !== undefined ? { role: nextRole } : {}) });
    this.#version++;
  }

  /// Every member of workspace `ws` known here (each device of theirs that came, whenever, and those that asked the
  /// vault), by sub: their email, as they said it last.
  members(ws: string): ReadonlyMap<string, string> {
    const out = new Map<string, { email: string; at: number }>();
    for (const r of this.#rows.values()) {
      if (r.workspace !== ws || r.email === "") continue;
      const had = out.get(r.sub);
      if (had === undefined || had.at <= r.last_seen) out.set(r.sub, { email: r.email, at: r.last_seen });
    }
    const said = new Map([...out].map(([sub, { email }]) => [sub, email]));
    for (const [sub, v] of this.#viewers.get(ws) ?? []) said.set(sub, v.email);
    return said;
  }

  /// Every member of workspace `ws` whose role is known here (from their last valid credential), by sub.
  roles(ws: string): ReadonlyMap<string, string> {
    const out = new Map<string, { role: string; at: number }>();
    for (const r of this.#rows.values()) {
      if (r.workspace !== ws || typeof r.role !== "string" || r.role === "") continue;
      const had = out.get(r.sub);
      if (had === undefined || had.at <= r.last_seen) out.set(r.sub, { role: r.role, at: r.last_seen });
    }
    const said = new Map([...out].map(([sub, { role }]) => [sub, role]));
    for (const [sub, v] of this.#viewers.get(ws) ?? []) if (v.role !== undefined && v.role !== "") said.set(sub, v.role);
    return said;
  }

  /// Moves on as what `members` says may have changed.
  version(): number {
    return this.#version;
  }

  /// Once what was seen is on disk.
  written(): Promise<void> {
    return this.#file?.written() ?? Promise.resolve();
  }

  #write() {
    this.#file?.write(JSON.stringify([...this.#rows.values()])).catch((e) => log.warn("mesh", "the devices seen were not kept", { error: (e as Error).message }));
  }
}

const key = (r: { workspace: string; sub: string; device: string }) => `${r.workspace}\0${r.sub}\0${r.device}`;
