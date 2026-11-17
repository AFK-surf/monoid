// The cloud's list of relays (src/relay-registry.ts): taken once from what the deploy's config said, kept by its
// operator after (the console, ADMIN_TOKEN), a relay putting itself on it only with a token the operator made for it,
// and every station and device told as it changes.
import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function station(h: Harness, token: string) {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  const enrolled = await h.fetch("/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, station: id, signature: await sign(`stillfail-station-enroll-v1:${h.origin}:${token}:${id}`), version: "0.5.0" }),
  });
  assert.equal(enrolled.status, 200);
  const told = (await enrolled.json()) as { relay_urls: string[] };
  const ts = h.now();
  const response = await h.fetch("/v1/stations/connect", {
    headers: { upgrade: "websocket", "x-stillfail-station": id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await sign(`stillfail-station-connect-v1:${h.origin}:${id}:${ts}`) },
  });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  const frames: any[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || frames.push(JSON.parse(event.data as string))));
  ws.accept();
  await h.heard(ws);
  return { told, state: () => frames.filter((f) => f.type === "state").at(-1), heard: () => h.heard(ws) };
}

async function listen(h: Harness, token: string) {
  const response = await h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${token}` } });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  ws.accept();
  const got: any[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || got.push(JSON.parse(event.data as string))));
  return { take: async () => (await h.heard(ws), got.splice(0).map((e) => e.type)) };
}

const BEIJING = "https://203.0.113.7";
const NEW = "https://203.0.113.9";

test("the list is taken once from the deploy's config; a relay puts itself on it only with the operator's token, and every station and device is told", async () => {
  const h = await harness({ relayUrls: BEIJING, relayNames: { [BEIJING]: "北京" } });
  try {
    const tokens = { alice: await h.login("alice"), bob: await h.login("bob") };
    const alice = h.as(tokens.alice), console_ = h.as(tokens.alice, "admin"), bob = h.as(tokens.bob, "admin");
    const me = async () => (await (await alice("GET", "/v1/me")).json()) as { relay_urls: string[]; relay_names: Record<string, string> };
    assert.deepEqual((await me()).relay_urls, [h.origin, BEIJING]);
    assert.deepEqual((await me()).relay_names, { [BEIJING]: "北京" });
    const w = ((await (await alice("POST", "/v1/workspaces", { name: "Lab" })).json()) as any).id as string;
    const s = await station(h, ((await (await alice("POST", `/v1/workspaces/${w}/enrollments`, { name: "s" })).json()) as any).token);
    assert.deepEqual(s.told.relay_urls, [h.origin, BEIJING]);
    assert.deepEqual(s.state().relay_urls, [h.origin, BEIJING]);
    const events = await listen(h, tokens.alice.access_token);

    const listed = (await (await console_("POST", "/v1/admin/relays/list", {})).json()) as any;
    assert.deepEqual(listed.relays.map((r: any) => [r.url, r.name, r.added_by, r.enrolled]), [[BEIJING, "北京", "config", false]]);
    // Only the operator keeps it.
    assert.equal((await bob("POST", "/v1/admin/relays/token", { name: "x" })).status, 404);
    assert.equal((await h.fetch("/v1/admin/relays/list", { method: "POST", headers: { authorization: "Bearer wrong" } })).status, 401);

    // A token for a relay at a URL; it enrolls there alone, once.
    assert.equal((await console_("POST", "/v1/admin/relays/token", { name: "" })).status, 400);
    const made = (await (await console_("POST", "/v1/admin/relays/token", { name: "东京", url: `${NEW}/` })).json()) as { token: string; url: string; command: string };
    assert.equal(made.url, NEW);
    assert.match(made.command, new RegExp(`relay-enroll\\.sh ${h.origin} ${made.token}$`));
    assert.equal((await events.take()).length, 0, "nothing told for a token made");
    const enroll = (body: unknown) => h.fetch("/v1/relays/enroll", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    assert.equal((await enroll({ token: "nope", url: NEW })).status, 403);
    assert.equal((await enroll({ token: made.token, url: "https://elsewhere.example" })).status, 403);
    const got = await enroll({ token: made.token, url: NEW });
    assert.equal(got.status, 200);
    const { secret, name } = (await got.json()) as { secret: string; name: string };
    assert.equal(name, "东京");
    assert.equal((await enroll({ token: made.token, url: NEW })).status, 403, "used once");

    assert.deepEqual((await me()).relay_urls, [h.origin, BEIJING, NEW]);
    assert.equal((await me()).relay_names[NEW], "东京");
    await s.heard();
    assert.deepEqual(s.state().relay_urls, [h.origin, BEIJING, NEW], "the station sent its state again");
    assert.deepEqual(s.state().stillfail_relays, [h.origin, BEIJING, NEW]);
    assert.deepEqual(await events.take(), ["workspaces"], "every device told to read its /v1/me again");

    // Its counters come with its secret; not by its address alone any more. Beijing's, with none, by its address.
    const load = (headers: Record<string, string>) => h.fetch("/v1/relays/load", { method: "POST", headers, body: "iroh_relay_accepts_total 1\n" });
    assert.equal((await load({ authorization: `Bearer ${secret}` })).status, 200);
    assert.equal((await load({ authorization: "Bearer wrong" })).status, 403);
    assert.equal((await load({ "x-stillfail-relay": NEW, "cf-connecting-ip": "203.0.113.9" })).status, 403);
    assert.equal((await load({ "x-stillfail-relay": BEIJING, "cf-connecting-ip": "203.0.113.7" })).status, 200);
    const shown = (await (await console_("GET", "/v1/admin/relays")).json()) as any;
    assert.deepEqual(shown.relays.map((r: any) => [r.url, r.name]), [[h.origin, new URL(h.origin).host], [BEIJING, "北京"], [NEW, "东京"]]);

    // A token naming no URL: the relay says its own.
    const open = (await (await console_("POST", "/v1/admin/relays/token", { name: "首尔" })).json()) as { token: string; command: string };
    assert.match(open.command, /<https:\/\/this relay's URL>$/);
    assert.equal((await enroll({ token: open.token })).status, 400);
    assert.equal((await enroll({ token: open.token, url: "ftp://x.example" })).status, 400);
    assert.equal((await enroll({ token: open.token, url: "https://seoul.example:8445" })).status, 200);
    assert.deepEqual((await me()).relay_urls, [h.origin, BEIJING, NEW, "https://seoul.example:8445"]);
  } finally {
    await h.close();
  }
});

test("the operator puts relays and ways into them on the list and takes them off, with ADMIN_TOKEN too", async () => {
  const h = await harness();
  try {
    const tokens = { alice: await h.login("alice") };
    const alice = h.as(tokens.alice);
    const admin = (path: string, body: unknown) => h.fetch(path, { method: "POST", headers: { authorization: `Bearer ${h.adminToken}`, "content-type": "application/json" }, body: JSON.stringify(body) });
    const me = async () => (await (await alice("GET", "/v1/me")).json()) as any;
    assert.deepEqual((await me()).relay_urls, [h.origin], "none but its own with no config");

    assert.equal((await admin("/v1/admin/relays/put", { url: "http://insecure.example", name: "x" })).status, 400);
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://hk.example", name: "x".repeat(41) })).status, 400);
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://hk.example", name: "香港" })).status, 200);
    // An entry is a way into a relay of the list, never into one off it, and is no relay itself.
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://bj.example:8443", name: "北京转香港", target: "https://nowhere.example" })).status, 400);
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://hk.example", name: "香港", target: h.origin })).status, 400);
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://bj.example:8443/", name: "北京转香港", target: "https://hk.example/" })).status, 200);
    // The cloud's own relay is named, and stays first.
    assert.equal((await admin("/v1/admin/relays/put", { url: h.origin, name: "Cloudflare" })).status, 200);
    let seen = await me();
    assert.deepEqual(seen.relay_urls, [h.origin, "https://hk.example"]);
    assert.deepEqual(seen.relay_entries, ["https://bj.example:8443"]);
    assert.deepEqual(seen.relay_entry_targets, { "https://bj.example:8443": "https://hk.example" });
    assert.deepEqual(seen.relay_names, { [h.origin]: "Cloudflare", "https://hk.example": "香港", "https://bj.example:8443": "北京转香港" });

    // Named anew in place.
    assert.equal((await admin("/v1/admin/relays/put", { url: "https://hk.example", name: "香港 2" })).status, 200);
    assert.equal((await me()).relay_names["https://hk.example"], "香港 2");

    // Taken off with the ways into it.
    assert.equal((await admin("/v1/admin/relays/remove", { url: "https://gone.example" })).status, 404);
    assert.equal((await admin("/v1/admin/relays/remove", { url: "https://hk.example/" })).status, 200);
    seen = await me();
    assert.deepEqual([seen.relay_urls, seen.relay_entries], [[h.origin], []]);
    const listed = (await (await admin("/v1/admin/relays/list", {})).json()) as any;
    assert.deepEqual(listed.relays.map((r: any) => [r.url, r.added_by]), [[h.origin, "admin-token"]]);
  } finally {
    await h.close();
  }
});
