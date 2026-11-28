import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";

// `stillfail admin` (bin/stillfail, bin/stillfail.ps1) runs Node's admin CLI wherever a release or a clone has Node and
// it, and the MoonBit reader's port only when STILLFAIL_ADMIN_ENGINE=moonbit asks for it or a release has no Node or no
// admin CLI: a reader shipped beside Node must not take every admin command from it.

const root = fileURLToPath(new URL("..", import.meta.url));
const unix = process.platform !== "win32";
const skipUnix = unix ? false : "bin/stillfail is the Unix command (bin/stillfail.ps1 is Windows')";

interface Run {
  code: number;
  stdout: string;
  stderr: string;
}

function run(file: string, args: string[], env: Record<string, string>, cwd?: string): Promise<Run> {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { env, cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => { stdout += d.toString("utf8"); });
    child.stderr.on("data", (d: Buffer) => { stderr += d.toString("utf8"); });
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

// A PATH with only what bin/stillfail's admin branch calls, so that no node is found on it unless a test puts one.
function toolsDir(base: string): string {
  const dir = join(base, "tools");
  mkdirSync(dir);
  for (const tool of ["readlink", "dirname", "basename"]) {
    const at = ["/usr/bin", "/bin"].map((d) => join(d, tool)).find((p) => existsSync(p));
    assert.ok(at, `${tool} is on this machine`);
    symlinkSync(at, join(dir, tool));
  }
  return dir;
}

// What a fake entry saw: which one ran, its arguments, the two variables the command gives it.
const reportJs = (who: string) => `
const out = { who: ${JSON.stringify(who)}, args: process.argv.slice(2), cmd: process.env.STILLFAIL_CMD ?? null, data: process.env.STILLFAIL_DATA ?? null, ...(process.env.FAKE_CWD ? { cwd: process.cwd() } : {}) };
process.stdout.write(JSON.stringify(out) + "\\n");
process.stderr.write("to stderr from " + ${JSON.stringify(who)} + "\\n");
process.exitCode = Number(process.env.FAKE_EXIT ?? "0");
`;

const readerSh = `#!/bin/sh
{
  printf '%s\\n' "reader"
  printf 'cmd=%s\\n' "\${STILLFAIL_CMD:-}"
  printf 'data=%s\\n' "\${STILLFAIL_DATA:-}"
  for a in "$@"; do printf 'arg=%s\\n' "$a"; done
} > "$FAKE_READER_LOG"
echo "reader ran" >&2
exit "\${FAKE_EXIT:-0}"
`;

interface Layout {
  app: string;
  data: string;
  readerLog: string;
  base: string;
  tools: string;
}

// An app directory laid out as a release (station/admin-cli.js, station/stillfail-reader, node/bin/node) or as a clone
// (bin/admin-cli.ts), each part only when asked for.
function layout(t: TestContext, parts: { js?: boolean; ts?: boolean; reader?: boolean; node?: boolean }): Layout {
  const base = mkdtempSync(join(tmpdir(), "sf-admin-wrapper-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const app = join(base, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(join(root, "bin", "stillfail"), join(app, "bin", "stillfail"));
  chmodSync(join(app, "bin", "stillfail"), 0o755);
  if (parts.js) writeFileSync(join(app, "station", "admin-cli.js"), reportJs("admin-cli.js"));
  // Type annotations: Node runs the clone's TypeScript as it is.
  if (parts.ts) writeFileSync(join(app, "bin", "admin-cli.ts"), `const typed: string = "ts";\nvoid typed;\n${reportJs("admin-cli.ts")}`);
  if (parts.reader) {
    writeFileSync(join(app, "station", "stillfail-reader"), readerSh);
    chmodSync(join(app, "station", "stillfail-reader"), 0o755);
  }
  if (parts.node) {
    mkdirSync(join(app, "node", "bin"), { recursive: true });
    symlinkSync(process.execPath, join(app, "node", "bin", "node"));
  }
  const data = join(base, "data dir");
  mkdirSync(data);
  return { app, data, readerLog: join(base, "reader.log"), base, tools: toolsDir(base) };
}

function envFor(l: Layout, more: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: l.tools,
    HOME: l.base,
    STILLFAIL_DATA: l.data,
    FAKE_READER_LOG: l.readerLog,
    ...more,
  };
}

const args = ["users", "get", "a b@example.test", "--json", "--origin", "http://x y"];

function parseReport(stdout: string): { who: string; args: string[]; cmd: string | null; data: string | null } {
  const line = stdout.trim().split("\n")[0]!;
  return JSON.parse(line);
}

test("a release with Node, admin-cli.js and the reader runs admin-cli.js, never the reader", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true, node: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l, { FAKE_EXIT: "3" }));
  assert.equal(r.code, 3, r.stderr);
  assert.deepEqual(parseReport(r.stdout), { who: "admin-cli.js", args, cmd: "stillfail", data: l.data });
  assert.equal(r.stderr, "to stderr from admin-cli.js\n");
  assert.equal(existsSync(l.readerLog), false, "the reader did not run");
});

test("Node is taken from STILLFAIL_NODE or the PATH where the release has none of its own", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true });
  const byEnv = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l, { STILLFAIL_NODE: process.execPath }));
  assert.equal(byEnv.code, 0, byEnv.stderr);
  assert.equal(parseReport(byEnv.stdout).who, "admin-cli.js");
  symlinkSync(process.execPath, join(l.tools, "node"));
  const byPath = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l));
  assert.equal(byPath.code, 0, byPath.stderr);
  assert.deepEqual(parseReport(byPath.stdout), { who: "admin-cli.js", args, cmd: "stillfail", data: l.data });
  assert.equal(existsSync(l.readerLog), false, "the reader did not run");
});

test("called as another product's command, admin-cli is told that command's name", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true, node: true });
  const link = join(l.base, "links", "monoid");
  mkdirSync(dirname(link));
  symlinkSync(join(l.app, "bin", "stillfail"), link);
  const r = await run(link, ["admin", ...args], envFor(l));
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(parseReport(r.stdout), { who: "admin-cli.js", args, cmd: "monoid", data: l.data });
});

test("a clone (bin/admin-cli.ts, no station/admin-cli.js) runs admin-cli.ts", { skip: skipUnix }, async (t) => {
  const l = layout(t, { ts: true, reader: true, node: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l, { FAKE_EXIT: "2" }));
  assert.equal(r.code, 2, r.stderr);
  assert.deepEqual(parseReport(r.stdout), { who: "admin-cli.ts", args, cmd: "stillfail", data: l.data });
  assert.equal(r.stderr, "to stderr from admin-cli.ts\n");
  assert.equal(existsSync(l.readerLog), false, "the reader did not run");
});

test("station/admin-cli.js is taken before bin/admin-cli.ts where both are there", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, ts: true, node: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(parseReport(r.stdout).who, "admin-cli.js");
});

function readerSaw(l: Layout): string[] {
  return readFileSync(l.readerLog, "utf8").trimEnd().split("\n");
}

test("a release with no admin CLI runs the reader, told --data before the person's arguments", { skip: skipUnix }, async (t) => {
  const l = layout(t, { reader: true, node: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l, { FAKE_EXIT: "4" }));
  assert.equal(r.code, 4, r.stderr);
  assert.equal(r.stdout, "");
  assert.equal(r.stderr, "reader ran\n");
  assert.deepEqual(readerSaw(l), ["reader", "cmd=stillfail", `data=${l.data}`, "arg=admin", "arg=--data", `arg=${l.data}`, ...args.map((a) => `arg=${a}`)]);
});

test("a release with admin-cli.js but no Node anywhere runs the reader", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l));
  assert.equal(r.code, 0, r.stderr);
  assert.deepEqual(readerSaw(l), ["reader", "cmd=stillfail", `data=${l.data}`, "arg=admin", "arg=--data", `arg=${l.data}`, "arg=whoami"]);
});

test("STILLFAIL_ADMIN_ENGINE=moonbit runs the reader where Node and admin-cli.js are there", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, ts: true, reader: true, node: true });
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", ...args], envFor(l, { STILLFAIL_ADMIN_ENGINE: "moonbit", FAKE_EXIT: "5" }));
  assert.equal(r.code, 5, r.stderr);
  assert.equal(r.stdout, "");
  assert.deepEqual(readerSaw(l), ["reader", "cmd=stillfail", `data=${l.data}`, "arg=admin", "arg=--data", `arg=${l.data}`, ...args.map((a) => `arg=${a}`)]);
});

test("STILLFAIL_MB_READER names the reader the fallback runs", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, node: true });
  const reader = join(l.base, "elsewhere", "reader");
  mkdirSync(dirname(reader));
  writeFileSync(reader, readerSh);
  chmodSync(reader, 0o755);
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l, { STILLFAIL_ADMIN_ENGINE: "moonbit", STILLFAIL_MB_READER: reader }));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(readerSaw(l)[0], "reader");
});

test("what cannot run says what is missing and how to go on, exit 1; an unknown engine exits 2", { skip: skipUnix }, async (t) => {
  const none = layout(t, { node: true });
  const neither = await run(join(none.app, "bin", "stillfail"), ["admin", "whoami"], envFor(none));
  assert.equal(neither.code, 1);
  assert.match(neither.stderr, /^stillfail admin: neither Node with admin-cli .* nor .*stillfail-reader is here; reinstall still\.fail\n$/);

  const noReader = layout(t, { js: true, node: true });
  const moonbit = await run(join(noReader.app, "bin", "stillfail"), ["admin", "whoami"], envFor(noReader, { STILLFAIL_ADMIN_ENGINE: "moonbit" }));
  assert.equal(moonbit.code, 1);
  assert.match(moonbit.stderr, /^stillfail admin: STILLFAIL_ADMIN_ENGINE=moonbit, but .*stillfail-reader is not there \(unset it to use Node's admin-cli\)\n$/);

  const readerOnly = layout(t, { reader: true });
  const node = await run(join(readerOnly.app, "bin", "stillfail"), ["admin", "whoami"], envFor(readerOnly, { STILLFAIL_ADMIN_ENGINE: "node" }));
  assert.equal(node.code, 1);
  assert.match(node.stderr, /^stillfail admin: STILLFAIL_ADMIN_ENGINE=node, but no Node with admin-cli in .* \(unset it to use .*stillfail-reader\)\n$/);
  assert.equal(existsSync(readerOnly.readerLog), false, "the reader did not run");

  const bad = await run(join(readerOnly.app, "bin", "stillfail"), ["admin", "whoami"], envFor(readerOnly, { STILLFAIL_ADMIN_ENGINE: "rust" }));
  assert.equal(bad.code, 2);
  assert.equal(bad.stderr, "stillfail admin: STILLFAIL_ADMIN_ENGINE must be node or moonbit, not rust\n");
});

// This clone's own command and admin CLI against a cloud on 127.0.0.1: what `stillfail admin` prints and exits with is
// what admin-cli.ts run directly prints and exits with.
test("bin/stillfail admin is bin/admin-cli.ts run directly, against a local cloud", { skip: skipUnix }, async (t) => {
  const calls: string[] = [];
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    calls.push(`${req.method} ${req.url} ${req.headers.authorization ?? ""}`);
    const send = (status: number, body: unknown) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.headers.authorization !== "Bearer sfa_wrapper_key") return send(401, { error: "unauthorized" });
    if (req.method === "GET" && req.url === "/v1/admin/me") return send(200, { email: "ops@example.test", key: { id: "ak_1", name: "Ops", prefix: "sfa_wrapper" } });
    return send(404, { error: "not_found" });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());
  const origin = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const base = mkdtempSync(join(tmpdir(), "sf-admin-wrapper-real-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const data = join(base, "data");
  mkdirSync(data);
  // No proxy of this machine's in between; no reader of this clone's taken even where one is built.
  const env = {
    PATH: [dirname(process.execPath), "/usr/bin", "/bin"].join(delimiter),
    HOME: base,
    STILLFAIL_NODE: process.execPath,
    STILLFAIL_MB_READER: join(base, "no-reader"),
    STILLFAIL_DATA: data,
  };
  const cases: { argv: string[]; env?: Record<string, string> }[] = [
    { argv: ["--origin", origin, "--key", "sfa_wrapper_key", "whoami"] },
    { argv: ["--origin", origin, "--key", "sfa_wrapper_key", "--json", "whoami"] },
    { argv: ["--origin", origin, "whoami"], env: { STILLFAIL_ADMIN_KEY: "sfa_wrong" } },
    { argv: ["--origin", origin, "--key", "sfa_wrapper_key", "feedback", "get", "FB-1"] },
    { argv: ["--origin", origin, "whoami"] },
    { argv: ["--origin"] },
    { argv: ["--key", "sfa_wrapper_key", "users", "list", "--bogus"] },
    { argv: ["--help"] },
  ];
  for (const c of cases) {
    const caseEnv = { ...env, ...c.env };
    const viaCommand = await run(join(root, "bin", "stillfail"), ["admin", ...c.argv], caseEnv);
    const direct = await run(process.execPath, [join(root, "bin", "admin-cli.ts"), ...c.argv], { ...caseEnv, STILLFAIL_CMD: "stillfail" });
    assert.deepEqual(viaCommand, direct, c.argv.join(" "));
  }
  const [ok, okJson, wrong, missing, noKey, noOrigin, bogus, help] = await Promise.all(
    cases.map((c) => run(join(root, "bin", "stillfail"), ["admin", ...c.argv], { ...env, ...c.env })),
  );
  assert.equal(ok!.code, 0, ok!.stderr);
  assert.match(ok!.stdout, /ops@example\.test/);
  assert.equal(okJson!.code, 0, okJson!.stderr);
  assert.equal(JSON.parse(okJson!.stdout).email, "ops@example.test");
  assert.notEqual(wrong!.code, 0);
  assert.notEqual(missing!.code, 0);
  assert.equal(noKey!.code, 1);
  assert.match(noKey!.stderr, /missing Admin API key/);
  assert.equal(noOrigin!.code, 2);
  assert.equal(bogus!.code, 2);
  assert.equal(help!.code, 0);
  assert.match(help!.stdout, /^Usage: stillfail admin/);
  assert.ok(calls.includes("GET /v1/admin/me Bearer sfa_wrapper_key"), calls.join("\n"));
  assert.ok(calls.includes("GET /v1/admin/me Bearer sfa_wrong"), calls.join("\n"));
});

test("STILLFAIL_CMD the caller gave is kept, to admin-cli and to the reader", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true, node: true });
  const byNode = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l, { STILLFAIL_CMD: "monoid" }));
  assert.equal(byNode.code, 0, byNode.stderr);
  assert.equal(parseReport(byNode.stdout).cmd, "monoid");
  const byReader = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l, { STILLFAIL_CMD: "monoid", STILLFAIL_ADMIN_ENGINE: "moonbit" }));
  assert.equal(byReader.code, 0, byReader.stderr);
  assert.equal(readerSaw(l)[1], "cmd=monoid");
});

test("a STILLFAIL_NODE that is not there gives way to the release's Node before the PATH's", { skip: skipUnix }, async (t) => {
  const l = layout(t, { js: true, reader: true, node: true });
  // A node on the PATH that must not run.
  writeFileSync(join(l.tools, "node"), "#!/bin/sh\necho path-node\nexit 9\n");
  chmodSync(join(l.tools, "node"), 0o755);
  const r = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l, { STILLFAIL_NODE: join(l.base, "no-node") }));
  assert.equal(r.code, 0, r.stderr);
  assert.equal(parseReport(r.stdout).who, "admin-cli.js");
  // STILLFAIL_NODE a directory: not a Node either.
  const dir = await run(join(l.app, "bin", "stillfail"), ["admin", "whoami"], envFor(l, { STILLFAIL_NODE: l.base }));
  assert.equal(dir.code, 0, dir.stderr);
  assert.equal(parseReport(dir.stdout).who, "admin-cli.js");
  assert.equal(existsSync(l.readerLog), false, "the reader did not run");
});

// --data, as the reader's port takes it (station/mb/src/station_main/admin_cli.mbt): the data directory whose
// mesh/cloud.json names the cloud, over STILLFAIL_DATA; the last one given counts.
test("admin-cli takes --data, the last one given, over STILLFAIL_DATA; --data with no value exits 2", { skip: skipUnix }, async (t) => {
  const seen: string[] = [];
  const server = (name: string) => {
    const s = createServer((req: IncomingMessage, res: ServerResponse) => {
      seen.push(`${name} ${req.url}`);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ email: `${name}@example.test` }));
    });
    return new Promise<string>((resolve) => s.listen(0, "127.0.0.1", () => {
      t.after(() => s.close());
      resolve(`http://127.0.0.1:${(s.address() as { port: number }).port}`);
    }));
  };
  const base = mkdtempSync(join(tmpdir(), "sf-admin-cli-data-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const dataWith = async (name: string) => {
    const dir = join(base, `${name} data`);
    mkdirSync(join(dir, "mesh"), { recursive: true });
    writeFileSync(join(dir, "mesh", "cloud.json"), JSON.stringify({ origin: await server(name) }));
    return dir;
  };
  const [envData, first, last] = [await dataWith("env"), await dataWith("first"), await dataWith("last")];
  const env = { PATH: [dirname(process.execPath), "/usr/bin", "/bin"].join(delimiter), HOME: base, STILLFAIL_NODE: process.execPath, STILLFAIL_MB_READER: join(base, "no-reader"), STILLFAIL_DATA: envData, STILLFAIL_ADMIN_KEY: "sfa_k" };
  const cli = join(root, "bin", "admin-cli.ts");
  const byEnv = await run(process.execPath, [cli, "whoami"], env);
  assert.equal(byEnv.code, 0, byEnv.stderr);
  assert.match(byEnv.stdout, /env@example\.test/);
  const byFlag = await run(process.execPath, [cli, "--data", first, "whoami"], env);
  assert.equal(byFlag.code, 0, byFlag.stderr);
  assert.match(byFlag.stdout, /first@example\.test/);
  const lastWins = await run(process.execPath, [cli, "--data", first, "whoami", "--data", last], env);
  assert.equal(lastWins.code, 0, lastWins.stderr);
  assert.match(lastWins.stdout, /last@example\.test/);
  const noValue = await run(process.execPath, [cli, "whoami", "--data"], env);
  assert.deepEqual(noValue, { code: 2, stdout: "", stderr: "--data requires a value\n" });
  // Through the command: the person's --data over the data it was given.
  const viaCommand = await run(join(root, "bin", "stillfail"), ["admin", "--data", last, "whoami"], env);
  assert.equal(viaCommand.code, 0, viaCommand.stderr);
  assert.match(viaCommand.stdout, /last@example\.test/);
  assert.deepEqual(seen, ["env /v1/admin/me", "first /v1/admin/me", "last /v1/admin/me", "last /v1/admin/me"]);
});

test("admin-cli run through a link to it runs, as it does by its own path", { skip: skipUnix }, async (t) => {
  const base = mkdtempSync(join(tmpdir(), "sf-admin-cli-link-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const link = join(base, "admin-cli.ts");
  symlinkSync(join(root, "bin", "admin-cli.ts"), link);
  const env = { PATH: [dirname(process.execPath), "/usr/bin", "/bin"].join(delimiter), HOME: base };
  const linked = await run(process.execPath, [link, "--help"], env);
  const direct = await run(process.execPath, [join(root, "bin", "admin-cli.ts"), "--help"], env);
  assert.equal(linked.code, 0, linked.stderr);
  assert.match(linked.stdout, /^Usage: stillfail admin/);
  assert.deepEqual(linked, direct);
  // A clone whose bin/admin-cli.ts is a link, run by the command.
  const app = join(base, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  copyFileSync(join(root, "bin", "stillfail"), join(app, "bin", "stillfail"));
  chmodSync(join(app, "bin", "stillfail"), 0o755);
  symlinkSync(join(root, "bin", "admin-cli.ts"), join(app, "bin", "admin-cli.ts"));
  const viaCommand = await run(join(app, "bin", "stillfail"), ["admin", "--help"], { ...env, STILLFAIL_NODE: process.execPath, STILLFAIL_DATA: base });
  assert.deepEqual(viaCommand, direct);
});

test("bin/stillfail does not concatenate partial stdout when readlink -f fails", { skip: skipUnix }, async (t) => {
  const base = mkdtempSync(join(tmpdir(), "sf-readlink-fail-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const app = join(base, "app");
  const tools = toolsDir(base);
  mkdirSync(join(app, "bin"), { recursive: true });
  copyFileSync(join(root, "bin", "stillfail"), join(app, "bin", "stillfail"));
  chmodSync(join(app, "bin", "stillfail"), 0o755);
  symlinkSync(join(root, "bin", "admin-cli.ts"), join(app, "bin", "admin-cli.ts"));
  // Model macOS BSD `readlink -f` printing a partial path to stdout and exiting 1.
  rmSync(join(tools, "readlink"));
  writeFileSync(join(tools, "readlink"), "#!/bin/sh\nprintf '%s\\n' '/nonexistent/.stillfail/app'\nexit 1\n");
  chmodSync(join(tools, "readlink"), 0o755);
  const env = { PATH: [tools, dirname(process.execPath)].join(delimiter), HOME: base, STILLFAIL_NODE: process.execPath, STILLFAIL_DATA: base };
  const r = await run(join(app, "bin", "stillfail"), ["admin", "--help"], env);
  assert.equal(r.code, 0, r.stderr);
  assert.match(r.stdout, /^Usage: stillfail admin/);
});

// Windows' command, read for the same order everywhere, and run under every PowerShell there (CI's ui-windows).
function adminBlock(): string {
  const ps1 = readFileSync(join(root, "bin", "stillfail.ps1"), "utf8");
  const start = ps1.indexOf("{ $a[0] -eq 'admin' } {");
  const end = ps1.indexOf("default { [Console]::Error.WriteLine($usage)", start);
  assert.ok(start > 0 && end > start, "bin/stillfail.ps1 has its admin branch");
  return ps1.slice(start, end);
}

test("bin/stillfail.ps1's admin branch takes Node's admin CLI before the reader, as bin/stillfail does", () => {
  const block = adminBlock();
  const at = (s: string) => {
    const i = block.indexOf(s);
    assert.ok(i >= 0, `the admin branch says ${s}`);
    return i;
  };
  const cmd = at("if (-not $env:STILLFAIL_CMD) { $env:STILLFAIL_CMD = ");
  const rest = at("$rest = @(if ($a.Count -gt 1)");
  const refuse = at("if ($engine -cnotin '', 'node', 'moonbit')");
  const native = at("$start.UseShellExecute = $false");
  const nodeOnly = at("if ($engine -cne 'moonbit') {");
  const nodeOrder = at("@($env:STILLFAIL_NODE, (Join-Path $here 'node\\node.exe'))");
  const byPath = at("Get-Command node");
  const built = at("Join-Path $here 'station\\admin-cli.js'");
  const src = at("Join-Path $here 'bin\\admin-cli.ts'");
  const byNode = at("RunNative $node (@($entry) + $rest)");
  const nodeAsked = at("if ($engine -ceq 'node')");
  const byReader = at("RunNative $reader (@('admin', '--data', $data) + $rest)");
  assert.ok(cmd < rest && rest < refuse && refuse < native && native < nodeOnly && nodeOnly < nodeOrder && nodeOrder < byPath && byPath < built && built < src && src < byNode && byNode < nodeAsked && nodeAsked < byReader);
  assert.equal(block.split("RunNative ").length, 3, "Node and the reader are each called in one place");
  assert.doesNotMatch(block, /-(notin|ne|eq) '(node|moonbit)'/, "the engine is matched by case, as bin/stillfail does");
});

const onWindows = process.platform === "win32";

// A PowerShell literal: single-quoted, its quotes doubled.
const psLiteral = (s: string) => `'${s.replace(/'/g, "''")}'`;

test("bin/stillfail.ps1 admin under Windows PowerShell 5.1 and PowerShell 7", { skip: onWindows ? false : "PowerShell's paths (station\\admin-cli.js) are Windows'" }, async (t) => {
  const base = mkdtempSync(join(tmpdir(), "sf-admin-wrapper-ps-"));
  t.after(() => rmSync(base, { recursive: true, force: true }));
  const app = join(base, "app");
  mkdirSync(join(app, "bin"), { recursive: true });
  mkdirSync(join(app, "station"), { recursive: true });
  const script = join(app, "bin", "stillfail.ps1");
  copyFileSync(join(root, "bin", "stillfail.ps1"), script);
  const adminJs = join(app, "station", "admin-cli.js");
  writeFileSync(adminJs, reportJs("admin-cli.js"));
  // The reader: a .cmd that runs Node on what reports what it was given.
  writeFileSync(join(base, "reader.js"), reportJs("reader"));
  const reader = join(base, "reader.cmd");
  writeFileSync(reader, `@"${process.execPath}" "${join(base, "reader.js")}" %*\r\n@exit /b %ERRORLEVEL%\r\n`);
  const data = join(base, "data dir");
  mkdirSync(data);
  // (Windows' own variables kept, cmd.exe's among them; none of the station's)
  const env: Record<string, string> = Object.fromEntries(Object.entries(process.env).filter((e): e is [string, string] => e[1] !== undefined && !/^STILLFAIL_|^FAKE_/i.test(e[0])));
  Object.assign(env, { STILLFAIL_DATA: data, STILLFAIL_NODE: process.execPath, STILLFAIL_MB_READER: reader });

  const shells: { exe: string; version: string }[] = [];
  for (const exe of ["powershell.exe", "pwsh.exe"]) {
    const probe = await run(exe, ["-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"], env).catch(() => null);
    if (probe && probe.code === 0) shells.push({ exe, version: probe.stdout.trim() });
  }
  assert.ok(shells.some((s) => s.exe === "powershell.exe" && s.version.startsWith("5.1")), `Windows PowerShell 5.1 is on every Windows: ${JSON.stringify(shells)}`);
  // CI's Windows has both: neither is let off there.
  if (process.env.CI) assert.ok(shells.some((s) => s.exe === "pwsh.exe" && Number(s.version.split(".")[0]) >= 7), `PowerShell 7 is on CI's Windows: ${JSON.stringify(shells)}`);

  for (const { exe, version } of shells) {
    await t.test(`${exe} (${version})`, async () => {
      // As stillfail.cmd runs it.
      const byFile = (argv: string[], more: Record<string, string> = {}) =>
        run(exe, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "admin", ...argv], { ...env, ...more });
      // Each argument exactly as PowerShell holds it (no command line of powershell.exe's own in between).
      const byCall = (argv: string[], more: Record<string, string> = {}) => {
        const command = `& ${psLiteral(script)} admin ${argv.map(psLiteral).join(" ")}; exit $LASTEXITCODE`;
        return run(exe, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Buffer.from(command, "utf16le").toString("base64")], { ...env, ...more });
      };
      for (const argv of [[], ["whoami"], ["--help"], ["whoami", "--json", "a b"]]) {
        const r = await byFile(argv);
        assert.equal(r.code, 0, `${argv.join(" ")}: ${r.stderr}`);
        assert.deepEqual(parseReport(r.stdout), { who: "admin-cli.js", args: argv, cmd: "stillfail", data }, argv.join(" "));
      }
      const exact = ["pre", "", "post", 'a"b', 'say "hi there"', "C:\\dir with space\\", "back\\\\\"slash", "tab\there", "a\\\n", "--json"];
      for (const argv of [[], ["whoami"], exact]) {
        const r = await byCall(argv);
        assert.equal(r.code, 0, `${JSON.stringify(argv)}: ${r.stderr}`);
        assert.deepEqual(parseReport(r.stdout).args, argv);
      }
      // Started from one folder, moved to another: Node and the reader run in the one PowerShell is at, where a relative
      // --data (cfg) is found.
      const started = join(base, "started");
      const moved = join(base, "moved");
      mkdirSync(started, { recursive: true });
      mkdirSync(moved, { recursive: true });
      const inMoved = (engine: string) => {
        const command = `Set-Location -LiteralPath ${psLiteral(moved)}; & ${psLiteral(script)} admin --data cfg whoami; exit $LASTEXITCODE`;
        return run(exe, ["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Buffer.from(command, "utf16le").toString("base64")], { ...env, FAKE_CWD: "1", ...(engine ? { STILLFAIL_ADMIN_ENGINE: engine } : {}) }, started);
      };
      for (const engine of ["", "moonbit"]) {
        const r = await inMoved(engine);
        assert.equal(r.code, 0, `${engine}: ${r.stderr}`);
        const report = parseReport(r.stdout) as { cwd?: string; args: string[] };
        assert.equal(realpathSync.native(report.cwd!).toLowerCase(), realpathSync.native(moved).toLowerCase(), engine || "node");
        assert.deepEqual(report.args.slice(-3), ["--data", "cfg", "whoami"]);
      }
      const kept = await byFile(["whoami"], { STILLFAIL_CMD: "monoid" });
      assert.equal(parseReport(kept.stdout).cmd, "monoid");
      const failed = await byFile(["whoami"], { FAKE_EXIT: "3" });
      assert.equal(failed.code, 3, failed.stderr);
      assert.equal(failed.stderr.trim(), "to stderr from admin-cli.js");
      const moonbit = await byCall(["whoami", "pre", "", "post"], { STILLFAIL_ADMIN_ENGINE: "moonbit", FAKE_EXIT: "4" });
      assert.equal(moonbit.code, 4, moonbit.stderr);
      assert.deepEqual(parseReport(moonbit.stdout), { who: "reader", args: ["admin", "--data", data, "whoami", "pre", "", "post"], cmd: "stillfail", data });
      const cased = await byFile(["whoami"], { STILLFAIL_ADMIN_ENGINE: "MoonBit" });
      assert.equal(cased.code, 2);
      assert.equal(cased.stderr.trim(), "stillfail admin: STILLFAIL_ADMIN_ENGINE must be node or moonbit, not MoonBit");
      rmSync(adminJs);
      try {
        const fallback = await byFile(["whoami"]);
        assert.equal(fallback.code, 0, fallback.stderr);
        assert.equal(parseReport(fallback.stdout).who, "reader");
      } finally {
        writeFileSync(adminJs, reportJs("admin-cli.js"));
      }
    });
  }
});
