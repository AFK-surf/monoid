// The vault's rules as rules/ (MoonBit) has them, as station/src/vault/crypto.ts calls them, against the TypeScript
// they replaced (vault-oracle.ts): on seeded random locks (lock-chains.ts) and random box certificates, vault versions
// and item versions (each now and then of a wrong shape, signed by a key that may not sign it, or forged), the same
// answer in the same words, first versions and following ones, kept and brought as copies.
import assert from "node:assert/strict";
import { test } from "node:test";
import { type Entry, fold } from "../../shared/lock.ts";
import { TAG, browserListingOk, certOk, itemOk, signedBytes, signerOf, vaultOk } from "../src/vault/crypto.ts";
import { WS, bases, genesisOf, key, nextOf, people, rng, signers, spare } from "./lock-chains.ts";
import * as oracle from "./vault-oracle.ts";

const SEEDS = Number(process.env.RULES_SEEDS ?? 40);
type R = ReturnType<typeof rng>;
const boxes = Array.from({ length: 4 }, (_, i) => `x25519:${key(70 + i).hex}`);
const ULID = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const ulid = (r: R) => Array.from({ length: 26 }, () => ULID[r.int(ULID.length)]).join("");
const b64 = (r: R, n: number) => Array.from({ length: n }, () => "ABCxyz019_-"[r.int(11)]).join("");

/// Signed under `tag` by a key of the lock's (or not), the signature now and then broken or missing.
function signed<T extends Record<string, unknown>>(r: R, o: T, tag: string, k = r.pick([...signers, ...spare.slice(0, 2)])): T & { sig: unknown } {
  // (a record with no canonical text, a number not whole in it, signed over nothing: refused before its signature)
  let bytes: Buffer;
  try {
    bytes = Buffer.from(signedBytes(o, tag));
  } catch {
    bytes = Buffer.alloc(0);
  }
  const sig = { key: k.id, alg: "Ed25519", sig: k.sign(bytes) };
  const roll = r.int(20);
  return { ...o, sig: roll === 0 ? { ...sig, sig: "00" + sig.sig.slice(2) } : roll === 1 ? { key: k.id, alg: "RSA", sig: "x" } : roll === 2 ? undefined : sig };
}

function certOf(r: R): any {
  const i = r.int(people.length);
  const odd = r.int(10) === 0;
  const c: Record<string, unknown> = {
    v: odd && r.int(2) ? 2 : 1, ws: r.int(25) === 0 ? "other" : WS,
    device: r.int(12) === 0 ? r.pick(["nothex", 5, [bases[i]!.hex]]) : r.int(6) === 0 ? r.pick(spare).hex : bases[i]!.hex,
    box: r.int(20) === 0 ? "x25519:zz" : r.pick(boxes), at: r.int(25) === 0 ? 1.5 : 1000 + r.int(100),
  };
  return signed(r, c, TAG.box, r.int(4) === 0 ? r.pick([...signers, ...spare]) : signers[i]!);
}

function vaultOf(r: R, prev: any | null): any {
  const owner = prev && r.int(8) ? prev.owner : r.pick(people);
  const members = [owner, ...people.filter((p) => p !== owner && r.int(2) === 0)];
  if (r.int(15) === 0) members.push(r.pick(["eve", "", owner]));
  const keys = Array.from({ length: r.int(4) }, () => (r.int(20) === 0 ? r.pick([null, { cert: certOf(r) }]) : { cert: certOf(r), wrapped: r.int(25) === 0 ? "+bad" : b64(r, 40) }));
  const v: Record<string, unknown> = {
    v: 1, ws: r.int(30) === 0 ? "other" : WS, id: prev && r.int(10) ? prev.id : r.int(12) === 0 ? "v_short" : `v_${ulid(r)}`,
    seq: prev ? prev.seq + r.pick([1, 1, 1, 2, 0, -1]) : r.int(6) === 0 ? 3 : 0, owner, name: r.pick(["Work", "名字 😀", ""]), members,
    epoch: prev ? prev.epoch + r.pick([0, 0, 1, -1]) : r.int(3), keys, at: 1000 + r.int(1000),
  };
  if (r.int(5) === 0) v.recovery = r.int(6) === 0 ? 7 : b64(r, 30);
  if (r.int(5) === 0) v.lasts = r.pick(["once", "hour", "chat", "week"]);
  if (r.int(12) === 0) {
    v.deleted = r.int(4) ? true : "yes";
    if (r.int(2)) v.keys = [];
  }
  if (r.int(25) === 0) v.seq = 1.5;
  const by = r.int(3) === 0 ? r.pick([...signers, ...spare.slice(0, 2)]) : signers[people.indexOf(owner)]!;
  return signed(r, v, TAG.vault, by);
}

function listingOf(r: R): unknown {
  const kind = r.pick(["token", "ssh_key", "login", "file", "browser", "magic"]);
  const l: Record<string, unknown> = {
    name: r.pick(["GitHub", "x".repeat(250)]), kind,
    modes: kind === "browser" && r.int(3) ? ["browser"] : r.pick([["proxy"], ["env", "proxy"], ["browser", "env"], ["ssh", "ssh"], ["telepathy"]]),
    hosts: r.pick([[], ["github.com"], ["*.example.com"], ["Bad Host"], ["a-.com"], ["api.github.com", "x.io"]]),
  };
  if (r.int(4) === 0) l.env = r.pick(["GITHUB_TOKEN", "1BAD", "_ok"]);
  if (r.int(6) === 0) l.lasts = r.pick(["hour", "forever"]);
  return l;
}

function itemOf(r: R, vault: any, prev: any | null): any {
  const deleted = r.int(10) === 0;
  const i: Record<string, unknown> = {
    v: 1, ws: r.int(30) === 0 ? "other" : WS, vault: r.int(20) === 0 ? "v_other" : vault.id, id: prev && r.int(10) ? prev.id : r.int(12) === 0 ? "i_x" : `i_${ulid(r)}`,
    version: prev ? prev.version + r.pick([1, 1, 2, 0]) : r.int(6) === 0 ? 2 : 0, epoch: r.int(5) === 0 ? vault.epoch + r.pick([1, -1]) : vault.epoch,
    ct: deleted ? (r.int(3) ? "" : b64(r, 40)) : r.int(15) === 0 ? b64(r, 10) : r.int(25) === 0 ? "+" + b64(r, 40) : b64(r, 60), at: 1000 + r.int(100),
  };
  if (deleted) i.deleted = r.int(5) ? true : 1;
  if (!deleted && r.int(2)) i.listing = listingOf(r);
  if (deleted && r.int(6) === 0) i.listing = listingOf(r);
  const by = r.int(4) === 0 ? r.pick([...signers, ...spare]) : signers[people.indexOf(r.pick(vault.members?.filter((m: string) => people.includes(m)) ?? people) as string)] ?? signers[0]!;
  return signed(r, i, TAG.item, by);
}

test("the MoonBit vault rules answer random certificates, vaults and items as the TypeScript did, in the same words", () => {
  const counts = { cert: [0, 0], vault: [0, 0], item: [0, 0] };
  const reasons = new Map<string, number>();
  const tally = (what: keyof typeof counts, why: string | null) => {
    counts[what][why === null ? 0 : 1]!++;
    if (why !== null) reasons.set(why, (reasons.get(why) ?? 0) + 1);
  };
  for (let seed = 1; seed <= SEEDS; seed++) {
    const r = rng(1000 + seed);
    // A lock as a random chain leaves it (who is a member, which device signs, which is its person's own).
    const chain: Entry[] = [genesisOf(r)];
    for (let i = 1; i <= 12; i++) {
      const next = nextOf(r, chain.at(-1)!, i);
      try {
        fold([...chain, next], null);
        chain.push(next);
      } catch {}
    }
    const lock = fold(chain, null);
    for (const k of [...signers, ...spare]) assert.deepEqual(signerOf(lock, k.id), oracle.signerOf(lock, k.id), `seed ${seed}: signer`);
    for (let n = 0; n < 10; n++) {
      const cert = certOf(r);
      for (const ever of [false, true]) {
        const want = oracle.certOk(lock, cert, ever);
        assert.equal(certOk(lock, cert, ever), want, `seed ${seed}: cert ${JSON.stringify(cert)}`);
        tally("cert", want);
      }
    }
    // A vault's versions: each tried after the last taken, as kept and as a copy.
    let held: any = null;
    let items: any[] = [];
    for (let n = 0; n < 12; n++) {
      const next = vaultOf(r, held);
      for (const copy of [false, true]) {
        const want = oracle.vaultOk(lock, held, next, copy);
        assert.equal(vaultOk(lock, held, next, copy), want, `seed ${seed}, vault ${n}, copy ${copy}: ${JSON.stringify(next)}`);
        tally("vault", want);
      }
      if (oracle.vaultOk(lock, held, next) === null) held = next;
      if (held === null) continue;
      const prev = items.length && r.int(2) ? r.pick(items) : null;
      const item = itemOf(r, held, prev);
      for (const copy of [false, true]) {
        const want = oracle.itemOk(lock, held, prev, item, copy);
        assert.equal(itemOk(lock, held, prev, item, copy), want, `seed ${seed}, item ${n}, copy ${copy}: ${JSON.stringify(item)}`);
        tally("item", want);
      }
      if (oracle.itemOk(lock, held, prev, item) === null) items = [...items.filter((x) => x.id !== item.id), item];
      const l = listingOf(r) as any;
      if (Array.isArray(l.modes) && Array.isArray(l.hosts)) assert.equal(browserListingOk(l), oracle.browserListingOk(l), `listing ${JSON.stringify(l)}`);
    }
  }
  if (process.env.RULES_TRACE) console.error(JSON.stringify(counts), [...reasons].sort((a, b) => b[1] - a[1]));
  // (both answers tried often, of each: a generator whose records all fail one check would test little)
  for (const [what, [ok, refused]] of Object.entries(counts)) assert.ok(ok! > SEEDS && refused! > SEEDS, `${what}: ${ok} taken, ${refused} refused`);
});

test("workspace vault rules: scope, admin creation/updates, owner takeover, member item writes, and scope immutability", () => {
  // Build a deterministic lock with alice (owner), bob (admin), and carol (member), each with an own app device.
  const alice = { sub: "alice", base: bases[0]!, signer: signers[0]! };
  const bob = { sub: "bob", base: bases[1]!, signer: signers[1]! };
  const carol = { sub: "carol", base: bases[2]!, signer: signers[2]! };
  const lock: any = {
    ws: WS,
    members: new Map([
      [alice.sub, { sub: alice.sub, email: "alice@x.test", role: "owner" }],
      [bob.sub, { sub: bob.sub, email: "bob@x.test", role: "admin" }],
      [carol.sub, { sub: carol.sub, email: "carol@x.test", role: "member" }],
    ]),
    devices: new Map([
      [alice.base.hex, { id: alice.base.hex, sub: alice.sub, kind: "app", label: "A", sign_key: alice.signer.id, own: true }],
      [bob.base.hex, { id: bob.base.hex, sub: bob.sub, kind: "app", label: "B", sign_key: bob.signer.id, own: true }],
      [carol.base.hex, { id: carol.base.hex, sub: carol.sub, kind: "app", label: "C", sign_key: carol.signer.id, own: true }],
    ]),
    signKeys: new Map([
      [alice.base.hex, [alice.signer.id]],
      [bob.base.hex, [bob.signer.id]],
      [carol.base.hex, [carol.signer.id]],
    ]),
  };
  const signRec = <T extends Record<string, unknown>>(o: T, tag: string, k: typeof alice.signer) => ({
    ...o,
    sig: { key: k.id, alg: "Ed25519" as const, sig: k.sign(Buffer.from(signedBytes(o, tag))) },
  });
  const certFor = (u: typeof alice, i: number) => signRec({ v: 1 as const, ws: WS, device: u.base.hex, box: boxes[i]!, at: 1000 }, TAG.box, u.signer);
  const kAlice = { cert: certFor(alice, 0), wrapped: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" };
  const kBob = { cert: certFor(bob, 1), wrapped: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" };
  const kCarol = { cert: certFor(carol, 2), wrapped: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" };
  const vid = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";

  // 1. Invalid scope rejected.
  const badScope = signRec({ v: 1 as const, ws: WS, id: vid, seq: 0, owner: alice.sub, name: "Team", scope: "team", members: [alice.sub], epoch: 0, keys: [kAlice], at: 1000 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(lock, null, badScope as any), "scope is workspace");

  // 2. Ordinary member cannot create a workspace vault; owner/admin can.
  const byMember = signRec({ v: 1 as const, ws: WS, id: vid, seq: 0, owner: carol.sub, name: "Team", scope: "workspace" as const, members: [carol.sub], epoch: 0, keys: [kCarol], at: 1000 }, TAG.vault, carol.signer);
  assert.notEqual(vaultOk(lock, null, byMember as any), null);

  const v0 = signRec({ v: 1 as const, ws: WS, id: vid, seq: 0, owner: alice.sub, name: "Team", scope: "workspace" as const, members: [alice.sub, bob.sub], epoch: 0, keys: [kAlice, kBob], at: 1000 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(lock, null, v0 as any), null);

  // Admin can also create a workspace vault (as its initial owner).
  const v0Admin = signRec({ v: 1 as const, ws: WS, id: "v_01HZZZZZZZZZZZZZZZZZZZZZZY", seq: 0, owner: bob.sub, name: "Ops", scope: "workspace" as const, members: [bob.sub], epoch: 0, keys: [kBob], at: 1000 }, TAG.vault, bob.signer);
  assert.equal(vaultOk(lock, null, v0Admin as any), null);

  // 3. Another workspace admin (bob, not creator alice) can update seq+1, add carol, and remove carol with epoch+1.
  const v1 = signRec({ v: 1 as const, ws: WS, id: vid, seq: 1, owner: alice.sub, name: "Team", scope: "workspace" as const, members: [alice.sub, bob.sub, carol.sub], epoch: 0, keys: [kAlice, kBob, kCarol], at: 1001 }, TAG.vault, bob.signer);
  assert.equal(vaultOk(lock, v0 as any, v1 as any), null);

  // Ordinary member carol cannot update vault metadata, but CAN write an item via itemOk.
  const v2ByMember = signRec({ v: 1 as const, ws: WS, id: vid, seq: 2, owner: alice.sub, name: "Hacked", scope: "workspace" as const, members: [alice.sub, bob.sub, carol.sub], epoch: 0, keys: [kAlice, kBob, kCarol], at: 1002 }, TAG.vault, carol.signer);
  assert.notEqual(vaultOk(lock, v1 as any, v2ByMember as any), null);

  const itemByMember = signRec({ v: 1 as const, ws: WS, vault: vid, id: "i_01HZZZZZZZZZZZZZZZZZZZZZZZ", version: 0, epoch: 0, ct: "A".repeat(48), at: 1002 }, TAG.item, carol.signer);
  assert.equal(itemOk(lock, v1 as any, null, itemByMember as any), null);

  // Admin bob removes carol with epoch+1.
  const v2 = signRec({ v: 1 as const, ws: WS, id: vid, seq: 2, owner: alice.sub, name: "Team", scope: "workspace" as const, members: [alice.sub, bob.sub], epoch: 1, keys: [kAlice, kBob], at: 1003 }, TAG.vault, bob.signer);
  assert.equal(vaultOk(lock, v1 as any, v2 as any), null);

  // 4. After creator alice leaves, admin bob takes over owner and removes alice (epoch+1).
  const v3Takeover = signRec({ v: 1 as const, ws: WS, id: vid, seq: 3, owner: bob.sub, name: "Team", scope: "workspace" as const, members: [bob.sub], epoch: 2, keys: [kBob], at: 1004 }, TAG.vault, bob.signer);
  assert.equal(vaultOk(lock, v2 as any, v3Takeover as any), null);

  // Admin bob cannot set owner to someone else (e.g. carol) when changing owner.
  const v3BadOwner = signRec({ v: 1 as const, ws: WS, id: vid, seq: 3, owner: carol.sub, name: "Team", scope: "workspace" as const, members: [bob.sub, carol.sub], epoch: 2, keys: [kBob, kCarol], at: 1004 }, TAG.vault, bob.signer);
  assert.equal(vaultOk(lock, v2 as any, v3BadOwner as any), "a vault's owner does not change");

  // 5. Scope cannot change: workspace -> personal or personal -> workspace both refused.
  const wsToPersonal = signRec({ v: 1 as const, ws: WS, id: vid, seq: 1, owner: alice.sub, name: "Team", members: [alice.sub, bob.sub], epoch: 0, keys: [kAlice, kBob], at: 1001 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(lock, v0 as any, wsToPersonal as any), "a vault's scope does not change");

  const p0 = signRec({ v: 1 as const, ws: WS, id: "v_01HZZZZZZZZZZZZZZZZZZZZZZX", seq: 0, owner: alice.sub, name: "Personal", members: [alice.sub], epoch: 0, keys: [kAlice], at: 1000 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(lock, null, p0 as any), null);
  const personalToWs = signRec({ v: 1 as const, ws: WS, id: "v_01HZZZZZZZZZZZZZZZZZZZZZZX", seq: 1, owner: alice.sub, name: "Personal", scope: "workspace" as const, members: [alice.sub], epoch: 0, keys: [kAlice], at: 1001 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(lock, p0 as any, personalToWs as any), "a vault's scope does not change");

  // 6. Ordinary member cannot forge a workspace vault via ?copy=1 with seq: 1 (prev = null, copy = true).
  const forgedCopy = signRec({ v: 1 as const, ws: WS, id: "v_01HZZZZZZZZZZZZZZZZZZZZZZW", seq: 1, owner: carol.sub, name: "Forged", scope: "workspace" as const, members: [carol.sub], epoch: 0, keys: [kCarol], at: 1000 }, TAG.vault, carol.signer);
  assert.equal(vaultOk(lock, null, forgedCopy as any, true), "a workspace vault is signed by a workspace owner or admin in the lock");

  // 7. Demoted creator (alice -> member) can no longer update the workspace vault, but can still write items and active admin bob can still update/take over.
  const demotedLock: any = {
    ...lock,
    members: new Map([
      [alice.sub, { sub: alice.sub, email: "alice@x.test", role: "member" }],
      [bob.sub, { sub: bob.sub, email: "bob@x.test", role: "admin" }],
      [carol.sub, { sub: carol.sub, email: "carol@x.test", role: "member" }],
    ]),
  };
  const v2ByDemotedAlice = signRec({ v: 1 as const, ws: WS, id: vid, seq: 2, owner: alice.sub, name: "Still Mine", scope: "workspace" as const, members: [alice.sub, bob.sub, carol.sub], epoch: 0, keys: [kAlice, kBob, kCarol], at: 1002 }, TAG.vault, alice.signer);
  assert.equal(vaultOk(demotedLock, v1 as any, v2ByDemotedAlice as any), "a workspace vault is signed by a workspace owner or admin in the lock");
  const itemByDemotedAlice = signRec({ v: 1 as const, ws: WS, vault: vid, id: "i_01HZZZZZZZZZZZZZZZZZZZZZZY", version: 0, epoch: 0, ct: "A".repeat(48), at: 1002 }, TAG.item, alice.signer);
  assert.equal(itemOk(demotedLock, v1 as any, null, itemByDemotedAlice as any), null);
  assert.equal(vaultOk(demotedLock, v2 as any, v3Takeover as any), null);
});
