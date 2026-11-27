import assert from "node:assert/strict";
import { createPrivateKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import type { Request } from "../src/api/request.ts";
import type { LockState } from "../../shared/lock.ts";
import { routes } from "../src/api/routes/vault.ts";
import { askOk, signedBytes, TAG, type BoxCert, type KeyAsk, type Vault } from "../src/vault/crypto.ts";
import { VaultStore } from "../src/vault/store.ts";

function fixture() {
  const v = JSON.parse(readFileSync(new URL("./fixtures/vault-vectors.json", import.meta.url), "utf8")) as {
    ws: string; signer: { key: string; seed: string }; device: { id: string }; cert: BoxCert;
  };
  const key = createPrivateKey({
    key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.from(v.signer.seed, "hex")]),
    format: "der",
    type: "pkcs8",
  });
  const signAsk = (vault: string, device: string, at: number): KeyAsk => {
    const unsigned = { v: 1 as const, ws: v.ws, vault, device, box: v.cert.box, at };
    return { ...unsigned, sig: { key: v.signer.key, alg: "Ed25519", sig: sign(null, signedBytes(unsigned, TAG.ask), key).toString("hex") } };
  };
  const db = new DatabaseSync(":memory:");
  let inspected = 0;
  db.function("ask_seen", (_id: unknown) => { inspected++; return 0; });
  const observed = new Proxy(db, {
    get(target, prop) {
      if (prop === "prepare") {
        return (sql: string) => target.prepare(sql.replace(
          "SELECT body FROM vault_asks WHERE ws = ?",
          "SELECT body, ask_seen(device) AS seen FROM vault_asks WHERE ws = ?",
        ));
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const vaults = new VaultStore(observed);
  const myVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZ1";
  const myVault: Vault = {
    v: 1, ws: v.ws, id: myVaultId, seq: 0, owner: "alice", name: "Alice", members: ["alice"], epoch: 0,
    keys: [], at: 1000, sig: v.cert.sig,
  };
  vaults.putVault(myVault);
  // Seed 200 asks belonging to unrelated vaults that Alice is NOT a member of.
  for (let i = 0; i < 200; i++) {
    const otherVault = `v_01HZZZZZZZZZZZZZZZZZZZZ${String(i).padStart(3, "0").replace(/[^0-9A-HJKMNP-TV-Z]/g, "0")}`;
    vaults.putAsk(signAsk(otherVault, i.toString(16).padStart(64, "0"), 1000 + i));
  }
  // Seed 80 asks for revoked devices in Alice's own vault with higher `at` — active device filter must keep Alice's ask visible!
  for (let i = 0; i < 80; i++) {
    vaults.putAsk(signAsk(myVaultId, `f${i.toString(16).padStart(63, "0")}`, 5000 + i));
  }
  const myAsk = signAsk(myVaultId, v.device.id, 2000);
  vaults.putAsk(myAsk);

  const device = { id: v.device.id, sub: "alice", kind: "app" as const, label: "Alice", own: true, sign_key: v.signer.key };
  const member = { sub: "alice", email: "a@example.test", role: "owner" as const };
  const state = { ws: v.ws, devices: new Map([[device.id, device]]), members: new Map([[member.sub, member]]), signKeys: new Map() } as LockState;
  const route = routes({ vaults, lock: () => state }).find((r) => r.method === "GET" && r.pattern.test("/vault/asks"))!;
  const request: Request = {
    method: "GET", path: "/vault/asks", query: [], headers: {}, body: Buffer.alloc(0),
    viewer: { sub: "alice", workspace: v.ws, email: "a@example.test", name: "Alice", role: "owner", device: v.device.id },
    lang: "en",
  };
  const read = async () => {
    inspected = 0;
    const answer = await route.handle(request, []);
    return { status: answer.status, body: JSON.parse((answer.body as Buffer).toString()), inspected };
  };
  return { db, vaults, state, myVaultId, myAsk, signAsk, read };
}

test("GET /vault/asks scans only the viewer's vaults via vault_asks_vault_at index (at DESC, no temp sort) and ignores revoked devices", async () => {
  const f = fixture();
  try {
    assert.equal(askOk(f.state, f.myAsk), null);
    const plan = f.db.prepare(
      "EXPLAIN QUERY PLAN SELECT body FROM vault_asks WHERE ws = ? AND vault = ? AND device IN (SELECT value FROM json_each(?)) ORDER BY at DESC, device ASC LIMIT ?",
    ).all("ws", f.myVaultId, JSON.stringify([f.myAsk.device]), 64) as { detail: string }[];
    assert.ok(
      plan.some((p) => p.detail.includes("USING INDEX vault_asks_vault_at")),
      `expected vault_asks_vault_at index lookup: ${JSON.stringify(plan)}`,
    );
    assert.ok(!plan.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort: ${JSON.stringify(plan)}`);

    const answer = await f.read();
    assert.equal(answer.status, 200);
    assert.deepEqual(answer.body.asks, [f.myAsk]);
    assert.equal(answer.inspected, 1, `scanned ${answer.inspected} rows instead of only the active device's ask`);

    // Active device filter stays active above 64 lock devices (no cliff), and a second vault is never starved by the first.
    for (let i = 0; i < 70; i++) {
      const id = `e${i.toString(16).padStart(63, "0")}`;
      f.state.devices.set(id, { id, sub: "alice", kind: "app", label: `dev-${i}`, own: true, sign_key: f.myAsk.sig.key });
    }
    const secondVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZ2";
    f.vaults.putVault({
      v: 1, ws: f.myAsk.ws, id: secondVaultId, seq: 0, owner: "alice", name: "Second", members: ["alice"], epoch: 0,
      keys: [], at: 1000, sig: f.myAsk.sig,
    });
    const secondAsk = f.signAsk(secondVaultId, f.myAsk.device, 1900);
    f.vaults.putAsk(secondAsk);
    // Add 63 empty member vaults + 4 more active devices asking on secondVaultId: empty vaults must NOT shrink its per-vault quota!
    for (let i = 0; i < 63; i++) {
      const emptyId = `v_01HZZZZZZZZZZZZZZZZZZZZ${i.toString(36).toUpperCase().padStart(3, "0").replace(/O/g, "8").replace(/I/g, "9").replace(/L/g, "7").replace(/U/g, "6")}`;
      f.vaults.putVault({
        v: 1, ws: f.myAsk.ws, id: emptyId, seq: 0, owner: "alice", name: `Empty-${i}`, members: ["alice"], epoch: 0,
        keys: [], at: 1000, sig: f.myAsk.sig,
      });
    }
    for (let i = 0; i < 4; i++) {
      const devId = `e${i.toString(16).padStart(63, "0")}`;
      f.vaults.putAsk(f.signAsk(secondVaultId, devId, 1901 + i));
    }
    const answer2 = await f.read();
    assert.equal(answer2.status, 200);
    assert.equal(answer2.body.asks.filter((a: KeyAsk) => a.vault === secondVaultId).length, 5, "empty vaults must not cap active vault below its 5 asks");
    assert.equal(answer2.body.asks.filter((a: KeyAsk) => a.vault === f.myVaultId).length, 1);
  } finally {
    f.db.close();
  }
});
