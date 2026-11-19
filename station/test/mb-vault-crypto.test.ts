// The vault's formats, rules, keeper and plain library in MoonBit (station/mb src/vault_crypto, `stillfail-reader-harness --builder
// harness-vault-crypto`, its primitives the shell's `crypto.*`) held to the TypeScript they are the MoonBit of
// (src/vault/crypto.ts, keeper.ts, plain.ts, schema-install.ts): the vectors every part is tested on
// (test/fixtures/vault-vectors.json), what one seals the other opens both ways, the same rules' answers in the same
// words on seeded random records signed with Ed25519 and ES256, a keeper and the program's run in lockstep on the same
// asks (its clock, its timers and its durable store's answers scripted alike) and handed over to each other, and the
// plain library's tables written by one and read by the other, byte for byte.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createPrivateKey, createPublicKey, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type Entry, type LockState, entryHash, fold, genesis, signedBytes as lockBytes } from "../src/cloud/lock.ts";
import { wall } from "../src/ops/fibers.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import {
  SCOPES, TAG, allows, boxPublic, browserListingOk, certOk, decrypt, encryptWith, grantContext, itemContext, itemOk, itemSupersedes,
  keyContext, openSeal, recoveryPair, saveContext, seal, sealWith, signedBytes, signedOk, signerOf, vaultOk, vaultSupersedes,
} from "../src/vault/crypto.ts";
import { type Held, Keeper, accountOf, hostAllowed, valueOf } from "../src/vault/keeper.ts";
import { PlainStore, fileOk, plainOk, shown } from "../src/vault/plain.ts";
import { UnaccountedSchema, installSchema } from "../src/vault/schema-install.ts";
import { WS as RWS, bases, genesisOf, key, nextOf, people, rng, signers, spare } from "./lock-chains.ts";
import V from "./fixtures/vault-vectors.json" with { type: "json" };

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
const SEEDS = Number(process.env.VAULT_CRYPTO_SEEDS ?? 12);

const dirs: string[] = [];
const tmp = () => {
  const d = mkdtempSync(join(tmpdir(), "mb-vault-crypto-"));
  dirs.push(d);
  return d;
};

/// The program, asked a line at a time.
class Program {
  readonly #p: ChildProcessWithoutNullStreams;
  readonly #waiting = new Map<number, { ok: (v: any) => void; no: (e: Error) => void }>();
  #next = 0;
  constructor(bin: string) {
    this.#p = spawn(bin, ["--builder", "harness-vault-crypto", "--shell-dir", tmp()], { stdio: ["pipe", "pipe", "pipe"] });
    createInterface({ input: this.#p.stdout }).on("line", (line) => {
      const a = JSON.parse(line);
      const w = this.#waiting.get(a.id);
      this.#waiting.delete(a.id);
      if ("error" in a) w?.no(new Error(a.error));
      else w?.ok(a.value);
    });
    this.#p.stderr.on("data", (d) => process.stderr.write(d));
    // (a program that ends answers nothing more: what waits on it fails saying so)
    this.#p.on("exit", (code, signal) => {
      for (const w of this.#waiting.values()) w.no(new Error(`the program ended (${code ?? signal})`));
      this.#waiting.clear();
    });
  }
  ask(op: string, args: Record<string, unknown> = {}): Promise<any> {
    const id = ++this.#next;
    return new Promise((ok, no) => {
      this.#waiting.set(id, { ok, no });
      this.#p.stdin.write(JSON.stringify({ id, op, ...args }) + "\n");
    });
  }
  /// What the ask answers, or its error's words.
  async said(op: string, args: Record<string, unknown> = {}): Promise<any> {
    try {
      return { value: await this.ask(op, args) };
    } catch (e) {
      return { error: (e as Error).message };
    }
  }
  close() {
    this.#p.stdin.end();
  }
}

let program: Program | null = null;
const mb = () => (program ??= new Program(binary!));
after(() => {
  program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const unhex = (s: string) => new Uint8Array(Buffer.from(s, "hex"));
const utf8 = (s: string) => new Uint8Array(Buffer.from(s, "utf8"));
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);
const ulidChars = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
type R = ReturnType<typeof rng>;
const ulid = (r: R) => Array.from({ length: 26 }, () => ulidChars[r.int(ulidChars.length)]).join("");

/// The lock as the program reads it (rules.mbt `lock_view`).
const lockJson = (lock: LockState) => ({
  ws: lock.ws,
  members: [...lock.members.keys()],
  devices: Object.fromEntries([...lock.devices].map(([id, d]: [string, any]) => [id, { sub: d.sub, kind: d.kind, sign_key: d.sign_key, own: d.own }])),
  signKeys: Object.fromEntries(lock.signKeys ?? []),
});

/// An ES256 signer as an app device's (its id `p256:…`, P1363 base64url).
function es256() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  const id = `p256:${Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x!, "base64url"), Buffer.from(jwk.y!, "base64url")]).toString("base64url")}`;
  return { id, sig: (o: any, tag: string) => ({ key: id, alg: "ES256", sig: nodeSign("sha256", signedBytes(o, tag), { key: privateKey, dsaEncoding: "ieee-p1363" }).toString("base64url") }) };
}

test("the vectors: the program makes and opens what the station and the core make", { skip }, async () => {
  const p = mb();
  const ctx = keyContext(V.ws, V.vault.id, 0);
  assert.equal(await p.ask("boxPublic", { priv: V.box.priv }), V.box.pub);
  assert.equal(await p.ask("boxPublic", { priv: V.requestBox.priv }), V.requestBox.pub);
  assert.equal(await p.ask("sealWith", { pub: V.box.pub, plain: V.vaultKey, context: ctx, eph: V.eph.wrap }), V.vault.keys[0]!.wrapped);
  const recovery = await p.ask("recoveryPair", { entropy: V.recovery[1]!.entropy });
  assert.equal(await p.ask("sealWith", { pub: recovery.pub, plain: V.vaultKey, context: ctx, eph: V.eph.recovery }), V.vault.recovery);
  assert.equal(await p.ask("encryptWith", { key: V.vaultKey, plain: hex(utf8(V.plain)), context: itemContext(V.ws, V.vault.id, V.item.id, 0, 0), nonce: V.nonce }), V.item.ct);
  assert.equal(await p.ask("sealWith", { pub: V.requestBox.pub, plain: hex(utf8(V.plain)), context: grantContext(V.ws, V.grant.request), eph: V.eph.grant }), V.grant.secret);
  for (const r of V.recovery) {
    const pair = await p.ask("recoveryPair", { entropy: r.entropy });
    assert.equal(pair.pub, r.pub);
    assert.deepEqual(pair, { pub: recoveryPair(unhex(r.entropy)).pub, priv: hex(recoveryPair(unhex(r.entropy)).priv) });
  }
  for (const [o, tag] of [[V.cert, TAG.box], [V.vault, TAG.vault], [V.item, TAG.item], [V.grant, TAG.grant], [V.deny, TAG.deny]] as const) {
    assert.equal(await p.ask("signedOk", { o, tag }), true, tag);
    assert.equal(await p.ask("signedBytes", { o, tag }), hex(signedBytes(o as any, tag)), tag);
  }
  assert.equal(await p.ask("signedOk", { o: V.item, tag: TAG.vault }), false);
  assert.equal(await p.ask("signedOk", { o: { ...V.item, version: 1 }, tag: TAG.item }), false);
  // its own signature, made as the core's (the same bytes: Ed25519 is deterministic)
  const { sig: _, ...cert } = V.cert;
  assert.deepEqual(await p.ask("sign", { o: cert, tag: TAG.box, seed: V.signer.seed }), V.cert);
  assert.equal(await p.ask("openSeal", { priv: V.box.priv, sealed: V.vault.keys[0]!.wrapped, context: ctx }), V.vaultKey);
  assert.match((await p.said("openSeal", { priv: V.box.priv, sealed: V.vault.keys[0]!.wrapped, context: keyContext(V.ws, V.vault.id, 1) })).error, /does not open/);
  assert.equal(await p.ask("decrypt", { key: V.vaultKey, ct: V.item.ct, context: itemContext(V.ws, V.vault.id, V.item.id, 0, 0) }), hex(utf8(V.plain)));
  assert.match((await p.said("decrypt", { key: V.vaultKey, ct: V.item.ct, context: itemContext(V.ws, V.vault.id, V.item.id, 1, 0) })).error, /does not open/);
  assert.match((await p.said("decrypt", { key: V.vaultKey, ct: "AAAA", context: "" })).error, /not an item's ciphertext/);
  assert.match((await p.said("openSeal", { priv: V.box.priv, sealed: "AAAA", context: "" })).error, /not a seal/);
  assert.match((await p.said("sealWith", { pub: "x25519:zz", plain: "", context: "", eph: V.eph.wrap })).error, /not an x25519 key/);
});

test("sealed by one, opened by the other: TypeScript to MoonBit and back, Node's lenient base64 and hex as Node reads them", { skip }, async () => {
  const p = mb();
  const r = rng(7);
  for (let n = 0; n < 40; n++) {
    const plain = new Uint8Array(Array.from({ length: r.int(300) }, () => r.int(256)));
    const ctx = r.pick([keyContext(V.ws, `v_${n}`, n), itemContext(V.ws, "v", "i", n, 1), grantContext(V.ws, `r_${n}`), saveContext(V.ws, "名字 😀"), ""]);
    // the program's own pair, which TypeScript makes the same public half of
    const pair = await p.ask("newBoxPair");
    assert.equal(boxPublic(unhex(pair.priv)), pair.pub);
    const toMb = seal(pair.pub, plain, ctx);
    assert.equal(await p.ask("openSeal", { priv: pair.priv, sealed: toMb, context: ctx }), hex(plain));
    const ts = { priv: fill(n + 1), pub: boxPublic(fill(n + 1)) };
    const fromMb = await p.ask("seal", { pub: ts.pub, plain: hex(plain), context: ctx });
    assert.deepEqual(openSeal(ts.priv, fromMb, ctx), plain);
    // the same seal with the same ephemeral key, byte for byte
    const eph = fill(200 - n);
    assert.equal(await p.ask("sealWith", { pub: ts.pub, plain: hex(plain), context: ctx, eph: hex(eph) }), sealWith(ts.pub, plain, ctx, eph));
    const key = fill(n + 50);
    const nonce = fill(n, 12);
    const ct = await p.ask("encryptWith", { key: hex(key), plain: hex(plain), context: ctx, nonce: hex(nonce) });
    assert.equal(ct, encryptWith(key, plain, ctx, nonce));
    assert.deepEqual(decrypt(key, ct, ctx), plain);
    // as Node reads it: base64 or base64url, padded or not, with what is of neither alphabet skipped
    const loose = Buffer.from(ct, "base64url").toString("base64") + (n % 2 ? "" : "\n");
    assert.equal(await p.ask("decrypt", { key: hex(key), ct: loose, context: ctx }), hex(decrypt(key, loose, ctx)));
  }
  for (const s of ["x25519:" + "ab".repeat(32), "x25519:" + "AB".repeat(32), "x25519:abc", "ed25519:" + "ab".repeat(32), ""]) {
    const want = /^x25519:[0-9a-f]{64}$/.test(s) ? s.slice(7) : null;
    assert.equal(await p.ask("boxBytes", { pub: s }), want, s);
  }
  const c = await p.ask("contexts", { ws: "w", vault: "v", item: "i", request: "r", epoch: 3, version: 9 });
  assert.deepEqual(c, { key: keyContext("w", "v", 3), item: itemContext("w", "v", "i", 9, 3), grant: grantContext("w", "r"), save: saveContext("w", "r") });
  for (const lasts of [undefined, null, ...SCOPES, "week", 3]) {
    for (const scope of [...SCOPES, "week"]) assert.equal(await p.ask("allows", { lasts, scope }), allows(lasts as any, scope as any), `${lasts} ${scope}`);
  }
});

test("signatures: Ed25519 and ES256, kept, changed and of the wrong shape, the same answers", { skip }, async () => {
  const p = mb();
  const ed = key(5);
  const es = es256();
  const r = rng(11);
  for (let n = 0; n < 60; n++) {
    const o: any = { v: 1, ws: V.ws, request: `r_${n}`, at: 1000 + n, name: r.pick(["x", "名字 😀", " ", "a\"b\\c"]) };
    const tag = r.pick(Object.values(TAG));
    let sig: any = r.int(2) ? { key: ed.id, alg: "Ed25519", sig: ed.sign(signedBytes(o, tag)) } : es.sig(o, tag);
    switch (r.int(9)) {
      case 0: sig = { ...sig, sig: (sig.sig.startsWith("AA") ? "BB" : "AA") + sig.sig.slice(2) }; break;
      case 1: sig = { ...sig, alg: sig.alg === "ES256" ? "Ed25519" : "ES256" }; break;
      case 2: sig = { ...sig, key: "p256:AAAA" }; break;
      case 3: sig = r.pick([null, "x", 5, [sig]]); break;
      case 4: o.at = 1.5; break;
      case 5: sig = { ...sig, sig: sig.sig.toUpperCase() }; break;
      case 6: sig = { ...sig, sig: sig.sig + "=" }; break;
    }
    const rec = { ...o, sig };
    const t = r.int(4) === 0 ? r.pick(Object.values(TAG)) : tag;
    assert.equal(await p.ask("signedOk", { o: rec, tag: t }), signedOk(rec, t), JSON.stringify(rec));
  }
  // what the program signs, TypeScript takes
  const seed = fill(9);
  const signed = await p.ask("sign", { o: { v: 1, ws: "w", at: 5 }, tag: TAG.deny, seed: hex(seed) });
  assert.equal(signedOk(signed, TAG.deny), true);
  assert.equal(signedOk(signed, TAG.grant), false);
});

/// Signed under `tag` by `k` (an Ed25519 key of the chain's, or an ES256 one), now and then broken or missing.
function signedR<T extends Record<string, unknown>>(r: R, o: T, tag: string, k: { id: string; sign: (b: Buffer) => string } | ReturnType<typeof es256>): T & { sig: unknown } {
  let sig: any;
  try {
    sig = "sign" in k ? { key: k.id, alg: "Ed25519", sig: k.sign(Buffer.from(signedBytes(o, tag))) } : k.sig(o, tag);
  } catch {
    sig = { key: k.id, alg: "Ed25519", sig: "00" };
  }
  const roll = r.int(20);
  return { ...o, sig: roll === 0 ? { ...sig, sig: "00" + sig.sig.slice(2) } : roll === 1 ? { key: k.id, alg: "RSA", sig: "x" } : roll === 2 ? undefined : sig };
}

test("the rules: certificates, vaults, items and who signs, on seeded random locks, in the same words", { skip }, async () => {
  const p = mb();
  const boxes = Array.from({ length: 4 }, (_, i) => `x25519:${key(70 + i).hex}`);
  const b64 = (r: R, n: number) => Array.from({ length: n }, () => "ABCxyz019_-"[r.int(11)]).join("");
  let taken = 0, refused = 0;
  const tally = (why: string | null) => (why === null ? taken++ : refused++);
  for (let seed = 1; seed <= SEEDS; seed++) {
    const r = rng(2000 + seed);
    const chain: Entry[] = [genesisOf(r)];
    for (let i = 1; i <= 12; i++) {
      const next = nextOf(r, chain.at(-1)!, i);
      try {
        fold([...chain, next], null);
        chain.push(next);
      } catch {}
    }
    const lock = fold(chain, null);
    const lj = lockJson(lock);
    const keyOf = (r: R) => r.pick([...signers, ...spare.slice(0, 2)]);
    for (const k of [...signers, ...spare]) assert.deepEqual(await p.ask("signerOf", { lock: lj, key: k.id }), signerOf(lock, k.id), `seed ${seed}: signer`);
    const certOf = (r: R): any => {
      const i = r.int(people.length);
      const c = {
        v: r.int(10) === 0 ? 2 : 1, ws: r.int(25) === 0 ? "other" : RWS,
        device: r.int(12) === 0 ? r.pick(["nothex", 5, [bases[i]!.hex]]) : r.int(6) === 0 ? r.pick(spare).hex : bases[i]!.hex,
        box: r.int(20) === 0 ? "x25519:zz" : r.pick(boxes), at: r.int(25) === 0 ? 1.5 : 1000 + r.int(100),
      };
      return signedR(r, c, TAG.box, r.int(4) === 0 ? keyOf(r) : signers[i]!);
    };
    for (let n = 0; n < 8; n++) {
      const cert = certOf(r);
      for (const ever of [false, true]) {
        const want = certOk(lock, cert, ever);
        assert.equal(await p.ask("certOk", { lock: lj, cert, ever }), want, `seed ${seed}: cert ${JSON.stringify(cert)}`);
        tally(want);
      }
    }
    let held: any = null;
    let items: any[] = [];
    for (let n = 0; n < 10; n++) {
      const owner = held && r.int(8) ? held.owner : r.pick(people);
      const v: any = {
        v: 1, ws: r.int(30) === 0 ? "other" : RWS, id: held && r.int(10) ? held.id : r.int(12) === 0 ? "v_short" : `v_${ulid(r)}`,
        seq: held ? held.seq + r.pick([1, 1, 1, 2, 0, -1]) : r.int(6) === 0 ? 3 : 0, owner, name: r.pick(["Work", "名字 😀", ""]),
        members: [owner, ...people.filter((x) => x !== owner && r.int(2) === 0)], epoch: held ? held.epoch + r.pick([0, 0, 1, -1]) : r.int(3),
        keys: Array.from({ length: r.int(3) }, () => ({ cert: certOf(r), wrapped: b64(r, 40) })), at: 1000 + r.int(1000),
      };
      if (r.int(5) === 0) v.lasts = r.pick(["once", "hour", "chat", "week"]);
      if (r.int(12) === 0) v.deleted = true;
      const next = signedR(r, v, TAG.vault, r.int(3) === 0 ? keyOf(r) : signers[people.indexOf(owner)]!);
      for (const copy of [false, true]) {
        const want = vaultOk(lock, held, next as any, copy);
        assert.equal(await p.ask("vaultOk", { lock: lj, prev: held, next, copy }), want, `seed ${seed}, vault ${n}: ${JSON.stringify(next)}`);
        tally(want);
      }
      if (held !== null) {
        assert.equal(await p.ask("vaultSupersedes", { a: next, b: held }), vaultSupersedes(next as any, held), "vault supersedes");
        assert.equal(await p.ask("vaultSupersedes", { a: held, b: next }), vaultSupersedes(held, next as any), "vault supersedes");
      }
      if (vaultOk(lock, held, next as any) === null) held = next;
      if (held === null) continue;
      const prev = items.length && r.int(2) ? r.pick(items) : null;
      const kind = r.pick(["token", "ssh_key", "login", "file", "browser", "magic"]);
      const listing: any = {
        name: r.pick(["GitHub", "x".repeat(250)]), kind,
        modes: kind === "browser" && r.int(3) ? ["browser"] : r.pick([["proxy"], ["env", "proxy"], ["browser", "env"], ["telepathy"]]),
        hosts: r.pick([[], ["github.com"], ["*.example.com"], ["Bad Host"], ["api.github.com", "x.io"]]),
      };
      if (r.int(4) === 0) listing.env = r.pick(["GITHUB_TOKEN", "1BAD", "_ok"]);
      const i: any = {
        v: 1, ws: RWS, vault: r.int(20) === 0 ? "v_other" : held.id, id: prev && r.int(10) ? prev.id : `i_${ulid(r)}`,
        version: prev ? prev.version + r.pick([1, 1, 2, 0]) : 0, epoch: held.epoch, ct: b64(r, 60), at: 1000 + r.int(100),
      };
      if (r.int(2)) i.listing = listing;
      if (r.int(10) === 0) i.deleted = true;
      const by = r.int(4) === 0 ? keyOf(r) : signers[people.indexOf(r.pick(held.members.filter((m: string) => people.includes(m))))] ?? signers[0]!;
      const item = signedR(r, i, TAG.item, by);
      for (const copy of [false, true]) {
        const want = itemOk(lock, held, prev, item as any, copy);
        assert.equal(await p.ask("itemOk", { lock: lj, vault: held, prev, next: item, copy }), want, `seed ${seed}, item ${n}: ${JSON.stringify(item)}`);
        tally(want);
      }
      if (prev !== null) assert.equal(await p.ask("itemSupersedes", { a: item, b: prev }), itemSupersedes(item as any, prev), "item supersedes");
      if (itemOk(lock, held, prev, item as any) === null) items = [...items.filter((x) => x.id !== item.id), item];
      if (Array.isArray(listing.modes) && Array.isArray(listing.hosts)) assert.equal(await p.ask("browserListingOk", { l: listing }), browserListingOk(listing), JSON.stringify(listing));
    }
  }
  assert.ok(taken > SEEDS && refused > SEEDS, `${taken} taken, ${refused} refused`);
});

// ── the keeper ───────────────────────────────────────────────────────────────────────────────────────────────────

const WS = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";
const ITEM = "i_01HZZZZZZZZZZZZZZZZZZZZZZZ";

/// A lock (alice, the vault's owner, and bob, its members, with Ed25519 signers; carol, of the workspace and not the
/// vault, signing with ES256), the vault and an item agents may ask for.
function world() {
  const ed = (n: number) => key(n);
  const alice = { sub: "alice", signer: ed(31), base: ed(32) };
  const bob = { sub: "bob", signer: ed(33), base: ed(34) };
  const carolSigner = es256();
  const carol = { sub: "carol", base: ed(35) };
  const body = {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
    members: [{ sub: "alice", email: "alice@x.com", role: "owner" }, { sub: "bob", email: "bob@x.com", role: "member" }, { sub: "carol", email: "carol@x.com", role: "member" }],
    devices: [
      { id: alice.base.hex, sub: "alice", kind: "app", label: "alice", sign_key: alice.signer.id },
      { id: bob.base.hex, sub: "bob", kind: "app", label: "bob", sign_key: bob.signer.id },
      { id: carol.base.hex, sub: "carol", kind: "app", label: "carol", sign_key: carolSigner.id },
    ],
    passkeys: [], stations: [], gateways: [],
  };
  const e = { v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis", body } as Omit<Entry, "sig">;
  const state = genesis({ ...e, sig: { key: alice.signer.id, alg: "Ed25519" as const, sig: alice.signer.sign(lockBytes(entryHash(e as Entry))) } });
  const sign = (o: any, tag: string, by: "alice" | "bob" | "carol" | "stranger") => {
    const k = by === "alice" ? alice.signer : by === "bob" ? bob.signer : ed(77);
    try {
      return by === "carol" ? { ...o, sig: carolSigner.sig(o, tag) } : { ...o, sig: { key: k.id, alg: "Ed25519", sig: k.sign(signedBytes(o, tag)) } };
    } catch {
      // (a record with no canonical text, a number not whole in it: signed over nothing, refused before its signature)
      return { ...o, sig: { key: k.id, alg: "Ed25519", sig: "00" } };
    }
  };
  const vault = sign({ v: 1, ws: WS, id: VAULT, seq: 0, owner: "alice", name: "Personal", members: ["alice", "bob", "carol"], epoch: 0, keys: [], at: 1000, lasts: "chat" }, TAG.vault, "alice");
  const item = sign({
    v: 1, ws: WS, vault: VAULT, id: ITEM, version: 0, epoch: 0, ct: encryptWith(fill(4), utf8("{}"), itemContext(WS, VAULT, ITEM, 0, 0), fill(5, 12)),
    listing: { name: "GitHub", kind: "token", modes: ["proxy", "env", "browser"], hosts: ["api.github.com", "*.example.com"], env: "GH_TOKEN" }, at: 1000,
  }, TAG.item, "alice");
  return { state, lj: lockJson(state), vault, item, sign };
}

/// The TypeScript keeper on the same clock, timers and store the program's harness keeps (harness.mbt `World`).
function tsSide(now0: number, keptOn: boolean) {
  let nowMs = now0 * 1000;
  let seq = 0;
  const timers: { due: number; seq: number; f: () => void; alive: boolean }[] = [];
  const answers: Record<string, unknown> = {};
  const log: unknown[] = [];
  const ended = new Set<string>();
  const told = (call: string, h: Held, at?: number) => log.push({ call, id: h.request.id, uses: h.uses, ...(h.until !== undefined ? { until: h.until } : {}), ...(at !== undefined ? { at } : {}) });
  const flag = (v: unknown) => (v === true || v === false ? v : null);
  const kept = {
    save: (h: Held) => told("save", h),
    forget: (h: Held) => told("forget", h),
    spendOnce: (h: Held) => (told("spendOnce", h), flag(answers.spendOnce)),
    spendAgain: (h: Held) => (told("spendAgain", h), flag(answers.spendAgain)),
    renew: (h: Held, until: number) => (told("renew", h, until), typeof answers.renew === "number" ? answers.renew : answers.renew === false ? false : null),
    current: (h: Held) => {
      told("current", h);
      const c = answers.current as any;
      return c === false ? false : c !== null && typeof c === "object" ? { uses: typeof c.uses === "number" ? c.uses : 0, ...(typeof c.until === "number" ? { until: c.until } : {}) } : null;
    },
    expire: (h: Held, now: number) => (told("expire", h, now), flag(answers.expire)),
  };
  const keeper = new Keeper(() => nowMs / 1000, { ended: (s) => ended.has(s), ...(keptOn ? { kept } : {}) });
  const fake = (ms: number, f: () => void) => {
    const t = { due: nowMs + ms, seq: ++seq, f, alive: true };
    timers.push(t);
    return () => void (t.alive = false);
  };
  const advance = (sec: number) => {
    nowMs = sec * 1000;
    for (;;) {
      let next: (typeof timers)[number] | undefined;
      for (const t of timers) if (t.alive && t.due <= nowMs && (next === undefined || t.due < next.due || (t.due === next.due && t.seq < next.seq))) next = t;
      if (next === undefined) break;
      next.alive = false;
      wall.after = fake;
      next.f();
    }
    const alive = timers.filter((t) => t.alive);
    timers.length = 0;
    timers.push(...alive);
    return timers.length;
  };
  return { keeper, answers, log, ended, advance, fake };
}

const asJson = (v: unknown) => JSON.parse(JSON.stringify(v ?? null));
/// A held grant without what is each side's own of it: the secret sealed to its own box, and the signature over that.
const bare = (h: any) => (h?.grant?.secret ? { ...h, grant: { ...h.grant, secret: "(sealed)", sig: "(signed)" } } : h);
const heldOf = (h: Held | string) => (typeof h === "string" ? { why: h } : { held: bare(asJson(h)) });
const bareAll = (v: any) => (Array.isArray(v) ? v.map(bare) : v?.held !== undefined ? { ...v, held: bare(v.held) } : v);

test("the keeper: the program and keeper.ts in lockstep on random asks, their store and clock scripted alike", { skip }, async () => {
  const p = mb();
  const w = world();
  const realAfter = wall.after;
  // what the asks came to, so that a generator whose grants all fail one check is seen to test little
  const seen = new Map<string, number>();
  const saw = (what: string) => seen.set(what, (seen.get(what) ?? 0) + 1);
  try {
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(5000 + seed);
      const keptOn = r.int(4) !== 0;
      const ts = tsSide(1000, keptOn);
      wall.after = ts.fake;
      await p.ask("keeper.new", { now: 1000, kept: keptOn });
      let now = 1000;
      const boxes = new Map<string, { ts: string; mb: string }>();
      const requests = new Map<string, any>();
      const ids = Array.from({ length: 6 }, (_, i) => `r_${seed}_${i}`);
      const sessions = ["s1", "s2"];
      const same = async (what: string, tsValue: unknown, op: string, args: Record<string, unknown> = {}) => {
        const got = await p.said(op, args);
        assert.deepEqual("value" in got ? { value: bareAll(got.value) } : got, { value: bareAll(asJson(tsValue)) }, `seed ${seed}: ${what}`);
        if (["accept", "take", "hold"].includes(what)) saw(tsValue === null ? `${what}: taken` : `refused: ${tsValue}`);
        if (what === "usable") saw(typeof tsValue === "object" && tsValue !== null && "why" in tsValue ? `usable: ${(tsValue as any).why}` : "usable: held");
      };
      for (let step = 0; step < 80; step++) {
        const id = r.pick(ids);
        const session = r.pick(sessions);
        if (keptOn && r.int(3) === 0) {
          const answers = {
            spendOnce: r.pick([true, false, null, null]), spendAgain: r.pick([true, false, null, null]),
            renew: r.pick([false, null, null, now + 100]), current: r.pick([null, null, null, false, { uses: r.int(3) }, { uses: 0, until: now + r.int(4000) }]),
            expire: r.pick([true, false, null, null]),
          };
          Object.assign(ts.answers, answers);
          await p.ask("kept.answer", { answers });
        }
        const pick = r.int(15);
        if (pick === 0) {
          // a box opened: its public half differs (each its own random key), its being there does not
          const tsPub = ts.keeper.open(id);
          const mbPub = await p.ask("keeper.open", { request: id });
          boxes.set(id, { ts: tsPub, mb: mbPub });
          requests.set(id, { id, ws: WS, vault: VAULT, item: ITEM, session, chat: "CHAT/1.0", mode: r.int(10) ? r.pick(["proxy", "env", "browser"]) : "ssh", reason: "test", at: 1000, status: r.int(15) ? "pending" : "denied", ...(r.int(6) === 0 ? { timeout: { kind: "idle", seconds: 600 } } : {}) });
        } else if (pick <= 3 && requests.has(id)) {
          // a grant: sealed to the program's box by TypeScript, to TypeScript's by the program
          const req = requests.get(id);
          const scope = r.int(12) ? r.pick(["once", "hour", "chat"]) : "week";
          const timeout = r.int(3) === 0 && scope !== "once" ? { kind: r.int(6) ? r.pick(["idle", "fixed"]) : "never", seconds: r.int(6) ? r.pick([60, 600, 3600]) : r.pick([0, 1.5]) } : undefined;
          const at = now;
          const exp = timeout !== undefined && r.int(6) ? at + timeout.seconds : r.int(4) ? r.pick([now + 600, now + 3600]) : r.pick([now + 3700, now - 1, now + 30 * 86400]);
          const secret = r.pick([{ kind: "token", name: "GitHub", fields: { value: "ghp_x" } }, { kind: "login", name: "L", fields: { username: "u", password: "p" } }, { kind: "token", name: "E", fields: { value: "" } }]);
          const hosts = r.int(4) ? r.pick([["api.github.com"], ["a.example.com"], ["*.example.com"]]) : r.pick([[], ["evil.com"], ["API.GITHUB.COM."], ["example.com"]]);
          const mode = r.int(12) ? req.mode : "env";
          const by = r.int(6) ? r.pick(["alice", "bob", "carol"] as const) : "stranger";
          const v = r.int(30) ? 1 : 2;
          const body = (sealedTo: string) => ({ v, ws: WS, request: id, vault: VAULT, item: ITEM, mode, hosts, scope, exp, ...(timeout ? { timeout } : {}), secret: sealedTo, at });
          const plain = utf8(JSON.stringify(secret));
          const ctx = grantContext(WS, id);
          const pair = boxes.get(id)!;
          const tamper = r.int(15) === 0;
          const forTs = w.sign(body(await p.ask("seal", { pub: pair.ts, plain: hex(plain), context: ctx })), TAG.grant, by);
          const forMb = w.sign(body(seal(pair.mb, plain, ctx)), TAG.grant, by);
          if (tamper) forTs.at = forMb.at = at + 1;
          const reqNow = { ...req, box: "x" };
          if (r.int(3) === 0) {
            const prepared = ts.keeper.prepareAccept(w.state, w.vault as any, w.item as any, reqNow, forTs);
            const mbPrepared = await p.ask("keeper.prepare", { lock: w.lj, vault: w.vault, item: w.item, req: reqNow, grant: forMb });
            if (typeof prepared === "string") assert.deepEqual(mbPrepared, { why: prepared }, `seed ${seed}: prepare`);
            else {
              assert.ok(typeof mbPrepared.ready === "number", `seed ${seed}: prepared ${JSON.stringify(mbPrepared)}`);
              if (r.int(3) === 0) {
                now += r.pick([0, 600, 4000]);
                await same("clock", ts.advance(now), "clock", { now });
              }
              if (r.int(4) === 0) {
                const tsPub = ts.keeper.open(id);
                const mbPub = await p.ask("keeper.open", { request: id });
                boxes.set(id, { ts: tsPub, mb: mbPub });
              }
              await same("take", prepared(), "keeper.take", { token: mbPrepared.ready });
            }
          } else {
            await same("accept", ts.keeper.accept(w.state, w.vault as any, w.item as any, reqNow, forTs), "keeper.accept", { lock: w.lj, vault: w.vault, item: w.item, req: reqNow, grant: forMb });
          }
        } else if (pick === 4) {
          const req = requests.get(id) ?? { id, ws: WS, vault: "plain", item: ITEM, session, mode: "proxy", status: "pending" };
          const d = {
            scope: r.pick(["once", "hour", "chat", "week"]), hosts: r.pick([["api.github.com"], [], ["x.example.com"], ["nope.io"]]),
            listing: { modes: r.pick([["proxy"], ["env", "proxy"], ["browser"]]), hosts: ["api.github.com", "*.example.com"] }, lasts: r.pick([null, "once", "hour", "chat"]),
            ...(r.int(3) === 0 ? { timeout: { kind: r.pick(["idle", "fixed"]), seconds: r.pick([60, 0, 99999999]) } } : {}),
          };
          const secret = r.pick([{ kind: "token", name: "T", fields: { value: "v" } }, { kind: "file", name: "F", fields: { content: "" } }]);
          await same("hold", ts.keeper.hold(req, d as any, secret as any), "keeper.hold", { req, d, secret });
        } else if (pick === 5) {
          now += r.pick([1, 60, 600, 3599, 3601, 7200]);
          await same("clock", ts.advance(now), "clock", { now });
        } else if (pick === 6) {
          await same("usable", heldOf(ts.keeper.usable(session, id)), "keeper.usable", { session, request: id });
        } else if (pick === 7) {
          await same("spend", ts.keeper.spend(id), "keeper.spend", { request: id });
        } else if (pick === 8) {
          ts.keeper.renew(session, id);
          await same("renew", null, "keeper.renew", { session, request: id });
        } else if (pick === 9) {
          await same("active", ts.keeper.active(session, id), "keeper.active", { session, request: id });
        } else if (pick === 10) {
          const which = r.pick(["drop", "discardBox", "end"] as const);
          if (which === "end") ts.keeper.end(session);
          else ts.keeper[which](id);
          await same(which, null, `keeper.${which}`, which === "end" ? { session } : { request: id });
        } else if (pick === 11) {
          const gone = r.int(3) === 0 ? [session] : [];
          ts.ended.clear();
          for (const s of gone) ts.ended.add(s);
          await p.ask("ended", { sessions: gone });
        } else if (pick === 12) {
          // an ask in a transaction that fails: what it changed of the request is put back
          const inner = r.pick([{ op: "keeper.spend", request: id }, { op: "keeper.drop", request: id }, { op: "keeper.discardBox", request: id }]);
          try {
            ts.keeper.rollbackOnError(id, () => {
              if (inner.op === "keeper.spend") ts.keeper.spend(id);
              else if (inner.op === "keeper.drop") ts.keeper.drop(id);
              else ts.keeper.discardBox(id);
              throw new Error("rolled back");
            });
          } catch {}
          await p.ask("keeper.rollback", { request: id, inner });
        } else if (pick === 13) {
          // a grant kept from before a restart, given back to both
          const h = { request: { id, ws: WS, vault: VAULT, item: ITEM, session, mode: "proxy", status: "granted" }, grant: { v: 1, ws: WS, request: id, vault: VAULT, item: ITEM, mode: "proxy", hosts: ["api.github.com"], scope: r.pick(["once", "hour"]), exp: now + r.pick([-5, 30, 600]), secret: "", at: now }, secret: { kind: "token", name: "T", fields: { value: "v" } }, uses: r.int(2), ...(r.int(3) === 0 ? { until: now + 100 } : {}) };
          ts.keeper.restore(structuredClone(h) as any);
          await same("restore", null, "keeper.restore", { held: h });
        } else {
          await same("held", ts.keeper.held(session), "keeper.held", { session });
        }
        await same("holds", ts.keeper.holds(session), "keeper.holds", { session });
        await same("hasGrant", ts.keeper.hasGrant(id), "keeper.hasGrant", { request: id });
        await same("waiting", ts.keeper.waiting(id), "keeper.waiting", { request: id });
        const told = asJson(ts.log.splice(0));
        assert.deepEqual(await p.ask("kept.log"), told, `seed ${seed}, step ${step}: what the store was told`);
        for (const t of told) saw(`told: ${t.call}`);
        const tsCarried = asJson(ts.keeper.carried());
        const mbCarried = await p.ask("keeper.carried");
        assert.deepEqual(mbCarried.held.map(bare), tsCarried.held.map(bare), `seed ${seed}, step ${step}: held`);
        assert.deepEqual(mbCarried.boxes.map((b: string[]) => b[0]), tsCarried.boxes.map((b: string[]) => b[0]), `seed ${seed}, step ${step}: boxes`);
      }
    }
  } finally {
    wall.after = realAfter;
  }
  if (process.env.KEEPER_TRACE) console.error([...seen].sort((a, b) => b[1] - a[1]));
  for (const what of ["accept: taken", "take: taken", "hold: taken", "usable: held", "told: save", "told: forget", "told: current", "told: expire", "told: spendOnce", "told: spendAgain", "told: renew"]) {
    assert.ok((seen.get(what) ?? 0) > 0, `${what}: never`);
  }
  assert.ok([...seen.keys()].filter((k) => k.startsWith("refused: ")).length >= 12, `refusals: ${[...seen.keys()].filter((k) => k.startsWith("refused: "))}`);
  assert.ok([...seen.keys()].filter((k) => k.startsWith("usable: ")).length >= 5, `usable: ${[...seen.keys()].filter((k) => k.startsWith("usable: "))}`);
});

test("a handover between the two: what one held the other takes up, boxes and grants, one-use grants' uses kept", { skip }, async () => {
  const p = mb();
  const w = world();
  const realAfter = wall.after;
  try {
    const ts = tsSide(1000, false);
    wall.after = ts.fake;
    await p.ask("keeper.new", { now: 1000 });
    const req = (id: string, session = "s1") => ({ id, ws: WS, vault: VAULT, item: ITEM, session, chat: "CHAT/1.0", mode: "proxy", reason: "t", box: "x", at: 1000, status: "pending" }) as any;
    const secret = { kind: "token", name: "GitHub", fields: { value: "ghp_handed" } };
    const grantTo = (pub: string, id: string, scope = "once", sealer: (pub: string, plain: Uint8Array, ctx: string) => string | Promise<string> = seal) =>
      Promise.resolve(sealer(pub, utf8(JSON.stringify(secret)), grantContext(WS, id))).then((s) => w.sign({ v: 1, ws: WS, request: id, vault: VAULT, item: ITEM, mode: "proxy", hosts: ["api.github.com"], scope, exp: 1600, secret: s, at: 1000 }, TAG.grant, "bob"));
    const mbSeal = async (pub: string, plain: Uint8Array, context: string) => p.ask("seal", { pub, plain: hex(plain), context });
    // TypeScript's boxes and grants carried to the program: a box opened there is accepted here (sealed by the program)
    const tsBox = ts.keeper.open("r_ts_box");
    const tsGrantBox = ts.keeper.open("r_ts_grant");
    assert.equal(ts.keeper.accept(w.state, w.vault as any, w.item as any, req("r_ts_grant"), await grantTo(tsGrantBox, "r_ts_grant", "hour", mbSeal)), null);
    ts.keeper.spend("r_ts_grant");
    await p.ask("keeper.carry", { carried: asJson(ts.keeper.carried()) });
    assert.deepEqual(bareAll(await p.ask("keeper.usable", { session: "s1", request: "r_ts_grant" })), heldOf(ts.keeper.usable("s1", "r_ts_grant")));
    assert.equal(await p.ask("keeper.waiting", { request: "r_ts_box" }), true);
    assert.equal(await p.ask("keeper.accept", { lock: w.lj, vault: w.vault, item: w.item, req: req("r_ts_box"), grant: await grantTo(tsBox, "r_ts_box") }), null);
    assert.equal((await p.ask("keeper.usable", { session: "s1", request: "r_ts_box" })).held.secret.fields.value, "ghp_handed");
    // and the program's back to TypeScript: its box opened there, accepted here, sealed by TypeScript
    const mbBox = await p.ask("keeper.open", { request: "r_mb_box" });
    await p.ask("keeper.spend", { request: "r_ts_box" });
    const back = new Keeper(() => 1000);
    back.carry(await p.ask("keeper.carried"));
    assert.equal(back.accept(w.state, w.vault as any, w.item as any, req("r_mb_box"), await grantTo(mbBox, "r_mb_box")), null);
    assert.equal((back.usable("s1", "r_mb_box") as Held).secret.fields.value, "ghp_handed");
    assert.match(back.usable("s1", "r_ts_box") as string, /one use and is used/);
    assert.deepEqual(heldOf(back.usable("s1", "r_ts_grant")), bareAll(await p.ask("keeper.usable", { session: "s1", request: "r_ts_grant" })));
    // a one-use grant used on either side after the other read it: the uses carried over are the most of both
    await p.ask("keeper.new", { now: 1000 });
    await p.ask("keeper.restore", { held: asJson(back.carried().held.find((h) => h.request.id === "r_mb_box")) });
    back.spend("r_mb_box");
    await p.ask("keeper.carry", { carried: asJson(back.carried()) });
    assert.match((await p.ask("keeper.usable", { session: "s1", request: "r_mb_box" })).why, /one use and is used/);
  } finally {
    wall.after = realAfter;
  }
});

test("hostAllowed, valueOf and accountOf: the same answers", { skip }, async () => {
  const p = mb();
  const patterns = [["api.github.com"], ["*.example.com"], ["*.example.com", "x.io"], [], ["Key.com"]];
  for (const host of ["api.github.com", "API.GitHub.com.", "example.com", "a.example.com", "a.b.example.com", ".example.com", "x.io", "Key.com", "key.com", "", "evil.com"]) {
    for (const ps of patterns) assert.equal(await p.ask("hostAllowed", { host, patterns: ps }), hostAllowed(host, ps), `${host} ${ps}`);
  }
  const secrets = [
    { kind: "token", fields: { value: "v" } }, { kind: "token", fields: { value: "" } }, { kind: "token" }, { kind: "ssh_key", fields: { private_key: "k" } },
    { kind: "login", fields: { username: "u", password: "p" } }, { kind: "login", fields: { password: "p" } }, { kind: "file", fields: { content: "AA==" } },
    { kind: "browser", fields: { cookies: "[]" } }, { kind: "magic", fields: { value: "v" } }, { kind: "token", fields: "v" }, { kind: "token", fields: null },
  ];
  for (const s of secrets) {
    assert.equal(await p.ask("valueOf", { secret: s }), valueOf(s as any), JSON.stringify(s));
    assert.equal(await p.ask("accountOf", { secret: s }), accountOf(s as any), JSON.stringify(s));
  }
});

// ── the plain library ─────────────────────────────────────────────────────────────────────────────────────────────

test("the plain library: the same checks, and the tables written by one read by the other byte for byte", { skip }, async () => {
  const p = mb();
  const r = rng(99);
  const dir = tmp();
  const tsDb = new DatabaseSync(join(dir, "ts.db"));
  const store = new PlainStore(tsDb);
  await p.ask("db.open", { path: join(dir, "mb.db") });
  await p.ask("plain.open");
  const owners = ["a@x.com", "b@x.com"];
  const kept = new Map<string, any>();
  const wsOf = () => r.pick([WS, "01OTHER"]);
  for (let n = 0; n < 160; n++) {
    const prev = kept.size && r.int(2) ? r.pick([...kept.values()]) : null;
    const owner = prev && r.int(8) ? prev.owner : r.pick(owners);
    const kind = r.pick(["token", "ssh_key", "login", "file", "browser", "magic"]);
    const fieldsOf: Record<string, unknown> = {
      token: { value: r.pick(["v", "名字 😀 ", "a\"b\\c\u0001", "\ud800x"]) }, ssh_key: { private_key: "k", public_key: "p" },
      login: { username: "u", password: "p", totp: "t" }, browser: { cookies: "[]" }, magic: { value: "v" },
      file: {
        content: r.pick(["", "AAAA", "AA==", "AAAA", "A===", "AAA", "A+/=", "AA*A", "A".repeat(87384), "A".repeat(87388)]),
        ...(r.int(2) ? { filename: r.pick(["f.txt", "f.txt", "../x", ".", "a\\b", "x".repeat(201)]) } : {}),
      },
    };
    const fields: any = r.int(8) ? fieldsOf[kind] : r.pick([{ extra: "x" }, null, [], "str", { value: 5 }]);
    const listing: any = r.int(2) ? undefined : {
      name: r.pick(["L", "L", "x".repeat(201)]), kind: r.int(8) ? kind : "token",
      modes: kind === "file" && r.int(3) ? ["file"] : kind === "browser" && r.int(3) ? ["browser"] : r.pick([["env"], ["env"], ["proxy"], ["file"], ["file", "env"], ["browser"], [], ["nope"]]),
      hosts: r.pick([["api.github.com"], ["api.github.com"], [], ["*.example.com"], ["Bad Host"], [5]]),
      ...(r.int(3) === 0 ? { env: r.pick(["GH", "1X", "_ok", "a-b"]) } : {}),
      ...(r.int(4) === 0 ? { lasts: r.pick(["once", "week"]) } : {}),
      ...(r.int(5) === 0 ? { about: r.pick(["about", "x".repeat(2001)]) } : {}),
    };
    const item: any = {
      ws: wsOf(), id: prev && r.int(3) ? prev.id : r.int(15) ? `i_${ulid(r)}` : r.pick(["i_short", 5, "i_" + "a".repeat(26)]), owner: r.int(12) ? owner : "eve@x.com",
      version: (prev?.version ?? -1) + 1, kind, name: r.int(5) ? r.pick(["Name", "名字 😀"]) : r.pick([" ", "\u3000", "x".repeat(201)]), fields, notes: r.int(10) ? r.pick(["", "n"]) : "x".repeat(10001),
      ...(listing ? { listing } : {}), at: r.int(15) ? 1000 + n : 1.5, ...(r.int(10) === 0 ? { deleted: true } : {}),
    };
    if (prev) item.ws = prev.ws;
    const want = plainOk(prev, item, owner);
    assert.equal(await p.ask("plainOk", { prev, next: item, owner }), want, JSON.stringify(item).slice(0, 300));
    if (item.fields && typeof item.fields === "object" && !Array.isArray(item.fields)) assert.equal(await p.ask("fileOk", { fields: item.fields }), fileOk(item.fields));
    if (want === null) {
      store.put(item);
      await p.ask("plain.put", { item });
      kept.set(item.id, item);
    }
    if (r.int(10) === 0 && kept.size) {
      const gone = r.pick([...kept.values()]);
      store.forget(gone.ws, gone.id);
      await p.ask("plain.forget", { ws: gone.ws, item: gone.id });
      kept.delete(gone.id);
    }
    if (r.int(6) === 0) {
      const lasts = r.pick(["once", "hour", "chat", "week", 3]);
      const at = r.pick([1000 + n, 900, 1.5, "x"]);
      assert.equal(await p.ask("plain.setLasts", { ws: WS, owner, lasts, at }), store.setLasts(WS, owner, lasts, at));
    }
  }
  assert.ok(kept.size > 10, `${kept.size} kept`);
  // what each wrote, each reads the same, and the other's table holds the same bytes
  const mbDb = new DatabaseSync(join(dir, "mb.db"));
  const rows = (db: DatabaseSync) => [db.prepare("SELECT ws, id, owner, version, body FROM vault_plain ORDER BY ws, id").all(), db.prepare("SELECT * FROM vault_plain_lasts ORDER BY ws, owner").all()];
  assert.deepEqual(rows(mbDb), rows(tsDb));
  const fromMb = new PlainStore(mbDb);
  for (const ws of [WS, "01OTHER"]) {
    for (const owner of [...owners, "eve@x.com"]) {
      assert.deepEqual(await p.ask("plain.items", { ws, owner }), asJson(store.items(ws, owner)));
      assert.deepEqual(fromMb.items(ws, owner), store.items(ws, owner));
      assert.deepEqual(await p.ask("plain.firstItems", { ws, owner, limit: 3 }), asJson(store.firstItems(ws, owner, 3)));
      const first = store.firstItems(ws, owner, 1)[0];
      if (first) assert.deepEqual(await p.ask("plain.itemsAfter", { ws, owner, item: first.id }), asJson(store.itemsAfter(ws, owner, first.id)));
      assert.deepEqual(await p.ask("plain.lasts", { ws, owner }), asJson(store.lasts(ws, owner)));
    }
  }
  for (const i of [...kept.values()].slice(0, 20)) {
    assert.deepEqual(await p.ask("plain.itemSnapshot", { ws: i.ws, item: i.id }), asJson(store.itemSnapshot(i.ws, i.id)));
    assert.deepEqual(await p.ask("plain.item", { ws: i.ws, item: i.id }), asJson(store.item(i.ws, i.id)));
    assert.deepEqual(await p.ask("shown", { item: i }), asJson(shown(i)));
  }
  assert.equal(await p.ask("plain.item", { ws: WS, item: "i_none" }), null);
  mbDb.close();
  tsDb.close();
});

test("a vault index's schema installed: the same statements refused in the same words, the same tables made, in a transaction too", { skip }, async () => {
  const p = mb();
  const dir = tmp();
  const schemas: [string, string, string[]][] = [
    ["t_ok", "CREATE TABLE IF NOT EXISTS t_ok (a TEXT);\n-- a comment; with a semicolon\nCREATE INDEX IF NOT EXISTS t_ok_a ON t_ok (a);", []],
    ["t_trig", "CREATE TABLE IF NOT EXISTS t_trig (a TEXT);\ncreate trigger if not exists t_trig_t AFTER INSERT ON t_trig BEGIN\n  UPDATE t_trig SET a = a; END;\n", []],
    ["t_seed", "CREATE TABLE IF NOT EXISTS t_seed (k TEXT PRIMARY KEY);\nINSERT OR IGNORE INTO t_seed (k) VALUES ('x');", ["SELECT 1 FROM t_seed WHERE k = 'x'"]],
    ["t_unseen", "CREATE TABLE IF NOT EXISTS t_unseen (k TEXT);\nINSERT OR IGNORE INTO t_unseen (k) VALUES ('x');", ["SELECT 1 FROM other"]],
    ["t_drop", "DROP TRIGGER IF EXISTS old_t;\nCREATE TABLE IF NOT EXISTS t_drop (a TEXT);", []],
    ["t_unique", "CREATE UNIQUE INDEX IF NOT EXISTS t_u ON t_ok (a);", []],
    ["t_plain", "CREATE TABLE t_plain (a TEXT);", []],
    ["t_long", `ALTER TABLE t_ok ADD COLUMN ${"x".repeat(100)} TEXT;`, []],
  ];
  for (const inTx of [false, true]) {
    const tsDb = new DatabaseSync(join(dir, `ts-${inTx}.db`));
    await p.ask("db.open", { path: join(dir, `mb-${inTx}.db`) });
    if (inTx) {
      tsDb.exec("BEGIN IMMEDIATE");
      await p.ask("db.exec", { sql: "BEGIN IMMEDIATE" });
    }
    assert.equal(await p.ask("db.inTransaction"), tsDb.isTransaction);
    for (const [name, schema, rows] of schemas) {
      let want: string | null = null;
      try {
        installSchema(tsDb, name, schema, rows);
      } catch (e) {
        want = e instanceof UnaccountedSchema ? (e as Error).message : `sql: ${(e as Error).message}`;
      }
      const got = await p.said("schema.install", { name, schema, rows });
      if (want === null) assert.deepEqual(got, { value: null }, name);
      else if (want.startsWith("sql: ")) assert.ok(got.error !== undefined, `${name}: ${want}`);
      else assert.deepEqual(got, { error: want }, name);
      // installed again: nothing to do, or the same refusal
      const again = await p.said("schema.install", { name, schema, rows });
      if (want === null) assert.deepEqual(again, { value: null }, `${name} again`);
    }
    if (inTx) {
      tsDb.exec("COMMIT");
      await p.ask("db.exec", { sql: "COMMIT" });
    }
    const master = (rows: any[]) => rows.map((x) => (Array.isArray(x) ? x : Object.values(x)).join("|"));
    const q = "SELECT type, name, tbl_name FROM sqlite_master ORDER BY name";
    assert.deepEqual(master(await p.ask("db.all", { sql: q })), master(tsDb.prepare(q).all()));
    const seeded = "SELECT k FROM t_seed";
    assert.deepEqual(master(await p.ask("db.all", { sql: seeded })), master(tsDb.prepare(seeded).all()));
    tsDb.close();
  }
});
