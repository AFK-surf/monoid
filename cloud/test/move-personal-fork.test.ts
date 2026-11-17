import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";
import { signer } from "./lock-signer.ts";
import { extendPersonalKept, type PersonalEntry } from "../src/personal-lock.ts";

test("an account export keeps the signed personal-lock branches held beside its active chain", async () => {
  const h = await harness();
  const into = await harness({ moving: true, signingKey: h.signingKey });
  try {
    const tokens = await h.login("alice");
    const owner = signer(tokens.subject), b = signer(tokens.subject), c = signer(tokens.subject);
    const ws = `person:${tokens.subject}`;
    const first = await owner.entry(ws, null, "genesis", { sub: tokens.subject, device: { key: owner.key, id: "ab".repeat(32), label: "owner" } });
    const left = await owner.entry(ws, first, "device", { key: b.key, id: "bc".repeat(32), label: "left" });
    const right = await owner.entry(ws, first, "device", { key: c.key, id: "cd".repeat(32), label: "right" });
    const expected = extendPersonalKept(tokens.subject, { entries: [first, left] as PersonalEntry[], aside: [] }, [right]);
    assert.equal(expected.aside.length, 1, "two valid signed entries at one place leave one branch held aside");
    const account = await h.object("ACCOUNTS", tokens.subject);
    assert.ok("entries" in await account.appendPersonalLock(tokens.subject, [first, left], true));
    assert.ok("entries" in await account.appendPersonalLock(tokens.subject, [right], true));
    const read = async (cloud: typeof h) => {
      const response = await cloud.fetch("/v1/admin/move/export", { method: "POST", headers: { authorization: `Bearer ${cloud.adminToken}` } });
      assert.equal(response.status, 200);
      return await response.json() as { directory: Record<string, unknown>; accounts: Record<string, Record<string, unknown>> };
    };
    const snapshot = await read(h);
    const exported = snapshot.accounts[tokens.subject]!;
    assert.deepEqual(exported["personal-lock"], expected.entries, "the active chain is exported");
    assert.deepEqual(exported["personal-lock-aside"], expected.aside, "the other signed branch must survive moving this account too");
    const write = async (value: typeof snapshot) => {
      const response = await into.fetch("/v1/admin/move/import", {
        method: "POST", headers: { authorization: `Bearer ${into.adminToken}`, "content-type": "application/json" }, body: JSON.stringify(value),
      });
      assert.equal(response.status, 200);
    };
    await write(snapshot);
    assert.deepEqual(await read(into), snapshot, "the destination keeps the whole signed history, including the active chain");

    const older = { ...exported };
    delete older["personal-lock-aside"];
    const olderSnapshot = { ...snapshot, accounts: { ...snapshot.accounts, [tokens.subject]: older } };
    await write(olderSnapshot);
    assert.deepEqual(await read(into), olderSnapshot, "a snapshot from before aside was kept replaces the destination's old branches too");
  } finally {
    await h.close();
    await into.close();
  }
});
