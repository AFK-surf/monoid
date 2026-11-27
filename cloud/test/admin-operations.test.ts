// What the console's operators do beyond its lists: a report read whole by its number, a code's link for each product,
// a token for a way into a relay and one taken back, the probes kept, a workspace's rigs, its limits given back, owners
// put in and an email added taken back, and every change of theirs in its 操作记录 (GET /v1/admin/audit).
import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}

async function enroll(h: Harness, token: string, body: Record<string, unknown> = {}) {
  const station = await key();
  const signature = await station.sign(`stillfail-station-enroll-v1:${h.origin}:${token}:${station.id}`);
  const response = await h.fetch("/v1/stations/enroll", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, station: station.id, signature, version: "0.5.0", ...body }),
  });
  assert.equal(response.status, 200);
  return station;
}

const audit = async (admin: ReturnType<Harness["as"]>) =>
  (((await (await admin("GET", "/v1/admin/audit")).json()) as any).audit as any[]).map((a) => [a.actor, a.action, a.target, a.detail]);

test("a report is read whole by its id or its number, though the console's list carries none of its logs", async () => {
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const admin = h.as(aliceTokens, "admin");
    const bob = h.as(await h.login("bob"));
    const logs = "x".repeat(60_000);
    for (const n of [1, 2, 3]) assert.equal((await bob("POST", "/v1/feedback", { key: `k${n}`, title: `第 ${n} 个`, body: "b", area: "web", ...(n === 1 ? { logs } : {}) })).status, 201);
    const listed = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback as any[];
    assert.deepEqual(listed.map((f) => [f.number, f.logs, f.has_logs]), [[3, null, false], [2, null, false], [1, null, true]]);
    // The feedback monitor's list has them whole, as before.
    const monitor = ((await (await h.fetch("/v1/admin/feedback/list", { method: "POST", headers: { authorization: `Bearer ${h.feedbackToken}`, "content-type": "application/json" }, body: "{}" })).json()) as any).feedback as any[];
    assert.equal(monitor[2].logs.length, logs.length);
    for (const ref of [listed[2].id, "FB-1", "fb-1", "1"]) {
      const one = (await (await admin("GET", `/v1/admin/feedback/${ref}`)).json()) as any;
      assert.deepEqual([one.item.number, one.item.logs.length, one.item.has_logs, one.item.replies], [1, logs.length, true, []], ref);
    }
    assert.equal((await admin("GET", "/v1/admin/feedback/FB-9")).status, 404);
    assert.equal((await bob("GET", "/v1/admin/feedback/FB-1")).status, 404, "the console's alone");
  } finally {
    await h.close();
  }
});

test("where the cloud answers as two products, a code has each one's sign-up link", async () => {
  const h = await harness({ origin: "https://app.monoid.build", guests: [{ origin: "https://app.still.fail", beta: "https://app.youdid.wtf" }], forwardSecret: "s".repeat(43) });
  try {
    const admin = h.as(await h.login("alice"), "admin");
    const made = (await (await admin("POST", "/v1/admin/invite-codes", {})).json()) as any;
    assert.equal(made.url, `https://app.monoid.build/?invite=${made.code}`);
    assert.deepEqual(made.links, [{ product: "monoid", url: `https://app.monoid.build/?invite=${made.code}` }, { product: "still.fail", url: `https://app.still.fail/?invite=${made.code}` }]);
    const listed = ((await (await admin("GET", "/v1/admin/invite-codes")).json()) as any).codes[0];
    assert.deepEqual(listed.links, made.links);
  } finally {
    await h.close();
  }
  // One product: one link, as before.
  const one = await harness();
  try {
    const made = (await (await one.as(await one.login("alice"), "admin")("POST", "/v1/admin/invite-codes", {})).json()) as any;
    assert.equal("links" in made, false);
  } finally {
    await one.close();
  }
});

test("a token is made for a way into a relay of the list, its machine saying its own address; one not used is taken back", async () => {
  const BEIJING = "https://203.0.113.7";
  const h = await harness({ relayUrls: BEIJING, relayNames: { [BEIJING]: "北京" } });
  try {
    const admin = h.as(await h.login("alice"), "admin");
    assert.equal((await admin("POST", "/v1/admin/relays/token", { name: "入口", target: "https://nowhere.example" })).status, 400);
    const made = (await (await admin("POST", "/v1/admin/relays/token", { name: "北京转香港", target: BEIJING })).json()) as any;
    assert.equal(made.url, null);
    const listed = async () => ((await (await admin("POST", "/v1/admin/relays/list", {})).json()) as any).tokens as any[];
    const [token] = await listed();
    assert.deepEqual([token.name, token.url, token.target], ["北京转香港", null, BEIJING]);
    assert.match(token.id, /^[A-Za-z0-9_-]{16}$/);
    assert.equal(JSON.stringify(await listed()).includes(made.token), false, "never the token");
    // Its machine enrolls at the address it says: a way into Beijing.
    const ENTRY = "https://198.51.100.4:8443";
    const enrolled = await h.fetch("/v1/relays/enroll", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: made.token, url: ENTRY }) });
    assert.equal(enrolled.status, 200);
    const relays = ((await (await admin("POST", "/v1/admin/relays/list", {})).json()) as any).relays as any[];
    assert.deepEqual(relays.find((r) => r.url === ENTRY)?.target, BEIJING);
    // Another, taken back before it is used.
    await admin("POST", "/v1/admin/relays/token", { name: "多签了一个" });
    const [extra] = await listed();
    assert.equal((await admin("POST", "/v1/admin/relays/token/revoke", { id: "nope" })).status, 400);
    assert.deepEqual(await (await admin("POST", "/v1/admin/relays/token/revoke", { id: extra.id })).json(), { revoked: true });
    assert.deepEqual(await listed(), []);
    // The operator renames a relay of the list.
    assert.equal((await admin("POST", "/v1/admin/relays/put", { url: BEIJING, name: "北京 2" })).status, 200);
    // (the latest four: the harness put Beijing on the list as it started, by the operator's token)
    assert.deepEqual((await audit(admin)).slice(0, 4).map((a) => a.slice(1, 3)), [["relay.put", "北京 2"], ["relay.token_revoke", extra.id], ["relay.token", "多签了一个"], ["relay.token", "北京转香港"]]);
  } finally {
    await h.close();
  }
});

test("what the probes found of each relay is kept, its latest shown on the console's relays page", async () => {
  const h = await harness();
  try {
    const admin = h.as(await h.login("alice"), "admin");
    const loads: any = await h.mf.getDurableObjectNamespace("RELAY_LOAD", "api");
    const load = loads.get(loads.idFromName("primary"));
    const line = { probe_country: "CN", probe_region: "", probe_city: "Beijing", probe_asn: 9808, probe_network: "China Mobile", rtt_avg: 80, loss: 0, status: "finished" };
    await load.recordProbes({ [h.origin]: [line], "https://gone.example": [] });
    const page = (await (await admin("GET", "/v1/admin/relays")).json()) as any;
    assert.deepEqual(page.relays[0].probes, { at: h.now(), lines: [line] });
  } finally {
    await h.close();
  }
});

test("the admin sees a workspace's rigs, gives its limits back, puts owners in and takes an added email back", async () => {
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const admin = h.as(aliceTokens, "admin");
    const alice = h.as(aliceTokens);
    const bobTokens = await h.login("bob");
    const bob = h.as(bobTokens);
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    const rigToken = ((await (await bob("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "build-box" })).json()) as any).token as string;
    const rig = await enroll(h, rigToken, { rig: true });
    const listed = async () => (((await (await admin("GET", "/v1/admin/workspaces")).json()) as any).workspaces as any[]).find((w) => w.id === home);
    const w = await listed();
    assert.deepEqual(w.rigs.map((r: any) => [r.id, r.name, r.owner_email]), [[rig.id, "build-box", "bob@example.test"]]);
    assert.deepEqual(w.stations, []);

    // A company's workspace, its limits given back to its creator's plan (the admin's).
    const made = (await (await admin("POST", "/v1/admin/workspaces", { name: "Acme", owners: ["boss@acme.example"], members: 20, stations: 64 })).json()) as any;
    const acme = async () => (((await (await admin("GET", "/v1/admin/workspaces")).json()) as any).workspaces as any[]).find((x) => x.id === made.id);
    assert.equal((await acme()).plan, "enterprise");
    const reset = (await (await admin("POST", `/v1/admin/workspaces/${made.id}/limits`, { reset: true })).json()) as any;
    assert.deepEqual([reset.reset, reset.stations], [true, 64]);
    assert.equal((await acme()).plan, "admin");

    // Owners put in: a member made one, an account joined, an email added; one written wrong taken back.
    const ownersOf = (x: any) => [...x.members.filter((m: any) => m.role === "owner").map((m: any) => m.email), ...x.added.map((a: any) => a.email)].sort();
    const put = (await (await admin("POST", `/v1/admin/workspaces/${home}/owners`, { emails: ["bob@example.test", "carol@example.test", "Typo@Example.test"] })).json()) as any;
    assert.deepEqual([put.joined.sort(), put.added], [["bob@example.test"], ["carol@example.test", "typo@example.test"]]);
    assert.deepEqual(ownersOf(await listed()), ["alice@example.test", "bob@example.test", "carol@example.test", "typo@example.test"]);
    assert.equal((await admin("POST", `/v1/admin/workspaces/${home}/added/remove`, { email: "typo@example.test" })).status, 200);
    assert.deepEqual(ownersOf(await listed()), ["alice@example.test", "bob@example.test", "carol@example.test"]);
    // bob, an owner now, may add owners himself.
    assert.equal((await bob("POST", `/v1/workspaces/${home}/members`, { role: "owner", emails: ["dave@example.test"] })).status, 200);

    assert.deepEqual((await audit(admin)).map((a) => a.slice(0, 4)), [
      ["alice@example.test", "workspace.added_remove", "Home", "typo@example.test"],
      ["alice@example.test", "workspace.owners", "Home", "bob@example.test, carol@example.test, Typo@Example.test"],
      ["alice@example.test", "workspace.limits", "Acme", "reset"],
      ["alice@example.test", "workspace.create", "Acme", "boss@acme.example"],
    ]);
  } finally {
    await h.close();
  }
});

test("every change of the operators is noted, by whom, of what as it was called; the scripts' and the monitor's too", async () => {
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const admin = h.as(aliceTokens, "admin");
    const bobTokens = await h.login("bob");
    const bob = h.as(bobTokens);
    assert.equal((await admin("POST", `/v1/admin/users/${bobTokens.subject}/beta`, { on: true })).status, 200);
    assert.equal((await admin("POST", `/v1/admin/users/${bobTokens.subject}/block`, { on: true })).status, 200);
    // A refused one is not noted.
    assert.equal((await admin("POST", `/v1/admin/users/${aliceTokens.subject}/block`, { on: true })).status, 403);
    const code = (await (await admin("POST", "/v1/admin/invite-codes", { note: "给小王", days: 7 })).json()) as any;
    const ws = ((await (await admin("POST", "/v1/admin/workspaces", { name: "Gone", owners: ["x@example.test"], members: 5, stations: 64 })).json()) as any).id as string;
    // Deleted by the scripts' token: still named as it was.
    assert.equal((await h.fetch(`/v1/admin/workspaces/${ws}/delete`, { method: "POST", headers: { authorization: `Bearer ${h.adminToken}` } })).status, 200);
    const missingDelete = await h.fetch(`/v1/admin/workspaces/${ws}/delete`, { method: "POST", headers: { authorization: `Bearer ${h.adminToken}` } });
    assert.equal(missingDelete.status, 404);
    assert.deepEqual(await missingDelete.json(), { error: "workspace_not_found" });
    const badBlock = await h.fetch(`/v1/admin/accounts/${bobTokens.subject}`, { method: "POST", headers: { authorization: `Bearer ${h.adminToken}`, "content-type": "application/json" }, body: "{" });
    assert.equal(badBlock.status, 400);
    assert.deepEqual(await badBlock.json(), { error: "invalid_request" });
    const carol = h.as(await h.login("carol"));
    assert.equal((await carol("POST", "/v1/feedback", { key: "k", title: "t", body: "b", area: "web" })).status, 201);
    const fb = ((await (await admin("GET", "/v1/admin/feedback")).json()) as any).feedback[0].id as string;
    assert.equal((await h.fetch(`/v1/admin/feedback/${fb}/status`, { method: "POST", headers: { authorization: `Bearer ${h.feedbackToken}`, "content-type": "application/json" }, body: JSON.stringify({ status: "triaged" }) })).status, 200);
    assert.deepEqual(await audit(admin), [
      ["feedback-monitor", "feedback.status", "FB-1", "triaged"],
      ["admin-token", "workspace.delete", "Gone", ""],
      ["alice@example.test", "workspace.create", "Gone", "x@example.test"],
      ["alice@example.test", "code.create", code.code, "给小王 · days=7"],
      ["alice@example.test", "user.block", "bob@example.test", "on"],
      ["alice@example.test", "user.beta", "bob@example.test", "on"],
    ]);
    assert.equal((await bob("GET", "/v1/admin/audit")).status, 404, "the console's alone");
  } finally {
    await h.close();
  }
});
