// Claude Code driver: one stream-json process or interactive TUI bridge per session, under a
// runner whose id comes from the session key.
//
// Behaviour pinned by spikes:
// - a turn is framed by system/init … result; `result.is_error` decides success, not `subtype` (an auth failure ends
//   as subtype "success");
// - 401/403 is retried silently for minutes, visible only as system/api_retry frames, so the first one fails the turn
//   (but see RENEWED);
// - input written while a turn is finishing may start a turn of its own (a system/init with no prompt of ours);
// - interrupt is a control_request; the turn still ends with a result frame.
// - background_tasks (a control_request) moves the Bash commands and subagents a turn waits on to the background: each
//   call returns at once and the turn goes on; a task_notification tells when one ends. Input written after it is
//   read in the turn then, not when they end.
// - each background command and subagent is told as it starts (system/task_started, is_backgrounded; or task_updated
//   with it later) and as it ends (task_notification, or task_updated with a final status); a subagent's own commands
//   say owned_by_subagent. They all end with the process.
import { link, mkdir, readdir, realpath, stat, symlink } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { REPO_RULES_COMMAND, hookCommand, hookNode } from "./repo-rules.ts";
import { SLACK_SPOKEN, SPEAKS, SPEAKS_WRITING } from "../tools/mcp.ts";
import { RenewRefused } from "../accounts/console.ts";
import { claudeToken as claudeFileToken } from "../accounts/oauth.ts";
import { log } from "../ops/log.ts";
import { claudeProject } from "../read/transcript.ts";
import { chars } from "./live.ts";
import { CLAUDE_TOKEN_MARGIN_MS, machineClaudeToken, type Env, type MachineToken } from "./machine-logins.ts";
import { fileCredentialsSoon, takeBack, takeBackMissing } from "./no-keychain.ts";
import { type Events, type Replayed, OwnProcessDriver, OwnProcessSession } from "./own-process.ts";
import { accessKind, expandRoute, isMachine, keyFile, profileEnv, profileFast, profileModel, takesFast } from "./profiles.ts";
import { runnerBinary, type RunnerInfo } from "./runner.ts";
import { withShellCommand } from "../ops/shell-path.ts";
import type { AgentsHost } from "./mb-agents.ts";
import { TOOL_SERVERS, cleanEnv, unreachable, uuid, type BackgroundTask, type OpenOptions, type Profile } from "./runtime.ts";
import { keepLocal } from "../ops/agent-env.ts";
import { wall } from "../ops/fibers.ts";
import { peerHttpBase } from "../tools/http.ts";
import { Said, stationLang, tr } from "../ops/i18n.ts";

type Json = any;

const TUI_BRIDGE = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/claude-tui.mjs", import.meta.url) : new URL("./claude-tui.mjs", import.meta.url));
const TUI_NODE = hookNode(TUI_BRIDGE);
const tuiRunner = (info: RunnerInfo) => /(?:^|[\\/])claude-tui\.mjs$/.test(info.args[0] ?? "");

const MCP_TOKEN_VAR = "STILLFAIL_MCP_TOKEN";
/// Inherited variables that would let a session authenticate as something other than its profile.
const SCRUBBED = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"];

/// The value given a flag in a process's arguments.
const flagOf = (args: string[], flag: string) => {
  const at = args.indexOf(flag);
  return at >= 0 ? args[at + 1] : undefined;
};

/// Whether a process runs Fast (Claude Code's `fastMode` setting), for an account that takes it (an Anthropic key):
/// as the session is set, else as its profile is. Fixed for the process, as its effort is.
const fastFor = (options: OpenOptions): boolean | undefined => (takesFast(options.profile) ? (options.fast ?? profileFast(options.profile)) : undefined);

/// The Fast a process was started with (its --settings' `fastMode`).
function fastOf(args: string[]): boolean | undefined {
  try {
    const fast = JSON.parse(flagOf(args, "--settings") ?? "")?.fastMode;
    return typeof fast === "boolean" ? fast : undefined;
  } catch {
    return undefined;
  }
}

/// The address of the station's tools a process was started with (its --mcp-config); null when it does not say.
export function mcpUrlOf(args: string[]): string | null {
  try {
    const servers = JSON.parse(flagOf(args, "--mcp-config") ?? "")?.mcpServers ?? {};
    const url = TOOL_SERVERS.map((name) => servers[name]?.url).find((u) => typeof u === "string");
    return url ?? null;
  } catch {
    return null;
  }
}

/// What a frame says of the station's tools being out of reach (null: nothing): their server failed to connect as a
/// turn started, or a call to one of them (`calls`: the ids of those made, noted here as they are) failed as
/// unreachable. Seen in the field as `ECONNREFUSED: Unable to connect…`, then `MCP server "stillfail" is not connected`.
/// What the program reads a process by does this (mb/src/claude/frames.mbt); this is what it is held to (tools-reach.test.ts).
export function toolsLostIn(frame: Json, calls: Set<string>): string | null {
  const kind = frame?.type;
  const content: Json[] = Array.isArray(frame?.message?.content) ? frame.message.content : [];
  if (kind === "system" && frame.subtype === "init" && Array.isArray(frame.mcp_servers)) {
    const server = frame.mcp_servers.find((s: Json) => TOOL_SERVERS.includes(s?.name));
    if (server?.status === "failed") return `the ${server.name} MCP server failed to connect`;
  } else if (kind === "assistant") {
    for (const c of content) {
      if (c?.type === "tool_use" && typeof c.id === "string" && TOOL_SERVERS.some((s) => String(c.name ?? "").startsWith(`mcp__${s}__`))) calls.add(c.id);
    }
  } else if (kind === "user") {
    for (const c of content) {
      if (c?.type !== "tool_result" || !calls.delete(c.tool_use_id) || c.is_error !== true) continue;
      const text = typeof c.content === "string" ? c.content : Array.isArray(c.content) ? c.content.map((x: Json) => (typeof x?.text === "string" ? x.text : "")).join("\n") : "";
      if (unreachable(text)) return chars(text, 300);
    }
  }
  return null;
}

export const userMessage = (text: string) => JSON.stringify({ type: "user", message: { role: "user", content: [{ type: "text", text }] } });

/// Claude keeps a session at $CLAUDE_CONFIG_DIR/projects/<encoded cwd>/<id>.jsonl, the cwd as it sees it (its real
/// path, as `bringTranscript` names it): looked for in that project first, then in the one of `cwd` as given, then in
/// every project's (it ran elsewhere before: many directories on a station, each looked at). Where it is, or null.
export async function transcriptAt(home: string, sessionId: string, cwd: string): Promise<string | null> {
  for (const project of new Set([claudeProject(await realpath(cwd).catch(() => cwd)), claudeProject(cwd)])) {
    const here = project === null ? null : join(home, "projects", project, `${sessionId}.jsonl`);
    if (here !== null && (await isFile(here))) return here;
  }
  let dirs: string[];
  try {
    dirs = await readdir(join(home, "projects"));
  } catch {
    return null;
  }
  for (const d of dirs) {
    const path = join(home, "projects", d, `${sessionId}.jsonl`);
    if (await isFile(path)) return path;
  }
  return null;
}

const isFile = (path: string) => stat(path).then((s) => s.isFile(), () => false);

/// A session found in another directory's project (it ran elsewhere before) is linked into `cwd`'s, where `--resume`
/// looks: an older Claude Code looks only there (2.1.63, on FB-16's station; 2.1.321 looks in every project's) and ends
/// at once with `error_during_execution` ("No conversation found with session ID"), never reaching the model. Named by
/// the directory as the process sees it (symbolic links resolved). A hard link, else a symbolic one: the one file goes
/// on either way, whichever name it is written by. Nothing done where neither can be made.
export async function bringTranscript(home: string, sessionId: string, cwd: string, found: string): Promise<void> {
  const project = claudeProject(await realpath(cwd).catch(() => cwd));
  if (project === null) return;
  const dir = join(home, "projects", project);
  const here = join(dir, `${sessionId}.jsonl`);
  if (here === found) return;
  try {
    await mkdir(dir, { recursive: true });
    await link(found, here).catch(() => symlink(found, here));
  } catch (e) {
    log.warn("agents::claude", "could not bring a session's transcript to where claude resumes it", { session: sessionId, error: (e as Error).message });
  }
}

/// `renews`: its token is handed over and renewed while it runs (RENEWED): a first 401 is left to that.
/// `renewed`: a new token was given it in this turn, so another 401 is not the old token's.
/// `tasks`: the commands and subagents it runs that have not ended, by id (`background` once moved there).
/// `compacting`: the turn is a `/compact` asked for by hand, and `compactError` why it compacted nothing.
export type Turn = { busy: boolean; aborting: boolean; authFailure: string | null; closed: boolean; renews?: boolean; renewed?: boolean; tasks?: Record<string, Task>; compacting?: boolean; compactError?: string | null };
export type Task = BackgroundTask & { background: boolean };

/// What its tasks as the turn leaves them run in the background.
export const backgroundOf = (turn: Turn): BackgroundTask[] =>
  Object.values(turn.tasks ?? {})
    .filter((t) => t.background)
    .map(({ id, kind, description, startedAt }) => (startedAt === undefined ? { id, kind, description } : { id, kind, description, startedAt }));

/// A token handed to the process (a machine login's, a local subscription's, a lent one) is renewed while it runs:
/// started with these, Claude Code asks its host for a new one on a 401 (an `oauth_token_refresh` control request) and
/// retries with it, so the process, its background tasks and subagents go on without racing on `.credentials.json`. It
/// honours them only for a few entrypoints; claude-desktop changes neither its prompt nor its tools (only the entrypoint
/// named in its requests), as checked on 2.1.299.
const RENEWED = { CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH: "1", CLAUDE_CODE_ENTRYPOINT: "claude-desktop" };
/// A CLI that does not ask (one too old) retries a 401 on its own: past the program's RENEW_ATTEMPTS (mb/src/claude
/// frames.mbt, 2) it is stopped as before.

/// What Claude Code reads on a tool of an MCP server's list as "never deferred" (tools/mcp.ts `Listing.loaded`). By
/// itself it keeps every MCP tool behind its ToolSearch: the first request of a session carries none of the station's
/// tools, only their names in a reminder, and a turn began with a search for chat_post and chat_state before it could
/// answer. Observed on 2.1.323, 2026-11-14, in the requests it made to a made-up Messages API, with ENABLE_TOOL_SEARCH
/// unset as with it true: a tool so marked is in the first request's `tools` whole (description and schema, the mark
/// itself not sent on), the others stay names, and that request waits for the server's tools/list (one answered 3 s
/// late was waited for). Not its server-wide `alwaysLoad`: the station's tools together were 73 KB (agents/agy.ts),
/// which its deferral rightly keeps out of every request. A subagent it starts (its Agent tool; general-purpose and
/// Explore, same day) is listed as its parent is: the two whole in its first request (10.7 KB as the station declares
/// them), where it had their names before, and nothing of the station's instructions, which --append-system-prompt
/// gives the main agent alone: it is shown chat_post unsearched, untold how a chat is posted to, and its call of it
/// is refused (`SILENT_SUBAGENTS`).
export const CLAUDE_TOOL_LOADED = Object.freeze({ "anthropic/alwaysLoad": true });

/// A tool result with this `_meta` ends the turn without another model request, unless a call of that message failed
/// (2.1.330, 2026-11-22). The request it saves wrote only words no one is shown, and read the whole context to do so.
export const CLAUDE_TURN_ENDED = Object.freeze({ "claude/endTurn": true });

/// The hook that refuses a subagent the tools a session speaks by (./subagent-hook.mjs says how it knows one).
export const SUBAGENT_HOOK = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/subagent-hook.mjs", import.meta.url) : new URL("./subagent-hook.mjs", import.meta.url));
/// A hook that does not answer is given up on after this many seconds, and the call goes on as if there were none
/// (2.1.323, 2026-11-14: a hook asleep, the main agent's chat_post made as the time ran out); Claude Code's own limit
/// is ten minutes, before the main agent's every post. One run takes 26 ms here.
const SUBAGENT_HOOK_SECONDS = 10;
/// A subagent never speaks in a chat (tools/mcp.ts `SPEAKS`), and Claude Code gives one every tool of its session: a
/// PreToolUse hook on exactly those tools, as Claude Code names them, so that no other call starts a process for it,
/// and on slack_api, whose writes it refuses and whose reads it lets through (the hook is told the methods that
/// speak: `SLACK_SPOKEN`, the list the threads rule goes by and a streamed message).
/// On every session that has the station's tools, one continued from a terminal too: with the hook and without, a
/// session's requests were the same (system prompt, tools, messages; 2.1.323, 2026-11-14), so its cache holds.
/// `disableAllHooks: false` goes with it wherever it goes (`open`): --settings is read over the user's, the project's
/// and the local settings file, any of which turned every hook off with `disableAllHooks: true`, this one too, and a
/// subagent wrote <cwd>/.claude/settings.local.json so and posted (measured, same day; with false said here its next
/// call was refused as its first). So a person's own hooks, turned off by them in one of those files, run again in a
/// station's sessions.
/// What it does not hold: a subagent's shell has the session's token as its parent's has, and a call made from there
/// is the session's to the station; a managed policy's `disableAllHooks` or `allowManagedHooksOnly`, Claude Code run
/// bare or in safe mode, and a workspace it does not trust each still turn this hook off (read in 2.1.323's code by
/// its reviewer, not run); and what goes wrong in the hook lets the call through (its file says why).
export const SILENT_SUBAGENTS = {
  PreToolUse: [
    {
      matcher: TOOL_SERVERS.flatMap((server) => [...SPEAKS, SPEAKS_WRITING].map((tool) => `mcp__${server}__${tool}`)).join("|"),
      hooks: [{ type: "command", command: hookCommand(SUBAGENT_HOOK, SLACK_SPOKEN.join(",")), timeout: SUBAGENT_HOOK_SECONDS }],
    },
  ],
};

/// Sets of hooks as one: an event several of them have keeps the entries of each, in their order (a spread would keep
/// the last set's alone).
export function hooksOf(...sets: Record<string, unknown[]>[]): Record<string, unknown[]> {
  const all: Record<string, unknown[]> = {};
  for (const set of sets) for (const [event, entries] of Object.entries(set)) all[event] = [...(all[event] ?? []), ...entries];
  return all;
}

/// What Claude Code brings of its own that a station's chat agent cannot or must not use, kept out of its context (a
/// fresh session began at 30k tokens, a third of them these; checked on 2.1.289):
/// - its own scheduling: still.fail's jobs are the station's (stillfail-cron); a wakeup or cron of the process's own
///   dies with it;
/// - claude.ai connectors: they come with the Claude account the session runs on, which changes as accounts run out,
///   so none is there to count on; and Claude Docs has the agent open a doc on claude.ai, out of the chat, first;
/// - skills, each listed with its whole description in every session: "off" for those needing what a station's process
///   never has (the desktop app's browser and computer use, connectors, a terminal, permission prompts, a scheduler of
///   its own, settings in a profile's home it leaves when it changes account); "name-only" for those seldom needed.
const DISALLOWED = ["ScheduleWakeup", "CronCreate", "CronDelete", "CronList", "RemoteTrigger"];
const SETTINGS = {
  disableClaudeAiConnectors: true,
  // A repository's rules told as its tools first touch it (./repo-rules.ts), and again after a compaction.
  hooks: {
    PostToolUse: [{ matcher: "Bash|Read|Edit|Write|MultiEdit|NotebookEdit|Grep|Glob", hooks: [{ type: "command", command: REPO_RULES_COMMAND }] }],
    SessionStart: [{ matcher: "compact", hooks: [{ type: "command", command: REPO_RULES_COMMAND }] }],
  },
  skillOverrides: {
    ...Object.fromEntries(["loop", "schedule", "keybindings-help", "fewer-permission-prompts", "plugin-authoring", "update-config"].map((name) => [name, "off"])),
    ...Object.fromEntries(["dataviz", "claude-api", "code-review", "run"].map((name) => [name, "name-only"])),
    ...Object.fromEntries(["computer-use", "chrome-browser", "built-in-browser", "docs", "google-workspace", "morning", "import-memory"].map((name) => [`anthropic-skills:${name}`, "off"])),
    ...Object.fromEntries(["docx", "pptx", "xlsx", "pdf", "deep-research", "skill-creator"].map((name) => [`anthropic-skills:${name}`, "name-only"])),
  },
};

/// Its live steps as the program keeps them (mb/src/claude `Live::state`): the message, its blocks, the calls running.
export type ClaudeLiveState = { message: string; blocks: [number, Json][]; tools: string[] };

/// A session as a next station takes it up.
export type ClaudeSnapshot = {
  runtime: "claude";
  id: string;
  runner: string;
  turn: { busy: boolean; aborting: boolean; authFailure: string | null; renews?: boolean; tasks?: Record<string, Task>; compacting?: boolean; compactError?: string | null };
  machineExpires: number | null;
  live: ClaudeLiveState;
};

export type ClaudeDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path (server.rs gives "claude").
  command?: string;
  /// The station's own environment (machine logins are read in it); process.env by default.
  env?: Env;
  /// The machine login's current token, renewed when about to run out or when it is `rejected` (claude_oauth.rs; the
  /// accounts module's).
  machineToken?: (env: Env, rejected?: string) => Promise<MachineToken>;
  /// A local subscription profile's current token, renewed under one lock by the station so concurrent `claude -p`
  /// processes neither race on a single-use refresh token nor delete `.credentials.json` on failure.
  subscriptionToken?: (profile: Profile, rejected?: string) => Promise<MachineToken>;
  /// What reads its processes' output off the station's thread (mb-agents.ts): the MoonBit program by default.
  agents?: AgentsHost;
  /// Another station's subscription, borrowed (share/index.ts): a token lent by the station signed in on it, handed
  /// to the process as the machine's is.
  lent?: { borrowed(profile: Profile): boolean; token(profile: Profile, rejected?: string): Promise<MachineToken> };
};

const interruptRequest = () => JSON.stringify({ type: "control_request", request_id: `interrupt-${uuid()}`, request: { subtype: "interrupt" } });

export class ClaudeDriver extends OwnProcessDriver<ClaudeSession> {
  private readonly command: string;
  private readonly env: Env;
  private readonly machineToken: (env: Env, rejected?: string) => Promise<MachineToken>;
  private readonly subscriptionToken: ClaudeDriverOptions["subscriptionToken"];
  private readonly lent: ClaudeDriverOptions["lent"];

  constructor(options: ClaudeDriverOptions) {
    super(options.data, options.agents);
    this.command = options.command ?? "claude";
    this.env = options.env ?? process.env;
    this.machineToken = options.machineToken ?? machineClaudeToken;
    this.subscriptionToken = options.subscriptionToken;
    this.lent = options.lent;
  }

  runtime(): "claude" {
    return "claude";
  }

  /// Its process is named by its session id in the log.
  protected label(_options: OpenOptions, session: ClaudeSession) {
    return `claude ${session.id()}`;
  }

  hosting() {
    return { kind: "claude" as const };
  }

  async open(options: OpenOptions, events: Events): Promise<ClaudeSession> {
    const home = options.profile.home;
    await mkdir(home, { recursive: true });
    if (options.resume !== undefined) {
      const found = await transcriptAt(home, options.resume, options.cwd);
      // claude would start and exit at once; failing here lets the caller start fresh.
      if (found === null) throw new Error(`no claude transcript for session ${options.resume}`);
      await bringTranscript(home, options.resume, options.cwd, found);
    }
    const sessionId = options.resume ?? uuid();
    const mcpConfig = options.textOnly ? { mcpServers: {} } : { mcpServers: { stillfail: { type: "http", url: options.mcpUrl, headers: { Authorization: `Bearer \${${MCP_TOKEN_VAR}}` } } } };
    const model = options.model ?? profileModel(options.profile);
    const env = keepLocal({ ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "claude"), options.route) });
    const tui = !options.textOnly && options.tui === true;
    const args: string[] = tui ? [] : ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"];
    if (!options.textOnly) args.push("--dangerously-skip-permissions");
    if (options.resume !== undefined) args.push("--resume", sessionId);
    else args.push("--session-id", sessionId);
    if (model !== undefined) args.push("--model", model);
    if (options.effort !== undefined) args.push("--effort", options.effort);
    // None for a session continued from a terminal: its system prompt and tools stay as they began, so its cache holds.
    const ours = options.instructions !== "";
    if (ours) args.push("--append-system-prompt", options.instructions);
    args.push("--mcp-config", JSON.stringify(mcpConfig));
    if (options.textOnly) args.push("--strict-mcp-config", "--tools", "", "--setting-sources", "", "--no-session-persistence", "--disable-slash-commands", "--no-chrome");
    if (ours) args.push("--disallowedTools", DISALLOWED.join(","));
    // A key the station renews in a file (a Kimi sign-in's token, minutes long): Claude Code's key helper reads it,
    // again every minute and after a 401 (Claude Code runs it in a POSIX shell, Git Bash on Windows).
    const file = keyFile(options.profile);
    const fast = fastFor(options);
    const settings = {
      ...(ours ? SETTINGS : {}),
      // With the station's tools, its subagents kept from speaking, whatever a settings file of the machine says of hooks.
      ...(options.textOnly ? {} : { disableAllHooks: false, hooks: hooksOf(ours ? SETTINGS.hooks : {}, SILENT_SUBAGENTS) }),
      ...(file === undefined ? {} : { apiKeyHelper: `cat '${file.replaceAll("'", `'\\''`)}'` }),
      // The most context it runs with: it compacts on its own at it (its window for the model, clamped to the model's).
      ...(options.context === undefined ? {} : { autoCompactWindow: options.context }),
      // Said either way: one turned on by hand in its home (/fast) would otherwise stay on.
      ...(fast === undefined ? {} : { fastMode: fast }),
    };
    if (Object.keys(settings).length > 0) args.push("--settings", JSON.stringify(settings));

    if (file !== undefined) env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = "60000";
    env.CLAUDE_CONFIG_DIR = home;
    // Claude Code refuses --dangerously-skip-permissions to root (a station installed under sudo, a root container)
    // and exits before the turn begins; IS_SANDBOX=1 is its own way to say the machine is the agent's to run as root.
    if (!options.textOnly && process.getuid?.() === 0) env.IS_SANDBOX = "1";
    env[MCP_TOKEN_VAR] = options.mcpToken;
    // Web services of the workspace's other stations: <this>/<station>/<port>/<path> (mesh/peer-http.ts).
    env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
    // Lets the agent name its own transcript, e.g. for an independent reviewer (codex has CODEX_THREAD_ID).
    env.STILLFAIL_RUNTIME_SESSION_ID = sessionId;
    const localSub = !isMachine(options.profile) && !this.lent?.borrowed(options.profile) && accessKind(options.profile) === "subscription";
    if (!isMachine(options.profile)) await fileCredentialsSoon(env);
    // A machine profile runs on the machine's own login, handed over as its current token; a local subscription on its
    // own login renewed here under one lock; another station's subscription on the token that station lends.
    const renew = this.renewer(options.profile);
    let machine: MachineToken | undefined;
    let renews = renew !== null;
    if (renew) {
      try {
        machine = await renew();
      } catch (error) {
        if (!localSub) throw error;
        // A local subscription whose refresh failed (or a test home with no token yet): never throw in open(), which
        // actor.ts treats as a broken --resume or a broken startup without rechecking or failing over. Hand over any
        // kept access token so Claude Code never touches or deletes .credentials.json itself.
        const kept = await claudeFileToken(home);
        if (kept !== undefined) {
          if (error instanceof RenewRefused) {
            env.CLAUDE_CODE_OAUTH_TOKEN = kept;
            renews = false;
          } else {
            machine = { token: kept, expiresAt: 0 };
          }
        } else {
          await takeBackMissing(home);
          renews = false;
        }
      }
    } else if (!isMachine(options.profile)) {
      // Its own login stays in its home's file when it refreshes it.
      await takeBack(home);
    }
    if (machine) {
      env.CLAUDE_CODE_OAUTH_TOKEN = machine.token;
      if (!tui) Object.assign(env, RENEWED);
    }
    // Its own root certificates, not the system's: read from the macOS keychain by a process outside the desktop
    // session, they took up to 36 s before a new session could start. One the user chose wins.
    env.CLAUDE_CODE_CERT_STORE ??= "bundled";
    // Claude Code nudges a model that has gone a few turns without writing to the user to say what it is doing. Here
    // ordinary output reaches nobody, so the nudge turned into status posts in the chat; the instructions say when to post.
    env.CLAUDE_CODE_SILENT_TURN_REMINDER ??= "0";

    // Renewed while it runs, it is never started again for its token; one read from a file again after a 401 is not
    // stopped at the first.
    const session = new ClaudeSession(this, sessionId, { busy: false, aborting: false, authFailure: null, closed: false, renews: (!tui && machine !== undefined && renews) || file !== undefined }, tui ? machine?.expiresAt ?? null : null, null, events, options.effort, renews ? renew : null, machine?.token ?? null, tui);
    session.toolsUrl = options.mcpUrl;
    session.fast = fast;
    if (tui) {
      // First-run appearance selection is for a person at a terminal. The TUI still requires a trusted workspace for hooks.
      env.IS_DEMO = "1";
      await this.start(session, options, process.execPath, [TUI_BRIDGE, TUI_NODE, runnerBinary(), this.command, ...args], await withShellCommand(this.command, env) as Record<string, string>);
    } else {
      await this.start(session, options, this.command, args, env);
    }
    return session;
  }

  /// Where a profile whose token is handed to the process gets a current one (null for a profile without one):
  /// the machine login's, a local subscription's renewed here, or the one lent by the station a borrowed subscription
  /// is signed in on.
  private renewer(profile: Profile): Renew | null {
    if (isMachine(profile)) return (rejected) => this.machineToken(this.env, rejected);
    const lent = this.lent;
    if (lent?.borrowed(profile)) return (rejected) => lent.token(profile, rejected);
    if (accessKind(profile) === "subscription" && this.subscriptionToken) {
      return (rejected) => this.subscriptionToken!(profile, rejected);
    }
    return null;
  }

  protected handedOver(options: OpenOptions, handed: ClaudeSnapshot, info: RunnerInfo, events: Events) {
    const session = new ClaudeSession(this, handed.id, { ...handed.turn, closed: false }, handed.machineExpires, handed.live, events, flagOf(info.args, "--effort"), this.renewer(options.profile), null, tuiRunner(info));
    // The address it was told is in its arguments: the station's may have moved since (hub.ts `toolsAt`).
    session.toolsUrl = mcpUrlOf(info.args);
    session.fast = fastOf(info.args);
    return session;
  }

  /// What the station before had handled (stdout up to where it acknowledged), read again by the program, says where
  /// the turn stands and its live steps (mb agents_own.mbt `own_replay`: its frames as on_frame and Live::feed read them).
  protected crashed(options: OpenOptions, replayed: Replayed, info: RunnerInfo, events: Events) {
    const turn: Turn = { busy: false, aborting: false, authFailure: null, ...(replayed.turn ?? {}), closed: false };
    const flag = info.args.findIndex((a) => a === "--session-id" || a === "--resume");
    const sessionId = flag >= 0 ? info.args[flag + 1]! : (options.resume ?? "");
    // Its token is not known, nor whether it asks for a new one: as if about to run out, so its next turn starts it
    // again with a current one (a machine login's or a lent one).
    const renew = this.renewer(options.profile);
    const session = new ClaudeSession(this, sessionId, turn, renew ? wall.now() : null, replayed.live ?? null, events, flagOf(info.args, "--effort"), renew, null, tuiRunner(info));
    session.toolsUrl = mcpUrlOf(info.args);
    session.fast = fastOf(info.args);
    return session;
  }
}

/// A current token for a process, renewed first when `rejected` is the one given.
type Renew = (rejected?: string) => Promise<MachineToken>;

export class ClaudeSession extends OwnProcessSession<Turn> {
  /// The machine login's token this process runs on (machine profiles): when it runs out.
  private readonly tui: boolean;
  private machineExpires: number | null;
  /// The effort it was started with: fixed for the process (`--effort` has no switch while it runs).
  private effort: string | undefined;
  /// The Fast it was started with (fastFor; none: an account that does not take it), fixed for the process too.
  fast: boolean | undefined;
  /// Where it gets a new token when it asks (RENEWED), and the one it was given last (null when not known here).
  private renew: Renew | null;
  private token: string | null;

  constructor(driver: ClaudeDriver, sessionId: string, turn: Turn, machineExpires: number | null, live: ClaudeLiveState | null, events: Events, effort: string | undefined, renew: Renew | null, token: string | null, tui = false) {
    super(driver, sessionId, turn, events, live);
    this.tui = tui;
    this.renew = renew;
    this.token = token;
    this.effort = effort;
    this.machineExpires = machineExpires;
  }

  /// A new token asked for (RENEWED): the program says it to the session's owner alone.
  protected took(e: Json) {
    if (e?.type !== "renew") return false;
    void this.renewToken(String(e.requestId ?? ""));
    return true;
  }

  /// Never called: its lines are the program's to read, none given here as a line.
  protected heard(_line: string) {}

  /// It was refused with its token and asks for a new one (RENEWED): given one other than the token refused, or told
  /// why not, when its turn ends failed on authentication as before.
  private async renewToken(requestId: string) {
    let response: Json;
    try {
      if (!this.renew) throw new Error("its token is its own login's");
      const got = await this.renew(this.token ?? undefined);
      if (got.token === this.token) throw new Error("no newer token");
      this.token = got.token;
      this.turn.renewed = true;
      this.proc.tell("renewed");
      response = { accessToken: got.token };
      log.info("agents::claude", "gave claude a new token", { session: this.sessionId });
    } catch (error) {
      log.warn("agents::claude", "no new token for claude", { session: this.sessionId, error: (error as Error).message });
      response = { accessToken: null, reason: "refresh_failed" };
    }
    if (this.turn.closed) return;
    this.proc.write(JSON.stringify({ type: "control_response", response: { subtype: "success", request_id: requestId, response } }));
  }

  background() {
    return backgroundOf(this.turn);
  }

  async prompt(text: string) {
    this.begin();
    this.proc.write(userMessage(text));
  }

  /// Its `/compact`, as in a terminal: the CLI says `status: compacting`, then how it went, then the turn's result.
  async compact() {
    this.begin();
    this.turn.compacting = true;
    this.turn.compactError = null;
    this.proc.tell("compact");
    this.proc.write(this.tui ? JSON.stringify({ type: "compact" }) : userMessage("/compact"));
  }

  outlived() {
    return this.tui && this.machineExpires !== null && this.machineExpires - wall.now() < CLAUDE_TOKEN_MARGIN_MS;
  }

  private begin() {
    this.startable();
    // Taken up without knowing whether it renews its token (RENEWED): about to run out, it is started again (resuming)
    // with a current one.
    if (this.machineExpires !== null && this.machineExpires - wall.now() < CLAUDE_TOKEN_MARGIN_MS) throw new Said(tr(stationLang(), "station.claudeAuth.machineRunsOut"));
    this.turn.renewed = false;
    this.turn.busy = true;
    this.proc.tell("begin");
  }

  async steer(text: string) {
    // The station keeps busy-time deliveries in its inbox until this TUI finishes its turn.
    if (this.tui || this.turn.closed || !this.turn.busy) return false;
    this.proc.write(userMessage(text));
    return true;
  }

  async backgroundTools() {
    if (this.turn.closed || !this.turn.busy) return;
    // Ctrl+B: every foreground Bash command and subagent. A CLI without it answers an error, and the message waits
    // as before.
    this.proc.write(JSON.stringify({ type: "control_request", request_id: `background-${uuid()}`, request: { subtype: "background_tasks" } }));
  }

  async abort() {
    if (this.turn.closed || !this.turn.busy || this.turn.aborting) return;
    this.turn.aborting = true;
    this.proc.tell("aborting");
    this.proc.write(interruptRequest());
  }

  /// Another model is set in the process (set_model, read before the next prompt written after it); another effort or
  /// Fast needs a new one.
  retune(options: OpenOptions) {
    const model = options.model ?? profileModel(options.profile);
    if (this.tui || options.tui === true || this.turn.closed || this.turn.busy || model === undefined || options.effort !== this.effort || fastFor(options) !== this.fast) return false;
    this.proc.write(JSON.stringify({ type: "control_request", request_id: `model-${uuid()}`, request: { subtype: "set_model", model } }));
    return true;
  }

  snapshot(): ClaudeSnapshot {
    // (read by the program: where it stood as its lines were held)
    const frozen = this.handOver();
    if (frozen) {
      const t = frozen.turn ?? {};
      return { runtime: "claude", id: this.sessionId, runner: this.proc.info.id, turn: { busy: t.busy === true, aborting: t.aborting === true, authFailure: t.authFailure ?? null, renews: t.renews, tasks: t.tasks, compacting: t.compacting, compactError: t.compactError }, machineExpires: this.machineExpires, live: frozen.live };
    }
    return {
      runtime: "claude",
      id: this.sessionId,
      runner: this.proc.info.id,
      turn: { busy: this.turn.busy, aborting: this.turn.aborting, authFailure: this.turn.authFailure, renews: this.turn.renews, tasks: this.turn.tasks, compacting: this.turn.compacting, compactError: this.turn.compactError },
      machineExpires: this.machineExpires,
      live: this.liveState,
    };
  }
}
