// GitHub Copilot driver: one Node process per session, under a runner whose id comes from the session key, running the
// station's own driver (./copilot-bridge.mjs) on GitHub's Copilot SDK (@microsoft/copilot-sdk), whose runtime (the agent
// loop, its built-in coding tools, subagents, skills, compaction) is a child process of the bridge's. Not the Copilot
// CLI's ACP server: the SDK says each model call's usage, steers a message into the running turn, compacts on request,
// changes model and effort between turns, and lets the station refuse a subagent's call before it is made, none of which
// that server does. The bridge speaks Cursor's lines (cursor-bridge.mjs), so the station's program reads it as Cursor's
// (`hosting`, mb/src/cursor), and keeps Cursor's transcript, read by the same history and usage readers.
//
// Behaviour pinned against @microsoft/copilot-sdk 2.0.1 (its runtime 1.0.114):
// - the SDK is installed by the station's updater into its own npm prefix (`sdkPrefix`, updates.ts readCopilot) with
//   its platform's runtime package; not installed, a session waits for it as for a missing CLI (`CommandMissing`);
// - a profile's GitHub token is its own (`copilotToken`: its access key, its own COPILOT_GITHUB_TOKEN, or the device
//   sign-in it kept, accounts/copilot.ts); none, the session is not opened and says it needs signing in. The runtime is
//   never let use a login of the machine's (`useLoggedInUser: false`, no GH_TOKEN, GITHUB_TOKEN or COPILOT_* inherited);
// - its home (COPILOT_HOME, the SDK's `baseDirectory`) is in the shared sessions (cursor/sessions/home's like), so a
//   session resumes on whichever profile takes it up; the transcript beside it, <sessions>/<session id>.jsonl;
// - the station's instructions are appended to Copilot's system message; its tools an HTTP MCP server named
//   `stillfail` (the model sees them as stillfail-<tool>); the workspace's skills a skills directory; and the profile's own
//   MCP servers and skills, in the Copilot CLI's shapes in its Copilot directory (mcp-config.json, skills/), read by the
//   bridge (`ownConfig`): a profile is given what it was given, never the machine's own ~/.copilot;
// - every tool runs without approvals, but a subagent's call of a speaking tool (tools/mcp.ts `SPEAKS`, slack_api's
//   writes), refused by the SDK's pre-tool hook on the `agentId` the runtime gives it.
import { access, mkdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { log } from "../ops/log.ts";
import { keepLocal } from "../ops/agent-env.ts";
import { peerHttpBase } from "../tools/http.ts";
import { SLACK_SPOKEN, SPEAKS } from "../tools/mcp.ts";
import { type Events, type Replayed, OwnProcessDriver, OwnProcessSession, type TurnState, parseLine } from "./own-process.ts";
import { expandRoute, profileEnv, profileModel } from "./profiles.ts";
import { CommandMissing, type RunnerInfo } from "./runner.ts";
import { cleanEnv, uuid, type OpenOptions } from "./runtime.ts";
import type { CursorLiveState } from "./cursor.ts";

type Json = any;

/// Inherited variables that would let a session use another GitHub account, another Copilot home or another provider
/// than its profile's.
const SCRUBBED = [
  "COPILOT_HOME",
  "COPILOT_GITHUB_TOKEN",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "GH_ENTERPRISE_TOKEN",
  "GITHUB_ENTERPRISE_TOKEN",
  "COPILOT_PROVIDERS_CONFIG",
  "COPILOT_PROVIDER_BASE_URL",
  "COPILOT_PROVIDER_API_KEY",
  "COPILOT_PROVIDER_TYPE",
  "COPILOT_SDK_DEFAULT_CONNECTION",
  "STILLFAIL_COPILOT_SDK",
  "STILLFAIL_COPILOT_TOKEN",
];
/// The package the driver runs on, installed by npm (updates/runtimes.ts).
export const SDK_PACKAGE = "@microsoft/copilot-sdk";
/// The station's driver: beside this module (src/agents/ from source; the bundle's directory, where the build copies it).
export const BRIDGE = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/copilot-bridge.mjs", import.meta.url) : new URL("./copilot-bridge.mjs", import.meta.url));

/// What the station keeps of Copilot in a profile's home: the sign-in (github-token, accounts/copilot.ts) and the
/// sessions (shared by every profile that runs Copilot: agent-home.ts links them), the SDK's home among them.
export const copilotHome = (home: string) => join(home, "copilot");
export const SESSIONS = "sessions";

/// The id of the request that opens the session; the others carry their own.
const OPEN = "open";
const PROMPT = "prompt:";
const STEER = "steer:";

/// Where the station keeps Copilot's SDK: npm installs it there (`-g --prefix`, updates/updates.ts), apart from the
/// machine's own global packages, with its platform's runtime package.
export const sdkPrefix = (data: string) => join(data, "runtimes", "copilot");

const sdkRoots = (data: string) => [join(sdkPrefix(data), "lib", "node_modules"), join(sdkPrefix(data), "node_modules")];

/// The SDK's package under the prefix (lib/node_modules where npm puts a prefix's packages; node_modules on Windows),
/// null when it is not installed.
export async function findSdk(data: string): Promise<string | null> {
  for (const root of sdkRoots(data)) {
    const dir = join(root, ...SDK_PACKAGE.split("/"));
    if (await access(join(dir, "package.json")).then(() => true, () => false)) return dir;
  }
  return null;
}

/// The SDK's version, as its package says (null: not installed; the software page's reading of it: updates.ts readCopilot).
export async function sdkVersionSoon(data: string): Promise<string | null> {
  for (const root of sdkRoots(data)) {
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

/// The station's instructions as Copilot is given them, with how its MCP tools are named there: the runtime prefixes a
/// server's tools with the server's name (`stillfail-chat_post`), not the `mcp__stillfail__…` another runtime uses.
export const copilotRules = (instructions: string) =>
  `${instructions}${instructions === "" ? "" : "\n\n"}The station's tools (chat_post, chat_state and the others named in these instructions) are MCP tools named stillfail-<tool>: stillfail-chat_post and so on. Call one by that name without listing the server's tools first.`;

/// The profile's own GitHub token (a fine-grained PAT or an OAuth token: gho_, ghu_, github_pat_): its access key, its
/// own COPILOT_GITHUB_TOKEN, or what its device sign-in kept. None: it is not signed in, and nothing else stands in.
export async function copilotToken(profile: OpenOptions["profile"]): Promise<string | undefined> {
  const access = profile.access as { key?: unknown } | undefined;
  const key = typeof access?.key === "string" ? access.key.trim() : "";
  if (/^(gho_|ghu_|github_pat_)/.test(key)) return key;
  const env = (profile.env as Record<string, unknown> | undefined)?.COPILOT_GITHUB_TOKEN;
  if (typeof env === "string" && env.trim() !== "") return env.trim();
  const kept = await readFile(join(copilotHome(profile.home), "github-token"), "utf8").then((t) => t.trim(), () => "");
  return kept === "" ? undefined : kept;
}

/// What a profile with no token of its own is told when a session would open on it.
export const NOT_SIGNED_IN = "GitHub Copilot is not signed in on this profile: sign it in to GitHub (its profile's sign-in), or give it a token of its own";

/// What a subagent may not call (the bridge refuses it, copilot-bridge.mjs `refusal`): the tools a session speaks by,
/// and slack_api's methods that write.
export const SILENT = { tools: SPEAKS, slackWrites: SLACK_SPOKEN };

/// A session as a next station takes it up.
export type CopilotSnapshot = { runtime: "copilot"; id: string; runner: string; turn: { busy: boolean; aborting: boolean }; tools: string | null; live: CursorLiveState; model: string | null; effort: string | null };

export type CopilotDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The Node the bridge runs on (the station's own).
  node?: string;
  /// The driver and the SDK's package (tests give their own): the station's when not given.
  bridge?: string;
  sdk?: string;
  /// What `open` tells the bridge besides (tests: a model provider of their own).
  extra?: Record<string, unknown>;
};

export class CopilotDriver extends OwnProcessDriver<CopilotSession> {
  private readonly node: string;
  private readonly bridge: string;
  private readonly sdk: string | undefined;
  private readonly extra: Record<string, unknown>;

  constructor(options: CopilotDriverOptions) {
    super(options.data);
    this.node = options.node ?? process.execPath;
    this.bridge = options.bridge ?? BRIDGE;
    this.sdk = options.sdk;
    this.extra = options.extra ?? {};
  }

  runtime(): "copilot" {
    return "copilot";
  }

  /// Read as Cursor's: the bridge speaks its lines.
  hosting() {
    return { kind: "cursor" as const };
  }

  /// Every chat model this GitHub account may use: GitHub's Copilot model catalog, with the profile's token. The
  /// profile's check offers these, and a chat may pick any of them.
  async models(profile: OpenOptions["profile"]): Promise<string[]> {
    const token = await copilotToken(profile);
    if (token === undefined) return [];
    const answer = await fetch("https://api.githubcopilot.com/models", {
      headers: { authorization: `Bearer ${token}`, "copilot-integration-id": "vscode-chat", accept: "application/json" },
    });
    if (!answer.ok) throw new Error(`GitHub Copilot models: ${answer.status}`);
    const body = (await answer.json().catch(() => null)) as Json;
    const data = Array.isArray(body?.data) ? body.data : [];
    return data
      .filter((m: Json) => m?.policy?.state === "enabled" && m?.capabilities?.type === "chat" && typeof m?.id === "string")
      .map((m: Json) => m.id as string);
  }

  /// Its environment: the profile's token, the SDK's package, the station's tools' token; no other account's.
  private env(options: OpenOptions, sdk: string, token: string): Record<string, string> {
    const env: Record<string, string> = keepLocal({ ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "copilot"), options.route) });
    // (a token in the profile's own variables is its token: given the SDK, not left for the runtime to find)
    delete env.COPILOT_GITHUB_TOKEN;
    env.STILLFAIL_COPILOT_SDK = sdk;
    env.STILLFAIL_COPILOT_TOKEN = token;
    env.STILLFAIL_MCP_TOKEN = options.mcpToken;
    env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
    return env;
  }

  async open(options: OpenOptions, events: Events): Promise<CopilotSession> {
    const sessions = join(copilotHome(options.profile.home), SESSIONS);
    await mkdir(sessions, { recursive: true });
    const sdk = this.sdk ?? (await findSdk(this.data));
    // Not installed: the person's message waits for it as for any runtime not on PATH (agents/runner.ts).
    if (sdk === null) throw new CommandMissing("copilot");
    const token = await copilotToken(options.profile);
    if (token === undefined) throw new Error(NOT_SIGNED_IN);
    if (options.resume !== undefined && !(await access(join(sessions, `${options.resume}.jsonl`)).then(() => true, () => false))) {
      // Not one this driver kept (the CLI's ACP server's sessions were its own home's): failing here lets the caller
      // start fresh, the transcript the station kept of it still read.
      throw new Error(`no Copilot session ${options.resume}`);
    }
    const model = options.model ?? profileModel(options.profile) ?? null;
    const effort = options.effort !== undefined && options.effort !== "" ? options.effort : null;
    const session = new CopilotSession(this, "", { busy: false, aborting: false, closed: false }, null, events, model, effort);
    session.toolsUrl = options.mcpUrl;
    await this.start(session, options, this.node, [this.bridge], this.env(options, sdk, token));
    try {
      const opened = await session.request(OPEN, "open", {
        cwd: options.cwd,
        ...(options.resume !== undefined ? { resume: options.resume } : {}),
        ...(model !== null && model !== "" ? { model } : {}),
        ...(effort !== null ? { effort } : {}),
        mcpUrl: options.mcpUrl,
        instructions: copilotRules(options.instructions),
        ...(options.skills !== undefined ? { skills: options.skills } : {}),
        own: copilotHome(options.profile.home),
        sessions,
        silent: SILENT,
        ...this.extra,
      }, "Copilot's SDK did not open the session in time");
      if (typeof opened?.session !== "string" || opened.session === "") throw new Error("Copilot's SDK named no session");
      session.named(opened.session);
    } catch (error) {
      await session.dispose();
      throw error;
    }
    return session;
  }

  protected handedOver(_options: OpenOptions, handed: CopilotSnapshot, _info: RunnerInfo, events: Events) {
    const session = new CopilotSession(this, handed.id, { ...handed.turn, closed: false }, handed.live, events, handed.model, handed.effort ?? null);
    session.toolsUrl = handed.tools;
    return session;
  }

  /// What the station before had handled, read again by the program, says the session and where its turn stands.
  protected crashed(options: OpenOptions, replayed: Replayed, _info: RunnerInfo, events: Events) {
    const turn: TurnState = { busy: false, aborting: false, ...(replayed.turn ?? {}), closed: false };
    const session = new CopilotSession(this, replayed.session ?? options.resume ?? "", turn, replayed.live ?? null, events, options.model ?? profileModel(options.profile) ?? null, options.effort ?? null);
    session.toolsUrl = options.mcpUrl || null;
    return session;
  }
}

/// A session: what the bridge's lines do to its turn and its live steps is the program's to read (mb/src/cursor), which
/// gives this the answers to its requests and the bridge's notes.
export class CopilotSession extends OwnProcessSession {
  /// The model and effort its turns run on (null: the runtime's).
  private model: string | null;
  private effort: string | null;

  constructor(driver: CopilotDriver, sessionId: string, turn: TurnState, live: CursorLiveState | null, events: Events, model: string | null, effort: string | null) {
    super(driver, sessionId, turn, events, live);
    this.model = model;
    this.effort = effort;
  }

  /// A request whose answer is waited for: an error answer rejects.
  request(id: string, op: string, params: Json, late?: string): Promise<Json> {
    const answer = this.waiting.wait(id, (m) => (typeof m?.error === "string" ? new Error(`copilot ${op}: ${m.error}`) : null), late);
    this.proc.write(JSON.stringify({ id, op, ...params }));
    return answer;
  }

  /// An answer to a request, or a note: the context compacted (a prompt it refused ends the turn there, in the program).
  protected heard(line: string) {
    const message = parseLine("copilot", line);
    if (message === undefined) return;
    if (message.note === "compacted") return this.events({ type: "compacted" });
    if (this.waiting.answer(message.id, message)) return;
    if (typeof message.error !== "string") return;
    log.warn("agents::copilot", "copilot refused a request", { session: this.sessionId, request: String(message.id), error: message.error });
  }

  async prompt(text: string) {
    this.startable();
    this.turn.busy = true;
    this.proc.tell("begin");
    this.proc.write(JSON.stringify({ id: `${PROMPT}${uuid()}`, op: "prompt", text, ...(this.model !== null && this.model !== "" ? { model: this.model } : {}) }));
  }

  /// Into the running turn, as the SDK's `immediate` message: the turn takes it at its next step. Not delivered (the
  /// turn ending as it came): the station gives it as the next turn's.
  async steer(text: string) {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return false;
    try {
      const answer = await this.request(`${STEER}${uuid()}`, "steer", { text });
      return answer?.delivered === true;
    } catch (e) {
      log.warn("agents::copilot", "a message could not go into the running turn", { session: this.sessionId, error: (e as Error).message });
      return false;
    }
  }

  /// Between turns, another model or effort from the next model call on (the SDK's setModel): no new process.
  retune(options: OpenOptions) {
    if (this.turn.closed || this.turn.busy || this.sessionId === "") return false;
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined || model === "") return false;
    const effort = options.effort !== undefined && options.effort !== "" ? options.effort : null;
    this.proc.write(JSON.stringify({ id: `retune:${uuid()}`, op: "retune", model, ...(effort !== null ? { effort } : {}) }));
    this.model = model;
    this.effort = effort;
    return true;
  }

  /// Between turns, the runtime's own compaction, as a turn of its own (its end says whether it could).
  async compact() {
    this.startable();
    this.turn.busy = true;
    this.proc.tell("begin");
    this.proc.write(JSON.stringify({ id: `compact:${uuid()}`, op: "compact" }));
  }

  async abort() {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return;
    this.turn.aborting = true;
    this.proc.tell("aborting");
    this.proc.write(JSON.stringify({ id: `cancel:${uuid()}`, op: "cancel" }));
  }

  snapshot(): CopilotSnapshot {
    const frozen = this.handOver();
    const turn = frozen?.turn ?? this.turn;
    return { runtime: "copilot", id: this.sessionId, runner: this.proc.info.id, turn: { busy: turn.busy === true, aborting: turn.aborting === true }, tools: this.toolsUrl, live: frozen?.live ?? this.liveState, model: this.model, effort: this.effort };
  }
}
