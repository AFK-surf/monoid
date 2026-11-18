import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { RelayEnrollment } from "../src/mesh/enrollment.ts";
const scope = "01".repeat(32), issuer = "02".repeat(32), node = "03".repeat(32);
function fixture() {
  const db = new DatabaseSync(":memory:");
  let clock = 1000, sequence = 0;
  const registry = new RelayEnrollment(db, issuer, () => clock, () => Buffer.alloc(32, ++sequence).toString("base64url"));
  return { db, registry, at: (n: number) => { clock = n; } };
}

test("workspace tokens are scoped, expire, and commit exactly one registration", () => {
  const f = fixture();
  try {
    const issued = f.registry.issue(scope, "relay", "member@example.test");
    assert.throws(() => f.registry.redeem("04".repeat(32), issued.token, node), /invalid/);
    const registration = f.registry.redeem(scope, issued.token, node);
    assert.equal(registration.generation, 1);
    assert.throws(() => f.registry.redeem(scope, issued.token, "05".repeat(32)), /already used/);
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM mesh_relay_registrations").get()!.n, 1);
    const expired = f.registry.issue(scope, "expired", "member@example.test");
    f.at(expired.expires);
    assert.throws(() => f.registry.redeem(scope, expired.token, node), /expired/);
    const stored = f.db.prepare("SELECT hash FROM mesh_relay_tokens").get()!;
    assert.notEqual(stored.hash, expired.token, "only the token digest is durable");
  } finally { f.db.close(); }
});

test("failed registration rolls back consumption and revocation survives a new registry instance", () => {
  const f = fixture();
  try {
    const issued = f.registry.issue(scope, "relay", "member@example.test");
    f.db.exec("CREATE TRIGGER reject_mesh_relay BEFORE INSERT ON mesh_relay_registrations BEGIN SELECT RAISE(ABORT, 'storage failure'); END;");
    assert.throws(() => f.registry.redeem(scope, issued.token, node), /storage failure/);
    f.db.exec("DROP TRIGGER reject_mesh_relay");
    f.registry.redeem(scope, issued.token, node);
    assert.equal(f.registry.revoke(scope, node).generation, 2);
    const restarted = new RelayEnrollment(f.db, issuer, () => 1000);
    assert.equal(restarted.revoke(scope, node).generation, 2);
    assert.throws(() => restarted.redeem(scope, issued.token, node), /already used/);
    const another = f.registry.issue(scope, "relay again", "member@example.test");
    assert.equal(restarted.redeem(scope, another.token, node).generation, 3);
  } finally { f.db.close(); }
});

test("pending enrollment has a per-workspace bound", () => {
  const f = fixture();
  try {
    for (let i = 0; i < 32; i++) f.registry.issue(scope, "relay", "member@example.test");
    assert.throws(() => f.registry.issue(scope, "relay", "member@example.test"), /too many/);
    f.at(1000 + 24 * 60 * 60 * 1000);
    f.registry.issue(scope, "relay", "member@example.test");
    assert.equal(f.db.prepare("SELECT COUNT(*) AS n FROM mesh_relay_tokens WHERE scope = ?").get(scope)!.n, 1);
  } finally { f.db.close(); }
});


test("enrollment binds the transport identity and can resume a lost acknowledgement", async () => {
  const { EnrollmentDoor } = await import("../src/mesh/enrollment-door.ts");
  const f = fixture();
  try {
    const door = new EnrollmentDoor(f.registry, (s) => s === scope, (body) => `signed:${body}`, async (scope, node) => f.db.prepare("SELECT revoked,made_by,name,generation,issuer,node,scope FROM mesh_relay_registrations WHERE scope=? AND node=? AND revoked=0").get(scope, node) as any ?? null);
    const invite = f.registry.issue(scope, "relay", "member@example.test");
    await assert.rejects(() => door.answer({ op: "enroll", scope: "04".repeat(32), token: invite.token }, node), /not available/);
    const reply = await door.answer({ op: "enroll", scope, token: invite.token, node: issuer }, node) as any;
    assert.equal(reply.record.node, node, "request field cannot replace the authenticated key");
    assert.deepEqual(JSON.parse(reply.body), reply.record);
    assert.deepEqual(await door.answer({ op: "resume", scope }, node), reply);
    await assert.rejects(() => door.answer({ op: "resume", scope }, issuer), /not registered/);
    f.registry.revoke(scope, node);
    await assert.rejects(() => door.answer({ op: "resume", scope }, node), /not registered/);
  } finally { f.db.close(); }
});

test("Node's signed registration matches the native wire fixture", async () => {
  const { readFile } = await import("node:fs/promises");
  const { createPrivateKey, sign } = await import("node:crypto");
  const fixture = JSON.parse(await readFile(new URL("../../libs/mesh-transport/tests/fixtures/registration.json", import.meta.url), "utf8"));
  const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, 70)]), format: "der", type: "pkcs8" });
  assert.equal(sign(null, Buffer.from(`mesh-relay-registration/v1\0${fixture.body}`), privateKey).toString("hex"), fixture.signature);
});

test("relay admission requires an admitted issuer and old grants cannot undo revocation", async () => {
  const { RelayRecords, relayRecordOf, signRelayRecord } = await import("../src/mesh/relay-records.ts");
  const { createPrivateKey, createPublicKey, sign } = await import("node:crypto");
  const key = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, 70)]), format: "der", type: "pkcs8" });
  const issuer = createPublicKey(key).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  const issuers = new Set([issuer]);
  const record = { scope, node, issuer, generation: 1, name: "relay", made_by: "member", revoked: 0 };
  const signed = (r: typeof record) => signRelayRecord(r, (text) => sign(null, Buffer.from(text), key).toString("hex"));
  const db = new DatabaseSync(":memory:");
  try {
    const records = new RelayRecords(db);
    const grant = signed(record), revoked = signed({ ...record, generation: 2, revoked: 1 });
    assert.throws(() => relayRecordOf(grant, scope, new Set()), /admitted/);
    assert.throws(() => relayRecordOf(grant, "04".repeat(32), issuers), /admitted/);
    assert.throws(() => relayRecordOf({ ...grant, body: grant.body.replace('"generation":1', '"generation":2') }, scope, issuers), /signature/);
    assert.equal(records.take(grant, scope, issuers), true);
    assert.equal(records.take(revoked, scope, issuers), true);
    assert.equal(records.take(grant, scope, issuers), false);
    const kept = db.prepare("SELECT body FROM mesh_relay_records WHERE scope=? AND node=?").get(scope, node)!;
    assert.equal(JSON.parse(String(kept.body)).revoked, 1);
    assert.equal(new RelayRecords(db).take(grant, scope, issuers), false);
    assert.equal(records.take(signed({ ...record, generation: 3 }), scope, issuers), true);
  } finally { db.close(); }
});
