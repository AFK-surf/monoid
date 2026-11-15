// Antigravity CLI driver: one `agy acp` per session, spoken to in ACP (acp.ts) with one ACP session in it. See
//. Beside what ACP says:
// - its files (sign-in, settings, conversations) are in the profile's, `--gemini-dir`: none of the machine's ~/.gemini,
//   and on macOS none of the login keychain's (`AGY_FILE_TOKENS`);
// - the station's instructions are appended to its system prompt (`_meta.antigravity.systemPrompt.append` of
//   session/new and session/load, which initialize says it takes);
// - it runs without approvals (`--dangerously-skip-permissions`), with no telemetry and no updating itself;
// - a message for the running turn steers it (`promptTakeover`); its model is session/set_model;
// - the station keeps the transcript (acp.ts KeptTranscript), with each turn's usage: the prompt's answer says it.
import { execFile } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { lstat, mkdir, rm, writeFile, readFile } from "node:fs/promises";
import { join } from "node:path";
import { wall } from "../ops/fibers.ts";
import { writePrivateSoon } from "../ops/files.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { peerHttpBase } from "../tools/http.ts";
import { AcpDriver, AcpSession, KeptTranscript, type AcpStart } from "./acp.ts";
import type { Events } from "./own-process.ts";
import { accessKind, expandRoute, profileEnv, profileModel } from "./profiles.ts";
import { TOOL_SERVERS, cleanEnv, failureOf, uuid, type FailureReason, type OpenOptions, type Profile } from "./runtime.ts";

type Json = any;

/// Inherited variables that would let a session use another account or project than its profile's.
const SCRUBBED = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION", "AGY_ADC_AUTH", "AGY_ACCOUNT"];
/// The CLI's home in a profile's: what `agy` signs in to with this as its HOME, its .gemini/ the ACP server's
/// `--gemini-dir`.
export const agyHome = (home: string) => join(home, "agy");
export const geminiDir = (home: string) => join(agyHome(home), ".gemini");
/// Where its sign-in to a Google account lands in that home (its TUI's, `agy` with the profile's agy/ as its HOME:
/// accounts/login.ts), which the ACP server reads from `--gemini-dir`: a file, `id_token_email` whose account it is.
export const agyToken = (home: string) => agyTokenIn(geminiDir(home));
/// The sign-in's file in a `--gemini-dir`.
export const agyTokenIn = (gemini: string) => join(gemini, "antigravity-cli", "antigravity-oauth-token");
/// Where the station notes the Google account's email when `agyToken` is written or checked: the account's name, and
/// which keychain item is this profile's (`agyTakeBack`).
export const agyAccountFile = (home: string) => join(agyHome(home), "account.json");
/// Where `agy acp` keeps its conversation databases under `--gemini-dir` once a signed-in session opens.
export const agyConversations = (home: string) => join(geminiDir(home), "antigravity-cli", "conversations");
export function agyEmailIn(text: string): string | null {
  try {
    const email = JSON.parse(text)?.id_token_email;
    return typeof email === "string" && email !== "" ? email : null;
  } catch {
    return null;
  }
}

export async function noteAgyEmail(home: string, text: string): Promise<string | null> {
  let parsed: Json;
  try {
    parsed = JSON.parse(text);
  } catch {
    await rm(agyAccountFile(home), { force: true }).catch(() => {});
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    await rm(agyAccountFile(home), { force: true }).catch(() => {});
    return null;
  }
  const raw = parsed.id_token_email;
  const email = typeof raw === "string" && raw !== "" ? raw : null;
  try {
    await writeFile(agyAccountFile(home), `${JSON.stringify(email !== null ? { email } : {})}\n`);
  } catch {}
  return email;
}

export async function agyNotedEmail(home: string): Promise<string | null> {
  try {
    const email = JSON.parse(await readFile(agyAccountFile(home), "utf8"))?.email;
    return typeof email === "string" && email !== "" ? email : null;
  } catch {
    return null;
  }
}

/// On macOS, `agy` keeps its sign-in in one login keychain item for the whole user (service `gemini`, account
/// `antigravity`, through go-keyring's `/usr/bin/security`), which `--gemini-dir` does not separate: it reads that item
/// before the profile's `agyToken`, and moved the file there, so every profile ran on whichever account was put there
/// last (2026-11-14: a session moved to another account went on with the first one's quota). Where it thinks it is
/// in an SSH session it keeps the sign-in in the file alone ("Using file-based token storage because SSH session
/// detected", 1.5.9), so the station's processes are given that (`agyEnv`, agy-quota.ts).
export const AGY_FILE_TOKENS = { SSH_CLIENT: "127.0.0.1 0 0" };

/// The keychain item `agy` kept a sign-in in before `AGY_FILE_TOKENS` (go-keyring's encoding taken off), or null.
/// Replaced in tests.
export const agyKeychain = {
  read: () =>
    new Promise<string | null>((resolve) => {
      execFile("/usr/bin/security", ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"], { timeout: 5000 }, (error, stdout) => resolve(error ? null : String(stdout).trim()));
    }),
};

/// go-keyring's stored value as `agy` wrote it: base64 or hex behind a prefix, else as it is.
export function goKeyringValue(stored: string): string {
  if (stored.startsWith("go-keyring-base64:")) return Buffer.from(stored.slice("go-keyring-base64:".length), "base64").toString("utf8");
  if (stored.startsWith("go-keyring-encoded:")) return Buffer.from(stored.slice("go-keyring-encoded:".length), "hex").toString("utf8");
  return stored;
}

/// Whether the profile has its sign-in in its `agyToken`, moving it back there from the keychain where `agy` moved it
/// before `AGY_FILE_TOKENS`: only when the item is the account the profile noted (`agyAccountFile`), since the item is
/// the last account signed in on the machine, not necessarily this profile's. One whose item is another account's
/// signs in again. The item is left: it may be the user's own `agy`'s.
export async function agyTakeBack(home: string): Promise<boolean> {
  try {
    await lstat(agyToken(home));
    return true;
  } catch {}
  if (!platform.hasKeychain) return false;
  const noted = await agyNotedEmail(home);
  if (noted === null) return false;
  const stored = await agyKeychain.read();
  if (stored === null) return false;
  const text = goKeyringValue(stored);
  if (agyEmailIn(text) !== noted) return false;
  try {
    await writePrivateSoon(agyToken(home), text);
  } catch (error) {
    log.warn("agents::agy", "could not move a profile's sign-in out of the keychain", { home, error: String(error) });
    return false;
  }
  log.info("agents::agy", "a profile's sign-in moved back from the keychain to its file", { home });
  return true;
}

/// When the access token of the profile's sign-in runs out (its `token.expiry`), 0 when it has none or none readable.
export function agyExpiryIn(text: string): number {
  try {
    const at = Date.parse(JSON.parse(text)?.token?.expiry);
    return Number.isFinite(at) ? at : 0;
  } catch {
    return 0;
  }
}

export async function agyExpiry(home: string): Promise<number> {
  try {
    return agyExpiryIn(await readFile(agyToken(home), "utf8"));
  } catch {
    return 0;
  }
}

/// The profile's sign-in renewed by `agy` itself, which holds the OAuth client Google renews it for (the station has
/// none of its own): a copy of it, marked run out, given to `agy models` in a directory of its own, which renews it
/// there (1.5.9: 2-3 s), and the renewed one written over the profile's, whose running sessions read it again as it
/// changes. The profile's own file is never marked run out, so nothing running on it is made to renew it too. A
/// failure leaves the profile's file as it was.
export async function agyRenew(home: string, command = "agy"): Promise<void> {
  const had = await readFile(agyToken(home), "utf8");
  const parsed = JSON.parse(had);
  if (typeof parsed?.token?.refresh_token !== "string" || parsed.token.refresh_token === "") throw new Error("no refresh token");
  const dir = join(agyHome(home), "renewing");
  await rm(dir, { recursive: true, force: true });
  try {
    const gemini = join(dir, ".gemini");
    await mkdir(join(gemini, "antigravity-cli"), { recursive: true });
    const marked = agyTokenIn(gemini);
    await writePrivateSoon(marked, JSON.stringify({ ...parsed, token: { ...parsed.token, expiry: "1970-01-01T00:00:00Z" } }));
    const env: Record<string, string> = { ...cleanEnv(SCRUBBED), HOME: dir, ANTIGRAVITY_GEMINI_DIR: gemini, AGY_CLI_DISABLE_AUTO_UPDATE: "1", ...AGY_FILE_TOKENS };
    await new Promise<void>((resolve, reject) => {
      execFile(command, ["models"], { env, cwd: dir, timeout: 30_000 }, (error) => (error ? reject(error) : resolve()));
    });
    const renewed = await readFile(marked, "utf8");
    if (agyExpiryIn(renewed) <= wall.now()) throw new Error("agy did not renew the sign-in");
    await writePrivateSoon(agyToken(home), renewed);
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/// A sign-in as a borrower keeps it: the access token its host lent, no refresh token (so `agy` never renews it here,
/// and asks to sign in once it runs out, which the station prevents by asking its host again first).
export function agyLentFile(lent: { token: Json; email?: string | null; auth_method?: string | null }): string {
  const { refresh_token: _, ...token } = lent.token ?? {};
  return JSON.stringify({ token, auth_method: lent.auth_method ?? "consumer", ...(lent.email ? { id_token_email: lent.email } : {}) });
}
/// How many bytes of the station's tools a session's model is declared (tools/mcp.ts `fitted`). `agy` 1.5.6 in ACP
/// declares an MCP server's tools only while all of them together stay within about 57-60 KB, dropping the largest
/// beyond that, and offers no call_mcp_tool for those it dropped: measured 2026-11-12 with the station's 42 tools
/// (73 KB; chat_post, station_task and secret_save were dropped, so its sessions could not post) and with subsets of
/// them (57 KB declared whole). Kept well under it, for its own tools' growth.
export const AGY_TOOL_BUDGET = 45_000;

/// Where the station keeps its sessions' transcripts.
export const SESSIONS = "sessions";

/// The conversation ids it gives: a path segment of the transcript's.
const SESSION_ID = /^[a-zA-Z0-9_-]+$/;

/// What failed a turn, from what it said of it.
export const classifyFailure = (text: string): FailureReason =>
  failureOf(text, { auth: ["authentication required", "not logged into antigravity", "authentication expired", "couldn't sign in", "invalid_grant", "unauthenticated", "token expired"], limit: ["resource_exhausted", "quota"] });

/// A failure Antigravity CLI tells only in words: a turn whose answer is end_turn, all it said one line of its own
/// notice (⚠). Its spent quota came so on 1.5.9 (2026-11-15: "⚠ Individual quota reached. Please upgrade your
/// subscription to increase your limits. Resets in 56m33s.", where its log says RESOURCE_EXHAUSTED (code 429)), and a
/// session went on asking the spent account instead of moving to another. What the model says is never one: a notice
/// is the whole turn, and only what tells the account, a limit or the provider counts (not `model`, the rest).
export function noticeFailure(said: string): FailureReason | null {
  const text = said.trim();
  if (!text.startsWith("⚠") || text.includes("\n")) return null;
  const reason = classifyFailure(text);
  return reason === "model" ? null : reason;
}

/// The process's arguments: the profile's files, no approvals, no telemetry.
export const agyArgs = (home: string) => ["acp", "--gemini-dir", geminiDir(home), "--dangerously-skip-permissions", "--disable-telemetry"];

/// Environment of an Antigravity CLI process: the station's scrubbed environment, the profile's own variables (which
/// win), its `--gemini-dir` (`ANTIGRAVITY_GEMINI_DIR`, for sandbox sync too), its sign-in in that file alone
/// (`AGY_FILE_TOKENS`), updates off, and the peer HTTP endpoint.
export function agyEnv(options: OpenOptions): Record<string, string> {
  const env: Record<string, string> = { ...cleanEnv(SCRUBBED), ...expandRoute(profileEnv(options.profile, "agy"), options.route) };
  env.ANTIGRAVITY_GEMINI_DIR = geminiDir(options.profile.home);
  if (platform.hasKeychain) Object.assign(env, AGY_FILE_TOKENS);
  env.AGY_CLI_DISABLE_AUTO_UPDATE = "1";
  env.STILLFAIL_PEER_HTTP = peerHttpBase(options.mcpUrl);
  return env;
}

/// What session/new and session/load are given besides the working directory and the station's tools: its instructions,
/// after its own system prompt.
export const agyOpening = (instructions: string): Json => (instructions === "" ? {} : { _meta: { antigravity: { systemPrompt: { append: instructions } } } });

/// A call's update as the station reads it: an MCP tool's title is `Run mcp_<server>_<tool>` (1.4.12), the station's
/// named as the other runtimes name them (mcp__stillfail__chat_post), so that its live steps, history and lost tools
/// know it.
export function agyUpdate(update: Json): Json {
  if (update?.sessionUpdate !== "tool_call" || typeof update.title !== "string") return update;
  for (const server of TOOL_SERVERS) {
    const prefix = `Run mcp_${server}_`;
    if (update.title.startsWith(prefix)) return { ...update, title: `mcp__${server}__${update.title.slice(prefix.length)}` };
  }
  return update;
}

/// The thinking levels Antigravity's ACP models append to a family's name (`gemini-4-carbon-high`, `claude-opus-5-5-medium`).
export const AGY_LEVELS = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// A raw ACP `modelId` split into its base model and thinking level (`gemini-4-carbon-high` → `gemini-4-carbon` at `high`,
/// `gemini-3.5-flash` → `gemini-3.5-flash`).
export function agyBaseModel(id: string): { model: string; effort?: string } {
  const trimmed = id.trim();
  const effort = AGY_LEVELS.find((l) => trimmed.endsWith(`-${l}`) && trimmed.length > l.length + 1);
  return effort === undefined ? { model: trimmed } : { model: trimmed.slice(0, -effort.length - 1), effort };
}

export type AgyCatalog = { models: string[]; efforts: Record<string, string[]>; defaults: Record<string, string> };

/// The base models, their thinking levels (`[]` where at most one variant is offered, e.g. `gpt-oss-120b-medium`), and
/// any default level reported by `currentModelId`.
export function agyCatalog(availableModels: readonly string[], currentModelId?: string | null): AgyCatalog {
  const models: string[] = [];
  const levels = new Map<string, Set<string>>();
  for (const raw of availableModels) {
    const { model, effort } = agyBaseModel(raw);
    if (model === "") continue;
    if (!models.includes(model)) models.push(model);
    if (effort !== undefined) {
      let set = levels.get(model);
      if (!set) levels.set(model, (set = new Set()));
      set.add(effort);
    }
  }
  const efforts: Record<string, string[]> = {};
  const defaults: Record<string, string> = {};
  const cur = typeof currentModelId === "string" && currentModelId.trim() !== "" ? agyBaseModel(currentModelId) : null;
  for (const model of models) {
    const sorted = AGY_LEVELS.filter((l) => levels.get(model)?.has(l) === true);
    efforts[model] = sorted.length >= 2 ? sorted : [];
    if (sorted.length >= 2) {
      defaults[model] =
        cur !== null && cur.model === model && cur.effort !== undefined && sorted.includes(cur.effort)
          ? cur.effort
          : sorted.includes("high")
            ? "high"
            : sorted[sorted.length - 1]!;
    }
  }
  return { models, efforts, defaults };
}

/// The ACP `modelId` for `(model, effort)` among `availableModels`, or `null` when `availableModels` is non-empty and
/// offers neither `model` nor any level of it.
export function agyVariant(model: string, effort: string | undefined, availableModels: readonly string[], defaultModelId?: string | null): string | null {
  const { model: base, effort: inline } = agyBaseModel(model);
  const wanted = effort !== undefined && AGY_LEVELS.includes(effort) ? effort : inline;
  if (wanted === undefined && typeof defaultModelId === "string" && defaultModelId !== "" && agyBaseModel(defaultModelId).model === base) {
    if (availableModels.length === 0 || availableModels.includes(defaultModelId)) return defaultModelId;
  }
  if (availableModels.length === 0) {
    return wanted !== undefined && inline === undefined ? `${base}-${wanted}` : model;
  }
  if (wanted !== undefined && availableModels.includes(`${base}-${wanted}`)) return `${base}-${wanted}`;
  if (effort === undefined && availableModels.includes(model)) return model;
  if (availableModels.includes(base)) return base;
  const variants = availableModels.filter((m) => agyBaseModel(m).model === base);
  if (variants.length === 0) return null;
  return variants.find((m) => m === `${base}-high`) ?? variants.find((m) => m === `${base}-medium`) ?? variants[0]!;
}

/// The models session/new or session/load lists (ACP's `models`), the current first.
export function agyModels(result: Json): string[] {
  const valid = (v: unknown): v is string => typeof v === "string" && v.trim() !== "";
  const out = new Set<string>();
  if (valid(result?.models?.currentModelId)) out.add(result.models.currentModelId);
  for (const m of Array.isArray(result?.models?.availableModels) ? result.models.availableModels : []) if (valid(m?.modelId)) out.add(m.modelId);
  return [...out];
}

/// A turn's counts as the prompt's answer says them (ACP's `usage`), as the transcript keeps them: Cursor's names, input
/// apart from the cache's. None when it says none.
export function turnUsage(answer: Json): { inputTokens: number; cacheReadTokens: number; cacheWriteTokens: number; outputTokens: number } | null {
  const u = answer?.result?.usage;
  if (u === null || typeof u !== "object") return null;
  const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const read = n(u.cachedReadTokens);
  const written = n(u.cachedWriteTokens);
  return { inputTokens: Math.max(0, n(u.inputTokens) - read - written), cacheReadTokens: read, cacheWriteTokens: written, outputTokens: n(u.outputTokens) + n(u.thoughtTokens) };
}

export type AgyDriverOptions = {
  /// The station's data directory: runners live in <data>/run/runners.
  data: string;
  /// The CLI, by name on the agent's PATH or a path.
  command?: string;
  /// Another station's subscription, borrowed (share/index.ts): its sign-in file written with the access token the
  /// station signed in on it lent (`write`, when it runs out).
  lent?: { borrowed(profile: Profile): boolean; write(profile: Profile): Promise<number> };
};

/// A borrowed sign-in is asked of its host again as a process opens on it once it has less than this left. A running
/// `agy` never reads its sign-in's file again (1.5.9, measured 2026-11-15: a file renewed under it, its next call still
/// "oauth2: token expired and refresh token is not set"), so one that runs out under a process fails its turn as a
/// sign-in's failure (`classifyFailure`), which the session's actor answers by ending the process and going on once in a
/// new one (actor_run.mbt `auth_retry`), opened here on a sign-in lent anew. Google's access tokens last an hour; `agy`
/// refuses to start on one with under 5 minutes.
export const AGY_LENT_RENEW_MS = 40 * 60_000;
/// What `agy` needs left of a sign-in to start on it (it asks to sign in under 5 minutes, 1.5.9), with a margin.
const AGY_LENT_LEAST_MS = 10 * 60_000;

export class AgyDriver extends AcpDriver<AgySession> {
  private readonly command: string;
  private readonly lent: AgyDriverOptions["lent"];

  constructor(options: AgyDriverOptions) {
    super(options.data);
    this.command = options.command ?? "agy";
    this.lent = options.lent;
  }

  /// A borrowed sign-in with little left (AGY_LENT_RENEW_MS) lent again before a process opens on it. Where none is lent,
  /// one that still lasts long enough for `agy` to start on is gone on with (said), else the failure is the opening's.
  private async renewLent(profile: Profile): Promise<void> {
    const until = await agyExpiry(profile.home);
    if (until - wall.now() >= AGY_LENT_RENEW_MS) return;
    try {
      await this.lent!.write(profile);
    } catch (error) {
      if (until - wall.now() < AGY_LENT_LEAST_MS) throw error;
      log.warn("agents::agy", "its borrowed sign-in runs out soon and no new one was lent; it goes on with the one it has", { profile: profile.id, error: (error as Error).message });
    }
  }

  runtime(): "agy" {
    return "agy";
  }

  /// The models a profile's CLI offers, normalized into base models and their thinking levels: a session opened only to ask.
  async catalog(profile: Profile): Promise<AgyCatalog> {
    const session = await this.begin({ key: `models-${profile.id}-${uuid()}`, profile, cwd: agyHome(profile.home), instructions: "", mcpToken: "", mcpUrl: "", route: "model-discovery" }, () => {}, true);
    try {
      return agyCatalog(session.availableModels, session.currentModelId);
    } finally {
      await session.dispose();
    }
  }

  /// The models a profile's CLI offers: a session opened only to ask.
  async models(profile: Profile): Promise<string[]> {
    return (await this.catalog(profile)).models;
  }

  protected session(options: OpenOptions, events: Events) {
    return new AgySession(this, events, options);
  }

  protected async begin(options: OpenOptions, events: Events, probe: boolean): Promise<AgySession> {
    if (this.lent?.borrowed(options.profile)) await this.renewLent(options.profile);
    else if (accessKind(options.profile) === "subscription") await agyTakeBack(options.profile.home);
    return super.begin(options, events, probe);
  }

  protected starting(options: OpenOptions): AcpStart {
    if (options.resume !== undefined && !SESSION_ID.test(options.resume)) throw new Error("invalid Antigravity conversation id");
    const sessions = join(agyHome(options.profile.home), SESSIONS);
    mkdirSync(sessions, { recursive: true });
    mkdirSync(geminiDir(options.profile.home), { recursive: true });
    // Not one the station kept.
    if (options.resume !== undefined && !existsSync(join(sessions, `${options.resume}.jsonl`))) throw new Error(`no Antigravity conversation ${options.resume}`);
    return { command: this.command, args: agyArgs(options.profile.home), env: agyEnv(options), opening: agyOpening(options.instructions) };
  }

  protected async ready(session: AgySession, options: OpenOptions, probe: boolean) {
    const model = probe ? undefined : (options.model ?? profileModel(options.profile));
    if (model === undefined) return;
    const target = agyVariant(model, options.effort, session.availableModels, session.defaultModelId) ?? model;
    if (target !== session.currentModelId) await session.request(`model:${uuid()}`, "session/set_model", { sessionId: session.id(), modelId: target });
    session.currentModelId = target;
    session.model = agyBaseModel(model).model;
  }
}

export class AgySession extends AcpSession {
  protected readonly steersByPrompt = true;
  /// What session/new or session/load said it offers.
  availableModels: string[] = [];
  /// The raw ACP `modelId` currently active in the process.
  currentModelId: string | null = null;
  /// The raw ACP `modelId` the process opened on before any `session/set_model`.
  defaultModelId: string | null = null;
  /// The context its last call had and the model's window, as usage_update says them.
  private context = { used: 0, size: 0 };

  constructor(driver: AgyDriver, events: Events, options: OpenOptions) {
    super(driver, events, new KeptTranscript("agy", join(agyHome(options.profile.home), SESSIONS)));
  }

  protected classify(text: string) {
    return classifyFailure(text);
  }

  protected failedSaying(said: string) {
    return noticeFailure(said);
  }

  named(id: string) {
    if (!SESSION_ID.test(id)) throw new Error("invalid Antigravity conversation id");
    super.named(id);
  }

  protected normalized(update: Json) {
    return agyUpdate(update);
  }

  opened(result: Json) {
    super.opened(result);
    this.availableModels = agyModels(result);
    const current = result?.models?.currentModelId;
    if (typeof current === "string" && current !== "") {
      this.currentModelId = current;
      this.defaultModelId = current;
      this.model = agyBaseModel(current).model;
    }
  }

  protected kept() {
    return { availableModels: this.availableModels, currentModelId: this.currentModelId, defaultModelId: this.defaultModelId, context: this.context };
  }

  protected taken(snapshot: Json) {
    this.availableModels = Array.isArray(snapshot.availableModels) ? snapshot.availableModels.filter((m: unknown): m is string => typeof m === "string") : [];
    this.currentModelId = typeof snapshot.currentModelId === "string" ? snapshot.currentModelId : this.model;
    this.defaultModelId = typeof snapshot.defaultModelId === "string" ? snapshot.defaultModelId : null;
    const c = snapshot.context;
    if (c && typeof c === "object") this.context = { used: typeof c.used === "number" ? c.used : 0, size: typeof c.size === "number" ? c.size : 0 };
  }

  protected updated(update: Json) {
    if (update?.sessionUpdate !== "usage_update") return;
    const n = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);
    if (n(update.used) > 0) this.context.used = n(update.used);
    if (n(update.size) > 0) this.context.size = n(update.size);
  }

  /// The turn's usage, into the transcript before its end.
  protected ending(id: string, answer: Json) {
    const usage = turnUsage(answer);
    if (usage !== null) this.transcript?.keep(this.sessionId, { type: "usage", run: id.slice(id.indexOf(":") + 1), model: this.model, usage, calls: 1, context: this.context.used, window: this.context.size });
  }

  protected ignored(id: string, answer: Json) {
    this.ending(id, answer);
  }

  /// Into the running turn: Antigravity CLI immediately resolves the superseded prompt and finishes on the new one.
  async steer(text: string) {
    return this.promptTakeover(text);
  }

  /// Between turns, another model or thinking level is set in the running process, read from its next turn on.
  retune(options: OpenOptions) {
    if (this.turn.closed || this.turn.busy || this.sessionId === "") return false;
    const model = options.model ?? profileModel(options.profile);
    if (model === undefined) return false;
    const target = agyVariant(model, options.effort, this.availableModels, this.defaultModelId);
    if (target === null) return false;
    if (target !== this.currentModelId) this.send("session/set_model", { sessionId: this.sessionId, modelId: target });
    this.currentModelId = target;
    this.model = agyBaseModel(model).model;
    return true;
  }
}
