import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";

type Harness = Awaited<ReturnType<typeof harness>>;

async function listen(h: Harness, token: string) {
  const response = await h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${token}` } });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  const got: { type: string; entry?: { name: string } }[] = [];
  const closed = new Promise<number>((resolve) => ws.addEventListener("close", (event) => resolve(event.code), { once: true }));
  ws.addEventListener("message", (event) => { if (event.data !== "pong") got.push(JSON.parse(event.data as string)); });
  ws.accept();
  await h.heard(ws);
  return { ws, got, closed };
}

async function primary(h: Harness) {
  assert.equal((await h.fetch("/__test/sockets", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ where: "primary" }) })).status, 200);
}

for (const where of ["objects", "primary"] as const) for (const end of ["remove", "logout", "logout_all", "idle", "absolute", "block", "delete"] as const) {
  test(`${where}: ${end} stops the ended sessions' events and keeps other devices' events`, async () => {
    const h = await harness();
    try {
      if (where === "primary") await primary(h);
      const alice = await h.login("alice"), old = await h.login("bob"), current = await h.login("bob");
      const owner = h.as(alice);
      const home = await (await owner("POST", "/v1/workspaces", { name: "Home" })).json() as { id: string };
      assert.equal((await owner("POST", `/v1/workspaces/${home.id}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
      const on = { owner: await listen(h, alice.access_token), old: await listen(h, old.access_token), other: await listen(h, current.access_token) };
      for (const listener of Object.values(on)) {
        await h.heard(listener.ws);
        listener.got.length = 0;
      }
      if (end === "idle" || end === "absolute") {
        const account = await h.object("ACCOUNTS", old.subject);
        await account.expire(old.session_id, end);
        if (end === "idle") await h.login("bob"); // create() prunes old sessions before adding the new one.
        else await account.sweepSessions();
      } else {
        const ended = end === "remove"
          ? await h.as(current)("DELETE", `/v1/auth/sessions/${old.session_id}`)
          : end === "block"
          ? await h.fetch(`/v1/admin/accounts/${old.subject}`, { method: "POST", headers: { authorization: `Bearer ${h.adminToken}`, "content-type": "application/json" }, body: JSON.stringify({ blocked: true }) })
          : end === "delete"
          ? await h.as(old)("DELETE", "/v1/me")
          : await h.fetch("/v1/auth/logout", { method: "POST", headers: { authorization: `Bearer ${old.refresh_token}`, "content-type": "application/json" }, body: JSON.stringify({ all: end === "logout_all" }) });
        assert.equal(ended.status, 200);
      }
      const all = end === "logout_all" || end === "block" || end === "delete";
      assert.equal(await on.old.closed, 1008);
      if (all) assert.equal(await on.other.closed, 1008);
      // Deleting the account tells it that its memberships went away before ending its sessions.
      on.old.got.length = 0;
      if (all) on.other.got.length = 0;
      assert.equal((await h.as(old)("GET", "/v1/me")).status, 401);
      const name = "Private workspace after revocation";
      assert.equal((await owner("PATCH", `/v1/workspaces/${home.id}`, { name })).status, 200);
      await h.heard(on.owner.ws);
      assert.ok(on.owner.got.some((event) => event.entry?.name === name), "another account's connection still receives the change");
      assert.deepEqual(on.old.got, [], "the ended session receives nothing after revocation");
      if (all) assert.deepEqual(on.other.got, [], "ending the account ends both sessions");
      else {
        await h.heard(on.other.ws);
        assert.ok(on.other.got.some((event) => event.entry?.name === name), "the same account's other session still receives the change");
      }
    } finally {
      await h.close();
    }
  });
}

test("an events connection revoked while the Directory notes its opening receives none of the queued changes", async () => {
  const h = await harness();
  try {
    const old = await h.login("alice"), current = h.as(await h.login("alice"));
    const home = await (await current("POST", "/v1/workspaces", { name: "Home" })).json() as { id: string };
    const account = await h.object("ACCOUNTS", old.subject);
    await account.holdOpening();
    const opening = h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${old.access_token}` } });
    await account.openingHeld();
    assert.equal((await current("DELETE", `/v1/auth/sessions/${old.session_id}`)).status, 200);
    assert.equal((await current("PATCH", `/v1/workspaces/${home.id}`, { name: "Changed during opening" })).status, 200);
    await h.settled();
    await account.letOpen();
    const response = await opening;
    assert.equal(response.status, 401);
    assert.equal(response.webSocket, null);
    const directory = await h.object("DIRECTORY", "primary");
    assert.equal((await directory.adminLoad()).live.accounts, 0, "the refused opening does not leave the account counted as connected");
  } finally {
    await h.close();
  }
});

test("the Directory rechecks a session revoked after the Worker's earlier check", async () => {
  const h = await harness();
  try {
    await primary(h);
    const old = await h.login("alice"), current = h.as(await h.login("alice"));
    assert.equal((await current("DELETE", `/v1/auth/sessions/${old.session_id}`)).status, 200);
    // A request already authenticated by the Worker, arriving at the Directory after the session was revoked.
    const directory = await h.object("DIRECTORY", "primary");
    const response = await directory.fetch("https://directory/events", { headers: { upgrade: "websocket", "x-stillfail-sub": old.subject, "x-stillfail-sid": old.session_id, "x-stillfail-protocol": "stillfail-events" } });
    assert.equal(response.status, 401);
    assert.equal(response.webSocket, null);
  } finally {
    await h.close();
  }
});

test("prune skips the Directory when no session ended, and a session removed again is told to it again", async () => {
  const h = await harness();
  try {
    await primary(h);
    const old = await h.login("alice"), current = await h.login("alice");
    const asCurrent = h.as(current);
    const account = await h.object("ACCOUNTS", old.subject);
    const directory = await h.object("DIRECTORY", "primary");
    const meCalls = async () => ((await directory.adminLoad()).calls.families.me ?? []).reduce((a: number, b: number) => a + b, 0);

    const base = await meCalls();
    await account.sweepSessions();
    assert.equal(await meCalls(), base, "sweepSessions skips revokeSessions when nothing expired");

    assert.equal((await asCurrent("DELETE", `/v1/auth/sessions/${old.session_id}`)).status, 200);
    await h.settled();
    assert.equal(await meCalls(), base + 1, "removing an active session notifies Directory once");

    const repeated = await asCurrent("DELETE", `/v1/auth/sessions/${old.session_id}`);
    assert.equal(repeated.status, 200);
    assert.deepEqual(await repeated.json(), { revoked: true });
    await h.settled();
    // A removal whose Directory call failed is retried by asking again: the Directory must hear it again.
    assert.equal(await meCalls(), base + 2, "removing an already removed session tells the Directory again");
    assert.equal((await asCurrent("GET", "/v1/me")).status, 200, "active session stays valid");
    const beforeExpire = await meCalls();

    await account.expire(current.session_id, "idle");
    await account.sweepSessions();
    await h.settled();
    assert.equal(await meCalls(), beforeExpire + 1, "expiring an active session notifies Directory once");
  } finally {
    await h.close();
  }
});
