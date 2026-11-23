import assert from "node:assert/strict";
import test from "node:test";
import { importJWK, jwtVerify } from "jose";
import { harness } from "./harness.ts";

const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

/** An iroh-style identity: an Ed25519 key whose public half, in hex, is the endpoint id. */
async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}

test("accounts own workspaces, invite each other, enroll stations and get credentials for them", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));

    // Each account sees only its own workspaces; one account may create several.
    const home = await (await alice("POST", "/v1/workspaces", { name: "  Home  " })).json() as any;
    assert.equal(home.name, "Home");
    assert.equal(home.role, "owner");
    await alice("POST", "/v1/workspaces", { name: "Lab" });
    const aliceMe = await (await alice("GET", "/v1/me")).json() as any;
    assert.deepEqual(aliceMe.workspaces.map((w: any) => w.name), ["Home", "Lab"]);
    assert.equal(aliceMe.user.name, "Name of alice");
    assert.equal((await bob("GET", `/v1/workspaces/${home.id}`)).status, 404);

    // An invitation bound to bob's email; bob previews and accepts it.
    const invite = await (await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: "member", email: "bob@example.test" })).json() as any;
    assert.match(invite.url, /\/invite#/);
    const preview = await (await bob("POST", "/v1/invitations/preview", { token: invite.token })).json() as any;
    assert.deepEqual([preview.name, preview.role, preview.inviter], ["Home", "member", "Name of alice"]);
    const carol = h.as(await h.login("carol"));
    assert.equal((await carol("POST", "/v1/invitations/accept", { token: invite.token })).status, 403, "bound to another email");
    assert.equal((await bob("POST", "/v1/invitations/accept", { token: invite.token })).status, 200);
    assert.equal((await bob("POST", "/v1/invitations/accept", { token: invite.token })).status, 404, "one use");
    assert.deepEqual(((await (await bob("GET", "/v1/me")).json()) as any).workspaces.map((w: any) => [w.name, w.role]), [["Home", "member"]]);

    // Members cannot manage; owners decide roles; the last owner stays.
    assert.equal((await bob("POST", `/v1/workspaces/${home.id}/invitations`, {})).status, 403);
    const view = await (await alice("GET", `/v1/workspaces/${home.id}`)).json() as any;
    const bobSub = view.members.find((m: any) => m.email === "bob@example.test").sub;
    const aliceSub = view.members.find((m: any) => m.role === "owner").sub;
    assert.equal((await alice("DELETE", `/v1/workspaces/${home.id}/members/${aliceSub}`)).status, 409);
    assert.equal((await alice("PATCH", `/v1/workspaces/${home.id}/members/${bobSub}`, { role: "admin" })).status, 200);

    // A station enrolls with a one-time token and proves it holds its key.
    const enrollment = await (await bob("POST", `/v1/workspaces/${home.id}/enrollments`, { name: "willow" })).json() as any;
    assert.match(enrollment.command, /^stillfail station enroll https:\/\/relay\.example [A-Za-z0-9_-]{43}$/);
    const station = await key();
    const forged = await key();
    const enroll = (token: string, id: string, signature: string) =>
      h.fetch("/v1/stations/enroll", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token, station: id, signature, version: "0.1.0" }) });
    const message = (id: string) => `stillfail-station-enroll-v1:${h.origin}:${enrollment.token}:${id}`;
    assert.equal((await enroll(enrollment.token, station.id, await forged.sign(message(station.id)))).status, 401, "must hold the key");
    const enrolled = await (await enroll(enrollment.token, station.id, await station.sign(message(station.id)))).json() as any;
    assert.deepEqual([enrolled.workspace, enrolled.name, enrolled.relay_url], [home.id, "willow", h.origin]);
    assert.deepEqual(enrolled.relay_urls, [h.origin], "every relay, still.fail's first");
    assert.equal((await enroll(enrollment.token, forged.id, await forged.sign(message(forged.id)))).status, 404, "one use");

    const ts = h.now();
    const connect = async () => h.fetch("/v1/stations/connect", {
      headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts}`) },
    });
    // A station's socket and what it was told (h.heard: all of it has arrived).
    const listen = (socket: NonNullable<Awaited<ReturnType<typeof h.fetch>>["webSocket"]>) => {
      const frames: any[] = [];
      socket.addEventListener("message", (event) => void (event.data === "pong" || frames.push(JSON.parse(event.data as string))));
      socket.accept();
      const told = async () => {
        await h.heard(socket);
        return frames;
      };
      return told;
    };
    const presence = await connect();
    assert.equal(presence.status, 101);
    const told = listen(presence.webSocket!);

    // A mstill.fail's credential names who, where, with what role, from which device and session; stations verify it
    // offline, for 30 days, whichever of the workspace's stations it is shown to.
    const device = await key();
    const issued = await (await bob("POST", `/v1/workspaces/${home.id}/credential`, { device: device.id })).json() as any;
    const keys = await (await h.fetch("/.well-known/stillfail-grant-keys")).json() as any;
    assert.equal(keys.keys[0].d, undefined, "no private half");
    const { payload, protectedHeader } = await jwtVerify(issued.credential, await importJWK(keys.keys[0], "EdDSA"), { issuer: "stillfail-cloud", currentDate: new Date(h.now() * 1000) });
    assert.deepEqual([payload.ws, payload.role, payload.device, payload.email, payload.name], [home.id, "admin", device.id, "bob@example.test", "Name of bob"]);
    assert.deepEqual([protectedHeader.typ, payload.exp! - payload.iat!, typeof payload.sid, issued.expires_at - issued.issued_at], ["stillfail-member+jwt", 30 * 86400, "string", 30 * 86400]);
    assert.equal((await carol("POST", `/v1/workspaces/${home.id}/credential`, { device: device.id })).status, 404);

    // Removing a member: no new credential, and the stations are told to refuse the ones it holds.
    assert.equal((await alice("DELETE", `/v1/workspaces/${home.id}/members/${bobSub}`)).status, 200);
    assert.equal((await bob("POST", `/v1/workspaces/${home.id}/credential`, { device: device.id })).status, 404);
    const revoke = (await told()).find((frame) => frame.type === "revoke");
    assert.deepEqual([revoke?.kind, revoke?.id, typeof revoke?.at], ["sub", bobSub, "number"]);
    // A station connecting later hears it with its state.
    const later = listen((await connect()).webSocket!);
    assert.deepEqual((await later()).find((frame) => frame.type === "state")?.revocations.map((r: any) => [r.kind, r.id]), [["sub", bobSub]]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${home.id}/stations/${station.id}`)).status, 200);
    assert.equal((await connect()).status, 404);
  } finally {
    await h.close();
  }
});

test("an invitation waits for its email: signing in with it shows the invitation, which joins without a link", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const home = await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any;
    assert.equal((await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: "member" })).status, 400, "an email is required");
    assert.equal((await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: "member", email: "alice@example.test" })).status, 409, "already a member");
    await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: "member", email: "Bob@Example.test" });
    const me = await (await bob("GET", "/v1/me")).json() as any;
    assert.deepEqual(me.invitations.map((i: any) => [i.name, i.role, i.inviter]), [["Home", "member", "Name of alice"]]);
    const carol = h.as(await h.login("carol"));
    assert.equal((await carol("POST", `/v1/invitations/${me.invitations[0].id}/accept`)).status, 403);
    assert.equal((await bob("POST", `/v1/invitations/${me.invitations[0].id}/accept`)).status, 200);
    const after = await (await bob("GET", "/v1/me")).json() as any;
    assert.deepEqual([after.invitations.length, after.workspaces.map((w: any) => w.name)], [0, ["Home"]]);
  } finally {
    await h.close();
  }
});

for (const via of ["id", "token"] as const) {
  for (const [addedRole, invitedRole, expectedRole] of [["member", "admin", "admin"], ["member", "owner", "owner"], ["owner", "member", "owner"]] as const) {
    test(`accepting an invitation by ${via} after first sign-in joins as ${addedRole} applies ${invitedRole} without losing a stronger role`, async () => {
      const h = await harness();
      try {
        const alice = h.as(await h.login("alice"));
        const home = await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as { id: string };
        assert.equal((await alice("POST", `/v1/workspaces/${home.id}/members`, { role: addedRole, emails: ["bob@example.test"] })).status, 200);
        const response = await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: invitedRole, email: "bob@example.test" });
        assert.equal(response.status, 200);
        const invitation = await response.json() as { id: string; token: string };

        // Signing in claims the pending membership first, leaving the invitation to accept in the app or by link.
        const bob = h.as(await h.login("bob"));
        const before = await (await bob("GET", "/v1/me")).json() as any;
        assert.equal(before.workspaces[0].role, addedRole);
        assert.equal(before.invitations[0].role, invitedRole);
        const accepted = await bob("POST", via === "id" ? `/v1/invitations/${invitation.id}/accept` : "/v1/invitations/accept", via === "id" ? undefined : { token: invitation.token });
        assert.equal(accepted.status, 200);
        assert.equal((await accepted.json() as any).role, expectedRole, "both acceptance routes honor the invitation without lowering an existing role");
        const after = await (await bob("GET", "/v1/me")).json() as any;
        assert.equal(after.workspaces[0].role, expectedRole);
        assert.deepEqual(after.invitations, [], "the accepted invitation is consumed");
      } finally {
        await h.close();
      }
    });
  }
}

test("the web app may use this origin's /auth/callback; other redirects are refused", async () => {
  const h = await harness();
  try {
    const start = (redirect: string) => h.fetch("/v1/auth/google/start?" + new URLSearchParams({
      state: "s".repeat(43), code_challenge: "c".repeat(43), code_challenge_method: "S256", redirect_uri: redirect,
    }), { redirect: "manual" });
    assert.equal((await start(`${h.origin}/auth/callback`)).status, 302);
    assert.equal((await start("https://evil.example/auth/callback")).status, 400);
  } finally {
    await h.close();
  }
});

test("the Android app signs in through stillfail://auth/callback", async () => {
  const h = await harness();
  try {
    const flow = await h.begin("google-android-user", undefined, "stillfail://auth/callback");
    const { redirect, code } = await h.complete(flow);
    assert.equal(`${redirect.protocol}//${redirect.host}${redirect.pathname}`, "stillfail://auth/callback");
    assert.equal(redirect.searchParams.get("state"), flow.state);
    const tokens = await h.exchange(flow, code);
    assert.equal(tokens.status, 200);
    assert.equal(((await tokens.json()) as { subject: string }).subject, "google-android-user");
  } finally {
    await h.close();
  }
});

test("people are added by email: members at once with an account, else from their first sign-in; no invitation to accept", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const home = await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any;
    await alice("POST", `/v1/workspaces/${home.id}/invitations`, { role: "member", email: "dave@example.test" });
    const made = await (await alice("POST", `/v1/workspaces/${home.id}/members`, { role: "member", emails: ["Bob@example.test", "dave@example.test", " alice@example.test "] })).json() as any;
    assert.deepEqual([made.joined, made.added, made.already], [["bob@example.test"], ["dave@example.test"], ["alice@example.test"]]);
    assert.deepEqual(made.view.added.map((a: any) => a.email), ["dave@example.test"]);
    assert.deepEqual(made.view.invitations, [], "being added replaces the invitation");
    assert.equal((await bob("GET", `/v1/workspaces/${home.id}`)).status, 200, "an account is a member at once");
    assert.equal((await bob("POST", `/v1/workspaces/${home.id}/members`, { emails: ["x@example.test"] })).status, 403, "only managers add");
    assert.equal((await alice("POST", `/v1/workspaces/${home.id}/members`, { emails: ["not an email"] })).status, 400);
    // dave signs in for the first time: a member already.
    const dave = h.as(await h.login("dave"));
    const me = await (await dave("GET", "/v1/me")).json() as any;
    assert.deepEqual(me.workspaces.map((w: any) => [w.name, w.role]), [["Home", "member"]]);
    const view = await (await alice("GET", `/v1/workspaces/${home.id}`)).json() as any;
    assert.deepEqual([view.members.length, view.added], [3, []]);
    // One added and taken back before signing in never joins.
    await alice("POST", `/v1/workspaces/${home.id}/members`, { emails: ["erin@example.test"] });
    await alice("DELETE", `/v1/workspaces/${home.id}/added/erin@example.test`);
    const erin = h.as(await h.login("erin"));
    assert.deepEqual((await (await erin("GET", "/v1/me")).json() as any).workspaces, []);
  } finally {
    await h.close();
  }
});

test("an account over its requests a minute is told to wait (429), not that it is signed out", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    let last = await alice("GET", "/v1/me");
    for (let i = 0; i < 130 && last.status === 200; i++) last = await alice("GET", "/v1/me");
    assert.equal(last.status, 429);
    assert.deepEqual(await last.json(), { error: "rate_limited" });
  } finally {
    await h.close();
  }
});

test("the locks kept for the stations from before use up none of an account's requests a minute, and have a minute of their own", async () => {
  // (the locks' end to end, 2026-11-10: what a person's devices signed was sent here too, not waited on, 44 requests
  // of the account's 123 that minute, and the owner's next change, a member added, was refused, 429)
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    let lock = await alice("GET", "/v1/me/personal-lock");
    for (let i = 0; i < 130 && lock.status === 200; i++) lock = await alice("GET", "/v1/me/personal-lock");
    assert.equal(lock.status, 429);
    assert.deepEqual([(await alice("GET", `/v1/workspaces/${ws}/lock`)).status, (await alice("GET", `/v1/workspaces/${ws}/devices`)).status], [429, 429], "the workspace's lock and its devices in the same minute");
    assert.equal((await alice("GET", "/v1/me")).status, 200);
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/members`, { emails: ["bob@example.test"] })).status, 200);
    // (and the account's own used up keeps no lock from being read)
    const bob = h.as(await h.login("bob"));
    let last = await bob("GET", "/v1/me");
    for (let i = 0; i < 130 && last.status === 200; i++) last = await bob("GET", "/v1/me");
    assert.equal(last.status, 429);
    assert.equal((await bob("GET", "/v1/me/personal-lock")).status, 200);
  } finally {
    await h.close();
  }
});

test("an account over its requests a minute still signs in a new device: its other devices' asking keeps no one out", async () => {
  // (the locks' end to end, 2026-11-10: a person's devices reading their workspaces again as they changed used up the
  // minute, and the next device's sign-in was refused, 429)
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    let last = await alice("GET", "/v1/me");
    for (let i = 0; i < 130 && last.status === 200; i++) last = await alice("GET", "/v1/me");
    assert.equal(last.status, 429);
    const another = await h.login("alice");
    assert.ok(another.access_token);
  } finally {
    await h.close();
  }
});


test("replacing an invitation at the open-invitation limit keeps its seat and invalidates its old link", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const home = await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as { id: string };
    const invite = (email: string, role = "member") => alice("POST", `/v1/workspaces/${home.id}/invitations`, { role, email });
    const first = await (await invite("bob@example.test")).json() as { id: string; token: string };
    for (let i = 1; i < 50; i++) assert.equal((await invite(`person${i}@example.test`)).status, 200);
    const extra = await invite("extra@example.test");
    assert.equal(extra.status, 429);
    assert.equal((await extra.json() as any).error, "too_many_invitations");

    const response = await invite("Bob@Example.test", "admin");
    assert.equal(response.status, 200, "replacing one of the fifty invitations adds no invitation");
    const replacement = await response.json() as { id: string; token: string };
    assert.notEqual(replacement.id, first.id);
    assert.notEqual(replacement.token, first.token);
    const view = await (await alice("GET", `/v1/workspaces/${home.id}`)).json() as any;
    assert.equal(view.invitations.length, 50);
    assert.deepEqual(view.invitations.filter((i: any) => i.email === "bob@example.test").map((i: any) => [i.id, i.role]), [[replacement.id, "admin"]]);
    assert.equal((await bob("POST", "/v1/invitations/preview", { token: first.token })).status, 404);
    assert.equal((await bob("POST", `/v1/invitations/${first.id}/accept`)).status, 404);
    assert.equal((await invite("another@example.test")).status, 429, "replacement never raises the cap");
    const accepted = await bob("POST", "/v1/invitations/accept", { token: replacement.token });
    assert.equal(accepted.status, 200);
    assert.equal((await accepted.json() as any).role, "admin");
  } finally {
    await h.close();
  }
});

test("a credential is one call of the Directory, and one asked by a non-member keeps nothing of its device", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const carol = h.as(await h.login("carol"));
    const ws = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    const directory = await h.object("DIRECTORY", "primary");
    await h.settled();
    // (adminLoad counts itself as "admin", not here)
    const workspaces = async () => ((await directory.adminLoad()).calls.families.workspaces ?? []).reduce((a: number, b: number) => a + b, 0);
    const device = await key();
    const before = await workspaces();
    const issued = (await (await alice("POST", `/v1/workspaces/${ws}/credential`, { device: device.id, kind: "app", label: "alice's Mac" })).json()) as any;
    assert.equal(typeof issued.credential, "string");
    assert.ok(Array.isArray(issued.relay_urls));
    assert.equal((await workspaces()) - before, 1, "the role and the device in one call");

    // Not a member: refused, its device not kept, not even once it joins later.
    const stranger = await key();
    assert.equal((await carol("POST", `/v1/workspaces/${ws}/credential`, { device: stranger.id })).status, 404);
    const invite = (await (await alice("POST", `/v1/workspaces/${ws}/invitations`, { role: "member", email: "carol@example.test" })).json()) as any;
    assert.equal((await carol("POST", "/v1/invitations/accept", { token: invite.token })).status, 200);
    const devices = ((await (await alice("GET", `/v1/workspaces/${ws}/devices`)).json()) as any).devices;
    assert.deepEqual(devices.map((d: any) => [d.email, d.device, d.kind, d.label]), [["alice@example.test", device.id, "app", "alice's Mac"]]);
  } finally {
    await h.close();
  }
});
