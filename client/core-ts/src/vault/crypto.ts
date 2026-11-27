// The vault's formats on the device (实现约定): what is signed and how, the seal a key or secret is sent
// in, an item's ciphertext, the recovery words. The stations check the same (station/src/vault/crypto.ts, on node's
// crypto); both are tested on the same values (station/test/fixtures/vault-vectors.json).
import { chacha20poly1305 } from "@noble/ciphers/chacha.js";
import { x25519 } from "@noble/curves/ed25519.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { CoreError } from "../error.ts";
import { canonical } from "../lock.ts";
import { ed25519Ok, p256Ok } from "./verified.ts";
import { base64url, hex, utf8 } from "../util.ts";

export type Sig = { key: string; alg: "Ed25519" | "ES256"; sig: string };
/// A device's box key, signed by that device's lock `sign_key`; `recovery`: its person's recovery key (what any of
/// their devices seals a new vault's key to).
export type BoxCert = { v: 1; ws: string; device: string; box: string; recovery?: string; at: number; sig: Sig };
/// A device's explicit per-vault key authorization request (`vault.ask`), signed separately under `TAG.ask` so
/// automatic box-certificate publishing never triggers prompts and asks never bloat `Vault.keys`.
export type KeyAsk = { v: 1; ws: string; vault: string; device: string; box: string; at: number; sig: Sig };
/// A non-member workspace user's explicit request to join (or withdraw from requesting) a shared workspace vault,
/// structurally isolated from `KeyAsk` so join requests never trigger global `lockPrompts` popups.
export type JoinAsk = {
  v: 1;
  ws: string;
  vault: string;
  sub: string;
  device: string;
  box: string;
  state: "pending" | "cancelled";
  at: number;
  sig: Sig;
};
/// A workspace vault admin's signed dismissal watermark for a member's join requests up to `upTo`.
export type JoinDismiss = {
  v: 1;
  ws: string;
  vault: string;
  sub: string;
  upTo: number;
  at: number;
  sig: Sig;
};
/// Minimal non-secret summary of a shared workspace vault shown to unjoined workspace members for discovery.
export type DiscoverableVault = {
  id: string;
  ws: string;
  name: string;
  scope: "workspace";
  owner: string;
  memberCount: number;
  seq: number;
  at: number;
};
const VAULT_ID_RE = /^v_[0-9A-HJKMNP-TV-Z]{26}$/;
const HEX32_RE = /^[0-9a-f]{64}$/;
const ED_KEY_RE = /^ed25519:[0-9a-f]{64}$/;
const ED_SIG_RE = /^[0-9a-f]{128}$/;
const B64URL_RE = /^[A-Za-z0-9_-]+$/;
const ASK_KEYS = new Set(["v", "ws", "vault", "device", "box", "at", "sig"]);
const JOIN_KEYS = new Set(["v", "ws", "vault", "sub", "device", "box", "state", "at", "sig"]);
const JOIN_DISMISS_KEYS = new Set(["v", "ws", "vault", "sub", "upTo", "at", "sig"]);
const SIG_KEYS = new Set(["key", "alg", "sig"]);

export type AskLockView = {
  ws: string;
  members: ReadonlyMap<string, unknown>;
  devices: ReadonlyMap<string, { sub: string; kind: string; own: boolean; sign_key?: string }>;
  signKeys: ReadonlyMap<string, readonly string[]>;
};

function sigShapeOk(sig: unknown): sig is Sig {
  if (sig === null || typeof sig !== "object" || Array.isArray(sig)) return false;
  const sigKeys = Object.keys(sig);
  if (sigKeys.length !== SIG_KEYS.size || !sigKeys.every((k) => SIG_KEYS.has(k))) return false;
  const s = sig as Partial<Sig>;
  if (typeof s.key !== "string" || s.key.length > 200 || typeof s.sig !== "string" || s.sig.length > 256) return false;
  if (s.alg === "Ed25519") return ED_KEY_RE.test(s.key) && ED_SIG_RE.test(s.sig);
  if (s.alg === "ES256") return s.key.startsWith("p256:") && B64URL_RE.test(s.key.slice(5)) && s.key.slice(5).length % 4 !== 1 && B64URL_RE.test(s.sig) && s.sig.length % 4 !== 1;
  return false;
}

/// Whether a 32-byte little-endian X25519 u-coordinate is in canonical range `[0, 2^255 - 19)`.
function isCanonicalX25519(raw: Uint8Array): boolean {
  if (raw.length !== 32) return false;
  if ((raw[31]! & 0x80) !== 0) return false;
  if (raw[31] === 0x7f) {
    let allFF = true;
    for (let i = 1; i <= 30; i++) {
      if (raw[i] !== 0xff) {
        allFF = false;
        break;
      }
    }
    if (allFF && raw[0]! >= 0xed) return false;
  }
  return true;
}

/// Whether `pub` is a usable canonical X25519 box public key (rejecting malformed or non-canonical encodings and
/// low-order/all-zero shared points so HKDF binds the exact public key bytes used by `openSeal`).
export function usableBoxKey(pub: string): boolean {
  if (!BOX.test(pub)) return false;
  const raw = unhex(pub.slice(7));
  if (!isCanonicalX25519(raw)) return false;
  try {
    const shared = x25519.getSharedSecret(new Uint8Array(32).fill(9), raw);
    return shared.some((b) => b !== 0);
  } catch {
    return false;
  }
}

/// Why a standalone per-vault key ask record is invalid for `lock`, or null when valid: exact fixed shape
/// `{v: 1, ws, vault, device, box, at, sig}` with no extra fields, signed under `TAG.ask` by the device's own
/// lock signing key (`ever`: also accepting historical signing keys of that device).
export function askOk(lock: AskLockView, raw: unknown, ever = false): string | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return "a key ask is an object";
  const keys = Object.keys(raw);
  if (keys.length !== ASK_KEYS.size || !keys.every((k) => ASK_KEYS.has(k))) {
    return "a key ask is {v: 1, ws, vault, device, box, at, sig}";
  }
  const a = raw as Partial<KeyAsk>;
  if (a.v !== 1 || a.ws !== lock.ws) return "a key ask is {v: 1, ws, vault, device, box, at, sig} of this workspace";
  if (typeof a.vault !== "string" || !VAULT_ID_RE.test(a.vault)) return "a key ask's vault is v_<ULID>";
  if (typeof a.device !== "string" || !HEX32_RE.test(a.device)) return "a key ask's device is a 32-byte hex id";
  if (typeof a.box !== "string" || !BOX.test(a.box)) return "a key ask's box is an x25519 key";
  if (typeof a.at !== "number" || !Number.isSafeInteger(a.at) || a.at < 0) return "a key ask's at is a whole number";
  if (!sigShapeOk(a.sig)) return "a key ask's sig is invalid";
  const d = lock.devices.get(a.device);
  if (d === undefined || d.kind !== "app" || !lock.members.has(d.sub)) {
    return "the key ask's device is not an app device in the lock";
  }
  if (!ever && !d.own) return "the key ask's device was put in the lock by someone else, not its person";
  const had = ever ? (lock.signKeys.get(a.device) ?? []) : [];
  if (d.sign_key !== a.sig.key && !(ever && had.includes(a.sig.key))) {
    return "a key ask is signed by its own device's key";
  }
  if (!signedOk(a as KeyAsk, TAG.ask)) return "the key ask's signature is invalid";
  return null;
}

/// Why a standalone workspace-vault join ask record is invalid for `lock`, or null when valid.
export function joinAskOk(lock: AskLockView, raw: unknown, ever = false): string | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return "a join ask is an object";
  const keys = Object.keys(raw);
  if (keys.length !== JOIN_KEYS.size || !keys.every((k) => JOIN_KEYS.has(k))) {
    return "a join ask is {v: 1, ws, vault, sub, device, box, state, at, sig}";
  }
  const a = raw as Partial<JoinAsk>;
  if (a.v !== 1 || a.ws !== lock.ws) return "a join ask is of this workspace";
  if (typeof a.vault !== "string" || !VAULT_ID_RE.test(a.vault)) return "a join ask's vault is v_<ULID>";
  if (typeof a.sub !== "string" || a.sub === "" || a.sub.length > 200) return "a join ask's sub is invalid";
  if (typeof a.device !== "string" || !HEX32_RE.test(a.device)) return "a join ask's device is a 32-byte hex id";
  if (typeof a.box !== "string" || !usableBoxKey(a.box)) return "a join ask's box is a usable x25519 key";
  if (a.state !== "pending" && a.state !== "cancelled") return "a join ask's state is pending or cancelled";
  if (typeof a.at !== "number" || !Number.isSafeInteger(a.at) || a.at < 0) return "a join ask's at is a whole number";
  if (!sigShapeOk(a.sig)) return "a join ask's sig is invalid";
  const d = lock.devices.get(a.device);
  if (d === undefined || d.kind !== "app" || d.sub !== a.sub || !lock.members.has(d.sub)) {
    return "the join ask's device is not an app device of that member in the lock";
  }
  if (!ever && !d.own) return "the join ask's device was put in the lock by someone else, not its person";
  const had = ever ? (lock.signKeys.get(a.device) ?? []) : [];
  if (d.sign_key !== a.sig.key && !(ever && had.includes(a.sig.key))) {
    return "a join ask is signed by its own device's key";
  }
  if (!signedOk(a as JoinAsk, TAG.join)) return "the join ask's signature is invalid";
  return null;
}

/// Why an admin's signed join-request dismissal is invalid for `lock` and `vault`, or null when valid.
/// Checks the signer's current owner/admin role in `lock` and membership in `vault`.
export function joinDismissOk(
  lock: AskLockView & { members: ReadonlyMap<string, unknown> },
  vault: { id: string; scope?: "workspace"; deleted?: true; members: readonly string[] },
  raw: unknown,
  isAdmin: (sub: string) => boolean,
): string | null {
  if (vault.scope !== "workspace" || vault.deleted) return "join dismiss applies only to active workspace vaults";
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return "a join dismiss is an object";
  const keys = Object.keys(raw);
  if (keys.length !== JOIN_DISMISS_KEYS.size || !keys.every((k) => JOIN_DISMISS_KEYS.has(k))) {
    return "a join dismiss is {v: 1, ws, vault, sub, upTo, at, sig}";
  }
  const d = raw as Partial<JoinDismiss>;
  if (d.v !== 1 || d.ws !== lock.ws || d.vault !== vault.id) return "a join dismiss is for this workspace vault";
  if (typeof d.sub !== "string" || d.sub === "" || d.sub.length > 200) return "a join dismiss's sub is invalid";
  if (typeof d.upTo !== "number" || !Number.isSafeInteger(d.upTo) || d.upTo < 0) return "a join dismiss's upTo is a whole number";
  if (typeof d.at !== "number" || !Number.isSafeInteger(d.at) || d.at < 0) return "a join dismiss's at is a whole number";
  if (!sigShapeOk(d.sig)) return "a join dismiss's sig is invalid";
  let signerSub: string | null = null;
  for (const dev of lock.devices.values()) {
    if (dev.kind === "app" && dev.own && dev.sign_key === d.sig.key) {
      signerSub = dev.sub;
      break;
    }
  }
  if (signerSub === null || !vault.members.includes(signerSub) || !isAdmin(signerSub)) {
    return "only a managing admin of this workspace vault may dismiss join requests";
  }
  if (!signedOk(d as JoinDismiss, TAG.joinDismiss)) return "the join dismiss's signature is invalid";
  return null;
}
export type Vault = {
  v: 1; ws: string; id: string; seq: number; owner: string; name: string; members: string[]; epoch: number;
  keys: { cert: BoxCert; wrapped: string }[]; recovery?: string; at: number; sig: Sig;
  /// Absent or personal: personal vault; `workspace`: shared workspace vault managed by workspace owners/admins.
  scope?: "workspace";
  /// The longest grant its items are given for, where an item's listing says none (absent: any).
  lasts?: Scope;
  /// Deleted by its owner (`vault.delete`): sealed to no one under a new epoch, its items gone; it stays deleted.
  deleted?: true;
};
export type Kind = "token" | "ssh_key" | "login" | "file" | "browser";
export type Mode = "proxy" | "ssh" | "env" | "file" | "browser";
/// How long a grant lasts: one use, an hour, or the chat until it is archived.
export type Scope = "once" | "hour" | "chat";
/// The scopes, shortest first.
export const SCOPES: Scope[] = ["once", "hour", "chat"];
/// How agents may ask for an item; `lasts`: the longest grant its owner gives (absent: as its vault says); `about`: what
/// it is and how it is used, the item's notes as agents are shown them beside its name (never a secret).
export type Listing = { name: string; kind: Kind; modes: Mode[]; hosts: string[]; env?: string; lasts?: Scope; about?: string };
/// Whether a grant may last as long as `scope` for an item that allows `lasts` at most (none: any).
export const allows = (lasts: Scope | null | undefined, scope: Scope): boolean =>
  SCOPES.indexOf(scope) >= 0 && SCOPES.indexOf(scope) <= SCOPES.indexOf(lasts ?? "chat");
export type Item = {
  v: 1; ws: string; vault: string; id: string; version: number; epoch: number; deleted?: true; ct: string; listing?: Listing; at: number; sig: Sig;
};
/// What an item holds, sealed: `fields` by kind (token `{value}`, ssh_key `{private_key, public_key}`, login
/// `{username, password, totp?}`, file `{content (its bytes in base64), filename?}`).
export type Plain = { kind: Kind; name: string; fields: Record<string, string>; domains: string[]; notes: string };
export type CrossListing = {
  sourceWs: string;
  sourceWsName: string;
  vault: string;
  vaultName: string;
  vaultLasts?: Scope;
  item: string;
  listing: Listing;
};
export type BrowseAnswer = {
  v: 1;
  ws: string;
  request: string;
  items: CrossListing[];
  at: number;
  sig: Sig;
};
export type Request = {
  id: string; ws: string; vault: string; item: string; session: string; chat: string; mode: Mode | "browse"; reason: string;
  timeout?: Timeout;
  command?: string; hosts?: string[]; box: string; at: number;
  /// `withdrawn`: taken back by the agent that asked (secret_cancel) before anyone decided it.
  status: "pending" | "granted" | "denied" | "expired" | "withdrawn";
  /// The plain library's item's owner, or whom a secret to keep, browse, or cross-workspace request is for (their email).
  owner?: string;
  /// An agent asking to keep a secret (secret_save agent 存入): the item as it is to be listed, written
  /// under `item` into `vault` (empty: one of the person's own, made when they have none).
  save?: Save;
  /// Its fields, sealed by the station that asked to each of the person's devices set up (`saveContext`).
  sealed?: { device: string; box: string; secret: string }[];
  /// A sign-in's newer fields (its cookies as an earlier grant of it ended), sealed by the station to each of its
  /// vault's members' devices set up (`saveContext` under its id): written as the item's next version when this
  /// request is granted, and granted.
  renewal?: { id: string; sealed: { device: string; box: string; secret: string }[] };
  /// An agent asking to rename the item or change its about (secret_describe 改名和说明): as they are to be, and as
  /// they were when asked. Granted by writing the item's next version so (`vault.approve`); it grants nothing.
  describe?: { name: string; about: string; was: { name: string; about: string } };
  /// An agent asking to delete the item (secret_delete 删除): its name when asked. Granted by deleting the item
  /// (`vault.approve`); it grants nothing.
  remove?: { name: string };
  /// An agent asking to browse personal secrets from other workspaces for this chat.
  browse?: { workspace?: string; workspaces?: number; items?: number };
  /// An agent asking to use a personal secret from another workspace.
  cross?: { workspace: string; workspaceName: string; vaultName: string };
};
/// `typed`: its secret is what the person types in on its card (nothing sealed: the app writes what was typed); with
/// `oauth`, the token they sign in to that service for on the card (vault/oauth.ts) instead.
export type Save = { kind: Kind; name: string; modes: Mode[]; hosts: string[]; env?: string; username?: string; public_key?: string; filename?: string; typed?: true; oauth?: string; about?: string; vaultName?: string; shared?: true };
export type Timeout = { kind: "idle" | "fixed"; seconds: number };
export type Grant = { v: 1; ws: string; request: string; vault: string; item: string; mode: Mode; hosts: string[]; scope: Scope; exp: number; timeout?: Timeout; sourceWs?: string; secret: string; at: number; sig: Sig };
export type Deny = { v: 1; ws: string; request: string; at: number; sig: Sig };

export const TAG = {
  box: "stillfail-vault-box/1",
  ask: "stillfail-vault-ask/1",
  join: "stillfail-vault-join/1",
  joinDismiss: "stillfail-vault-join-dismiss/1",
  vault: "stillfail-vault/1",
  item: "stillfail-vault-item/1",
  grant: "stillfail-vault-grant/1",
  deny: "stillfail-vault-deny/1",
  browse: "stillfail-vault-browse/1",
} as const;

export const keyContext = (ws: string, vault: string, epoch: number) => `stillfail-vault-key/1\0${ws}\0${vault}\0${epoch}`;
export const itemContext = (ws: string, vault: string, id: string, version: number, epoch: number) => `stillfail-vault-item/1\0${ws}\0${vault}\0${id}\0${version}\0${epoch}`;
export const grantContext = (ws: string, request: string) => `stillfail-vault-grant/1\0${ws}\0${request}`;
/// The seal's context for a secret an agent asks to keep, sealed to one of its owner's devices.
export const saveContext = (ws: string, request: string) => `stillfail-vault-save/1\0${ws}\0${request}`;

const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};
const unhex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));

/// base64url without padding, as the formats write bytes; null when it is not.
export function fromB64url(text: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) return null;
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  const out = new Uint8Array(Math.floor((text.length * 3) / 4));
  let bits = 0, value = 0, o = 0;
  for (let i = 0; i < text.length; i++) {
    value = (value << 6) | alphabet.indexOf(text[i]!);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (value >> bits) & 255;
    }
  }
  return out;
}

const b64 = (text: string, what: string): Uint8Array => {
  const b = fromB64url(text);
  if (b === null) throw new CoreError("vault_invalid", `${what} is not base64url`);
  return b;
};

/// The bytes a record's signature is over: its tag, a NUL, then the sha256 (32 raw bytes) of the record without `sig`.
export function signedBytes(o: Record<string, unknown>, tag: string): Uint8Array {
  const { sig: _, ...rest } = o;
  return concat(utf8(`${tag}\0`), sha256(utf8(canonical(rest))));
}

/// Whether `o.sig` is its key's signature over `o` under `tag` (which key may sign is the caller's to check): checked once
/// on this device for those bytes (verified.ts).
export function signedOk(o: { sig: Sig } & Record<string, unknown>, tag: string): boolean {
  try {
    return sigOver(o.sig, signedBytes(o, tag));
  } catch {
    return false;
  }
}

/// The vault's rules' cryptography (rules/, MoonBit: views/vault.ts checks by them): whether `sig` is its key's over a
/// record whose canonical text without it is `text`, under `tag`.
export const rulesCrypto = {
  recordSigValid: (sig: Sig, tag: string, text: string): boolean => sigOver(sig, concat(utf8(`${tag}\0`), sha256(utf8(text)))),
};

/// Whether `sig` is its key's over `bytes`.
function sigOver(sig: Sig, bytes: Uint8Array): boolean {
  try {
    if (sig === null || typeof sig !== "object" || typeof sig.key !== "string" || typeof sig.sig !== "string") return false;
    if (sig.alg === "Ed25519" && /^ed25519:[0-9a-f]{64}$/.test(sig.key) && /^[0-9a-f]{128}$/.test(sig.sig)) return ed25519Ok(unhex(sig.sig), bytes, unhex(sig.key.slice(8)));
    if (sig.alg === "ES256" && sig.key.startsWith("p256:")) {
      const point = fromB64url(sig.key.slice(5)), s = fromB64url(sig.sig);
      return point !== null && s !== null && point.length === 65 && p256Ok(s, bytes, point);
    }
    return false;
  } catch {
    return false;
  }
}

export { verifies } from "./verified.ts";

/// A record signed under `tag` by an Ed25519 key, signing the bytes it is given (the lock's `Signer`).
export function sign<T extends Record<string, unknown>>(o: T, tag: string, signer: { id: string; signBytes(bytes: Uint8Array): string }): T & { sig: Sig } {
  return { ...o, sig: { key: signer.id, alg: "Ed25519", sig: signer.signBytes(signedBytes(o, tag)) } };
}

const BOX = /^x25519:[0-9a-f]{64}$/;
export function boxBytes(pub: string): Uint8Array {
  if (!BOX.test(pub)) throw new CoreError("vault_invalid", "not an x25519 key");
  return unhex(pub.slice(7));
}

/// The public half of a raw X25519 private key, as `x25519:<hex>`.
export const boxPublic = (priv: Uint8Array) => `x25519:${hex(x25519.getPublicKey(priv))}`;

const SEAL_INFO = utf8("stillfail-vault-seal/1");
const NONCE0 = new Uint8Array(12);

/// `plain` sealed to the box key `pub` under `context`, with this ephemeral private key (32 random bytes).
export function sealWith(pub: string, plain: Uint8Array, context: string, eph: Uint8Array): string {
  const to = boxBytes(pub);
  const ephPub = x25519.getPublicKey(eph);
  const key = hkdf(sha256, x25519.getSharedSecret(eph, to), concat(ephPub, to), SEAL_INFO, 32);
  return base64url(concat(ephPub, chacha20poly1305(key, NONCE0, utf8(context)).encrypt(plain)));
}

/// Fault-isolating variant of `sealWith` that validates `usableBoxKey(pub)` and returns null if sealing fails
/// (so a single corrupted or low-order device certificate never blocks sealing keys for other devices).
export function trySealWith(pub: string, plain: Uint8Array, context: string, eph: Uint8Array): string | null {
  if (!usableBoxKey(pub)) return null;
  try {
    return sealWith(pub, plain, context, eph);
  } catch {
    return null;
  }
}

/// What `sealWith` sealed to `priv`'s public half under `context`; throws when it is not.
export function openSeal(priv: Uint8Array, sealed: string, context: string): Uint8Array {
  const b = b64(sealed, "a seal");
  if (b.length < 48) throw new CoreError("vault_invalid", "not a seal");
  const ephPub = b.subarray(0, 32);
  const key = hkdf(sha256, x25519.getSharedSecret(priv, ephPub), concat(ephPub, x25519.getPublicKey(priv)), SEAL_INFO, 32);
  try {
    return chacha20poly1305(key, NONCE0, utf8(context)).decrypt(b.subarray(32));
  } catch {
    throw new CoreError("vault_unsealed", "this key does not open it");
  }
}

/// An item's ciphertext: a 12-byte nonce, then ChaCha20-Poly1305 under the vault key with `context` as additional data.
export function encryptWith(key: Uint8Array, plain: Uint8Array, context: string, nonce: Uint8Array): string {
  return base64url(concat(nonce, chacha20poly1305(key, nonce, utf8(context)).encrypt(plain)));
}

export function decrypt(key: Uint8Array, ct: string, context: string): Uint8Array {
  const b = b64(ct, "an item's ciphertext");
  if (b.length < 28) throw new CoreError("vault_invalid", "not an item's ciphertext");
  try {
    return chacha20poly1305(key, b.subarray(0, 12), utf8(context)).decrypt(b.subarray(12));
  } catch {
    throw new CoreError("vault_unsealed", "the vault's key does not open this item");
  }
}

/// The recovery key pair from the 32 bytes the recovery words hold.
export function recoveryPair(entropy: Uint8Array): { pub: string; priv: Uint8Array } {
  const priv = hkdf(sha256, entropy, new Uint8Array(0), utf8("stillfail-vault-recovery/1"), 32);
  return { pub: boxPublic(priv), priv };
}

/// 32 bytes as BIP-39's 24 English words (the last carries 8 bits of their sha256).
export function toWords(entropy: Uint8Array): string {
  if (entropy.length !== 32) throw new CoreError("vault_invalid", "recovery words hold 32 bytes");
  const bits = concat(entropy, sha256(entropy).subarray(0, 1));
  const out: string[] = [];
  for (let i = 0; i < 24; i++) {
    let n = 0;
    for (let b = i * 11; b < i * 11 + 11; b++) n = (n << 1) | ((bits[b >> 3]! >> (7 - (b & 7))) & 1);
    out.push(wordlist[n]!);
  }
  return out.join(" ");
}

/// The 32 bytes 24 recovery words hold; throws when a word is not one, or they do not add up (their checksum).
export function fromWords(words: string): Uint8Array {
  const list = words.trim().split(/\s+/).map((w) => w.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32)));
  if (list.length !== 24) throw new CoreError("vault_words", "the recovery words are 24");
  const bits = new Uint8Array(33);
  list.forEach((w, i) => {
    const n = wordlist.indexOf(w);
    if (n < 0) throw new CoreError("vault_words", `“${w}” is not one of the recovery words`);
    for (let b = 0; b < 11; b++) {
      const at = i * 11 + b;
      if ((n >> (10 - b)) & 1) bits[at >> 3] = bits[at >> 3]! | (1 << (7 - (at & 7)));
    }
  });
  const entropy = bits.subarray(0, 32);
  if (sha256(entropy)[0] !== bits[32]) throw new CoreError("vault_words", "the recovery words do not add up: one is wrong or out of place");
  return entropy.slice();
}
