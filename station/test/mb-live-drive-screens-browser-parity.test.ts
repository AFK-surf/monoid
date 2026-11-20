// Live MoonBit station parity tests for Drive (roots, CRUD, chunked upload, path escape, zip/stage,
// large chunked transfers, folder watch SSE + long-poll), Screens / Helper / Permissions (Admin API +
// screen / permissions / computer MCP tool contracts), and Browser / Farview / Sign-in (browser MCP
// tool + /browser/<session> WS door + sign_in MCP tool + /admin-api/browser/sign-ins/* + card_outbox).
// All tests run against the real `stillfail-reader run` binary with no Node on PATH and STILLFAIL_LOCAL_ADMIN=1.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const skip = binary === null
  ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32"
    ? "the launcher's descriptors are Unix's"
    : false;

const dirs: string[] = [];
// (short: Unix sockets on macOS are capped at 104 bytes)
const fresh = (what: string) => {
  const dir = realpathSync(mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfg-${what}-`)));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];

after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const TOKEN = "track-g-parity-door";

/// Environment with no Node on PATH, isolated HOME/TMPDIR, and test doors enabled.
const noNode = (more: Record<string, string> = {}) => ({
  PATH: fresh("path"),
  HOME: fresh("home"),
  TMPDIR: tmpdir(),
  STILLFAIL_TEST_UI_ASK: TOKEN,
  STILLFAIL_LOCAL_ADMIN: "1",
  STILLFAIL_HELD_EVERY_MS: "300",
  STILLFAIL_NO_DISCOVERY: "1",
  ...more,
});

type Launched = {
  child: ChildProcess;
  door: number;
  tell: (m: unknown) => void;
  stop: () => Promise<void>;
  err: () => string;
};

async function launch(data: string, app: string, more: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode(more),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  await next("ready", (m) => m.ready === true);
  const door = (await next("mcp", (m) => m.serving === "mcp")).port as number;
  const tell = (m: unknown) => channel.write(`${JSON.stringify(m)}\n`);
  const stop = async () => {
    tell({ op: "stop" });
    assert.equal(await ended, 0, `clean stop; stderr=${err}`);
  };
  return { child, door, tell, stop, err: () => err };
}

async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms = 15_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}`);
    await new Promise((r) => setTimeout(r, 40));
  }
}

type HttpReply = { status: number; headers: Record<string, string | string[] | undefined>; body: Buffer; text: string };

function httpRaw(
  port: number,
  path: string,
  o: { method?: string; body?: string | Buffer; headers?: Record<string, string> } = {},
): Promise<HttpReply> {
  return new Promise((resolve, reject) => {
    const method = o.method ?? (o.body === undefined ? "GET" : "POST");
    const headers: Record<string, string> = { "stillfail-lang": "en", ...o.headers };
    if (o.body !== undefined && !Object.keys(headers).some((k) => k.toLowerCase() === "content-type")) {
      headers["content-type"] = Buffer.isBuffer(o.body) ? "application/octet-stream" : "application/json";
    }
    const req = request({ host: "127.0.0.1", port, path, method, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(Buffer.from(d)));
      res.on("end", () => {
        const body = Buffer.concat(chunks);
        resolve({ status: res.statusCode!, headers: res.headers, body, text: body.toString("utf8") });
      });
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

async function httpJson(
  port: number,
  path: string,
  o: { method?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<{ status: number; headers: Record<string, string | string[] | undefined>; json: any; text: string }> {
  const rawBody = o.body === undefined ? undefined : Buffer.isBuffer(o.body) ? o.body : typeof o.body === "string" ? o.body : JSON.stringify(o.body);
  const r = await httpRaw(port, path, { method: o.method, body: rawBody, headers: o.headers });
  let parsed: any = null;
  try {
    parsed = JSON.parse(r.text);
  } catch {}
  return { status: r.status, headers: r.headers, json: parsed, text: r.text };
}

async function ask(port: number, op: string, args: unknown[] = []): Promise<{ answer?: any; error?: any; kind?: string }> {
  const got = await httpRaw(port, "/ui-ask/", {
    method: "POST",
    body: JSON.stringify({ op, args }),
    headers: { authorization: `Bearer ${TOKEN}`, "content-type": "application/json" },
  });
  return JSON.parse(got.text);
}

async function mcpCall(port: number, token: string, name: string, args: Record<string, unknown> = {}): Promise<{ text: string; isError: boolean; raw: any }> {
  const r = await httpRaw(port, "/mcp", {
    method: "POST",
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  });
  assert.equal(r.status, 200, r.text);
  const parsed = JSON.parse(r.text);
  const result = parsed.result;
  assert.ok(result, `expected MCP result: ${r.text}`);
  const text = (result.content ?? []).map((c: any) => c.text ?? "").join("\n");
  return { text, isError: result.isError === true, raw: result };
}

const config = (data: string, c: unknown) => writeFileSync(join(data, "config.json"), JSON.stringify(c));

function seedSession(data: string, key: string, token: string, ws: string, createdBy: string, threadTs: string) {
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({
      key,
      connect: "chat",
      runtime: "claude",
      profile: "cc",
      workspace: fresh("ws"),
      token,
      createdBy,
      ws,
      createdAt: Date.now(),
      lastActiveAt: Date.now(),
    });
    const thread = store.openThread("chat", "CHAT", threadTs, null, createdBy);
    store.joinThread(thread.id, key, "chat");
    return thread.id;
  } finally {
    store.close();
  }
}

// ============================================================================
// Domain 1: Drive (Admin API CRUD, chunked upload, path escape, transfers, watch)
// ============================================================================

test("drive parity: roots, list/sort/mime, stat/read ranges, chunked upload, mkdir/rename/remove/zip/stage, path escape", { skip }, async () => {
  const data = fresh("drv-data");
  const app = fresh("drv-app");
  const base = fresh("drv-base");
  const root = join(base, "root");
  const root2 = join(base, "root2");
  mkdirSync(join(root, "Season 1"), { recursive: true });
  mkdirSync(root2, { recursive: true });
  writeFileSync(join(app, "BUILD"), "9500\n");
  writeFileSync(join(root, "Season 1", "E10.mp4"), "ten");
  writeFileSync(join(root, "Season 1", "E2.mp4"), "two");
  writeFileSync(join(root, "Season 1", "e1.mp4"), "one");
  writeFileSync(join(root, "Season 1", "clip.ogv"), "ogv");
  writeFileSync(join(root, "Season 1", "clip.3GP"), "3gp");
  writeFileSync(join(root, "Season 1", "clip.3g2"), "3g2");
  writeFileSync(join(root, "notes.md"), "# hello\n");
  writeFileSync(join(base, "outside.txt"), "secret-outside");
  symlinkSync(join(base, "outside.txt"), join(root, "out-link"));
  symlinkSync(join(root, "notes.md"), join(root, "in-link"));
  config(data, { updateChannel: "stable", drive: { roots: [] } });

  const s = await launch(data, app);
  try {
    // 1. GET /drive & PUT /drive/roots (config read/write + validation)
    const emptyDrive = await httpJson(s.door, "/admin-api/drive");
    assert.equal(emptyDrive.status, 200, emptyDrive.text);
    assert.deepEqual(emptyDrive.json.roots, []);
    assert.equal(emptyDrive.json.manage, true);
    assert.equal(emptyDrive.json.write, true);
    assert.equal(emptyDrive.json.anywhere, true);
    assert.equal(emptyDrive.json.watch, true);
    assert.equal(emptyDrive.json.zip, true);
    assert.equal(emptyDrive.json.transfers, true);

    // Invalid roots payloads refused
    const badRootsType = await httpJson(s.door, "/admin-api/drive/roots", { method: "PUT", body: { roots: "not-an-array" } });
    assert.equal(badRootsType.status, 400, badRootsType.text);
    assert.equal(badRootsType.json.code, "invalid_request");

    const missingRoot = await httpJson(s.door, "/admin-api/drive/roots", { method: "PUT", body: { roots: [join(base, "no-such-dir")] } });
    assert.equal(missingRoot.status, 404, missingRoot.text);
    assert.equal(missingRoot.json.code, "not_found");

    // Pin roots (deduplicated)
    const pinned = await httpJson(s.door, "/admin-api/drive/roots", { method: "PUT", body: { roots: [root, root2, root] } });
    assert.equal(pinned.status, 200, pinned.text);
    assert.deepEqual(pinned.json.roots.map((r: any) => r.path), [root, root2]);

    // GET /drive/folders lists folders under base
    const folders = await httpJson(s.door, `/admin-api/drive/folders?path=${encodeURIComponent(base)}`);
    assert.equal(folders.status, 200, folders.text);
    const folderNames = (folders.json.entries ?? []).map((e: any) => e.name).sort();
    assert.ok(folderNames.includes("root") && folderNames.includes("root2"), JSON.stringify(folders.json));

    // 2. GET /drive/list: folders first, natural numeric order, MIME types; escaping symlink hidden when anywhere=false
    const top = await httpJson(s.door, `/admin-api/drive/list?root=${encodeURIComponent(root)}&path=`);
    assert.equal(top.status, 200, top.text);
    assert.deepEqual(
      top.json.entries.map((e: any) => [e.name, e.dir]),
      [["Season 1", true], ["in-link", false], ["notes.md", false], ["out-link", false]],
    );
    assert.equal(top.json.entries.find((e: any) => e.name === "notes.md").type, "text/markdown; charset=utf-8");

    const topScoped = await ask(s.door, "drive.list", [root, "", false]);
    assert.deepEqual(
      topScoped.answer.entries.map((e: any) => [e.name, e.dir]),
      [["Season 1", true], ["in-link", false], ["notes.md", false]],
      "escaping symlink hidden when anywhere=false",
    );

    const season = await httpJson(s.door, `/admin-api/drive/list?root=${encodeURIComponent(root)}&path=${encodeURIComponent("Season 1")}`);
    assert.equal(season.status, 200, season.text);
    assert.equal(season.json.path, "Season 1");
    const seasonNames = season.json.entries.map((e: any) => e.name);
    assert.ok(seasonNames.indexOf("e1.mp4") < seasonNames.indexOf("E2.mp4"), JSON.stringify(seasonNames));
    assert.ok(seasonNames.indexOf("E2.mp4") < seasonNames.indexOf("E10.mp4"), JSON.stringify(seasonNames));
    const typeOf = (n: string) => season.json.entries.find((e: any) => e.name === n)?.type;
    assert.deepEqual(
      [typeOf("e1.mp4"), typeOf("clip.ogv"), typeOf("clip.3GP"), typeOf("clip.3g2")],
      ["video/mp4", "video/ogg", "video/3gpp", "video/3gpp2"],
    );

    // 3. GET /drive/stat & GET /drive/read (full, offset/length slice, past EOF, headers, errors)
    const st = await httpJson(s.door, `/admin-api/drive/stat?root=${encodeURIComponent(root)}&path=${encodeURIComponent("notes.md")}`);
    assert.equal(st.status, 200, st.text);
    assert.equal(st.json.name, "notes.md");
    assert.equal(st.json.size, 8);
    assert.equal(st.json.dir, false);

    const slice = await httpRaw(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=${encodeURIComponent("notes.md")}&offset=2&length=3`);
    assert.equal(slice.status, 200, slice.text);
    assert.equal(slice.text, "hel");
    assert.equal(slice.headers["stillfail-total"], "8");
    assert.ok(Number(slice.headers["stillfail-mtime"]) > 0, JSON.stringify(slice.headers));
    assert.equal(slice.headers["cache-control"], "no-store");

    const pastEof = await httpRaw(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=${encodeURIComponent("notes.md")}&offset=100&length=3`);
    assert.equal(pastEof.status, 200);
    assert.equal(pastEof.body.length, 0);
    assert.equal(pastEof.headers["stillfail-total"], "8");

    // In-root symlink readable
    const inLink = await httpRaw(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=in-link`);
    assert.equal(inLink.status, 200);
    assert.equal(inLink.text, "# hello\n");

    const dirRead = await httpJson(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=${encodeURIComponent("Season 1")}`);
    assert.equal(dirRead.status, 409, dirRead.text);
    assert.equal(dirRead.json.code, "is_a_directory");

    const missingRead = await httpJson(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=nothing.txt`);
    assert.equal(missingRead.status, 404, missingRead.text);
    assert.equal(missingRead.json.code, "not_found");

    // 4. Path escape & protected data dir refusal
    for (const bad of ["../outside.txt", "Season 1/../../outside.txt"]) {
      const r = await httpJson(s.door, `/admin-api/drive/read?root=${encodeURIComponent(root)}&path=${encodeURIComponent(bad)}`);
      assert.equal(r.status, 403, `${bad}: ${r.text}`);
      assert.equal(r.json.code, "path_escape", `${bad}: ${r.text}`);
    }
    const outLinkScoped = await ask(s.door, "drive.read", [root, "out-link", 0, 10, false]);
    assert.equal(outLinkScoped.kind, "DriveError", JSON.stringify(outLinkScoped));
    assert.equal(outLinkScoped.error.code, "path_escape", JSON.stringify(outLinkScoped));
    const ownProtected = await httpJson(s.door, `/admin-api/drive/list?root=${encodeURIComponent(data)}&path=`);
    assert.equal(ownProtected.status, 403, ownProtected.text);
    assert.equal(ownProtected.json.code, "protected");

    // Non-root refused when anywhere=false
    const notRoot = await ask(s.door, "drive.list", [base, "", false]);
    assert.equal(notRoot.kind, "DriveError");
    assert.equal(notRoot.error.code, "not_a_root");

    // 5. PUT /drive/upload: chunked upload, { have, entry }, idempotent re-upload, gap -> 409 upload_lost + have, replace
    const upUrl = (p: string, q: string) => `/admin-api/drive/upload?root=${encodeURIComponent(root)}&path=${encodeURIComponent(p)}&${q}`;
    const p1 = await httpJson(s.door, upUrl("Season 1/E3.mp4", "id=up1&offset=0&total=6"), { method: "PUT", body: Buffer.from("abc") });
    assert.equal(p1.status, 200, p1.text);
    assert.equal(p1.json.have, 3, `expected { have: 3, entry: null }, got ${p1.text}`);
    assert.equal(p1.json.entry, null, p1.text);
    assert.equal(existsSync(join(root, "Season 1", "E3.mp4")), false, "partial file must not appear before final chunk");

    // Hidden from listing while uploading
    const midList = await httpJson(s.door, `/admin-api/drive/list?root=${encodeURIComponent(root)}&path=${encodeURIComponent("Season 1")}`);
    assert.ok(!midList.json.entries.some((e: any) => e.name.startsWith(".stillfail-up-")), JSON.stringify(midList.json));

    // Re-uploading same chunk is idempotent
    const p1Again = await httpJson(s.door, upUrl("Season 1/E3.mp4", "id=up1&offset=0&total=6"), { method: "PUT", body: Buffer.from("abc") });
    assert.equal(p1Again.status, 200, p1Again.text);
    assert.equal(p1Again.json.have, 3, p1Again.text);

    // Gap offset rejected with 409 upload_lost + have: 3
    const gap = await httpJson(s.door, upUrl("Season 1/E3.mp4", "id=up1&offset=5&total=6"), { method: "PUT", body: Buffer.from("f") });
    assert.equal(gap.status, 409, gap.text);
    assert.equal(gap.json.code, "upload_lost", gap.text);
    assert.equal(gap.json.have, 3, gap.text);

    // Final chunk completes and commits atomically
    const p2 = await httpJson(s.door, upUrl("Season 1/E3.mp4", "id=up1&offset=3&total=6"), { method: "PUT", body: Buffer.from("def") });
    assert.equal(p2.status, 200, p2.text);
    assert.equal(p2.json.have, 6, p2.text);
    assert.equal(p2.json.entry?.size, 6, p2.text);
    assert.equal(readFileSync(join(root, "Season 1", "E3.mp4"), "utf8"), "abcdef");
    assert.deepEqual(readdirSync(join(root, "Season 1")).filter((n) => n.startsWith(".stillfail-up-")), []);

    // Existing file rejected without replace=1, overwritten with replace=1
    const existsRefused = await httpJson(s.door, upUrl("notes.md", "id=up2&offset=0&total=1"), { method: "PUT", body: Buffer.from("x") });
    assert.equal(existsRefused.status, 409, existsRefused.text);
    assert.equal(existsRefused.json.code, "exists");

    const replaced = await httpJson(s.door, upUrl("notes.md", "id=up3&offset=0&total=2&replace=1"), { method: "PUT", body: Buffer.from("ok") });
    assert.equal(replaced.status, 200, replaced.text);
    assert.equal(readFileSync(join(root, "notes.md"), "utf8"), "ok");

    // 6. mkdir, rename, zip, stage, remove
    const mk = await httpJson(s.door, "/admin-api/drive/mkdir", { method: "POST", body: { root, path: "created-dir" } });
    assert.equal(mk.status, 200, mk.text);
    assert.equal(mk.json.name, "created-dir");
    assert.equal(mk.json.dir, true);

    const ren = await httpJson(s.door, "/admin-api/drive/rename", { method: "POST", body: { root, from: "created-dir", to: "renamed-dir" } });
    assert.equal(ren.status, 200, ren.text);
    assert.equal(ren.json.name, "renamed-dir");
    assert.equal(existsSync(join(root, "renamed-dir")), true);
    assert.equal(existsSync(join(root, "created-dir")), false);

    // zip folder
    const zipped = await httpJson(s.door, "/admin-api/drive/zip", { method: "POST", body: { root, path: "Season 1" } });
    assert.equal(zipped.status, 200, zipped.text);
    assert.equal(zipped.json.name, "Season 1.zip");
    assert.ok(zipped.json.size > 0, zipped.text);

    // stage file & zipped folder
    const staged = await httpJson(s.door, "/admin-api/drive/stage", { method: "POST", body: { root, path: "notes.md", zip: false } });
    assert.equal(staged.status, 200, staged.text);
    assert.equal(staged.json.name, "notes.md");
    assert.equal(readFileSync(staged.json.path, "utf8"), "ok");

    const stagedZip = await httpJson(s.door, "/admin-api/drive/stage", { method: "POST", body: { root, path: "Season 1", zip: true } });
    assert.equal(stagedZip.status, 200, stagedZip.text);
    assert.equal(stagedZip.json.name, "Season 1.zip");
    assert.equal(readFileSync(stagedZip.json.path).subarray(0, 2).toString("latin1"), "PK");

    // remove (permanent)
    const rem = await httpJson(s.door, "/admin-api/drive/remove", { method: "POST", body: { root, path: "renamed-dir", permanent: true } });
    assert.equal(rem.status, 200, rem.text);
    assert.equal(existsSync(join(root, "renamed-dir")), false);
  } finally {
    await s.stop();
  }
});

test("drive parity: large chunked transfers (copy, conflicts keep/replace/skip, move, self-escape guards) and folder watch SSE + poll", { skip }, async () => {
  const data = fresh("drv-tx");
  const app = fresh("drv-tx-app");
  const root = fresh("drv-tx-root");
  writeFileSync(join(app, "BUILD"), "9500\n");
  mkdirSync(join(root, "src", "deep"), { recursive: true });
  mkdirSync(join(root, "dst"), { recursive: true });
  mkdirSync(join(root, "watched"), { recursive: true });
  const big = randomBytes(320 * 1024); // > 256 KiB multi-chunk payload
  writeFileSync(join(root, "src", "big.bin"), big);
  writeFileSync(join(root, "src", "a.txt"), "new-a");
  writeFileSync(join(root, "src", "deep", "b.txt"), "nested-b");
  writeFileSync(join(root, "dst", "a.txt"), "old-a");
  config(data, { updateChannel: "stable", drive: { roots: [root] } });

  const s = await launch(data, app);
  try {
    // 1. Grant signing route
    const granted = await httpJson(s.door, "/admin-api/drive/grant", {
      method: "POST",
      body: { root, path: "src", names: ["big.bin", "a.txt"], move: false },
    });
    assert.equal(granted.status, 200, granted.text);
    assert.equal(typeof granted.json.grant, "string");
    assert.ok(granted.json.grant.length > 20);
    assert.ok(granted.json.expires > Date.now());

    // 2. Large chunked transfer copy with conflict policy: keep
    const started = await httpJson(s.door, "/admin-api/drive/transfers", {
      method: "POST",
      body: {
        from: { root, path: "src", names: ["big.bin", "a.txt", "deep"] },
        to: { root, path: "dst" },
        conflicts: { "a.txt": "keep" },
      },
    });
    assert.equal(started.status, 200, started.text);
    const tid = started.json.transfer.id as string;
    assert.ok(tid, started.text);

    const done = await given("transfer done", async () => {
      const list = await httpJson(s.door, "/admin-api/drive/transfers");
      assert.equal(list.status, 200, list.text);
      const t = (list.json.transfers ?? []).find((x: any) => x.id === tid);
      return t && (t.state === "done" || t.state === "failed") ? t : null;
    });
    assert.equal(done.state, "done", JSON.stringify(done));
    assert.equal(Buffer.compare(readFileSync(join(root, "dst", "big.bin")), big), 0, "large file copied byte-for-byte");
    assert.equal(readFileSync(join(root, "dst", "a.txt"), "utf8"), "old-a");
    assert.equal(readFileSync(join(root, "dst", "a 2.txt"), "utf8"), "new-a");
    assert.equal(readFileSync(join(root, "dst", "deep", "b.txt"), "utf8"), "nested-b");
    assert.equal(existsSync(join(root, "src", "big.bin")), true, "copy keeps source");

    // 3. Unresolved conflict fails without overwriting
    const conflictFail = await httpJson(s.door, "/admin-api/drive/transfers", {
      method: "POST",
      body: {
        from: { root, path: "src", names: ["a.txt"] },
        to: { root, path: "dst" },
      },
    });
    assert.equal(conflictFail.status, 200, conflictFail.text);
    const failId = conflictFail.json.transfer.id as string;
    const failed = await given("conflict transfer failed", async () => {
      const list = await httpJson(s.door, "/admin-api/drive/transfers");
      const t = (list.json.transfers ?? []).find((x: any) => x.id === failId);
      return t && (t.state === "done" || t.state === "failed") ? t : null;
    });
    assert.equal(failed.state, "failed", JSON.stringify(failed));
    assert.equal(readFileSync(join(root, "dst", "a.txt"), "utf8"), "old-a");

    // 4. Move transfer removes source after copy
    writeFileSync(join(root, "src", "move-me.txt"), "moving");
    const moved = await httpJson(s.door, "/admin-api/drive/transfers", {
      method: "POST",
      body: {
        move: true,
        from: { root, path: "src", names: ["move-me.txt"] },
        to: { root, path: "dst" },
      },
    });
    assert.equal(moved.status, 200, moved.text);
    const moveId = moved.json.transfer.id as string;
    const moveDone = await given("move transfer done", async () => {
      const list = await httpJson(s.door, "/admin-api/drive/transfers");
      const t = (list.json.transfers ?? []).find((x: any) => x.id === moveId);
      return t && (t.state === "done" || t.state === "failed") ? t : null;
    });
    assert.equal(moveDone.state, "done", JSON.stringify(moveDone));
    assert.equal(readFileSync(join(root, "dst", "move-me.txt"), "utf8"), "moving");
    assert.equal(existsSync(join(root, "src", "move-me.txt")), false, "move removes original");

    // 5. Folder watch SSE (`Accept: text/event-stream`): detects newly created file
    let sseBuf = "";
    const sseReq = request({
      host: "127.0.0.1",
      port: s.door,
      path: `/admin-api/drive/watch?root=${encodeURIComponent(root)}&path=watched`,
      method: "GET",
      headers: { accept: "text/event-stream" },
    });
    const sseStatus = await new Promise<number>((resolve, reject) => {
      sseReq.on("response", (res) => {
        res.on("data", (d) => (sseBuf += d.toString("utf8")));
        resolve(res.statusCode!);
      });
      sseReq.on("error", reject);
      sseReq.end();
    });
    assert.equal(sseStatus, 200);
    // Write a file into watched folder and wait for `event: changed`
    writeFileSync(join(root, "watched", "trigger.txt"), "ping");
    await given("SSE drive/watch changed event", () => sseBuf.includes("event: changed"), 10_000);
    sseReq.destroy();

    // 6. Folder watch long-poll (`GET /drive/watch?id=...`) detects subsequent change
    const pollPromise = httpJson(s.door, `/admin-api/drive/watch?root=${encodeURIComponent(root)}&path=watched&id=poll-1`);
    // Wait briefly so the watcher establishes its baseline, then mutate
    setTimeout(() => writeFileSync(join(root, "watched", "trigger-2.txt"), "pong"), 300);
    const polled = await pollPromise;
    assert.equal(polled.status, 200, polled.text);
    assert.equal(polled.json.changed, true, polled.text);
  } finally {
    await s.stop();
  }
});

// ============================================================================
// Domain 2: Screens / Helper / Permissions (Admin API + MCP tools)
// ============================================================================

test("screens, helper & permissions parity: Admin API routes and screen / permissions / computer MCP tool contracts", { skip }, async () => {
  const data = fresh("scr-data");
  const app = fresh("scr-app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  config(data, { updateChannel: "stable" });

  const s = await launch(data, app);
  try {
    seedSession(data, "s-scr", "t-scr", "ws1", "alice@example.com", "1795000001.000100");

    // 1. GET /admin-api/screens
    const listed = await httpJson(s.door, "/admin-api/screens");
    assert.equal(listed.status, 200, listed.text);
    assert.ok(Array.isArray(listed.json.screens), listed.text);
    const desktop = listed.json.screens.find((x: any) => x.id === "desktop");
    assert.ok(desktop, `desktop screen should be listed: ${listed.text}`);
    assert.equal(desktop.kind, "desktop");
    assert.equal(typeof desktop.title, "string");
    assert.ok(Array.isArray(desktop.viewers), listed.text);
    assert.ok(Array.isArray(desktop.controlledBy), listed.text);
    assert.ok(Array.isArray(desktop.views), listed.text);

    // 2. POST /admin-api/screens/browser validation
    const badUrl = await httpJson(s.door, "/admin-api/screens/browser", { method: "POST", body: {} });
    assert.equal(badUrl.status, 400, badUrl.text);
    const badId = await httpJson(s.door, "/admin-api/screens/browser", {
      method: "POST",
      body: { url: "https://example.com", id: "not-valid-id" },
    });
    assert.equal(badId.status, 400, badId.text);
    assert.match(badId.text, /u_ and 12 hex digits/);

    // 3. Unknown screen id routes return 404 (not 500)
    for (const [method, path, body] of [
      ["POST", "/admin-api/screens/no-such-screen/close", {}],
      ["POST", "/admin-api/screens/no-such-screen/reload", {}],
      ["POST", "/admin-api/screens/no-such-screen/back", {}],
      ["POST", "/admin-api/screens/no-such-screen/forward", {}],
      ["POST", "/admin-api/screens/no-such-screen/sleep", {}],
      ["POST", "/admin-api/screens/no-such-screen/open-url", { url: "https://example.com" }],
      ["POST", "/admin-api/screens/no-such-screen/views/end", {}],
      ["GET", "/admin-api/screens/no-such-screen/logs", undefined],
      ["GET", "/admin-api/screens/no-such-screen/apps", undefined],
      ["GET", "/admin-api/screens/no-such-screen/settings", undefined],
      ["POST", "/admin-api/screens/no-such-screen/screenshot", {}],
      ["GET", "/admin-api/screens/no-such-screen/chrome/0/0", undefined],
    ] as const) {
      const r = await httpJson(s.door, path, { method, body });
      assert.equal(r.status, 404, `${method} ${path} -> ${r.status} ${r.text}`);
    }

    // 4. POST /admin-api/permissions/request (on macOS; 404 on non-macOS)
    if (process.platform === "darwin") {
      const badGrant = await httpJson(s.door, "/admin-api/permissions/request", {
        method: "POST",
        body: { grant: "not-a-grant" },
      });
      assert.equal(badGrant.status, 400, badGrant.text);

      // Without still.fail Helper.app installed in isolated app/env, requesting capture must return 503 (noHelper / none), never 200 {} or 500
      const noHelper = await httpJson(s.door, "/admin-api/permissions/request", {
        method: "POST",
        body: { grant: "capture" },
      });
      assert.equal(noHelper.status, 503, `expected 503 when Helper unavailable, got ${noHelper.status}: ${noHelper.text}`);
      assert.equal(typeof noHelper.json?.error, "string", noHelper.text);
    }

    // 5. `screen` MCP tool contract
    const scrList = await mcpCall(s.door, "t-scr", "screen", {});
    assert.equal(scrList.isError, false, scrList.text);
    assert.match(scrList.text, /"id":\s*"desktop"/, scrList.text);
    assert.match(scrList.text, /"kind":\s*"desktop"/, scrList.text);

    const scrMissing = await mcpCall(s.door, "t-scr", "screen", { id: "missing-id" });
    assert.equal(scrMissing.isError, true, scrMissing.text);
    assert.match(scrMissing.text, /no screen missing-id on this station/);

    const scrBadAction = await mcpCall(s.door, "t-scr", "screen", { action: "bogus", id: "desktop" });
    assert.equal(scrBadAction.isError, true, scrBadAction.text);
    assert.match(scrBadAction.text, /no action bogus/);

    const scrNoId = await mcpCall(s.door, "t-scr", "screen", { action: "take_control" });
    assert.equal(scrNoId.isError, true, scrNoId.text);
    assert.match(scrNoId.text, /take_control needs id/);

    const scrNoView = await mcpCall(s.door, "t-scr", "screen", { action: "disconnect", id: "desktop" });
    assert.equal(scrNoView.isError, true, scrNoView.text);
    assert.match(scrNoView.text, /disconnect needs view/);

    // 6. `permissions` MCP tool contract
    const permList = await mcpCall(s.door, "t-scr", "permissions", {});
    assert.equal(permList.isError, false, permList.text);
    if (process.platform === "darwin") {
      assert.match(permList.text, /still\.fail Helper/, permList.text);

      const permBad = await mcpCall(s.door, "t-scr", "permissions", { request: "invalid-grant" });
      assert.equal(permBad.isError, true, permBad.text);
      assert.match(permBad.text, /no grant invalid-grant/, permBad.text);

      // Without Helper, requesting capture must refuse cleanly (not claim window is up!)
      const permNoHelper = await mcpCall(s.door, "t-scr", "permissions", { request: "capture" });
      assert.equal(permNoHelper.isError, true, `expected refusal without Helper, got: ${permNoHelper.text}`);
      assert.doesNotMatch(permNoHelper.text, /window asking for .* is up/, permNoHelper.text);
    } else {
      assert.match(permList.text, /not a Mac/, permList.text);
    }

    // 7. `computer` MCP tool contract (parameter validation + unknown screen + no-permission refusal)
    const compMissingScreen = await mcpCall(s.door, "t-scr", "computer", { screen: "nonexistent", action: "screenshot" });
    assert.equal(compMissingScreen.isError, true, compMissingScreen.text);
    assert.match(compMissingScreen.text, /no screen nonexistent/, compMissingScreen.text);

    const compBadAction = await mcpCall(s.door, "t-scr", "computer", { screen: "desktop", action: "teleport" });
    assert.equal(compBadAction.isError, true, compBadAction.text);

    const compBadKey = await mcpCall(s.door, "t-scr", "computer", { screen: "desktop", action: "key", key: "bogus+unknownkeyname" });
    assert.equal(compBadKey.isError, true, compBadKey.text);

    const compNoText = await mcpCall(s.door, "t-scr", "computer", { screen: "desktop", action: "type" });
    assert.equal(compNoText.isError, true, compNoText.text);

    // Screenshot on desktop without Helper/capture permission refuses cleanly
    const compShot = await mcpCall(s.door, "t-scr", "computer", { screen: "desktop", action: "screenshot" });
    assert.equal(compShot.isError, true, `expected screenshot refusal without Helper/display: ${compShot.text}`);
  } finally {
    await s.stop();
  }
});

// ============================================================================
// Domain 3: Browser / Farview / Sign-in (MCP tools, WS door, sign-ins API & outbox)
// ============================================================================

test("browser & sign-in parity: browser MCP tool, /browser WS door, sign_in MCP tool, /admin-api/browser/sign-ins/* & card_outbox", { skip }, async () => {
  const data = fresh("br-data");
  const app = fresh("br-app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin: "http://127.0.0.1:9",
      station: "st-track-g",
      workspace: "ws1",
      workspace_name: "W",
      name: "track-g",
      relay_url: "",
      relay_urls: [],
      grant_keys: null,
      peers: [],
      revocations: [],
    }),
  );
  config(data, { updateChannel: "stable", browser: { farview: false } });

  const s = await launch(data, app);
  try {
    const threadId = seedSession(data, "s-br", "t-br", "ws1", "", "1795000002.000100");
    const aliceThread = seedSession(data, "s-alice", "t-alice", "ws1", "alice@example.com", "1795000002.000200");

    // 1. `browser` MCP tool: status, tabs, stop, chrome-only refusals, unknown action, farview disabled
    const st0 = await mcpCall(s.door, "t-br", "browser", { action: "status" });
    assert.equal(st0.isError, false, st0.text);
    assert.match(st0.text, /Not running/);

    const tabs0 = await mcpCall(s.door, "t-br", "browser", { action: "tabs" });
    assert.equal(tabs0.isError, false, tabs0.text);
    assert.match(tabs0.text, /No tabs open/);

    const stopped = await mcpCall(s.door, "t-br", "browser", { action: "stop" });
    assert.equal(stopped.isError, false, stopped.text);
    assert.match(stopped.text, /browser is closed/);

    for (const act of ["open", "close"] as const) {
      const r = await mcpCall(s.door, "t-br", "browser", { action: act });
      assert.equal(r.isError, true, r.text);
      assert.match(r.text, /is Farview's/);
    }

    const badAct = await mcpCall(s.door, "t-br", "browser", { action: "explode" });
    assert.equal(badAct.isError, true, badAct.text);
    assert.match(badAct.text, /unknown action explode/);

    const noFarview = await mcpCall(s.door, "t-br", "browser", { action: "status", engine: "farview" });
    assert.equal(noFarview.isError, true, noFarview.text);
    assert.match(noFarview.text, /no Farview/);

    // ui-ask parity with browser.status / browser.tabs
    const uiStatus = await ask(s.door, "browser.status", ["s-br"]);
    assert.equal(uiStatus.answer?.running, false, JSON.stringify(uiStatus));
    const uiTabs = await ask(s.door, "browser.tabs", ["s-br"]);
    assert.deepEqual(uiTabs.answer, [], JSON.stringify(uiTabs));

    // 2. `/browser/<session>` WebSocket door boundary checks
    const nonWs = await httpRaw(s.door, "/browser/c2Vzc2lvbg");
    assert.equal(nonWs.status, 400);
    assert.match(nonWs.text, /WebSocket/);

    const noKey = await httpRaw(s.door, "/browser/c2Vzc2lvbg", {
      headers: { upgrade: "websocket", connection: "Upgrade" },
    });
    assert.equal(noKey.status, 400);
    assert.match(noKey.text, /Sec-WebSocket-Key/);

    const badSessionPath = await httpRaw(s.door, "/browser/", {
      headers: { upgrade: "websocket", connection: "Upgrade", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==" },
    });
    assert.ok(badSessionPath.status === 400 || badSessionPath.status === 404, `expected 400/404, got ${badSessionPath.status}: ${badSessionPath.text}`);

    // 3. `sign_in` MCP tool boundary checks
    const badSite = await mcpCall(s.door, "t-br", "sign_in", { site: "localhost", reason: "test" });
    assert.equal(badSite.isError, true, badSite.text);
    assert.match(badSite.text, /site is the site's host/);

    const emptySite = await mcpCall(s.door, "t-br", "sign_in", { site: "", reason: "test" });
    assert.equal(emptySite.isError, true, emptySite.text);
    assert.match(emptySite.text, /site is the site's host/);

    // No starter on s-br refuses with "No one started this chat"
    const noOwner = await mcpCall(s.door, "t-br", "sign_in", { site: "example.com", reason: "test sign in" });
    assert.equal(noOwner.isError, true, noOwner.text);
    assert.match(noOwner.text, /No one started this chat/);

    // Starter present (alice), but no open tab on example.com
    const noTab = await mcpCall(s.door, "t-alice", "sign_in", { site: "example.com", reason: "test sign in" });
    assert.equal(noTab.isError, true, noTab.text);
    assert.match(noTab.text, /open|tab|browser/i, noTab.text);

    // 4. `/admin-api/browser/sign-ins/:id/{fill,self,deny}` unknown id -> 409 signin_refused
    for (const action of ["fill", "self", "deny"] as const) {
      const r = await httpJson(s.door, `/admin-api/browser/sign-ins/g_missing/${action}`, { method: "POST", body: {} });
      assert.equal(r.status, 409, `${action}: ${r.text}`);
      assert.equal(r.json.code, "signin_refused", r.text);
      assert.match(r.json.error, /no such sign-in/);
    }

    // 5. Real sign-in card lifecycle & card_outbox replay through Admin API
    const db = new DatabaseSync(join(data, "stillfail.db"));
    const nowSec = Math.floor(Date.now() / 1000);
    const seedSignin = (id: string, session: string, owner: string, thread: number, cardTs: string, n: number) => {
      db.prepare("INSERT INTO entries(thread,n,kind,ts,author_kind,author,text,at,card) VALUES(?,?,'message',?,'agent',?,'sign in',?,?)")
        .run(thread, n, cardTs, session, Date.now(), JSON.stringify({ type: "options", signin: { id, site: "example.com", reason: "parity test" } }));
      const body = { id, session, chat: session, owner, site: "example.com", tab: "T1", reason: "parity test", at: nowSec, status: "pending", thread, cardTs };
      db.prepare("INSERT INTO signin_asks(id,session,owner,status,body) VALUES(?,?,?,?,?)")
        .run(id, session, owner, "pending", JSON.stringify(body));
    };
    seedSignin("g_deny_1", "s-br", "", threadId, "1795000002.000101", 10);
    seedSignin("g_self_1", "s-br", "", threadId, "1795000002.000102", 11);
    seedSignin("g_other_1", "s-alice", "alice@example.com", aliceThread, "1795000002.000201", 10);
    db.close();

    // Non-owner / wrong workspace refused on g_other_1
    const wrongOwner = await httpJson(s.door, "/admin-api/browser/sign-ins/g_other_1/deny", { method: "POST", body: {} });
    assert.equal(wrongOwner.status, 409, wrongOwner.text);
    assert.equal(wrongOwner.json.code, "signin_refused");

    // Owner denies g_deny_1 -> status=denied, closed_cards updated, card_outbox drains to edit entry with outcome.status="denied"
    const denied = await httpJson(s.door, "/admin-api/browser/sign-ins/g_deny_1/deny", { method: "POST", body: {} });
    assert.equal(denied.status, 200, denied.text);
    assert.deepEqual(denied.json, { ok: true });

    const denyAsk = await ask(s.door, "signIns.get", ["g_deny_1"]);
    assert.equal(denyAsk.answer?.status, "denied", JSON.stringify(denyAsk));

    // Re-denying an already denied ask returns 409
    const deniedAgain = await httpJson(s.door, "/admin-api/browser/sign-ins/g_deny_1/deny", { method: "POST", body: {} });
    assert.equal(deniedAgain.status, 409, deniedAgain.text);
    assert.match(deniedAgain.json.error, /denied already/);

    // Verify closed_cards & card_outbox drain wrote the edit entry with signin.outcome = { status: "denied" }
    const deniedOutcome = await given("denied card outcome edit written", () => {
      const ro = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
      try {
        const closed = ro.prepare("SELECT COUNT(*) AS c FROM closed_cards WHERE thread = ? AND n = 10").get(threadId) as { c: number };
        if (closed.c !== 1) return null;
        const edit = ro.prepare("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND target = 10 ORDER BY n DESC LIMIT 1").get(threadId) as { card: string } | undefined;
        if (!edit?.card) return null;
        return JSON.parse(edit.card).signin?.outcome ?? null;
      } finally {
        ro.close();
      }
    });
    assert.deepEqual(deniedOutcome, { status: "denied" });

    // Owner takes over g_self_1 (done: false -> status="person"), then finishes (done: true -> status="left")
    const selfStart = await httpJson(s.door, "/admin-api/browser/sign-ins/g_self_1/self", { method: "POST", body: { done: false } });
    assert.equal(selfStart.status, 200, selfStart.text);
    assert.equal((await ask(s.door, "signIns.get", ["g_self_1"])).answer?.status, "person");

    const selfDone = await httpJson(s.door, "/admin-api/browser/sign-ins/g_self_1/self", { method: "POST", body: { done: true } });
    assert.equal(selfDone.status, 200, selfDone.text);
    assert.equal((await ask(s.door, "signIns.get", ["g_self_1"])).answer?.status, "left");

    const selfOutcome = await given("self card outcome edit written", () => {
      const ro = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
      try {
        const edit = ro.prepare("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND target = 11 ORDER BY n DESC LIMIT 1").get(threadId) as { card: string } | undefined;
        if (!edit?.card) return null;
        const out = JSON.parse(edit.card).signin?.outcome;
        return out?.status === "left" ? out : null;
      } finally {
        ro.close();
      }
    });
    assert.deepEqual(selfOutcome, { status: "left" });
  } finally {
    await s.stop();
  }
});
