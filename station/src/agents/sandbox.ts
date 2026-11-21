// Sandboxes as targets of station_task (托管重任务, 左子健 2026-11-13: 「直接写 station 配置就好吧，然后就多一个可以排任务的
// 目标」): each of config.json's `sandboxes` is an l4es front door (`{name}.WORKSPACE@host`, at a size of its operator's),
// listed by station_list and sent tasks by its name as a station is. Nothing is installed there and no agent runs there:
// the station takes the task itself (jobs/remote.ts `ask`), as its own job, and runs its command in a sandbox of the
// chat's (made on the first task, deleted by the front door once idle) through ./sandbox-bridge.mjs, which carries itself
// over ssh (the sandbox needs only node), copies the task's mirror there before the command and brings what the task
// brings back (`back`) here once it ends. The job's log, its exit and its notices are the station's own, as any job's.
// A sandbox of kind "colab" is a Google Colab VM with a GPU instead: from the station's Google Colab service profiles
// (`homes/<id>/colab-auth.json`, synced into bounded-ephemeral `<data>/colab/cli-homes/<id>/`), started for a task, kept
// warm a while for the chat's next and then stopped (../../assets/agents/colab-sandbox.mjs), the same bridge running the
// task there. When a station has at least one Google Colab profile and no explicit `kind: "colab"` entry in config.json,
// `colab-g4`, `colab-l4` and `colab-t4` are exposed automatically and advertised over the workspace mesh.
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { access, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { COLAB_AUTH_FILE, COLAB_SERVICE_ID } from "../accounts/colab.ts";
import { allowedIn, type Profile } from "../sessions/config.ts";
import { sandboxName } from "./sandbox-name.ts";
import type { Json } from "../store/store.ts";

/// How a sandbox is named as a station of station_task's: `sandbox:<its name>` (or `sandbox:<hostId>:<name>` across the mesh).
export const SANDBOX = "sandbox:";

/// Valid sandbox name pattern.
export const SANDBOX_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/;

/// The bridge the station runs in a sandbox job's place.
export const BRIDGE = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/sandbox-bridge.mjs", import.meta.url) : new URL("./sandbox-bridge.mjs", import.meta.url));
/// What takes a Colab VM for a task, runs it there through the bridge and hands the VM back (and stops idle ones).
export const COLAB = fileURLToPath(import.meta.url.endsWith(".ts") ? new URL("../../assets/agents/colab-sandbox.mjs", import.meta.url) : new URL("./colab-sandbox.mjs", import.meta.url));
/// The GPUs a Colab sandbox may name (colab-sandbox.mjs GPUS).
export const COLAB_GPUS = ["T4", "L4", "G4", "A100", "H100"] as const;
export type ColabGpu = (typeof COLAB_GPUS)[number];
/// Where the station keeps its Colab CLI venv, synced CLI homes and VM records (bounded-ephemeral, no authoritative credentials).
export const colabPool = (data: string) => join(data, "colab");

/// What the bridge says, and its exit code, when the connection to the sandbox was lost rather than the command
/// ending (sandbox-bridge.mjs `LOST`): a job is started again once.
export const CONNECTION_LOST = "sandbox: the connection to the sandbox was lost";
export const LOST_EXIT = 75;

/// One of config.json's `sandboxes`: an l4es front door (`target`, `size?`, `identity?`), or kind "colab" (`gpu`).
export type Sandbox =
  | { name: string; target: string; size?: string; identity?: string; kind?: "l4es" }
  | { name: string; kind: "colab"; gpu: ColabGpu };

export const isColab = (d: Sandbox): d is Extract<Sandbox, { kind: "colab" }> => d.kind === "colab";

/// Default Colab sandboxes exposed automatically when a station has >=1 usable Colab profile and no explicit `kind: "colab"` entry.
export const DEFAULT_COLAB_SANDBOXES: readonly Extract<Sandbox, { kind: "colab" }>[] = [
  { name: "colab-g4", kind: "colab", gpu: "G4" },
  { name: "colab-l4", kind: "colab", gpu: "L4" },
  { name: "colab-t4", kind: "colab", gpu: "T4" },
];

/// One Colab profile's credential file passed to colab-sandbox.mjs.
export type ColabAccount = { id: string; authFile: string };

/// Where a job runs in a sandbox: which (by its name), the chat (each has a sandbox of its own there), what is
/// brought back, and optionally the workspace (used to filter Colab profiles on spawn).
export type SandboxPlace = { sandbox: string; session: string; back: string[]; workspace?: string };

/// Parses a cross-station sandbox target `sandbox:<hostId>:<name>`; returns null for local `sandbox:<name>` or non-sandbox ids.
export function parseRemoteSandbox(station: string): { hostId: string; name: string } | null {
  if (!station.startsWith(SANDBOX)) return null;
  const rest = station.slice(SANDBOX.length);
  const colon = rest.indexOf(":");
  if (colon <= 0 || colon === rest.length - 1) return null;
  const hostId = rest.slice(0, colon);
  const name = rest.slice(colon + 1);
  if (name.includes(":") || !SANDBOX_NAME_RE.test(name)) return null;
  return { hostId, name };
}

/// config.json's `sandboxes` as the station takes them: those that are not well formed left out (`checkSandboxes` says
/// why as one is written).
export function sandboxesOf(raw: any): Sandbox[] {
  const list = Array.isArray(raw?.sandboxes) ? raw.sandboxes : [];
  return list.filter((s: unknown) => sandboxRefusal(s) === null).map((s: any): Sandbox =>
    s.kind === "colab"
      ? { name: s.name, kind: "colab", gpu: s.gpu }
      : {
          name: s.name,
          target: s.target,
          ...(s.kind === "l4es" ? { kind: "l4es" as const } : {}),
          ...(typeof s.size === "string" ? { size: s.size } : {}),
          ...(typeof s.identity === "string" ? { identity: s.identity } : {}),
        },
  );
}

/// Effective sandboxes for a workspace: config.json's `sandboxes`, plus `DEFAULT_COLAB_SANDBOXES` when
/// `colabAccountCount > 0` and config.json has no explicit `kind: "colab"` entry (skipping names taken by l4es).
export function effectiveSandboxes(raw: any, colabAccountCount: number): Sandbox[] {
  const configured = sandboxesOf(raw);
  if (colabAccountCount <= 0 || configured.some(isColab)) return configured;
  const taken = new Set(configured.map((s) => s.name.toLowerCase()));
  return [...configured, ...DEFAULT_COLAB_SANDBOXES.filter((d) => !taken.has(d.name.toLowerCase()))];
}

/// Whether `profile` serves `workspace` given the station's `homeWorkspace`.
export function profileServes(profile: Profile, workspace?: string | null, homeWorkspace?: string | null): boolean {
  const ws = workspace && workspace !== "" ? workspace : null;
  const home = homeWorkspace && homeWorkspace !== "" ? homeWorkspace : null;
  if (home !== null) return allowedIn(profile, ws, home);
  const share = profile.share as { borrowed?: unknown; workspaces?: unknown } | undefined;
  if (share?.borrowed === true && Array.isArray(share.workspaces) && ws !== null && !share.workspaces.includes(ws)) return false;
  return ws === null || !(profile.withheld ?? []).includes(ws);
}

const isColabProfile = (p: Profile): boolean => {
  const access = p.access as { kind?: unknown; service?: unknown } | undefined;
  return access?.kind === "service" && access.service === COLAB_SERVICE_ID;
};

/// Usable Google Colab accounts for `workspace`: enabled service:colab profiles serving `workspace` whose
/// `colab-auth.json` exists on disk, sorted by id.
export function colabAccountsFor(profiles: readonly Profile[], workspace?: string | null, homeWorkspace?: string | null): ColabAccount[] {
  const out: ColabAccount[] = [];
  for (const p of profiles) {
    if (!isColabProfile(p) || p.enabled === false || !profileServes(p, workspace, homeWorkspace)) continue;
    const authFile = join(p.home, COLAB_AUTH_FILE);
    if (!existsSync(authFile)) continue; // sync: one stat per configured Colab profile
    out.push({ id: p.id, authFile });
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/// All Google Colab accounts on disk (ignoring `enabled` and `withheld`), for `reapColab` so VMs held by
/// later-disabled or withheld profiles are still stopped cleanly.
export function allColabAccounts(profiles: readonly Profile[]): ColabAccount[] {
  const out: ColabAccount[] = [];
  for (const p of profiles) {
    if (!isColabProfile(p)) continue;
    const authFile = join(p.home, COLAB_AUTH_FILE);
    if (!existsSync(authFile)) continue; // sync: one stat per configured Colab profile
    out.push({ id: p.id, authFile });
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/// Throws what is wrong with config.json's `sandboxes`.
export function checkSandboxes(raw: any): void {
  const list = raw?.sandboxes;
  if (list === undefined || list === null) return;
  if (!Array.isArray(list)) throw new Error("sandboxes must be a list");
  const names = new Set<string>();
  for (const s of list) {
    const why = sandboxRefusal(s);
    if (why !== null) throw new Error(`sandboxes: ${why}`);
    if (names.has(s.name.toLowerCase())) throw new Error(`sandboxes: ${s.name} is named twice`);
    names.add(s.name.toLowerCase());
  }
}

/// Why `s` is no sandbox, or null.
function sandboxRefusal(s: any): string | null {
  if (s === null || typeof s !== "object") return "each is {name, target, size?, identity?} or {name, kind: \"colab\", gpu}";
  if (typeof s.name !== "string" || !SANDBOX_NAME_RE.test(s.name)) return "a name of letters, digits, ., _ and -";
  if (s.kind === "colab") return (COLAB_GPUS as readonly string[]).includes(s.gpu) ? null : `${s.name}'s gpu is one of Colab's: ${COLAB_GPUS.join(", ")}`;
  if (s.kind !== undefined && s.kind !== "l4es") return `${s.name}'s kind is "colab", "l4es", or none`;
  if (typeof s.target !== "string" || !/^[^\s@]*\{name\}[^\s@]*@[^\s@]+$/.test(s.target)) return `${s.name}'s target is its front door, like {name}.WORKSPACE@HOST`;
  if (s.size !== undefined && (typeof s.size !== "string" || !/^[a-z][a-z0-9-]{0,30}$/.test(s.size))) return `${s.name}'s size is the name of one of its operator's sizes`;
  if (s.identity !== undefined && (typeof s.identity !== "string" || !s.identity.startsWith("/"))) return `${s.name}'s identity is a key's absolute path`;
  return null;
}

/// What `describe` says of a sandbox in station_list.
export function sandboxDescribed(d: Sandbox, opts?: { accounts?: number; host?: string }): Json {
  if (isColab(d)) {
    const accounts = opts?.accounts ?? 0;
    const host = opts?.host;
    const where = host ? `station ${host}'s` : "this station's";
    return {
      kind: "sandbox",
      sandboxKind: "colab",
      gpu: d.gpu,
      accounts,
      ...(host !== undefined ? { host } : {}),
      tasks: true,
      files: true,
      sync: 1,
      sessions: false,
      messages: false,
      reads: false,
      chats: false,
      note: `A Google Colab VM with a ${d.gpu} GPU (Linux, root, x86-64), from ${where} Google Colab profile pool (${accounts} account${accounts === 1 ? "" : "s"}): started for this chat's first task (about 10 s; tasks wait in turn while every account holds its 3 of this GPU), kept 3 minutes after a task for the next, then stopped. Run GPU work there with station_task (dir to sync, back to bring results here); no screen. Manage Colab accounts in Settings → Profiles → Add Account → Google → Google Colab.`,
    };
  }
  return {
    kind: "sandbox", target: d.target, ...(d.size !== undefined ? { size: d.size } : {}),
    tasks: true, files: true, sync: 1, sessions: false, messages: false, reads: false, chats: false,
    note: "A sandbox: a Linux sandbox of this chat's, made for its first task and deleted once idle. Run builds and tests there with station_task (dir to sync, back to bring results here); no screen. The first time, its front door may ask for this station's key to be linked: the task's log gives the link a person opens.",
  };
}

/// The station's own ssh key for its sandboxes, and the host keys it took: made at the first task.
export const identityOf = (data: string) => join(data, "run", "sandbox", "id_ed25519");
const knownHostsOf = (data: string) => join(data, "run", "sandbox", "known_hosts");

/// The station's key made where it has none: the front door asks a person to link it once (its message, in the
/// task's log, names where).
export async function ensureIdentity(data: string): Promise<void> {
  const file = identityOf(data);
  if (existsSync(file)) return; // sync: one stat, the key made once
  await mkdir(join(data, "run", "sandbox"), { recursive: true });
  await new Promise<void>((resolve, reject) =>
    execFile("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "stillfail-station", "-f", file], (error) => (error ? reject(error) : resolve())));
}

/// ssh's command line to `destination` with `identity` (none: the station's key), up to (not including) the remote
/// command.
function sshTo(data: string, destination: string, identity = identityOf(data)): string[] {
  return [
    "ssh", "-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=accept-new",
    "-i", identity, "-o", "IdentitiesOnly=yes", "-o", `UserKnownHostsFile=${knownHostsOf(data)}`, destination,
  ];
}

/// The sandbox of chat `session` at `d`, by its name at the front door.
export const sandboxOf = (d: { name: string }, session: string) => sandboxName(`${d.name}|${session}`);

/// What the shell runs in place of a job's command in a sandbox: the bridge, which makes the sandbox (of its
/// size) when there is none, makes the station's data directory there at its path, copies `cwd` there and runs
/// `command` in it by sh; then the bridge again, with no command, to bring `back`'s paths here. The command's exit code
/// is the job's. `ports`: the station's own ports its command reaches on 127.0.0.1 (a job's notice), listened for there.
export function sandboxCommand(
  data: string,
  d: Sandbox,
  place: SandboxPlace,
  command: string,
  cwd: string,
  ports: number[],
  lostFile: string,
  node = process.execPath,
  accounts: readonly ColabAccount[] = [],
): string {
  if (isColab(d)) {
    const spec = {
      pool: colabPool(data),
      data,
      gpu: d.gpu,
      chat: place.session,
      command,
      cwd,
      ports,
      lostFile,
      back: place.back,
      bridge: BRIDGE,
      accounts,
    };
    return [node, COLAB, "run", JSON.stringify(spec)].map(quoted).join(" ");
  }
  const name = sandboxOf(d, place.session);
  const base = {
    ssh: sshTo(data, d.target.replace("{name}", name), d.identity),
    ...(d.size !== undefined ? { create: [...sshTo(data, d.target.replace("{name}", "_"), d.identity), "create", name, "--size", d.size] } : {}),
    root: { path: data },
    dirs: [cwd],
  };
  // The task's directory goes there; what the command makes there stays there (its build output, for the next task).
  const run = { ...base, ports, sync: [{ path: cwd, mode: "whole", back: false, dir: true }], program: "/bin/sh", args: ["-c", command], cwd, lostFile };
  // What it brings back, once it ended: a file or a directory, whichever it is there.
  const back = { ...base, sync: place.back.map((b) => ({ path: join(cwd, b), mode: "whole", push: false, dir: false })) };
  const bridge = (spec: object) => [node, BRIDGE, "host", JSON.stringify(spec)].map(quoted).join(" ");
  return place.back.length === 0 ? bridge(run) : `${bridge(run)}; code=$?; ${bridge(back)}; exit $code`;
}

/// How often the station looks for idle Colab VMs to stop (colab-sandbox.mjs KEEP_WARM_MS is 3 minutes).
export const COLAB_REAP_MS = 60_000;

/// Stops this station's idle Colab VMs (colab-sandbox.mjs `reap`), where it has any Colab profile or `<data>/colab/vms`.
export async function reapColab(data: string, accounts: readonly ColabAccount[], node = process.execPath): Promise<void> {
  const pool = colabPool(data);
  if (accounts.length === 0 && !(await access(join(pool, "vms")).then(() => true, () => false))) return;
  await new Promise<void>((resolve) => execFile(node, [COLAB, "reap", JSON.stringify({ pool, accounts })], { timeout: 10 * 60_000 }, () => resolve()));
}

/// `s` as one word of sh's.
const quoted = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;
