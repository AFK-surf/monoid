// The reads a device asks that the MoonBit program answers itself, not this process (station/mb's reader `--serve`,
// `serve.mbt`): the front hands it each request stream of a route given here (front.ts `route`, client/shell
// `conn.hand`), and it answers as serve.ts and the admin API would, its read in its own snapshot of the database. What
// only this process knows it is told: who each connection's member is, as serve.ts let them in (`viewer`, null once the
// connection is gone or no longer let in), people's names, the words of each language and the floors. It tells this
// process the build each device says (kept as serve.ts keeps it), and gives it what it does not answer itself
// (`fallback`: a read refused for what the pool prepares, a core that does not take every runtime), answered here.
import { sep, join } from "node:path";
import { mkdirSync, rmSync } from "node:fs";
import { tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { MbProcess, type ResolvedReaderSelection, engineOfSelection, fallbackModeOf } from "../read/mb-reader.ts";
import { COUNTED_FROM, OLDEST_CORE, stationBuild } from "../api/oldest.ts";
import { MOVED_FROM_BUILD } from "../../../shared/moved-from.ts";
import { RUNTIME_KINDS } from "../agents/runtime.ts";
import { READS_PENDING } from "../read/pool.ts";
import { LAST_KNOWN } from "../store/store.ts";

/// The routes answered there (api/routes/chats.ts, sessions.ts), every one a read moved to MoonBit; `*` a segment.
export const SERVED_ROUTES = [
  "GET /admin/api/chats",
  "GET /admin/api/sessions", "GET /admin/api/sessions/*", "GET /admin/api/sessions/*/timeline",
  "GET /admin/api/threads", "GET /admin/api/threads/*", "GET /admin/api/threads/*/entries", "GET /admin/api/threads/*/letters",
  // (not several of those in one, POST /admin/api/batch: a history brought on in the background is Node's, its reads
  // after every other a person waits on, one at a time, read/pool.ts; here it held one of the two programs for its
  // whole batch, and a person's read waited behind it)
  "GET /admin/api/jobs", "GET /admin/api/jobs/*", "GET /admin/api/jobs/*/log",
  // (a list read again as what changed of it: routes/changed.ts)
  "POST /admin/api/changed/chats", "POST /admin/api/changed/shared", "POST /admin/api/changed/sessions", "POST /admin/api/changed/threads",
  // (what changes, as it changes: made by Node's events, carried and compressed by the program, `relay`)
  "GET /admin/api/events",
  // (a member's own marks, written there: api/routes/marks.ts; what changed told the store's followers)
  "PUT /admin/api/threads/*/read", "PUT /admin/api/threads/*/hidden", "PUT /admin/api/threads/*/muted",
  "PUT /admin/api/threads/*/keep", "DELETE /admin/api/threads/*/keep", "PUT /admin/api/sessions/*/pin", "DELETE /admin/api/sessions/*/pin",
  // (a person's message in words and quotes: written there, delivered by Node; with files or copies Node's: `say`)
  "POST /admin/api/threads/*/messages",
  // (names given by hand, and a card the member will not take up: marks.ts)
  "POST /admin/api/sessions/*/title", "PUT /admin/api/threads/*/title", "PUT /admin/api/threads/*/dismissed",
];
/// How many of the program answer at once (each one read at a time, as a reader of the pool's).
const SERVERS = 2;
/// A program that ran this long before it ended is started again at once (its connections' streams go to its socket,
/// which the next one listens on); one that ends sooner, a second after, so one that keeps ending is not started again
/// and again.
export const SERVED_STEADY_MS = 5_000;
export const SERVED_AGAIN_MS = 1_000;
/// How long the programs are given to listen as the station starts: its connections are taken only after (mesh.ts).
const SERVED_LISTEN_MS = 15_000;

/// What a request given back is answered with.
export type Handled = { status: number; headers: Record<string, string>; body: Buffer };

/// A program answering (an MbProcess; a test's own).
export type ServingProcess = {
  on(event: "message", f: (said: any) => void): unknown;
  on(event: "error", f: (error: Error) => void): unknown;
  on(event: "exit", f: (code: number) => void): unknown;
  postMessage(message: unknown): void;
  terminate(): Promise<number>;
};

/// `ready`: listening, so on the routes the connections taken from now on go by (`onRoutes`).
/// `ended`: its process exited.
type Server = { process: ServingProcess; path: string; listening: Promise<void>; startedAt: number; ready: boolean; ended: boolean };

/// What a test gives in place of the programs and the machine's time, or an async binary resolver for restarts.
export type ServedWith = {
  spawn?: (binary: string, args: string[]) => ServingProcess;
  now?: () => number;
  after?: (ms: number, f: () => void) => () => void;
  resolveBinary?: () => Promise<string | ResolvedReaderSelection>;
};

export class Served {
  #binary: string | ResolvedReaderSelection;
  readonly #resolveBinary: (() => Promise<string | ResolvedReaderSelection>) | undefined;
  readonly #data: string;
  readonly #answer: (viewer: any, head: any, body: Buffer) => Promise<Handled>;
  readonly #stream: ((viewer: any, head: any, body: Buffer) => Promise<{ status: number; headers: Record<string, string>; body: Buffer | AsyncIterable<Buffer> }>) | undefined;
  /// The answers made as they come for each program, by its request's number: what lets each go when it stops.
  readonly #streaming = new Map<ServingProcess, Map<number, () => void>>();
  readonly #built: (viewer: any, build: number | null) => void;
  #servers: Server[] = [];
  /// What each connection's program is told of it, as said last (said again only as it changes).
  readonly #told = new Map<number, string>();
  readonly #names = new Map<string, string>();
  #closed = false;
  /// Past `start`: a program that ends or listens again changes the routes (`onRoutes`).
  #started = false;
  readonly #spawn: (binary: string | ResolvedReaderSelection, args: string[]) => ServingProcess;
  readonly #now: () => number;
  readonly #after: (ms: number, f: () => void) => () => void;
  /// The sockets of the programs listening now, said each time that changes after `start`: the front hands the
  /// connections it gives this process from then on to them alone (mesh.ts, front.ts `route`).
  onRoutes: ((paths: string[]) => void) | undefined;
  /// A person's message the program writes: claimed before (the key's first answer, the timestamp), told once written
  /// (admin.ts `claimSay`, `saidElsewhere`).
  says: {
    claim(viewer: any, path: string, key: string | null, lang: "zh" | "en"): Promise<{ kept: Handled } | { refused: Handled } | { ts: string; settle: (answer: Handled | null) => void }>;
    said(thread: number, n: number, text: string, row: Record<string, unknown>): void;
  } | undefined;
  /// What settles each claim's key once its answer is here, by its program and the claim's number (each program numbers
  /// its own from 0).
  readonly #claims = new Map<ServingProcess, Map<number, (answer: Handled | null) => void>>();
  /// What the program wrote (a device's marks), told the store's followers (store.ts `told`); `titled`, the chats it
  /// named by hand (store.ts `retitled`).
  changed: ((changes: any[], titled: number[]) => void) | undefined;

  /// `answer`: a request of a connection's member given back, answered as serve.ts answers one; `built`: the build a
  /// connection's device says.
  /// `stream`: one answered as it comes (GET /events), its body's pieces given the program as they are made.
  constructor(binary: string | ResolvedReaderSelection, data: string, answer: (viewer: any, head: any, body: Buffer) => Promise<Handled>, built: (viewer: any, build: number | null) => void,
    stream?: (viewer: any, head: any, body: Buffer) => Promise<{ status: number; headers: Record<string, string>; body: Buffer | AsyncIterable<Buffer> }>,
    given: ServedWith = {}) {
    this.#spawn = given.spawn
      ? ((bin, args) => given.spawn!(typeof bin === "string" ? bin : bin.primaryBinary, args))
      : ((bin, args) => typeof bin === "string"
        ? new MbProcess(bin, args)
        : new MbProcess(bin.primaryBinary, args, { engine: engineOfSelection(bin), fallbackMode: fallbackModeOf(bin.selection) }));
    this.#now = given.now ?? wall.now;
    this.#after = given.after ?? wall.after;
    this.#binary = binary;
    this.#resolveBinary = given.resolveBinary;
    this.#data = data;
    this.#answer = answer;
    this.#built = built;
    this.#stream = stream;
  }

  /// Where the programs listen, once each listened or ended, or `SERVED_LISTEN_MS` passed: those that listen by then,
  /// the rest put on the routes as they listen (`onRoutes`). One that neither listened nor ended in that time is ended
  /// (and started again as one that ended). None listening fails it: this process answers every request till one does.
  async start(): Promise<string[]> {
    for (let i = 0; i < SERVERS; i++) this.#servers.push(this.#start(i));
    let stop = () => {};
    const late = new Promise<void>((resolve) => (stop = this.#after(SERVED_LISTEN_MS, resolve))); // timer: a deadline on child processes starting
    await Promise.race([Promise.allSettled(this.#servers.map((s) => s.listening)), late]).finally(stop);
    this.#started = true;
    for (const s of this.#servers) {
      if (!s.ready && !s.ended) {
        log.warn("served", "a serving program did not listen in time; ending it", { path: s.path });
        void s.process.terminate().catch(() => {});
      }
    }
    const live = this.#livePaths();
    if (live.length === 0) throw new Error("no serving program listens");
    return live;
  }

  /// The sockets of the programs listening now.
  #livePaths(): string[] {
    return this.#servers.filter((s) => s.ready).map((s) => s.path);
  }

  #start(i: number, binary = this.#binary): Server {
    // (this process's own: the next one in a handover has its own, the front giving it the connections it takes)
    const path = join(this.#data, "run", `serve-${process.pid}-${i}.sock`);
    mkdirSync(join(this.#data, "run"), { recursive: true }); // sync: one step before the program listens there
    rmSync(path, { force: true }); // sync: one step before the program listens there
    const child = this.#spawn(binary, ["--data", this.#data, "--sep", sep, "--serve", path]);
    let listened = () => {};
    let failed = (_: Error) => {};
    const listening = new Promise<void>((resolve, reject) => ((listened = resolve), (failed = reject)));
    // (`start` waits on it; one started again later, nothing)
    listening.catch(() => {});
    const server: Server = { process: child, path, listening, startedAt: this.#now(), ready: false, ended: false };
    child.on("message", (said: any) => {
      if (typeof said?.listening === "string") {
        this.#settle(server);
        server.ready = true;
        listened();
        if (this.#started && !this.#closed) this.onRoutes?.(this.#livePaths());
      } else if (said?.build !== undefined) {
        const viewer = this.#viewerOf(Number(said.build.conn));
        if (viewer !== null) this.#built(viewer, typeof said.build.build === "number" ? said.build.build : null);
      }
      else if (typeof said?.fallback === "number") void (said.stream === true ? this.#relay(server, said) : this.#fallback(server, said));
      else if (Array.isArray(said?.changes)) this.changed?.(said.changes, Array.isArray(said.titled) ? said.titled : []);
      else if (typeof said?.claim === "number") void this.#claim(server, said);
      else if (said?.said !== undefined) this.#said(server, said);
      else if (typeof said?.stop === "number") this.#streaming.get(child)?.get(said.stop)?.();
    });
    child.on("error", (error: Error) => log.warn("served", "a serving program failed", { error: error.message }));
    child.on("exit", (code: number) => {
      // (what it was given as it came goes with it, and a message it claimed and did not say written is not)
      for (const stop of this.#streaming.get(child)?.values() ?? []) stop();
      this.#streaming.delete(child);
      const claims = this.#claims.get(child);
      this.#claims.delete(child);
      for (const settle of claims?.values() ?? []) settle(null);
      this.#queued.delete(server);
      server.ready = false;
      server.ended = true;
      failed(new Error(`a serving program ended (${code})`));
      if (this.#closed) return;
      const at = this.#servers.indexOf(server);
      if (at < 0) return;
      // Off the routes the connections taken from now on go by, till the next one listens.
      if (this.#started) this.onRoutes?.(this.#livePaths());
      const restartWith = (nextBinary?: string | ResolvedReaderSelection) => {
        if (this.#closed || this.#servers[at] !== server) return;
        try {
          if (nextBinary !== undefined) this.#binary = nextBinary;
          this.#servers[at] = this.#start(i, nextBinary ?? this.#binary);
        } catch (err) {
          if (this.#closed || this.#servers[at] !== server) return;
          log.warn("served", "starting serving program failed; retrying after backoff", {
            error: err instanceof Error ? err.message : String(err),
          });
          this.#after(SERVED_AGAIN_MS, again); // timer: a retry after a failure, with a backoff
        }
      };
      const again = () => {
        if (this.#closed || this.#servers[at] !== server) return;
        if (this.#resolveBinary === undefined) {
          restartWith();
          return;
        }
        void this.#resolveBinary().then(
          (nextBinary) => restartWith(nextBinary),
          (err) => {
            if (this.#closed || this.#servers[at] !== server) return;
            log.warn("served", "resolving serving binary failed; retrying after backoff", {
              error: err instanceof Error ? err.message : String(err),
            });
            this.#after(SERVED_AGAIN_MS, again); // timer: a retry after a failure, with a backoff
          },
        );
      };
      if (this.#now() - server.startedAt >= SERVED_STEADY_MS) {
        log.warn("served", "a serving program ended; starting it again", { code });
        again();
      } else {
        log.warn("served", "a serving program ended soon after it started; starting it again in a second", { code });
        this.#after(SERVED_AGAIN_MS, again); // timer: a retry after a failure, with a backoff (one that keeps ending is started again each second at most)
      }
    });
    return server;
  }

  /// A program that listens told all it is to know.
  #settle(server: Server) {
    const words = Object.fromEntries((["zh", "en"] as const).map((lang) => [lang, {
      // (a device's reads say no words: the client says them, read/pool.ts `WORDED`; what it is refused writing is said)
      updateApp: tr(lang, "station.admin.updateApp"), badN: tr(lang, "station.admin.badN"),
      postOnlyStillfail: tr(lang, "station.admin.postOnlyStillfail"), emptyMessage: tr(lang, "station.admin.emptyMessage"),
      renameOnlyStillfail: tr(lang, "station.admin.renameOnlyStillfail"), nothingWaiting: tr(lang, "station.admin.nothingWaiting"), updateClientForOption: tr(lang, "station.admin.updateClientForOption"),
      // (a write to a chat handed to another station: seen.ts `went`)
      movedThere: tr(lang, "station.move.movedThere"),
    }]));
    server.process.postMessage({
      set: { lastKnown: LAST_KNOWN, words, oldestCore: OLDEST_CORE, countedFrom: COUNTED_FROM, movedFromBuild: MOVED_FROM_BUILD, build: stationBuild(), runtimes: RUNTIME_KINDS, pending: READS_PENDING },
      wall: wall.now(),
    });
    if (this.#names.size > 0) server.process.postMessage({ names: [...this.#names] });
    for (const told of this.#told.values()) server.process.postMessage(JSON.parse(told));
  }

  /// Who connection `conn`'s member is now (null: gone, or no longer let in), whether its workspace's chain moved, and
  /// the build under which a core is too old there (serve.ts `movedFloor`; null: none). A program from before `floor`
  /// goes by `moved` alone, under MOVED_FROM_BUILD.
  viewer(conn: number, viewer: { email: string; name?: string } | null, moved = false, floor: number | null = null) {
    if (viewer !== null && viewer.name !== undefined && viewer.name !== "" && this.#names.get(viewer.email) !== viewer.name) {
      this.#names.set(viewer.email, viewer.name);
      this.#tell({ names: [[viewer.email, viewer.name]] });
    }
    const told = JSON.stringify({ viewer: { conn, viewer, moved, floor } });
    if (this.#told.get(conn) === told) return;
    if (viewer === null) this.#told.delete(conn);
    else this.#told.set(conn, told);
    this.#tell({ ...JSON.parse(told), wall: wall.now() });
  }

  /// Connection `conn`'s member as told last; null for none.
  #viewerOf(conn: number): any {
    const told = this.#told.get(conn);
    return told === undefined ? null : JSON.parse(told).viewer.viewer;
  }

  #tell(said: unknown) {
    for (const s of this.#servers) s.process.postMessage(said);
  }

  async #fallback(server: Server, said: { fallback: number; conn: number; head: any; body?: string }) {
    let handled: Handled;
    try {
      const viewer = this.#viewerOf(Number(said.conn));
      handled = viewer === null ? { status: 502, headers: { "content-type": "application/json" }, body: Buffer.from('{"error":"the connection is gone"}') }
        : await this.#answer(viewer, said.head, Buffer.from(said.body ?? ""));
    } catch (e) {
      handled = { status: 500, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify({ error: (e as Error).message })) };
    }
    server.process.postMessage({ answered: said.fallback, status: handled.status, headers: handled.headers, text: handled.body.toString() });
  }

  /// A request the program writes as it comes (`stream`: GET /events): its head, then each piece, then its end.
  async #relay(server: Server, said: { fallback: number; conn: number; head: any; body?: string }) {
    const n = said.fallback;
    const viewer = this.#viewerOf(Number(said.conn));
    const post = (m: unknown) => server.process.postMessage(m);
    let answer;
    try {
      if (viewer === null || this.#stream === undefined) throw new Error("the connection is gone");
      answer = await this.#stream(viewer, said.head, Buffer.from(said.body ?? ""));
    } catch (e) {
      post({ answered: n, status: 500, headers: { "content-type": "application/json" } });
      post({ chunk: n, text: JSON.stringify({ error: (e as Error).message }) });
      return post({ done: n });
    }
    post({ answered: n, status: answer.status, headers: answer.headers });
    if (Buffer.isBuffer(answer.body)) {
      if (answer.body.length > 0) post({ chunk: n, text: answer.body.toString() });
      return post({ done: n });
    }
    // A body that is told as it is made (api/events.ts `relay`): each piece given here at once, one told several streams
    // of this program at once given it once (`#tell`).
    const relay = (answer.body as { relay?: (send: (text: string) => void, ended: () => void) => void }).relay;
    if (relay !== undefined) {
      let streams = this.#streaming.get(server.process);
      if (streams === undefined) this.#streaming.set(server.process, (streams = new Map()));
      const body = answer.body as AsyncIterableIterator<Buffer>;
      let over = false;
      streams.set(n, () => {
        over = true;
        void body.return?.();
      });
      relay.call(answer.body, (text) => this.#piece(server, n, text), () => {
        streams!.delete(n);
        if (!over) this.#piece(server, n, null);
      });
      return;
    }
    const pieces = answer.body[Symbol.asyncIterator]();
    let streams = this.#streaming.get(server.process);
    if (streams === undefined) this.#streaming.set(server.process, (streams = new Map()));
    let stopped = false;
    streams.set(n, () => {
      stopped = true;
      void pieces.return?.();
    });
    try {
      for (;;) {
        const next = await pieces.next();
        if (next.done || stopped) break;
        post({ chunk: n, text: Buffer.from(next.value).toString() });
      }
    } finally {
      streams.delete(n);
      if (!stopped) post({ done: n });
    }
  }

  /// What is to be told each program, in order, till the turn ends: a piece told several of its streams in a row is
  /// the one text, given once with them all (`pieces`); `null`, a stream's end.
  readonly #queued = new Map<Server, { text: string | null; to: number[] }[]>();

  #piece(server: Server, n: number, text: string | null) {
    let pending = this.#queued.get(server);
    if (pending === undefined) {
      this.#queued.set(server, (pending = []));
      queueMicrotask(() => {
        this.#queued.delete(server);
        for (const p of pending!) {
          if (p.text === null) for (const k of p.to) server.process.postMessage({ done: k });
          else if (p.to.length === 1) server.process.postMessage({ chunk: p.to[0], text: p.text });
          else server.process.postMessage({ pieces: p.text, to: p.to });
        }
      });
    }
    const last = pending.at(-1);
    if (last !== undefined && last.text === text && text !== null) last.to.push(n);
    else pending.push({ text, to: [n] });
  }

  async #claim(server: Server, said: { claim: number; conn: number; path: string; key?: string | null; lang?: string }) {
    const n = said.claim;
    const viewer = this.#viewerOf(Number(said.conn));
    const give = (m: Record<string, unknown>) => server.process.postMessage({ claimed: n, ...m });
    const text = (h: Handled) => ({ status: h.status, headers: h.headers, text: h.body.toString() });
    if (viewer === null || this.says === undefined) return give({ refused: { status: 503, headers: { "content-type": "application/json" }, text: '{"error":"station starting"}' } });
    try {
      const got = await this.says.claim(viewer, said.path, said.key ?? null, said.lang === "en" ? "en" : "zh");
      if ("kept" in got) return give({ kept: text(got.kept) });
      if ("refused" in got) return give({ refused: text(got.refused) });
      // (its program ended meanwhile: nobody is to say it written)
      if (server.ended) return got.settle(null);
      let claims = this.#claims.get(server.process);
      if (claims === undefined) this.#claims.set(server.process, (claims = new Map()));
      claims.set(n, got.settle);
      give({ ts: got.ts });
    } catch (e) {
      give({ refused: { status: 500, headers: { "content-type": "application/json" }, text: JSON.stringify({ error: (e as Error).message }) } });
    }
  }

  #said(server: Server, said: { said: { thread: number; n: number; text: string; row: Record<string, unknown> } | null; of: number; answer?: { status: number; headers: Record<string, string>; text: string } }) {
    if (said.said !== null) this.says?.said(said.said.thread, said.said.n, said.said.text, said.said.row);
    const claims = this.#claims.get(server.process);
    const settle = claims?.get(said.of);
    claims?.delete(said.of);
    settle?.(said.answer === undefined ? null : { status: said.answer.status, headers: said.answer.headers, body: Buffer.from(said.answer.text) });
  }

  async close() {
    this.#closed = true;
    await Promise.all(this.#servers.map((s) => s.process.terminate()));
    for (const s of this.#servers) rmSync(s.path, { force: true }); // sync: the station stopping
  }
}
