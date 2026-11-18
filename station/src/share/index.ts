// What this station shares with the other stations of its workspaces, and what it uses of theirs
//. It is between the stations only (the station transport, `share.*`, jobs/remote.ts hands
// them here); still.fail cloud says nothing of it beyond which stations are in each workspace.
//
// - Which stations a share is for: a profile, those of every workspace this station is in
//   that it serves (all but those it is withheld from); a skill, those of the home workspace, whose agents' skills it
//   is. Its `allow` narrows that. A copy of a profile serves only the workspaces its host shares it in (it says which,
//   `share.workspaces`); a copy of a skill is linked into the skills of the workspace it was had in.
//
// - The station that has a profile or a skill (its host) keeps who may use it (`allow`, null: every station) and who
//   has a copy or borrows it (state.json `hosted[id].told`: each station and the version it was told of). It tells
//   each station that may use it, directly, when it is shared, changed, moved or no longer shared (share.changed), the
//   ones that did not answer again later.
// - A station that uses one keeps which station it has it from (`share.host` on its profile, state.json
//   `borrowed[id].host`) and asks that station once a run what it is at (share.version), for what changed while it was
//   away.
// - A key profile and a skill: each station that may use it keeps a copy (config.json, <data>/share/<id>/); the host
//   being offline changes nothing for them.
// - A subscription: only its host keeps the login and renews it (a refresh token is spent when used, so two renewing
//   would sign each other out). The others borrow a short-lived access token for each process they start; with the host
//   offline they cannot.
// - Edits to a skill made where it is copied go to its host, which keeps one order of them; one made on an older copy
//   is kept beside the skill as SKILL.conflict-<station>.md.
// - A profile moves to another whole station of a workspace it serves only from the station that has it (never a copy,
//   never the machine's own login), while both are up (`moveProfile`; the owner, 2026-11-14: 「账号在 station 之间转移也做
//   一下」): its login files (`signInFiles`, those its runtime signs in with, nothing else of its home) are handed over,
//   and this station lets go of them only once the other says it has it, so one station alone ever holds a login. One
//   shared stops lending, keeps a copy borrowed from the new host (where its `allow` lets it) and tells the stations it
//   had told where it went; one not shared is the other's own then, gone from here (its sessions go on on another
//   profile, as one deleted). It keeps its id there where that is free (a session moved with a retired station takes its conversation up on it), and
//   serves there only the workspaces it served here (`withheldFor`; not moved to a station whose home it did not serve).
//   A migration (move/accounts.ts) moves one not shared whose login can be (`shareRefusal`) as a shared one, shared
//   first with the two stations alone (`shareFirst`), so the station it leaves borrows it and nothing there stops; back
//   home, that share is undone where nobody opened it to another station meanwhile (`unshareMoved`).
//
// Config: a shared profile has `share: {id, allow}` on its host and `share: {id, borrowed: true, host}` where copied
// (`paused`: this station does not use the copy, `hostOff`: its host disabled it; accounts/index.ts putProfile);
// (made and removed only here). Shared skills are config.json `sharedSkills: {name: {id, allow}}`.
import { createHash, randomBytes } from "node:crypto";
import { readFileSync, watch } from "node:fs";
import { lstat, mkdir, readdir, readFile, readlink, rm, stat, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { Clock } from "effect";
import type { Env, MachineToken } from "../agents/machine-logins.ts";
import { codexAuthFile } from "../agents/machine-logins.ts";
import { CONSOLE_FILE } from "../accounts/console.ts";
import { authFile as cursorAuthFile } from "../accounts/cursor.ts";
import { KIMI_FILE, KIMI_TOKEN_FILE } from "../accounts/kimi.ts";
import { devinAccountFile, grokAuthFile } from "../accounts/profiles.ts";
import { accountEmailSoon } from "../accounts/index.ts";
import { agyAccountFile, agyExpiryIn, agyLentFile, agyToken } from "../agents/agy.ts";
import { LEND_BOUND_MS } from "../accounts/oauth.ts";
import { devinData } from "../agents/devin.ts";
import { kimiSignedIn, machineProxy } from "../agents/profiles.ts";
import type { Cloud } from "../cloud/state.ts";
import { Refused } from "../mesh/bus.ts";
import type { ConfigFile } from "../ops/config.ts";
import { Fibers } from "../ops/fibers.ts";
import { PrivateFile, writePrivateSoon } from "../ops/files.ts";
import { FollowedTree } from "../ops/follow.ts";
import { log } from "../ops/log.ts";
import { link } from "../ops/links.ts";
import { joinPath, portableName } from "../ops/paths.ts";
import { profileFetch } from "../ops/agent-env.ts";
import { workspaceAgentHomePath } from "../sessions/agent-home.ts";
import { SKIPPED } from "./memory.ts";
import { MemoryProgram, MemoryProgramStopped } from "./memory-mb.ts";
import { allowedIn } from "../sessions/config.ts";
import { type Lang, Said, stationLang, tr } from "../ops/i18n.ts";

type Json = any;

/// What a skill may hold to be shared (sent whole in one request of the station transport, which takes 1 MB).
const MAX_SKILL_BYTES = 512 * 1024;
const MAX_SKILL_FILES = 200;
/// A host lends a Codex token it has for at least this long; one closer to its end is renewed first (when it can be).
const CODEX_LEND_MS = 24 * 3600_000;
const CODEX_MIN_MS = 3600_000;
/// A host lends an Antigravity CLI sign-in it has for at least this long (Google's access tokens last an hour), one
/// closer to its end renewed first; one with less than AGY_MIN_MS waits for its renewal. A borrower asks again as a
/// process opens with 40 minutes left (agents/agy.ts AGY_LENT_RENEW_MS), so what is lent lasts longer than that.
const AGY_LEND_MS = 50 * 60_000;
const AGY_MIN_MS = 42 * 60_000;
/// A login lent before is used again while its host does not answer, if it still has this long.
const KEEP_LENT_MS = 3600_000;
/// A borrower goes on with the Antigravity CLI sign-in lent before while its host is away, if it lasts this long still
/// (`agy` refuses one with under 5 minutes; a turn begun on it has the rest).
const KEEP_AGY_MS = 10 * 60_000;
/// How long a login wanted waits for the cloud to say the workspace's stations.
const ROSTER_WAIT_MS = 10_000;
/// Edits to a skill are taken once they have settled this long.
const SETTLE_MS = 2000;
/// The most directories of a skill shared from here watched.
const SKILL_DIRS_MOST = 200;
/// What could not be done because another station did not answer is tried again after this, then twice as long each
/// time up to RETRY_MAX_MS (only while there is).
const RETRY_MS = 60_000;
const RETRY_MAX_MS = 30 * 60_000;
const CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const CODEX_TOKEN_URL = "https://auth.openai.com/oauth/token";

export type ShareRole = "host" | "user";
/// What the overview says of a shared profile or skill: for its host also the stations that have it (`users`); for a
/// copy of a profile, that this station pauses it (`pausable`: accounts/index.ts putProfile; absent on a station from
/// before, which refuses it).
export type ShareView = { id: string; role: ShareRole; host: string; allow: string[] | null; reachable: boolean | null; users?: string[]; pausable?: true };
export type ShareKind = "profile" | "skill";

export type SharingDeps = {
  data: string;
  config: ConfigFile;
  /// Which stations are in each of the station's workspaces (cloud.json's rosters), and this one's id.
  cloud: Cloud;
  /// A request to another station of one of the station's workspaces (the station transport), made in `workspace` (null:
  /// the first of the station's, its home one first, that the other is in too).
  ask: (station: string, workspace: string | null, request: Json) => Promise<Json>;
  /// The agents' home (its skills/ directory is where shared skills are linked; a joined workspace's is in it).
  agentHome: () => string;
  /// The station's environment (the machine's own logins are found in it).
  env: Env;
  /// The account of a profile on the machine's login, as read by Accounts.
  machineEmail?: (runtime: string) => string | null;
  /// A Claude profile's current access token, renewed when about to run out (the accounts module's).
  /// `rejected`: the token a borrower was refused with, renewed first if it is still the current one.
  claudeToken: (profile: Json, rejected?: string) => Promise<MachineToken>;
  /// Has the Codex app-server running on a profile here renew its login (it holds the refresh token, which must not be
  /// renewed under it); false: none runs on it.
  codexRenewRunning: (profileId: string) => Promise<boolean>;
  /// Has `agy` renew an Antigravity CLI profile's sign-in here (agents/agy.ts `agyRenew`: it holds the OAuth client).
  agyRenew?: (home: string) => Promise<void>;
  /// A profile's check and allowance as this station has them, its allowance asked again when old (for the stations
  /// borrowing it).
  status: (profileId: string) => Promise<{ check: Json; quota: Json }>;
  /// Something the overview shows changed.
  changed: () => void;
  /// A host that had not answered answers again: what is borrowed from it is checked again.
  recheck?: () => void;
  /// A copied profile changed on its host; refresh its login and, for a reset, its allowance.
  profileChanged?: (id: string, reset: boolean) => Promise<void>;
  /// A borrower redeemed a reset: read the host's allowance and wake its waiting sessions.
  quotaReset?: (id: string) => Promise<void>;
  /// A profile of this station's moved to another and gone from here: its sessions go on on another (hub `profileGone`).
  profileGone?: (id: string) => Promise<void>;
  /// Whether a request naming `station` comes back to this station (mesh/bus.ts `cameHere`: a station retired into this
  /// one, `formerly`): it is neither told nor asked anything, as this station would answer itself.
  itself?: (station: string) => boolean;
  clock?: Clock.Clock;
  /// Tests: Codex's token endpoint.
  codexTokenUrl?: string;
  /// Tests: the MoonBit program that reads and writes the skills' files (readerBinary's where none is given).
  binary?: string;
};

/// `dir`: of a skill, its directory's device and inode (`dev:ino`), by which it is found again once renamed.
/// `missing`: the stations that may use it but do not, and why (Missing). `unread`: why what it is cannot be read now
/// (too-large: past what may be shared; unreadable), so its stations keep the last of it.
type Hosted = { version: number; hash: string; kind: ShareKind; name: string; allow: string[] | null; told: Record<string, number>; dir?: string; missing?: Record<string, Missing>; unread?: string; quotaRevision?: number; resetKeys?: string[] };
/// Why a station that may use a share does not: it refused the share's name (name), it has a skill of its own by that
/// name, which wins (same-name), it refused for another reason (refused).
export type Missing = "name" | "same-name" | "refused";
/// `workspace`: of a skill, the workspace it was had in, whose agents' skills it is linked into (absent: the home one's,
/// as files of before have it).
type Borrowed = { version: number; hash: string; kind: ShareKind; name: string; host: string; allow: string[] | null; workspace?: string; pending?: boolean; stale?: boolean; quotaRevision?: number; resetPending?: string[]; profileUpdate?: { reset: boolean } };
/// A share of this station's: what it is, who may use it, its content's hash (null: unreadable now, `unread` why).
type Own = { kind: ShareKind; name: string; allow: string[] | null; hash: string | null; profile?: Json; skill?: string; unread?: string };
/// A share of this station's as configured, nothing of it read.
type Shared = Omit<Own, "hash" | "unread">;
type State = {
  /// What this station shares: its version (raised when what it is changes) and each station told of it, at which
  /// version (-1: told it is no longer for it).
  hosted: Record<string, Hosted>;
  /// What it uses of others': from which station, at which version.
  borrowed: Record<string, Borrowed>;
  /// Shares it handed to another station, and the stations still to be told where they went.
  moved: Record<string, { to: string; tell: string[] }>;
  /// Profiles not shared that other stations handed over to this one (`<station>/<their id>` → its id here): one asked
  /// again (its answer lost) is the one taken already.
  taken?: Record<string, string>;
};

/// Whose word a failed request is: the other station's (it answered with a refusal), or this one's (it could not ask, or
/// no answer came).
const whoSaid = (e: unknown) => (e instanceof Refused ? "them" : "here");
const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
const hashOf = (v: unknown) => createHash("sha256").update(typeof v === "string" ? v : JSON.stringify(v)).digest("hex");
const newId = () => `sh-${randomBytes(10).toString("hex")}`;
/// The files a profile's login is in, under its home, by its runtime and how it signs in: what is handed over with it as
/// it moves to another station. Login and identity files alone, never the home's caches, sessions or transcripts. A key
/// profile has none (its key is in the profile).
export function signInFiles(p: Json): string[] {
  const kind = isObject(p?.access) ? p.access.kind : undefined;
  const out: string[] = [];
  if (kind === "subscription") {
    const r = String(p.runtime ?? "claude");
    if (r === "claude") out.push(".credentials.json", ".claude.json");
    else if (r === "codex") out.push("auth.json");
    else if (r === "grok") out.push(grokAuthFile(""));
    else if (r === "cursor") out.push(cursorAuthFile(""));
    else if (r === "devin") out.push(join(devinData(""), "devin", "credentials.toml"), devinAccountFile(""));
    else if (r === "agy") out.push(agyToken(""), agyAccountFile(""));
  }
  // (an OpenCode Go profile signed in to the OpenCode Console, a Kimi Code one to Kimi: accounts/console.ts, kimi.ts)
  if (kind === "opencode-go" && p.access.login === true) out.push(CONSOLE_FILE);
  if (kimiSignedIn(p)) out.push(KIMI_FILE, KIMI_TOKEN_FILE);
  return out;
}
const keyed = (kind: unknown) => kind === "opencode-go" || kind === "anthropic-api" || kind === "api-provider";

/// A profile as another station gets it: what it is, its key when it has one, never where its files are or a login.
export function portable(p: Json): Json {
  const out: Json = {};
  for (const k of ["name", "runtime", "access", "env", "model", "models", "backgroundOnMessage", "fast", "enabled"]) if (p[k] !== undefined) out[k] = structuredClone(p[k]);
  if (isObject(out.access) && !keyed(out.access.kind)) delete out.access.key;
  // A proxy is this machine's, not the profile's: the other station has its own way out, or none.
  if (isObject(out.env)) for (const k of Object.keys(out.env)) if (machineProxy(k)) delete out.env[k];
  return out;
}

class TooLarge extends Error {}
const TOO_LARGE = "the skill is too large to share (512 KB, 200 files at most)";

/// Keeps why a station that may use a share does not (null: it does, or may not).
function miss(hosted: Hosted, peer: string, why: Missing | null) {
  if (why !== null) (hosted.missing ??= {})[peer] = why;
  else if (hosted.missing) {
    delete hosted.missing[peer];
    if (Object.keys(hosted.missing).length === 0) delete hosted.missing;
  }
}

/// What is at `path` itself (a link not followed): a link and where it leads, something else, or nothing.
async function entryAt(path: string): Promise<{ link: string } | "other" | null> {
  try {
    if (!(await lstat(path)).isSymbolicLink()) return "other";
    return { link: await readlink(path) };
  } catch {
    return null;
  }
}

/// A directory's device and inode (`dev:ino`), which a rename keeps; null: no directory of its own there. (Node's,
/// in bigints: the shell's lstat says no inode on Windows, and past 2^53 one would not be itself in JSON.)
async function dirKey(dir: string): Promise<string | null> {
  try {
    const meta = await lstat(dir, { bigint: true });
    return meta.isDirectory() ? `${meta.dev}:${meta.ino}` : null;
  } catch {
    return null;
  }
}

/// What the memory's program says of a skill's files (mb/src/memory skills.mbt `skill_read`; what it replaced is
/// test/reference/share-skills.ts `readSkill`, `skillHash`): its hash and whether it has its SKILL.md, with `bytes` its
/// files too (path → base64), as another station is sent them.
type SkillRead = { hash: string; hasSkillMd: boolean; files?: Record<string, string> };

/// When a JWT runs out (ms), if it says.
function jwtExpiry(token: unknown): number | null {
  if (typeof token !== "string") return null;
  try {
    const claims = JSON.parse(Buffer.from(token.split(".")[1] ?? "", "base64url").toString("utf8"));
    return typeof claims?.exp === "number" ? claims.exp * 1000 : null;
  } catch {
    return null;
  }
}

/// When the Codex login lent before, kept in a borrowed profile's home, runs out (0 when there is none).
async function keptCodexExpiry(file: string): Promise<number> {
  try {
    return jwtExpiry(JSON.parse(await readFile(file, "utf8"))?.tokens?.access_token) ?? 0;
  } catch {
    return 0;
  }
}

/// Why profile `p`'s login cannot be shared with other stations (null: it can): what `shareProfile` refuses turning a
/// share on, and what a move asks before sharing a login as it moves it (move/accounts.ts), so the two never differ. A
/// copy of another station's is not this station's to share.
export function shareRefusal(p: Json): string | null {
  if (isObject(p?.share) && p.share.borrowed === true) return "this profile is another station's";
  // Grok Build's sign-in is not lent yet (only Claude Code's, Codex's and the Antigravity CLI's are: lendClaude,
  // lendCodex, lendAgy).
  if (p?.access?.kind === "subscription" && p.runtime === "grok") return "a SuperGrok subscription cannot be shared with other stations yet";
  // Nor Cursor's (its key stays where it was minted).
  if (p?.access?.kind === "subscription" && p.runtime === "cursor") return "a Cursor account cannot be shared with other stations yet";
  // Nor Devin's.
  if (p?.access?.kind === "subscription" && p.runtime === "devin") return "a Devin account cannot be shared with other stations yet";
  // Nor a Kimi sign-in (its token is renewed every few minutes here, accounts/kimi.ts).
  if (p?.access?.provider === "kimi-code" && p?.access?.login === true) return "a Kimi Code sign-in cannot be shared with other stations yet";
  return null;
}

export class Sharing {
  private deps: SharingDeps;
  private time: Fibers;
  private watchers = new Map<string, { close(): void }>();
  private loginDirs = new Map<string, string>();
  private settle = new Map<string, () => void>();
  private retry: (() => void) | null = null;
  private retryMs = RETRY_MS;
  private stops: (() => void)[] = [];
  /// Hosts that did not answer lately, and when (for the overview's `reachable`).
  private unreachable = new Map<string, number>();
  /// Shares this station is handing to another right now: not lent meanwhile.
  private moving = new Set<string>();
  /// Shares made to move a profile (moveProfile `shareFirst`), while it moves: no station is told of them here (the one
  /// it goes to tells them, as their host), so none takes a copy of what goes to that station in a moment.
  private unannounced = new Set<string>();
  private moveDone = new Map<string, Promise<void>>();
  /// The Claude token each borrowed profile was last lent (Codex keeps its own in its home's auth.json).
  private lentClaude = new Map<string, MachineToken>();
  private reconciling: Promise<void> | null = null;
  private again = false;
  /// Copies asked about in this run (what changed while this station was away is found that way).
  private checked = new Set<string>();
  /// The skills' files read, hashed and written off the station's thread (mb/src/memory skills.mbt), let go idle.
  private program: MemoryProgram;
  /// What reads the skills shared from here and changes `state.hosted` by it (`syncHosted`, `takeEdit`, a skill
  /// sent): one at a time, so that what one read is not written over by another that read before it.
  private hostedTurn: Promise<unknown> = Promise.resolve();

  constructor(deps: SharingDeps) {
    this.deps = deps;
    this.time = new Fibers("share", deps.clock);
    this.program = new MemoryProgram(this.root, deps.binary === undefined ? {} : { binary: deps.binary });
    this.readState();
  }

  /// The skills' program let go at once if nothing is asked of it: 1, else 0 (the station short of memory).
  trimIdle(): number {
    return this.program.trimIdle();
  }

  private serially<T>(f: () => Promise<T>): Promise<T> {
    const run = this.hostedTurn.then(f, f);
    this.hostedTurn = run.catch(() => {});
    return run;
  }

  /// A skill's files as the program reads them (SkillRead); TooLarge past what may be shared.
  private async readSkill(dir: string, bytes = false): Promise<SkillRead> {
    const r = await this.program.ask("skillRead", { dir, maxBytes: MAX_SKILL_BYTES, maxFiles: MAX_SKILL_FILES, bytes });
    if (r.tooLarge === true) throw new TooLarge(TOO_LARGE);
    return { hash: String(r.hash), hasSkillMd: r.hasSkillMd === true, ...(bytes ? { files: r.files } : {}) };
  }

  private get root() {
    return join(this.deps.data, "share");
  }

  private me(): string | null {
    return this.deps.cloud.state?.station ?? null;
  }

  /// The other stations of the station's workspaces, as the cloud said last (each workspace's as its lock lets it), each
  /// with the workspaces it is in too, the home one first (null: not known now).
  private rosters(): Map<string, string[]> | null {
    const cloud = this.deps.cloud;
    if (!cloud.peersCurrent || cloud.state === null) return null;
    const me = this.me();
    const out = new Map<string, string[]>();
    for (const m of cloud.memberships()) {
      for (const p of m.peers) if (typeof p?.id === "string" && p.id !== me) out.set(p.id, [...(out.get(p.id) ?? []), m.workspace]);
    }
    return out;
  }

  /// Whether a share is for the stations of workspace `ws`: a profile for those of each workspace it serves, a skill for
  /// the home one's.
  private servesIn(share: { kind: ShareKind; profile?: Json }, ws: string): boolean {
    const home = this.deps.cloud.home();
    return share.kind === "profile" ? allowedIn(share.profile, ws, home) : ws === home;
  }

  /// The workspaces of this station's a profile is shared in (what its copies may serve, sessions/config.ts `allowedIn`).
  private sharedIn(profile: Json): string[] {
    return this.deps.cloud.memberships().flatMap((m) => (this.servesIn({ kind: "profile", profile }, m.workspace) ? [m.workspace] : []));
  }

  /// What a shared profile is, hashed: where it is shared too (its copies serve those workspaces only).
  private async profileHash(p: Json): Promise<string> {
    let login: string | null = null;
    if (p.runtime === "codex" && p.access?.kind === "subscription") {
      try { login = hashOf(await readFile(this.codexFile(p), "utf8")); } catch {}
    }
    // A machine login is read outside the profile's home. Include its account so existing copies receive it after an
    // upgrade and again after a different account is signed in.
    const email = p.machine === true && p.access?.kind === "subscription" ? { email: await this.emailOf(p) } : {};
    return hashOf({ ...portable(p), workspaces: this.sharedIn(p), ...email, ...(login === null ? {} : { login }) });
  }

  private codexFile(p: Json): string {
    return p.machine === true ? codexAuthFile(this.deps.env) : join(this.home(p), "auth.json");
  }

  /// The workspace a share reaches `station` in (`rosters`: as they are now): the first both are in that it is for;
  /// null when there is none.
  private reach(share: { kind: ShareKind; profile?: Json }, station: string, rosters = this.rosters()): string | null {
    return rosters?.get(station)?.find((ws) => this.servesIn(share, ws)) ?? null;
  }

  /// Where a copy's host is asked: a skill's in the workspace it was had in; a profile's in any both are in.
  private askIn(had: Borrowed): string | null {
    return had.kind === "skill" ? (had.workspace ?? this.deps.cloud.home()) : null;
  }

  /// Whether a copy's host is still one this station has it from: in the workspace a skill was had in, in any of this
  /// station's for a profile.
  private hostThere(had: Borrowed, rosters: Map<string, string[]>): boolean {
    const where = this.askIn(had);
    const of = rosters.get(had.host);
    return of !== undefined && (where === null || of.includes(where));
  }

  private mayUse(allow: string[] | null, station: string): boolean {
    return allow === null || allow.includes(station);
  }

  // ── state ──

  /// The one copy of state.json in memory (read as the station starts, `constructor`): every change is made to it and
  /// written through, so a request answered while the shares are brought in line changes the same one.
  private state: State | null = null;
  private stateFile: PrivateFile | null = null;

  private readState(): State {
    if (this.state) return this.state;
    try {
      const s = JSON.parse(readFileSync(join(this.root, "state.json"), "utf8")); // sync: read once, before the station serves
      this.state = { hosted: isObject(s.hosted) ? s.hosted : {}, borrowed: isObject(s.borrowed) ? s.borrowed : {}, moved: isObject(s.moved) ? s.moved : {}, taken: isObject(s.taken) ? s.taken : {} };
    } catch {
      this.state = { hosted: {}, borrowed: {}, moved: {} };
    }
    return this.state;
  }

  /// Written through off the station's thread, the latest only: a reader reading it from the disk (read/memory.ts) may
  /// find the one before for as long as the write takes.
  /// Once the state asked to be written is (what a reader of its file then finds).
  stateWritten(): Promise<void> {
    return this.stateFile?.written() ?? Promise.resolve();
  }

  private writeState(_s: State = this.readState()): void {
    this.stateFile ??= new PrivateFile(join(this.root, "state.json"));
    void this.stateFile.write(JSON.stringify(this.readState(), null, 2))
      .catch((error) => log.warn("share", "the shares' state not written", { error: (error as Error).message }));
  }

  private profiles(): Json[] {
    const raw = this.deps.config.raw();
    return Array.isArray(raw?.profiles) ? raw.profiles : [];
  }

  private home(p: Json): string {
    const home = String(p.home ?? `homes/${p.id}`);
    // Relative to the data directory unless rooted (as each machine roots paths: C:\… on Windows).
    return joinPath(this.deps.data, home);
  }

  /// The agents' skills of workspace `ws` (null: the home one's, where this station's own shared skills are): a joined
  /// one's made with its agent home (sessions/agent-home.ts `workspaceAgentHome`), or where a skill is linked into it.
  private skillsDir(ws: string | null = null): string {
    return join(workspaceAgentHomePath(this.deps.agentHome(), ws, this.deps.cloud.home()), "skills");
  }

  /// The skills this station shares: name → id and who may use it (an id alone: every station).
  private sharedSkills(): Record<string, { id: string; allow: string[] | null }> {
    const s = this.deps.config.raw()?.sharedSkills;
    if (!isObject(s)) return {};
    const out: Record<string, { id: string; allow: string[] | null }> = {};
    for (const [name, v] of Object.entries(s)) {
      if (typeof v === "string") out[name] = { id: v, allow: null };
      else if (isObject(v) && typeof v.id === "string") out[name] = { id: v.id, allow: Array.isArray(v.allow) ? v.allow : null };
    }
    return out;
  }

  /// Shared skills whose directory is gone: shared under the name it was renamed to (the same directory), or no longer
  /// once it is deleted. Not while there are no skills to look in (an agents' home moved).
  private async followSkills(state: State) {
    const skills = this.skillsDir();
    let names: string[];
    try {
      names = await readdir(skills);
    } catch {
      return;
    }
    const shared = this.sharedSkills();
    const gone: [string, { id: string; allow: string[] | null }][] = [];
    for (const entry of Object.entries(shared)) {
      try {
        await stat(join(skills, entry[0]));
      } catch {
        gone.push(entry);
      }
    }
    if (gone.length === 0) return;
    const free = new Map<string, string>();
    for (const name of names) {
      const key = name in shared ? null : await dirKey(join(skills, name));
      if (key !== null) free.set(key, name);
    }
    await this.deps.config.updateSoon((raw) => {
      const to: Json = isObject(raw.sharedSkills) ? raw.sharedSkills : {};
      for (const [name, { id }] of gone) {
        const key = state.hosted[id]?.dir;
        const now = key === undefined ? undefined : free.get(key);
        if (now !== undefined && portableName(now)) {
          to[now] = to[name];
          log.info("share", "a shared skill renamed is shared under its new name", { id, from: name, to: now });
        } else log.info("share", "a shared skill deleted is no longer shared", { id, name });
        delete to[name];
        this.stopWatch(`hosted:${name}`);
      }
      raw.sharedSkills = to;
    });
  }

  /// What this station shares now, by id: what it is and who may use it, as configured (nothing of it read).
  private shares(): Map<string, Shared> {
    const out = new Map<string, Shared>();
    for (const p of this.profiles()) {
      if (!isObject(p.share) || p.share.borrowed === true || typeof p.share.id !== "string") continue;
      out.set(p.share.id, { kind: "profile", name: String(p.name ?? p.id), allow: Array.isArray(p.share.allow) ? p.share.allow : null, profile: p });
    }
    for (const [name, { id, allow }] of Object.entries(this.sharedSkills())) out.set(id, { kind: "skill", name, allow, skill: name });
    return out;
  }

  /// What this station shares now, by id, with its content's hash (null: unreadable now), a skill's read by the program.
  private async ownShares(): Promise<Map<string, Own>> {
    const out = new Map<string, Own>();
    for (const [id, share] of this.shares()) {
      if (share.kind === "profile") {
        out.set(id, { ...share, hash: await this.profileHash(share.profile) });
        continue;
      }
      let hash: string | null = null;
      let unread: string | undefined;
      try {
        hash = (await this.readSkill(join(this.skillsDir(), share.skill!))).hash;
      } catch (e) {
        // (the station stopping: nothing is said of the skill)
        if (e instanceof MemoryProgramStopped) throw e;
        unread = e instanceof TooLarge ? "too-large" : "unreadable";
        log.warn("share", "a shared skill could not be read", { name: share.skill, error: (e as Error).message });
      }
      out.set(id, { ...share, hash, unread });
    }
    return out;
  }

  /// Updates `state.hosted` and file watchers for what this station currently shares, writing `state.json` through
  /// when anything changed so callers (`shareProfile`, `shareSkill`, `lendTo`) and `deps.changed()` see the new version
  /// once it is done, without waiting on slow or unanswered peers. One at a time with what else changes it (`serially`).
  private syncHosted(state: State = this.readState()): Promise<Map<string, Own>> {
    return this.serially(() => this.syncHostedNow(state));
  }

  private async syncHostedNow(state: State): Promise<Map<string, Own>> {
    const own = await this.ownShares();
    let dirty = false;
    for (const id of this.loginDirs.keys()) if (!own.has(id)) {
      this.stopWatch(`login:${id}`);
      this.loginDirs.delete(id);
    }
    // (a skill no longer shared: its watch, made again by a pass that read it before it stopped, stops)
    const skills = new Set([...own.values()].flatMap((now) => (now.kind === "skill" ? [`hosted:${now.skill}`] : [])));
    for (const key of [...this.watchers.keys()]) if (key.startsWith("hosted:") && !skills.has(key)) this.stopWatch(key);
    for (const [id, now] of own) {
      if (this.unannounced.has(id)) continue;
      if (now.kind === "skill") await this.watchHosted(now.skill!, join(this.skillsDir(), now.skill!));
      if (now.kind === "profile" && now.profile?.runtime === "codex" && now.profile?.access?.kind === "subscription") this.watchLogin(id, this.codexFile(now.profile));
      else if (this.loginDirs.has(id)) { this.stopWatch(`login:${id}`); this.loginDirs.delete(id); }
      const was = state.hosted[id];
      const hosted: Hosted = was ?? { version: 0, hash: "", kind: now.kind, name: now.name, allow: now.allow, told: {} };
      if (!was) dirty = true;
      if (now.hash === null) {
        if (hosted.unread !== now.unread) {
          hosted.unread = now.unread;
          dirty = true;
        }
        state.hosted[id] = hosted;
        continue;
      }
      if (hosted.unread !== undefined) {
        delete hosted.unread;
        dirty = true;
      }
      // Its name is part of what it is: a skill renamed is linked under its new name where it is copied.
      if (hosted.hash !== now.hash || hosted.name !== now.name) {
        hosted.version += 1;
        hosted.hash = now.hash;
        dirty = true;
      }
      if (now.kind === "skill") {
        const nextDir = (await dirKey(join(this.skillsDir(), now.skill!))) ?? hosted.dir;
        if (hosted.dir !== nextDir) {
          hosted.dir = nextDir;
          dirty = true;
        }
      }
      if (JSON.stringify(hosted.allow) !== JSON.stringify(now.allow)) {
        hosted.allow = now.allow;
        dirty = true;
      }
      if (hosted.name !== now.name) {
        hosted.name = now.name;
        dirty = true;
      }
      state.hosted[id] = hosted;
    }
    // Written before anyone is told, so what they ask for is that version.
    if (dirty) this.writeState(state);
    return own;
  }

  // ── running ──

  start() {
    this.stops.push(this.deps.cloud.listen(() => this.reconcile()));
    this.stops.push(this.deps.config.listen(() => this.reconcile()));
    this.reconcile();
  }

  /// Closed: nothing is followed from then on (a watch begun before, its directory still being looked at, is not made).
  private closed = false;

  async close() {
    this.closed = true;
    for (const stop of this.stops.splice(0)) stop();
    this.stopWatches();
    await this.time.close();
    await this.program.close();
    // (the links' turn, files alone, done; a pass still asking other stations is not waited for, its watches refused)
    await this.linkTurn;
    this.stopWatches();
    await this.stateWritten();
  }

  private stopWatches() {
    for (const w of this.watchers.values()) w.close();
    this.watchers.clear();
    this.loginDirs.clear();
  }

  /// Brings what is here in line with what is configured and what the hosts say: one at a time, again if asked meanwhile.
  reconcile(): Promise<void> {
    if (this.reconciling) {
      this.again = true;
      return this.reconciling;
    }
    // (set before the pass begins: what a pass asks may be answered here at once, by this station itself, which asks for
    // one again; begun inside it, each began another inside it until the stack ran out, 2026-11-14)
    this.reconciling = Promise.resolve().then(async () => {
      do {
        this.again = false;
        try {
          await this.reconcileOnce();
        } catch (e) {
          log.warn("share", "bringing shares in line failed", { error: (e as Error).message });
        }
      } while (this.again);
    }).finally(() => (this.reconciling = null));
    return this.reconciling;
  }

  private async reconcileOnce() {
    const me = this.me();
    if (me === null || this.deps.cloud.removed()) return;
    const rosters = this.rosters();
    const state = this.readState();
    await this.followSkills(state);
    let pending = false;
    const silent = new Set(this.unreachable.keys());
    const itself = (station: string) => this.deps.itself?.(station) === true;
    /// Its answer; a refusal kept on what it was of (`hosted`: shown where it is shared, till it is taken).
    const tell = async (peer: string, ws: string | null, request: Json, hosted?: Hosted): Promise<Json | Error> => {
      try {
        const answer = (await this.deps.ask(peer, ws, request)) ?? {};
        if (hosted) miss(hosted, peer, answer.hidden === true ? "same-name" : null);
        return answer;
      } catch (e) {
        pending = true;
        // Said, as a copy that could not be had is: else nothing on the host says why a station never got a share.
        log.info("share", "a station could not be told of a share", { id: request.id, peer, by: whoSaid(e), error: (e as Error).message });
        // One that did not answer is asked again; what it was before stands meanwhile.
        if (hosted && e instanceof Refused) miss(hosted, peer, /bad skill name/.test(e.message) ? "name" : "refused");
        return e as Error;
      }
    };

    // What this station shares: its version raised when what it is changed, each station that may use it told
    // (again, one that did not answer), in a workspace it is for, one that no longer may told so.
    const own = await this.syncHosted(state);
    for (const [id, now] of own) {
      if (this.unannounced.has(id) || now.hash === null || rosters === null) continue;
      const hosted = state.hosted[id];
      if (!hosted) continue;
      const peers: Promise<void>[] = [];
      for (const peer of rosters.keys()) {
        // (a station retired into this one: its copies came here with it)
        if (itself(peer)) continue;
        const ws = this.reach(now, peer, rosters);
        if (ws !== null && this.mayUse(now.allow, peer)) {
          const version = hosted.version;
          if (hosted.told[peer] === version) continue;
          peers.push(
            tell(peer, ws, { method: "share.changed", id, kind: now.kind, name: now.name, version, allow: now.allow }, hosted).then((r) => {
              if (!(r instanceof Error)) hosted.told[peer] = version;
            }),
          );
        } else {
          miss(hosted, peer, null);
          if (peer in hosted.told) {
            peers.push(
              tell(peer, null, { method: "share.changed", id, gone: true }).then((r) => {
                if (!(r instanceof Error)) delete hosted.told[peer];
              }),
            );
          }
        }
      }
      if (peers.length > 0) await Promise.all(peers);
      // Stations in none of this station's workspaces now: forgotten.
      for (const peer of Object.keys(hosted.told)) if (!rosters.has(peer)) delete hosted.told[peer];
      for (const peer of Object.keys(hosted.missing ?? {})) if (!rosters.has(peer)) miss(hosted, peer, null);
    }
    // No longer shared: each station told is told so, then it is forgotten.
    // Shared now, after awaiting peer notifications, so a share turned on while peers were told is kept.
    const currentOwn = this.shares();
    for (const [id, hosted] of Object.entries(state.hosted)) {
      if (currentOwn.has(id)) continue;
      const peers: Promise<void>[] = [];
      for (const peer of Object.keys(hosted.told)) {
        if (itself(peer) || (rosters !== null && !rosters.has(peer))) delete hosted.told[peer];
        else {
          peers.push(
            tell(peer, null, { method: "share.changed", id, gone: true }).then((r) => {
              if (!(r instanceof Error)) delete hosted.told[peer];
            }),
          );
        }
      }
      if (peers.length > 0) await Promise.all(peers);
      if (!this.shares().has(id) && Object.keys(hosted.told).length === 0) delete state.hosted[id];
    }
    // Handed to another station: the stations told of it hear where it went.
    for (const [id, moved] of Object.entries(state.moved)) {
      const left: string[] = [];
      const peers: Promise<void>[] = [];
      for (const peer of moved.tell) {
        if (peer === moved.to || itself(peer) || (rosters !== null && !rosters.has(peer))) continue;
        peers.push(
          tell(peer, null, { method: "share.changed", id, host: moved.to }).then((r) => {
            if (r instanceof Error) left.push(peer);
          }),
        );
      }
      if (peers.length > 0) await Promise.all(peers);
      if (left.length === 0) delete state.moved[id];
      else moved.tell = left;
    }

    // What this station uses of others': fetched when its host said it changed, asked once a run, and taken away when
    // its host is gone from the workspace it was had in (any of this station's, for a profile).
    for (const [id, had] of Object.entries(state.borrowed)) {
      if (rosters !== null && !this.hostThere(had, rosters)) {
        log.info("share", "the station a share was from left the workspace; its copy is taken away", { id, host: had.host });
        delete state.borrowed[id];
        await this.drop(id, had);
        continue;
      }
      if (!had.stale && !had.pending && !had.profileUpdate && !had.resetPending?.length && this.checked.has(id)) continue;
      // (its host retired into this station: nobody to ask, it comes here as its accounts do, `share.take`)
      if (itself(had.host)) continue;
      try {
        for (const key of [...(had.resetPending ?? [])]) {
          try {
            await this.deps.ask(had.host, this.askIn(had), { method: "share.quotaReset", id, key });
            had.resetPending = had.resetPending?.filter((pending) => pending !== key);
            this.writeState(state);
          } catch (e) {
            // An older host may not know this request yet. Retry it, without holding up other profile updates.
            pending = true;
            log.info("share", "an allowance reset could not be sent to its host", { id, host: had.host, by: whoSaid(e), error: (e as Error).message });
            break;
          }
        }
        if (had.pending && had.kind === "skill") await this.sendSkillEdit(id, had);
        if (!had.stale && !had.profileUpdate) {
          const now = await this.deps.ask(had.host, this.askIn(had), { method: "share.version", id, ...(had.kind === "skill" ? { hidden: !(await this.skillLinked(id, had)) } : {}) });
          this.unreachable.delete(had.host);
          if (typeof now?.moved === "string") {
            had.host = now.moved;
            had.stale = true;
          } else if (now?.version === had.version) {
            this.checked.add(id);
            continue;
          }
        }
        if (had.stale || !had.profileUpdate) {
          const got = await this.deps.ask(had.host, this.askIn(had), { method: "share.get", id });
          this.unreachable.delete(had.host);
          // (heard of again while it was asked for: taken away, or changed, `heard` putting a copy marked stale in its
          // place, which the pass `heard` asks for fetches; what came here is not placed, nor its allowance's reset
          // counted, twice)
          if (state.borrowed[id] !== had) continue;
          if (had.kind === "profile") {
            await this.placedHome(await this.placeProfile(id, had, got));
            // (lent meanwhile, or heard of again, while it was placed: that one's copy in its place, as above)
            if (state.borrowed[id] !== had) continue;
            const revision = Number(got?.quotaRevision ?? 0);
            if (had.version >= 0) had.profileUpdate = { reset: revision > (had.quotaRevision ?? 0) || had.profileUpdate?.reset === true };
            had.quotaRevision = revision;
          } else {
            await this.placeSkill(id, had, got);
            if (state.borrowed[id] !== had) continue;
          }
          had.version = Number(got?.version ?? 0);
          had.allow = Array.isArray(got?.allow) ? got.allow : null;
          had.stale = false;
          this.writeState(state);
        }
        if (had.profileUpdate) {
          const profile = this.profiles().find((p) => p.share?.id === id && p.share?.borrowed === true);
          if (profile) await this.deps.profileChanged?.(String(profile.id), had.profileUpdate.reset);
          delete had.profileUpdate;
          this.writeState(state);
        }
        this.checked.add(id);
      } catch (e) {
        pending = true;
        this.unreachable.set(had.host, this.time.now());
        log.info("share", "a share could not be had from its host", { id, host: had.host, by: whoSaid(e), error: (e as Error).message });
      }
    }
    // Hosts of borrowed subscriptions that did not answer: asked whether they do now.
    for (const host of [...this.unreachable.keys()]) {
      if (itself(host)) {
        this.unreachable.delete(host);
        continue;
      }
      const borrowed = this.profiles().find((p) => this.borrowedSubscription(p) && p.share.host === host);
      if (!borrowed) {
        this.unreachable.delete(host);
        continue;
      }
      try {
        await this.deps.ask(host, null, { method: "share.status", id: borrowed.share.id });
        this.unreachable.delete(host);
      } catch {
        pending = true;
      }
    }
    if ([...silent].some((h) => !this.unreachable.has(h))) this.deps.recheck?.();
    this.forgetTaken(state);
    this.writeState(state);
    await this.linkBorrowedSkills(state);
    // What did not get through is tried again, less often the longer it does not.
    if (!pending) this.retryMs = RETRY_MS;
    else if (this.retry === null) {
      const wait = this.retryMs;
      this.retryMs = Math.min(this.retryMs * 2, RETRY_MAX_MS);
      this.retry = this.time.after(wait, () => {
        this.retry = null;
        void this.reconcile();
      });
    }
    this.deps.changed();
  }

  // ── copies of others' shares ──

  /// The copy's profile made or changed in config.json, taken at once and written before what its caller changes of
  /// the state: its home, for `placedHome` to make.
  private async placeProfile(id: string, had: Borrowed, got: Json): Promise<string | null> {
    const given = isObject(got?.profile) ? got.profile : null;
    if (!given) throw new Error("the host sent no profile");
    await this.deps.config.updateSoon((raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const at = list.findIndex((p) => isObject(p?.share) && p.share.id === id);
      // One kept from before (a station that handed it over keeps its id and home: its chats go on with it).
      const local = at >= 0 ? String(list[at].id) : id;
      const home = at >= 0 && typeof list[at].home === "string" ? list[at].home : `homes/${id}`;
      const made: Json = { ...portable(given), id: local, home, share: { id, borrowed: true, host: had.host } };
      // Disabled by its host (kept apart from a pause here, so that the host enabling it again does not end the pause);
      // paused on this station (accounts/index.ts putProfile): still, as the host changes it.
      if (given.enabled === false) made.share.hostOff = true;
      if (at >= 0 && isObject(list[at].share) && list[at].share.paused === true) {
        made.share.paused = true;
        made.enabled = false;
      }
      if (typeof got.email === "string") made.share.email = got.email;
      // The workspaces it may serve here (none said: a host of before, as before).
      if (Array.isArray(got.workspaces)) made.share.workspaces = got.workspaces.filter((w: unknown) => typeof w === "string");
      if (!isObject(made.env)) made.env = {};
      if (at >= 0) list[at] = made;
      else list.push(made);
      raw.profiles = list;
    });
    const placed = this.profiles().find((p) => isObject(p.share) && p.share.id === id);
    return placed ? this.home(placed) : null;
  }

  private async placedHome(home: string | null) {
    if (home !== null) await mkdir(home, { recursive: true });
  }

  private mirror(id: string) {
    return join(this.root, id, "skill");
  }

  private async placeSkill(id: string, had: Borrowed, got: Json) {
    if (!isObject(got?.files)) throw new Error("the host sent no files");
    this.stopWatch(`borrowed:${id}`);
    await this.program.ask("skillWrite", { dir: this.mirror(id), files: got.files });
    had.hash = String(got.hash ?? "");
  }

  /// A copy taken away (already gone from the state): its profile, or its skill's link and files.
  private async drop(id: string, had: Borrowed) {
    if (had.kind === "profile") {
      await this.deps.config.updateSoon((raw) => {
        raw.profiles = (Array.isArray(raw.profiles) ? raw.profiles : []).filter((p: Json) => !(isObject(p?.share) && p.share.id === id && p.share.borrowed === true));
      });
      return;
    }
    this.stopWatch(`borrowed:${id}`);
    await this.linking(async () => {
      // (again in its turn: a watch made before it came, by a pass that saw the copy still there, stops too)
      this.stopWatch(`borrowed:${id}`);
      await this.unlinkSkillNow(id, had);
      await rm(join(this.root, id), { recursive: true, force: true });
    });
  }

  /// The copied skills' links made and taken away one at a time (`linkBorrowedSkills`, `drop`, `unlinkSkill`), so that
  /// none is made to a copy while it is taken away, each looking at the state as it is when its turn comes.
  private linkTurn: Promise<unknown> = Promise.resolve();

  private linking<T>(f: () => Promise<T>): Promise<T> {
    const run = this.linkTurn.then(f, f);
    this.linkTurn = run.catch(() => {});
    return run;
  }

  /// A copied skill's link under its name, if it is this copy's (`had`: as it was, its name the one it was linked by).
  private unlinkSkill(id: string, had: Borrowed): Promise<void> {
    return this.linking(() => this.unlinkSkillNow(id, had));
  }

  private async unlinkSkillNow(id: string, had: Borrowed) {
    const at = join(this.skillsDir(this.askIn(had)), had.name);
    const now = await entryAt(at);
    if (now !== null && now !== "other" && now.link === this.mirror(id)) await unlink(at).catch(() => {});
  }

  /// Each copied skill linked under its name into the agents' skills of the workspace it was had in, unless one of that
  /// workspace's own has it; edits to the copy followed.
  private linkBorrowedSkills(state: State): Promise<void> {
    return this.linking(async () => {
      for (const id of Object.keys(state.borrowed)) {
        const had = state.borrowed[id];
        if (had?.kind !== "skill") continue;
        const target = this.mirror(id);
        if (!(await stat(target).then(() => true, () => false))) continue;
        try {
          const skills = this.skillsDir(this.askIn(had));
          const at = join(skills, had.name);
          const there = await entryAt(at);
          // (taken away or renamed while its copy was looked at: `drop` or `heard` has it now)
          if (state.borrowed[id] !== had || had.kind !== "skill" || join(skills, had.name) !== at) continue;
          if (there === null) {
            await mkdir(skills, { recursive: true });
            // Where links are refused, a junction will do: its target is the copy's own directory, which stays where it is.
            await link(target, at, { junction: true });
            // Its host hears it is shown here (it may have been told otherwise).
            if (this.checked.delete(id)) this.again = true;
          } else if (there === "other" || there.link !== target) continue;
        } catch (e) {
          // This copy's alone: the others are linked all the same.
          log.warn("share", "a shared skill could not be linked", { id, name: had.name, error: (e as Error).message });
          continue;
        }
        await this.watchBorrowed(id, target);
      }
    });
  }

  /// Whether something else is under a copied skill's name here (one of this station's own, or another's copy).
  private async nameTaken(had: Borrowed): Promise<boolean> {
    try {
      return (await entryAt(join(this.skillsDir(this.askIn(had)), had.name))) !== null;
    } catch {
      return false;
    }
  }

  /// Whether a copied skill shows under its name here (one of this station's own of that name wins).
  private async skillLinked(id: string, had: Borrowed): Promise<boolean> {
    try {
      const now = await entryAt(join(this.skillsDir(this.askIn(had)), had.name));
      return now !== null && now !== "other" && now.link === this.mirror(id);
    } catch {
      return false;
    }
  }

  // ── edits followed ──

  private stopWatch(key: string) {
    this.watchers.get(key)?.close();
    this.watchers.delete(key);
  }

  /// `still`: whether it is still to be followed once its directory was looked at (it may have stopped meanwhile).
  private async watchDir(key: string, dir: string, then: () => void, still: () => boolean) {
    if (this.closed || this.watchers.has(key) || !(await stat(dir).then(() => true, () => false))) return;
    // (closed, no longer to be followed, or one begun meanwhile for the same key follows it already)
    if (this.closed || !still() || this.watchers.has(key)) return;
    // Its directories each watched, not what a program made beside its files (ops/follow.ts says why).
    const tree: FollowedTree = new FollowedTree({
      root: dir,
      into: (rel) => rel.split("/").every((n) => !SKIPPED.has(n)),
      most: SKILL_DIRS_MOST,
      changed: () => {
        this.settle.get(key)?.();
        this.settle.set(key, this.time.after(SETTLE_MS, () => (this.settle.delete(key), void tree.scan(), then()))); // timer: a debounce of a burst
      },
      // Failing later (macOS turning it down: EMFILE): dropped, for the next reconcile to follow it again.
      failed: (e) => {
        log.warn("share", "a shared skill's directory no longer followed", { dir, error: e.message });
        if (this.watchers.get(key) === tree) this.stopWatch(key);
      },
    });
    this.watchers.set(key, tree);
    void tree.scan().then((r) => {
      if (r.failed === undefined) return;
      log.warn("share", "a shared skill's directory cannot be followed", { dir, error: r.failed.message });
      if (this.watchers.get(key) === tree) this.stopWatch(key);
    });
  }

  private watchHosted(name: string, dir: string): Promise<void> {
    return this.watchDir(`hosted:${name}`, dir, () => void this.reconcile(), () => name in this.sharedSkills());
  }

  /// Follow the directory, not auth.json itself: Codex replaces the file when it signs in or renews.
  private watchLogin(id: string, file: string) {
    const key = `login:${id}`;
    if (this.closed || (this.loginDirs.get(id) === file && this.watchers.has(key))) return;
    this.stopWatch(key);
    this.loginDirs.delete(id);
    try {
      const w = watch(dirname(file), { persistent: false }, (_event, name) => {
        if (name !== null && String(name) !== basename(file)) return;
        this.settle.get(key)?.();
        this.settle.set(key, this.time.after(SETTLE_MS, () => (this.settle.delete(key), void this.reconcile())));
      });
      w.on("error", () => { if (this.watchers.get(key) === w) this.stopWatch(key); });
      this.watchers.set(key, w);
      this.loginDirs.set(id, file);
    } catch { /* The profile's home may not exist until it is signed in. */ }
  }

  private watchBorrowed(id: string, dir: string): Promise<void> {
    const key = `borrowed:${id}`;
    return this.watchDir(key, dir, () => {
      if (!this.readState().borrowed[id]) return;
      // (read while no new copy is placed: placing one stops this watch first, and what it read then is not an edit)
      const watching = this.watchers.get(key);
      void this.readSkill(dir).then(({ hash }) => {
        const state = this.readState();
        const had = state.borrowed[id];
        if (!had || this.watchers.get(key) !== watching || hash === had.hash) return;
        had.pending = true;
        this.writeState(state);
        void this.reconcile();
      }, () => {});
    }, () => this.readState().borrowed[id] !== undefined);
  }

  /// An edit made to a copied skill, sent to its host on the version it was made on.
  private async sendSkillEdit(id: string, had: Borrowed) {
    const { hash, files } = await this.readSkill(this.mirror(id), true);
    const answer = await this.deps.ask(had.host, this.askIn(had), { method: "share.put", id, base: had.version, files });
    had.pending = false;
    had.hash = hash;
    if (typeof answer?.version === "number") had.version = answer.version;
    // On an older copy: the host's is fetched, the edit beside it.
    if (answer?.conflict === true) had.stale = true;
  }

  // ── what others ask (share.*) ──

  /// A request of another station of one of the station's workspaces (the transport checked it is one), made in
  /// `workspace` (none said: the home one).
  async handle(peer: string, request: Json, workspace?: string): Promise<Json> {
    const method = String(request?.method ?? "");
    const id = String(request?.id ?? "");
    if (method === "share.changed") {
      // (one this station is handing over as it is told: heard once the hand-over is done here, so a word of the new
      // host's, its share undone as the login came home, is not heard by the station that still hosts it, then lost)
      const moving = this.moveDone.get(id);
      if (moving !== undefined) await moving;
      return this.heard(peer, id, request, workspace ?? this.deps.cloud.home());
    }
    if (method === "share.take") return this.take(peer, request);
    if (method === "share.borrow") return this.borrow(peer, id, request);
    const state = this.readState();
    const moved = state.moved[id];
    if (moved && method === "share.version") return { moved: moved.to };
    const own = this.shares().get(id);
    if (!own) throw new Error("this station does not share that");
    if (!this.mayUse(own.allow, peer) || this.reach(own, peer) === null) throw new Error("that share is not for this station");
    const version = state.hosted[id]?.version ?? 0;
    if (method === "share.version") {
      // A copy of a skill not shown there, as one of that station's own has its name (or shown again).
      const hosted = state.hosted[id];
      if (hosted && typeof request.hidden === "boolean" && (hosted.missing?.[peer] ?? null) !== (request.hidden ? "same-name" : null)) {
        miss(hosted, peer, request.hidden ? "same-name" : null);
        this.writeState(state);
        this.deps.changed();
      }
      return { version };
    }
    if (own.kind === "profile") {
      const p = own.profile!;
      if (method === "share.get") {
        // (its account read first: the rest as it is when this answers, its version and allowance's revision of one
        // moment, not a version from before a reset with the reset's revision)
        const email = p.access?.kind === "subscription" ? await this.emailOf(p) : null;
        const now = this.shares().get(id);
        if (now?.kind !== "profile") throw new Error("this station does not share that");
        const at = state.hosted[id]?.version ?? 0;
        // It has a copy now: it is told when this one changes.
        this.told(id, peer, at);
        return { version: at, profile: portable(now.profile), email, allow: now.allow, workspaces: this.sharedIn(now.profile), quotaRevision: state.hosted[id]?.quotaRevision ?? 0 };
      }
      if (method === "share.lend") {
        if (this.moving.has(id)) throw new Error("the login is being moved to another station");
        return this.lend(p, typeof request.rejected === "string" ? request.rejected : undefined);
      }
      if (method === "share.status") return this.deps.status(p.id);
      if (method === "share.quotaReset") {
        const key = typeof request.key === "string" ? request.key : "";
        if (!key || p.runtime !== "codex" || p.access?.kind !== "subscription") throw new Error("invalid allowance reset");
        if (!state.hosted[id]?.resetKeys?.includes(key)) await this.deps.quotaReset?.(p.id);
        await this.quotaReset(p.id, key);
        return { heard: true };
      }
    } else {
      const dir = join(this.skillsDir(), own.skill!);
      if (method === "share.get") {
        // (its version as it is when its files are read: not between a change read and its version raised)
        return this.serially(async () => {
          const { hash, files } = await this.readSkill(dir, true);
          const now = state.hosted[id]?.version ?? 0;
          this.told(id, peer, now);
          return { version: now, hash, files, allow: own.allow };
        });
      }
      if (method === "share.put") return this.takeEdit(peer, id, own.skill!, dir, request);
    }
    throw new Error(`unknown share request ${method}`);
  }

  /// Notes that a station has a share at a version (it has fetched it).
  private told(id: string, peer: string, version: number) {
    const state = this.readState();
    const hosted = state.hosted[id];
    if (!hosted) return;
    hosted.told[peer] = version;
    this.writeState(state);
  }

  /// What a host says of one of its shares, in workspace `ws`: there, changed, no longer for this station, or moved to
  /// another station.
  private async heard(peer: string, id: string, request: Json, ws: string | null): Promise<Json> {
    if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
    const state = this.readState();
    const had = state.borrowed[id];
    // From another station than the one it was had from: that one handed it over (its word on where may come later).
    if (had && had.host !== peer && request.gone !== true && typeof request.host !== "string") {
      had.host = peer;
      had.stale = true;
    }
    // The new host's announcement may arrive before the old host's handover notice. A notice naming the host already
    // taken is a harmless retry, so the old host can stop sending it.
    if (had && had.host !== peer && request.host === had.host) return { heard: true };
    if (had && had.host !== peer) throw new Error("only the station that has it says so");
    // (the state changed at once, then the files: what reads the state meanwhile finds it as it is now)
    let dropped: Promise<void> | null = null;
    if (request.gone === true) {
      if (had) {
        delete state.borrowed[id];
        dropped = this.drop(id, had);
      }
    } else if (typeof request.host === "string") {
      if (had) {
        had.host = request.host;
        had.stale = true;
      }
    } else if (!had || had.version !== request.version) {
      const kind: ShareKind = request.kind === "skill" ? "skill" : "profile";
      const name = String(request.name ?? id);
      if (kind === "skill" && !portableName(name)) throw new Error("bad skill name");
      // Renamed on its host: no longer linked under the name it had.
      if (had?.kind === "skill" && had.name !== name) dropped = this.unlinkSkill(id, { ...had });
      // A skill of a joined workspace's station: linked into that workspace's skills.
      const where = kind === "skill" && had === undefined && ws !== null && ws !== this.deps.cloud.home() ? { workspace: ws } : {};
      state.borrowed[id] = { ...(had ?? { version: -1, hash: "" }), ...where, kind, name, host: peer, allow: Array.isArray(request.allow) ? request.allow : null, stale: true };
    }
    this.writeState(state);
    if (dropped !== null) await dropped;
    void this.reconcile();
    // Not to be shown here, as something of this station's has its name (its own skill wins): said to its host.
    const now = state.borrowed[id];
    if (now?.kind === "skill" && !(await this.skillLinked(id, now)) && (await this.nameTaken(now))) return { heard: true, hidden: true };
    return { heard: true };
  }

  private async emailOf(p: Json): Promise<string | null> {
    if (typeof p.share?.email === "string") return p.share.email;
    if (p.machine === true) return this.deps.machineEmail?.(p.runtime) ?? null;
    const home = this.home(p);
    // (read again only once its file changed: accounts/index.ts emailKept)
    if (p.runtime === "grok" || p.runtime === "cursor") return accountEmailSoon(p.runtime, home);
    if (p.runtime === "codex") {
      try {
        const auth = JSON.parse(await readFile(join(home, "auth.json"), "utf8"));
        const claims = JSON.parse(Buffer.from(String(auth?.tokens?.id_token ?? "").split(".")[1] ?? "", "base64url").toString("utf8"));
        const email = claims?.email ?? claims?.["https://api.openai.com/profile"]?.email;
        return typeof email === "string" ? email : null;
      } catch {
        return null;
      }
    }
    for (const file of [join(home, ".claude.json"), join(home, "claude.json")]) {
      try {
        const email = JSON.parse(await readFile(file, "utf8"))?.oauthAccount?.emailAddress;
        if (typeof email === "string") return email;
      } catch {}
    }
    return null;
  }

  /// An edit from a station that copies a skill: taken when made on the current version; else kept beside it.
  private takeEdit(peer: string, id: string, name: string, dir: string, request: Json): Promise<Json> {
    return this.serially(() => this.takeEditNow(peer, id, name, dir, request));
  }

  private async takeEditNow(peer: string, id: string, name: string, dir: string, request: Json): Promise<Json> {
    const state = this.readState();
    const hosted = state.hosted[id];
    const version = hosted?.version ?? 0;
    const files: Record<string, unknown> = isObject(request.files) ? request.files : {};
    const conflict = request.base !== version;
    // Its every file checked by the program before anything is written (a path that leaves the skill, past what may
    // be shared), one made on an older copy too.
    await this.program.ask("skillWrite", { dir, files, most: MAX_SKILL_BYTES, ...(conflict ? { check: true } : {}) });
    const skill = files["SKILL.md"];
    if (conflict && typeof skill === "string") await this.program.ask("skillConflict", { dir, peer, content: skill });
    const next = version + 1;
    if (hosted) {
      hosted.version = next;
      hosted.hash = (await this.readSkill(dir)).hash;
      // The station that sent it has it (unless it conflicted); the others are told.
      if (!conflict) hosted.told[peer] = next;
    }
    this.writeState(state);
    log.info("share", conflict ? "a skill edit on an older copy kept beside it" : "a skill edit taken", { name, from: peer });
    void this.reconcile();
    return { version: next, conflict };
  }

  /// A short-lived access token of a shared subscription, renewed here when needed.
  private async lend(p: Json, rejected?: string): Promise<Json> {
    if (p.access?.kind !== "subscription") throw new Error("only a subscription is lent");
    if (p.runtime === "claude") {
      const t = await this.deps.claudeToken(p, rejected);
      return { runtime: "claude", token: t.token, expiresAt: t.expiresAt };
    }
    if (p.runtime === "agy") return this.lendAgyHere(p);
    const file = this.codexFile(p);
    let auth = JSON.parse(await readFile(file, "utf8"));
    let expiresAt = jwtExpiry(auth?.tokens?.access_token) ?? 0;
    if (expiresAt - this.time.now() < CODEX_LEND_MS) {
      // By the Codex running on it, asked to (else it would only when its own token runs out, the station's borrowers
      // refused till then), or here where none runs.
      const renewed = this.renewOnce(p, "Codex", expiresAt, async () => {
        if (!(await this.deps.codexRenewRunning(p.id))) await this.renewCodex(file, auth);
      });
      // One that still lasts CODEX_MIN_MS waits for its renewal LEND_BOUND_MS at most, then is lent as it is, the renewal
      // going on behind: the station that asked waits 30 s for the answer (mesh/peer.ts ANSWER_MS), as long as the
      // renewal's call may take (Claude's lend, 2026-11-14). One with less waits for it.
      if (expiresAt - this.time.now() >= CODEX_MIN_MS) await this.withinBound(p, "Codex", expiresAt, renewed);
      else await renewed;
      // Read again either way: Codex may have renewed it and then failed a step after (it answers with that error).
      auth = JSON.parse(await readFile(file, "utf8"));
      expiresAt = jwtExpiry(auth?.tokens?.access_token) ?? 0;
    }
    if (expiresAt - this.time.now() < CODEX_MIN_MS) throw new Error("the Codex login here runs out soon and cannot be renewed now");
    const tokens = auth.tokens ?? {};
    return { runtime: "codex", tokens: { id_token: tokens.id_token, access_token: tokens.access_token, account_id: tokens.account_id }, expiresAt };
  }

  /// An Antigravity CLI sign-in's access token, renewed first when it has less than AGY_LEND_MS left: one that still
  /// lasts AGY_MIN_MS waits for its renewal LEND_BOUND_MS at most and is lent as it is, the renewal going on behind (as
  /// Codex's). Its refresh token stays here.
  private async lendAgyHere(p: Json): Promise<Json> {
    const file = agyToken(this.home(p));
    let text = await readFile(file, "utf8");
    let expiresAt = agyExpiryIn(text);
    if (expiresAt - this.time.now() < AGY_LEND_MS) {
      const renewed = this.renewOnce(p, "Antigravity CLI", expiresAt, () => {
        if (!this.deps.agyRenew) throw new Error("this station renews no Antigravity CLI sign-in");
        return this.deps.agyRenew(this.home(p));
      });
      if (expiresAt - this.time.now() >= AGY_MIN_MS) await this.withinBound(p, "Antigravity CLI", expiresAt, renewed);
      else await renewed;
      text = await readFile(file, "utf8");
      expiresAt = agyExpiryIn(text);
    }
    if (expiresAt - this.time.now() < AGY_MIN_MS) throw new Error("the Antigravity CLI sign-in here runs out soon and cannot be renewed now");
    const had = JSON.parse(text);
    const { refresh_token: _, ...token } = had.token ?? {};
    // `stored`: the rest of its file (a company's project, region and tier) for the borrower's (agents/agy.ts
    // agyLentFile); the fields beside it for borrowers from before.
    const { token: __, ...rest } = had;
    return { runtime: "agy", token, email: typeof had.id_token_email === "string" ? had.id_token_email : null, auth_method: typeof had.auth_method === "string" ? had.auth_method : null, stored: rest, expiresAt };
  }

  /// `renewed` waited for LEND_BOUND_MS at most: past it, what is lent is the login as it is, which is said.
  private async withinBound(p: Json, what: string, expiresAt: number, renewed: Promise<void>): Promise<void> {
    const began = this.time.now();
    let stop = () => {};
    const bound = new Promise<boolean>((resolve) => (stop = this.time.after(LEND_BOUND_MS, () => resolve(false))));
    const inTime = await Promise.race([renewed.then(() => true), bound]);
    stop();
    if (!inTime) log.warn("share", `a shared ${what} login's renewal outlasted the lend's bound; the login it has was lent, the renewal goes on`, { profile: p.id, ms: this.time.now() - began, lastsMin: Math.round((expiresAt - this.time.now()) / 60_000) });
  }

  /// One renewal of a profile's login at a time (`renew`), what is lent meanwhile waiting on it; a failure is said:
  /// which login, how long it took, how long what it has still lasts.
  private renewOnce(p: Json, what: string, expiresAt: number, renew: () => Promise<unknown>): Promise<void> {
    const id = String(p.id);
    const going = this.renewing.get(id);
    if (going !== undefined) return going;
    const began = this.time.now();
    const done = Promise.resolve()
      .then(renew)
      .then(
        () => {},
        (e) => log.warn("share", `renewing a shared ${what} login failed`, { profile: p.id, ms: this.time.now() - began, lastsMin: Math.round((expiresAt - this.time.now()) / 60_000), error: (e as Error).message }),
      )
      .finally(() => this.renewing.delete(id));
    this.renewing.set(id, done);
    return done;
  }

  /// The renewals of shared logins going on, by profile: one at a time, what is lent meanwhile waiting on it.
  private renewing = new Map<string, Promise<void>>();

  /// Once a renewal of profile `id` going on, if any, is over (tests).
  renewedBehind(id: string): Promise<void> {
    return this.renewing.get(id) ?? Promise.resolve();
  }

  /// Codex's own renewal of its ChatGPT login, done here while no Codex runs on it (it would hold the old refresh token).
  private async renewCodex(file: string, auth: Json): Promise<Json> {
    const refresh = auth?.tokens?.refresh_token;
    if (typeof refresh !== "string" || refresh === "") throw new Error("no refresh token");
    const response = await profileFetch(this.deps.codexTokenUrl ?? CODEX_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: CODEX_CLIENT_ID, grant_type: "refresh_token", refresh_token: refresh, scope: "openid profile email" }),
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`the token endpoint answered ${response.status}`);
    const got = await response.json();
    const next = structuredClone(auth);
    next.tokens = { ...next.tokens };
    for (const k of ["id_token", "access_token", "refresh_token"]) if (typeof got?.[k] === "string") next.tokens[k] = got[k];
    next.last_refresh = new Date(this.time.now()).toISOString();
    await writePrivateSoon(file, JSON.stringify(next, null, 2));
    return next;
  }

  // ── borrowing (the agents' drivers) ──

  /// Whether a profile is a copy of another station's subscription (its login borrowed for each process).
  borrowedSubscription(profile: Json): boolean {
    return isObject(profile?.share) && profile.share.borrowed === true && profile.access?.kind === "subscription";
  }

  private hostOf(profile: Json): string {
    const host = profile?.share?.host;
    if (typeof host !== "string") throw new Error("this profile is not borrowed from another station");
    return host;
  }

  /// Once the cloud has said the workspace's stations, or ROSTER_WAIT_MS on. A station just started hears them some
  /// 500 ms after what waited for an agent is given one again (2026-11-02), and nothing would try that again until it
  /// next restarts: only what has no login kept to go on with waits here.
  private rosterSaid(): Promise<void> {
    const cloud = this.deps.cloud;
    if (cloud.peersCurrent || cloud.state === null) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        stop();
        giveUp();
        resolve();
      };
      const stop = cloud.listen(() => {
        if (cloud.peersCurrent) done();
      });
      const giveUp = this.time.after(ROSTER_WAIT_MS, done);
    });
  }

  /// A borrowed Claude subscription's token, from its host; `rejected`, the one a process here was refused with.
  async lendClaude(profile: Json, rejected?: string): Promise<MachineToken> {
    const host = this.hostOf(profile);
    const before = this.lentClaude.get(profile.id);
    if (!before || before.token === rejected || before.expiresAt - this.time.now() < KEEP_LENT_MS) await this.rosterSaid();
    try {
      const got = await this.deps.ask(host, null, { method: "share.lend", id: profile.share.id, ...(rejected !== undefined ? { rejected } : {}) });
      this.unreachable.delete(host);
      if (typeof got?.token !== "string") throw new Error("the host lent no token");
      const token = { token: got.token, expiresAt: Number(got.expiresAt ?? 0) };
      this.lentClaude.set(profile.id, token);
      return token;
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      this.deps.changed();
      const kept = this.lentClaude.get(profile.id);
      if (kept && kept.token !== rejected && kept.expiresAt - this.time.now() >= KEEP_LENT_MS) {
        log.warn("share", "the host did not lend a new token; the one lent before is used", { profile: profile.id, error: (e as Error).message });
        return kept;
      }
      log.warn("share", "the host did not lend it", { profile: profile.id, error: (e as Error).message });
      throw new Said(tr(stationLang(), "station.share.notLent"));
    }
  }

  /// A borrowed Codex subscription: its home's auth.json written with the host's current tokens (no refresh token, so
  /// Codex never renews it here); when they run out.
  async lendCodex(profile: Json, rejected = false): Promise<number> {
    const host = this.hostOf(profile);
    const home = this.home(profile);
    if ((await keptCodexExpiry(join(home, "auth.json"))) - this.time.now() < KEEP_LENT_MS) await this.rosterSaid();
    let got: Json;
    try {
      got = await this.deps.ask(host, null, { method: "share.lend", id: profile.share.id });
      this.unreachable.delete(host);
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      this.deps.changed();
      const kept = await keptCodexExpiry(join(home, "auth.json"));
      if (!rejected && kept - this.time.now() >= KEEP_LENT_MS) {
        log.warn("share", "the host did not lend a new login; the one lent before is used", { profile: profile.id, error: (e as Error).message });
        return kept;
      }
      log.warn("share", "the host did not lend it", { profile: profile.id, error: (e as Error).message });
      throw new Said(tr(stationLang(), "station.share.notLent"));
    }
    const auth = {
      auth_mode: "chatgpt",
      OPENAI_API_KEY: null,
      tokens: { ...got.tokens, refresh_token: "lent-by-another-station" },
      last_refresh: new Date(this.time.now()).toISOString(),
    };
    await writePrivateSoon(join(home, "auth.json"), JSON.stringify(auth, null, 2));
    return Number(got.expiresAt ?? 0);
  }

  /// A borrowed Antigravity CLI subscription: its home's sign-in file written with the host's current access token (no
  /// refresh token, so `agy` never renews it here); when it runs out. `rejected`: the one there was refused, so it is not
  /// used again while the host is away.
  async lendAgy(profile: Json, rejected = false): Promise<number> {
    const host = this.hostOf(profile);
    const file = agyToken(this.home(profile));
    const kept = () => readFile(file, "utf8").then(agyExpiryIn, () => 0);
    if ((await kept()) - this.time.now() < KEEP_AGY_MS) await this.rosterSaid();
    let got: Json;
    try {
      got = await this.deps.ask(host, null, { method: "share.lend", id: profile.share.id });
      this.unreachable.delete(host);
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      this.deps.changed();
      const until = await kept();
      if (!rejected && until - this.time.now() >= KEEP_AGY_MS) {
        log.warn("share", "the host did not lend a new sign-in; the one lent before is used", { profile: profile.id, error: (e as Error).message });
        return until;
      }
      log.warn("share", "the host did not lend it", { profile: profile.id, error: (e as Error).message });
      throw new Said(tr(stationLang(), "station.share.notLent"));
    }
    if (got?.runtime !== "agy" || typeof got?.token?.access_token !== "string") throw new Said(tr(stationLang(), "station.share.notLent"));
    await writePrivateSoon(file, agyLentFile(got));
    if (typeof got.email === "string" && got.email !== "") await writePrivateSoon(agyAccountFile(this.home(profile)), `${JSON.stringify({ email: got.email })}\n`);
    return Number(got.expiresAt ?? 0);
  }

  /// A borrowed profile's check and allowance, as its host has them.
  async status(profile: Json): Promise<{ check: Json; quota: Json }> {
    const host = this.hostOf(profile);
    try {
      const got = await this.deps.ask(host, null, { method: "share.status", id: profile.share.id });
      this.unreachable.delete(host);
      return { check: got?.check ?? null, quota: got?.quota ?? null };
    } catch (e) {
      this.unreachable.set(host, this.time.now());
      throw e;
    }
  }

  /// A sign-in changed on this station. `profileId`: a profile signed in anew, whose copies are told a new version when
  /// it is shared from here, so that each takes the new sign-in (accounts/index.ts `sharedChanged`): a Codex one's
  /// version follows its sign-in's file by itself (`profileHash`), the others' (the Antigravity CLI's, Claude's) only so.
  loginUpdated(profileId?: string): void {
    const profile = profileId === undefined ? undefined : this.profiles().find((p) => p.id === profileId);
    const id = profile?.share?.id;
    if (profile && typeof id === "string" && profile.runtime !== "codex" && profile.share.borrowed !== true) {
      const state = this.readState();
      const hosted = state.hosted[id];
      if (hosted) {
        hosted.version++;
        this.writeState(state);
      }
    }
    void this.reconcile();
  }

  /// A reset made here or by a borrower is sent to every copy, including those currently offline. The redemption key
  /// makes a retry after a lost reply harmless.
  async quotaReset(profileId: string, key: string): Promise<void> {
    const profile = this.profiles().find((p) => p.id === profileId);
    const id = profile?.share?.id;
    if (typeof id !== "string") return;
    const moving = this.moveDone.get(id);
    if (moving) {
      await moving;
      return this.quotaReset(profileId, key);
    }
    const state = this.readState();
    if (profile.share.borrowed === true) {
      const had = state.borrowed[id];
      if (!had) return;
      had.resetPending = [...new Set([...(had.resetPending ?? []), key])];
    } else {
      let hosted = state.hosted[id];
      if (!hosted) {
        await this.reconcile();
        hosted = state.hosted[id];
      }
      if (!hosted || hosted.resetKeys?.includes(key)) return;
      hosted.resetKeys = [...(hosted.resetKeys ?? []), key].slice(-32);
      hosted.quotaRevision = (hosted.quotaRevision ?? 0) + 1;
      hosted.version++;
    }
    this.writeState(state);
    void this.reconcile();
  }

  // ── what the pages ask (this station hosting) ──

  /// A profile shared (with who may use it: null, every station), its stations changed, or no longer shared. `among`:
  /// the stations a person chose from (a page lists those of the workspace it is in, not every one the profile reaches
  /// where this station is in several): `allow` says which of them may use it (none said: all of them) and the others
  /// keep what they had (allowAmong), so a choice made in one workspace never undoes one made in another, as a list made
  /// of one workspace's stations and written whole did (the user, 2026-11-13: 「我明明关掉对几个特定机子的 Profile 分享了，
  /// 但老是莫名其妙就重置了」).
  /// `by`: who asked (said in the log, which is where a change nobody remembers making is found).
  async shareProfile(profileId: string, on: boolean, allow: string[] | null, among: string[] | null = null, by: string | null = null) {
    const p = this.profiles().find((x) => x.id === profileId);
    if (!p) throw new Error(`unknown profile ${profileId}`);
    if (isObject(p.share) && p.share.borrowed === true) throw new Error("this profile is another station's");
    const refused = on ? shareRefusal(p) : null;
    if (refused !== null) throw new Error(refused);
    const had = isObject(p.share) && typeof p.share.id === "string" ? (p.share.id as string) : null;
    // (the stations it reaches are said by the cloud: a station just started waits for them, as a login wanted does)
    if (on && among !== null) await this.rosterSaid();
    const stored: { allow: string[] | null } = { allow: null };
    await this.deps.config.updateSoon((raw) => {
      for (const x of raw.profiles ?? []) {
        if (x.id !== profileId) continue;
        if (!on) {
          delete x.share;
          continue;
        }
        stored.allow = among === null ? allow : this.allowAmong(x, allow, among);
        x.share = { id: had ?? newId(), allow: stored.allow };
      }
    });
    const who = stored.allow === null ? "every station" : stored.allow.map((s) => s.slice(0, 8)).join(",");
    log.info("share", "who may use a shared profile changed", { profile: profileId, shared: on, allow: on ? who : null, by });
    await this.syncHosted();
    this.deps.changed();
    void this.reconcile();
  }

  /// Who may use profile `p` once a person chose among stations `among` (shareProfile): those of them `allow` names
  /// (null: all of them), and every other station as it was. Every station it reaches allowed so (those of the workspaces
  /// it is shared in, as the cloud said last) is every station again (null: those to come too), as all of them ticked in
  /// a station's one workspace says; one left out where there were none makes the others it reaches a list, which needs
  /// them said (refused till they are).
  private allowAmong(p: Json, allow: string[] | null, among: string[]): string[] | null {
    const me = this.me();
    const shown = new Set(among);
    const yes = new Set(allow ?? among);
    const before: string[] | null = isObject(p.share) && Array.isArray(p.share.allow) ? p.share.allow : null;
    const rosters = this.rosters();
    const reached = rosters === null ? null : [...rosters.keys()].filter((peer) => this.reach({ kind: "profile", profile: p }, peer, rosters) !== null);
    if (before === null && among.every((s) => s === me || yes.has(s))) return null;
    if (before === null && reached === null) throw new Said(tr(stationLang(), "station.share.stationsUnknown"));
    const next = new Set((before ?? reached!).filter((s) => !shown.has(s)));
    if (me !== null) next.add(me);
    for (const s of among) if (yes.has(s)) next.add(s);
    if (reached !== null && reached.every((s) => next.has(s))) return null;
    return [...next];
  }

  /// A skill shared, its stations changed, or no longer shared.
  async shareSkill(name: string, on: boolean, allow: string[] | null) {
    const had = this.sharedSkills()[name]?.id ?? null;
    if (on) {
      const dir = join(this.skillsDir(), name);
      if ((await lstat(dir)).isSymbolicLink()) throw new Error("this skill is another station's");
      if (!(await this.readSkill(dir)).hasSkillMd) throw new Error("no SKILL.md in that skill");
    }
    await this.deps.config.updateSoon((raw) => {
      const skills: Json = isObject(raw.sharedSkills) ? raw.sharedSkills : {};
      if (on) skills[name] = { id: had ?? newId(), allow };
      else delete skills[name];
      raw.sharedSkills = skills;
    });
    if (!on) this.stopWatch(`hosted:${name}`);
    await this.syncHosted();
    this.deps.changed();
    void this.reconcile();
  }

  /// A profile of this station's moved to another whole station of a workspace it serves (`to`): its login handed over
  /// (`signInFiles`), let go of here only once that station says it has it. One shared: this one stops lending, keeps a
  /// copy borrowed from the new host (none where its stations do not include this one: gone from here then, as one not
  /// shared) and tells the stations it had told where it went. One not shared: gone from here,
  /// the other's own, its sessions here going on on another profile. Its id there, said back. Refused in words.
  /// `shareFirst` (a migration's, move/accounts.ts): one not shared whose login can be (`shareRefusal`) is shared first,
  /// with this station and `to` alone (`allow` those two: neither every station nor a third gains anything), no station
  /// told, and moved as a shared one, so that this station borrows it after and its chats here go on. `shareFirst` is
  /// given the share's id before it is made (kept, by the move, as one it made). Where the move fails before the other
  /// took it, the share is undone and the login here is as it was; the login here is let go of only once the other said
  /// it has it (its files written there before it answers), so it is never on neither station. `share`: the share it
  /// moved as.
  async moveProfile(profileId: string, to: string, lang = stationLang(), shareFirst?: (share: string) => Promise<void>): Promise<{ id: string; share?: string }> {
    const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
    const p = this.profiles().find((x) => x.id === profileId);
    if (!p) throw new Said(t("station.share.moveUnknown"));
    if (p.machine === true) throw new Said(t("station.share.moveMachine"));
    if (isObject(p.share) && p.share.borrowed === true) throw new Said(t("station.share.moveBorrowed"));
    if (to === this.me()) return { id: profileId };
    const ws = this.reach({ kind: "profile", profile: p }, to);
    if (ws === null) throw new Said(t("station.share.moveWhere"));
    const credentials: Record<string, string> = {};
    const home = this.home(p);
    for (const name of signInFiles(p)) {
      try {
        const path = join(home, name);
        if (!(await lstat(path)).isSymbolicLink()) credentials[name] = (await readFile(path)).toString("base64");
      } catch {}
    }
    // (its account read while its login is here: the copy kept here is named by it after the login goes)
    const email = await this.emailOf(p);
    const me = this.me();
    const sharing = !isObject(p.share) && shareFirst !== undefined && shareRefusal(p) === null && me !== null;
    if (!isObject(p.share) && !sharing) return this.moveOwn(p, to, ws, credentials, t, lang);
    const id = sharing ? newId() : (p.share.id as string);
    if (this.moving.has(id)) throw new Said(t("station.share.moving"));
    const allow: string[] | null = sharing ? [me!, to] : Array.isArray(p.share.allow) ? p.share.allow : null;
    const state = this.readState();
    const was = sharing ? undefined : state.hosted[id];
    const done = Promise.withResolvers<void>();
    this.moving.add(id);
    if (sharing) this.unannounced.add(id);
    this.moveDone.set(id, done.promise);
    let there = profileId;
    let made = false;
    let taken = false;
    let keeps = true;
    try {
      if (sharing) {
        await shareFirst!(id);
        await this.deps.config.updateSoon((raw) => {
          for (const x of raw.profiles ?? []) if (x.id === profileId) x.share = { id, allow };
        });
        made = true;
        log.info("share", "a profile shared as it moves, with this station and the one it goes to only", { profile: profileId, to });
      }
      const answer = await this.deps.ask(to, ws, { method: "share.take", id, profileId, profile: { ...portable(p), access: p.access }, served: this.sharedIn(p), lang, email, credentials, allow, version: (was?.version ?? 0) + 1, quotaRevision: was?.quotaRevision ?? 0, resetKeys: was?.resetKeys ?? [] });
      taken = true;
      if (typeof answer?.id === "string") there = answer.id;
      // Ours no more: the login forgotten (the new host renews it now), the profile kept as a copy under the same id.
      for (const name of Object.keys(credentials)) await rm(join(home, name), { force: true });
      // (a station its stations do not include keeps no copy: it may not borrow it, and its host's word that it is
      // no longer for it may come before it has one, so it would keep it)
      keeps = allow === null || (me !== null && allow.includes(me));
      await this.deps.config.updateSoon((raw) => {
        if (!keeps) raw.profiles = (Array.isArray(raw.profiles) ? raw.profiles : []).filter((x: Json) => x?.id !== profileId);
        else for (const x of raw.profiles ?? []) if (x.id === profileId) x.share = { id, borrowed: true, host: to, ...(email ? { email } : {}) };
      });
      const after = this.readState();
      delete after.hosted[id];
      // Fetched from the new host at once: the workspaces it shares it in are its to say now.
      if (keeps) after.borrowed[id] = { version: (was?.version ?? 0) + 1, hash: "", kind: "profile", name: String(p.name ?? p.id), host: to, allow, stale: true, quotaRevision: was?.quotaRevision ?? 0 };
      after.moved[id] = { to, tell: Object.keys(was?.told ?? {}) };
      this.writeState(after);
    } catch (e) {
      // (the share this move made, undone while the login is still here alone: as it was)
      if (made && !taken) {
        await this.deps.config.updateSoon((raw) => {
          for (const x of raw.profiles ?? []) if (x.id === profileId && isObject(x.share) && x.share.id === id) delete x.share;
        });
        log.info("share", "a share made to move a profile undone: the move failed", { profile: profileId, to, error: (e as Error).message });
      }
      throw e;
    } finally {
      this.moving.delete(id);
      this.unannounced.delete(id);
      this.moveDone.delete(id);
      done.resolve();
    }
    log.info("share", "a shared profile moved to another station", { profile: profileId, to, ...(keeps ? {} : { copy: "none: this station may not use it" }) });
    if (!keeps) {
      await this.deps.profileGone?.(profileId).catch((error) => log.warn("share", "moving sessions off a profile moved away failed", { profile: profileId, error: (error as Error).message }));
      this.deps.changed();
    }
    await this.reconcile();
    return { id: there, share: id };
  }

  /// Profile `profileId` lent to station `to` for a move's sake, this station staying its host: shared with it (with this
  /// station and `to` alone where it is not shared; `to` added where it is shared with stations it is not among), and
  /// `to` told so directly, answered once it has its copy (`share.borrow`); refused in words where it does not answer,
  /// what was changed here for it undone. What it changed, for `unlend` to undo.
  async lendTo(profileId: string, to: string): Promise<{ share: string; made: boolean; widened: boolean }> {
    const p = this.profiles().find((x) => x.id === profileId);
    if (!p) throw new Error(`unknown profile ${profileId}`);
    if (isObject(p.share) && p.share.borrowed === true) throw new Error("this profile is another station's");
    const me = this.me();
    if (me === null) throw new Error("this station is in no workspace");
    let made = false;
    let widened = false;
    if (!isObject(p.share)) {
      await this.shareProfile(profileId, true, [me, to], null, "a move");
      made = true;
    } else if (Array.isArray(p.share.allow) && !p.share.allow.includes(to)) {
      await this.shareProfile(profileId, true, [...p.share.allow, to], null, "a move");
      widened = true;
    }
    const now = this.profiles().find((x) => x.id === profileId)!;
    const share = String(now.share.id);
    // (its account read first: its version and allowance's revision then of one moment)
    const email = now.access?.kind === "subscription" ? await this.emailOf(now) : null;
    const state = this.readState();
    const version = state.hosted[share]?.version ?? 1;
    try {
      await this.deps.ask(to, null, {
        method: "share.borrow", id: share, version, profile: portable(now), email,
        allow: Array.isArray(now.share.allow) ? now.share.allow : null, workspaces: this.sharedIn(now), quotaRevision: state.hosted[share]?.quotaRevision ?? 0,
      });
      this.told(share, to, version);
    } catch (e) {
      await this.unlend(share, to, made, widened).catch(() => {});
      throw e;
    }
    return { share, made, widened };
  }

  /// What `lendTo` changed undone, this station its host: the share made for it undone, or `to` taken out of those it
  /// was added to; `to` told so as the sharing tells it (now, or once it is heard from).
  async unlend(share: string, to: string, made: boolean, widened: boolean): Promise<void> {
    const p = this.profiles().find((x) => isObject(x.share) && x.share.id === share && x.share.borrowed !== true);
    if (p === undefined) return;
    if (made) await this.shareProfile(String(p.id), false, null, null, "a move done with it");
    else if (widened && Array.isArray(p.share.allow)) await this.shareProfile(String(p.id), true, p.share.allow.filter((x: string) => x !== to), null, "a move done with it");
  }

  /// A share lent to this station by its host for a move (`lendTo`): its copy placed here before this answers.
  private async borrow(peer: string, id: string, request: Json): Promise<Json> {
    if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
    if (this.shares().has(id)) return { borrowed: true };
    const me = this.me();
    const allow: string[] | null = Array.isArray(request?.allow) ? request.allow : null;
    if (allow !== null && (me === null || !allow.includes(me))) throw new Error("this station is not among those it is shared with");
    const state = this.readState();
    // (a copy put in the place of what was had, never that one changed where it is: a pass of `reconcile` waiting on its
    // host holds it, and finds by that it was taken over, as `heard` does)
    const before = state.borrowed[id];
    const had: Borrowed = before
      ? { ...before, host: peer, allow }
      : { version: -1, hash: "", kind: "profile", name: String(request?.profile?.name ?? id), host: peer, allow, stale: true };
    const home = await this.placeProfile(id, had, request);
    had.version = Number(request?.version ?? 0);
    had.quotaRevision = Number(request?.quotaRevision ?? 0);
    had.stale = false;
    state.borrowed[id] = had;
    this.writeState(state);
    this.checked.add(id);
    await this.placedHome(home);
    void this.reconcile();
    return { borrowed: true };
  }

  /// A share a move made (`moveProfile` `shareFirst`) undone once its login is home again (move/accounts.ts `back`): no
  /// longer shared, each station told so letting go of its copy, where it is this station's again under that share and
  /// allowed to none but `stations` (the two of the move). One a person opened to another station meanwhile (or to
  /// every station) stays shared, and the log says so: what a person gave is not taken away. True: undone.
  async unshareMoved(share: string, stations: string[]): Promise<boolean> {
    const p = this.profiles().find((x) => isObject(x.share) && x.share.id === share && x.share.borrowed !== true);
    if (p === undefined) {
      log.info("share", "a share a move made is not undone: this station does not host it", { share });
      return false;
    }
    const allow: string[] | null = Array.isArray(p.share.allow) ? p.share.allow : null;
    if (allow === null || allow.some((s) => !stations.includes(s))) {
      log.info("share", "a share a move made stays shared: a person allowed other stations since", { profile: p.id, share, allow: allow === null ? "every station" : allow.map((s) => s.slice(0, 8)).join(",") });
      return false;
    }
    await this.shareProfile(String(p.id), false, null, null, "a move back");
    return true;
  }

  /// A profile not shared moved to `to`: the other station takes it as its own, then it is gone from here.
  private async moveOwn(p: Json, to: string, ws: string, credentials: Record<string, string>, t: (key: string, args?: Record<string, unknown>) => string, lang: Lang): Promise<{ id: string }> {
    const key = `own:${p.id}`;
    if (this.moving.has(key)) throw new Said(t("station.share.moving"));
    this.moving.add(key);
    let there: string;
    try {
      const answer = await this.deps.ask(to, ws, { method: "share.take", own: true, profileId: p.id, profile: { ...portable(p), access: p.access }, served: this.sharedIn(p), lang, email: await this.emailOf(p), credentials });
      if (answer?.taken !== true || typeof answer.id !== "string") throw new Said(t("station.share.moveNotTaken"));
      there = answer.id;
      // (the other has it now: the login here goes, so that one station alone renews it)
      const home = this.home(p);
      for (const name of Object.keys(credentials)) await rm(join(home, name), { force: true });
      await this.deps.config.updateSoon((raw) => {
        raw.profiles = (Array.isArray(raw.profiles) ? raw.profiles : []).filter((x: Json) => x?.id !== p.id);
      });
    } finally {
      this.moving.delete(key);
    }
    log.info("share", "a profile moved to another station", { profile: p.id, to, there });
    await this.deps.profileGone?.(p.id).catch((error) => log.warn("share", "moving sessions off a profile moved away failed", { profile: p.id, error: (error as Error).message }));
    this.deps.changed();
    return { id: there };
  }

  /// A profile's id here for one handed over as `wanted` there: that id where it is free, else the next free one of it.
  private idFor(wanted: unknown, fallback: string): string {
    const taken = new Set(this.profiles().map((x) => String(x.id)));
    const base = typeof wanted === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(wanted) ? wanted : fallback;
    let id = base;
    for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
    return id;
  }

  /// The joined workspaces of this station's a profile handed over is withheld from: those of them it did not serve on
  /// the station it came from (`served`, as `sharedIn` says them there), so that it serves here no workspace it did not
  /// serve there. Refused, in words, where it did not serve this station's home workspace (which no profile is withheld
  /// from). Null where the other station did not say (one from before): as before.
  private withheldFor(served: unknown, lang: unknown): string[] | null {
    if (!Array.isArray(served)) return null;
    const home = this.deps.cloud.home();
    if (home !== null && !served.includes(home)) {
      const l: Lang = lang === "zh" || lang === "en" ? lang : stationLang();
      throw new Refused(tr(l, "station.share.moveHome", { workspaces: served.join(", ") }));
    }
    return this.deps.cloud.memberships().map((m) => m.workspace).filter((w) => w !== home && !served.includes(w));
  }

  /// The login files handed over with a profile, written in its home here (only those its runtime signs in with).
  private async writeSignIns(home: string, given: Json, credentials: unknown) {
    const allowed = new Set(signInFiles(given));
    for (const [name, data] of Object.entries(isObject(credentials) ? credentials : {})) {
      if (!allowed.has(name) || typeof data !== "string") continue;
      const path = join(home, name);
      try {
        if ((await lstat(path)).isSymbolicLink()) await unlink(path);
      } catch {}
      await writePrivateSoon(path, Buffer.from(data, "base64"));
    }
  }

  /// What `taken` keeps is read by `takeOwn` alone, for the same hand-over asked again (its answer lost), and only while
  /// the profile it names is here: one whose profile is gone (moved on, removed) is over, and goes.
  private forgetTaken(state: State) {
    const ids = new Set(this.profiles().map((x) => x?.id));
    for (const [asked, id] of Object.entries(state.taken ?? {})) if (!ids.has(id)) delete state.taken![asked];
  }

  /// A profile not shared handed over by another station of a workspace both are in: this station's own from now on,
  /// under the id it had there where that is free. One of the same account here already (or taken before, its answer
  /// lost) is the one taken.
  private async takeOwn(peer: string, request: Json): Promise<Json> {
    const given = isObject(request.profile) ? request.profile : null;
    if (!given || typeof given.runtime !== "string" && given.runtime !== undefined) throw new Error("nothing handed over");
    const state = this.readState();
    const asked = `${peer}/${String(request.profileId ?? "")}`;
    const before = state.taken?.[asked];
    if (before !== undefined && this.profiles().some((x) => x.id === before)) return { taken: true, id: before };
    const email = typeof request.email === "string" && request.email !== "" ? request.email : null;
    let same: Json | undefined;
    for (const x of email === null ? [] : this.profiles()) {
      if (x.machine !== true && !(isObject(x.share) && x.share.borrowed === true) && x.runtime === given.runtime && x.access?.kind === given.access?.kind && (await this.emailOf(x)) === email) {
        same = x;
        break;
      }
    }
    if (same !== undefined) return { taken: true, id: same.id, had: true };
    const withheld = this.withheldFor(request.served, request.lang);
    const localId = this.idFor(request.profileId, `moved-${randomBytes(4).toString("hex")}`);
    const home = join(this.deps.data, "homes", localId);
    // The login written first, then the profile and what it was taken as, in this share's turn (`serially`): nothing of
    // the shares reads one without the other.
    await mkdir(home, { recursive: true });
    await this.writeSignIns(home, given, request.credentials);
    await this.deps.config.updateSoon((raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const made: Json = { ...portable(given), access: given.access, id: localId, home: `homes/${localId}` };
      if (withheld !== null && withheld.length > 0) made.withheld = withheld;
      if (!isObject(made.env)) made.env = {};
      list.push(made);
      raw.profiles = list;
    });
    (state.taken ??= {})[asked] = localId;
    this.forgetTaken(state);
    this.writeState(state);
    log.info("share", "a profile handed over to this station", { id: localId, from: peer });
    this.deps.changed();
    return { taken: true, id: localId };
  }

  /// Told as a shared profile is handed over to this station to host (share `id`, from `peer`): a move's (move/
  /// accounts.ts) undoes the share its trip made once the login is home again, by whatever route it came.
  onHosted: ((id: string, peer: string) => void) | null = null;

  /// A profile handed over by the station that has it (one this station borrows it from, or any station of its
  /// workspaces for one not seen here).
  /// One at a time (`serially`, with what else changes `state.hosted`): what one looked at to decide (its id here, a copy
  /// it had, one of the same account) is as it was when it is written.
  private take(peer: string, request: Json): Promise<Json> {
    return this.serially(() => (request?.own === true ? this.takeOwn(peer, request) : this.takeShared(peer, request)));
  }

  private async takeShared(peer: string, request: Json): Promise<Json> {
    const id = String(request?.id ?? "");
    if (!/^sh-[0-9a-z]{10,40}$/.test(id)) throw new Error("bad share id");
    const state = this.readState();
    const had = state.borrowed[id];
    if (had && had.host !== peer) throw new Error("only the station that has it can hand it over");
    const mine = this.profiles().find((x) => isObject(x.share) && x.share.id === id && x.share.borrowed !== true);
    if (this.shares().has(id)) return { taken: true, ...(mine ? { id: mine.id } : {}) };
    const given = isObject(request.profile) ? request.profile : null;
    if (!given) throw new Error("nothing handed over");
    // (the workspaces it served there, and no more, as it is this station's to share now)
    const withheld = this.withheldFor(request.served, request.lang);
    // (the copy here keeps its id; else the id it had there, where that is free here)
    const existing = this.profiles().find((x) => isObject(x.share) && x.share.id === id);
    const localId = existing?.id ?? (typeof request.profileId === "string" ? this.idFor(request.profileId, id) : id);
    const home = join(this.deps.data, "homes", localId);
    // The login written first, then the profile and the share in one step: nothing reads one without the other.
    await mkdir(home, { recursive: true });
    await this.writeSignIns(home, given, request.credentials);
    const allow = Array.isArray(request.allow) ? request.allow : null;
    const made: Json = { ...portable(given), access: given.access, id: localId, home: `homes/${localId}`, share: { id, allow } };
    if (withheld !== null && withheld.length > 0) made.withheld = withheld;
    if (!isObject(made.env)) made.env = {};
    // (hashed as it will be, its login written: the profile, the copy let go and the share then, in this share's turn)
    const hash = await this.profileHash(made);
    await this.deps.config.updateSoon((raw) => {
      const list: Json[] = Array.isArray(raw.profiles) ? raw.profiles : [];
      const at = list.findIndex((x) => x.id === localId);
      if (at >= 0) list[at] = made;
      else list.push(made);
      raw.profiles = list;
    });
    const after = this.readState();
    delete after.borrowed[id];
    // The station that handed it over keeps a copy, at this version.
    const version = Number(request.version ?? 1);
    const quotaRevision = Number.isSafeInteger(request.quotaRevision) && request.quotaRevision >= 0 ? request.quotaRevision : 0;
    const resetKeys = Array.isArray(request.resetKeys) ? request.resetKeys.filter((key: unknown): key is string => typeof key === "string").slice(-32) : [];
    after.hosted[id] = { version, hash, kind: "profile", name: String(given.name ?? localId), allow, told: { [peer]: version }, quotaRevision, resetKeys };
    this.writeState(after);
    log.info("share", "a shared profile handed over to this station", { id, from: peer });
    void this.reconcile();
    this.onHosted?.(id, peer);
    return { taken: true, id: localId };
  }

  // ── the overview ──

  /// What the overview says of a profile's sharing (null: not shared). `workspace`: the viewer's; the stations it names
  /// (`users`, `allow`) are this one and those of that workspace only, so a member never sees a station of a workspace of
  /// this station's they are not in, which they could only show by its id (null: all of them).
  profileView(p: Json, workspace: string | null = null): ShareView | null {
    if (!isObject(p?.share) || typeof p.share.id !== "string") return null;
    const id = p.share.id as string;
    const me = this.me();
    const rosters = workspace === null ? null : this.rosters();
    const seen = (station: string) => rosters === null || station === me || rosters.get(station)?.includes(workspace!) === true;
    if (p.share.borrowed === true) {
      // The allowance is the host's, naming the stations of each of its workspaces: only this one's and the viewer's.
      const host = String(p.share.host ?? "");
      const had = this.readState().borrowed[id];
      return { id, role: "user", host, allow: had?.allow?.filter(seen) ?? null, reachable: !this.unreachable.has(host), pausable: true };
    }
    const told = this.readState().hosted[id]?.told ?? {};
    const users = Object.entries(told).filter(([k, v]) => v >= 0 && seen(k)).map(([k]) => k);
    return { id, role: "host", host: me ?? "", allow: Array.isArray(p.share.allow) ? p.share.allow.filter(seen) : null, reachable: null, users };
  }

  /// What the memory page says of a skill's sharing (null: not shared): by its name in the agents' skills.
  async skillView(name: string): Promise<ShareView | null> {
    const hosted = this.sharedSkills()[name];
    if (hosted) return { id: hosted.id, role: "host", host: this.me() ?? "", allow: hosted.allow, reachable: null };
    for (const [id, had] of Object.entries(this.readState().borrowed)) {
      if (had.kind !== "skill" || had.name !== name || !(await this.skillLinked(id, had))) continue;
      return { id, role: "user", host: had.host, allow: had.allow, reachable: !this.unreachable.has(had.host) };
    }
    return null;
  }
}
