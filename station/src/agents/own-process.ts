// A runtime that runs each session in a process of its own (Claude Code, DeepSeek Harness, Cursor, Grok Build, Devin,
// Hermes Agent, Antigravity CLI; not Codex, whose sessions share their profile's app-server): the process under a
// runner whose id comes from the session key (./runner.ts), read by the station's MoonBit program (./mb-agents.ts), so
// that a station starting again takes it up, from the snapshot the one before left at handover or, after a crash, from
// what that one had handled of its output, which the program reads again (`replayOwn`). What every such driver does is
// here: the sessions it has, starting a process and taking one up, its lines held while the station hands over, its
// requests waiting for their answers, what the program tells of it (the runtime's events, given its actor in the
// program where it is there, and the lines it answers itself), the process going away (a turn running fails as exited,
// then the session closes), letting it go. What a runtime is told and says is each driver's, and how its lines are
// read the program's.
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { ackedOffset, debug, findRunner, outFile, runnerId } from "./process.ts";
import type { RunnerInfo } from "./runner.ts";
import { AgentsHost, HostedProcess, type Heard, type HostedKind, type HostedOptions, type Router } from "./mb-agents.ts";
import type { AgentDriver, AgentSession, OpenOptions, RuntimeEvent, RuntimeKind } from "./runtime.ts";

type Json = any;
export type Events = (event: RuntimeEvent) => void;

/// Where a session's turn stands, as its handled lines leave it.
export type TurnState = { busy: boolean; aborting: boolean; closed: boolean };

/// What every such session's snapshot says (each runtime's says more).
export type ProcessSnapshot = { runtime: RuntimeKind; id: string; runner: string; turn: { busy: boolean } };

/// What the program read again of the output of a process a station had when it crashed (mb agents_own.mbt
/// `own_replay`): the session the runtime named there, where its turn stands and its live steps (an ACP runtime's: the
/// whole of its reading), and an ACP runtime's answer to its opening and its updates of usage.
export type Replayed = { session?: string | null; turn: Json; live: Json; opened?: Json; usages?: Json[] };

/// How long a runtime has to answer a request of ours: opening a long session it loads included.
export const ANSWER_MS = 120_000;

/// A line of a runtime's output as the JSON it is (one that is not: nothing, said when debugging).
export function parseLine(kind: RuntimeKind, line: string): Json | undefined {
  try {
    return JSON.parse(line);
  } catch {
    debug(`agents::${kind}`, `${kind} non-json line`, { line: line.slice(0, 500) });
    return undefined;
  }
}

/// A session's requests waiting for their answers, by the id each was sent with.
export class Waiting {
  private waits = new Map<string, { answered: (answer: Json) => void; failed: (error: Error) => void }>();

  /// The answer to the request `id` (to be sent once this is asked): one `refused` makes an error of rejects, and so
  /// does no answer within `ms` (saying `late`, where there is a likely why).
  wait(id: string, refused: (answer: Json) => Error | null, late?: string, ms = ANSWER_MS): Promise<Json> {
    return new Promise((resolve, reject) => {
      const cancel = wall.after(ms, () => this.fail(id, new Error(late ?? `no answer to ${id} in ${ms / 1000} s`)));
      this.waits.set(id, {
        answered: (answer) => {
          cancel();
          const error = refused(answer);
          if (error === null) resolve(answer);
          else reject(error);
        },
        failed: (error) => {
          cancel();
          reject(error);
        },
      });
    });
  }

  /// An answer came: whether it was waited for.
  answer(id: unknown, answer: Json): boolean {
    const wait = typeof id === "string" ? this.waits.get(id) : undefined;
    if (wait === undefined) return false;
    this.waits.delete(id as string);
    wait.answered(answer);
    return true;
  }

  /// Gives up on one.
  fail(id: string, error: Error) {
    const wait = this.waits.get(id);
    this.waits.delete(id);
    wait?.failed(error);
  }

  /// Gives up on all of them (the process went away, the session closed).
  failAll(error: Error) {
    const waits = [...this.waits.values()];
    this.waits.clear();
    for (const wait of waits) wait.failed(error);
  }
}

/// How the program reads a runtime's processes, and what it is told of them as it attaches (an ACP runtime's flavor).
export type Hosting = { kind: HostedKind; flavor?: string; kept?: boolean };

export abstract class OwnProcessDriver<S extends OwnProcessSession = OwnProcessSession> implements AgentDriver {
  protected readonly data: string;
  protected readonly live = new Set<S>();
  /// What reads its processes' output off the station's thread: the MoonBit program, one for every driver.
  protected readonly agents: AgentsHost;
  /// The runners of processes it is starting or taking up, not yet a session's of `live`.
  private readonly claimed = new Set<string>();

  constructor(data: string, agents?: AgentsHost) {
    this.data = data;
    this.agents = agents ?? AgentsHost.where(data);
    this.agents.use(this);
  }

  abstract runtime(): RuntimeKind;
  abstract open(options: OpenOptions, events: Events): Promise<AgentSession>;
  /// How the program reads its processes.
  abstract hosting(): Hosting;
  /// The session a snapshot says (the station before handed it over), on the process `info` keeps.
  protected abstract handedOver(options: OpenOptions, snapshot: Json, info: RunnerInfo, events: Events): S;
  /// The session the station before had when it crashed: what the program made of what that one had handled of the
  /// process's output, read again (silently) to know it and where its turn stands.
  protected abstract crashed(options: OpenOptions, replayed: Replayed, info: RunnerInfo, events: Events): S | Promise<S>;

  /// What the program is told besides to read again a process's output after a crash (the session it resumes).
  protected replaying(options: OpenOptions): Json {
    return options.resume === undefined ? {} : { resume: options.resume };
  }

  /// How its process is named in the log.
  protected label(options: OpenOptions, _session: S): string {
    return `${this.runtime()} ${options.key}`;
  }

  /// The runner `id` is this driver's while `work` starts or takes up its process, which is then a session's of `live`.
  protected async claiming<T>(id: string, work: () => Promise<T>): Promise<T> {
    this.claimed.add(id);
    try {
      return await work();
    } finally {
      this.claimed.delete(id);
    }
  }

  ownedRunners(): ReadonlySet<string> {
    const owned = new Set(this.claimed);
    for (const session of this.live) {
      const id = session.runner();
      if (id !== undefined) owned.add(id);
    }
    return owned;
  }

  /// Starts the process of a session being opened, which is one of this driver's from now on.
  protected async start(session: S, options: OpenOptions, command: string, args: string[], env: Record<string, string>) {
    const id = runnerId(this.runtime(), options.key);
    await this.claiming(id, async () => {
      session.attach(await HostedProcess.start(this.agents, this.data, id, command, args, env, options.cwd, session.hostedOptions(this.label(options, session)), session.turnNow()));
      this.live.add(session);
    });
  }

  async adopt(options: OpenOptions, snapshot: unknown | null, events: Events): Promise<S> {
    const handed = snapshot as ProcessSnapshot | null;
    const id = handed?.runner ?? runnerId(this.runtime(), options.key);
    return this.claiming(id, () => this.adoptOn(id, options, handed, events));
  }

  private async adoptOn(id: string, options: OpenOptions, handed: ProcessSnapshot | null, events: Events): Promise<S> {
    const kind = this.runtime();
    const info = await findRunner(this.data, id);
    if (!info) throw new Error(`no runner keeps ${kind} for ${options.key}`);
    let session: S;
    if (handed) {
      log.info(`agents::${kind}`, `taking up a ${kind} process handed over`, { session: handed.id, pgid: info.pgid, busy: handed.turn.busy });
      session = this.handedOver(options, handed, info, events);
    } else {
      const out = outFile(this.data, id);
      const { at } = await ackedOffset(info, out);
      options.taking?.();
      const hosting = this.hosting();
      const extra = { ...this.replaying(options), ...(hosting.flavor === undefined ? {} : { flavor: hosting.flavor, kept: hosting.kept === true }) };
      const replayed = (await this.agents.replayOwn(hosting.kind, out, at, extra)) as Replayed;
      options.taking?.();
      session = await this.crashed(options, replayed, info, events);
      // A process whose station went before its session was open (stuck on `initialize`, say) is no session to go on
      // with: refused before it is held, so `endOrphans` ends its runner and the session opens again the usual way.
      // Every runtime here but Claude Code speaks to open one (Claude Code is told its id as it starts and says nothing
      // before its first turn); Pi's id is the station's, never said back, so only its output tells for Pi.
      if ((hosting.kind !== "pi" && session.id() === "") || (hosting.kind !== "claude" && at === 0)) {
        throw new Error(`${kind} process for ${options.key} had not opened a session`);
      }
      log.info(`agents::${kind}`, `taking up a ${kind} process after a crash`, { session: session.id(), pgid: info.pgid, busy: session.busy(), from: at });
      // A turn is running that this station did not start.
      if (session.busy()) events({ type: "turnStarted" });
    }
    session.attach(HostedProcess.adopt(this.agents, info, session.hostedOptions(this.label(options, session)), session.turnNow(), session.liveNow(), options.router ?? null));
    await session.adopted();
    options.taking?.();
    this.live.add(session);
    return session;
  }

  /// Its processes' lines held while the station hands over (hub.ts `handOver`), and read on where it does not.
  async freeze() {
    await this.agents.freeze(this.hostedProcs());
  }

  thaw() {
    this.agents.thaw(this.hostedProcs());
  }

  /// Its sessions' processes the program reads.
  protected hostedProcs(): HostedProcess[] {
    return [...this.live].map((s) => s.hostedProc());
  }

  forget(session: S) {
    this.live.delete(session);
  }

  async shutdown(again = false) {
    const live = [...this.live];
    this.live.clear();
    await Promise.all(live.map((s) => s.dispose()));
    // (used again: its program ends once it has nothing to read, mb-agents.ts `forget`)
    if (!again) await this.agents.close(this);
  }

  detach() {
    for (const session of this.live) session.detach();
    this.live.clear();
  }
}

export abstract class OwnProcessSession<T extends TurnState = TurnState> implements AgentSession {
  /// Its process, as the program reads it (mb-agents.ts).
  protected proc!: HostedProcess;
  protected readonly driver: OwnProcessDriver<any>;
  protected sessionId: string;
  protected turn: T;
  /// Its live steps as the program last said them (a snapshot's, or what it read again after a crash): what the
  /// program takes up again with when it starts again, and a snapshot says where none was frozen.
  protected liveState: Json;
  protected readonly events: Events;
  /// Requests of ours waiting for their answers.
  protected readonly waiting = new Waiting();
  /// The address of the station's tools it was given (one taken up from another station: as it was given then).
  toolsUrl: string | null = null;

  constructor(driver: OwnProcessDriver<any>, sessionId: string, turn: T, events: Events, liveState: Json = null) {
    this.driver = driver;
    this.sessionId = sessionId;
    this.turn = turn;
    this.events = events;
    this.liveState = liveState;
  }

  /// A line of its output the program gives Node to read: an answer to a request of ours, or one of the runtime's.
  protected abstract heard(line: string): void;
  abstract prompt(text: string): Promise<void>;
  abstract steer(text: string): Promise<boolean>;
  abstract abort(): Promise<void>;
  abstract snapshot(): unknown;

  /// An event the program said for the session's owner itself, not one of the runtime's (true: taken here).
  protected took(_event: Json): boolean {
    return false;
  }

  /// What is being written of it on the disk, done (null: nothing is): what the program tells next waits for it, and
  /// a turn is not said ended before.
  protected settled(): Promise<void> | null {
    return null;
  }

  /// Its process went away during a turn: what is open of the turn ends with it (the program ends its steps).
  protected cutShort(_said: string): void {}

  /// No turn runs any more.
  protected idle() {
    this.turn.busy = false;
  }

  protected get kind(): RuntimeKind {
    return this.driver.runtime();
  }

  attach(proc: HostedProcess) {
    this.proc = proc;
  }

  /// Taken up (attached): once what it keeps is written.
  async adopted() {
    await this.settled();
  }

  /// Its process's runner, once it has one.
  runner(): string | undefined {
    return (this.proc as HostedProcess | undefined)?.info.id;
  }

  named(id: string) {
    this.sessionId = id;
  }

  /// What its process's lines are read with by the program (mb-agents.ts).
  hostedOptions(label: string): HostedOptions {
    const hosting = this.driver.hosting();
    return { label, ...hosting, heard: (heard: Heard) => this.heardHosted(heard), attached: () => this.attached(), exit: (said: string, stderr: string) => this.exited(said, stderr) };
  }

  /// Its process attached in the program (again, after the program started again: what it has of it is the turn and
  /// the live steps it was last told, `turnNow`, `liveNow`).
  protected attached() {}

  /// The turn as the program is told it (it keeps it from then on).
  turnNow(): Json {
    const { closed: _, ...turn } = this.turn;
    return turn;
  }

  liveNow(): Json {
    return this.liveState;
  }

  /// The turn as the program says it (a turn's start and end carry it, and what it read).
  protected take(t: Json) {
    if (t === null || typeof t !== "object") return;
    const closed = this.turn.closed;
    this.turn = { ...t, closed } as T;
  }

  /// What the program read of its lines: the lines it gives this to read, then its events in order, each turn's end
  /// said once what is written of the turn is (`settled`), and the whole taken once what it gave to be written is.
  protected heardHosted(heard: Heard): void | Promise<void> {
    for (const line of heard.lines ?? []) this.heard(line.text);
    return this.told(heard, 0);
  }

  private told(heard: Heard, from: number): void | Promise<void> {
    const events = heard.events;
    for (let i = from; i < events.length; i++) {
      const e = events[i];
      if (e?.type === "turnEnded") {
        const writing = this.settled();
        if (writing !== null) {
          return writing.then(() => {
            this.event(heard, e);
            return this.told(heard, i + 1);
          });
        }
      }
      this.event(heard, e);
    }
    this.take(heard.turn);
    // (acknowledged once what it gave to be written is: a crash reads again what is not, a handover's `drained` waits
    // for it, and what the program says after, its process's exit too, comes after it)
    return this.settled() ?? undefined;
  }

  private event(heard: Heard, e: Json) {
    if (this.took(e)) return;
    const { turn, ...event } = e;
    if (turn !== undefined) this.take(turn);
    // (given its actor by the program: here only what the station's own parts take of it)
    if (heard.routed === true) event.routed = true;
    this.events(event as RuntimeEvent);
  }

  hostedProc(): HostedProcess {
    return this.proc;
  }

  /// What its process reads is given its actor in the program too (mb-actor.ts), where that reads it.
  route(router: Router | null) {
    this.proc.route(router);
  }

  /// Its process went away: a turn running fails as exited, then the session closes, each said once what is written of
  /// it (its transcript's end) is.
  protected exited(said: string, stderr: string): void | Promise<void> {
    // What it wrote to stderr last is the only word of why one that fails as it starts gives.
    const why = stderr === "" ? "" : `: ${stderr}`;
    this.turn.closed = true;
    this.waiting.failAll(new Error(`${this.kind} exited (${said})${why}`));
    const busy = this.busy();
    this.idle();
    if (busy) this.cutShort(said);
    const told = () => {
      if (busy) this.events({ type: "turnEnded", outcome: { kind: "failed", reason: "exited", message: `${this.kind} exited (${said}) during the turn${why}` } });
      this.events({ type: "closed", why: `${this.kind} exited (${said})${why}` });
      this.driver.forget(this);
    };
    const writing = this.settled();
    if (writing !== null) return writing.then(told);
    told();
  }

  /// A turn can be started now: else why not.
  protected startable() {
    if (this.turn.closed) throw new Error(`${this.kind} session is closed`);
    if (this.busy()) throw new Error("a turn is already running");
  }

  /// Stops hearing it, for a snapshot: the turn stands as its last handled line left it, and the lines after are the
  /// next station's. Where it stood then, as the program said it (null: it was not read there).
  protected handOver(): { turn: Json; live: Json } | null {
    this.proc.freeze();
    this.turn.closed = true;
    return this.proc.frozenState();
  }

  id() {
    return this.sessionId;
  }

  mcpUrl() {
    return this.toolsUrl;
  }

  busy() {
    return this.turn.busy;
  }

  async backgroundTools() {}

  async dispose() {
    this.driver.forget(this);
    this.turn.closed = true;
    this.waiting.failAll(new Error(`${this.kind} session is closed`));
    await this.proc.kill(5000);
    await this.settled();
  }

  detach() {
    this.turn.closed = true;
    this.driver.forget(this);
    this.proc.detach();
  }
}
