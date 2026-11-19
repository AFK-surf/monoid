import { denied, nowSeconds } from "../auth";
import { header } from "../compat";
import { grantKeys, verifyKeySignature } from "../grants";
import { watchMessage, watchRequest, type MeshRelayEvents } from "../mesh-relay-events";
import { MAX_RELAYS, parseRelays, relays, relayUrls, sameUrl, WAY_KINDS, waysOf } from "../relays";
import type { AccountEvent, StationEvent } from "../types";
import type { DirectoryDb, DirectoryHost } from "./db";
import { CLOSE, EVENTS_PROTOCOLS, OUTBOX_MAX_DELAY, REVOCATION_DAYS, SILENT_MS, sockets, type Attachment, type Delivery } from "./types";

// ── notifications, deliveries, sockets, and presence ────────────────────

export class DirectorySockets {
  #db: DirectoryDb;
  #host: DirectoryHost;
  #meshEvents: MeshRelayEvents;

  /** Each object's sending now (`kind key`): what is written for it meanwhile goes next, in the same run. */
  readonly #sending = new Map<string, Promise<void>>();
  /** Objects the step being run must have reached before its request answers (#delivered). */
  #urgent: string[] = [];
  #soon: Promise<void> | null = null;

  constructor(db: DirectoryDb, host: DirectoryHost, meshEvents: MeshRelayEvents) {
    this.#db = db;
    this.#host = host;
    this.#meshEvents = meshEvents;
  }

  /**
   * Sockets held here while devices' and stations' open on their own objects (those from before the deploy that moved
   * them, or from before the way back was left): closed as a restarting service's (1012), so each reconnects onto its
   * own object, reading everything again as it does after any reconnect.
   */
  handOff(): void {
    for (const ws of this.#db.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment;
      if ("station" in attachment) this.drop(ws, 1012, "moved");
      else {
        try {
          ws.close(1012, "moved");
        } catch {
          // Closed already.
        }
      }
    }
  }

  /** Pushes events to every events socket of these accounts: on their objects, and any held here. */
  tell(subs: Iterable<string>, ...events: AccountEvent[]): void {
    const frames = events.map((event) => JSON.stringify(event));
    for (const sub of new Set(subs)) {
      this.deliver("account", sub, { frames });
      for (const ws of this.#db.ctx.getWebSockets(`sub:${sub}`)) {
        for (const frame of frames) {
          try {
            ws.send(frame);
          } catch {
            // Closing already; its device reconnects and refetches.
          }
        }
      }
    }
  }

  /** `always`: whether or not it holds a socket (what its object keeps: an account's test channel, a station let go). */
  deliver(kind: "account" | "station", key: string, body: Delivery, how: { urgent?: boolean; always?: boolean } = {}): void {
    if (!how.always && !this.#db.one("SELECT 1 AS x FROM live WHERE kind = ? AND key = ?", kind, key)) return;
    this.#db.run("INSERT INTO outbox (kind, key, body) VALUES (?, ?, ?)", kind, key, JSON.stringify(body));
    this.#soon ??= Promise.resolve().then(() => {
      this.#soon = null;
      this.flush();
    });
    if (how.urgent) this.#urgent.push(`${kind} ${key}`);
  }

  /**
   * Waits until the deliveries the step that just ran made urgent got there or failed once (then they are tried again
   * after). Called in that same step, before anything is awaited: what another request's step makes is its own.
   */
  async delivered(): Promise<void> {
    const keys = this.#urgent.splice(0);
    await this.#soon;
    await Promise.all(keys.map((k) => this.#sending.get(k)));
  }

  /** Sends what is due, to each object not being sent to already. */
  flush(): void {
    for (const r of this.#db.rows("SELECT DISTINCT kind, key FROM outbox WHERE next_at <= ?", nowSeconds())) {
      const kind = r.kind as "account" | "station", key = r.key as string, k = `${kind} ${key}`;
      if (this.#sending.has(k)) continue;
      this.#sending.set(k, this.#sendAll(kind, key).finally(() => {
        this.#sending.delete(k);
        // Written between its last read and now.
        if (this.#db.one("SELECT 1 AS x FROM outbox WHERE kind = ? AND key = ? AND next_at <= ?", kind, key, nowSeconds())) this.flush();
      }));
    }
  }

  async #sendAll(kind: "account" | "station", key: string): Promise<void> {
    for (;;) {
      // All that waits for it, what failed before with what is new, so it never hears a later change before an earlier one.
      const group = this.#db.rows("SELECT id, body, tries FROM outbox WHERE kind = ? AND key = ? ORDER BY id", kind, key);
      if (group.length === 0) return;
      const bodies = group.map((r) => JSON.parse(r.body as string) as Delivery);
      const tried = group.some((r) => (r.tries as number) > 0);
      const beta = [...bodies].reverse().find((b) => b.beta !== undefined)?.beta;
      const body: Delivery = {
        frames: bodies.flatMap((b) => b.frames ?? []),
        ...(beta === undefined ? {} : { beta }),
        // Tried again, a station is told its state too: what was told late is then followed by all of it as it is.
        // Made as it is sent, so the station need not ask for it.
        ...(bodies.some((b) => b.state) || (kind === "station" && tried) ? { state: true as const, frame: this.frame(key) } : {}),
      };
      const ids = group.map((r) => r.id as number);
      const marks = ids.map(() => "?").join(", ");
      const gen = this.#db.one("SELECT gen FROM live WHERE kind = ? AND key = ?", kind, key)?.gen as number | undefined;
      try {
        const said = await this.#host.send(kind, key, body);
        this.#db.run(`DELETE FROM outbox WHERE id IN (${marks})`, ...ids);
        // It holds no socket: out of `live`, unless one opened since (a newer gen).
        if (!said.live && gen !== undefined) this.#db.run("DELETE FROM live WHERE kind = ? AND key = ? AND gen <= ?", kind, key, gen);
      } catch (error) {
        const tries = Math.max(...group.map((r) => r.tries as number)) + 1;
        if (tries % 8 === 0) console.warn(`directory: ${kind} ${key} not told after ${tries} tries: ${(error as Error).message}`);
        this.#db.run(`UPDATE outbox SET tries = ?, next_at = ? WHERE id IN (${marks})`, tries, nowSeconds() + Math.min(2 ** tries, OUTBOX_MAX_DELAY), ...ids);
        await this.arm();
        return;
      }
    }
  }

  /** The alarm at the next delivery due again, unless it is set sooner. */
  async arm(): Promise<void> {
    const next = this.#db.one("SELECT MIN(next_at) AS at FROM outbox")?.at as number | null | undefined;
    if (next === null || next === undefined) return;
    const at = Math.max(next * 1000, Date.now());
    const set = await this.#db.ctx.storage.getAlarm();
    if (set === null || at < set) await this.#db.ctx.storage.setAlarm(at); // timer: a retry after a failure, with a backoff
  }

  /** Every delivery under way has got there or failed (the tests' barrier, instead of waiting a while). */
  async settled(): Promise<void> {
    while (this.#soon !== null || this.#sending.size > 0) await Promise.all([this.#soon, ...this.#sending.values()]);
  }

  /**
   * An object holding a socket now (an account's events socket, a station's presence socket): told what is for its
   * sockets, and what goes to all, until it says it holds none (closed, or a delivery's answer). Its `gen` tells a
   * close from before a later open.
   */
  opened(kind: "account" | "station", key: string): number {
    // Never one given before: a close or an answer from before a later open must not take the later one's row.
    const gen = (this.#db.ctx.storage.kv.get<number>("opened") ?? 0) + 1;
    this.#db.ctx.storage.kv.put("opened", gen);
    this.#db.run("INSERT INTO live (kind, key, gen) VALUES (?, ?, ?) ON CONFLICT (kind, key) DO UPDATE SET gen = excluded.gen", kind, key, gen);
    return gen;
  }

  /** An account's object opened an events socket (account.ts): seen now (the console's last seen), and live. */
  seen(sub: string): number {
    this.#db.run("UPDATE users SET last_seen = ? WHERE sub = ?", nowSeconds(), sub);
    return this.opened("account", sub);
  }

  /** An account's object closed its last events socket, opened as `gen`. */
  closed(sub: string, gen: number): void {
    this.#db.run("DELETE FROM live WHERE kind = 'account' AND key = ? AND gen = ?", sub, gen);
  }

  /** Tells every connected device of every account `event`, and every connected station `station` (a release out). */
  tellAll(event: AccountEvent, station: StationEvent | null): void {
    const frames = [JSON.stringify(event), station === null ? null : JSON.stringify(station)];
    for (const ws of this.#db.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment;
      const frame = "station" in attachment ? frames[1] : frames[0];
      if (frame === null || ws.readyState !== WebSocket.OPEN) continue;
      try {
        ws.send(frame);
      } catch {
        // Closing already; it reads what it needs as it connects again.
      }
    }
    for (const r of this.#db.rows("SELECT kind, key FROM live")) {
      const frame = r.kind === "station" ? frames[1] : frames[0];
      if (frame !== null) this.deliver(r.kind as "account" | "station", r.key as string, { frames: [frame] });
    }
  }

  /** Tells every connected station `event` (the models' catalog changed). */
  tellStations(event: StationEvent): void {
    const frame = JSON.stringify(event);
    for (const ws of this.#db.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment;
      if (!("station" in attachment) || attachment.dropped || ws.readyState !== WebSocket.OPEN) continue;
      try {
        ws.send(frame);
      } catch {}
    }
    for (const r of this.#db.rows("SELECT key FROM live WHERE kind = 'station'")) this.deliver("station", r.key as string, { frames: [frame] });
  }

  /** The models' catalog the cron made (models.ts `checkModels`): told to every connected station when it changed. */
  async modelsMade(etag: string): Promise<void> {
    const before = await this.#db.ctx.storage.get<string>("models-etag");
    if (before === etag) return;
    await this.#db.ctx.storage.put("models-etag", etag);
    this.#host.tellStations({ type: "models", etag });
  }

  /**
   * Upgrades reach here only through the Worker, which has authenticated
   * them: `/events` names the account in `x-stillfail-sub` (and the
   * subprotocol to select in `x-stillfail-protocol`), `/stations/connect` the
   * station (whose signature it checked) in `x-stillfail-station`.
   */
  async fetch(request: Request): Promise<Response> {
    if (new URL(request.url).pathname === "/mesh-relays/events" && request.method === "POST") {
      const signed = await request.json() as { body?: unknown; signature?: unknown };
      const input = watchRequest(signed.body, Date.now());
      if (!input || typeof signed.signature !== "string" || !await verifyKeySignature(input.node, signed.signature, watchMessage(this.#db.env.PUBLIC_ORIGIN, signed.body as string))) {
        return Response.json({ error: "invalid_signature" }, { status: 401 });
      }
      // The signature check awaits. Read admission afterwards so revocation wins.
      const meshRelays = this.#host.meshRelays();
      if (!meshRelays.some((r) => r.node === input.node && r.generation === input.generation)) return Response.json({ error: "mesh_relay_not_registered" }, { status: 403 });
      const stream = this.#meshEvents.open(input.node, input.generation, input.at, Date.now(), meshRelays);
      if (!stream) return Response.json({ error: "mesh_watch_capacity" }, { status: 429 });
      return new Response(stream, { headers: { "content-type": "application/x-ndjson", "cache-control": "no-store" } });
    }
    // Only while the sockets are rolled back here (sockets.where). An old Worker's, in flight as it is replaced, is
    // turned away as a restarting service: the device or station tries again, through the new one, onto its object.
    if (sockets.where(this.#db.env) === "objects") return Response.json({ error: "moved" }, { status: 503 });
    const path = new URL(request.url).pathname;
    const pair = new WebSocketPair();
    if (path === "/events") {
      const sub = header(request, "sub")!;
      const sid = header(request, "sid") ?? "";
      // Every device opens this when it starts: the nearest thing to "last seen" that costs no write per request.
      this.#db.run("UPDATE users SET last_seen = ? WHERE sub = ?", nowSeconds(), sub);
      this.#db.ctx.acceptWebSocket(pair[1], [`sub:${sub}`]);
      pair[1].serializeAttachment({ sub, sid } satisfies Attachment);
      // Registered before checking, so a revocation during that call closes it too. The client receives no socket
      // until checked: the Worker's earlier check may have preceded a revocation on the way here.
      let live: boolean;
      try {
        live = await this.#db.env.ACCOUNTS.getByName(sub).signedIn({ sub, sid });
      } catch (error) {
        if (pair[1].readyState === WebSocket.OPEN) pair[1].close(1011, "session check failed");
        throw error;
      }
      if (!live || pair[1].readyState !== WebSocket.OPEN) {
        if (pair[1].readyState === WebSocket.OPEN) pair[1].close(1008, "session ended");
        return denied();
      }
      return new Response(null, { status: 101, webSocket: pair[0], headers: { "sec-websocket-protocol": header(request, "protocol") ?? EVENTS_PROTOCOLS[0] } });
    }
    const station = header(request, "station")!;
    if (!this.#host.isStation(station)) return Response.json({ error: "station_removed" }, { status: 404 });
    // One socket per station: a reconnect replaces the one it gave up on.
    for (const old of this.presence(station)) this.drop(old, CLOSE.replaced, "replaced");
    this.#db.run("UPDATE stations SET last_seen = ?, version = COALESCE(?, version) WHERE id = ?", nowSeconds(), header(request, "version"), station);
    this.#db.ctx.acceptWebSocket(pair[1], [`station:${station}`]);
    pair[1].serializeAttachment({ station, at: Date.now() } satisfies Attachment);
    this.sendState(station);
    if ((await this.#db.ctx.storage.getAlarm()) === null) await this.#db.ctx.storage.setAlarm(Date.now() + SILENT_MS);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  /** The open presence sockets of a station (at most one, but a replaced one may linger). */
  presence(station: string): WebSocket[] {
    return this.#db.ctx.getWebSockets(`station:${station}`).filter((ws) => ws.readyState === WebSocket.OPEN && !(ws.deserializeAttachment() as { dropped?: boolean }).dropped);
  }

  /** Closes a socket from this side; its close event then changes nothing. */
  drop(ws: WebSocket, code: number, reason: string): void {
    ws.serializeAttachment({ ...(ws.deserializeAttachment() as Attachment), dropped: true });
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  /** A station in no workspace now: its object hears it (and lets its socket go, 4004), and any socket held here goes. */
  disconnect(station: string): void {
    this.deliver("station", station, { state: true }, { urgent: true, always: true });
    for (const ws of this.presence(station)) this.drop(ws, CLOSE.removed, "station_removed");
  }

  /**
   * Where a station is and what it is called, and the cloud's own addresses as it has them now (a station enrolled
   * under an old host follows them: its links then use the new one); sent on connect and when that changes. What it
   * says at the top is of the station's home, as it was when a station was in one workspace (all a station from before
   * several knows); `workspaces`, each other one it is in, with its own peers, revocations and lock head.
   */
  sendState(station: string, urgent = false): void {
    this.deliver("station", station, { state: true }, { urgent });
    const open = this.presence(station);
    if (!open.length) return;
    const frame = this.frame(station);
    if (frame !== null) for (const ws of open) ws.send(frame);
  }

  /** A station's state frame (#sendState); null for one in no workspace. */
  frame(station: string): string | null {
    const found = this.#db.rows(`SELECT m.workspace, w.name AS workspace_name, m.name, w.relays, w.ways_off, m.rig, m.enrolled_by FROM station_members m JOIN workspaces w ON w.id = m.workspace
      WHERE m.station = ? ORDER BY m.enrolled_at, m.rowid`, station);
    if (!found.length) return null;
    const since = nowSeconds() - REVOCATION_DAYS * 86400;
    // The rigs apart from the stations (`rigs`): a station from before them reads no such field and so takes no rig
    // for a station (which it would let ask anything of it). A rig is told the stations (they alone ask of it), not
    // the other rigs, and whose it is (`rig`).
    // (`ways`: the workspace's own relays and the ways it turned off, as kept here before its stations kept them: what a
    // station takes as its first of them, station/src/mesh/ways.ts), but one of still.fail's a workspace also added as its
    // own before it was still.fail's: kept as both, a station took it for neither (2026-11-16, 上海 in hypershell-算法)
    const told = relays(this.#db.relays(this.#host.meshRelays()));
    const ours = told.relay_urls.map(sameUrl);
    const theirs = (raw: unknown) => parseRelays(raw).filter((u) => !ours.includes(sameUrl(u)));
    const [home, ...joined] = found.map(({ relays: wsRelays, ways_off, rig, enrolled_by, ...row }) => ({
      ...(row as { workspace: string; workspace_name: string; name: string }),
      ways: { relays: theirs(wsRelays), off: parseRelays(ways_off) },
      peers: this.#db.rows("SELECT m.station AS id, m.name, s.version FROM station_members m LEFT JOIN stations s ON s.id = m.station WHERE m.workspace = ? AND m.rig IS NULL ORDER BY m.enrolled_at, m.rowid", row.workspace),
      ...(rig === 1 ? { rig: { owner: enrolled_by as string } } : this.#db.rigsTold(row.workspace as string)),
      revocations: this.#db.rows("SELECT kind, id, at FROM revocations WHERE workspace = ? AND at >= ?", row.workspace, since),
      lock: this.#host.lockHead(row.workspace as string),
      ...(this.#host.locked(row.workspace as string) ? { locked: true } : {}),
    }));
    const { peers, revocations, lock: _, locked: __, ...row } = home! as typeof home & { locked?: true };
    // Every workspace's own relays after still.fail's (one endpoint, homed on any of them): a station from before them
    // keeps one more relay as it keeps the rest.
    // `stillfail_relays`: still.fail's alone, so a station tells them from its workspaces' own where one of those is
    // also one of still.fail's (station/src/mesh/ways.ts `stillFails`).
    const stillfail_relays = [...told.relay_urls];
    const relay_urls = [...told.relay_urls];
    for (const url of found.flatMap((w) => parseRelays(w.relays))) if (!relay_urls.map(sameUrl).includes(sameUrl(url))) relay_urls.push(url);
    const lock = this.#host.lockHead(row.workspace);
    return JSON.stringify({ type: "state", peers, ...row, origin: this.#db.env.PUBLIC_ORIGIN, ...told, relay_urls, stillfail_relays, grant_keys: grantKeys(this.#db.env), revocations, lock, workspaces: joined });
  }

  #offline(station: string): void {
    if (this.presence(station).length) return;
    this.#db.run("UPDATE stations SET last_seen = ? WHERE id = ?", nowSeconds(), station);
  }

  /** "ping" is answered by the runtime; a station speaks otherwise only of the workspace locks: it asks for entries it
   * lacks (`lock.get {after}`, answered `{type: "lock", entries}`) or brings ones the cloud lacks (`lock.put`), of its
   * home's lock, or of another workspace's it is in that it names (`workspace`, said back with the entries); and of
   * the ways it keeps of a workspace it names (`ways.put`, #waysPut). */
  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment;
    if (typeof message !== "string" || !("station" in attachment)) return;
    await this.said(attachment.station, message, (frame) => ws.send(frame));
  }

  /** What a station said (here or on its object), answered with `send`. */
  async said(station: string, message: string, send: (frame: string) => void): Promise<void> {
    let body: { type?: unknown; after?: unknown; entries?: unknown; workspace?: unknown; genesis?: unknown; keep?: unknown };
    try {
      body = JSON.parse(message);
    } catch {
      return;
    }
    const all = this.#db.memberships(station);
    const named = typeof body.workspace === "string" ? body.workspace : null;
    const workspace = named === null ? all[0] : all.includes(named) ? named : undefined;
    if (!workspace) return;
    if (body.type === "lock.get") {
      const after = Number.isSafeInteger(body.after) ? (body.after as number) : -1;
      // A station that holds a chain turned off since (it was offline then, and the lock was turned on again after):
      // the rest of that chain, its `disable` with it, so it lets that chain go by itself (it checks each entry).
      const off = typeof body.genesis === "string" ? this.#host.lockTurnedOff(workspace, body.genesis, after) : [];
      send(JSON.stringify({ type: "lock", entries: off.length > 0 ? off : this.#host.lockAfter(workspace, after), ...(named === null ? {} : { workspace }) }));
    } else if (body.type === "lock.put") {
      // Refused when it does not follow: the station hears the cloud's head in the state frame and asks again. `keep`:
      // what the station keeps of the lock that the cloud's chain parted from (its head an entry that lost), kept by
      // the fork choice (a station from before says none, and is answered as before).
      await this.#host.appendLockInternal(workspace, body.entries, body.keep === true).catch(() => this.sendState(station));
    } else if (body.type === "ways.put" && named !== null) {
      this.#waysPut(station, workspace, body as Record<string, unknown>);
    }
  }

  /**
   * A workspace's ways as one of its stations keeps them (station/src/cloud/presence.ts `waysTeller`): theirs, kept here
   * for those that reach no station yet (an app from before the stations kept them; a browser or a device new to the
   * workspace, which learns its relays from `/v1/me` alone, 2026-11-16). The newest record kept, as the stations keep
   * it (`at`, then the larger station id: station/src/mesh/ways.ts); one of a rig's, which keeps none, not. Cleaned as
   * setRelays and setWay clean, never every relay off. Told only when the ways changed: each station says its record
   * again as its socket opens.
   */
  #waysPut(station: string, workspace: string, body: Record<string, unknown>): void {
    const { at, station: by } = body;
    if (!Number.isSafeInteger(at) || (at as number) < 0 || typeof by !== "string" || by.length > 128 || !Array.isArray(body.relays) || !Array.isArray(body.off)) return;
    if (this.#db.one("SELECT rig FROM station_members WHERE station = ? AND workspace = ?", station, workspace)?.rig === 1) return;
    const row = this.#db.one("SELECT relays, ways_off, ways_at, ways_station FROM workspaces WHERE id = ?", workspace);
    if (!row) return;
    const was = { at: row.ways_at as number | null, station: (row.ways_station as string | null) ?? "" };
    if (was.at !== null && !((at as number) > was.at || (at === was.at && by > was.station))) return;
    const currentRelays = this.#db.relays(this.#host.meshRelays());
    const ours = relayUrls(currentRelays);
    const insecure = this.#db.env.PUBLIC_ORIGIN.startsWith("http:");
    const list: string[] = [];
    for (const raw of body.relays) {
      const url = typeof raw === "string" && URL.canParse(raw.trim()) ? new URL(raw.trim()) : null;
      if (!url || !(url.protocol === "https:" || (insecure && url.protocol === "http:")) || url.username || url.password || url.search || url.hash) continue;
      const clean = url.href.replace(/\/+$/, "");
      if (list.length < MAX_RELAYS && !ours.some((u) => sameUrl(u) === sameUrl(clean)) && !list.some((u) => sameUrl(u) === sameUrl(clean))) list.push(clean);
    }
    // What is off: `ours`, a kind of way, or a relay of still.fail's or of its own (as listed); else nothing.
    let off: string[] = [];
    for (const w of body.off) {
      if (typeof w !== "string") continue;
      const id = w === "ours" || (WAY_KINDS as readonly string[]).includes(w) ? w : [...ours, ...list].find((u) => sameUrl(u) === sameUrl(w));
      if (id !== undefined && !off.includes(id)) off.push(id);
    }
    // (as the stations' keepRelayOn: still.fail's back on rather than none)
    if (!waysOf(this.#db.relays(this.#host.meshRelays()), list, off).some((w) => w.kind === "relay" && w.on)) off = off.filter((o) => o !== "ours" && !ours.some((u) => sameUrl(u) === sameUrl(o)));
    const nextRelays = list.length ? JSON.stringify(list) : null;
    const waysOff = off.length ? JSON.stringify(off) : null;
    this.#db.run("UPDATE workspaces SET relays = ?, ways_off = ?, ways_at = ?, ways_station = ? WHERE id = ?", nextRelays, waysOff, at as number, by, workspace);
    if (nextRelays !== ((row.relays as string | null) ?? null) || waysOff !== ((row.ways_off as string | null) ?? null)) this.#host.changed(workspace, true);
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment;
    try {
      ws.close(code === 1005 || code === 1006 ? 1000 : code);
    } catch {
      // The runtime completed the close.
    }
    if ("station" in attachment && !attachment.dropped) this.#offline(attachment.station);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    const attachment = ws.deserializeAttachment() as Attachment;
    if ("station" in attachment && !attachment.dropped) this.#offline(attachment.station);
  }

  async alarm(sweepFn: (now: number) => boolean): Promise<void> {
    if (sweepFn(Date.now())) await this.#db.ctx.storage.setAlarm(Date.now() + SILENT_MS); // timer: a heartbeat's check, the stations' pings
    this.flush();
    await Promise.all(this.#sending.values());
  }

  /** Drops station sockets silent at `now`; says whether any station is still connected. */
  sweep(now: number): boolean {
    let connected = false;
    for (const ws of this.#db.ctx.getWebSockets()) {
      const attachment = ws.deserializeAttachment() as Attachment;
      if (!("station" in attachment) || attachment.dropped || ws.readyState !== WebSocket.OPEN) continue;
      const answered = this.#db.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
      if (now - Math.max(attachment.at, answered) > SILENT_MS) {
        this.drop(ws, CLOSE.silent, "silent");
        this.#offline(attachment.station);
      } else connected = true;
    }
    return connected;
  }
}
