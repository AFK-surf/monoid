// The Agent Client Protocol (JSON-RPC over stdio, agentclientprotocol.com) as the station speaks it to the runtimes that
// serve it (Antigravity CLI, Grok Build, Devin, Hermes Agent: agy.ts, grok.ts, devin.ts, hermes.ts), one ACP session in
// a process of its own (own-process.ts):
// - `initialize`, then `session/new` (the agent names the session) or `session/load` (one it keeps), given the station's
//   tools as an HTTP MCP server; what session/load says again of the session's past is no turn;
// - a turn is a `session/prompt`, ended by its answer: `stopReason` (`cancelled` after `session/cancel`), or an error
//   whose message says why it failed;
// - what the model says and does streams in `session/update`s: text and thinking in chunks, a call as `tool_call`, then
//   `tool_call_update`s until it completed or failed. A step with no turn running is not the session's turn's, unless a
//   prompt of ours put in the turn as it ended became a turn of its own;
// - a permission it asks is granted for the call (the station runs its agents without approvals); any other request of
//   its own is refused (what it would ask is asked in the chat);
// - a call to the station's tools failing as unreachable says the tools are lost.
// The updates and a prompt's answer are read by the station's MoonBit program (mb/src/acp, mb/src/reader
// agents_own.mbt), off the station's thread: what the model says is put together there, its steps given the session's
// actor there, and this is told what it keeps of them (the transcript's lines, a prompt's answer, the usage) and given
// the lines it answers (its requests' answers, the runtime's requests). What each runtime does its own way (how it is
// started and signed in, how it is given the station's instructions, a message for the running turn, what it says of
// its usage) is its driver's, by the hooks below; and so is a transcript kept by the station (KeptTranscript), for a
// runtime whose own the station cannot read.
import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import { appendFile } from "node:fs/promises";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { chars } from "./live.ts";
import { type Events, type Hosting, type ProcessSnapshot, type Replayed, OwnProcessDriver, OwnProcessSession, parseLine } from "./own-process.ts";
import { profileModel } from "./profiles.ts";
import type { RunnerInfo } from "./runner.ts";
import { runtimeLabel, uuid, type FailureReason, type OpenOptions, type RuntimeKind, type TurnOutcome } from "./runtime.ts";

type Json = any;

/// The ids of the requests the station makes. A prompt carries its own (prompt:<uuid>), and so does a prompt put in the
/// running turn (steer:<uuid>), so whatever answers one (after a crash too) is known for what it is.
export const INIT = "init";
export const OPEN = "open";
export const PROMPT = "prompt:";
export const STEER = "steer:";

const CLIENT = { name: "still.fail", version: "1" };

export const rpc = (id: string, method: string, params: Json) => JSON.stringify({ jsonrpc: "2.0", id, method, params });

/// The station's tools as ACP gives an MCP server.
export const mcpServers = (url: string, token: string) => [{ type: "http", name: "stillfail", url, headers: [{ name: "Authorization", value: `Bearer ${token}` }] }];

/// What an error answer says: its message, and its data's.
export function errorText(error: Json): string {
  const text = typeof error?.message === "string" ? error.message.replace(/^Internal error: /, "") : JSON.stringify(error);
  const data = typeof error?.data === "string" ? `: ${error.data}` : typeof error?.data?.message === "string" ? `: ${error.data.message}` : typeof error?.data?.details === "string" ? `: ${error.data.details}` : "";
  return `${text}${data}`;
}

/// How a prompt's answer ends the turn, told apart by `classify` when it failed. What the program reads a process by
/// does this (mb/src/acp `acp_outcome`); this is what it is held to.
export function acpOutcome(answer: Json, classify: (text: string) => FailureReason): TurnOutcome {
  if (answer?.error !== undefined) {
    const said = errorText(answer.error);
    return { kind: "failed", reason: classify(said), message: chars(said, 1000) };
  }
  const stop = answer?.result?.stopReason;
  if (stop === "cancelled") return { kind: "aborted" };
  if (stop === "refusal") return { kind: "failed", reason: "model", message: "the model refused" };
  return { kind: "completed" };
}

/// A call under way, as it started: its name (as the station names it: mb/src/acp `acp_named`), its input and when it
/// began.
export type Call = { name: string; input: Json; startedAt?: number };

/// What is being said, as a transcript keeps it: the step's kind and its text so far.
export type Said = { type: "assistant" | "thinking"; text: string };

/// Its live steps as the program keeps them (mb/src/acp `Live::state`).
export type AcpLiveState = { open: string[]; said: string | null; n: number; phase: string | null };

/// A session as a next station takes it up. What a station before this one's handed over may lack.
export type AcpSnapshot = ProcessSnapshot & {
  turn: { busy: boolean; aborting: boolean };
  tools: string | null;
  live: AcpLiveState;
  model?: string | null;
  owner?: string | null;
  steering?: string[];
  said?: Said | null;
  calls?: [string, Call][];
  /// What the model said last in the running turn, and Grok Build's subagents' steps (mb/src/acp `Session::state`).
  saidLast?: string;
  children?: [string, Json][];
};

/// The transcript the station keeps of a session whose runtime keeps none it can read (Devin keeps its sessions in a
/// database of its own; Hermes'; Antigravity CLI's): <dir>/<session id>.jsonl, a line for each thing said and done, as
/// Cursor's bridge keeps its own (read/transcript.ts reads them alike): the person's messages, what was said once whole
/// (something else came), a call once done with what it said, the turn's usage, its end. The program says each line
/// (mb/src/acp `kept`) but the session's opening, a turn's usage and an end by its process exiting; each is written in
/// turn off the station's thread, a turn's end said once what came before it is (`settled`).
/// How much of a kept transcript's end is read for its running turn (lastOfTurn).
const TAIL = 1 << 20;

export class KeptTranscript {
  private readonly kind: RuntimeKind;
  private readonly dir: string;
  /// Read again after a crash: what was written then is not written twice.
  private quiet = false;
  /// What is being written, in order.
  #writing: Promise<void> | null = null;

  constructor(kind: RuntimeKind, dir: string) {
    this.kind = kind;
    this.dir = dir;
  }

  keep(id: string, line: Json) {
    if (id === "" || this.quiet) return;
    const text = `${JSON.stringify({ time: wall.now(), ...line })}\n`;
    const path = join(this.dir, `${id}.jsonl`);
    const write = async () => {
      try {
        await appendFile(path, text);
      } catch (e) {
        log.warn(`agents::${this.kind}`, "a transcript line was not kept", { session: id, error: (e as Error).message });
      }
    };
    const next: Promise<void> = (this.#writing ?? Promise.resolve()).then(write);
    this.#writing = next;
    void next.then(() => {
      if (this.#writing === next) this.#writing = null;
    });
  }

  /// The last line of `type` kept of `id` since its last turn's end (null: none, or none in the file's last `TAIL`
  /// bytes): what a station taken up after a crash goes on from, where what the one before wrote was not yet
  /// acknowledged to its runner and comes again.
  lastOfTurn(id: string, type: string): Json | null {
    if (id === "") return null;
    let fd: number;
    try {
      fd = openSync(join(this.dir, `${id}.jsonl`), "r"); // sync: once, as a crashed session is taken up, before it is told anything
    } catch {
      return null;
    }
    try {
      const size = fstatSync(fd).size; // sync: as above
      const from = Math.max(0, size - TAIL);
      const buf = Buffer.alloc(size - from);
      readSync(fd, buf, 0, buf.length, from); // sync: as above, its last TAIL bytes at most
      const lines = buf.toString("utf8").split("\n");
      if (from > 0) lines.shift();
      for (let i = lines.length - 1; i >= 0; i--) {
        let line: Json;
        try {
          line = JSON.parse(lines[i]!);
        } catch {
          continue;
        }
        if (line?.type === "end") return null;
        if (line?.type === type) return line;
      }
      return null;
    } finally {
      closeSync(fd); // sync: as above
    }
  }

  /// What is being written, done (null: nothing is).
  settled(): Promise<void> | null {
    return this.#writing;
  }

  ended(id: string, outcome: TurnOutcome) {
    this.keep(id, { type: "end", status: outcome.kind === "completed" ? "finished" : outcome.kind === "aborted" ? "cancelled" : "error", ...(outcome.kind === "failed" ? { error: { message: outcome.message } } : {}) });
  }

  /// `f`, nothing written of it.
  quietly(f: () => void) {
    this.quiet = true;
    try {
      f();
    } finally {
      this.quiet = false;
    }
  }
}

/// Where an ACP session's turn stands: the prompt whose answer ends it (ours, or one put in the turn that became a turn
/// of its own), and the prompts put in the running turn not answered yet.
type AcpTurn = { busy: boolean; aborting: boolean; closed: boolean; owner: string | null; steering: string[] };

export abstract class AcpSession extends OwnProcessSession<AcpTurn> {
  /// The model its turns run on (null when not known).
  model: string | null = null;
  /// The transcript the station keeps of it (null: the runtime's own is read).
  protected readonly transcript: KeptTranscript | null;

  constructor(driver: AcpDriver<any>, events: Events, transcript: KeptTranscript | null = null) {
    super(driver, "", { busy: false, aborting: false, closed: false, owner: null, steering: [] }, events);
    this.transcript = transcript;
  }

  /// An update of the session's usage (`owner`: the prompt whose turn it is in).
  protected updated(_update: Json, _owner: string | null): void {}
  /// The turn ends as `answer` says, before what is open of it ends.
  protected ending(_id: string, _answer: Json): void {}
  /// A steering or superseded prompt's answer was ignored while the turn continues.
  protected ignored(_id: string, _answer: Json): void {}
  /// What a message of the person's is given to it as.
  protected promptText(text: string): string {
    return text;
  }
  /// What a snapshot keeps besides the protocol's (the runtime's own), and takes back.
  protected kept(): Record<string, unknown> {
    return {};
  }
  protected taken(_snapshot: Json): void {}

  /// Whether it is open (`opened`): what it says of its past before is no turn's.
  #open = false;

  /// Open: session/new's or session/load's answer (`result`) says what it runs on besides. What it says of its past
  /// before is no turn's (the program is told).
  opened(_result: Json) {
    this.#open = true;
    (this.proc as typeof this.proc | undefined)?.say("acpOpened");
  }

  /// The program started again reads it from what it was told last: the session it is, open.
  protected attached() {
    const proc = this.proc as typeof this.proc | undefined;
    if (proc === undefined) return;
    if (this.sessionId !== "") proc.say("acpSession", { id: this.sessionId });
    if (this.#open) proc.say("acpOpened");
  }

  named(id: string) {
    super.named(id);
    (this.proc as typeof this.proc | undefined)?.say("acpSession", { id });
  }

  /// A session made new: the transcript says so first.
  began(cwd: string) {
    this.transcript?.keep(this.sessionId, { type: "session", id: this.sessionId, cwd });
  }

  /// A request whose answer is waited for: an error answer rejects.
  request(id: string, method: string, params: Json, timeoutMs?: number): Promise<Json> {
    const answer = this.waiting.wait(id, (m) => (m?.error !== undefined ? new Error(`${this.kind} ${method}: ${errorText(m.error)}`) : null), undefined, timeoutMs);
    this.proc.write(rpc(id, method, params));
    return answer;
  }

  /// A request whose answer is not waited for.
  protected send(method: string, params: Json) {
    this.proc.write(rpc(`${method}:${uuid()}`, method, params));
  }

  /// A line the program gives this: a request of the runtime's, or the answer to one of ours.
  protected heard(line: string) {
    const message = parseLine(this.kind, line);
    if (message === undefined) return;
    const id = message.id;
    if (message.method === "session/request_permission" && id !== undefined) return this.permit(id, message.params?.options);
    // A request of its own the station has no answer for (asking the person a question, a plan to approve): what it
    // asks is answered in the chat, not here.
    if (message.method !== undefined) {
      if (id !== undefined) this.proc.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32601, message: `${message.method} is not supported` } }));
      return;
    }
    this.waiting.answer(id, message);
  }

  /// What the program says of the session for this alone: the transcript's lines, its usage, a prompt's answer.
  protected took(e: Json): boolean {
    if (e?.type === "kept") {
      this.transcript?.keep(this.sessionId, e.line);
      return true;
    }
    if (e?.type === "usage") {
      this.updated(e.update, typeof e.owner === "string" ? e.owner : null);
      return true;
    }
    if (e?.type === "answered") {
      if (e.outcome !== undefined) this.ending(String(e.id), e.answer);
      else this.ignored(String(e.id), e.answer);
      return true;
    }
    return false;
  }

  protected settled(): Promise<void> | null {
    return this.transcript?.settled() ?? null;
  }

  /// A permission it asks: granted for this call, as the other runtimes run without approvals here, and only for it
  /// (nothing of it is kept in the runtime's settings); refused when it offers no way to allow just this call.
  private permit(id: Json, options: Json) {
    const offered: Json[] = Array.isArray(options) ? options : [];
    const chosen = offered.find((o) => o?.kind === "allow_once");
    const result = chosen ? { outcome: { outcome: "selected", optionId: chosen.optionId } } : { outcome: { outcome: "cancelled" } };
    this.proc.write(JSON.stringify({ jsonrpc: "2.0", id, result }));
  }

  /// Its process went away during a turn: what was being said is written by the program (its steps end there), its end
  /// here.
  protected cutShort(said: string) {
    this.transcript?.ended(this.sessionId, { kind: "failed", reason: "exited", message: `${this.kind} exited (${said})` });
  }

  async prompt(text: string) {
    this.startable();
    const owner = `${PROMPT}${uuid()}`;
    this.turn.busy = true;
    this.turn.owner = owner;
    this.proc.say("acpPrompt", { owner, ...(this.transcript !== null ? { text } : {}) });
    this.proc.write(rpc(owner, "session/prompt", { sessionId: this.sessionId, prompt: [{ type: "text", text: this.promptText(text) }] }));
  }

  /// Not into the running turn: the station gives it as the next turn's.
  async steer(_text: string): Promise<boolean> {
    return false;
  }

  private injectPrompt(text: string, takeOver: boolean): boolean {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return false;
    const id = `${STEER}${uuid()}`;
    const steering = new Set(this.turn.steering);
    if (takeOver) {
      if (this.turn.owner !== null) steering.add(this.turn.owner);
      this.turn.owner = id;
    } else {
      steering.add(id);
    }
    this.turn.steering = [...steering];
    this.proc.say("acpInject", { id, takeOver, ...(this.transcript !== null ? { text } : {}) });
    this.proc.write(rpc(id, "session/prompt", { sessionId: this.sessionId, prompt: [{ type: "text", text: this.promptText(text) }] }));
    return true;
  }

  /// Into the running turn as a prompt of its own, read at the turn's next step and answered with it. Not when nothing
  /// runs: it would be a turn of its own, which the station starts itself.
  protected promptInto(text: string): boolean {
    return this.injectPrompt(text, false);
  }

  /// Into the running turn as a prompt that takes ownership of it from the current prompt (the runtime answers the
  /// superseded prompt immediately and answers this one when the turn finishes). Not when nothing runs.
  protected promptTakeover(text: string): boolean {
    return this.injectPrompt(text, true);
  }

  async abort() {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return;
    this.turn.aborting = true;
    this.proc.tell("aborting");
    this.proc.write(JSON.stringify({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId: this.sessionId } }));
  }

  /// What the station that handed it over knew of it.
  handed(snapshot: AcpSnapshot) {
    this.sessionId = snapshot.id;
    this.turn = { busy: snapshot.turn.busy, aborting: snapshot.turn.aborting, closed: false, owner: snapshot.owner ?? null, steering: snapshot.steering ?? [] };
    this.liveState = { live: snapshot.live, said: snapshot.said ?? null, calls: snapshot.calls ?? [], saidLast: snapshot.saidLast ?? "", children: snapshot.children ?? [], loading: false, session: snapshot.id };
    this.toolsUrl = snapshot.tools;
    this.model = snapshot.model ?? this.model;
    this.#open = true;
    this.taken(snapshot);
  }

  /// What the program read again of what the station before had handled of its output when it crashed: the session,
  /// whether a turn runs, what the turn had said and called so far; what it was opened with and the running turn's
  /// usage, read here as if heard now, nothing of it written again.
  replayed(replayed: Replayed, resume: string | undefined) {
    this.sessionId = replayed.session || (resume ?? "");
    const t = replayed.turn ?? {};
    this.turn = { busy: t.busy === true, aborting: false, closed: false, owner: null, steering: [] };
    this.liveState = replayed.live ?? null;
    this.#open = true;
    const configured = this.model;
    if (replayed.opened !== undefined && replayed.opened !== null) this.opened(replayed.opened);
    if (configured !== null) this.model = configured;
    const again = () => {
      for (const update of replayed.usages ?? []) this.updated(update, null);
    };
    if (this.transcript !== null) this.transcript.quietly(again);
    else again();
  }

  snapshot(): AcpSnapshot {
    const frozen = this.handOver();
    const turn = frozen?.turn ?? this.turnNow();
    const state = frozen?.live ?? this.liveState ?? {};
    return {
      runtime: this.kind,
      id: this.sessionId,
      runner: this.proc.info.id,
      turn: { busy: turn.busy === true, aborting: turn.aborting === true },
      tools: this.toolsUrl,
      live: state.live ?? { open: [], said: null, n: 0, phase: null },
      model: this.model,
      owner: turn.owner ?? null,
      steering: turn.steering ?? [],
      said: state.said ?? null,
      calls: state.calls ?? [],
      saidLast: state.saidLast ?? "",
      children: state.children ?? [],
      ...this.kept(),
    };
  }
}

/// How a runtime's process is started for a session, and what the protocol's own requests carry of it.
export type AcpStart = {
  /// Only initialize: a runtime may prepare its profile dependencies before it can speak ACP.
  initializeTimeoutMs?: number;
  command: string;
  args: string[];
  env: Record<string, string>;
  /// The `_meta` of initialize, session/new and session/load (Grok Build's rules).
  meta?: Json;
  /// What session/new and session/load are given besides the working directory and the station's tools.
  opening?: Json;
};

export abstract class AcpDriver<S extends AcpSession> extends OwnProcessDriver<S> {
  /// Whether the station keeps its transcript (KeptTranscript).
  protected readonly keepsTranscript: boolean = false;

  hosting(): Hosting {
    return { kind: "acp", flavor: this.runtime(), kept: this.keepsTranscript };
  }

  /// A session of it, not open yet.
  protected abstract session(options: OpenOptions, events: Events): S;
  /// How its process is started for a session (`probe`: one opened only to learn what it offers, with no tools of the
  /// station's, nothing of it kept). What must be there first is made here; a session it would not find to load fails
  /// here, before anything starts, so that the caller starts afresh.
  protected abstract starting(options: OpenOptions, probe: boolean): AcpStart | Promise<AcpStart>;
  /// Once initialize is answered (`answer`): signing in, its version.
  protected async initialized(_session: S, _answer: Json, _options: OpenOptions): Promise<void> {}
  /// Once the session is open: what it runs with (no approvals, its model).
  protected async ready(_session: S, _options: OpenOptions, _probe: boolean): Promise<void> {}

  open(options: OpenOptions, events: Events): Promise<S> {
    return this.begin(options, events, false);
  }

  protected async begin(options: OpenOptions, events: Events, probe: boolean): Promise<S> {
    const start = await this.starting(options, probe);
    const session = this.session(options, events);
    session.toolsUrl = options.mcpUrl;
    await this.start(session, options, start.command, start.args, start.env);
    try {
      const meta = start.meta === undefined ? {} : { _meta: start.meta };
      const answer = await session.request(INIT, "initialize", { protocolVersion: 1, clientCapabilities: {}, clientInfo: CLIENT, ...meta }, start.initializeTimeoutMs);
      await this.initialized(session, answer, options);
      const opening = { cwd: options.cwd, mcpServers: probe ? [] : mcpServers(options.mcpUrl, options.mcpToken), ...start.opening, ...meta };
      let opened: Json;
      if (options.resume !== undefined) {
        session.named(options.resume);
        opened = await session.request(OPEN, "session/load", { sessionId: options.resume, ...opening });
      } else {
        opened = await session.request(OPEN, "session/new", opening);
        const id = opened?.result?.sessionId;
        if (typeof id !== "string" || id === "") throw new Error(`${runtimeLabel(this.runtime())} named no session`);
        session.named(id);
        if (!probe) session.began(options.cwd);
      }
      session.opened(opened?.result);
      await this.ready(session, options, probe);
      // (what it keeps of its opening written before it is anyone's)
      await session.adopted();
    } catch (error) {
      await session.dispose();
      throw error;
    }
    return session;
  }

  protected handedOver(options: OpenOptions, snapshot: Json, _info: RunnerInfo, events: Events): S {
    const session = this.session(options, events);
    session.handed(snapshot as AcpSnapshot);
    return session;
  }

  protected crashed(options: OpenOptions, replayed: Replayed, _info: RunnerInfo, events: Events): S {
    const session = this.session(options, events);
    session.model = options.model ?? profileModel(options.profile) ?? session.model;
    session.replayed(replayed, options.resume);
    session.toolsUrl = options.mcpUrl || null;
    return session;
  }
}
