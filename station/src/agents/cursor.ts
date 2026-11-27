// Cursor driver: one Node process per session, under a runner whose id comes from the session key, running the station's
// own driver (./cursor-bridge.mjs) on Cursor's TypeScript SDK (@cursor/sdk, its local runtime): the agent loop here, the
// models Cursor's, on the person's Cursor account. Not the Cursor CLI's ACP server: a message for the running turn there
// cancels the turn and kills the command it runs; the SDK's `steer` puts it in the turn, the command going on in the
// background. The bridge speaks a line of JSON per message (its header).
//
// Behaviour pinned against @cursor/sdk 1.0:
// - `open` creates the SDK's agent (it names it) or resumes one it keeps; the station's tools an HTTP MCP server, its
//   instructions (with its workspace's memory) and skills a folder of project rules beside the session's working directory;
// - `prompt` starts a run (a turn), whose messages stream (status, thinking, assistant text, tool calls, usage) and which
//   ends finished, cancelled or in error; `steer` puts a message in the running turn (said delivered or not); `cancel`
//   stops it;
// - the model is the SDK's selection, `id` or `id[param=value,…]`, set per prompt;
// - the bridge keeps the transcript itself (<sessions>/<agent id>.jsonl), the turn's usage in it.

import { access, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { log } from "../ops/log.ts";
import { peerHttpBase } from "../tools/http.ts";
import { rulesFolder as folderOf } from "./rules-folder.ts";
import { chars } from "./live.ts";
import { type Events, type Replayed, OwnProcessDriver, OwnProcessSession, type TurnState, parseLine } from "./own-process.ts";
import { expandRoute, profileEnv, profileModel } from "./profiles.ts";
import { CommandMissing, type RunnerInfo } from "./runner.ts";
import { cleanEnv, failureOf, uuid, type FailureReason, type OpenOptions, type TurnOutcome } from "./runtime.ts";
import { keepLocal } from "../ops/agent-env.ts";

type Json = any;

/// Inherited variables that would let a session use another account than its profile's.
const SCRUBBED = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN", "CURSOR_BACKEND_URL", "CURSOR_WEBSITE_URL", "STILLFAIL_CURSOR_SDK", "STILLFAIL_CURSOR_HOME"];
/// The package the driver runs on, installed by npm (updates/runtimes.ts).
export const SDK_PACKAGE = "@cursor/sdk";
/// The station's driver: beside this module (src/agents/ from source; the bundle's directory, where the build copies it).
export const BRIDGE = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/cursor-bridge.mjs", import.meta.url) : new URL("./cursor-bridge.mjs", import.meta.url));

/// What Cursor keeps of a profile, in its home: the sign-in (auth.json, accounts/cursor.ts), the sessions (shared by every
/// profile that runs Cursor: agent-home.ts links them), the folders of the station's rules.
export const cursorHome = (home: string) => join(home, "cursor");
export const SESSIONS = "sessions";
/// The SDK's own home, in the shared sessions: what it keeps of its agents (their checkpoints, the terminals' output) goes
/// with them to whichever profile takes a session on.
export const SDK_HOME = "home";

/// The id of the request that opens the session; the others carry their own.
const OPEN = "open";
const PROMPT = "prompt:";
const STEER = "steer:";

/// Where the station keeps Cursor's SDK: npm installs it there (`-g --prefix`, updates/updates.ts), apart from the
/// machine's own global packages, so it is found by a look at the disk, not by asking npm.
export const sdkPrefix = (data: string) => join(data, "runtimes", "cursor");

/// The SDK's package under the prefix (lib/node_modules where npm puts a prefix's packages; node_modules on Windows),
/// null when it is not installed.
export async function findSdk(data: string): Promise<string | null> {
  for (const root of [join(sdkPrefix(data), "lib", "node_modules"), join(sdkPrefix(data), "node_modules")]) {
    const dir = join(root, ...SDK_PACKAGE.split("/"));
    if (await access(join(dir, "package.json")).then(() => true, () => false)) return dir;
  }
  return null;
}

/// The SDK's version, as its package says (null: not installed; the software page's reading of it: updates.ts readCursor).
export async function sdkVersionSoon(data: string): Promise<string | null> {
  for (const root of [join(sdkPrefix(data), "lib", "node_modules"), join(sdkPrefix(data), "node_modules")]) {
    const text = await readFile(join(root, ...SDK_PACKAGE.split("/"), "package.json"), "utf8").catch(() => null);
    if (text === null) continue;
    try {
      const v = JSON.parse(text)?.version;
      return typeof v === "string" ? v : null;
    } catch {
      return null;
    }
  }
  return null;
}

/// The key a profile signed in to Cursor has (accounts/cursor.ts keeps it in its home's cursor/auth.json); custom
/// variables bring their own CURSOR_API_KEY.
export async function cursorKey(home: string): Promise<string | null> {
  try {
    const key = JSON.parse(await readFile(join(cursorHome(home), "auth.json"), "utf8"))?.apiKey;
    return typeof key === "string" && key !== "" ? key : null;
  } catch {
    return null;
  }
}

/// The station's instructions as a project rule that always applies, in a folder of the session's own beside its working
/// directory, with the skills of its workspace (`skills`) linked in as .cursor/skills: the SDK reads a folder it is given
/// as a project's (rules, AGENTS.md, skills) without them being written into the person's project.
export function rulesFolder(home: string, key: string, instructions: string, skills?: string): Promise<string> {
  const rule = `---\ndescription: still.fail station\nalwaysApply: true\n---\n${instructions}\n`;
  return folderOf(cursorHome(home), key, ".cursor", { file: "stillfail.mdc", text: rule }, "Cursor", skills);
}

/// What failed a turn, from the SDK's error (its code first). What the program reads a process by does this (mb/src/cursor
/// `outcome_of`); this is what it is held to.
export const classifyFailure = (code: string, text: string): FailureReason => failureOf(`${code} ${text}`);

/// How a run's end ends the turn.
export function outcomeOf(end: Json): TurnOutcome {
  if (end?.status === "cancelled") return { kind: "aborted" };
  if (end?.status === "finished") return { kind: "completed" };
  const message = typeof end?.error?.message === "string" ? end.error.message : `the run ended ${String(end?.status ?? "without saying how")}`;
  return { kind: "failed", reason: classifyFailure(String(end?.error?.code ?? ""), message), message: chars(message, 1000) };
}

/// Its live steps as the program keeps them (mb/src/cursor `Live::state`).
export type CursorLiveState = { open: [string, string][]; said: string | null; n: number; phase: string | null };

/// A session as a next station takes it up.
export type CursorSnapshot = { runtime: "cursor"; id: string; runner: string; turn: { busy: boolean; aborting: boolean }; tools: string | null; live: CursorLiveState; model: string | null };

export type CursorDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The Node the bridge runs on (the station's own).
  node?: string;
  /// The driver (tests give their own) and the SDK's package (tests give a fake): found with npm when not given.
  bridge?: string;
  sdk?: string;
};

export class CursorDriver extends OwnProcessDriver<CursorSession> {
  private readonly node: string;
  private readonly bridge: string;
  private readonly sdk: string | undefined;

  constructor(options: CursorDriverOptions) {
    super(options.data);
    this.node = options.node ?? process.execPath;
    this.bridge = options.bridge ?? BRIDGE;
    this.sdk = options.sdk;
  }

  runtime(): "cursor" {
    return "cursor";
  }

  hosting() {
    return { kind: "cursor" as const };
  }

  /// Its environment: the profile's key, the SDK's home and package, the station's tools' token.
  private async env(options: OpenOptions, sdk: string): Promise<Record<string, string>> {
    const env: Record<string, string> = keepLocal({ ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "cursor"), options.route) });
    const key = await cursorKey(options.profile.home);
    if (key !== null && env.CURSOR_API_KEY === undefined) env.CURSOR_API_KEY = key;
    env.STILLFAIL_CURSOR_SDK = sdk;
    env.STILLFAIL_CURSOR_HOME = join(cursorHome(options.profile.home), SESSIONS, SDK_HOME);
    env.STILLFAIL_MCP_TOKEN = options.mcpToken;
    env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
    return env;
  }

  async open(options: OpenOptions, events: Events): Promise<CursorSession> {
    const home = options.profile.home;
    const sessions = join(cursorHome(home), SESSIONS);
    await mkdir(sessions, { recursive: true });
    const sdk = this.sdk ?? (await findSdk(this.data));
    // Not installed: the person's message waits for it as for any runtime not on PATH (agents/runner.ts).
    if (sdk === null) throw new CommandMissing("cursor");
    if (options.resume !== undefined && !(await access(join(sessions, `${options.resume}.jsonl`)).then(() => true, () => false))) {
      // The SDK would not find it; failing here lets the caller start fresh.
      throw new Error(`no Cursor session ${options.resume}`);
    }
    const model = options.model ?? profileModel(options.profile) ?? null;
    const rules = await rulesFolder(home, options.key, options.instructions, options.skills);
    const session = new CursorSession(this, "", { busy: false, aborting: false, closed: false }, null, events, model);
    session.toolsUrl = options.mcpUrl;
    await this.start(session, options, this.node, [this.bridge], await this.env(options, sdk));
    try {
      const opened = await session.request(OPEN, "open", {
        cwd: options.cwd,
        ...(options.resume !== undefined ? { resume: options.resume } : {}),
        ...(model !== null ? { model } : {}),
        mcpUrl: options.mcpUrl,
        rules,
        sessions,
      }, "Cursor's SDK did not open the agent in time");
      if (typeof opened?.session !== "string" || opened.session === "") throw new Error("Cursor's SDK named no agent");
      session.named(opened.session);
    } catch (error) {
      await session.dispose();
      throw error;
    }
    return session;
  }

  protected handedOver(_options: OpenOptions, handed: CursorSnapshot, _info: RunnerInfo, events: Events) {
    const session = new CursorSession(this, handed.id, { ...handed.turn, closed: false }, handed.live, events, handed.model);
    session.toolsUrl = handed.tools;
    return session;
  }

  /// What the station before had handled, read again by the program, says the session and where its turn stands.
  protected crashed(options: OpenOptions, replayed: Replayed, _info: RunnerInfo, events: Events) {
    const turn: TurnState = { busy: false, aborting: false, ...(replayed.turn ?? {}), closed: false };
    const session = new CursorSession(this, replayed.session ?? options.resume ?? "", turn, replayed.live ?? null, events, options.model ?? profileModel(options.profile) ?? null);
    session.toolsUrl = options.mcpUrl || null;
    return session;
  }
}

/// A session: what the bridge's lines do to its turn and its live steps is the program's to read (mb/src/cursor), which
/// gives this the answers to its requests.
export class CursorSession extends OwnProcessSession {
  /// The model its next turn runs on (null: the agent's).
  private model: string | null;

  constructor(driver: CursorDriver, sessionId: string, turn: TurnState, live: CursorLiveState | null, events: Events, model: string | null) {
    super(driver, sessionId, turn, events, live);
    this.model = model;
  }

  /// A request whose answer is waited for: an error answer rejects.
  request(id: string, op: string, params: Json, late?: string): Promise<Json> {
    const answer = this.waiting.wait(id, (m) => (typeof m?.error === "string" ? new Error(`cursor ${op}: ${m.error}`) : null), late);
    this.proc.write(JSON.stringify({ id, op, ...params }));
    return answer;
  }

  /// An answer to a request (a prompt it refused ends the turn there, in the program).
  protected heard(line: string) {
    const message = parseLine("cursor", line);
    if (message === undefined || this.waiting.answer(message.id, message)) return;
    if (typeof message.error !== "string") return;
    log.warn("agents::cursor", "cursor refused a request", { session: this.sessionId, request: String(message.id), error: message.error });
  }

  async prompt(text: string) {
    this.startable();
    this.turn.busy = true;
    this.proc.tell("begin");
    this.proc.write(JSON.stringify({ id: `${PROMPT}${uuid()}`, op: "prompt", text, ...(this.model !== null ? { model: this.model } : {}) }));
  }

  /// Into the running turn, by the SDK's steer: the turn takes it at its next step (a command it runs goes on in the
  /// background). Not delivered (the turn ending as it came): the station gives it as the next turn's.
  async steer(text: string) {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return false;
    try {
      const answer = await this.request(`${STEER}${uuid()}`, "steer", { text });
      return answer?.delivered === true;
    } catch (e) {
      log.warn("agents::cursor", "a message could not go into the running turn", { session: this.sessionId, error: (e as Error).message });
      return false;
    }
  }

  /// Between turns, another model is the next prompt's (the SDK takes one per run): no new process.
  retune(options: OpenOptions) {
    if (this.turn.closed || this.turn.busy || this.sessionId === "") return false;
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined) return false;
    this.model = model;
    return true;
  }

  /// Asked to stop its running turn (own-process.ts `abort`).
  protected cancel() {
    this.proc.write(JSON.stringify({ id: `cancel:${uuid()}`, op: "cancel" }));
  }

  snapshot(): CursorSnapshot {
    const frozen = this.handOver();
    const turn = frozen?.turn ?? this.turn;
    return { runtime: "cursor", id: this.sessionId, runner: this.proc.info.id, turn: { busy: turn.busy === true, aborting: turn.aborting === true }, tools: this.toolsUrl, live: frozen?.live ?? this.liveState, model: this.model };
  }
}
