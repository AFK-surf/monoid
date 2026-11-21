// Fast regression test for `--builder harness-leaf` (`station/mb/src/reader_harness/mesh_leaf.mbt` +
// `client/core-ts/side/mb-leaf-harness.ts`): verifies real MoonBit `@mesh_scopes.workspace_scope`,
// `@cloud_lock` + `@gate.serve` member JWT admission, `GET`/`POST /admin/api/mesh/leaf`,
// `GET /admin/api/mesh/leaf/events` live updates on `updateRecords`, watched headers, and custom streams.
import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadAddon } from "../src/hosts/node-iroh.ts";
import { GrantKey } from "../../../station/test/fake-control-plane.ts";
import { startLeafHarness, writeLine } from "../side/mb-leaf-harness.ts";

class MemStream {
  private readonly inChunks: (Buffer | null)[] = [];
  private readonly inWaiters: ((v: Buffer | null) => void)[] = [];
  private readonly outChunks: (Buffer | null)[] = [];
  private readonly outWaiters: ((v: Buffer | null) => void)[] = [];
  private stoppedResolve!: (code: number | null) => void;
  private readonly stoppedPromise: Promise<number | null>;
  private finishedOut = false;

  constructor() {
    this.stoppedPromise = new Promise((r) => { this.stoppedResolve = r; });
  }

  // Client -> Server
  clientWrite(data: Buffer | Uint8Array): void {
    const buf = Buffer.from(data);
    const w = this.inWaiters.shift();
    if (w) w(buf);
    else this.inChunks.push(buf);
  }
  clientFinish(): void {
    const w = this.inWaiters.shift();
    if (w) w(null);
    else this.inChunks.push(null);
  }
  clientStop(code: number | null = 0): void {
    this.stoppedResolve(code);
  }
  async clientRead(): Promise<Buffer | null> {
    if (this.outChunks.length > 0) return this.outChunks.shift()!;
    return new Promise((r) => this.outWaiters.push(r));
  }
  async clientReadLine(): Promise<any> {
    let text = "";
    for (;;) {
      const chunk = await this.clientRead();
      if (chunk === null) throw new Error(`stream ended before line (got: ${text})`);
      text += chunk.toString("utf8");
      const at = text.indexOf("\n");
      if (at >= 0) return JSON.parse(text.slice(0, at));
    }
  }
  async clientReadAll(): Promise<{ head: any; body: string }> {
    let text = "";
    for (;;) {
      const chunk = await this.clientRead();
      if (chunk === null) break;
      text += chunk.toString("utf8");
    }
    const at = text.indexOf("\n");
    assert.ok(at >= 0, `expected response head line, got: ${text}`);
    return { head: JSON.parse(text.slice(0, at)), body: text.slice(at + 1) };
  }

  // Server side (consumed by mb-leaf-harness)
  async read(): Promise<Buffer | null> {
    if (this.inChunks.length > 0) return this.inChunks.shift()!;
    return new Promise((r) => this.inWaiters.push(r));
  }
  async write(data: Buffer | Uint8Array): Promise<void> {
    const buf = Buffer.from(data);
    const w = this.outWaiters.shift();
    if (w) w(buf);
    else this.outChunks.push(buf);
  }
  async finish(): Promise<void> {
    if (this.finishedOut) return;
    this.finishedOut = true;
    const w = this.outWaiters.shift();
    if (w) w(null);
    else this.outChunks.push(null);
  }
  async reset(code: number): Promise<void> {
    this.stoppedResolve(code);
    await this.finish();
  }
  stopped(): Promise<number | null> {
    return this.stoppedPromise;
  }
}

class MemConn {
  private readonly remote: string;
  private readonly biQueue: (MemStream | null)[] = [];
  private readonly biWaiters: ((s: MemStream | null) => void)[] = [];
  private closedFlag = false;
  private closedResolve!: (reason: string) => void;
  private readonly closedPromise: Promise<string>;

  constructor(remoteId: string) {
    this.remote = remoteId;
    this.closedPromise = new Promise((r) => { this.closedResolve = r; });
  }

  remoteId(): string { return this.remote; }
  isClosed(): boolean { return this.closedFlag; }
  closed(): Promise<string> { return this.closedPromise; }
  close(_code: number, reason: string): void {
    if (this.closedFlag) return;
    this.closedFlag = true;
    this.closedResolve(reason);
    while (this.biWaiters.length > 0) this.biWaiters.shift()!(null);
    this.biQueue.push(null);
  }
  openBi(): MemStream {
    const s = new MemStream();
    const w = this.biWaiters.shift();
    if (w) w(s);
    else this.biQueue.push(s);
    return s;
  }
  async acceptBi(): Promise<MemStream | null> {
    if (this.biQueue.length > 0) return this.biQueue.shift()!;
    if (this.closedFlag) return null;
    return new Promise((r) => this.biWaiters.push(r));
  }
}

test("harness-leaf: workspaceScope, JWT auth, GET/POST /admin/api/mesh/leaf, events push, watched headers and custom streams", async (t) => {
  const addon = loadAddon();
  assert.ok(addon, "mesh native addon is required");
  const temp = await mkdtemp(join(tmpdir(), "mb-leaf-harness-test-"));
  const harness = startLeafHarness();
  const nodes: any[] = [];
  t.after(async () => {
    await harness.close();
    await Promise.all(nodes.map((n) => n.close()));
    await rm(temp, { recursive: true, force: true });
  });

  // 1. workspaceScope parity (including app.monoid.build -> app.still.fail normalization)
  const origin = "https://leaf-test.invalid";
  const workspace = "01HLEAF0000000000000000000";
  const scope = await harness.workspaceScope(origin, workspace);
  const expectedScope = createHash("sha256").update(`mesh-workspace/v1\0${origin}\0${workspace}`).digest("hex");
  assert.equal(scope, expectedScope);
  assert.equal(
    await harness.workspaceScope("https://app.monoid.build/", workspace),
    await harness.workspaceScope("https://app.still.fail", workspace),
  );

  // 2. Bind 2 real station nodes + 1 real device node to get genuine Ed25519-signed descriptors
  const relay = "http://127.0.0.1:1/";
  const secretKeys = [randomBytes(32), randomBytes(32), randomBytes(32)];
  for (let i = 0; i < 3; i++) {
    nodes.push(await addon.bind({ secretKey: secretKeys[i], alpns: [Buffer.from("leaf-test/1")], relayUrls: [], lookup: false, discovery: false }));
  }
  const desc0 = await nodes[0].meshConfigure({ scope, transit: true, peers: [], relayUrls: [relay] });
  const desc1 = await nodes[1].meshConfigure({ scope, transit: true, peers: [], relayUrls: [relay] });
  const deviceDesc = await nodes[2].meshConfigure({ scope, transit: false, peers: [], relayUrls: [relay] });

  const grant = new GrantKey("leaf-harness-test");
  let viewCount = 0;
  let heldResolve!: () => void;
  const heldArrived = new Promise<void>((r) => { heldResolve = r; });

  let attachedReq: any = null;
  const station = await harness.createStation({
    data: join(temp, "station-0"),
    state: {
      origin,
      station: nodes[0].id(),
      workspace,
      workspace_name: "LeafTest",
      name: "station-0",
      relay_url: relay,
      relay_urls: [relay],
      grant_keys: { keys: [grant.jwk] },
      peers: [{ id: nodes[1].id(), name: "station-1" }],
      revocations: [],
    },
    stationId: nodes[0].id(),
    secretKey: secretKeys[0],
    records: {
      [scope]: [
        { descriptor: desc0, secretKey: secretKeys[0] },
        { descriptor: desc1, secretKey: secretKeys[1] },
      ],
    },
    node: {
      async meshAttachLeaf(_conn: any, req: any) {
        attachedReq = req;
        return { id: "att-1", issuer: desc0.binding };
      },
      async meshDetachLeaf() {},
    },
    onLeafView: () => { viewCount++; },
    watchHeaders: ["leaf-held"],
    onWatchedHead: (head) => { if (head.headers?.["leaf-held"] === "1") heldResolve(); },
    customStreams: {
      "/admin/api/custom/ok": async ({ stream }) => {
        await writeLine(stream, { status: 200, headers: {} });
        await stream.write(Buffer.from("custom-ok"));
        await stream.finish();
      },
    },
  });
  t.after(() => station.close());

  // 3. Invalid JWT is refused
  const badConn = new MemConn(nodes[2].id());
  const badServed = station.serveConnection(badConn).catch(() => {});
  const badControl = badConn.openBi();
  badControl.clientWrite(Buffer.from(`${JSON.stringify({ credential: "not-a-jwt", protocol: 2 })}\n`));
  const badHello = await badControl.clientReadLine();
  assert.ok(badHello.error, `expected refusal error, got ${JSON.stringify(badHello)}`);
  badConn.close(0, "done");
  await badServed;

  // 4. Valid JWT is admitted with meshLeaf: true
  const now = Math.floor(Date.now() / 1000);
  const credential = grant.credential(
    { typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "usr_leaf", email: "leaf@example.invalid", name: "Leaf", ws: workspace, role: "owner", device: nodes[2].id(), sid: "leaf", iat: now, exp: now + 3600 },
  );
  const conn = new MemConn(nodes[2].id());
  const served = station.serveConnection(conn).catch(() => {});
  const control = conn.openBi();
  control.clientWrite(Buffer.from(`${JSON.stringify({ credential, protocol: 2 })}\n`));
  const hello = await control.clientReadLine();
  assert.equal(hello.ok, true);
  assert.equal(hello.meshLeaf, true);

  // 5. GET /admin/api/mesh/leaf returns scope & both peers and bumps onLeafView
  const getStream = conn.openBi();
  getStream.clientWrite(Buffer.from(`${JSON.stringify({ method: "GET", path: "/admin/api/mesh/leaf", headers: { "stillfail-build": "0.1.0" } })}\n`));
  getStream.clientFinish();
  const getReply = await getStream.clientReadAll();
  assert.equal(getReply.head.status, 200);
  const viewBody = JSON.parse(getReply.body);
  assert.equal(viewBody.scope, scope);
  assert.equal(viewBody.peers.length, 2);
  assert.equal(viewCount, 1);

  // 6. POST /admin/api/mesh/leaf attaches real device descriptor via MoonBit Leaves::attach + Rust meshAttachLeaf
  const postStream = conn.openBi();
  postStream.clientWrite(Buffer.from(
    `${JSON.stringify({ method: "POST", path: "/admin/api/mesh/leaf", headers: { "stillfail-build": "0.1.0" } })}\n${JSON.stringify({ target: nodes[1].id(), descriptor: deviceDesc })}`,
  ));
  postStream.clientFinish();
  const postReply = await postStream.clientReadAll();
  assert.equal(postReply.head.status, 200, postReply.body);
  const attachBody = JSON.parse(postReply.body);
  assert.equal(attachBody.attachment?.id, "att-1");
  assert.equal(attachBody.config.scope, scope);
  assert.equal(attachedReq?.target, nodes[1].id());
  assert.equal(attachedReq?.scope, scope);

  // 7. GET /admin/api/mesh/leaf/events streams initial line AND pushes a new line on updateRecords
  const evStream = conn.openBi();
  evStream.clientWrite(Buffer.from(`${JSON.stringify({ method: "GET", path: "/admin/api/mesh/leaf/events", headers: { "stillfail-build": "0.1.0" } })}\n`));
  evStream.clientFinish();
  const evHead = await evStream.clientReadLine();
  assert.equal(evHead.status, 200);
  const evLine1 = await evStream.clientReadLine();
  assert.equal(evLine1.scope, scope);
  assert.equal(evLine1.peers.length, 2);
  assert.ok(evLine1.credentialExpiresUnixMs > 0);

  // Reconfigure node 1 with a modified relay list to produce a fresh descriptor and trigger updateRecords
  const desc1Next = await nodes[1].meshConfigure({ scope, transit: true, peers: [desc0], relayUrls: [relay] });
  // Ensure descriptor actually differs (e.g. attach a relay address or generation bump)
  const desc1Updated = {
    ...desc1Next,
    address: { ...desc1Next.address, addrs: [{ Relay: "http://127.0.0.1:2/" }] },
  };
  await station.updateRecords(scope, [
    { descriptor: desc0, secretKey: secretKeys[0] },
    { descriptor: desc1Updated, secretKey: secretKeys[1] },
  ]);
  const evLine2 = await evStream.clientReadLine();
  assert.equal(evLine2.scope, scope);
  assert.ok(
    evLine2.peers.some((p: any) => p.address?.addrs?.some((a: any) => a.Relay === "http://127.0.0.1:2/")),
    "expected updated peer descriptor pushed on /admin/api/mesh/leaf/events",
  );
  evStream.clientStop(0);

  // 8. Watched header fires immediately BEFORE clientFinish, while GET /admin/api/mesh/leaf waits for clientFinish
  const beforeHeld = viewCount;
  const heldStream = conn.openBi();
  heldStream.clientWrite(Buffer.from(`${JSON.stringify({ method: "GET", path: "/admin/api/mesh/leaf", headers: { "stillfail-build": "0.1.0", "leaf-held": "1" } })}\n`));
  await heldArrived;
  assert.equal(viewCount, beforeHeld, "GET /admin/api/mesh/leaf must wait for stream finish before calling leaves.view");
  heldStream.clientFinish();
  const heldReply = await heldStream.clientReadAll();
  assert.equal(heldReply.head.status, 200);
  assert.equal(viewCount, beforeHeld + 1);

  // 9. Custom stream route works
  const customStream = conn.openBi();
  customStream.clientWrite(Buffer.from(`${JSON.stringify({ method: "GET", path: "/admin/api/custom/ok", headers: { "stillfail-build": "0.1.0" } })}\n`));
  customStream.clientFinish();
  const customReply = await customStream.clientReadAll();
  assert.equal(customReply.head.status, 200);
  assert.equal(customReply.body, "custom-ok");

  conn.close(0, "done");
  await served;
});
