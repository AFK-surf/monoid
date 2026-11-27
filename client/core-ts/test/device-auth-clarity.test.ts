// Device authorization clarity (PR 1: core-ts engine + shapes):
// - deterministic 6-char deviceVerifyCode
// - non-safe-mode deviceText resolution in vaultAsks + extended VaultKeyAsk metadata
// - VaultsView thisDeviceCode/thisDeviceText + VaultRow authorizedDevices/pendingDevices + single-device addDevice
// - pairing LockPair.thisDeviceCode === LockPairing.deviceCode + build, willSign, handoverVaults preview & parity
import assert from "node:assert/strict";
import { test } from "node:test";
import { ed25519 } from "@noble/curves/ed25519.js";
import { Effect } from "effect";
import { STORAGE_KEY } from "../src/accounts.ts";
import type { HttpRequest } from "../src/host.ts";
import { type Entry, Signer, entryHash, next } from "../src/lock.ts";
import { PERSONAL_KEY } from "../src/personal-lock.ts";
import { hex, utf8 } from "../src/util.ts";
import {
  type BoxCert, type Item, type KeyAsk, type Request, type Vault, TAG, boxPublic, sign, signedOk,
} from "../src/vault/crypto.ts";
import { deviceVerifyCode, pairs, signerKnown } from "../src/views/lock.ts";
import { serveTrusted, tryOne, trying } from "../src/views/pair.ts";
import {
  pairBoxCerts, previewHandoverVaults, vaultAsks, vaultCome, vaultsView,
} from "../src/views/vault.ts";
import { account, call, subscribe } from "./helpers.ts";
import { ME, PHONE, genesis, grant, pipe, rig, withoutMesh } from "./lock-rig.ts";
import { started, stationReplies, status } from "./station-fixture.ts";
// @ts-ignore: the MoonBit build's JS, untyped
import * as rules from "../../../rules/js/rules.js";

const unhex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);

function edKey(seed: Uint8Array) {
  const id = `ed25519:${hex(ed25519.getPublicKey(seed))}`;
  return { id, hex: hex(ed25519.getPublicKey(seed)), signBytes: (b: Uint8Array) => hex(ed25519.sign(b, seed)) };
}

function lockEntry(e: ReturnType<typeof next>, by: ReturnType<typeof edKey>): Entry {
  return { ...e, sig: { key: by.id, alg: "Ed25519", sig: by.signBytes(new Uint8Array([...utf8("stillfail-lock/1 sig\0"), ...unhex(entryHash(e))])) } };
}

function makePersonalChain(
  sub: string,
  first: { devId: string; personalSeed: Uint8Array; signKeyId: string; label: string },
  extra: { devId: string; personalSeed: Uint8Array; signKeyId: string; label: string }[] = [],
  at = 1000,
): Entry[] {
  const pk0 = edKey(first.personalSeed);
  const entries: Entry[] = [
    lockEntry(next(`person:${sub}`, null, at, "genesis", {
      sub,
      device: { key: pk0.id, id: first.devId, label: first.label, sign_key: first.signKeyId },
    }), pk0),
  ];
  const genesisHash = entryHash(entries[0]!);
  for (let i = 0; i < extra.length; i++) {
    const d = extra[i]!;
    const pk = edKey(d.personalSeed);
    const prev = entries[entries.length - 1]!;
    const prevHead = { seq: prev.seq, hash: entryHash(prev), genesis: genesisHash };
    entries.push(
      lockEntry(next(`person:${sub}`, prevHead, at + i + 1, "device", {
        key: pk.id, id: d.devId, label: d.label, sign_key: d.signKeyId,
      }), pk0),
    );
  }
  return entries;
}

function sharedStation(opts: {
  ws?: string;
  safeMode: boolean;
  roles: Record<string, string>;
  chains?: Record<string, Entry[]>;
}) {
  const ws = opts.ws ?? "ws";
  const vaults = new Map<string, Vault>();
  const items = new Map<string, Item>();
  const boxes = new Map<string, BoxCert>();
  const asks = new Map<string, KeyAsk>();
  const requests: Request[] = [];

  const replyFor = (viewerSub: string) => (req: HttpRequest): unknown => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (!path.startsWith("/vault/")) return undefined;
    const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
    const [route, query] = path.split("?");
    const k = `${req.method} ${route}`;
    switch (k) {
      case "GET /vault/plain":
        return { items: [], locked: opts.safeMode };
      case "GET /vault/uses":
        return { uses: [] };
      case "GET /vault/requests":
        return { requests: requests.filter((r) => r.status === "pending") };
      case "GET /vault/vaults":
        return { vaults: [...vaults.values()].filter((v) => v.members.includes(viewerSub)) };
      case "POST /vault/vaults/latest":
        return { vaults: (body.held as Vault[]).map((h) => vaults.get(h.id)).filter((v): v is Vault => v !== undefined) };
      case "PUT /vault/vaults": {
        const prev = vaults.get(body.id);
        const copy = query === "copy=1";
        if (copy && prev && body.seq <= prev.seq && !(body.seq === prev.seq && rules.vault_supersedes_js(body, prev))) return { vault: prev };
        if (!copy && body.seq !== (prev ? prev.seq + 1 : 0)) return status(409, { error: "seq", code: "vault_conflict", vault: prev ?? null });
        if (!signedOk(body, TAG.vault)) return status(400, { error: "signature", code: "vault_invalid" });
        vaults.set(body.id, body);
        return { vault: body };
      }
      case "GET /vault/items": {
        const of = new URLSearchParams(query).get("vault");
        const allowed = new Set([...vaults.values()].filter((v) => v.members.includes(viewerSub) && (!of || v.id === of)).map((v) => v.id));
        return { items: [...items.values()].filter((i) => allowed.has(i.vault)) };
      }
      case "PUT /vault/items": {
        const prev = items.get(body.id);
        const copy = query === "copy=1";
        if (!vaults.has(body.vault)) return status(404, { error: "no vault", code: "vault_unknown" });
        if (copy && prev && body.version <= prev.version && !(body.version === prev.version && rules.item_supersedes_js(body, prev))) return { item: prev };
        if (!copy && body.version !== (prev ? prev.version + 1 : 0)) return status(409, { error: "version", code: "vault_conflict", item: prev ?? null });
        if (!signedOk(body, TAG.item)) return status(400, { error: "signature", code: "vault_invalid" });
        items.set(body.id, body);
        return { item: body };
      }
      case "GET /vault/boxes":
        return opts.safeMode
          ? { boxes: [...boxes.values()] }
          : { boxes: [...boxes.values()], chains: { ...(opts.chains ?? {}) }, roles: { ...opts.roles } };
      case "PUT /vault/boxes":
        if (!signedOk(body, TAG.box)) return status(400, { error: "signature", code: "vault_invalid" });
        boxes.set(body.device, body);
        return { box: body };
      case "GET /vault/asks":
        return { asks: [...asks.values()].filter((a) => vaults.get(a.vault)?.members.includes(viewerSub)) };
      case "PUT /vault/asks":
        if (!signedOk(body, TAG.ask)) return status(400, { error: "signature", code: "vault_invalid" });
        asks.set(`${body.vault}/${body.device}`, body);
        return { ask: body };
      default:
        return undefined;
    }
  };

  return { ws, vaults, items, boxes, asks, requests, replyFor };
}

let seq = 0;

async function makeMemberDevice(opts: {
  sub: string;
  email: string;
  devId: string;
  deviceName?: string;
  signerSeed: Uint8Array;
  personalSeed?: Uint8Array;
  st: ReturnType<typeof sharedStation>;
  wsMembers: { sub: string; email: string; name: string; role: string }[];
  safeMode: boolean;
  personalChain?: Entry[];
}) {
  const signer = edKey(opts.signerSeed);
  const myRole = opts.wsMembers.find((m) => m.sub === opts.sub)?.role ?? "member";
  const s = await started(undefined, 0, undefined, (x) => {
    x.host.appKeys = true;
    x.host.store(STORAGE_KEY, [account(opts.sub, opts.email, "", "tok", "r0", Math.floor(x.host.nowMs() / 1000) + 3600)]);
    x.host.secure.set("lock-signer", { value: opts.signerSeed, user: false });
    if (opts.personalSeed) {
      x.host.secure.set(PERSONAL_KEY, { value: opts.personalSeed, user: false });
      x.host.storage.set("personal-signer-id", utf8(edKey(opts.personalSeed).id));
    }
    if (!opts.safeMode && opts.personalChain && opts.personalChain.length > 0) {
      x.host.store(`personal-lock-${hex(utf8(opts.sub))}`, opts.personalChain);
    }
    x.cloud.role = myRole;
    x.cloud.also = { locked: opts.safeMode, members: opts.wsMembers };
    stationReplies(x.host, (req) => {
      if (req.url.includes("/v1/me/personal-lock")) {
        return { entries: opts.personalChain ?? [] };
      }
      return opts.st.replyFor(opts.sub)(req);
    });
  });
  s.core.inner.mesh = () => withoutMesh(opts.devId);
  s.core.inner.meshNow = () => ({ deviceId: () => opts.devId } as any);
  signerKnown(s.core.inner, signer.id);
  if (opts.deviceName) {
    s.core.inner.data.put("prefs", "device", { device: { name: opts.deviceName } });
  }
  await s.host.time.pass(1000 * (++seq));
  if (opts.personalChain && opts.personalChain.length > 0) {
    s.core.inner.runner.fork(Effect.ignore(s.core.inner.adb.personal().refresh(opts.sub)));
    await s.host.time.pass(200);
  }
  vaultCome(s.core.inner, "ws");
  const ui = s.core.connect();
  subscribe(s.core, ui, 1, { topic: "workspaces" });
  await s.host.time.pass(50);
  s.host.takeEmitted();
  let nextId = 100;
  const ask = async (name: string, params: Record<string, unknown> = {}) => {
    const id = ++nextId;
    s.host.takeEmitted();
    call(s.core, ui, id, name, { workspace: "ws", ...params });
    let found: any;
    for (let i = 0; i < 60 && found === undefined; i++) {
      await s.host.time.pass(50);
      for (const [, m] of s.host.takeEmitted()) {
        const r = m as any;
        if (r.id === id && ("ok" in r || "error" in r)) found = r;
      }
    }
    assert.ok(found !== undefined, `${name}: no answer`);
    assert.equal(found.error, undefined, `${name}: ${JSON.stringify(found.error)}`);
    return found.ok as any;
  };
  const sync = async () => {
    for (const a of s.core.inner.stations.also) {
      s.core.inner.runner.fork(Effect.ignore(a.read("ws/st")));
    }
    await s.host.time.pass(400);
    s.host.takeEmitted();
  };
  return { ...s, sub: opts.sub, devId: opts.devId, signer, ask, sync };
}

test("deviceVerifyCode: deterministic, XXX-XXX format without 0/O/1/I, empty returns empty, no collisions", () => {
  assert.equal(deviceVerifyCode(""), "");
  const c1 = deviceVerifyCode("a1".repeat(32));
  const c2 = deviceVerifyCode("a1".repeat(32));
  assert.equal(c1, c2);
  assert.match(c1, /^[2-9A-HJ-NP-Z]{3}-[2-9A-HJ-NP-Z]{3}$/);

  const seen = new Set<string>();
  for (let i = 0; i < 200; i++) {
    const id = `dev-${i.toString(16).padStart(8, "0")}-${"ab".repeat(24)}`;
    const code = deviceVerifyCode(id);
    assert.match(code, /^[2-9A-HJ-NP-Z]{3}-[2-9A-HJ-NP-Z]{3}$/);
    assert.ok(!/[01OI]/.test(code), `ambiguous char in ${code}`);
    assert.ok(!seen.has(code), `collision on ${code}`);
    seen.add(code);
  }
});

test("non-safe-mode vaultAsks & vaultsView: resolves own and teammate device labels, metadata, and per-device authorization", async () => {
  const aliceSeed1 = fill(31), aliceSeed2 = fill(32), bobSeed = fill(33);
  const alicePSeed1 = fill(41), alicePSeed2 = fill(42), bobPSeed = fill(43);
  const aliceDev1 = "a1".repeat(32);
  const aliceDev2 = "a2".repeat(32);
  const bobDev = "b1".repeat(32);
  const aliceKey1 = edKey(aliceSeed1);
  const aliceKey2 = edKey(aliceSeed2);
  const bobKey = edKey(bobSeed);

  const aliceChain = makePersonalChain(
    "alice",
    { devId: aliceDev1, personalSeed: alicePSeed1, signKeyId: aliceKey1.id, label: "Alice MacBook Pro" },
    [{ devId: aliceDev2, personalSeed: alicePSeed2, signKeyId: aliceKey2.id, label: "Alice iPhone 16" }],
  );
  const bobChain = makePersonalChain(
    "bob",
    { devId: bobDev, personalSeed: bobPSeed, signKeyId: bobKey.id, label: "Bob ThinkPad X1" },
  );

  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice Chen", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob Lin", role: "member" },
  ];
  const st = sharedStation({
    safeMode: false,
    roles: { alice: "owner", bob: "member" },
    chains: { alice: aliceChain, bob: bobChain },
  });

  const alice1 = await makeMemberDevice({
    sub: "alice", email: "alice@x.com", devId: aliceDev1, deviceName: "Alice MacBook Pro",
    signerSeed: aliceSeed1, personalSeed: alicePSeed1, st, wsMembers, safeMode: false, personalChain: aliceChain,
  });

  // Set up Alice's first device, create personal vault (via setup) + workspace vault + add 2 items to workspace vault
  const setup = await alice1.ask("vault.setup");
  const wsVault = await alice1.ask("vault.create", { name: "团队共享库", scope: "workspace", members: ["alice", "bob"] });
  await alice1.ask("vault.putItem", {
    vault: wsVault.id,
    plain: { kind: "token", name: "NPM_TOKEN", fields: { value: "npm_123" } },
    listing: { name: "NPM_TOKEN", kind: "token", modes: ["env"], hosts: [] },
  });
  await alice1.ask("vault.putItem", {
    vault: wsVault.id,
    plain: { kind: "token", name: "GH_TOKEN", fields: { value: "ghp_456" } },
    listing: { name: "GH_TOKEN", kind: "token", modes: ["env"], hosts: [] },
  });

  // Publish box certs for Alice's 2nd device and Bob's device directly to the station
  const aliceSigner2 = edKey(aliceSeed2);
  const bobSigner = edKey(bobSeed);
  const aliceBox2 = boxPublic(fill(52));
  const bobBox = boxPublic(fill(53));
  // (pure BoxCerts + standalone signed KeyAsks for the specific vaults requested via 申请授权)
  st.boxes.set(aliceDev2, sign({ v: 1 as const, ws: "ws", device: aliceDev2, box: aliceBox2, at: 2000 }, TAG.box, aliceSigner2 as unknown as Signer));
  st.boxes.set(bobDev, sign({ v: 1 as const, ws: "ws", device: bobDev, box: bobBox, at: 2100 }, TAG.box, bobSigner as unknown as Signer));
  st.asks.set(`${setup.made}/${aliceDev2}`, sign({ v: 1 as const, ws: "ws", vault: setup.made, device: aliceDev2, box: aliceBox2, at: 2000 }, TAG.ask, aliceSigner2 as unknown as Signer));
  st.asks.set(`${wsVault.id}/${aliceDev2}`, sign({ v: 1 as const, ws: "ws", vault: wsVault.id, device: aliceDev2, box: aliceBox2, at: 2000 }, TAG.ask, aliceSigner2 as unknown as Signer));
  st.asks.set(`${wsVault.id}/${bobDev}`, sign({ v: 1 as const, ws: "ws", vault: wsVault.id, device: bobDev, box: bobBox, at: 2100 }, TAG.ask, bobSigner as unknown as Signer));

  // Lock Alice's RAM keys first so sync doesn't auto-give keys in the background
  await alice1.ask("vault.lock");
  await alice1.sync();

  // 1. Check vaultAsks on Alice's 1st device (non-safe mode!)
  const asks = vaultAsks(alice1.core.inner);
  const ownAsk = asks.find((a) => a.device === aliceDev2 && a.vault === wsVault.id);
  const bobAsk = asks.find((a) => a.device === bobDev && a.vault === wsVault.id);
  assert.ok(ownAsk, `expected own device ask in ${JSON.stringify(asks)}`);
  assert.ok(bobAsk, `expected teammate ask in ${JSON.stringify(asks)}`);

  // Real device names resolved (not generic "应用")
  assert.equal(ownAsk.deviceText, "Alice iPhone 16");
  assert.equal(ownAsk.deviceCode, deviceVerifyCode(aliceDev2));
  assert.equal(ownAsk.ownerName, "Alice Chen");
  assert.equal(ownAsk.ownerEmail, "alice@x.com");
  assert.equal(ownAsk.isOwnDevice, true);
  assert.equal(ownAsk.vaultScope, "workspace");
  assert.equal(ownAsk.vaultItems, 2);
  assert.equal(ownAsk.safeMode, false);

  assert.equal(bobAsk.deviceText, "Bob ThinkPad X1");
  assert.equal(bobAsk.deviceCode, deviceVerifyCode(bobDev));
  assert.equal(bobAsk.ownerName, "Bob Lin");
  assert.equal(bobAsk.ownerEmail, "bob@x.com");
  assert.equal(bobAsk.isOwnDevice, false);
  assert.equal(bobAsk.vaultScope, "workspace");
  assert.equal(bobAsk.vaultItems, 2);
  assert.equal(bobAsk.safeMode, false);

  // Also check personal vault ask for Alice's 2nd device
  const personalAsk = asks.find((a) => a.device === aliceDev2 && a.vault !== wsVault.id);
  assert.ok(personalAsk, "expected personal vault ask for Alice's 2nd device");
  assert.equal(personalAsk.vaultScope, "personal");
  assert.equal(personalAsk.isOwnDevice, true);
  assert.equal(personalAsk.safeMode, false);

  // 2. Check vaultsView: thisDeviceCode, thisDeviceText, authorizedDevices, pendingDevices
  const view1 = vaultsView(alice1.core.inner, "ws");
  assert.equal(view1.thisDeviceCode, deviceVerifyCode(aliceDev1));
  assert.equal(view1.thisDeviceText, "Alice MacBook Pro");

  const wsRow1 = view1.vaults.find((v: any) => v.id === wsVault.id);
  assert.ok(wsRow1, "expected workspace vault row");
  assert.equal(wsRow1.authorizedDevices.length, 1);
  assert.equal(wsRow1.authorizedDevices[0].device, aliceDev1);
  assert.equal(wsRow1.authorizedDevices[0].deviceCode, deviceVerifyCode(aliceDev1));
  assert.equal(wsRow1.authorizedDevices[0].deviceText, "Alice MacBook Pro");
  assert.equal(wsRow1.authorizedDevices[0].ownerName, "Alice Chen");
  assert.equal(wsRow1.authorizedDevices[0].ownerEmail, "alice@x.com");
  assert.equal(wsRow1.authorizedDevices[0].current, true);

  assert.equal(wsRow1.pendingDevices.length, 2);
  // Ordered by `at` descending: bobDev (2100) then aliceDev2 (2000)
  assert.equal(wsRow1.pendingDevices[0].device, bobDev);
  assert.equal(wsRow1.pendingDevices[0].deviceCode, deviceVerifyCode(bobDev));
  assert.equal(wsRow1.pendingDevices[0].deviceText, "Bob ThinkPad X1");
  assert.equal(wsRow1.pendingDevices[0].ownerName, "Bob Lin");
  assert.equal(wsRow1.pendingDevices[0].ownerEmail, "bob@x.com");
  assert.equal(wsRow1.pendingDevices[0].current, false);

  assert.equal(wsRow1.pendingDevices[1].device, aliceDev2);
  assert.equal(wsRow1.pendingDevices[1].deviceCode, deviceVerifyCode(aliceDev2));
  assert.equal(wsRow1.pendingDevices[1].deviceText, "Alice iPhone 16");
  assert.equal(wsRow1.pendingDevices[1].ownerName, "Alice Chen");
  assert.equal(wsRow1.pendingDevices[1].current, false);

  // 3. Authorize ONLY Bob's device via vault.addDevice { vault, device }
  await alice1.ask("vault.addDevice", { vault: wsVault.id, device: bobDev });
  const view2 = vaultsView(alice1.core.inner, "ws");
  const wsRow2 = view2.vaults.find((v: any) => v.id === wsVault.id);
  assert.equal(wsRow2.authorizedDevices.length, 2);
  // Current device still sorted first
  assert.equal(wsRow2.authorizedDevices[0].device, aliceDev1);
  assert.equal(wsRow2.authorizedDevices[0].current, true);
  assert.equal(wsRow2.authorizedDevices[1].device, bobDev);
  assert.equal(wsRow2.authorizedDevices[1].current, false);
  assert.equal(wsRow2.authorizedDevices[1].deviceCode, deviceVerifyCode(bobDev));

  // Alice's 2nd device remains in pendingDevices
  assert.equal(wsRow2.pendingDevices.length, 1);
  assert.equal(wsRow2.pendingDevices[0].device, aliceDev2);
});

// A teammate added to a workspace vault, their app setting itself up (`autoBox`: a certificate with no `asked`), puts
// up no prompt on the managers' devices: only 申请授权 pressed on it does. Their device still waits among the vault's
// pendingDevices, where a manager may give it the key unasked.
test("non-safe-mode workspace vault: a teammate's device set up by itself prompts nobody; once its person presses 申请授权 it does", async () => {
  const aliceSeed = fill(91), bobSeed = fill(92), alicePSeed = fill(93), bobPSeed = fill(94);
  const aliceDev = "a9".repeat(32);
  const bobDev = "b9".repeat(32);
  const aliceKey = edKey(aliceSeed);
  const bobKey = edKey(bobSeed);
  const aliceChain = makePersonalChain("alice", { devId: aliceDev, personalSeed: alicePSeed, signKeyId: aliceKey.id, label: "Alice MacBook Pro" });
  const bobChain = makePersonalChain("bob", { devId: bobDev, personalSeed: bobPSeed, signKeyId: bobKey.id, label: "Bob ThinkPad X1" });
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice Chen", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob Lin", role: "member" },
  ];
  const st = sharedStation({ safeMode: false, roles: { alice: "owner", bob: "member" }, chains: { alice: aliceChain, bob: bobChain } });
  const alice = await makeMemberDevice({
    sub: "alice", email: "alice@x.com", devId: aliceDev, deviceName: "Alice MacBook Pro",
    signerSeed: aliceSeed, personalSeed: alicePSeed, st, wsMembers, safeMode: false, personalChain: aliceChain,
  });
  await alice.ask("vault.setup");
  const wsVault = await alice.ask("vault.create", { name: "Workspace 密钥库", scope: "workspace", members: ["alice", "bob"] });
  await alice.ask("vault.lock");

  // Bob's app sets itself up, nobody pressing anything there: pure BoxCert only, no KeyAsk.
  const bobBox = boxPublic(fill(95));
  st.boxes.set(bobDev, sign({ v: 1 as const, ws: "ws", device: bobDev, box: bobBox, at: 2100 }, TAG.box, bobKey as unknown as Signer));
  await alice.sync();
  assert.deepEqual(vaultAsks(alice.core.inner).filter((a) => a.device === bobDev), [], "set up by itself: no prompt");
  const pending = vaultsView(alice.core.inner, "ws").vaults.find((v: any) => v.id === wsVault.id).pendingDevices;
  assert.deepEqual(pending.map((d: any) => d.device), [bobDev], "still waiting among the vault's devices");

  // Bob previously pressed 申请授权 for some other vault (e.g. his own personal vault): still no prompt for wsVault!
  st.asks.set(`v_01JAOTHER00000000000000000/${bobDev}`, sign({ v: 1 as const, ws: "ws", vault: "v_01JAOTHER00000000000000000", device: bobDev, box: bobBox, at: 2150 }, TAG.ask, bobKey as unknown as Signer));
  await alice.sync();
  assert.deepEqual(vaultAsks(alice.core.inner).filter((a) => a.device === bobDev), [], "asking for another vault never prompts for workspace vault");

  // Bob presses 申请授权 specifically for wsVault: standalone KeyAsk for wsVault -> prompts Alice for wsVault only.
  st.asks.set(`${wsVault.id}/${bobDev}`, sign({ v: 1 as const, ws: "ws", vault: wsVault.id, device: bobDev, box: bobBox, at: 2200 }, TAG.ask, bobKey as unknown as Signer));
  await alice.sync();
  const asks = vaultAsks(alice.core.inner).filter((a) => a.device === bobDev);
  assert.deepEqual(asks.map((a) => [a.vault, a.isOwnDevice, a.at]), [[wsVault.id, false, 2200]]);
});

test("pairing flow: LockPair.thisDeviceCode === LockPairing.deviceCode, build, willSign, and handoverVaults match actual handover", async () => {
  const aliceSeed1 = fill(61), aliceSeed2 = fill(62);
  const alicePSeed1 = fill(71), alicePSeed2 = fill(72);
  const aliceDev1 = "d1".repeat(32);
  const aliceDev2 = "d2".repeat(32);
  const aliceKey1 = edKey(aliceSeed1);
  const aliceKey2 = edKey(aliceSeed2);
  const alicePk2 = edKey(alicePSeed2);
  const aliceChain0 = makePersonalChain("alice", {
    devId: aliceDev1, personalSeed: alicePSeed1, signKeyId: aliceKey1.id, label: "Alice Mac Studio",
  });
  const wsMembers = [{ sub: "alice", email: "alice@x.com", name: "Alice Chen", role: "owner" }];
  const st = sharedStation({ safeMode: false, roles: { alice: "owner" }, chains: { alice: aliceChain0 } });

  const alice1 = await makeMemberDevice({
    sub: "alice", email: "alice@x.com", devId: aliceDev1, deviceName: "Alice Mac Studio",
    signerSeed: aliceSeed1, personalSeed: alicePSeed1, st, wsMembers, safeMode: false, personalChain: aliceChain0,
  });

  // Set up personal vault (1 item) + workspace vault (2 items)
  const setupRes = await alice1.ask("vault.setup");
  const personalVaultId = setupRes.made as string;
  await alice1.ask("vault.putItem", {
    vault: personalVaultId,
    plain: { kind: "token", name: "MY_API_KEY", fields: { value: "sk_1" } },
    listing: { name: "MY_API_KEY", kind: "token", modes: ["env"], hosts: [] },
  });
  const wsVault = await alice1.ask("vault.create", { name: "团队密钥库", scope: "workspace", members: ["alice"] });
  await alice1.ask("vault.putItem", {
    vault: wsVault.id,
    plain: { kind: "token", name: "TEAM_KEY_1", fields: { value: "tk_1" } },
    listing: { name: "TEAM_KEY_1", kind: "token", modes: ["env"], hosts: [] },
  });
  await alice1.ask("vault.putItem", {
    vault: wsVault.id,
    plain: { kind: "token", name: "TEAM_KEY_2", fields: { value: "tk_2" } },
    listing: { name: "TEAM_KEY_2", kind: "token", modes: ["env"], hosts: [] },
  });

  // Prepare requesting device's boxCerts for "ws"
  const phoneBoxPub = boxPublic(fill(88));
  const phoneBoxCert = sign({ v: 1 as const, ws: "ws", device: aliceDev2, box: phoneBoxPub, at: 3000 }, TAG.box, aliceKey2 as unknown as Signer);

  // Requesting side LockPair state
  const reqCore = await started(undefined, 0, undefined, (x) => {
    x.host.appKeys = true;
  });
  reqCore.core.inner.mesh = () => withoutMesh(aliceDev2);
  reqCore.core.inner.meshNow = () => ({ deviceId: () => aliceDev2 } as any);
  reqCore.core.inner.data.put("prefs", "device", { device: { name: "Pixel 9 Pro" } });
  trying(reqCore.core.inner, ["ws"]);
  const reqPair = pairs.mine(reqCore.core.inner, "ws");
  assert.ok(reqPair !== null, "expected LockPair state");
  assert.equal(reqPair.thisDeviceCode, deviceVerifyCode(aliceDev2));
  assert.equal(reqPair.thisDeviceText, "Pixel 9 Pro");

  // Run pairing hello from aliceDev2 -> aliceDev1 via personal lock
  const [trusted, phone] = await pipe();
  alice1.core.inner.runner.fork(serveTrusted(alice1.core.inner, aliceDev2, aliceDev1, trusted));
  const run = async <A>(e: Effect.Effect<A, any>): Promise<{ ok: A } | { err: any }> => {
    const out: ({ ok: A } | { err: any })[] = [];
    alice1.core.inner.runner.fork(Effect.map(Effect.result(e), (x) => out.push(x._tag === "Success" ? { ok: x.success } : { err: x.failure })));
    await alice1.host.time.passUntil(5000, () => out.length !== 0);
    return out[0] ?? { err: "no answer" };
  };

  const helloRes = await run(Effect.andThen(
    phone.send({
      t: "hello",
      v: 1,
      workspaces: [],
      kind: "app",
      label: "Pixel 9 Pro",
      sign_key: aliceKey2.id,
      build: "0.1.10600",
      personal: { subs: ["alice"], key: alicePk2.id },
      box: phoneBoxPub,
      boxCerts: { ws: phoneBoxCert },
    }),
    phone.next(),
  ));
  assert.deepEqual(helloRes, { ok: { t: "code", workspaces: ["person:alice"] } });

  const shown = pairs.shown(alice1.core.inner);
  assert.equal(shown.length, 1);
  assert.equal(shown[0].device, aliceDev2);
  assert.equal(shown[0].deviceCode, reqPair.thisDeviceCode, "approver deviceCode must match requester thisDeviceCode");
  assert.equal(shown[0].build, "0.1.10600");
  assert.equal(shown[0].willSign, true);
  assert.ok(Array.isArray(shown[0].handoverVaults), "expected handoverVaults preview");
  assert.equal(shown[0].handoverVaults.length, 2);

  const previewPersonal = shown[0].handoverVaults.find((v: any) => v.id === personalVaultId);
  const previewWorkspace = shown[0].handoverVaults.find((v: any) => v.id === wsVault.id);
  assert.ok(previewPersonal, "expected personal vault in handoverVaults");
  assert.equal(previewPersonal.scope, "personal");
  assert.equal(previewPersonal.items, 1);
  assert.equal(previewPersonal.workspace, "ws");
  assert.ok(previewWorkspace, "expected workspace vault in handoverVaults");
  assert.equal(previewWorkspace.name, "团队密钥库");
  assert.equal(previewWorkspace.scope, "workspace");
  assert.equal(previewWorkspace.items, 2);
  assert.equal(previewWorkspace.workspace, "ws");

  // Direct previewHandoverVaults matches shown[0].handoverVaults
  const directPreview = previewHandoverVaults(alice1.core.inner, {
    device: aliceDev2,
    subs: ["alice"],
    workspaces: [],
    boxCerts: { ws: phoneBoxCert },
  });
  assert.deepEqual(directPreview, shown[0].handoverVaults);

  // Complete pairing approval and verify handed-over vault IDs match handoverVaults 100%
  const approved = await run(tryOne(alice1.core.inner, { id: aliceDev1, d: phone, workspaces: ["person:alice"] }, aliceDev2, shown[0].code));
  assert.ok("ok" in approved && "approved" in approved.ok, JSON.stringify(approved));
  const handedIds = (approved.ok.approved.vaults ?? []).map((h: any) => h.vault?.id).filter(Boolean).sort();
  const previewIds = shown[0].handoverVaults.map((v: any) => v.id).sort();
  assert.deepEqual(handedIds, previewIds, "previewed handoverVaults must match actually handed-over vaults");

  // Also verify web pairing sets willSign: false and omits handoverVaults
  const g = grant();
  const r = await rig((me) => ({ ws: genesis("ws", me, true, [], g.keys, ME, []) }));
  await r.watch({ topic: "lock", workspace: "ws" });
  const prompts = await r.watch({ topic: "lockPrompts" });
  const [trustedWeb, web] = await pipe();
  const webId = "cc".repeat(32);
  r.core.inner.runner.fork(serveTrusted(r.core.inner, webId, ME, trustedWeb));
  const runR = async <A>(e: Effect.Effect<A, any>): Promise<{ ok: A } | { err: any }> => {
    const out: ({ ok: A } | { err: any })[] = [];
    r.core.inner.runner.fork(Effect.map(Effect.result(e), (x) => out.push(x._tag === "Success" ? { ok: x.success } : { err: x.failure })));
    await r.host.time.passUntil(5000, () => out.length !== 0);
    return out[0] ?? { err: "no answer" };
  };
  const webHello = await runR(Effect.andThen(
    web.send({
      t: "hello",
      v: 1,
      workspaces: [{ ws: "ws", credential: g.credential("ws", webId, "s1") }],
      kind: "web",
      label: "Chrome",
      sign_key: null,
      build: "0.1.10601",
    }),
    web.next(),
  ));
  assert.deepEqual(webHello, { ok: { t: "code", workspaces: ["ws"] } });
  const webShown = (await prompts()).pairing;
  assert.equal(webShown.length, 1);
  assert.equal(webShown[0].deviceCode, deviceVerifyCode(webId));
  assert.equal(webShown[0].build, "0.1.10601");
  assert.equal(webShown[0].willSign, false);
  assert.equal(webShown[0].handoverVaults, undefined);

  alice1.core.close();
  reqCore.core.close();
  r.core.close();
});
