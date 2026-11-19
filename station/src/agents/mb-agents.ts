// Every runtime's processes read by the MoonBit program (station/mb's reader `--sessions`, mb/src/reader/agents.mbt;
// agents/mb-program.ts), not on the station's thread: Claude Code's, Codex app-servers (agents_codex.mbt), DeepSeek
// Harness', Cursor's and the ACP runtimes' (agents_own.mbt). The program attaches to each process's runner, reads its
// output and says what it comes to (the runtime's events, where the turn stands, the lines Node answers, up to where it
// read), which this hands the session and acknowledges once handed, the line then acknowledged to the runner; what a
// crash reads again of an output is read there too (`replayOwn`, Codex's `replay`). A process is started and ended here
// (runner.ts); only reading it, and writing to it, go through the program (a runner's pipe on Windows opened by the
// shell as a Unix socket is elsewhere). The program is built for every system a station runs on, so there is no
// reading of a process's lines in TypeScript to fall back to (as with the actors, mb-actor.ts).
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { mbReaderBinary } from "../read/mb-reader.ts";
import { SessionsProgram, type ProgramUser } from "./mb-program.ts";
import { platform } from "../platform/index.ts";
import { describeExit, endRunner, groupAlive } from "./process.ts";
import { leave, startRunner, type RunnerInfo } from "./runner.ts";

type Json = any;

/// What the program says of a process's lines: the events, the turn as it left it, up to where.
/// `lines`, `marks`, `threads`: a Codex app-server's (`kind` "codex", mb agents_codex.mbt): the lines Node reads, each
/// with where it begins and ends; the turns' starts and ends of threads no session has; each session's thread's events
/// and live steps as they stand after them, with its batch where the program keeps them for its actor.
/// `lines` for the others (`kind` "dsh", "cursor", "acp", "pi", mb agents_own.mbt): the lines that answer Node's requests
/// or ask something of it.
/// `batch`: the events are kept by the program to give the session's actor there once its owner took them (`route`);
/// `routed`: they are, so the session's owner says it took them (its router) and the program, not Node, acknowledges.
export type Heard = {
  events: Json[];
  turn: Json;
  to: number;
  lines?: { text: string; from: number; to: number }[];
  marks?: [string, number, number, number][];
  threads?: CodexHeard[];
  batch?: number;
  routed?: boolean;
};

/// A Codex thread's events as the program read them (mb `codex_tell`).
export type CodexHeard = { thread: string; events: Json[]; live: Json; batch?: number };

/// What takes a batch the program keeps for the actor in the same program (mb-actor.ts): told the batch, once its
/// events are had here; false: it was not, so it is acknowledged as before (its events not given there).
export type Router = { program: SessionsProgram; took: (batch: number, proc?: number) => boolean };

/// How a process's lines are read: Claude Code's frames, a Codex app-server's JSON-RPC, DeepSeek Harness' or Cursor's
/// driver's lines (dsh-bridge.mjs, cursor-bridge.mjs), an ACP runtime's JSON-RPC, Pi's RPC.
export type HostedKind = "claude" | "codex" | "dsh" | "cursor" | "acp" | "pi";

export type HostedOptions = {
  label: string;
  /// true: a batch of it was taken by its actor in the program, which acknowledges it then; a promise: it is, once
  /// that is done (what the session writes of it on the disk), what comes after it held till then.
  heard: (heard: Heard) => boolean | void | Promise<void>;
  /// How its lines are read (Claude Code's by default).
  kind?: HostedKind;
  /// An ACP runtime's: which ("agy", "grok", "devin", "hermes"), and whether the station keeps its transcript.
  flavor?: string;
  kept?: boolean;
  /// A Codex app-server's taken up while its sessions are: what comes for a thread not taken up yet is held for it.
  orphans?: boolean;
  /// Said to the program after each attach (again after it started again): what it has of the process (its threads).
  attached?: () => void;
  /// Another station took its runner over: what waits on its answers lets go.
  handed?: () => void;
  /// A promise: what it writes of its end is being written, what comes after held till then.
  exit: (said: string, stderr: string) => void | Promise<void>;
};

const pidAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// A wait on another process (a grace raced against its exit): the machine's time.
const sleep = wall.sleep;

export class AgentsHost {
  readonly #data: string;
  #proc: SessionsProgram | null = null;
  /// What it is to the program (mb-program.ts): the agents' part.
  readonly #user: ProgramUser = {
    actors: false,
    said: (said) => this.#said(said),
    exited: (code) => this.#exited(code),
  };
  #next = 0;
  readonly #sessions = new Map<number, HostedProcess>();
  readonly #freezes = new Map<number, (states: Record<string, { turn: Json; live: Json }>) => void>();
  /// A Codex app-server's output read again (`replay`), from when it is asked: what waits on its live steps, once it
  /// waits (`done`).
  readonly #replays = new Map<number, ((live: Record<string, Json>) => void) | null>();
  readonly #ownReplays = new Map<number, { done: (said: Json) => void; failed: (error: Error) => void }>();
  /// The processes whose reading a handover holds (`freeze`, till `thaw`): held again in a program started again.
  readonly #held = new Set<HostedProcess>();
  #closed = false;

  private constructor(data: string) {
    this.#data = data;
  }

  /// The program for `data`'s processes: one for every driver of the station (each taking it, `close` letting it go;
  /// it ends with the last). A checkout that did not build the program runs no Claude Code or Codex session.
  static where(data: string): AgentsHost {
    if (mbReaderBinary() === null) throw new Error("the station's MoonBit program (stillfail-reader) is not built here: every runtime's processes are read by its --sessions");
    let host = AgentsHost.#shared.get(data);
    if (host === undefined || host.#closed) AgentsHost.#shared.set(data, (host = new AgentsHost(data)));
    return host;
  }

  static readonly #shared = new Map<string, AgentsHost>();
  /// The drivers using it (`use`), each once: it ends once none is left (`close`).
  readonly #users = new Set<object>();

  use(user: object) {
    this.#users.add(user);
  }

  /// Let go by its last driver (`close`): it reads nothing more.
  get closed() {
    return this.#closed;
  }

  /// The program, started if it is not running: what is said to it before it is ready waits in its stdin. Never once
  /// closed: one started then would be held by what it reads, and nothing would end it (2026-11-16, a Codex turn
  /// opening as its station shut down: hub-e2e.test.ts's process never ended).
  #ensure(): SessionsProgram {
    if (this.#proc && !this.#proc.ended) return this.#proc;
    if (this.#closed) throw new Error("the station's agents were let go: no process is read any more");
    const proc = SessionsProgram.of(this.#data)!;
    this.#proc = proc;
    proc.use(this.#user);
    proc.post({ wall: wall.now() });
    return proc;
  }

  #exited(code: number) {
    // (ended here: it had nothing left to read, or the drivers are gone)
    if (this.#closed) return;
    log.warn("agents", "the program reading agents ended; starting it again", { code });
    this.#proc = null;
    // (what it read again of an output is lost with it: those threads' live steps as none were open; a handover holding
    // its reading goes on with what each process's session said last, hub.ts `handOver`)
    this.#settle("the program reading agents ended while it read an output again");
    // (each process read again from where it was acknowledged, the turn as its session knows it)
    const again = [...this.#sessions.values()];
    // (one being let go is gone with it: no `left` will come from this program, nor be asked of the next)
    for (const p of again) if (p.gone || p.detaching) p.left_();
    // timer: a retry after a failure, with a backoff (one that keeps ending is started again each second at most)
    wall.after(1_000, () => {
      if (this.#closed) return;
      for (const p of again) if (!p.gone && !p.detaching) this.attach(p);
      // (what a handover holds stays held: its answer, the states, was given already)
      const held = again.filter((p) => !p.gone && !p.detaching && this.#held.has(p));
      if (held.length > 0) this.post({ freeze: this.number(), only: held.map((p) => p.n) });
    });
  }

  #said(said: Json) {
    if (typeof said?.ownReplayed === "number") {
      const r = this.#ownReplays.get(said.ownReplayed);
      this.#ownReplays.delete(said.ownReplayed);
      r?.done(said);
      this.#idleIfNone();
      return;
    }
    if (typeof said?.replayed === "number") {
      const done = this.#replays.get(said.replayed);
      this.#replays.delete(said.replayed);
      done?.(said.live ?? {});
      this.#idleIfNone();
      return;
    }
    if (typeof said?.frozen === "number") {
      const done = this.#freezes.get(said.frozen);
      this.#freezes.delete(said.frozen);
      done?.(said.states ?? {});
      return;
    }
    const n = said?.lines ?? said?.exit ?? said?.closed ?? said?.left ?? said?.ended;
    const p = typeof n === "number" ? this.#sessions.get(n) : undefined;
    if (p === undefined) return;
    if (said.lines !== undefined) {
      let lines: Heard["lines"];
      if (Array.isArray(said.at)) {
        const body: Buffer = said.body ?? Buffer.alloc(0);
        let at = 0;
        lines = said.at.map(([from, to, length]: [number, number, number]) => {
          const text = body.subarray(at, at + length).toString("utf8");
          at += length;
          return { text, from, to };
        });
      }
      const heard: Heard = { events: Array.isArray(said.events) ? said.events : [], turn: said.turn, to: said.to, lines, batch: typeof said.batch === "number" ? said.batch : undefined };
      if (Array.isArray(said.marks)) heard.marks = said.marks;
      if (Array.isArray(said.threads)) heard.threads = said.threads;
      p.heard(heard);
    } else if (said.exit !== undefined) p.inTurn(() => p.exited_(said.code ?? null, said.signal ?? null, typeof said.stderr === "string" ? said.stderr : ""));
    else if (said.closed !== undefined) p.inTurn(() => p.closed_(typeof said.stderr === "string" ? said.stderr : ""));
    // (its socket closed once it was read to its end: nothing more of it to read)
    else if (said.ended !== undefined) p.inTurn(() => this.forget(p));
    else p.inTurn(() => p.left_());
  }

  post(message: Json) {
    this.#proc?.post(message);
  }

  /// Reads `p`'s process (again, after the program started again: from where it was acknowledged).
  attach(p: HostedProcess) {
    this.#ensure().hold(this.#user, true);
    this.#sessions.set(p.n, p);
    this.post({ attach: p.n, socket: p.info.socket, turn: p.turnNow(), live: p.liveNow(), kind: p.kind, ...p.flavor, ...(p.orphans ? { orphans: true } : {}), ...(p.routed ? { routed: true } : {}) });
    p.attached();
  }

  /// What a crash reads again of a Codex app-server's output, given the program a piece at a time (`feed`: each thread's
  /// notification as what its live steps are made of, mb agents_codex.mbt `replay`): each thread's live steps as it
  /// comes to (`done`).
  /// It holds the program from when it is asked: another's end while it is fed lets nothing go. `close` once it is
  /// done with (what was never waited on, or failed on the way, let go).
  replay(): { feed: (notices: Json[][]) => void; done: () => Promise<Record<string, Json>>; close: () => void } {
    this.#ensure().hold(this.#user, true);
    const id = this.number();
    this.#replays.set(id, null);
    return {
      feed: (notices) => {
        if (notices.length > 0) this.post({ codexReplay: id, notices });
      },
      done: () => new Promise((resolve) => {
        // (let go meanwhile, the program's answer already given: none comes)
        if (!this.#replays.has(id)) return resolve({});
        this.#replays.set(id, resolve);
        this.post({ codexReplayed: id });
      }),
      close: () => {
        if (this.#replays.get(id) !== null) return;
        this.#replays.delete(id);
        this.#idleIfNone();
      },
    };
  }

  /// What a station that crashed had read of a process's output (its runner's `file`, up to `at`), read again by the
  /// program as `kind` reads it (`flavor`, `kept`, `resume`: an ACP runtime's): the session, its turn and live steps it
  /// comes to (mb agents_own.mbt `own_replay`).
  replayOwn(kind: HostedKind, file: string, at: number, extra: Json = {}): Promise<Json> {
    this.#ensure().hold(this.#user, true);
    const id = this.number();
    return new Promise((done, failed) => {
      this.#ownReplays.set(id, { done, failed });
      this.post({ ownReplay: id, kind, path: file, at, ...extra });
    });
  }

  /// Nothing of it read: the program let go (started again for the next).
  /// Let go once nothing is read or read again.
  #idleIfNone() {
    if (this.#sessions.size === 0 && this.#replays.size === 0 && this.#ownReplays.size === 0) this.#idle();
  }

  #idle() {
    if (this.#proc === null) return;
    const proc = this.#proc;
    this.#proc = null;
    void proc.release(this.#user);
  }

  /// The program its processes are read by now (null: none running).
  program(): SessionsProgram | null {
    return this.#proc;
  }

  number() {
    return ++this.#next;
  }

  forget(p: HostedProcess) {
    this.#sessions.delete(p.n);
    this.#held.delete(p);
    // (it runs while it has a process to read: started again for the next)
    this.#idleIfNone();
  }

  /// Every process's lines held (the station hands over): each one's turn and live steps as they stand then.
  /// `only`: those processes (a driver's own).
  async freeze(only: HostedProcess[]): Promise<void> {
    const held = only.filter((p) => this.#sessions.get(p.n) === p);
    if (this.#proc === null || held.length === 0) return;
    const id = this.number();
    for (const p of held) this.#held.add(p);
    const states = await new Promise<Record<string, { turn: Json; live: Json }>>((resolve) => {
      this.#freezes.set(id, resolve);
      this.post({ freeze: id, only: held.map((p) => p.n) });
    });
    // (what was told before it taken first: a session that writes some of it on the disk first holds what comes after)
    await Promise.all(held.map((p) => p.drained()));
    // (a Codex app-server's says its threads' live steps, which what was told before it already gave its sessions)
    for (const [n, state] of Object.entries(states)) if ("turn" in state) this.#sessions.get(Number(n))?.froze(state.turn, state.live);
  }

  /// Read on again (a handover that did not happen).
  thaw(only: HostedProcess[]) {
    for (const p of only) {
      this.#held.delete(p);
      if (this.#sessions.get(p.n) !== p) continue;
      p.thawed();
      this.post({ thaw: p.n });
    }
  }

  async close(user: object) {
    this.#users.delete(user);
    if (this.#users.size > 0 || this.#closed) return;
    this.#closed = true;
    if (AgentsHost.#shared.get(this.#data) === this) AgentsHost.#shared.delete(this.#data);
    const proc = this.#proc;
    this.#proc = null;
    // (nothing more will be said of what was asked of it: what waits on it goes on, a process being let go too)
    this.#settle();
    for (const p of [...this.#sessions.values()]) if (p.gone || p.detaching) p.left_();
    await proc?.release(this.#user);
  }

  /// What waits on the program's answer, answered as none will come: a freeze with no states (each session's own), a
  /// replay with no live steps, a read again failed.
  #settle(why = "the program reading agents was let go while it read an output again") {
    for (const done of this.#freezes.values()) done({});
    this.#freezes.clear();
    for (const done of this.#replays.values()) done?.({});
    this.#replays.clear();
    for (const r of this.#ownReplays.values()) r.failed(new Error(why));
    this.#ownReplays.clear();
  }
}

/// A process under a runner, read by the program, its lines told as `heard`.
export class HostedProcess {
  readonly info: RunnerInfo;
  readonly n: number;
  readonly #host: AgentsHost;
  readonly #options: HostedOptions;
  #frozen = false;
  gone = false;
  #killing = false;
  #said: string | null = null;
  /// The turn and live steps as they were last said: what the program takes up again with, and a snapshot says.
  #turn: Json;
  #live: Json;
  #frozenState: { turn: Json; live: Json } | null = null;
  readonly exited: Promise<string>;
  #resolveExit!: (said: string) => void;
  #left: (() => void) | null = null;
  /// Let go (`detach`), told the program once what it is taking now is taken.
  #detaching = false;
  #router: Router | null = null;
  /// What comes for a Codex thread not taken up yet is held for it (HostedOptions `orphans`), until `orphansOff`.
  #orphans: boolean;
  /// What its session is writing of what was told before (`heard`'s promise): what is told next waits for it.
  #waiting: Promise<void> | null = null;

  private constructor(host: AgentsHost, info: RunnerInfo, options: HostedOptions, turn: Json, live: Json) {
    this.#host = host;
    this.info = info;
    this.n = host.number();
    this.#options = options;
    this.#orphans = options.orphans === true;
    this.#turn = turn;
    this.#live = live;
    this.exited = new Promise((resolve) => (this.#resolveExit = resolve));
  }

  /// Starts `program` under a runner `id` (one of that id left by an earlier station ended first), read by `host`.
  /// Not once `host` is closed (its drivers shut down while this was on its way): the runner of that id may be the next
  /// station's by then, and what would be started now nobody would read or end.
  static async start(host: AgentsHost, data: string, id: string, program: string, args: string[], env: Record<string, string>, cwd: string, options: HostedOptions, turn: Json) {
    const closed = () => new Error(`${options.label} not started: the station's agents were let go`);
    if (host.closed) throw closed();
    await endRunner(data, id, options.label);
    const info = await startRunner(data, id, program, args, env, cwd);
    if (host.closed) {
      await endRunner(data, id, options.label, info);
      throw closed();
    }
    const p = new HostedProcess(host, info, options, turn, null);
    host.attach(p);
    return p;
  }

  /// Takes up the process a runner keeps, its turn and live steps as `turn` and `live` say: one its caller found
  /// listening, off the station's thread (process.ts `findRunner`, codex.ts `leftRunners`).
  static adopt(host: AgentsHost, info: RunnerInfo, options: HostedOptions, turn: Json, live: Json, router: Router | null = null) {
    const p = new HostedProcess(host, info, options, turn, live);
    if (router !== null && p.kind !== "codex" && host.program() === router.program) p.#router = router;
    host.attach(p);
    return p;
  }

  /// What it reads is given its session's actor in the program, where that is the program reading it (`router`):
  /// told here, as before, then taken there; null: told here only.
  route(router: Router | null) {
    if (router !== null && (this.kind === "codex" || this.#host.program() !== router.program)) router = null;
    const was = this.#router !== null;
    this.#router = router;
    if ((router !== null) !== was) this.#host.post({ route: this.n, on: router !== null });
  }

  /// A Codex app-server's thread's events given its session's actor in the program (`route`, by thread): the router
  /// that takes them, or null where none does.
  routeThread(thread: string, router: Router | null, was: boolean): Router | null {
    if (router !== null && (this.kind !== "codex" || this.#host.program() !== router.program)) router = null;
    if ((router !== null) !== was) this.#host.post({ route: this.n, on: router !== null, thread });
    return router;
  }

  /// A session's thread on a Codex app-server, its live steps as they stand: its notifications read for it from now on
  /// (with what was held for it while it was not taken up).
  acceptsRouter(router: Router): boolean { return this.#host.program() === router.program; }

  thread(thread: string, live: Json, routed = false) {
    this.#host.post({ codexThread: this.n, id: thread, live, ...(routed ? { routed: true } : {}) });
  }

  /// A thread no longer a session's.
  dropThread(thread: string) {
    this.#host.post({ codexDrop: this.n, id: thread });
  }

  /// No more is held for threads not taken up (`orphans`), nor once the program is started again.
  orphansOff() {
    this.#orphans = false;
    this.#host.post({ orphans: this.n, on: false });
  }

  get orphans() {
    return this.#orphans;
  }

  attached() {
    this.#options.attached?.();
  }

  get routed() {
    return this.#router !== null;
  }

  get kind(): HostedKind {
    return this.#options.kind ?? "claude";
  }

  /// What the program is told of an ACP runtime's as it attaches.
  get flavor(): Json {
    return this.#options.flavor === undefined ? {} : { flavor: this.#options.flavor, kept: this.#options.kept === true };
  }

  get pgid() {
    return this.info.pgid;
  }

  turnNow() {
    return this.#turn;
  }

  liveNow() {
    return this.#live;
  }

  /// Where it stood as its lines were held (a handover): what its snapshot says.
  frozenState() {
    return this.#frozenState;
  }

  /// What the program read, unless it is let go or held (then not acknowledged: the next station's); acknowledged once
  /// its session took it, or said taken by its actor, which the program acknowledges then. One its session began to
  /// take before it was let go or held is acknowledged all the same once taken.
  heard(heard: Heard) {
    this.inTurn(() => this.#take(heard));
  }

  /// `f` once what was told before it is taken (at once where nothing is being written).
  inTurn(f: () => void | Promise<void>) {
    if (this.#waiting !== null) {
      const next = this.#waiting.then(f);
      this.#waiting = next;
      void next.then(() => {
        if (this.#waiting === next) this.#waiting = null;
      });
      return;
    }
    const wait = f();
    if (wait instanceof Promise) {
      this.#waiting = wait;
      void wait.then(() => {
        if (this.#waiting === wait) this.#waiting = null;
      });
    }
  }

  /// Once what was told it is taken.
  async drained() {
    while (this.#waiting !== null) await this.#waiting;
  }

  #take(heard: Heard): void | Promise<void> {
    if (this.gone || this.#frozen) return;
    if (heard.turn !== undefined) this.#turn = heard.turn;
    const router = heard.batch !== undefined ? this.#router : null;
    if (router !== null) heard.routed = true;
    const taken = this.#options.heard(heard);
    // (taken, it is acknowledged though it was let go or held meanwhile: its session wrote it, and the next must not take
    // it again; `detach` is told the program after this ack, `inTurn`. 2026-11-17, devin.test.ts: a turn the next driver
    // never saw, its batch's ack dropped as it was let go while the transcript was written)
    const done = () => {
      if (taken === true || this.gone) return;
      // (acknowledged by the program as its actor takes them)
      if (router === null || !router.took(heard.batch!, this.n)) this.#host.post({ ack: this.n, to: heard.to });
    };
    if (taken instanceof Promise) return taken.then(done);
    done();
  }

  froze(turn: Json, live: Json) {
    this.#turn = turn;
    this.#live = live;
    this.#frozenState = { turn, live };
  }

  thawed() {
    this.#frozenState = null;
  }

  exited_(code: number | null, signal: string | null, stderr: string): void | Promise<void> {
    if (this.#said !== null) return;
    this.#said = describeExit({ code, signal });
    this.#resolveExit(this.#said);
    if (this.#frozen) return;
    const told = this.#options.exit(this.#said, stderr);
    if (!this.#killing) this.done();
    return told;
  }

  /// Its socket closed with no end told (`stderr`: the last lines its process wrote there).
  closed_(stderr = ""): void | Promise<void> {
    if (this.gone || this.#said !== null) return;
    // (the program keeps it till what it told before is taken: what was, was said before this on its stdin, and the
    // rest, held or let go here, is let go there with it)
    if (pidAlive(this.info.runner)) {
      log.warn("agents::process", "another station took the runner over; letting go", { label: this.#options.label });
      this.#options.handed?.();
      this.#frozen = true;
      this.gone = true;
      this.done();
      this.#host.forget(this);
      this.#leftNow();
    } else {
      this.#said = "runner gone";
      this.#resolveExit(this.#said);
      const told = this.#frozen ? undefined : this.#options.exit(this.#said, stderr);
      this.done();
      this.#host.forget(this);
      this.#leftNow();
      return told;
    }
  }

  left_() {
    this.#host.forget(this);
    this.#leftNow();
  }

  /// What waits on its letting go (`allLeft`) goes on, once.
  #leftNow() {
    const left = this.#left;
    this.#left = null;
    left?.();
  }

  /// Being let go: `detach` asked, the program not yet told.
  get detaching() {
    return this.#detaching && !this.gone;
  }

  hasExited() {
    return this.#said !== null;
  }

  handed() {
    return this.#frozen;
  }

  write(line: string) {
    if (this.#frozen) return;
    this.#host.post({ write: this.n, line });
  }

  /// What a prompt, an abort or a new token does to the turn before what goes with it is written (claude.ts `begin`,
  /// `compact`, `abort`, `renewToken`; a prompt of DeepSeek Harness' or Cursor's): the program keeps the turn.
  tell(what: "begin" | "compact" | "aborting" | "renewed") {
    if (this.#frozen) return;
    if (what === "compact") this.#host.post({ begin: this.n, compact: true });
    else this.#host.post({ [what]: this.n });
  }

  /// What an ACP session's owner says of it (`acpSession`, `acpOpened`, `acpPrompt`, `acpInject`: mb agents_own.mbt),
  /// before what goes with it is written.
  say(what: "acpSession" | "acpOpened" | "acpPrompt" | "acpInject", fields: Json = {}) {
    if (this.#frozen) return;
    this.#host.post({ [what]: this.n, ...fields });
  }

  /// Up to where its runner may give the disk back, told with the next ack (process.ts `keepFrom`).
  keepFrom(at: number) {
    this.#host.post({ keep: this.n, at });
  }

  freeze() {
    this.#frozen = true;
  }

  detach() {
    // (held at once: nothing told after this is taken, written or said)
    this.#frozen = true;
    if (this.gone || this.#detaching) return;
    this.#detaching = true;
    leave(new Promise<void>((resolve) => {
      this.#left = resolve;
      // (after what it is taking now is taken and acknowledged, `#take`: the runner reads on from there for the next)
      this.inTurn(() => {
        // (gone meanwhile, its socket closed or the program ended: nothing to tell)
        if (this.gone || this.#left === null) {
          this.left_();
          return;
        }
        this.gone = true;
        // (a pipe has no closing of one side: the runner is asked to close, runner.ts `detach`)
        this.#host.post({ detach: this.n, ...(platform.runnerSaysLeave ? { leave: true } : {}) });
      });
    }));
  }

  done() {
    this.#host.post({ done: this.n });
  }

  async released() {
    if (this.#frozen || this.#said === null) return;
    for (let i = 0; i < 1000 && pidAlive(this.info.runner); i++) await sleep(10);
  }

  async kill(graceMs: number) {
    if (this.#frozen) return;
    if (this.#killing) {
      await this.exited;
      return;
    }
    this.#killing = true;
    this.#host.post({ signal: this.n, name: "TERM" });
    await Promise.race([this.exited, sleep(graceMs)]);
    if (groupAlive(this.pgid)) {
      this.#host.post({ signal: this.n, name: "KILL" });
      for (let i = 0; i < 100 && groupAlive(this.pgid); i++) await sleep(10);
    }
    await Promise.race([this.exited, sleep(1000)]);
    this.done();
    for (let i = 0; i < 1000 && pidAlive(this.info.runner); i++) await sleep(10);
  }
}
