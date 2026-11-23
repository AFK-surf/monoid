// A rig (a station that only runs tasks): a machine a member adds as their own, which only runs what the workspace's stations send it. The
// cloud lists it apart from the stations, with its person; a station's state names the rigs in a field of their own
// (one from before them takes no rig for a station), a rig's the stations and whose it is.
import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";

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

const view = async (who: As, workspace: string) => (await (await who("GET", `/v1/workspaces/${workspace}`)).json()) as any;

async function enroll(h: Harness, station: Station, token: string, body: Record<string, unknown> = {}, join = false): Promise<{ status: number; body: any }> {
  const signature = await station.sign(`stillfail-station-enroll-v1:${h.origin}:${token}:${station.id}`);
  const response = await h.fetch(join ? "/v1/stations/join" : "/v1/stations/enroll", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token, station: station.id, signature, version: "0.5.0", ...body }),
  });
  return { status: response.status, body: await response.json() };
}

async function connect(h: Harness, station: Station) {
  const ts = h.now();
  const response = await h.fetch("/v1/stations/connect", {
    headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts}`) },
  });
  assert.equal(response.status, 101);
  const ws = response.webSocket!;
  const frames: any[] = [];
  const closed = new Promise<number>((resolve) => ws.addEventListener("close", (event) => resolve(event.code), { once: true }));
  ws.addEventListener("message", (event) => void (event.data === "pong" || frames.push(JSON.parse(event.data as string))));
  ws.accept();
  /** The last state it was told since the last time, everything sent for what was done before arrived (h.heard). */
  const state = async () => {
    await h.heard(ws);
    return frames.splice(0).filter((f) => f.type === "state").at(-1);
  };
  return { closed, state };
}

test("a member adds a rig of their own: listed apart from the stations, told to them in a field of its own, gone with its person", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    const subOf = async (email: string) => (await view(alice, home)).members.find((m: any) => m.email === email).sub as string;
    const bobSub = await subOf("bob@example.test");

    const station = await key(), rig = await key();
    const stationToken = ((await (await alice("POST", `/v1/workspaces/${home}/enrollments`, { name: "willow" })).json()) as any).token as string;
    assert.equal((await enroll(h, station, stationToken)).status, 200);

    // A member adds one (a station is its managers' to add); one outside the workspace adds none.
    assert.equal((await bob("POST", `/v1/workspaces/${home}/enrollments`, { name: "x" })).status, 403);
    assert.equal((await h.as(await h.login("carol"))("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "x" })).status, 404);
    const made = (await (await bob("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "build-box" })).json()) as any;
    assert.equal(made.rig, true);
    assert.match(made.install, /install\.sh \| sh -s -- /);

    // Its token makes a rig and nothing else; a station's token makes none.
    assert.deepEqual(await enroll(h, rig, made.token), { status: 409, body: { error: "rig_enrollment" } }, "a station's program from before rigs does not serve under a rig's name");
    const other = ((await (await alice("POST", `/v1/workspaces/${home}/enrollments`, { name: "nas" })).json()) as any).token as string;
    assert.deepEqual(await enroll(h, rig, other, { rig: true }), { status: 409, body: { error: "station_enrollment" } });
    const joined = await enroll(h, rig, made.token, { rig: true });
    assert.equal(joined.status, 200);
    assert.deepEqual(joined.body.rig, { owner: bobSub, owner_email: "bob@example.test", owner_name: "Name of bob" });

    // Listed apart, with its person; the stations' count is the stations'.
    const seen = await view(alice, home);
    assert.deepEqual(seen.stations.map((s: any) => s.id), [station.id]);
    assert.deepEqual(seen.rigs.map((r: any) => [r.id, r.name, r.owner, r.owner_email, r.version]), [[rig.id, "build-box", bobSub, "bob@example.test", "0.5.0"]]);
    assert.equal((((await (await alice("GET", "/v1/me")).json()) as any).workspaces as any[]).find((w) => w.id === home).stations, 1);

    // A station is told the rigs beside its peers; a rig the stations, and whose it is.
    const s = await connect(h, station);
    const told = await s.state();
    assert.deepEqual(told.peers.map((p: any) => p.id), [station.id]);
    assert.deepEqual(told.rigs, [{ id: rig.id, name: "build-box", owner: bobSub, owner_email: "bob@example.test", owner_name: "Name of bob", version: "0.5.0" }]);
    const r = await connect(h, rig);
    const mine = await r.state();
    assert.deepEqual(mine.peers.map((p: any) => p.id), [station.id]);
    assert.deepEqual(mine.rig, { owner: bobSub });
    assert.equal(mine.rigs, undefined);

    // Its person renames it; another member neither renames nor removes it.
    const dave = h.as(await h.login("dave"));
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["dave@example.test"] })).status, 200);
    assert.equal((await dave("PATCH", `/v1/workspaces/${home}/stations/${rig.id}`, { name: "mine" })).status, 403);
    assert.equal((await dave("DELETE", `/v1/workspaces/${home}/stations/${rig.id}`)).status, 403);
    assert.equal((await bob("PATCH", `/v1/workspaces/${home}/stations/${rig.id}`, { name: "gpu-box" })).status, 200);
    assert.equal((await s.state()).rigs[0].name, "gpu-box");

    // Its person out of the workspace, it leaves with them.
    assert.equal((await alice("DELETE", `/v1/workspaces/${home}/members/${bobSub}`)).status, 200);
    assert.equal(await r.closed, 4004);
    assert.equal((await view(alice, home)).rigs, undefined);
    assert.equal((await s.state()).rigs, undefined, "nothing said with none, as before there were any");
  } finally {
    await h.close();
  }
});

for (const leaving of ["removed", "leave", "delete account"] as const) test(`a departed rig owner's unused tokens stay revoked after ${leaving}, even if they join again`, async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    let bob = h.as(await h.login("bob"));
    const bobSub = ((await (await bob("GET", "/v1/me")).json()) as any).user.sub as string;
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    const other = ((await (await alice("POST", "/v1/workspaces", { name: "Other" })).json()) as any).id as string;
    const add = (workspace: string) => alice("POST", `/v1/workspaces/${workspace}/members`, { emails: ["bob@example.test"] });
    for (const workspace of [home, other]) assert.equal((await add(workspace)).status, 200);
    const pending = async (who: As, workspace: string) => {
      const made = await who("POST", `/v1/workspaces/${workspace}/rigs/enrollments`, { name: "build-box" });
      assert.equal(made.status, 200);
      return ((await made.json()) as any).token as string;
    };
    const before = await pending(bob, home), afterRejoin = await pending(bob, home);
    const elsewhere = await pending(bob, other), alices = await pending(alice, home);
    const left = leaving === "delete account" ? await bob("DELETE", "/v1/me") : await (leaving === "leave" ? bob : alice)("DELETE", `/v1/workspaces/${home}/members/${bobSub}`);
    assert.equal(left.status, 200);
    assert.deepEqual(await enroll(h, await key(), before, { rig: true }), { status: 404, body: { error: "enrollment_not_found" } });
    assert.equal((await view(alice, home)).rigs, undefined);
    const otherResult = await enroll(h, await key(), elsewhere, { rig: true });
    assert.equal(otherResult.status, leaving === "delete account" ? 404 : 200, "leaving one workspace does not revoke another's token; deleting the account leaves both");
    assert.equal((await enroll(h, await key(), alices, { rig: true })).status, 200, "another member's pending rig stays theirs");

    if (leaving === "delete account") bob = h.as(await h.login("bob"));
    assert.equal((await add(home)).status, 200);
    assert.deepEqual(await enroll(h, await key(), afterRejoin, { rig: true }), { status: 404, body: { error: "enrollment_not_found" } }, "joining again never brings back a token from before leaving");
    assert.equal((await enroll(h, await key(), await pending(bob, home), { rig: true })).status, 200, "a new member's new token works");
  } finally {
    await h.close();
  }
});

test("an unused rig token left by an older Directory cannot enroll for someone no longer a member", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice")), bob = h.as(await h.login("bob"));
    const bobSub = ((await (await bob("GET", "/v1/me")).json()) as any).user.sub as string;
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { emails: ["bob@example.test"] })).status, 200);
    const token = ((await (await bob("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "old-box" })).json()) as any).token as string;
    await (await h.object("DIRECTORY", "primary")).leaveWithRigTokenFromBefore(home, bobSub);
    assert.deepEqual(await enroll(h, await key(), token, { rig: true }), { status: 404, body: { error: "enrollment_not_found" } });
    assert.equal((await view(alice, home)).rigs, undefined);
  } finally {
    await h.close();
  }
});

test("a whole station its adder or any owner or admin makes one that only runs tasks, theirs then; whole again only its owner's", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const carol = h.as(await h.login("carol"));
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "admin", emails: ["carol@example.test"] })).status, 200);
    const subOf = async (email: string) => (await view(alice, home)).members.find((m: any) => m.email === email).sub as string;
    const aliceSub = await subOf("alice@example.test"), carolSub = await subOf("carol@example.test"), bobSub = await subOf("bob@example.test");
    // Alice (the workspace's owner) adds the first, Carol (an admin) the second.
    const first = await key(), second = await key();
    for (const [who, station, name] of [[alice, first, "willow"], [carol, second, "nas"]] as const) {
      const token = ((await (await who("POST", `/v1/workspaces/${home}/enrollments`, { name })).json()) as any).token as string;
      assert.equal((await enroll(h, station, token)).status, 200);
    }
    const a = await connect(h, first), b = await connect(h, second);
    await a.state();
    await b.state();
    const mode = (who: As, station: Station, to: string) => who("PATCH", `/v1/workspaces/${home}/stations/${station.id}`, { mode: to });

    // A plain member may not make one another added a rig; the workspace's owner may, and it is theirs then.
    assert.equal((await mode(bob, second, "tasks")).status, 403);
    assert.equal((await mode(carol, second, "sideways")).status, 400);
    assert.equal((await mode(alice, second, "tasks")).status, 200);
    const seen = await view(alice, home);
    assert.deepEqual(seen.stations.map((s: any) => s.id), [first.id]);
    assert.deepEqual(seen.rigs.map((r: any) => [r.id, r.name, r.owner]), [[second.id, "nas", aliceSub]]);
    // Both are told at once: the others that it is a rig now, itself whose.
    assert.deepEqual((await a.state()).rigs.map((r: any) => r.id), [second.id]);
    const told = await b.state();
    assert.deepEqual(told.rig, { owner: aliceSub });
    assert.deepEqual(told.peers.map((p: any) => p.id), [first.id]);
    // Said again, by its adder even, nothing changes: a rig is never taken over. The workspace keeps one whole station.
    assert.equal((await mode(carol, second, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[second.id, aliceSub]]);
    assert.deepEqual(await (await mode(alice, first, "tasks")).json(), { error: "last_station" });

    // Whole again: its owner's, not another manager's (nor its adder's); among the stations, told as one.
    assert.equal((await mode(carol, second, "full")).status, 403);
    assert.equal((await mode(bob, second, "full")).status, 403);
    assert.equal((await mode(alice, second, "full")).status, 200);
    assert.deepEqual((await view(alice, home)).stations.map((s: any) => s.id), [first.id, second.id]);
    assert.equal((await view(alice, home)).rigs, undefined);
    assert.equal((await b.state()).rig, undefined);
    assert.equal((await a.state()).rigs, undefined);

    // An admin makes the one the owner added a rig, theirs then, and makes it whole again.
    assert.equal((await mode(carol, first, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[first.id, carolSub]]);
    assert.deepEqual((await a.state()).rig, { owner: carolSub });
    assert.equal((await mode(alice, first, "full")).status, 403);
    assert.equal((await mode(carol, first, "full")).status, 200);
    assert.equal((await view(alice, home)).rigs, undefined);
    assert.equal((await a.state()).rig, undefined);

    // One a plain member added stays one that only runs tasks: they add no whole station, and a manager may not make it one.
    const box = await key();
    const made = (await (await bob("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "build-box" })).json()) as any;
    assert.equal((await enroll(h, box, made.token, { rig: true })).status, 200);
    assert.equal((await mode(bob, box, "full")).status, 403);
    assert.equal((await mode(alice, box, "full")).status, 403);
    // Nor take it over by asking it to run tasks.
    assert.equal((await mode(alice, box, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[box.id, bobSub]]);

    // A station in a second workspace may switch to tasks-only in one workspace while staying whole in the other (mixed mode).
    const other = ((await (await carol("POST", "/v1/workspaces", { name: "Other" })).json()) as any).id as string;
    const join = ((await (await carol("POST", `/v1/workspaces/${other}/enrollments`, { name: "nas" })).json()) as any).token as string;
    assert.equal((await enroll(h, second, join, {}, true)).status, 200);
    assert.equal((await mode(carol, second, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[second.id, carolSub], [box.id, bobSub]]);
    assert.deepEqual((await view(carol, other)).stations.map((s: any) => s.id), [second.id]);
    assert.equal((await view(carol, other)).rigs, undefined);
    // Home re-ordered to the full workspace (`other`), with `home` demoted to `workspaces` as a rig.
    const mixedFrame = await b.state();
    assert.equal(mixedFrame.workspace, other);
    assert.equal(mixedFrame.rig, undefined);
    const demotedHome = mixedFrame.workspaces?.find((w: any) => w.workspace === home);
    assert.deepEqual(demotedHome?.rig, { owner: carolSub });
    // `joined` flag in `other` is omitted because the station's only other membership (`home`) is tasks-only.
    assert.equal((await view(carol, other)).stations.find((s: any) => s.id === second.id).joined, undefined);
  } finally {
    await h.close();
  }
});

test("pure rig in 2 workspaces and pure rig promoted to mixed mode when joining a full workspace", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const wsA = ((await (await alice("POST", "/v1/workspaces", { name: "WS-A" })).json()) as any).id as string;
    const wsB = ((await (await alice("POST", "/v1/workspaces", { name: "WS-B" })).json()) as any).id as string;
    const wsC = ((await (await alice("POST", "/v1/workspaces", { name: "WS-C" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${wsA}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    assert.equal((await alice("POST", `/v1/workspaces/${wsB}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    const bobSub = (await view(alice, wsA)).members.find((m: any) => m.email === "bob@example.test").sub as string;

    const rig = await key();
    const tokA = ((await (await bob("POST", `/v1/workspaces/${wsA}/rigs/enrollments`, { name: "gpu-a" })).json()) as any).token as string;
    assert.equal((await enroll(h, rig, tokA, { rig: true })).status, 200);

    // Join WS-B as rig too.
    const tokB = ((await (await bob("POST", `/v1/workspaces/${wsB}/rigs/enrollments`, { name: "gpu-b" })).json()) as any).token as string;
    const joinB = await enroll(h, rig, tokB, { rig: true }, true);
    assert.equal(joinB.status, 200);
    assert.equal(joinB.body.home, wsA);
    assert.deepEqual((await view(alice, wsA)).rigs.map((r: any) => r.id), [rig.id]);
    assert.deepEqual((await view(alice, wsB)).rigs.map((r: any) => r.id), [rig.id]);

    const r = await connect(h, rig);
    const f1 = await r.state();
    assert.equal(f1.workspace, wsA);
    assert.deepEqual(f1.rig, { owner: bobSub });
    assert.equal(f1.workspaces?.length, 1);
    assert.equal(f1.workspaces[0].workspace, wsB);
    assert.deepEqual(f1.workspaces[0].rig, { owner: bobSub });

    // Join WS-C as a full station -> WS-C becomes home (full before rig), WS-A and WS-B are in `workspaces` as rigs.
    const tokC = ((await (await alice("POST", `/v1/workspaces/${wsC}/enrollments`, { name: "host-c" })).json()) as any).token as string;
    const joinC = await enroll(h, rig, tokC, {}, true);
    assert.equal(joinC.status, 200);
    assert.equal(joinC.body.home, wsC);
    const f2 = await r.state();
    assert.equal(f2.workspace, wsC);
    assert.equal(f2.rig, undefined);
    assert.deepEqual(f2.workspaces.map((w: any) => [w.workspace, w.rig?.owner]), [[wsA, bobSub], [wsB, bobSub]]);

    // Removing bob from WS-A removes the rig from WS-A alone; WS-B and WS-C stay intact.
    assert.equal((await alice("DELETE", `/v1/workspaces/${wsA}/members/${bobSub}`)).status, 200);
    assert.equal((await view(alice, wsA)).rigs, undefined);
    assert.deepEqual((await view(alice, wsB)).rigs.map((r: any) => r.id), [rig.id]);
    assert.deepEqual((await view(alice, wsC)).stations.map((s: any) => s.id), [rig.id]);
    const f3 = await r.state();
    assert.equal(f3.workspace, wsC);
    assert.deepEqual(f3.workspaces.map((w: any) => w.workspace), [wsB]);
  } finally {
    await h.close();
  }
});

test("a station whose adder is no member any more: an owner or admin makes it one that only runs tasks, and it is theirs; a member does not", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const carol = h.as(await h.login("carol"));
    const dave = h.as(await h.login("dave"));
    const erin = h.as(await h.login("erin"));
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "admin", emails: ["carol@example.test", "dave@example.test"] })).status, 200);
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["erin@example.test"] })).status, 200);
    const subOf = async (email: string) => (await view(alice, home)).members.find((m: any) => m.email === email).sub as string;
    const aliceSub = await subOf("alice@example.test"), carolSub = await subOf("carol@example.test"), daveSub = await subOf("dave@example.test");
    const first = await key(), second = await key();
    for (const [who, station, name] of [[alice, first, "willow"], [carol, second, "nas"]] as const) {
      const token = ((await (await who("POST", `/v1/workspaces/${home}/enrollments`, { name })).json()) as any).token as string;
      assert.equal((await enroll(h, station, token)).status, 200);
    }
    const mode = (who: As, station: Station, to: string) => who("PATCH", `/v1/workspaces/${home}/stations/${station.id}`, { mode: to });

    // Its adder gone, the station stays; a plain member still may not make it a rig, an owner or admin may.
    assert.equal((await alice("DELETE", `/v1/workspaces/${home}/members/${carolSub}`)).status, 200);
    assert.deepEqual((await view(alice, home)).stations.map((s: any) => s.id), [first.id, second.id]);
    assert.equal((await mode(erin, second, "tasks")).status, 403);
    assert.equal((await mode(dave, second, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[second.id, daveSub]]);
    // Theirs now: whole again is theirs too, not the owner's.
    assert.equal((await mode(alice, second, "full")).status, 403);
    assert.equal((await mode(dave, second, "full")).status, 200);
    // The owner may as well, and it is theirs then.
    assert.equal((await mode(alice, second, "tasks")).status, 200);
    assert.deepEqual((await view(alice, home)).rigs.map((r: any) => [r.id, r.owner]), [[second.id, aliceSub]]);
    assert.equal((await mode(dave, second, "full")).status, 403);
    assert.equal((await mode(alice, second, "full")).status, 200);
  } finally {
    await h.close();
  }
});

test("a rig's person removes it themselves", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const home = ((await (await alice("POST", "/v1/workspaces", { name: "Home" })).json()) as any).id as string;
    assert.equal((await alice("POST", `/v1/workspaces/${home}/members`, { role: "member", emails: ["bob@example.test"] })).status, 200);
    const rig = await key();
    const made = (await (await bob("POST", `/v1/workspaces/${home}/rigs/enrollments`, { name: "build-box" })).json()) as any;
    assert.equal((await enroll(h, rig, made.token, { rig: true })).status, 200);
    const r = await connect(h, rig);
    assert.equal((await bob("DELETE", `/v1/workspaces/${home}/stations/${rig.id}`)).status, 200);
    assert.equal(await r.closed, 4004);
  } finally {
    await h.close();
  }
});

test("the installers pass a rig's command on: `rig:<person>` after the token (and a lock's hash), as `--rig <person>`", async () => {
  const { installScript } = await import("../src/install.ts");
  const { windowsInstallScript } = await import("../src/install-windows.ts");
  const sh = installScript("https://ember.test");
  assert.match(sh, /case "\$lock" in rig:\*\) rig="\$lock" lock="" ;; esac/);
  assert.match(sh, /station enroll "\$origin" "\$token" --stay \$\{lock:\+--lock "\$lock"\} \$\{rig:\+--rig "\$\{rig#rig:\}"\}/);
  const ps = windowsInstallScript("https://ember.test");
  assert.match(ps, /if \(\$Lock -like 'rig:\*'\) \{ \$Rig = \$Lock; \$Lock = '' \}/);
  assert.match(ps, /if \(\$Rig\) \{ \$pin \+= @\('--rig', \$Rig\.Substring\(4\)\) \}/);
});
