// The vaults this station holds: GET/PUT vault/vaults, GET/PUT vault/items, GET/PUT vault/boxes. Only
// where the station pinned its workspace's lock (`vault_needs_lock` otherwise): the lock is what says which devices sign
// and whose they are, without it the control plane could add a device of its own and be given the keys. A member sees
// the vaults they are a member of and those vaults' items; each write is checked against the lock and the version it
// follows (vault/crypto.ts), and told to the members' streams as it is kept (`vault`, `vault-item`, `vault-box`; a
// member taken out of a vault is told `vault-gone`; a vault deleted is kept as its last version, `deleted`, its items
// gone). A vault is written on one station (its host) and copied to the
// others by its members' devices (`?copy=1`: a later version than the one held, not necessarily the next; one not later
// is answered with the one held, unchanged), so that agents on any station may ask for its secrets.
import { type LockState, type Member, admit } from "../../../../shared/lock.ts";
import type { Viewer } from "../../mesh/credential.ts";
import {
  type BoxCert, type DiscoverableVault, type Item, type JoinAsk, type JoinDismiss, type KeyAsk, type Vault,
  TAG, askOk, certOk, itemOk, itemSupersedes, joinAskOk, joinDismissOk, signedOk, signerOf, usableBoxKey, vaultOk, vaultSupersedes,
} from "../../vault/crypto.ts";
import { isDeletedVaultWrite, type VaultStore } from "../../vault/store.ts";
import type { Route } from "../admin.ts";
import type { Events, To } from "../events.ts";
import { type Answer, type Request, json, param } from "../request.ts";

export type VaultDeps = {
  vaults: VaultStore;
  /// The lock a workspace's vault goes by (Cloud `vaultLock`): its lock in force in security mode, else its members'
  /// own; null when there is none (or it is broken: nobody is admitted then). `viewer`: who asks, known by it from then on.
  lock(workspace: string, viewer?: Viewer): LockState | null;
  /// The personal chains selected for each member outside security mode (cloud/vault-lock.ts `personalVaultChains`).
  chains?(workspace: string): Record<string, unknown[]>;
  events?: Events;
  /// Wait for an older station's writes to stop; undefined means the handover is already complete.
  beforeWrite?(): false | Promise<boolean> | undefined;
  /// A checked certificate is held: seal its person's waiting saves to it (vault/secrets.ts `boxed`). False says a
  /// conflicting write delayed reboxing; the certificate is already held and its retry is scheduled there.
  boxed?(lock: LockState, cert: BoxCert): boolean | void;
};

/// A refusal with its code, which the core says as it is.
const refuse = (status: number, code: string, error: string, more: Record<string, unknown> = {}): Answer => json(status, JSON.stringify({ error, code, ...more }));

const NEEDS_LOCK = () => refuse(409, "vault_needs_lock", "the vault needs the workspace's security mode (its lock) pinned on this station");

function body(r: Request): unknown {
  try {
    return JSON.parse(r.body.toString("utf8"));
  } catch {
    return undefined;
  }
}

/// The lock device the request comes from, as a connection is admitted (cloud/lock.ts `admit`); null for none. (No
/// clock: only an app device has a box, and an app's approval does not run out.)
function deviceOf(lock: LockState, r: Request): string | null {
  const v = r.viewer;
  try {
    return admit(lock, { sub: v.sub, endpoint: v.device, base: v.lockDevice?.base, proof: v.lockDevice?.proof }, 0).device.id;
  } catch {
    return null;
  }
}

const sees = (vault: Vault, viewer: Viewer) =>
  vault.ws === viewer.workspace && Array.isArray(vault.members) && vault.members.includes(viewer.sub);
/// Whom a vault's changes are told to: its members.
const members = (vault: Vault): To => ({ workspace: vault.ws, subs: vault.members });
const isAdminRole = (role: string | undefined) => role === "owner" || role === "admin";
const MAX_DISCOVERABLE = 4;

function toDiscoverable(v: Vault): DiscoverableVault {
  return {
    id: v.id,
    ws: v.ws,
    name: v.name,
    scope: "workspace",
    owner: v.owner,
    memberCount: v.members.length,
    seq: v.seq,
    at: v.at,
  };
}

/// Active workspace vaults in `l.ws` that `viewerSub` is NOT yet a member of, read newest-first via the
/// `vaults_workspace_active` partial index (never scanning personal or deleted vaults). Verifies vault signature
/// and current owner/admin signer role (rather than full `vaultOk`) so a workspace vault with a removed device's
/// historical key remains discoverable.
function discoverableWorkspaceVaults(vaults: VaultStore, l: LockState, viewerSub: string): Vault[] {
  if (!(l.members instanceof Map) || !l.members.has(viewerSub)) return [];
  return vaults.activeWorkspaceVaults(l.ws, MAX_DISCOVERABLE, {
    maxScan: 64,
    accept: (v) => {
      if (v.ws !== l.ws || v.deleted || v.scope !== "workspace" || !Array.isArray(v.members) || v.members.includes(viewerSub)) return false;
      if (!signedOk(v, TAG.vault)) return false;
      const signer = signerOf(l, v.sig?.key);
      return signer !== null && isAdminRole(l.members.get(signer.sub)?.role);
    },
  });
}

function adminSubsOf(l: LockState, v: Vault): string[] {
  return v.members.filter((s) => isAdminRole(l.members.get(s)?.role));
}

/// Outside security mode (`genesis` ""), an authenticated workspace owner or admin may include workspace members who
/// have never connected to this station in a workspace vault (`PUT /vault/vaults`, including `?copy=1`). Add those
/// unseen subs as ordinary `"member"` entries on a temporary `LockState` for `vaultOk` only, never mutating `l`,
/// elevating roles, or adding devices/signKeys.
function workspaceCheckLock(l: LockState, prev: Vault | null, next: Vault): LockState {
  if (l.genesis !== "" || next.scope !== "workspace" || (prev !== null && prev.scope !== "workspace")) return l;
  if (!Array.isArray(next.members) || typeof next.sig?.key !== "string") return l;
  const signer = signerOf(l, next.sig.key);
  const role = signer === null ? undefined : l.members.get(signer.sub)?.role;
  if (role !== "owner" && role !== "admin") return l;
  let members: Map<string, Member> | null = null;
  for (const m of next.members) {
    if (typeof m !== "string" || m === "" || m.length > 200) continue;
    if (l.members.has(m) || members?.has(m)) continue;
    if (members === null) members = new Map(l.members);
    members.set(m, { sub: m, email: "", role: "member" });
  }
  return members === null ? l : { ...l, members };
}

export const routes = ({ vaults, lock, chains, events, boxed, beforeWrite }: VaultDeps): Route[] => {
  /// The lock of the viewer's workspace, or the refusal.
  const locked = (r: Request): LockState | Answer => lock(r.viewer.workspace, r.viewer) ?? NEEDS_LOCK();
  const isAnswer = (v: LockState | Answer): v is Answer => "status" in v;
  const tell = (event: string, data: unknown, of: string, to: To) => events?.tell(event, data, of, to);
  return [
    {
      method: "GET",
      pattern: /^\/vault\/vaults$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        const memberVaults = vaults.memberVaults(l.ws, r.viewer.sub).filter((v) => sees(v, r.viewer));
        const discoverable = discoverableWorkspaceVaults(vaults, l, r.viewer.sub).map(toDiscoverable);
        const payload = discoverable.length > 0 ? { vaults: memberVaults, discoverable } : { vaults: memberVaults };
        return json(200, JSON.stringify(payload));
      },
    },
    {
      method: "GET",
      pattern: /^\/vault\/discover$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        const discoverable = discoverableWorkspaceVaults(vaults, l, r.viewer.sub).map(toDiscoverable);
        return json(200, JSON.stringify({ discoverable }));
      },
    },
    {
      // The latest versions of vaults the viewer was a member of, each shown by a version naming them that its owner's
      // or a workspace admin's device signed (`held`): how a device taken out of a vault (or one that was away as it
      // was) knows it was, rather than taking a station's not listing it for it. Nothing for one the viewer was never
      // shown. Matches scope first and blocks self-forged witnesses by an unjoined workspace admin.
      method: "POST",
      pattern: /^\/vault\/vaults\/latest$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        const held = (body(r) as { held?: unknown } | null)?.held;
        if (!Array.isArray(held) || held.length > 256) return refuse(400, "vault_invalid", "held is a list of vault versions");
        const latest: Vault[] = [];
        for (const h of held as Vault[]) {
          if (h === null || typeof h !== "object" || typeof h.id !== "string" || h.ws !== r.viewer.workspace || !Array.isArray(h.members) || !h.members.includes(r.viewer.sub)) continue;
          if (!signedOk(h, TAG.vault)) continue;
          const signer = signerOf(l, h.sig.key);
          if (signer === null) continue;
          const isWs = h.scope === "workspace";
          const role = l.members.get(signer.sub)?.role;
          if (isWs ? !isAdminRole(role) : signer.sub !== h.owner) continue;
          const v = vaults.vault(l.ws, h.id);
          if (v === null) continue;
          if ((v.scope ?? null) !== (h.scope ?? null)) continue;
          if (!Number.isSafeInteger(h.seq) || h.seq > v.seq) continue;
          if (isWs) {
            if (!v.members.includes(signer.sub) && signer.sub !== v.owner && signer.sub === r.viewer.sub) continue;
          } else if (v.owner !== h.owner) {
            continue;
          }
          latest.push(v);
        }
        return json(200, JSON.stringify({ vaults: latest }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/vaults$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const next = body(r) as Vault;
        if (next === null || typeof next !== "object" || typeof next.id !== "string" || !Array.isArray(next.members)) return refuse(400, "vault_invalid", "a vault, as JSON");
        if (next.ws !== r.viewer.workspace) return refuse(400, "vault_invalid", "a vault of another workspace");
        const copy = param(r, "copy") === "1";
        const approveSub = param(r, "approveJoinSub");
        const approveAtRaw = param(r, "approveJoinAt");
        const approveDevice = param(r, "approveJoinDevice");
        const approveBox = param(r, "approveJoinBox");
        const approveSig = param(r, "approveJoinSig");
        let approveJoin: { sub: string; at: number; device: string; box: string; sig: string } | undefined;
        if (
          approveSub !== undefined || approveAtRaw !== undefined || approveDevice !== undefined
          || approveBox !== undefined || approveSig !== undefined
        ) {
          const atNum = Number(approveAtRaw);
          if (
            copy
            || !approveSub || approveSub.length > 200
            || !Number.isSafeInteger(atNum) || atNum < 0
            || !approveDevice || approveDevice.length > 128
            || !approveBox || !usableBoxKey(approveBox)
            || !approveSig || approveSig.length > 256
          ) {
            return refuse(400, "vault_invalid", "explicit join approval requires valid approveJoinSub, approveJoinAt, approveJoinDevice, approveJoinBox, and approveJoinSig");
          }
          approveJoin = { sub: approveSub, at: atNum, device: approveDevice, box: approveBox, sig: approveSig };
        }
        for (let attempt = 0; attempt < 3; attempt++) {
          const held = vaults.vaultSnapshot(l.ws, next.id), prev = held?.value ?? null;
          const checkLock = workspaceCheckLock(l, prev, next);
          const viewerSeesPrev = prev !== null && sees(prev, r.viewer);
          if (prev !== null && !viewerSeesPrev) {
            if (!copy) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
            // On ?copy=1 from a newly-added member spreading `next` to a lagging station, prove `next` itself is
            // validly signed and names `r.viewer` before touching `prev` or answering anything other than 404.
            if (!sees(next, r.viewer) || vaultOk(checkLock, null, next, true) !== null) {
              return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
            }
          }
          // Direct writes (`!copy`) to an existing workspace vault must be signed by an existing managing admin in
          // `prev.members`. Replication copies (`copy=1`) rely on `vaultOk` (consistent with workspace-vault admin
          // takeover semantics in `rules/src/vault/vault.mbt`) so lagging stations always catch up across key rotations
          // and newly-added admins without requiring an unbreakable historical trail.
          if (prev !== null && prev.scope === "workspace" && !copy) {
            const signer = typeof next.sig?.key === "string" ? signerOf(checkLock, next.sig.key) : null;
            if (signer === null || !prev.members.includes(signer.sub) || !isAdminRole(l.members.get(signer.sub)?.role)) {
              return viewerSeesPrev
                ? refuse(403, "vault_not_admin", "only an existing managing admin of this workspace vault may update it")
                : refuse(404, "vault_unknown", "no such vault here, or not one of yours");
            }
          }
          // A copy of a sibling is kept only if every station chooses it over the one currently held.
          let sibling = false;
          if (copy && prev !== null && Number.isSafeInteger(next.seq) && next.seq <= prev.seq) {
            if (next.seq < prev.seq || !vaultSupersedes(next, prev)) {
              return viewerSeesPrev ? json(200, JSON.stringify({ vault: prev })) : refuse(404, "vault_unknown", "no such vault here, or not one of yours");
            }
            sibling = true;
          }
          if (!copy && Number.isSafeInteger(next.seq) && next.seq !== (prev === null ? 0 : prev.seq + 1)) {
            return refuse(409, "vault_conflict", `seq ${prev === null ? 0 : prev.seq + 1} is the one that follows`, viewerSeesPrev ? { vault: prev } : {});
          }
          const scopeChanged = (next.scope ?? null) !== (prev?.scope ?? null);
          const ownerChanged = prev !== null && next.owner !== prev.owner &&
            !(next.scope === "workspace" && prev.scope === "workspace" && signerOf(l, next.sig?.key)?.sub === next.owner);
          const why = sibling
            ? vaultOk(checkLock, null, next, true) ?? (scopeChanged ? "a vault's scope does not change" : ownerChanged ? "a vault's owner does not change" : null)
            : vaultOk(checkLock, prev, next, copy);
          if (why !== null) return refuse(400, "vault_invalid", why);
          const addedSubs = next.scope === "workspace" && !next.deleted
            ? next.members.filter((m) => !(prev?.members ?? []).includes(m))
            : [];
          if (approveJoin !== undefined && (!next.members.includes(approveJoin.sub) || next.scope !== "workspace" || next.deleted)) {
            return refuse(400, "vault_invalid", "approveJoinSub must be included in an active workspace vault's members");
          }
          if (
            approveJoin !== undefined
            && !next.keys.some((k) => k.cert.device === approveJoin.device && k.cert.box === approveJoin.box)
          ) {
            return refuse(400, "vault_invalid", "explicit join approval must wrap the vault key for the approved device and box");
          }
          let writeRes: "saved" | "conflict" | "join_cancelled";
          try {
            if (approveJoin !== undefined || addedSubs.length > 0) {
              const targetVault = prev ?? next;
              writeRes = vaults.putVaultChecked(next, held?.body ?? null, {
                addedSubs,
                approveJoin,
                isValidAsk: (a) => joinAskOk(l, a) === null,
                isActiveDismiss: (d) => joinDismissOk(l, targetVault, d) === null,
              });
            } else {
              writeRes = vaults.putVaultIf(next, held?.body ?? null) ? "saved" : "conflict";
            }
          } catch (error) {
            if (!isDeletedVaultWrite(error)) throw error;
            continue;
          }
          if (writeRes === "join_cancelled") {
            return refuse(409, "join_cancelled", "that join request was cancelled or superseded before approval");
          }
          if (writeRes === "conflict") continue;
          tell("vault", next, `vault\0${next.id}`, members(next));
          const gone = (prev?.members ?? []).filter((m) => !next.members.includes(m));
          const goneDevices = gone.length === 0 ? [] : [...l.devices.values()].filter((d) => gone.includes(d.sub)).map((d) => d.id);
          if (!next.deleted) vaults.pruneAsks(next.ws, next.id, next.keys, goneDevices);
          if (gone.length > 0) tell("vault-gone", { id: next.id, vault: next }, `vault-gone\0${next.id}`, { workspace: next.ws, subs: gone });
          if (next.scope === "workspace") {
            // Emitted AFTER `vault-gone` so removed members never have discovery cleared by stale membership; carries
            // zero secret or member payload (receivers re-read under live auth).
            tell("vault-discover", { vault: next.id, deleted: Boolean(next.deleted) }, `vault-discover\0${next.ws}\0${next.id}`, { workspace: next.ws });
            if (addedSubs.length > 0) {
              const notifySubs = [...new Set([...adminSubsOf(l, next), ...addedSubs])];
              tell("vault-joins-changed", { vault: next.id }, `vault-joins-changed\0${next.ws}\0${next.id}`, { workspace: next.ws, subs: notifySubs });
            }
          }
          return json(200, JSON.stringify({ vault: next }));
        }
        const current = vaults.vault(l.ws, next.id);
        if (current === null || !sees(current, r.viewer)) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
        return refuse(409, "vault_conflict", "the vault changed while it was being written", { vault: current });
      },
    },
    {
      method: "GET",
      pattern: /^\/vault\/items$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        // One vault's (`vault=`), or those of every vault the member is in.
        const of = param(r, "vault");
        const candidates = of === undefined ? vaults.memberVaults(l.ws, r.viewer.sub) : [vaults.vault(l.ws, of)].filter((v): v is Vault => v !== null);
        const seen = candidates.filter((v) => sees(v, r.viewer) && (of === undefined || v.id === of));
        if (of !== undefined && seen.length === 0) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
        return json(200, JSON.stringify({ items: seen.flatMap((v) => vaults.items(l.ws, v.id)) }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/items$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const next = body(r) as Item;
        if (next === null || typeof next !== "object" || typeof next.vault !== "string" || typeof next.id !== "string") return refuse(400, "vault_invalid", "an item, as JSON");
        const copy = param(r, "copy") === "1";
        for (let attempt = 0; attempt < 3; attempt++) {
          const heldVault = vaults.vaultSnapshot(l.ws, next.vault), vault = heldVault?.value ?? null;
          if (vault === null || !sees(vault, r.viewer)) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
          if (vault.deleted) return refuse(404, "vault_unknown", "that vault was deleted");
          const held = vaults.itemSnapshot(l.ws, vault.id, next.id), prev = held?.value ?? null;
          let sibling = false;
          if (copy && prev !== null && Number.isSafeInteger(next.version) && next.version <= prev.version) {
            if (next.version < prev.version || !itemSupersedes(next, prev)) return json(200, JSON.stringify({ item: prev }));
            sibling = true;
          }
          if (!copy && Number.isSafeInteger(next.version) && next.version !== (prev === null ? 0 : prev.version + 1)) {
            return refuse(409, "vault_conflict", `version ${prev === null ? 0 : prev.version + 1} is the one that follows`, { item: prev });
          }
          const why = itemOk(l, vault, sibling ? null : prev, next, copy);
          if (why !== null) return refuse(400, "vault_invalid", why);
          try {
            if (!vaults.putItemIf(next, heldVault!.body, held?.body ?? null)) continue;
          } catch (error) {
            if (!isDeletedVaultWrite(error)) throw error;
            continue;
          }
          tell("vault-item", next, `vault-item\0${vault.id}\0${next.id}`, members(vault));
          return json(200, JSON.stringify({ item: next }));
        }
        return refuse(409, "vault_conflict", "the vault or item changed while it was being written");
      },
    },
    {
      method: "GET",
      pattern: /^\/vault\/boxes$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        // Only those of devices still in the lock.
        // A small lock can address its devices by the existing primary key, leaving removed devices' certificates
        // unread. For a larger lock the certificate table may be smaller than the device list, so scan it as before.
        const boxes = l.devices.size <= 32 ? vaults.boxesFor(l.ws, [...l.devices.keys()]) : vaults.boxes(l.ws);
        const kept = boxes.filter((c) => certOk(l, c) === null);
        if (l.genesis === "") {
          const roles: Record<string, string> = {};
          for (const [sub, m] of l.members) roles[sub] = m.role;
          const rawChains = chains?.(l.ws) ?? {};
          const memberChains: Record<string, unknown[]> = {};
          for (const [sub, ch] of Object.entries(rawChains)) if (l.members.has(sub)) memberChains[sub] = ch;
          return json(200, JSON.stringify({ boxes: kept, chains: memberChains, roles }));
        }
        return json(200, JSON.stringify({ boxes: kept }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/boxes$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const cert = body(r) as BoxCert;
        const why = certOk(l, cert);
        if (why !== null) return refuse(400, "vault_invalid", why);
        if (!usableBoxKey(cert.box)) return refuse(400, "vault_invalid", "a box certificate's box is a canonical usable x25519 key");
        // Published by the device itself, as the lock admits it: a signing key alone (an admin's, who put a device in
        // under someone's name) does not publish a box that the person's secrets would be sealed to.
        if (deviceOf(l, r) !== cert.device) return refuse(403, "vault_not_device", "a device publishes its own box certificate");
        for (let attempt = 0; attempt < 3; attempt++) {
          const held = vaults.boxSnapshot(l.ws, cert.device), had = held?.value ?? null;
          // An older one than held changes nothing, including when it was replaced during this write.
          if (had !== null && had.at > cert.at) {
            // A prior attempt may have stored this newer certificate but been unable to finish reboxing its saves.
            if (had.ws === l.ws && had.device === cert.device && certOk(l, had) === null && boxed?.(l, had) === false)
              return refuse(503, "vault_busy", "the box certificate or a pending request changed while it was being reboxed");
            return json(200, JSON.stringify({ box: had }));
          }
          if (!vaults.putBoxIf(cert, held?.body ?? null)) continue;
          tell("vault-box", cert, `vault-box\0${cert.device}`, { workspace: cert.ws });
          if (boxed?.(l, cert) === false) return refuse(503, "vault_busy", "the box certificate or a pending request changed while it was being reboxed");
          return json(200, JSON.stringify({ box: cert }));
        }
        return refuse(503, "vault_busy", "the box certificate changed while it was being written");
      },
    },
    {
      method: "GET",
      pattern: /^\/vault\/asks$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        const of = param(r, "vault");
        const candidates = of === undefined ? vaults.memberVaults(l.ws, r.viewer.sub) : [vaults.vault(l.ws, of)].filter((v): v is Vault => v !== null);
        const seen = candidates.filter((v) => sees(v, r.viewer) && !v.deleted && (of === undefined || v.id === of));
        if (of !== undefined && seen.length === 0) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
        const byId = new Map(seen.map((v) => [v.id, v]));
        const activeDevices = [...l.devices.keys()];
        const kept = vaults.asksForVaults(l.ws, [...byId.keys()], 256, {
          devices: activeDevices,
          perVault: 64,
          accept: (a) => {
            if (askOk(l, a) !== null) return false;
            const v = byId.get(a.vault);
            const owner = l.devices.get(a.device)?.sub;
            if (v === undefined || owner === undefined || !v.members.includes(owner)) return false;
            return !v.keys.some((k) => k.cert.device === a.device && k.cert.box === a.box);
          },
        });
        return json(200, JSON.stringify({ asks: kept }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/asks$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const next = body(r) as KeyAsk;
        const why = askOk(l, next);
        if (why !== null) return refuse(400, "vault_invalid", why);
        if (deviceOf(l, r) !== next.device) return refuse(403, "vault_not_device", "a device publishes its own key ask");
        for (let attempt = 0; attempt < 3; attempt++) {
          const heldVault = vaults.vaultSnapshot(l.ws, next.vault), vault = heldVault?.value ?? null;
          if (vault === null || !sees(vault, r.viewer) || vault.deleted) return refuse(404, "vault_unknown", "no such vault here, or not one of yours");
          if (vault.keys.some((k) => k.cert.device === next.device && k.cert.box === next.box)) {
            return json(200, JSON.stringify({ ask: next }));
          }
          const held = vaults.askSnapshot(l.ws, next.vault, next.device), had = held?.value ?? null;
          // An older-or-equal valid ask changes nothing; an invalidated ask (e.g. rotated signing key) is always replaced.
          if (had !== null && had.at >= next.at && askOk(l, had) === null) return json(200, JSON.stringify({ ask: had }));
          if (!vaults.putAskIf(next, heldVault!.body, held?.body ?? null)) continue;
          tell("vault-ask", next, `vault-ask\0${next.vault}\0${next.device}`, { workspace: vault.ws, subs: vault.members, vault: vault.id });
          return json(200, JSON.stringify({ ask: next }));
        }
        return refuse(503, "vault_busy", "the key ask changed while it was being written");
      },
    },
    {
      method: "GET",
      pattern: /^\/vault\/joins$/,
      handle: async (r) => {
        const l = locked(r);
        if (isAnswer(l)) return l;
        const of = param(r, "vault");
        const dismissAfterVault = param(r, "dismissAfterVault");
        const dismissAfterSub = param(r, "dismissAfterSub");
        const cancelledAfterVault = param(r, "cancelledAfterVault");
        const cancelledAfterAtRaw = param(r, "cancelledAfterAt");
        const cancelledAfterSub = param(r, "cancelledAfterSub");
        const cancelledAfterAt = cancelledAfterAtRaw !== undefined && /^\d+$/.test(cancelledAfterAtRaw) ? Number(cancelledAfterAtRaw) : undefined;
        const viewerIsAdmin = isAdminRole(l.members.get(r.viewer.sub)?.role);
        const managedVaults: Vault[] = [];
        if (viewerIsAdmin) {
          const candidates = of === undefined ? vaults.memberVaults(l.ws, r.viewer.sub) : [vaults.vault(l.ws, of)].filter((v): v is Vault => v !== null);
          for (const v of candidates) {
            if (sees(v, r.viewer) && !v.deleted && v.scope === "workspace" && (of === undefined || v.id === of)) managedVaults.push(v);
          }
        }
        const discoverable = discoverableWorkspaceVaults(vaults, l, r.viewer.sub).filter((v) => of === undefined || v.id === of);
        if (of !== undefined && managedVaults.length === 0 && discoverable.length === 0) {
          return refuse(404, "vault_unknown", "no such workspace vault here");
        }
        const managedById = new Map(managedVaults.map((v) => [v.id, v]));
        const joins: JoinAsk[] = [];
        const dismisses: JoinDismiss[] = [];
        let nextDismissCursor: { vault: string; sub: string } | undefined;
        let nextCancelledCursor: { vault: string; at: number; sub: string } | undefined;
        if (managedVaults.length > 0) {
          const managedIds = [...managedById.keys()];
          const joinsPaged = vaults.joinsForVaults(l.ws, managedIds, 128, {
            perVault: 64,
            perVaultCancelled: 64,
            cancelledLimit: 64,
            perVaultScan: 128,
            maxScan: 512,
            cancelledMaxScan: 512,
            cancelledAfterVault,
            cancelledAfterAt,
            cancelledAfterSub,
            accept: (a, joinedUpTo, dismiss) => {
              if (joinAskOk(l, a) !== null) return false;
              const v = managedById.get(a.vault);
              if (v === undefined || v.members.includes(a.sub) || !l.members.has(a.sub)) return false;
              if (a.at <= joinedUpTo) return false;
              if (a.state === "pending" && dismiss !== null && joinDismissOk(l, v, dismiss) === null && a.at <= dismiss.upTo) {
                return false;
              }
              return true;
            },
          });
          joins.push(...joinsPaged.joins);
          nextCancelledCursor = joinsPaged.nextCancelledCursor;
          const dismissRes = vaults.joinDismissesForVaults(l.ws, managedIds, 64, {
            afterVault: dismissAfterVault,
            afterSub: dismissAfterSub,
            accept: (d) => {
              const v = managedById.get(d.vault);
              return v !== undefined && joinDismissOk(l, v, d) === null;
            },
          });
          dismisses.push(...dismissRes.dismisses);
          nextDismissCursor = dismissRes.nextCursor;
        }
        if (discoverable.length > 0) {
          const own = vaults.ownJoinsForVaults(l.ws, discoverable.map((v) => v.id), r.viewer.sub);
          const discById = new Map(discoverable.map((v) => [v.id, v]));
          for (const j of own.joins) {
            if (joinAskOk(l, j, true) === null) joins.push(j);
          }
          for (const d of own.dismisses) {
            const v = discById.get(d.vault);
            if (v !== undefined && joinDismissOk(l, v, d) === null) dismisses.push(d);
          }
        }
        const out = {
          joins,
          dismisses,
          ...(nextDismissCursor !== undefined ? { nextDismissCursor } : {}),
          ...(nextCancelledCursor !== undefined ? { nextCancelledCursor } : {}),
        };
        return json(200, JSON.stringify(out));
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/joins$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const next = body(r) as JoinAsk;
        const why = joinAskOk(l, next);
        if (why !== null) return refuse(400, "vault_invalid", why);
        if (deviceOf(l, r) !== next.device || next.sub !== r.viewer.sub) {
          return refuse(403, "vault_not_device", "a device publishes only its own member's join request");
        }
        if (!l.members.has(r.viewer.sub)) return refuse(403, "vault_not_member", "only workspace members may request to join");
        for (let attempt = 0; attempt < 3; attempt++) {
          const heldVault = vaults.vaultSnapshot(l.ws, next.vault), vault = heldVault?.value ?? null;
          if (vault === null || vault.deleted || vault.scope !== "workspace" || vault.ws !== l.ws) {
            return refuse(404, "vault_unknown", "no such workspace vault here");
          }
          if (vault.members.includes(r.viewer.sub)) {
            return json(200, JSON.stringify({ join: next, alreadyMember: true }));
          }
          if (next.state === "pending") {
            // Require the station to already hold a verified BoxCert for `(next.device, next.box)` so admin approval
            // can wrap the vault key immediately without a zero-key gap.
            const heldBox = vaults.box(l.ws, next.device);
            if (heldBox === null || heldBox.box !== next.box || certOk(l, heldBox) !== null) {
              return refuse(409, "vault_box_missing", "publish this device's box certificate before requesting to join");
            }
          }
          const snap = vaults.joinSnapshot(l.ws, next.vault, next.sub);
          const had = snap?.value ?? null;
          const hadValid = had !== null && joinAskOk(l, had) === null;
          if (had !== null && had.at >= next.at && hadValid) {
            const superseded = snap !== null && had.at <= snap.joinedUpTo;
            return json(200, JSON.stringify(superseded ? { join: had, superseded: true } : { join: had }));
          }
          const resetJoinedFloor = had !== null && !hadValid && joinAskOk(l, had, true) !== null;
          if (!vaults.putJoinIf(next, heldVault!.body, snap?.body ?? null, snap !== null, resetJoinedFloor)) continue;
          const notifySubs = [...new Set([...adminSubsOf(l, vault), r.viewer.sub])];
          tell("vault-joins-changed", { vault: vault.id }, `vault-joins-changed\0${vault.ws}\0${vault.id}`, { workspace: vault.ws, subs: notifySubs });
          return json(200, JSON.stringify({ join: next }));
        }
        return refuse(503, "vault_busy", "the join request changed while it was being written");
      },
    },
    {
      method: "PUT",
      pattern: /^\/vault\/joins\/dismiss$/,
      handle: async (r) => {
        const waiting = beforeWrite?.();
        if (waiting === false || (waiting !== undefined && (!await waiting || beforeWrite?.() === false))) return refuse(503, "vault_handover", "the previous station has not finished handing over");
        const l = locked(r);
        if (isAnswer(l)) return l;
        const next = body(r) as JoinDismiss;
        if (next === null || typeof next !== "object" || typeof next.vault !== "string" || typeof next.sub !== "string") {
          return refuse(400, "vault_invalid", "a join dismiss is an object");
        }
        if (deviceOf(l, r) === null) return refuse(403, "vault_not_device", "a lock app device signs join dismissals");
        for (let attempt = 0; attempt < 3; attempt++) {
          const heldVault = vaults.vaultSnapshot(l.ws, next.vault), vault = heldVault?.value ?? null;
          if (vault === null || vault.deleted || vault.scope !== "workspace" || !sees(vault, r.viewer)) {
            return refuse(404, "vault_unknown", "no such workspace vault here, or not one of yours");
          }
          const why = joinDismissOk(l, vault, next);
          if (why !== null) return refuse(400, "vault_invalid", why);
          const snap = vaults.joinSnapshot(l.ws, next.vault, next.sub);
          const hadValid = snap !== null && snap.dismiss !== null && joinDismissOk(l, vault, snap.dismiss) === null;
          if (hadValid && snap.dismissUpTo >= next.upTo) {
            return json(200, JSON.stringify({ dismiss: snap.dismiss }));
          }
          const allowReplaceInvalid = snap !== null && snap.dismiss !== null && !hadValid;
          if (!vaults.putJoinDismissIf(next, heldVault!.body, snap === null ? null : snap.dismissUpTo, snap?.dismissBody ?? null, allowReplaceInvalid)) continue;
          const notifySubs = [...new Set([...adminSubsOf(l, vault), next.sub])];
          tell("vault-joins-changed", { vault: vault.id }, `vault-joins-changed\0${vault.ws}\0${vault.id}`, { workspace: vault.ws, subs: notifySubs });
          return json(200, JSON.stringify({ dismiss: next }));
        }
        return refuse(503, "vault_busy", "the join dismissal changed while it was being written");
      },
    },
  ];
};
