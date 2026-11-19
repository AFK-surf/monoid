// The machine's side of the background jobs, the remote tasks, the web previews and the link previews in MoonBit
// (station/mb/src/jobs_host, `stillfail-reader-harness --builder harness-jobs-host`) held to the TypeScript station it replaces
// (src/jobs/*, src/links/preview.ts) on the same inputs: the GPU, load and link-preview parsers compared value for
// value; the preview proxy and WebSocket, the workspace-size state machine, the remote tasks' file transfers and the
// jobs' process lifecycle run on the real filesystem and sockets and held to how the TypeScript behaves.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { chmod, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer } from "ws";
import { appleGpu, macDiscreteGpus, nvidiaGpus, windowsAmdGpus } from "../src/jobs/gpu.ts";
import { amdIntegrated } from "../src/jobs/amd-integrated.ts";
import { pciNames } from "../src/jobs/linux-gpu.ts";
import { detailed, summary } from "../src/jobs/load.ts";
import { blobId } from "../src/jobs/dirsync.ts";
import { hash, remoteBudget } from "../src/jobs/remote.ts";
import { headOf, htmlText, isPublic, oembedOf } from "../src/links/preview.ts";
import { isIP } from "node:net";
import { mbHarnessBinary } from "./mb-harness.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `jobs-host-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
function harness() {
  if (program !== null) return program;
  const child = spawn(binary!, ["--builder", "harness-jobs-host", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  child.on("exit", (code) => { for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` })); });
  program = {
    child,
    next: (line) => new Promise((resolve) => {
      waiting.push((answer) => resolve(JSON.parse(answer)));
      child.stdin.write(`${line}\n`);
    }),
  };
  return program;
}
after(() => {
  program?.child.stdin.end();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit says of `c` (its `ok`, or the words it failed with).
async function mb(c: unknown): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}
/// `{ok}` or `{error}` of a value, for the cases that may fail either side.
async function mbOutcome(c: unknown): Promise<any> {
  return harness().next(JSON.stringify(c));
}
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
const base64 = (b: Buffer | Uint8Array) => Buffer.from(b).toString("base64");

// ── the GPU, load and link parsers, value for value ──

test("GPU parsers say what the TypeScript parsers say", { skip }, async () => {
  const ioregs = [
    `"model" = "Apple M1 Pro"\n"gpu-core-count" = 16\n"Device Utilization %"=21`,
    `"model" = "Apple M2"\n"Device Utilization %"=101`,
    "nothing",
    `"gpu-core-count" = 10`,
  ];
  for (const text of ioregs) assert.deepEqual(await mb({ op: "gpu.apple", text }), plain(appleGpu(text)), text);
  for (const text of ["NVIDIA GeForce RTX 4090, 24564, 1024, 37\nTesla T4, 15360, [N/A], [N/A]\n", "", "A, x, y, z"]) {
    assert.deepEqual(await mb({ op: "gpu.nvidia", text }), plain(nvidiaGpus(text)), text);
  }
  const windows = [`{"Name":"AMD Radeon RX 6800","PNPDeviceID":"PCI\\\\VEN_1002&DEV_73BF&X"}`,
    `[{"Name":"AMD A","PNPDeviceID":"PCI\\\\VEN_1002&DEV_164C&X"},{"Name":"AMD B","PNPDeviceID":"PCI\\\\VEN_1002&DEV_73BF"}]`, "not json", "[]"];
  for (const text of windows) assert.deepEqual(await mb({ op: "gpu.windows", text }), plain(windowsAmdGpus(text)), text);
  const macs = [
    JSON.stringify({ SPDisplaysDataType: [{ sppci_bus: "spdisplays_pcie_device", spdisplays_vendor: "AMD (0x1002)", sppci_model: "Radeon Pro 580", spdisplays_vram: "8 GB" }] }),
    JSON.stringify({ SPDisplaysDataType: [{ sppci_bus: "spdisplays_pcie_device", spdisplays_vendor: "NVIDIA", _spdisplays_vram: "4096 MB" }] }),
    JSON.stringify({ SPDisplaysDataType: [{ sppci_bus: "other", spdisplays_vendor: "AMD" }] }),
    "x",
  ];
  for (const text of macs) assert.deepEqual(await mb({ op: "gpu.mac", text }), plain(macDiscreteGpus(text)), text);
  const lspci = "Slot:\t0000:01:00.0\nDevice:\tRadeon RX 7900\n\nSlot:\t0000:00:02.0\nDevice:\tIntegrated\n";
  assert.deepEqual(await mb({ op: "gpu.pci", text: lspci }), plain(Object.fromEntries(pciNames(lspci))));
  for (const id of ["0x164C", "164c", "73bf", null, "", "0x73BF"]) assert.equal(await mb({ op: "gpu.amd", id }), amdIntegrated(id), String(id));
});

test("load summary and detailed say what the TypeScript says", { skip }, async () => {
  const loads: any[] = [
    { os: "macos", arch: "arm64", cpus: 8, cpuModel: "Apple M1", gpus: [{ name: "Apple M1", cores: 8 }, { name: "RTX", memoryTotalBytes: 2 ** 34, memoryUsedBytes: 2 ** 33, busy: 0.5 }], cpuBusy: { share: 0.25, seconds: 60 }, loadAvg: [1, 2, 3], memory: { totalBytes: 2 ** 34, availableBytes: 2 ** 33 }, disk: { path: "/", totalBytes: 2 ** 40, freeBytes: 2 ** 39 }, running: { remoteTasks: 1, jobs: 0, services: 2, turns: 1 }, relay: { home: "r", ping: { relay: "r", ms: 12 } } },
    { unavailable: "not measured within 1 s" },
    null,
    { arch: "x86_64", os: "linux", cpuBusy: { share: 0.1, seconds: null } },
  ];
  for (const load of loads) assert.equal(await mb({ op: "load.summary", load }), summary(load), JSON.stringify(load));
  for (const described of [{ load: loads[0] }, { version: "1", protocol: 1 }, null, loads[0]]) {
    assert.deepEqual(await mb({ op: "load.detailed", described }), plain(detailed(described)), JSON.stringify(described));
  }
});

test("link head, htmlText, isPublic, isIP and oEmbed say what the TypeScript says", { skip }, async () => {
  const htmls = [
    [`<html><head><title>Plain &amp; simple</title><meta property="og:title" content="The &quot;real&quot; title"><meta name=description content='What it is'><meta property="og:site_name" content="Example"><link rel="icon" href="/i.png"></head>`, "https://ex.am/docs/page"],
    [`<head><title>T</title><meta property="og:image" content="https://cdn.ex.am/p.jpg?a=1&amp;b=2"><meta name="twitter:image" content="/t.png"></head>`, "https://ex.am/docs/page"],
    [`<head><title>T</title><meta property="og:image" content="javascript:alert(1)"></head>`, "https://ex.am/"],
    [`<title> A&#x26;B  &#169; </title>`, "https://ex.am/"],
  ] as const;
  for (const [html, base] of htmls) assert.deepEqual(await mb({ op: "links.head", html, base }), plain(headOf(html, new URL(base))), html);
  for (const text of ["a&nbsp;b &bogus; c", "A&#x26;B  &#169;", "x\n  y\tz "]) assert.equal(await mb({ op: "links.text", text }), htmlText(text), text);
  for (const a of ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "1.1.1.1", "140.82.112.3", "2606:4700::1111", "172.32.0.1", "::ffff:7f00:1", "0:0:0:0:0:FFFF:7F00:0001", "0:0::ffff:192.168.1.1", "::ffff:a01:203", "::ffff:101:101", "0:0::ffff:1.1.1.1", "::ffff:0:0:1", "0:0:0:0:0:0:0:1", "::1%lo0", "not-an-address"]) {
    assert.equal(await mb({ op: "links.public", address: a }), isPublic(a), a);
    assert.equal(await mb({ op: "links.ip", address: a }), isIP(a), a);
  }
  for (const s of ["https://www.youtube.com/watch?v=7YiXO6twfXk", "https://m.youtube.com/watch?v=x", "https://youtu.be/7YiXO6twfXk", "https://www.youtube.com/shorts/abc", "https://vimeo.com/76979871", "https://www.youtube.com/", "https://vimeo.com/about", "https://notyoutube.com/watch?v=x"]) {
    assert.deepEqual(await mb({ op: "links.oembed", url: s }), oembedOf(new URL(s)) ?? null, s);
  }
});

test("blobId, hash and remoteBudget say what the TypeScript says", { skip }, async () => {
  for (const s of ["", "abc", "a".repeat(1000)]) assert.equal(await mb({ op: "dirsync.blob", content: base64(Buffer.from(s)) }), blobId(Buffer.from(s)), s);
  for (const v of [{ a: 1, b: [2, "x"] }, "s", [1, 2], null]) assert.equal(await mb({ op: "remote.hash", value: v }), hash(v), JSON.stringify(v));
  for (const total of [null, 0, -5, 100 * 1024 ** 3, 500 * 1024 ** 3]) assert.equal(await mb({ op: "remote.budget", total }), remoteBudget(total), String(total));
});

// ── the link-preview head read from a real server ──

test("a page is read up to its head's end, even when a tag is cut between chunks", { skip }, async () => {
  const chunks = ["<html><head><title>T</title></he", "ad><body>", "x".repeat(1000)];
  const got = await mb({ op: "links.body", chunks: chunks.map((c) => base64(Buffer.from(c))), max: 1 << 20, untilHead: true });
  assert.equal(Buffer.from(got, "base64").toString("utf8"), chunks[0] + chunks[1]);
});

test("a page's body is read as sent from the pinned address; one in any encoding is not read", { skip }, async () => {
  const seen: { host?: string; encoding?: string }[] = [];
  const server = createServer((req, res) => {
    seen.push({ host: req.headers.host, encoding: req.headers["accept-encoding"] as string });
    if (req.url === "/gz") { res.setHeader("content-encoding", "gzip"); res.end(Buffer.from([1, 2, 3])); return; }
    res.setHeader("content-type", "text/html"); res.end("<title>T</title>");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as any).port;
  try {
    const page = await mb({ op: "links.getAt", url: `http://localhost:${port}/`, addresses: ["127.0.0.1"], accept: "text/html" });
    assert.equal(page.status, 200);
    assert.equal(page.body, "<title>T</title>");
    assert.equal(seen.at(-1)!.host, `localhost:${port}`);
    assert.equal(seen.at(-1)!.encoding, "identity");
    assert.equal(await mb({ op: "links.getAt", url: `http://localhost:${port}/gz`, addresses: ["127.0.0.1"], accept: "*/*" }), null);
  } finally { server.close(); }
});

test("a link preview of a GitHub pull request, as its API says it", { skip }, async () => {
  const api = {
    "repos/o/r/pulls/5": { title: "Fix", merged_at: null, state: "open", draft: false, user: { login: "u" }, additions: 3, deletions: 1, changed_files: 2, updated_at: "2026-01-02T03:04:05Z", head: { sha: "abc" } },
    "repos/o/r/commits/abc/check-runs?per_page=100": { check_runs: [{ status: "completed", conclusion: "success" }, { status: "in_progress" }] },
  };
  const preview = await mb({ op: "links.preview", href: "https://github.com/o/r/pull/5", api });
  assert.deepEqual(preview, { kind: "github_pull_request", url: "https://github.com/o/r/pull/5", repository: "o/r", number: 5, title: "Fix", state: "open", author: { login: "u" }, additions: 3, deletions: 1, changedFiles: 2, updatedAt: Date.parse("2026-01-02T03:04:05Z"), checks: { passed: 1, failed: 0, pending: 1 } });
});

test("the MoonBit station shows the failed job and links to its step in this attempt", { skip }, async () => {
  const url = "https://github.com/o/r/actions/runs/12345678901/attempts/1";
  const path = "repos/o/r/actions/runs/12345678901/attempts/1";
  const run = { run_number: 12, run_attempt: 1, name: "pipeline", display_title: "Ship", status: "completed", conclusion: "failure",
    head_branch: "main", head_sha: "123456789", run_started_at: "2026-01-01T12:00:00Z", updated_at: "2026-01-01T12:12:00Z" };
  const job = { id: 9876543210, name: "desktop", status: "completed", conclusion: "failure",
    steps: [{ number: 3, name: "Sign", status: "completed", conclusion: "failure" }] };
  const jobs = { total_count: 1, jobs: [job] };
  const preview = await mb({ op: "links.preview", href: url, api: { [path]: run, [path + "/jobs?per_page=100&page=1"]: jobs } });
  assert.equal(preview.state, "failure");
  assert.deepEqual(preview.counts, { failed: 1 });
  assert.deepEqual(preview.jobs, [{ name: "desktop", step: "Sign", url: "https://github.com/o/r/actions/runs/12345678901/job/9876543210#step:3:1" }]);
  assert.equal(preview.finishedAt - preview.startedAt, 12 * 60000);
});

// ── the preview proxy and WebSocket, round-tripped through a real server ──

test("the preview proxy passes a request and its answer, strips framing headers and rewrites a self-redirect", { skip }, async () => {
  const server = createServer((req, res) => {
    if (req.url === "/redir") { res.statusCode = 302; res.setHeader("location", `http://localhost:${(server.address() as any).port}/there`); res.end(); return; }
    res.setHeader("x-frame-options", "DENY");
    res.setHeader("content-type", "text/plain");
    res.end(`got ${req.method} ${req.url} host=${req.headers.host} ae=${req.headers["accept-encoding"]}`);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as any).port;
  try {
    const got = await mb({ op: "preview.proxy", method: "GET", headers: [["accept", "text/plain"]], port, path: "/x?y", lang: "en", asker: "preview" });
    assert.equal(got.status, 200);
    assert.equal(Buffer.from(got.body, "base64").toString("utf8"), `got GET /x?y host=localhost:${port} ae=identity`);
    assert.ok(!got.headers.some((h: [string, string]) => h[0] === "x-frame-options"), "framing header stripped");
    const redir = await mb({ op: "preview.proxy", method: "GET", headers: [], port, path: "/redir", lang: "en" });
    assert.equal(redir.status, 302);
    assert.equal(redir.headers.find((h: [string, string]) => h[0] === "location")?.[1], "/there");
  } finally { server.close(); }
});

test("the preview proxy posts a body and reads a chunked answer", { skip }, async () => {
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => { res.setHeader("content-type", "text/plain"); res.write("a".repeat(5)); res.write("b".repeat(5)); res.end(`:${body}`); });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as any).port;
  try {
    const got = await mb({ op: "preview.proxy", method: "POST", headers: [["content-type", "text/plain"]], body: base64(Buffer.from("sent")), port, path: "/", lang: "en" });
    assert.equal(Buffer.from(got.body, "base64").toString("utf8"), "aaaaabbbbb:sent");
  } finally { server.close(); }
});

test("the preview proxy says a refusal in the person's language when the service does not answer", { skip }, async () => {
  const en = await mb({ op: "preview.proxy", method: "GET", headers: [], port: 9, path: "/", lang: "en" });
  const zh = await mb({ op: "preview.proxy", method: "GET", headers: [], port: 9, path: "/", lang: "zh" });
  assert.equal(en.status, 502);
  assert.match(Buffer.from(en.body, "base64").toString("utf8"), /localhost:9/);
  assert.match(Buffer.from(zh.body, "base64").toString("utf8"), /无响应/);
  const bad = await mb({ op: "preview.proxy", method: "BAD METHOD", headers: [], port: 9, path: "/", lang: "en" });
  assert.equal(bad.status, 400);
});

test("a preview WebSocket: the handshake, the client's frames to the service, the service's back, and a close", { skip }, async () => {
  const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
  const heard: string[] = [];
  wss.on("connection", (ws, req) => {
    assert.equal(req.headers.origin, `http://localhost:${(wss.address() as any).port}`);
    ws.on("message", (d, isBinary) => { heard.push(isBinary ? `bin:${d}` : `txt:${d}`); ws.send(`echo:${d}`); });
  });
  await new Promise<void>((r) => wss.on("listening", r));
  const port = (wss.address() as any).port;
  try {
    // One client text frame, masked, FIN set: kind 1, length 2, "hi".
    const clientFrame = Buffer.concat([Buffer.from([1, 0, 0, 0, 2]), Buffer.from("hi")]);
    const got = await mb({ op: "preview.ws", headers: [["sec-websocket-protocol", "chat"]], port, path: "/", lang: "en", client: base64(clientFrame) });
    assert.equal(heard.length >= 1, true);
    assert.equal(heard[0], "txt:hi");
    // The service's echo comes back framed to the client.
    const sent = Buffer.from(got.sent, "base64");
    assert.equal(sent[0], 1); // FRAME_TEXT
    const len = sent.readUInt32BE(1);
    assert.equal(sent.subarray(5, 5 + len).toString("utf8"), "echo:hi");
  } finally { wss.close(); }
});

test("a preview WebSocket says the service's refusal when the handshake is not accepted", { skip }, async () => {
  const server = createServer((_req, res) => { res.statusCode = 403; res.end(); });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as any).port;
  try {
    const got = await mbOutcome({ op: "preview.ws", headers: [], port, path: "/", lang: "en", client: base64(Buffer.alloc(0)) });
    assert.equal(got.ok.refused, 403);
  } finally { server.close(); }
});

// ── the workspace-size reader and watch ──

test("the workspace reader walks one at a time, reuses a fresh result, and sweeps", { skip }, async () => {
  const out = await mb({ op: "ws.reader", steps: [
    { do: "size", at: 0, path: "/w1" },
    { do: "size", at: 1, path: "/w1" },           // still pending: null, no second walk
    { do: "done", at: 2, size: { bytes: 5, complete: true } },
    { do: "size", at: 3, path: "/w1" },           // fresh, complete: returns it
    { do: "size", at: 10 * 60_001, path: "/w1" }, // past CHECK_MS: walks again
    { do: "done", at: 10 * 60_002, size: { bytes: 9, complete: true } },
  ] });
  assert.deepEqual(out.out[0], null);
  assert.deepEqual(out.out[1], null);
  assert.deepEqual(out.out[3], { bytes: 5, complete: true });
  assert.equal(out.walked.length, 2, "walked twice");
});

test("the workspace watch warns over the limit, reminds hourly, and warns anew after it cleans up", { skip }, async () => {
  const data = fresh("ws-watch");
  const over = { session: "s1", station: "", name: "here", path: "/w", bytes: 11 * 1024 ** 3, complete: true };
  const out = await mb({ op: "ws.watch", data, steps: [
    { do: "look", at: 0, readings: [over], working: ["s1"] },
    { do: "limit", session: "s1", station: "" },
    { do: "look", at: 60 * 60_000 - 1, readings: [over], working: ["s1"] }, // before REMIND_MS: no new notice
    { do: "look", at: 60 * 60_000, readings: [over], working: ["s1"] },     // at REMIND_MS: reminded
    { do: "look", at: 60 * 60_001, readings: [{ ...over, bytes: 9 * 1024 ** 3, complete: true }], working: ["s1"] }, // under again
    { do: "look", at: 60 * 60_002, readings: [over], working: ["s1"] },     // over again: warned anew
  ] });
  assert.equal(out.out[1], 10 * 1024 ** 3, "default limit");
  assert.equal(out.told.length, 3);
  assert.match(out.told[0][1], /11\.0 GiB.*10 GiB.*workspace_limit/s);
});

test("the workspace watch keeps a raised limit, and forgets a deleted chat", { skip }, async () => {
  const data = fresh("ws-set");
  const out = await mb({ op: "ws.watch", data, steps: [
    { do: "set", at: 0, session: "s1", station: "", gib: 20 },
    { do: "limit", session: "s1", station: "" },
    { do: "set", at: 0, session: "s1", station: "", gib: 0 },  // refused
    { do: "forget", session: "s1" },
    { do: "limit", session: "s1", station: "" },
  ] });
  assert.equal(out.out[0], 20 * 1024 ** 3);
  assert.equal(out.out[1], 20 * 1024 ** 3);
  assert.ok(out.out[2].error, "a non-positive limit is refused");
  assert.equal(out.out[4], 10 * 1024 ** 3, "back to the default after forget");
});

// ── the remote tasks' file transfers ──

test("filePath takes only relative paths and refuses links and .. ", { skip }, async () => {
  const root = fresh("fp");
  await mkdir(join(root, "a"), { recursive: true });
  assert.equal(await mb({ op: "remote.filePath", root, relative: "a/b.txt", create: true }), join(root, "a/b.txt"));
  for (const relative of ["/abs", "../x", "a/../b", ""]) {
    assert.equal((await mbOutcome({ op: "remote.filePath", root, relative, create: false })).error !== undefined, true, relative);
  }
  await symlink(root, join(root, "link"));
  assert.ok((await mbOutcome({ op: "remote.filePath", root: join(root, "link"), relative: "x", create: false })).error);
});

test("a task's file put whole and in chunks, and got whole and in chunks, round-trips byte for byte", { skip }, async () => {
  const dir = fresh("files");
  const content = Buffer.from("héllo ".repeat(100000)); // ~600 KiB, several chunks
  const src = join(dir, "src.bin");
  await writeFile(src, content);
  // put whole (bytes after the request), then get whole
  const put = await mb({ op: "remote.put", path: join(dir, "whole.bin"), request: { size: content.length }, whole: base64(content) });
  assert.deepEqual(put, { bytes: content.length, whole: true });
  const got = await mb({ op: "remote.get", path: join(dir, "whole.bin"), request: { offset: 0, whole: true } });
  assert.equal(Buffer.from(got.bytes, "base64").length, content.length);
  assert.ok(Buffer.from(got.bytes, "base64").equals(content), "whole round-trip");
  // a chunk to a station from before
  const chunk = content.subarray(0, 100);
  const one = await mb({ op: "remote.put", path: join(dir, "chunk.bin"), request: { offset: 0, data: chunk.toString("base64"), final: true } });
  assert.deepEqual(one, { bytes: chunk.length, whole: true });
});

test("download fetches a whole file from a peer, and a chunked one from a station from before", { skip }, async () => {
  const remoteRoot = fresh("peer");
  const dir = fresh("dl");
  const content = Buffer.from("x".repeat(500000));
  await writeFile(join(remoteRoot, "f.bin"), content);
  for (const older of [false, true]) {
    const path = join(dir, `got-${older}.bin`);
    const out = await mb({ op: "remote.download", remoteRoot, older, request: { path: "f.bin" }, path, replace: false });
    assert.equal(out.size, content.length, `older=${older}`);
    assert.ok((await readFile(path)).equals(content), `older=${older} content`);
  }
});

test("stationFile uploads an input and downloads an output through the peer", { skip }, async () => {
  const remoteRoot = fresh("peer2");
  const root = fresh("ws");
  const content = Buffer.from("data ".repeat(60000));
  await writeFile(join(root, "in.bin"), content);
  const up = await mb({ op: "remote.stationFile", remoteRoot, root, request: {}, args: { direction: "upload", local: "in.bin", path: "there.bin" } });
  assert.equal(up.bytes, content.length);
  assert.ok((await readFile(join(remoteRoot, "there.bin"))).equals(content), "uploaded");
  const down = await mb({ op: "remote.stationFile", remoteRoot, root, request: {}, args: { direction: "download", local: "out.bin", path: "there.bin" } });
  assert.equal(down.bytes, content.length);
  assert.ok((await readFile(join(root, "out.bin"))).equals(content), "downloaded");
});

test("bringBack fetches a task's files into station-back and leaves what is not there as missing", { skip }, async () => {
  const remoteRoot = fresh("peer3");
  const ws = fresh("wsb");
  await writeFile(join(remoteRoot, "out.txt"), "result");
  const told = { taskFiles: { base: "", files: [["out.txt", 6], ["gone.txt", null]] } };
  const out = await mb({ op: "remote.bringBack", remoteRoot, root: fresh("rr"), workspace: ws, told, entry: { station: "s", key: "k1", session: "sess", back: ["out.txt", "gone.txt"] } });
  assert.equal(out.files.count, 1);
  assert.deepEqual(out.files.files, ["out.txt"]);
  assert.equal(out.files.missing.length, 1);
  assert.equal(await readFile(join(ws, "station-back", "k1", "out.txt"), "utf8"), "result");
});

test("station list, named, workspace, targets and record say what is meant", { skip }, async () => {
  const roster = { stations: [{ id: "own", name: "Me", version: "1" }, { id: "b", name: "Bee", version: "0" }], unprotected: [{ id: "c", name: "Cee" }] };
  const answers = { b: { ok: { version: "2", load: { os: "linux", arch: "x86_64", cpus: 4 } } } };
  const listed = await mb({ op: "remote.list", roster, own: "own", version: "1", ownLoad: { os: "macos", arch: "arm64", cpus: 8 }, answers, sandboxes: [{ name: "box", described: { sandbox: true } }] });
  assert.equal(listed.stations[0].here, true);
  assert.equal(listed.stations[1].version, "2");
  assert.ok(listed.stations.some((s: any) => s.id === "sandbox:box"));
  assert.ok(listed.stations.some((s: any) => s.unprotected));
  assert.equal(await mb({ op: "remote.named", named: "Bee", sandboxes: [], roster }), "b");
  assert.equal(await mb({ op: "remote.named", named: "box", sandboxes: ["box"], roster: null }), "sandbox:box");
  assert.equal(await mb({ op: "remote.workspace", state: { workspace: "w" }, own: null }), "w");
  assert.ok((await mbOutcome({ op: "remote.workspace", state: { workspace: "w", removed_at: 1 }, own: null })).error);
  assert.deepEqual(await mb({ op: "remote.targets", record: { workspace: "w", stations: ["a", ""] }, workspace: "w" }), { workspace: "w", stations: ["a"] });
});

// ── the jobs' processes ──

test("job constants, jobJson, named, exit codes and file ids match the TypeScript", { skip }, async () => {
  const c = await mb({ op: "jobs.constants" });
  const { WRAPPER, JOB_COMMAND, JOB_COMMAND_NAME } = await import("../src/jobs/jobs.ts");
  assert.equal(c.wrapper, WRAPPER);
  assert.equal(c.command, JOB_COMMAND);
  assert.equal(c.name, JOB_COMMAND_NAME);
  const { jobJson, named, movedSaid } = await import("../src/jobs/jobs.ts");
  const row: any = { id: "job_1", sessionKey: "s", name: "n", command: "echo hi", cwd: "/", port: 3000, token: "secret", state: "running", pgid: 42, exitCode: null, startedAt: 1, endedAt: null, restarts: 0, log: "/l", watch: false, queued: true, screen: true };
  assert.deepEqual(await mb({ op: "jobs.json", job: row }), plain(jobJson(row)));
  assert.ok(!("token" in (await mb({ op: "jobs.json", job: row }))), "token not serialized");
  assert.equal(await mb({ op: "jobs.named", id: "job_1", name: "n", port: 3000 }), named({ id: "job_1", name: "n", port: 3000 }));
  assert.equal(await mb({ op: "jobs.named", id: "job_1", name: "n", port: null }), named({ id: "job_1", name: "n", port: null }));
  assert.equal(await mb({ op: "jobs.moved", why: "moved", id: "job_1", name: "n", port: null, error: null }), movedSaid("moved", { id: "job_1", name: "n", port: null }, null));
  assert.equal(await mb({ op: "jobs.moved", why: "moved", id: null, name: "n", port: 3000, error: "boom" }), movedSaid("moved", { id: null, name: "n", port: 3000 }, "boom"));
  for (const text of ["42", " -1 ", "x", "+7\n"]) assert.deepEqual(await mb({ op: "jobs.exitCode", text }), /^[+-]?\d+$/.test(text.trim()) ? Number(text.trim()) : null, text);
  assert.equal(await mb({ op: "jobs.fileId", name: "job_1.log", sub: "logs" }), "job_1");
  assert.equal(await mb({ op: "jobs.fileId", name: "job_1.log.1.tmp", sub: "logs" }), "job_1");
  assert.equal(await mb({ op: "jobs.fileId", name: "job_1.lost", sub: "exit" }), "job_1");
});

test("the notify and screen endpoints answer as the TypeScript endpoints do", { skip }, async () => {
  const good = await mb({ op: "jobs.notify", authorization: "Bearer good", body: base64(Buffer.from("hello")) });
  assert.deepEqual(good, { status: 200, body: { ok: true }, heard: ["hello"] });
  const bad = await mb({ op: "jobs.notify", authorization: "Bearer no", body: base64(Buffer.from("x")) });
  assert.equal(bad.status, 400);
  const tooLong = await mb({ op: "jobs.notify", authorization: "Bearer good", body: base64(Buffer.alloc(64 * 1024 + 1)) });
  assert.equal(tooLong.status, 400);
  const take = await mb({ op: "jobs.screen", authorization: "Bearer good", body: base64(Buffer.from("take 123")) });
  assert.deepEqual(take.body, { screen: "yours", pid: 123 });
  const malformed = await mb({ op: "jobs.screen", authorization: "Bearer good", body: base64(Buffer.from("nope")) });
  assert.equal(malformed.status, 400);
});

test("tail reads a log, and reads on into what was kept of before when it was just cut", { skip }, async () => {
  const dir = fresh("logs");
  const path = join(dir, "j.log");
  await writeFile(`${path}.1`, "old1\nold2\n");
  await writeFile(path, "new1\nnew2\n");
  assert.equal(await mb({ op: "jobs.tail", path, lines: 3 }), "old2\nnew1\nnew2");
  assert.equal(await mb({ op: "jobs.tail", path, lines: 1 }), "new2");
});

test("rotateInPlace cuts a log past its cap and keeps its tail in .1", { skip }, async () => {
  const dir = fresh("rot");
  const path = join(dir, "big.log");
  await writeFile(path, "a".repeat(100) + "\n" + "b".repeat(100) + "\n");
  const cut = await mb({ op: "jobs.rotate", path, cap: 50, keep: 120 });
  assert.equal(cut, true);
  assert.equal((await readFile(path, "utf8")), "", "cut to nothing");
  assert.ok((await readFile(`${path}.1`, "utf8")).includes("b".repeat(100)), "tail kept");
  assert.equal(await mb({ op: "jobs.rotate", path, cap: 1 << 20 }), false, "under the cap: not cut");
});

test("a job runs in a group of its own, writes its exit code aside and into place, and its end is heard", { skip }, async () => {
  const data = fresh("jobrun");
  const log = join(data, "out.log");
  const job = { id: "j1", sessionKey: "s", name: "n", command: "printf hello; exit 7", cwd: data, port: null, token: "t", state: "running", pgid: null, exitCode: null, startedAt: 0, endedAt: null, restarts: 0, log, watch: false };
  const out = await mb({ op: "jobs.run", data, job });
  assert.equal(out.ended.id, "j1");
  assert.equal(out.ended.code, 7, "its exit code heard");
  assert.equal(out.exit, "7", "exit file holds the code");
  assert.equal(out.tmpLeft, false, "no .tmp left");
  assert.equal(out.log, "hello", "its output in the log");
  assert.equal(out.groupAlive, false, "its group ended");
});

test("a job an earlier station started is followed to its end by the next station", { skip }, async () => {
  const data = fresh("jobadopt");
  const log = join(data, "a.log");
  const job = { id: "j2", sessionKey: "s", name: "n", command: "sleep 0.3; printf done; exit 0", cwd: data, port: null, token: "t", state: "running", pgid: null, exitCode: null, startedAt: 0, endedAt: null, restarts: 0, log, watch: false };
  const out = await mb({ op: "jobs.run", data, job, adopt: true });
  assert.equal(out.ended.code, 0, "the next station heard its end");
  assert.equal(out.log, "done");
});

test("a stopped job's group is ended within the grace", { skip }, async () => {
  const data = fresh("jobstop");
  const log = join(data, "s.log");
  const job = { id: "j3", sessionKey: "s", name: "n", command: "sleep 30", cwd: data, port: null, token: "t", state: "running", pgid: null, exitCode: null, startedAt: 0, endedAt: null, restarts: 0, log, watch: false };
  const out = await mb({ op: "jobs.run", data, job, stop: true });
  assert.equal(out.ended.id, "j3", "its end was heard after the stop");
  assert.equal(out.groupAlive, false, "its group ended");
});
