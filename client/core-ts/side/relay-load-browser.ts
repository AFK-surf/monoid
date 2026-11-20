// Real browser sockets, production Mesh/LeafLinks, and local native stations.
// Run each five-minute scenario separately. See RELAY_LOAD_* options below.
// Install the root lockfile's browser with `pnpm exec playwright-core install chromium-headless-shell`.
// Use PLAYWRIGHT_BROWSERS_PATH for a task-local cache. Set CHROME_BIN to the installed headless shell.
import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { randomBytes, createHash } from "node:crypto";
import { createServer } from "node:http";
import { createServer as tcpServer, connect as tcpConnect, type Socket } from "node:net";
import { mkdtemp, readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { build } from "esbuild";
import { loadAddon } from "../src/hosts/node-iroh.ts";
import { HOT_RELAYS } from "../src/mesh.ts";
import { Cloud, writeState } from "../../../station/src/cloud/state.ts";
import { GrantKey } from "../../../station/test/fake-control-plane.ts";
import { serve } from "../../../station/src/mesh/serve.ts";
import { writeLine } from "../../../station/src/mesh/wire.ts";
import { LeafAttachments } from "../../../station/src/mesh/leaf.ts";
import { workspaceScope } from "../../../station/src/mesh/enrollment-door.ts";
import { RelayCapture } from "./relay-load-cdp.ts";
import { dualRelayFailure } from "./relay-load-failure.ts";
import { relayControls } from "./relay-load-controls.ts";

const root = resolve(import.meta.dirname, "../../..");
const { chromium } = createRequire(new URL("../../../package.json", import.meta.url))("playwright-core");
const pause = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms));
function integer(key: string, fallback: number, min = 1, max = 32): number {
  const value = Number(process.env[key] ?? fallback);
  assert.ok(Number.isInteger(value) && value >= min && value <= max, key);
  return value;
}
const hotFlag = process.env.RELAY_LOAD_HOT ?? (process.env.RELAY_LOAD_CONTROLS === "1" ? "0" : "1");
assert.ok(hotFlag === "0" || hotFlag === "1", "RELAY_LOAD_HOT must be 0 or 1");
const hotRelays = { enabled: hotFlag === "1", budget: hotFlag === "1" ? HOT_RELAYS : 0 };
const options = {
  relays: integer("RELAY_LOAD_R", 6), entries: integer("RELAY_LOAD_E", 2, 0), stations: integer("RELAY_LOAD_S", 2),
  workspaces: integer("RELAY_LOAD_W", 1), durationMs: integer("RELAY_LOAD_MS", 300_000, 1000, 900_000),
  streamMs: integer("RELAY_LOAD_STREAM_MS", 0, 0, 60_000),
  visibility: process.env.RELAY_LOAD_VISIBILITY ?? "visible",
  hotRelays,
};
assert.ok(options.entries <= options.relays, "one alternate entrance on each of the first E relays");
assert.ok(["visible", "hidden"].includes(options.visibility));
const failure = process.env.RELAY_LOAD_CUT ?? "single";
assert.ok(["single", "dual"].includes(failure), "RELAY_LOAD_CUT is single or dual");
const continuity = process.env.RELAY_LOAD_REQUIRE_CONTINUITY ?? "0";
assert.ok(["0", "1"].includes(continuity), "RELAY_LOAD_REQUIRE_CONTINUITY is 0 or 1");
const output = resolve(process.env.RELAY_LOAD_OUT ?? `data/relay-load-w${options.workspaces}-${options.visibility}`);
const pkg = process.env.MESH_WASM_PKG || join(root, "web/src/core/iroh-pkg");
const origin = "https://relay-load.invalid";
const alpn = Buffer.from("relay-load-side/1");
async function until<T>(read: () => Promise<T | false> | T | false, what: string, deadlineMs = 15_000): Promise<T> {
  const until = performance.now() + deadlineMs;
  for (;;) { const value = await read(); if (value !== false) return value; assert.ok(performance.now() < until, what); await pause(25); }
}
async function port(): Promise<number> {
  const server = tcpServer();
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  const value = (server.address() as { port: number }).port;
  await new Promise<void>(resolve => server.close(() => resolve()));
  return value;
}

test("relay load in a real core worker", { timeout: options.durationMs + 180_000 }, async t => {
  await mkdir(output, { recursive: true });
  const scriptHashes = Object.fromEntries(await Promise.all(["relay-load-browser.ts", "relay-load-worker.ts", "relay-load-cdp.ts", "relay-load-controls.ts", "relay-load-failure.ts"].map(async name => [name, createHash("sha256").update(await readFile(join(import.meta.dirname, name))).digest("hex")])));
  const cleanups: (() => unknown | Promise<unknown>)[] = [];
  t.after(async () => { for (const cleanup of cleanups.reverse()) await cleanup(); });
  const temp = await mkdtemp(join(tmpdir(), "relay-load-"));
  cleanups.push(() => rm(temp, { recursive: true, force: true }));
  const addon = loadAddon(); assert.ok(addon, "mesh addon is required");
  assert.ok(process.env.STILLFAIL_RELAY_BIN, "iroh-relay binary is required");
  const relays: { url: string; entry?: string; stop(): void }[] = [];
  for (let i = 0; i < options.relays; i++) {
    const number = await port();
    const url = `http://127.0.0.1:${number}/`;
    const config = join(temp, `relay-${i}.toml`);
    await writeFile(config, `enable_relay = true\nhttp_bind_addr = "127.0.0.1:${number}"\nenable_metrics = false\nenable_quic_addr_discovery = false\n`);
    const child = spawn(process.env.STILLFAIL_RELAY_BIN, ["--dev", "--config-path", config], { stdio: ["ignore", "pipe", "pipe"] });
    const relayLog: string[] = [];
    child.stdout.on("data", data => relayLog.push(String(data)));
    child.stderr.on("data", data => relayLog.push(String(data)));
    cleanups.push(async () => {
      child.kill("SIGTERM");
      await writeFile(join(output, `relay-${i}.log`), relayLog.join(""));
    });
    await until(() => fetch(url).then(() => true, () => false), `relay ${i} starts`);
    const sockets = new Set<Socket>();
    let entry: string | undefined;
    let closeEntry = () => {};
    if (i < options.entries) {
      const proxy = tcpServer(down => {
        const up = tcpConnect(number, "127.0.0.1");
        sockets.add(down); sockets.add(up);
        down.pipe(up); up.pipe(down);
        for (const [a, b] of [[down, up], [up, down]]) {
          a.on("error", () => b.destroy());
          a.on("close", () => { sockets.delete(a); b.destroy(); });
        }
      });
      await new Promise<void>(resolve => proxy.listen(0, "127.0.0.1", resolve));
      entry = `http://127.0.0.1:${(proxy.address() as { port: number }).port}/`;
      closeEntry = () => { for (const socket of sockets) socket.destroy(); if (proxy.listening) proxy.close(); };
      cleanups.push(closeEntry);
    }
    relays.push({ url, entry, stop: () => { closeEntry(); child.kill("SIGKILL"); } });
  }
  const urls = relays.map(r => r.url);
  const entries = relays.flatMap(r => r.entry ? [r.entry] : []);
  const targets = Object.fromEntries(relays.flatMap(r => r.entry ? [[r.entry, r.url]] : []));
  const workspaces = Array.from({ length: options.workspaces }, (_, i) => `relay-load-${i}`);
  const nodes: any[] = [];
  cleanups.push(async () => { await Promise.all(nodes.map(node => node.close())); });
  for (let i = 0; i < options.stations; i++) nodes.push(await addon.bind({ secretKey: randomBytes(32), alpns: [alpn], relayUrls: urls, discovery: false, lookup: false }));
  await until(() => nodes.every(n => n.relayStatus().filter((r: any) => r.connected).length === options.relays), "stations home on every relay");
  const descriptors = new Map<string, any[]>();
  const descriptorChanges: { at: number; scope: string; station: string; descriptor: any }[] = [];
  const directoryListeners = new Set<(scope: string) => void>();
  const configuredPeers = new Map<string, string>();
  const directoryErrors: string[] = [];
  let directoryWork = Promise.resolve();
  let directoryClosed = false;
  // ScopeDirectory publishes native descriptors unchanged and follows meshSubscribe.
  // LeafAttachments sends these addresses beside the independent relay allowlist.
  const publish = (index: number, scope: string, descriptor: any) => {
    if (directoryClosed) return;
    const peers = descriptors.get(scope);
    if (!peers || JSON.stringify(peers[index]) === JSON.stringify(descriptor)) return;
    peers[index] = descriptor;
    descriptorChanges.push({ at: performance.now(), scope, station: nodes[index].id(), descriptor });
    for (const listener of directoryListeners) listener(scope);
    if (peers.filter(Boolean).length !== nodes.length) return;
    directoryWork = directoryWork.then(async () => {
      if (directoryClosed) return;
      for (let i = 0; i < nodes.length; i++) {
        const others = descriptors.get(scope)!.filter((_, j) => i !== j);
        const key = `${scope}:${i}`, word = JSON.stringify(others);
        if (configuredPeers.get(key) === word) continue;
        const own = await nodes[i].meshConfigure({ scope, transit: true, relayUrls: urls, peers: others });
        configuredPeers.set(key, word);
        publish(i, scope, own);
      }
    }).catch(error => { directoryErrors.push(String(error)); });
  };
  for (const workspace of workspaces) descriptors.set(workspaceScope(origin, workspace), []);
  for (let i = 0; i < nodes.length; i++) {
    assert.equal(typeof nodes[i].meshSubscribe, "function", "native scope address updates are required");
    await nodes[i].meshSubscribe(1, (error: Error | null, scopes: any[]) => {
      if (error) { directoryErrors.push(String(error)); return; }
      for (const { scope, descriptor } of scopes) publish(i, scope, descriptor);
    });
  }
  cleanups.push(async () => {
    directoryClosed = true;
    for (const node of nodes) node.meshUnsubscribe(1);
    await directoryWork;
  });
  for (const workspace of workspaces) {
    const scope = workspaceScope(origin, workspace);
    await Promise.all(nodes.map(async (node, i) => publish(i, scope,
      await node.meshConfigure({ scope, transit: true, peers: [], relayUrls: urls }))));
  }
  await until(() => [...descriptors.values()].every(peers => peers.filter(Boolean).length === nodes.length
    && peers.every(peer => peer.address.addrs.some((addr: any) => addr.Relay))), "native scope home addresses");
  await directoryWork;
  assert.deepEqual(directoryErrors, []);
  const grant = new GrantKey("relay-load");
  const eventStreams = new Set<any>();
  const serverCounts = { accepted: 0, eventOpens: 0, requests: 0 };
  for (let i = 0; i < nodes.length; i++) {
    const peers = nodes.filter((_, j) => j !== i).map(node => ({ id: node.id(), name: "peer" }));
    const data = join(temp, `station-${i}`);
    writeState(data, { origin, station: nodes[i].id(), workspace: workspaces[0], workspace_name: "Load", name: `station-${i}`,
      relay_url: urls[0], relay_urls: urls, grant_keys: { keys: [grant.jwk] }, peers, revocations: [],
      joined: workspaces.slice(1).map(workspace => ({ workspace, workspace_name: "Load", name: `station-${i}`, peers, revocations: [] })),
    });
    const cloud = new Cloud(data); cleanups.push(() => cloud.close());
    const directory = { directory: { policy: () => ({ nodes: nodes.map(n => n.id()), relayUrls: urls, globalRelays: [] }),
      records: (scope: string) => descriptors.get(scope)!.map(descriptor => ({ body: JSON.stringify({ descriptor }) })) }, listen: (listener: (scope: string) => void) => { directoryListeners.add(listener); return () => { directoryListeners.delete(listener); }; } };
    const leaves = new LeafAttachments(nodes[i], directory as any, cloud);
    void (async () => {
      for (;;) {
        const conn = await nodes[i].accept(); if (!conn) break;
        serverCounts.accepted++;
        void serve({ cloud, leaves, admin: undefined as any, up: () => true,
          streams: head => head.path === "/admin/api/relay-load/ok" ? async ({ stream }) => {
            serverCounts.requests++; await writeLine(stream, { status: 200, headers: {} });
            await stream.write(Buffer.from("ok")); await stream.finish();
          } : head.path === "/admin/api/relay-load/events" ? async ({ stream }) => {
            serverCounts.eventOpens++; eventStreams.add(stream);
            try { await writeLine(stream, { status: 200, headers: {} }); await stream.write(Buffer.from("ready\n")); await stream.stopped(); }
            finally { eventStreams.delete(stream); }
          } : undefined,
        }, conn).catch(error => { if (!conn.isClosed()) console.error("station serve", error); });
      }
    })();
  }
  const bundle = await build({ entryPoints: [join(import.meta.dirname, "relay-load-worker.ts")], bundle: true, format: "esm", platform: "browser", write: false });
  const server = createServer(async (req, res) => {
    try {
      if (req.url === "/worker.js") { res.setHeader("Content-Type", "text/javascript"); res.end(bundle.outputFiles[0].contents); }
      else if (req.url?.startsWith("/wasm/")) {
        const name = req.url.slice(6); assert.match(name, /^[a-zA-Z0-9_.]+$/);
        res.setHeader("Content-Type", name.endsWith(".wasm") ? "application/wasm" : "text/javascript"); res.end(await readFile(join(pkg, name)));
      } else {
        res.setHeader("Content-Type", "text/html");
        res.end(`<script>
          const worker = new Worker('/worker.js', { type: 'module' }); const pending = new Map(); let serial = 0;
          window.callWorker = (method,args) => new Promise((resolve,reject) => { const id=++serial; pending.set(id,{resolve,reject}); worker.postMessage({id,method,args}); });
          worker.onmessage = ({data}) => { if(data.ready){window.workerReady=true;return;} const item=pending.get(data.id); pending.delete(data.id); data.error?item.reject(Error(data.error)):item.resolve(data.result); };
        </script>`);
      }
    } catch (error) { res.statusCode = 500; res.end(String(error)); }
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>(resolve => server.close(() => resolve())));
  assert.ok(process.env.CHROME_BIN, "set CHROME_BIN to the root lockfile's installed chromium-headless-shell");
  // Playwright launch enables focus emulation on every page. A separate CDP
  // client cannot remove that override. Attach to our own clean browser with
  // noDefaults so minimizing its window changes real page visibility.
  const chrome = spawn(process.env.CHROME_BIN, ["--headless", "--no-sandbox", "--no-first-run",
    "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", `--user-data-dir=${join(temp, "chromium")}`, "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] });
  const chromeLog: string[] = [];
  const exited = new Promise<void>(resolve => chrome.once("exit", () => resolve()));
  cleanups.push(async () => {
    if (chrome.exitCode === null && chrome.signalCode === null) chrome.kill("SIGKILL");
    if (chrome.pid) await exited;
    await writeFile(join(output, "browser.log"), chromeLog.join(""));
  });
  const websocket = await new Promise<string>((resolve, reject) => {
    const timer = setTimeout(() => reject(Error("Chromium did not expose DevTools within 15 seconds")), 15_000);
    const fail = (error: Error) => { clearTimeout(timer); reject(error); };
    chrome.once("error", fail);
    chrome.once("exit", code => fail(Error(`Chromium exited before DevTools: ${code}`)));
    chrome.stderr.on("data", data => {
      chromeLog.push(String(data));
      const found = chromeLog.join("").match(/DevTools listening on (ws:\/\/\S+)/);
      if (found) { clearTimeout(timer); resolve(found[1]); }
    });
  });
  const browser = await chromium.connectOverCDP(websocket, { noDefaults: true, timeout: 15_000 });
  cleanups.push(() => browser.close());
  const capture = new RelayCapture(await browser.newBrowserCDPSession(), join(output, "cdp.ndjson"));
  cleanups.push(() => capture.close());
  await capture.start();
  const context = browser.contexts()[0];
  const page = context.pages()[0] ?? await context.newPage();
  page.on("pageerror", (error: unknown) => console.error("page", error));
  await page.goto(`http://127.0.0.1:${(server.address() as { port: number }).port}`);
  await page.waitForFunction(() => (globalThis as any).workerReady === true);
  await until(() => capture.workers.size > 0, "CDP attached before binding the core endpoint");
  const rpc = (method: string, args: unknown = {}): Promise<any> => page.evaluate(({ method, args }: any) => (globalThis as any).callWorker(method, args), { method, args });
  const device = await rpc("init", { relays: urls, entries, targets, hotRelays: hotRelays.budget });
  const now = Math.floor(Date.now() / 1000);
  const credentials = new Map(workspaces.map(ws => [ws, grant.credential({ typ: "stillfail-member+jwt" },
    { iss: "stillfail-cloud", sub: "load", email: "load@example.invalid", name: "Load", ws, role: "owner", device: device.id, sid: "load", iat: now, exp: now + 3600 })]));
  for (const workspace of workspaces) await rpc("connect", { workspace, station: nodes[0].id(), relays: urls, credential: credentials.get(workspace) });
  await until(async () => (await rpc("snapshot")).counts.leafLines >= workspaces.length, "initial workspace leaf policies received");
  // The policy reader runs before a later worker message. No artificial request load in the idle window.
  for (const workspace of workspaces) for (const node of nodes.slice(1)) await rpc("connect", { workspace, station: node.id(), relays: urls, credential: credentials.get(workspace) });
  await until(async () => (await rpc("snapshot")).counts.eventOpens === workspaces.length * nodes.length, "all application event streams open");
  let streamTimer: ReturnType<typeof setInterval> | undefined;
  if (options.streamMs > 0) {
    streamTimer = setInterval(() => { for (const stream of eventStreams) void stream.write(Buffer.from("data\n")).catch(() => {}); }, options.streamMs);
    cleanups.push(() => clearInterval(streamTimer));
  }
  const pageSession = await context.newCDPSession(page);
  const { windowId } = await pageSession.send("Browser.getWindowForTarget");
  await pageSession.send("Browser.setWindowBounds", { windowId, bounds: { windowState: options.visibility === "hidden" ? "minimized" : "normal" } });
  if (options.visibility === "visible") await page.bringToFront();
  await until(async () => await page.evaluate(() => document.visibilityState) === options.visibility, "real page visibility matches the scenario", 5000);
  await pause(15_000);
  const before = await rpc("snapshot");
  assert.equal(capture.errors.length, 0, capture.errors.join("\n"));
  const start = performance.now();
  console.log(JSON.stringify({ phase: "measurement-start", options, start, output }));
  await pause(options.durationMs);
  const end = performance.now();
  const after = await rpc("snapshot");
  const actualVisibility = await page.evaluate(() => document.visibilityState);
  assert.equal(actualVisibility, options.visibility);
  // Finish observing short sockets created in the last ten seconds of the window.
  await pause(10_000);
  const measured = capture.summarize(start, end, after.identities, [...urls, ...entries]);
  const controls = process.env.RELAY_LOAD_CONTROLS === "1" ? await relayControls(rpc, capture, device.id, urls, entries, targets, output) : undefined;
  if (failure === "dual") {
    const fault = await dualRelayFailure(rpc, relays, eventStreams, serverCounts, output);
    const result = { stationDescriptors: Object.fromEntries(descriptors), descriptorChanges, directoryErrors,
      transport: "ws/local-loopback", sourceRevision: process.env.RELAY_LOAD_REVISION ?? "unspecified",
      options, hotRelays, failure, continuityRequired: continuity === "1", browser: browser.version(), visibilityControl: "native-window/no-focus-emulation",
      actualVisibility, scriptHashes, urls, entries, targets, before, after, controls,
      measurement: measured, ...fault, serverCounts };
    await writeFile(join(output, "result.json"), JSON.stringify(result, null, 2) + "\n");
    console.log(JSON.stringify({ phase: "dual-result", hotRelays, recovery: result.recovery }));
    assert.ok(result.recovery.requests.every(r => r.status === 200), "all application requests recover");
    assert.equal(result.recovery.allStreamsDelivered, true, "every station event stream delivers");
    // The full-relay baseline can replace a link when path recovery races a new dial.
    // Record that outcome; a later hot-set experiment can require continuity explicitly.
    if (continuity === "1") {
      assert.equal(result.recovery.allOriginalConnectionsOpen, true, "dual failure keeps all original connections");
      assert.equal(result.recovery.eventStreamsReopened, 0, "dual failure does not reopen event streams");
    }
    assert.deepEqual(directoryErrors, []);
  } else {
    const selected = (await rpc("snapshot")).links[0].paths.find((path: any) => path.selected && path.relay);
    assert.ok(selected, "the first station has a selected relay path");
    const cut = relays.find(relay => [relay.url, relay.entry].some(url => url && new URL(url).host === new URL(selected.relay).host));
    assert.ok(cut, `selected relay is a local fixture: ${JSON.stringify(selected)}`);
    const opensBefore = serverCounts.eventOpens;
    const cutAt = performance.now(); cut.stop();
    const recovered = await rpc("request", { address: after.links[0].address });
    const recoveryMs = Math.round(performance.now() - cutAt);
    assert.equal(recovered.status, 200);
    const chunksBefore = (await rpc("snapshot")).counts.eventChunks;
    for (const stream of eventStreams) await stream.write(Buffer.from("after-cut\n"));
    await until(async () => (await rpc("snapshot")).counts.eventChunks > chunksBefore, "existing stream delivers after relay removal");
    const final = await rpc("snapshot");
    assert.deepEqual(directoryErrors, []);
    const result = { stationDescriptors: Object.fromEntries(descriptors), descriptorChanges, directoryErrors, transport: "ws/local-loopback", sourceRevision: process.env.RELAY_LOAD_REVISION ?? "unspecified", options, hotRelays,
      browser: browser.version(), visibilityControl: "native-window/no-focus-emulation", actualVisibility, scriptHashes, urls, entries, targets, before, after, final, controls,
      measurement: measured, recovery: { relay: cut.url, milliseconds: recoveryMs, ...recovered,
        eventStreamsReopened: serverCounts.eventOpens - opensBefore, allOriginalConnectionsOpen: final.links.every((link: any) => link.originalClosed === null && link.sameConnection) }, serverCounts };
    await writeFile(join(output, "result.json"), JSON.stringify(result, null, 2) + "\n");
    const { perSecond: _seconds, ...total } = measured.total;
    console.log(JSON.stringify({ phase: "result", output, hotRelays, total, recovery: result.recovery }));
    assert.equal(result.recovery.allOriginalConnectionsOpen, true, "all original station connections survive the measurement and relay cut");
    assert.equal(result.recovery.eventStreamsReopened, 0, "relay recovery does not reopen application event streams");
  }
  await rpc("close");
});
