import assert from "node:assert/strict";
import test from "node:test";
import { harness, type OutboundRequest } from "./harness.ts";

// One cloud answering as the other product too (src/guests.ts): still.fail's accounts in monoid's cloud, still.fail's
// hosts forwarding to it.
const SECRET = "s".repeat(40);
const GUEST = "https://app.still.fail";
const GUEST_BETA = "https://app.youdid.wtf";
const guests = [{ origin: GUEST, beta: GUEST_BETA, google_client_id: "still-fail-google-client", google_client_secret: "still-fail-google-secret" }];
/** Headers as still.fail's Worker forwards a request made on `origin` from `ip`. */
const forwarded = (origin = GUEST, secret = SECRET, ip = "203.0.113.7") => ({ "x-stillfail-forwarded-origin": origin, "x-stillfail-forward-secret": secret, "x-stillfail-forwarded-for": ip });

test("a request a guest forwarded is answered as made on its origin; a wrong secret or an origin not listed is this cloud's own", async () => {
  const h = await harness({ origin: "https://app.monoid.build", guests, forwardSecret: SECRET });
  try {
    const script = async (headers: Record<string, string>) => (await h.fetch("/install.sh", { headers })).text();
    assert.match(await script(forwarded()), /app\.still\.fail/, "the guest's installer joins the guest's origin");
    assert.doesNotMatch(await script(forwarded()), /app\.monoid\.build/);
    assert.match(await script({}), /app\.monoid\.build/);
    assert.match(await script(forwarded(GUEST, "x".repeat(40))), /app\.monoid\.build/, "a wrong secret: as made here");
    assert.match(await script(forwarded("https://elsewhere.example")), /app\.monoid\.build/, "an origin not a guest's: as made here");
    // The test channel's host of the guest: its installer gives the test channel's release.
    assert.match(await script(forwarded(GUEST_BETA)), /STILLFAIL_CHANNEL:-beta/);
  } finally {
    await h.close();
  }
});

test("signing in on a guest's origin goes by its Google client and calls back there, and its tokens are good on this cloud's", async () => {
  const h = await harness({ origin: "https://app.monoid.build", guests, forwardSecret: SECRET });
  try {
    const start = new URLSearchParams({ state: "s".repeat(43), redirect_uri: "http://127.0.0.1:32145/oauth/callback", code_challenge: "c".repeat(43), code_challenge_method: "S256" });
    const asGuest = await h.fetch(`/v1/auth/google/start?${start}`, { redirect: "manual", headers: forwarded() });
    assert.equal(asGuest.status, 302, "no move to this cloud's own origin");
    const google = new URL(asGuest.headers.get("location")!);
    assert.equal(google.searchParams.get("client_id"), "still-fail-google-client");
    assert.equal(google.searchParams.get("redirect_uri"), `${GUEST}/v1/auth/google/callback`);
    const own = new URL((await h.fetch(`/v1/auth/google/start?${new URLSearchParams({ ...Object.fromEntries(start), state: "t".repeat(43) })}`, { redirect: "manual" })).headers.get("location")!);
    assert.equal(own.searchParams.get("client_id"), "test-google-client");
    assert.equal(own.searchParams.get("redirect_uri"), "https://app.monoid.build/v1/auth/google/callback");

    // A device's sign-in started on the guest's origin is finished on it.
    const device = await h.fetch("/v1/auth/device", { method: "POST", headers: { "content-type": "application/json", ...forwarded() }, body: JSON.stringify({ id: "d".repeat(43), code_challenge: "e".repeat(43), name: "a laptop" }) });
    assert.equal(((await device.json()) as { verification_uri: string }).verification_uri, `${GUEST}/v1/auth/device/${"d".repeat(43)}`);

    // Signed in here, the account's token is good with the guest's origin too (one cloud's accounts).
    const tokens = await h.login();
    const me = await h.fetch("/v1/me", { headers: { authorization: `Bearer ${tokens.access_token}`, ...forwarded() } });
    assert.equal(me.status, 200);
  } finally {
    await h.close();
  }
});

test("an enrollment's command is its product's: monoid's on monoid's cloud, still.fail's on a guest's origin", async () => {
  const h = await harness({ origin: "https://app.monoid.build", guests, forwardSecret: SECRET });
  try {
    const tokens = await h.login("alice");
    const auth = { "content-type": "application/json", authorization: `Bearer ${tokens.access_token}` };
    const made = async (path: string, headers: Record<string, string> = {}) => (await (await h.fetch(path, { method: "POST", headers: { ...auth, ...headers }, body: JSON.stringify({ name: "tokyo" }) })).json()) as { token: string; command: string };
    const own = (await (await h.fetch("/v1/workspaces", { method: "POST", headers: auth, body: JSON.stringify({ name: "Own" }) })).json()) as { id: string };
    for (const path of [`/v1/workspaces/${own.id}/enrollments`, `/v1/workspaces/${own.id}/rigs/enrollments`]) {
      const enrollment = await made(path);
      assert.equal(enrollment.command, `monoid station enroll https://app.monoid.build ${enrollment.token}`, path);
    }
    const theirs = (await (await h.fetch("/v1/workspaces", { method: "POST", headers: { ...auth, ...forwarded() }, body: JSON.stringify({ name: "Theirs" }) })).json()) as { id: string };
    const enrollment = await made(`/v1/workspaces/${theirs.id}/enrollments`, forwarded());
    assert.equal(enrollment.command, `stillfail station enroll ${GUEST} ${enrollment.token}`);
  } finally {
    await h.close();
  }
});

test("devices and stations asking on a guest's origin are handed this cloud's own relay, matching the stations' state frames", async () => {
  const HOST = "https://app.monoid.build";
  const HK = "https://47.76.247.168";
  const h = await harness({
    origin: HOST,
    guests,
    forwardSecret: SECRET,
    relayUrls: HK,
    relayNames: { [HOST]: "Cloudflare", [HK]: "香港" },
  });
  try {
    const tokens = await h.login("alice");
    await h.as(tokens, "admin")("POST", `/v1/admin/users/${tokens.subject}/beta`, { on: true });
    const auth = { authorization: `Bearer ${tokens.access_token}` };
    const created = (await (await h.fetch("/v1/workspaces", { method: "POST", headers: { "content-type": "application/json", ...auth, ...forwarded() }, body: JSON.stringify({ name: "Hypershell" }) })).json()) as { id: string };

    // Both the guest's stable and beta origins hand devices this cloud's Cloudflare relay (not the guest's unforwarded one).
    for (const guestOrigin of [GUEST, GUEST_BETA]) {
      const me = (await (await h.fetch("/v1/me", { headers: { ...auth, ...forwarded(guestOrigin) } })).json()) as any;
      assert.equal(me.relay_url, HOST);
      assert.deepEqual(me.relay_urls, [HOST, HK]);
      assert.deepEqual(me.relay_names, { [HOST]: "Cloudflare", [HK]: "香港" });
    }

    // A station enrolling and connecting through the guest's origin keeps its guest origin, while its relay matches devices'.
    const enrollment = (await (await h.fetch(`/v1/workspaces/${created.id}/enrollments`, { method: "POST", headers: { "content-type": "application/json", ...auth, ...forwarded() }, body: JSON.stringify({ name: "tokyo" }) })).json()) as { token: string; command: string };
    assert.match(enrollment.command, /https:\/\/app\.still\.fail/, "enrollment command stays on the guest's origin");

    const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const stationId = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
    const sign = async (msg: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(msg)));

    const enrolled = (await (
      await h.fetch("/v1/stations/enroll", {
        method: "POST",
        headers: { "content-type": "application/json", ...forwarded() },
        body: JSON.stringify({ token: enrollment.token, station: stationId, signature: await sign(`stillfail-station-enroll-v1:${GUEST}:${enrollment.token}:${stationId}`), version: "0.1.9230" }),
      })
    ).json()) as any;
    assert.equal(enrolled.relay_url, HOST);
    assert.deepEqual(enrolled.relay_urls, [HOST, HK]);

    const ts = h.now();
    const presence = await h.fetch("/v1/stations/connect", {
      headers: {
        upgrade: "websocket",
        "x-stillfail-station": stationId,
        "x-stillfail-ts": String(ts),
        "x-stillfail-signature": await sign(`stillfail-station-connect-v1:${GUEST}:${stationId}:${ts}`),
        ...forwarded(),
      },
    });
    assert.equal(presence.status, 101);
    const frames: any[] = [];
    presence.webSocket!.accept();
    presence.webSocket!.addEventListener("message", (ev) => {
      if (typeof ev.data === "string" && ev.data !== "pong") frames.push(JSON.parse(ev.data));
    });
    await h.heard(presence.webSocket!);
    assert.equal(frames[0]?.origin, GUEST, "station stays on the guest's origin");
    assert.equal(frames[0]?.relay_url, HOST);
    assert.deepEqual(frames[0]?.relay_urls, [HOST, HK]);
    assert.deepEqual(frames[0]?.stillfail_relays, [HOST, HK]);

    // A member's workspace credential request on the guest's origin also names the same relay.
    const devPair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const devId = hex((await crypto.subtle.exportKey("raw", devPair.publicKey)) as ArrayBuffer);
    const cred = (await (
      await h.fetch(`/v1/workspaces/${created.id}/credential`, {
        method: "POST",
        headers: { "content-type": "application/json", ...auth, ...forwarded() },
        body: JSON.stringify({ device: devId }),
      })
    ).json()) as any;
    assert.equal(cred.relay_url, HOST);
    assert.deepEqual(cred.relay_urls, [HOST, HK]);
  } finally {
    await h.close();
  }
});

test("a cloud that moved forwards what reaches it, saying its origin and client, but keeps answering its releases", async () => {
  const got: OutboundRequest[] = [];
  const h = await harness({
    forwardTo: "https://app.monoid.build",
    forwardSecret: SECRET,
    push: (request) => {
      got.push(request);
      return { status: 200, body: JSON.stringify({ there: true }) };
    },
  });
  try {
    const answer = await h.fetch("/v1/me?x=1", { headers: { authorization: "Bearer abc", "cf-connecting-ip": "198.51.100.4" } });
    assert.deepEqual(await answer.json(), { there: true });
    assert.equal(got.length, 1);
    assert.equal(got[0]!.url, "https://app.monoid.build/v1/me?x=1");
    assert.equal(got[0]!.headers["x-stillfail-forwarded-origin"], h.origin);
    assert.equal(got[0]!.headers["x-stillfail-forward-secret"], SECRET);
    assert.equal(got[0]!.headers["x-stillfail-forwarded-for"], "198.51.100.4");
    assert.equal(got[0]!.headers.authorization, "Bearer abc");
    // Its releases are its own bucket's: asked here, not there.
    assert.equal((await h.fetch("/releases/android/latest.json")).status, 404);
    assert.equal(got.length, 1);
  } finally {
    await h.close();
  }
});
