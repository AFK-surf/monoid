// A workspace's provisioning keys (src/directory/stations.ts): what a console holds to enroll the stations of machines
// it makes for that workspace, one enrollment at a time (`/v1/provision/*`), each the one-hour, one-use token of a whole
// station an owner's 添加 station makes.
import assert from "node:assert/strict";
import test from "node:test";
import { STATIONS_PER_WORKSPACE } from "../../client/limits.ts";
import { harness } from "./harness.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}

async function enroll(h: Harness, station: Awaited<ReturnType<typeof key>>, token: string, rig = false): Promise<{ status: number; body: any }> {
  const signature = await station.sign(`stillfail-station-enroll-v1:${h.origin}:${token}:${station.id}`);
  const response = await h.fetch("/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, station: station.id, signature, version: "0.5.0", ...(rig ? { rig: true } : {}) }),
  });
  return { status: response.status, body: await response.json() };
}

/** A call with a provisioning key (or any bearer), as a console makes it. */
const withKey = (h: Harness, bearer: string, method: string, path: string, value?: unknown) =>
  h.fetch(path, {
    method,
    headers: { authorization: `Bearer ${bearer}`, ...(value === undefined ? {} : { "content-type": "application/json" }) },
    ...(value === undefined ? {} : { body: JSON.stringify(value) }),
  });

async function setUp(h: Harness) {
  const aliceTokens = await h.login("alice");
  const alice = h.as(aliceTokens);
  const bob = h.as(await h.login("bob"));
  const carol = h.as(await h.login("carol"));
  const ws = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
  assert.equal((await alice("POST", `/v1/workspaces/${ws}/members`, { role: "admin", emails: ["bob@example.test"] })).status, 200);
  assert.equal((await alice("POST", `/v1/workspaces/${ws}/members`, { role: "member", emails: ["carol@example.test"] })).status, 200);
  const view = (await (await alice("GET", `/v1/workspaces/${ws}`)).json()) as any;
  const subOf = (email: string) => view.members.find((m: any) => m.email === email).sub as string;
  return { alice, aliceTokens, bob, carol, ws, subOf };
}

test("a workspace's owners and admins make, list and revoke its provisioning keys; a member, or one outside it, none", async () => {
  const h = await harness();
  try {
    const { alice, bob, carol, ws, subOf } = await setUp(h);
    const path = `/v1/workspaces/${ws}/provision-keys`;

    const made = await alice("POST", path, { name: "  Machine   fleet ", days: 30 });
    assert.equal(made.status, 200);
    const first = (await made.json()) as any;
    assert.match(first.key, /^sfpk_[A-Za-z0-9_-]{43}$/);
    assert.match(first.id, /^pk_[0-9A-Z]{26}$/);
    assert.equal(first.prefix, first.key.slice(0, 13));
    assert.equal(first.name, "Machine fleet");
    assert.equal(first.workspace, ws);
    assert.equal(first.created_by, subOf("alice@example.test"));
    assert.equal(first.expires_at - first.created_at, 30 * 86_400);
    assert.deepEqual([first.last_used_at, first.revoked_at], [null, null]);

    // An admin makes one too, which never expires without days.
    const second = (await (await bob("POST", path, { name: "Bob's" })).json()) as any;
    assert.equal(second.expires_at, null);

    // Listed newest first, the key itself never again.
    const listed = (await (await bob("GET", path)).json()) as any;
    assert.deepEqual(listed.keys.map((k: any) => k.id), [second.id, first.id].sort().reverse());
    assert.ok(listed.keys.every((k: any) => !("key" in k) && !("key_hash" in k)));

    // A member makes, lists and revokes none; one outside the workspace finds none.
    assert.equal((await carol("POST", path, { name: "x" })).status, 403);
    assert.equal((await carol("GET", path)).status, 403);
    assert.equal((await carol("DELETE", `${path}/${first.id}`)).status, 403);
    const dave = h.as(await h.login("dave"));
    assert.equal((await dave("GET", path)).status, 404);
    assert.equal((await dave("POST", path, { name: "x" })).status, 404);

    // What it is given is checked.
    for (const body of [{}, { name: "" }, { name: "   " }, { name: 7 }]) assert.deepEqual(await (await alice("POST", path, body)).json(), { error: "invalid_name" }, JSON.stringify(body));
    for (const days of [0, 3651, 1.5, "7", -1]) {
      const answer = await alice("POST", path, { name: "x", days });
      assert.equal(answer.status, 400, String(days));
      assert.deepEqual(await answer.json(), { error: "invalid_days" });
    }

    // Revoking is the workspace's own key's alone, and done once however often asked.
    const revoked = await alice("DELETE", `${path}/${first.id}`);
    assert.deepEqual(await revoked.json(), { id: first.id, name: "Machine fleet", prefix: first.prefix, ok: true });
    const at = ((await (await alice("GET", path)).json()) as any).keys.find((k: any) => k.id === first.id).revoked_at;
    assert.equal(typeof at, "number");
    assert.equal((await bob("DELETE", `${path}/${first.id}`)).status, 200);
    assert.equal(((await (await alice("GET", path)).json()) as any).keys.find((k: any) => k.id === first.id).revoked_at, at);
    assert.deepEqual(await (await alice("DELETE", `${path}/pk_nothing`)).json(), { error: "key_not_found" });
    const other = ((await (await dave("POST", "/v1/workspaces", { name: "Other" })).json()) as any).id as string;
    const theirs = (await (await dave("POST", `/v1/workspaces/${other}/provision-keys`, { name: "theirs" })).json()) as any;
    assert.equal((await alice("DELETE", `${path}/${theirs.id}`)).status, 404, "another workspace's key is not found here");
  } finally {
    await h.close();
  }
});

test("a workspace keeps 20 working provisioning keys at most; a revoked or expired one makes room, and they go with the workspace", async () => {
  const h = await harness();
  try {
    const { alice, ws } = await setUp(h);
    const path = `/v1/workspaces/${ws}/provision-keys`;
    const ids: string[] = [];
    for (let i = 0; i < 20; i++) {
      const made = await alice("POST", path, { name: `k${i}` });
      assert.equal(made.status, 200, `key ${i}`);
      ids.push(((await made.json()) as any).id);
    }
    const over = await alice("POST", path, { name: "one more" });
    assert.equal(over.status, 409);
    assert.deepEqual(await over.json(), { error: "too_many_keys" });

    assert.equal((await alice("DELETE", `${path}/${ids[0]}`)).status, 200);
    assert.equal((await alice("POST", path, { name: "after a revoke" })).status, 200);
    assert.equal((await alice("POST", path, { name: "full again" })).status, 409);
    await (await h.object("DIRECTORY", "primary")).expireProvisionKey(ids[1]);
    assert.equal((await alice("POST", path, { name: "after an expiry" })).status, 200);

    // Deleting the workspace takes its keys: one made beforehand works no more.
    assert.equal((await alice("DELETE", `${path}/${ids[2]}`)).status, 200);
    const live = (await (await alice("POST", path, { name: "x" })).json()) as any;
    assert.equal((await withKey(h, live.key, "GET", "/v1/provision/verify")).status, 200);
    assert.equal((await alice("DELETE", `/v1/workspaces/${ws}`)).status, 200);
    assert.equal((await withKey(h, live.key, "GET", "/v1/provision/verify")).status, 401);
    const exported = (await (await h.fetch("/v1/admin/move/export", { method: "POST", headers: { authorization: `Bearer ${h.adminToken}` } })).json()) as any;
    assert.equal(exported.directory.provision_keys.length, 0, "no row of the workspace's keys is left");
  } finally {
    await h.close();
  }
});

test("a provisioning key verifies to its workspace while it works: never revoked, expired, unknown, another kind of token, nor its maker no longer managing", async () => {
  const h = await harness();
  try {
    const { alice, aliceTokens, bob, ws, subOf } = await setUp(h);
    const path = `/v1/workspaces/${ws}/provision-keys`;
    const made = (await (await alice("POST", path, { name: "Fleet", days: 7 })).json()) as any;

    const verified = await withKey(h, made.key, "GET", "/v1/provision/verify");
    assert.equal(verified.status, 200);
    assert.deepEqual(await verified.json(), { key_id: made.id, name: "Fleet", prefix: made.prefix, workspace: ws, workspace_name: "Home", expires_at: made.expires_at });
    const used = ((await (await alice("GET", path)).json()) as any).keys[0];
    assert.equal(used.last_used_at, h.now(), "its use is noted");

    const refused = async (bearer: string | null, why: string) => {
      const answer = await h.fetch("/v1/provision/verify", bearer === null ? {} : { headers: { authorization: `Bearer ${bearer}` } });
      assert.equal(answer.status, 401, why);
      assert.deepEqual(await answer.json(), { error: "unauthorized" }, why);
    };
    await refused(null, "no key");
    await refused(`sfpk_${"a".repeat(43)}`, "unknown");
    await refused(`sfpk_short`, "not a key's shape");
    await refused(made.key.replace(/^sfpk_/, "sfa_"), "another kind of key");
    await refused(aliceTokens.access_token, "an account's token");
    // Only GET verifies.
    assert.equal((await withKey(h, made.key, "POST", "/v1/provision/verify", {})).status, 404);

    // An expired one works no more.
    const short = (await (await alice("POST", path, { name: "Short", days: 1 })).json()) as any;
    await (await h.object("DIRECTORY", "primary")).expireProvisionKey(short.id);
    await refused(short.key, "expired");

    // One its maker made works while they manage the workspace: made a member, theirs stops; made admin again, it works.
    const bobs = (await (await bob("POST", path, { name: "Bob's" })).json()) as any;
    assert.equal((await withKey(h, bobs.key, "GET", "/v1/provision/verify")).status, 200);
    assert.equal((await alice("PATCH", `/v1/workspaces/${ws}/members/${subOf("bob@example.test")}`, { role: "member" })).status, 200);
    await refused(bobs.key, "its maker a member now");
    assert.equal((await alice("PATCH", `/v1/workspaces/${ws}/members/${subOf("bob@example.test")}`, { role: "admin" })).status, 200);
    assert.equal((await withKey(h, bobs.key, "GET", "/v1/provision/verify")).status, 200);
    assert.equal((await alice("DELETE", `/v1/workspaces/${ws}/members/${subOf("bob@example.test")}`)).status, 200);
    await refused(bobs.key, "its maker gone from the workspace");

    // Revoked: at once.
    assert.equal((await alice("DELETE", `${path}/${made.id}`)).status, 200);
    await refused(made.key, "revoked");
  } finally {
    await h.close();
  }
});

test("a provisioning key makes one-hour, one-use enrollments of whole stations, within the station limit, and opens nothing else", async () => {
  const h = await harness();
  try {
    const { alice, ws, subOf } = await setUp(h);
    const path = `/v1/workspaces/${ws}/provision-keys`;
    const made = (await (await alice("POST", path, { name: "Fleet" })).json()) as any;

    const asked = await withKey(h, made.key, "POST", "/v1/provision/enrollments", { name: "  m-001 " });
    assert.equal(asked.status, 200);
    const enrollment = (await asked.json()) as any;
    assert.equal(enrollment.workspace, ws);
    assert.equal(enrollment.expires_at, h.now() + 3600);
    assert.equal(enrollment.command, `stillfail station enroll ${h.origin} ${enrollment.token}`);
    assert.ok(enrollment.install.endsWith(` ${enrollment.token}`) && enrollment.installWindows.endsWith(` ${enrollment.token}`) && enrollment.installDocker.endsWith(` ${enrollment.token}`));
    assert.ok(!("rig" in enrollment) && !("lock" in enrollment), "the cloud names no lock and makes no rig");

    // Redeemed by a machine: a whole station of the workspace, enrolled by the key's maker, its name as asked.
    const machine = await key();
    assert.deepEqual(await enroll(h, machine, enrollment.token, true), { status: 409, body: { error: "station_enrollment" } }, "never a rig");
    const joined = await enroll(h, machine, enrollment.token);
    assert.equal(joined.status, 200);
    assert.equal(joined.body.workspace, ws);
    assert.equal(joined.body.name, "m-001");
    assert.ok(!("rig" in joined.body));
    const view = (await (await alice("GET", `/v1/workspaces/${ws}`)).json()) as any;
    const listed = view.stations.find((s: any) => s.id === machine.id);
    assert.equal(listed?.name, "m-001");
    assert.equal(listed.enrolled_by, subOf("alice@example.test"));
    assert.ok(!(view.rigs ?? []).some((r: any) => r.id === machine.id));
    // Once only.
    assert.deepEqual(await enroll(h, await key(), enrollment.token), { status: 404, body: { error: "enrollment_not_found" } });

    // Its name is checked as an owner's is.
    assert.deepEqual(await (await withKey(h, made.key, "POST", "/v1/provision/enrollments", { name: "" })).json(), { error: "invalid_name" });
    assert.equal((await withKey(h, made.key, "POST", "/v1/provision/enrollments", { name: "" })).status, 400);
    assert.equal((await withKey(h, made.key, "POST", "/v1/provision/enrollments")).status, 400, "a body is wanted");

    // The workspace's station limit holds.
    await (await h.object("DIRECTORY", "primary")).fillStations(ws, STATIONS_PER_WORKSPACE - 1);
    const full = await withKey(h, made.key, "POST", "/v1/provision/enrollments", { name: "m-065" });
    assert.equal(full.status, 429);
    assert.deepEqual(await full.json(), { error: "too_many_stations" });

    // The key opens nothing but its own routes: an account's or the console's answer it as no one's.
    for (const [method, route] of [["GET", "/v1/me"], ["GET", `/v1/workspaces/${ws}`], ["POST", `/v1/workspaces/${ws}/enrollments`], ["GET", `/v1/workspaces/${ws}/provision-keys`], ["POST", `/v1/workspaces/${ws}/provision-keys`]] as const) {
      assert.equal((await withKey(h, made.key, method, route, method === "POST" ? { name: "x" } : undefined)).status, 401, `${method} ${route}`);
    }
    const consoleAs = async (bearer: string) => (await h.fetchAdmin("/v1/admin/workspaces", { headers: { authorization: `Bearer ${bearer}` } })).status;
    assert.equal(await consoleAs(made.key), await consoleAs("not-a-token"), "the console answers it as no one's");

    // Revoked or expired: no enrollment.
    const other = (await (await alice("POST", path, { name: "Other", days: 1 })).json()) as any;
    await (await h.object("DIRECTORY", "primary")).expireProvisionKey(other.id);
    assert.deepEqual(await (await withKey(h, other.key, "POST", "/v1/provision/enrollments", { name: "m" })).json(), { error: "unauthorized" });
    assert.equal((await alice("DELETE", `${path}/${made.id}`)).status, 200);
    const gone = await withKey(h, made.key, "POST", "/v1/provision/enrollments", { name: "m" });
    assert.equal(gone.status, 401);
    assert.deepEqual(await gone.json(), { error: "unauthorized" });
  } finally {
    await h.close();
  }
});

test("a workspace's provisioning keys move with it into another cloud", async () => {
  const from = await harness();
  const into = await harness({ moving: true, signingKey: from.signingKey });
  try {
    const { alice, ws } = await setUp(from);
    const made = (await (await alice("POST", `/v1/workspaces/${ws}/provision-keys`, { name: "Fleet" })).json()) as any;
    const admin = (h: Harness) => ({ authorization: `Bearer ${h.adminToken}` });
    const exported = (await (await from.fetch("/v1/admin/move/export", { method: "POST", headers: admin(from) })).json()) as any;
    assert.deepEqual(exported.directory.provision_keys.map((k: any) => [k.id, k.workspace, k.name]), [[made.id, ws, "Fleet"]]);
    const written = await into.fetch("/v1/admin/move/import", { method: "POST", headers: { ...admin(into), "content-type": "application/json" }, body: JSON.stringify(exported) });
    assert.equal(written.status, 200);
    const again = (await (await into.fetch("/v1/admin/move/export", { method: "POST", headers: admin(into) })).json()) as any;
    assert.deepEqual(again.directory.provision_keys, exported.directory.provision_keys);
  } finally {
    await from.close();
    await into.close();
  }
});
