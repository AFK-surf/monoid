// The lock a workspace's vault goes by where the workspace is not in security mode: its members' own locks (the
// person logs this station keeps, mesh/person-chains.ts), each a person's devices, as one `LockState` with no chain of
// its own (`genesis` ""), whoever is known to be a member here named in it (mesh/seen-devices.ts). A vault is always
// encrypted and kept by its person's own devices (the user's word: 「一律走个人加密密钥库」), security mode on or not:
// with it on, the workspace's lock in force is the vault's (Cloud `vaultLock`), never this.
//
// Who is let in by it is only a person's own devices, each proving its key for this workspace (cloud/lock.ts `admit`);
// nobody signs a member or a role into it. Where a person keeps more than one log here (begun anew, or one brought by
// someone holding their credential), the log their vaults are already signed by is theirs, then the one their box
// certificate checks against, then the newest: so a log brought later takes neither their vaults nor the secrets kept
// for them.
import { type Device, type LockState, type Member, personFold } from "../../../shared/lock.ts";
import type { BoxCert, Vault } from "../vault/crypto.ts";

/// What the vault keeps of a workspace that this lock is made of: its vaults (whose owners and members it names, and
/// whose signatures say which of a person's logs is theirs) and its box certificates; `version` moves on as either is
/// written (vault/store.ts); `certOk` the vault's check of a box certificate against a lock (vault/crypto.ts, given:
/// the platform imports none of the parts but their types).
export type VaultsHeld = { version(): number; vaults(ws: string): Vault[]; boxes(ws: string): BoxCert[]; certOk(lock: LockState, cert: BoxCert): boolean };

/// What the lock is made of besides the vault: the person logs kept and the members known.
export type PersonalSources = {
  chains: { version(): number; every(): [string, unknown[]][] };
  members: { version(): number; members(ws: string): ReadonlyMap<string, string>; roles?(ws: string): ReadonlyMap<string, string> };
};

type Made = { key: string; state: LockState };
const made = new WeakMap<object, Map<string, Made>>();

/// Workspace `ws`'s vault lock made of its members' own locks, the same object while nothing it is made of changed
/// (GET /vault/requests reads whether it changed while it waited by that). `owner`: what the cache is kept by.
export function personalVaultLock(owner: object, ws: string, from: PersonalSources, held?: VaultsHeld): LockState {
  let of = made.get(owner);
  if (of === undefined) made.set(owner, (of = new Map()));
  const key = `${from.chains.version()}/${from.members.version()}/${held?.version() ?? "-"}`;
  const had = of.get(ws);
  if (had !== undefined && had.key === key) return had.state;
  const state = makeLock(ws, from, held);
  of.set(ws, { key, state });
  return state;
}

/// A person's devices as their log folds them, those of an app only (a web page keeps no vault).
type Folded = { genesis: string; head: string; at: number; chain: unknown[]; devices: { id: string; label: string; sign_key?: string; sign_keys: string[] }[] };

function fold(genesis: string, chain: unknown[], sub: string): Folded | null {
  try {
    const p = personFold(chain, sub) as unknown as { head: string; devices: { id: string; label: string; sign_key?: string; sign_keys?: string[] }[] };
    const last = chain.at(-1) as { at?: unknown } | undefined;
    return {
      genesis, head: p.head, at: typeof last?.at === "number" ? last.at : 0, chain,
      devices: p.devices.map((d) => ({ id: d.id, label: d.label, ...(typeof d.sign_key === "string" ? { sign_key: d.sign_key } : {}), sign_keys: Array.isArray(d.sign_keys) ? d.sign_keys : [] })),
    };
  } catch {
    return null;
  }
}

const subOf = (chain: unknown[]): string | null => {
  const ws = (chain[0] as { ws?: unknown } | undefined)?.ws;
  return typeof ws === "string" && ws.startsWith("person:") ? ws.slice("person:".length) : null;
};

/// The lock of one person's log alone, as `makeLock` names their devices: what a box certificate is checked by.
function lockOfOne(ws: string, sub: string, f: Folded): LockState {
  const devices = new Map<string, Device>();
  const signKeys = new Map<string, string[]>();
  for (const d of f.devices) {
    devices.set(d.id, { id: d.id, sub, kind: "app", label: d.label, ...(d.sign_key !== undefined ? { sign_key: d.sign_key } : {}), own: true });
    signKeys.set(d.id, d.sign_keys);
  }
  return bare(ws, new Map([[sub, { sub, email: "", role: "member" }]]), devices, signKeys, new Map([[sub, f.genesis]]));
}

function bare(ws: string, members: Map<string, Member>, devices: Map<string, Device>, signKeys: Map<string, string[]>, persons: Map<string, string>): LockState {
  return {
    ws, seq: 0, head: "", genesis: "", origins: [], rp_id: "", cloud_keys: null, members, devices, signKeys,
    passkeys: new Map(), signed: new Set([...devices.values()].map((d) => d.sub)), stations: new Map(), gateways: new Set(), persons, disabled: false,
  };
}

/// Which of `sub`'s logs is theirs here: the one an own vault of theirs is signed by, else the one their newest box
/// certificate checks against, else the newest.
function chosen(ws: string, sub: string, logs: Folded[], vaults: Vault[] | null, boxes: BoxCert[] | null, certOk: (lock: LockState, cert: BoxCert) => boolean): Folded {
  if (logs.length === 1) return logs[0]!;
  for (const v of vaults ?? []) {
    if (v.owner !== sub || v.deleted) continue;
    const key = v.sig?.key;
    const by = logs.find((l) => l.devices.some((d) => d.sign_keys.includes(key) || d.sign_key === key));
    if (by !== undefined) return by;
  }
  const certs = [...(boxes ?? [])].sort((a, b) => b.at - a.at);
  for (const cert of certs) {
    const by = logs.find((l) => l.devices.some((d) => d.id === cert.device) && certOk(lockOfOne(ws, sub, l), cert));
    if (by !== undefined) return by;
  }
  return [...logs].sort((a, b) => a.at - b.at).at(-1)!;
}

function selectLogs(ws: string, from: PersonalSources, held?: VaultsHeld): { vaults: Vault[] | null; picked: Map<string, Folded> } {
  const logs = new Map<string, Folded[]>();
  for (const [genesis, chain] of from.chains.every()) {
    const sub = subOf(chain);
    if (sub === null) continue;
    const f = fold(genesis, chain, sub);
    if (f === null) continue;
    const of = logs.get(sub) ?? [];
    of.push(f);
    logs.set(sub, of);
  }
  // (read only where they say something: a person with more than one log, or a vault's owners and members)
  const vaults = held === undefined ? null : held.vaults(ws);
  const several = [...logs.values()].some((l) => l.length > 1);
  const boxes = held === undefined || !several ? null : held.boxes(ws);
  const picked = new Map<string, Folded>();
  for (const [sub, of] of logs) {
    picked.set(sub, chosen(ws, sub, of, vaults, boxes?.filter((c) => of.some((l) => l.devices.some((d) => d.id === c.device))) ?? null, held?.certOk ?? (() => false)));
  }
  return { vaults, picked };
}

/// The personal chain selected for each member in `personalVaultLock` (for GET /vault/boxes outside security mode).
export function personalVaultChains(ws: string, from: PersonalSources, held?: VaultsHeld): Record<string, unknown[]> {
  const { picked } = selectLogs(ws, from, held);
  const out: Record<string, unknown[]> = {};
  for (const [sub, f] of picked) out[sub] = f.chain;
  return out;
}

function makeLock(ws: string, from: PersonalSources, held?: VaultsHeld): LockState {
  const emails = from.members.members(ws);
  const roles = from.members.roles?.(ws);
  const { vaults, picked } = selectLogs(ws, from, held);
  const members = new Map<string, Member>();
  const name = (sub: string) => {
    const role = roles?.get(sub);
    if (!members.has(sub)) members.set(sub, { sub, email: emails.get(sub) ?? "", role: (role === "owner" || role === "admin" || role === "member" || role === "viewer" ? role : "member") });
  };
  for (const sub of emails.keys()) name(sub);
  for (const v of vaults ?? []) {
    if (v.deleted) continue;
    name(v.owner);
    for (const m of v.members) name(m);
  }
  const devices = new Map<string, Device>();
  const signKeys = new Map<string, string[]>();
  const persons = new Map<string, string>();
  for (const [sub, f] of picked) {
    name(sub);
    persons.set(sub, f.genesis);
    for (const d of f.devices) {
      devices.set(d.id, { id: d.id, sub, kind: "app", label: d.label, ...(d.sign_key !== undefined ? { sign_key: d.sign_key } : {}), own: true });
      signKeys.set(d.id, d.sign_keys);
    }
  }
  return bare(ws, members, devices, signKeys, persons);
}
