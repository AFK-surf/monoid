// A workspace's ways are its stations' (station/src/mesh/ways.ts); each station says the record it keeps on its presence
// socket (`ways.put`, station/src/cloud/presence.ts `waysTeller`), and the cloud keeps the newest of them for those that
// reach no station yet: an app from before the stations kept them, a browser or a device new to the workspace, which
// learn its relays from `/v1/me` alone (2026-11-16, Hypershell: 官方中继 turned off on the stations, `/v1/me` still said
// none were, the web app could reach no station).
import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";
import type { AccountEvent } from "../src/types.ts";

type Harness = Awaited<ReturnType<typeof harness>>;
type As = ReturnType<Harness["as"]>;
const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}
type Station = Awaited<ReturnType<typeof key>>;

async function enroll(h: Harness, station: Station, token: string, body: Record<string, unknown> = {}) {
  const signature = await station.sign(`stillfail-station-enroll-v1:${h.origin}:${token}:${station.id}`);
  const response = await h.fetch("/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, station: station.id, signature, version: "0.5.0", ...body }),
  });
  assert.equal(response.status, 200);
}

async function connect(h: Harness, station: Station) {
  const ts = h.now();
  const response = await h.fetch("/v1/stations/connect", {
    headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts}`) },
  });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  const frames: any[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || frames.push(JSON.parse(event.data as string))));
  ws.accept();
  return {
    frames,
    /** Says a frame, and waits for all it led to (h.heard). */
    async say(frame: unknown) {
      ws.send(JSON.stringify(frame));
      await h.heard(ws);
    },
  };
}

/** A device's events socket; `take` what arrived since the last take, of what was done before (h.heard). */
async function listen(h: Harness, token: string) {
  const response = await h.fetch("/v1/events", { headers: { upgrade: "websocket", "sec-websocket-protocol": `stillfail-events, stillfail-token.${token}` } });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  ws.accept();
  const got: AccountEvent[] = [];
  ws.addEventListener("message", (event) => void (event.data === "pong" || got.push(JSON.parse(event.data as string))));
  return {
    async take(): Promise<string[]> {
      await h.heard(ws);
      return got.splice(0).map((e) => `${e.type} ${(e as { id?: string }).id ?? ""}`.trim()).sort();
    },
  };
}

const mine = async (who: As, ws: string) => ((await (await who("GET", "/v1/me")).json()) as any).workspaces.find((w: any) => w.id === ws);

test("a station's ways said on its presence socket: kept for `/v1/me`, told once, the newest kept, only of a whole station of the workspace, never every relay off", async () => {
  const h = await harness();
  try {
    const tokens = { alice: await h.login("alice"), bob: await h.login("bob") };
    const alice = h.as(tokens.alice), bob = h.as(tokens.bob);
    const w = ((await (await alice("POST", "/v1/workspaces", { name: "Hypershell" })).json()) as any).id as string;
    const other = ((await (await alice("POST", "/v1/workspaces", { name: "Lab" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${w}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    const token = async (ws: string, rig = false) => ((await (await (rig ? bob : alice)("POST", `/v1/workspaces/${ws}/${rig ? "rigs/" : ""}enrollments`, { name: "s" })).json()) as any).token as string;
    const a = await key(), b = await key(), stranger = await key(), rig = await key();
    await enroll(h, a, await token(w));
    await enroll(h, b, await token(w));
    await enroll(h, stranger, await token(other));
    await enroll(h, rig, await token(w, true), { rig: true });
    const sa = await connect(h, a), sb = await connect(h, b), ss = await connect(h, stranger), sr = await connect(h, rig);
    await sa.say("ping");
    const ours = sa.frames[0].relay_urls as string[];
    const on = { alice: await listen(h, tokens.alice.access_token), bob: await listen(h, tokens.bob.access_token) };
    const put = (record: { relays: unknown[]; off: unknown[]; at: number; station: string }) => ({ type: "ways.put", workspace: w, ...record });

    // A's own relay, still.fail's off (#6692: its stations leave them): every member told, `/v1/me` says it.
    await sa.say(put({ relays: ["https://own.example/", "https://own.example", ours[0], "ftp://no.example"], off: ["ours", "lan", "bogus", "https://nowhere.example"], at: 1_000, station: a.id }));
    assert.deepEqual(await on.alice.take(), ["workspace " + w, "workspaces"]);
    assert.deepEqual(await on.bob.take(), ["workspace " + w, "workspaces"]);
    let seen = await mine(bob, w);
    assert.deepEqual([seen.relays, seen.ways_off], [["https://own.example"], ["ours", "lan"]], "cleaned as setRelays and setWay clean");
    assert.deepEqual(sb.frames.filter((f) => f.type === "state").at(-1).ways, { relays: ["https://own.example"], off: ["ours", "lan"] }, "told the other stations as before");

    // The same again (each station says it as its socket opens): nothing told.
    await sa.say(put({ relays: ["https://own.example"], off: ["ours", "lan"], at: 1_000, station: a.id }));
    await sb.say(put({ relays: ["https://own.example"], off: ["ours", "lan"], at: 1_000, station: a.id }));
    assert.deepEqual(await on.alice.take(), [], "the same said again tells nothing");
    assert.deepEqual(await on.bob.take(), []);
    // A newer record of the same ways (another station brought level and changed back): kept, told nothing.
    await sb.say(put({ relays: ["https://own.example"], off: ["ours", "lan"], at: 2_000, station: b.id }));
    assert.deepEqual(await on.bob.take(), []);

    // An older record (a station back from a long sleep), or one of the same time by a smaller station id: not taken.
    const [low, high] = [a.id, b.id].sort();
    await sa.say(put({ relays: [], off: [], at: 1_500, station: a.id }));
    await sa.say(put({ relays: [], off: [], at: 2_000, station: high === b.id ? low! : "0" }));
    assert.deepEqual(await on.bob.take(), [], "an older record changes nothing");
    seen = await mine(bob, w);
    assert.deepEqual([seen.relays, seen.ways_off], [["https://own.example"], ["ours", "lan"]]);

    // Of a station not in the workspace, or of a rig (which keeps no ways of the workspace's): not taken.
    await ss.say(put({ relays: [], off: [], at: 9_000, station: stranger.id }));
    await sr.say(put({ relays: [], off: [], at: 9_000, station: rig.id }));
    await ss.say({ type: "ways.put", relays: [], off: [], at: 9_000, station: stranger.id });
    assert.deepEqual(await on.bob.take(), []);
    seen = await mine(bob, w);
    assert.deepEqual([seen.relays, seen.ways_off], [["https://own.example"], ["ours", "lan"]]);
    assert.equal((await mine(alice, other)).ways_off, undefined, "the stranger's own workspace has nothing of it");

    // Malformed: not taken.
    for (const bad of [{ at: -1 }, { at: 1.5 }, { at: "9" }, { station: 7 }, { relays: "https://x.example" }, { off: "ours" }]) {
      await sa.say({ ...put({ relays: [], off: [], at: 9_000, station: a.id }), ...bad });
    }
    assert.deepEqual(await on.bob.take(), [], "nothing malformed taken");

    // One that would leave no relay on (its own taken away, still.fail's still off): still.fail's back on.
    await sa.say(put({ relays: [], off: ["ours", "tailnet", ...ours], at: 10_000, station: a.id }));
    seen = await mine(bob, w);
    assert.deepEqual([seen.relays, seen.ways_off], [[], ["tailnet"]], "never every relay off");
    assert.deepEqual(await on.bob.take(), ["workspace " + w, "workspaces"]);

    // An app from before the stations kept them changes them here: a station's record older than that does not undo it.
    assert.equal((await alice("PUT", `/v1/workspaces/${w}/relays`, { relays: ["https://by-hand.example"] })).status, 200);
    await sa.say(put({ relays: ["https://own.example"], off: ["ours"], at: 11_000, station: a.id }));
    seen = await mine(bob, w);
    assert.deepEqual(seen.relays, ["https://by-hand.example"], "older than the change by hand");
    await sa.say(put({ relays: ["https://own.example"], off: ["ours"], at: h.now() * 1000 + 60_000, station: a.id }));
    seen = await mine(bob, w);
    assert.deepEqual([seen.relays, seen.ways_off], [["https://own.example"], ["ours"]], "a station's change after it is taken");
  } finally {
    await h.close();
  }
});
