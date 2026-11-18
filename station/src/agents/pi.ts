// Pi driver: one `pi --mode rpc` per session, under a runner whose id comes from the session key, spoken to in Pi's RPC
// (a line of JSON per command on stdin; its answers, `type: "response"`, and its session's events on stdout).
//
// Behaviour pinned against Pi 1.5:
// - the session is a file of its own, named by the station (`--session <home>/pi/sessions/<id>.jsonl`): a new one is
//   that file not there yet, a resumed one the file Pi wrote before (`resume` names it);
// - `prompt` starts a run; `steer` puts a message in the running one, read once the step it is in (its tool calls)
//   ends, before the model is asked again; `abort` stops it. A run goes on by itself past its turns (retries, a
//   compaction on overflow, steered messages) and ends with `agent_settled`: the station's turn is that whole run;
// - the profile's provider and the station's tools are this process's alone, given by the station's extension
//   (./pi-bridge.mjs, STILLFAIL_PI_SETUP): the provider registered as "stillfail" on pi-ai's routes as DeepSeek
//   Harness's are (profiles.ts `piRoute`), its key read from STILLFAIL_PI_KEY; the station's tools its built-in MCP's,
//   declared to the model as mcp__stillfail__<tool>. Pi's own files in its directory (models.json, mcp.json) are shared
//   by every session of the profile, each of a model of its own;
// - nothing of the person's Pi: its directory (PI_CODING_AGENT_DIR) is the profile home's pi/, no extension but the
//   built-in MCP and the station's, no skill but the session's workspace's, no project-local Pi resource (`--no-approve`:
//   a project's extension would run inside the process the station speaks to), no update check and no telemetry;
// - the station's instructions after Pi's own system prompt (`--append-system-prompt`, a file per session).
// A dialog an extension opens (`extension_ui_request`) has nobody to answer it here: it is cancelled at once.
import { mkdir, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { facts } from "../accounts/catalog.ts";
import { seesImages } from "../accounts/models.ts";
import { log } from "../ops/log.ts";
import { peerHttpBase } from "../tools/http.ts";
import { type Events, type Replayed, OwnProcessDriver, OwnProcessSession, type TurnState, parseLine } from "./own-process.ts";
import { PI_KEY, expandRoute, piRoute, profileEnv, profileModel, type PiRoute } from "./profiles.ts";
import type { RunnerInfo } from "./runner.ts";
import { cleanEnv, uuid, type OpenOptions } from "./runtime.ts";
import { keepLocal } from "../ops/agent-env.ts";

type Json = any;

/// Inherited variables that would let a session use another home, sessions or setup than its profile's.
const SCRUBBED = ["PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR", "PI_SESSION_ID", "PI_SESSION_FILE", PI_KEY, "STILLFAIL_PI_SETUP"];
/// The provider the station registers in Pi for a profile's route.
const PROVIDER = "stillfail";
/// Pi's directory in a profile's home (PI_CODING_AGENT_DIR): its own files apart from the other runtimes' a profile may
/// run.
export const piHome = (home: string) => join(home, "pi");
/// Where in Pi's directory the station keeps its sessions (read/transcript.ts `transcriptDir`: pi/sessions of the home).
export const SESSIONS = "sessions";
/// A session's file: named by its id.
export const sessionFile = (home: string, id: string) => join(piHome(home), SESSIONS, `${id}.jsonl`);
/// The station's extension in Pi: beside this module (src/agents/ from source; the bundle's directory, where the build
/// copies it).
export const BRIDGE = fileURLToPath(new URL("./pi-bridge.mjs", import.meta.url));
/// The id of the request that sees the process up (its extensions loaded, the session opened).
const OPEN = "open";
/// The variable the session's token for the station's tools is read from by the extension.
const MCP_TOKEN_VAR = "STILLFAIL_MCP_TOKEN";
/// Reasoning efforts as Pi takes them (`--thinking`; it clamps one to what the model offers).
const EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max"];
/// An extension's dialogs, which wait for an answer (the others only tell).
const DIALOGS = ["select", "confirm", "input", "editor"];

/// The provider as Pi's `registerProvider` takes it, for a profile's route and the session's model: its window and most
/// output as the model catalog says them (Pi knows nothing of a model on a provider of its own), images where the model
/// reads them, and the profile's effort taken (a model Pi has no entry for is taken as one without reasoning). As
/// DeepSeek Harness's (dsh.ts `dshSetup`), the instructions go as "system" on an OpenAI protocol anywhere but OpenAI's
/// own API: a gateway refuses the "developer" role (FB-7).
export function piProvider(route: PiRoute, model: string, effort: string | undefined, sessionRoute: string): Json {
  const known = facts(model);
  const window = known?.context;
  const output = known?.output;
  const entry: Json = {
    id: model,
    name: model,
    reasoning: effort !== undefined,
    input: seesImages(model) ? ["text", "image"] : ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    ...(window !== undefined && Number.isInteger(window) && window > 0 ? { contextWindow: window } : {}),
    ...(output !== undefined && Number.isInteger(output) && output > 0 && (window === undefined || output < window) ? { maxTokens: output } : {}),
  };
  const provider: Json = { name: route.name, baseUrl: route.baseURL, api: route.api, apiKey: `$${PI_KEY}`, models: [entry] };
  if (route.headers) provider.headers = expandRoute(route.headers, sessionRoute);
  if (route.api !== "anthropic-messages" && !openaiOwn(route.baseURL)) provider.compat = { supportsDeveloperRole: false };
  return provider;
}

/// Whether a route's address is OpenAI's own API.
const openaiOwn = (baseURL: string) => {
  try {
    return new URL(baseURL).hostname === "api.openai.com";
  } catch {
    return false;
  }
};

/// What a session is started with: its arguments and what its extension is given.
export type PiSetup = { args: string[]; setup: Json };

/// The process's arguments and its extension's setup for a session. A profile that brings its own configuration (custom
/// variables) names its model as Pi finds it (its own providers, by the person's variables).
export function piSetup(route: PiRoute | null, model: string | undefined, options: OpenOptions, file: string, instructions: string | null, bridge = BRIDGE): PiSetup {
  const args = ["--mode", "rpc", "--offline", "--no-extensions", "-e", "builtin:mcp", "-e", bridge, "--no-approve", "--no-skills", "--session", file];
  if (options.skills !== undefined) args.push("--skill", options.skills);
  if (instructions !== null) args.push("--append-system-prompt", instructions);
  const setup: Json = { tools: { url: options.mcpUrl } };
  if (route !== null) {
    if (model === undefined) throw new Error("the profile names no model for Pi");
    setup.provider = piProvider(route, model, options.effort, options.route);
    args.push("--model", `${PROVIDER}/${model}`);
  } else if (model !== undefined) {
    args.push("--model", model);
  }
  if (options.effort !== undefined && EFFORTS.includes(options.effort)) args.push("--thinking", options.effort);
  return { args, setup };
}

const isFile = (path: string): Promise<boolean> => stat(path).then((s) => s.isFile(), () => false);

/// The turn as its handled lines leave it. `prompted`: a turn of ours is asked for and has not started yet.
export type Turn = TurnState & { prompted: boolean };

/// Its live steps as the program keeps them (mb/src/pi `Live::state`).
export type PiLiveState = Json;

/// A session as a next station takes it up.
export type PiSnapshot = { runtime: "pi"; id: string; runner: string; turn: Json; tools: string | null; live: PiLiveState };

export type PiDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path.
  command?: string;
  /// The extension Pi loads (tests give their own).
  bridge?: string;
};

export class PiDriver extends OwnProcessDriver<PiSession> {
  private readonly command: string;
  private readonly bridge: string;

  constructor(options: PiDriverOptions) {
    super(options.data);
    this.command = options.command ?? "pi";
    this.bridge = options.bridge ?? BRIDGE;
  }

  runtime(): "pi" {
    return "pi";
  }

  hosting() {
    return { kind: "pi" as const };
  }

  async open(options: OpenOptions, events: Events): Promise<PiSession> {
    const home = options.profile.home;
    const dir = piHome(home);
    await mkdir(join(dir, SESSIONS), { recursive: true });
    const id = options.resume ?? uuid();
    const file = sessionFile(home, id);
    // Pi would start it afresh; failing here lets the caller start fresh, and say so.
    if (options.resume !== undefined && !(await isFile(file))) throw new Error(`no Pi session ${options.resume}`);
    // Per session: its instructions are in it. Named by the session's key, so a session started again writes over its
    // own. No secret is in it: the key and the tools' token are in the environment.
    let instructions: string | null = null;
    if (options.instructions !== "") {
      const own = join(dir, "stillfail");
      await mkdir(own, { recursive: true });
      instructions = join(own, `${createHash("sha256").update(options.key).digest("hex").slice(0, 16)}.md`);
      await writeFile(instructions, options.instructions, { mode: 0o600 });
    }
    const { args, setup } = piSetup(piRoute(options.profile), options.model ?? profileModel(options.profile), options, file, instructions, this.bridge);

    const env: Record<string, string> = keepLocal({ ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "pi"), options.route) });
    env.PI_CODING_AGENT_DIR = dir;
    // Nothing of a session goes to Pi's telemetry; the station updates it (updates/runtimes.ts), not Pi itself.
    env.PI_TELEMETRY = "0";
    env.PI_SKIP_VERSION_CHECK = "1";
    env.STILLFAIL_PI_SETUP = JSON.stringify(setup);
    env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
    env[MCP_TOKEN_VAR] = options.mcpToken;

    const session = new PiSession(this, id, { busy: false, prompted: false, aborting: false, closed: false }, null, events);
    session.toolsUrl = options.mcpUrl;
    await this.start(session, options, this.command, args, env);
    try {
      // Up once it answers: its extensions loaded (a provider it could not register fails it here, not at the prompt).
      await session.request(OPEN, "get_state", {}, "Pi did not answer (it could not start, or it is older than 1.0?)");
    } catch (error) {
      await session.dispose();
      throw error;
    }
    return session;
  }

  protected handedOver(_options: OpenOptions, handed: PiSnapshot, _info: RunnerInfo, events: Events) {
    const session = new PiSession(this, handed.id, { busy: false, prompted: false, aborting: false, ...(handed.turn ?? {}), closed: false }, handed.live, events);
    session.toolsUrl = handed.tools;
    return session;
  }

  /// What the station before had handled, read again by the program, says where its turn stands.
  protected crashed(options: OpenOptions, replayed: Replayed, _info: RunnerInfo, events: Events) {
    const turn: Turn = { busy: false, prompted: false, aborting: false, ...(replayed.turn ?? {}), closed: false };
    const session = new PiSession(this, options.resume ?? "", turn, replayed.live ?? null, events);
    session.toolsUrl = options.mcpUrl || null;
    return session;
  }
}

/// A session: what Pi's lines do to its turn and its live steps is the program's to read (mb/src/pi), which gives this
/// the answers to its requests and the dialogs its extensions open.
export class PiSession extends OwnProcessSession<Turn> {
  constructor(driver: PiDriver, sessionId: string, turn: Turn, live: PiLiveState | null, events: Events) {
    super(driver, sessionId, turn, events, live);
  }

  /// A request whose answer is waited for: one it refuses rejects.
  request(id: string, type: string, params: Json, late?: string): Promise<Json> {
    const answer = this.waiting.wait(id, (m) => (m?.success === false ? new Error(`pi ${type}: ${String(m.error ?? "refused")}`) : null), late);
    this.proc.write(JSON.stringify({ id, type, ...params }));
    return answer;
  }

  /// A command sent without waiting for its answer (one refused is logged; a prompt refused ends the turn there, in
  /// the program).
  private send(type: string, params: Json = {}) {
    this.proc.write(JSON.stringify({ id: `${type}:${uuid()}`, type, ...params }));
  }

  busy() {
    return this.turn.busy || this.turn.prompted;
  }

  protected idle() {
    this.turn.busy = false;
    this.turn.prompted = false;
  }

  /// An answer to a command, or an extension's dialog.
  protected heard(line: string) {
    const message = parseLine("pi", line);
    if (message === undefined) return;
    if (message.type === "extension_ui_request") {
      if (DIALOGS.includes(message.method)) this.proc.write(JSON.stringify({ type: "extension_ui_response", id: message.id, cancelled: true }));
      return;
    }
    if (this.waiting.answer(message.id, message) || message.success !== false) return;
    log.warn("agents::pi", "pi refused a command", { session: this.sessionId, command: String(message.command), error: String(message.error) });
  }

  async prompt(text: string) {
    this.startable();
    this.turn.prompted = true;
    this.proc.tell("begin");
    this.send("prompt", { message: text });
  }

  /// Into the running turn: read once the step it is in ends.
  async steer(text: string) {
    if (this.turn.closed || !this.busy()) return false;
    this.send("steer", { message: text });
    return true;
  }

  async abort() {
    if (this.turn.closed || !this.busy() || this.turn.aborting) return;
    this.turn.aborting = true;
    this.proc.tell("aborting");
    this.send("abort");
  }

  snapshot(): PiSnapshot {
    const frozen = this.handOver();
    const turn = frozen?.turn ?? this.turn;
    return {
      runtime: "pi",
      id: this.sessionId,
      runner: this.proc.info.id,
      turn: { busy: turn.busy === true, prompted: turn.prompted === true, aborting: turn.aborting === true, ...(typeof turn.error === "string" ? { error: turn.error } : {}) },
      tools: this.toolsUrl,
      live: frozen?.live ?? this.liveState,
    };
  }
}
