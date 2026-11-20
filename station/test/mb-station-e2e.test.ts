// The station as the MoonBit program runs it itself, with no Node and no main.js (station/mb src/station_main, run by
// stillfail-reader as `stillfail-reader <command>`): its commands held to the TypeScript's (cli.ts) on the same data,
// the hooks to the .mjs files they are written from (agents/repo-rules-hook.mjs, agents/subagent-hook.mjs) on the same
// input, local links and the images' codecs to the mesh addon's (native/mesh), what sys.c says of the machine to
// node:os, the words it carries to the catalog, and `run` under a launcher of the test's (ops/launcher.ts's channel on
// a descriptor): ready, serving, its heartbeat, the loopback port, the status socket, the agents' door, a handover to a
// second process with what it carries, and a stop that leaves no process behind. Every program is run with a PATH that
// names no directory with a Node in it.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer, type Server } from "node:net";
import { createServer as httpServer, request } from "node:http";
import os, { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { deflateSync } from "node:zlib";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { enroll as tsEnroll, id as tsId, joinWorkspace, lockCommand, status as tsStatus } from "../src/cli.ts";
import { loadKey } from "../src/cloud/key.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { launcherEventOf, reportLauncherEvents } from "../src/ops/launcher-events.ts";
import { answer as loopbackAnswer } from "../src/ops/loopback.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
/// (the tests' program, its harness: the station's own commands are the reader's)
const harnessProgram = mbHarnessBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : harnessProgram === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// The launcher's control channel handed to `run` (its fd 5).
const controlPipe = (c: ChildProcess) => (c.stdio as readonly unknown[])[5] as import("node:net").Socket;

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

/// The program run to its end.
function run(args: string[], o: { env?: Record<string, string>; input?: string } = {}) {
  const r = spawnSync(binary!, args, { env: o.env ?? noNode(), input: o.input ?? "", encoding: "utf8", timeout: 60_000 });
  return { code: r.status, out: r.stdout, err: r.stderr };
}

/// What console.log would have printed of `f`.
function logged(f: () => void): string {
  const lines: string[] = [];
  const was = console.log;
  console.log = (...a: unknown[]) => void lines.push(a.map(String).join(" "));
  try {
    f();
  } finally {
    console.log = was;
  }
  return lines.join("\n") + (lines.length > 0 ? "\n" : "");
}

// ── the harness ──

let harnessProc: { send: (op: string, a?: Record<string, unknown>) => Promise<any> } | null = null;
function harness() {
  if (harnessProc !== null) return harnessProc;
  const child = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"], env: noNode() });
  children.push(child);
  let seq = 0;
  const waiting = new Map<number, (v: any) => void>();
  let stderr = "";
  child.stderr!.on("data", (d) => (stderr += d));
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const m = JSON.parse(line);
    waiting.get(m.id)?.(m);
    waiting.delete(m.id);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the harness ended (${code}): ${stderr}` });
  });
  harnessProc = {
    send: (op, a = {}) =>
      new Promise((resolve) => {
        seq += 1;
        waiting.set(seq, resolve);
        child.stdin!.write(`${JSON.stringify({ id: seq, op, ...a })}\n`);
      }),
  };
  return harnessProc;
}
const ok = async (op: string, a: Record<string, unknown> = {}) => {
  const said = await harness().send(op, a);
  assert.equal(said.error, undefined, `${op}: ${said.error}`);
  return said.ok;
};

// ── the commands ──

test("id, lock status and status, as cli.ts says them, on the same data", { skip }, () => {
  const data = fresh("data");
  const first = run(["id", "--data", data]);
  assert.equal(first.code, 0, first.err);
  assert.equal(first.out, logged(() => tsId(data)), "the key the program made is the one cli.ts reads");
  assert.equal(run(["id", "--data", data]).out, first.out, "made once");
  assert.equal(first.out.trim(), loadKey(data).id);
  // no lock, no workspace, nothing running
  assert.equal(run(["lock", "status", "--data", data]).out, `${lockCommand(data, "status")}\n`);
  assert.equal(run(["lock", "reset", "--data", data]).out, `${lockCommand(data, "reset")}\n`);
  assert.equal(run(["lock", "reset", "--workspace", "w9", "--data", data]).out, `${lockCommand(data, "reset", "w9")}\n`);
  assert.equal(run(["lock", "nonsense", "--data", data]).code, 2);
  const offline = run(["status", "--data", data]);
  assert.equal(offline.code, 0);
  assert.equal(offline.out, `${tsStatus(data)}\n`);
  // in a workspace, removed from one, a rig's: as cli.ts reads the same cloud.json
  const state = { origin: "https://app.still.fail", station: loadKey(data).id, workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [] };
  for (const s of [state, { ...state, removed_at: 1_794_900_000, removed_code: 4004 }, { ...state, removed_at: 1_794_900_000, removed_code: 404 }, { ...state, rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) } }]) {
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(s));
    assert.equal(run(["status", "--data", data]).out, `${tsStatus(data)}\n`, JSON.stringify(s));
  }
  // in English, as config.json says
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en" }));
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify(state));
  const en = run(["status", "--data", data]).out;
  assert.match(en, /^Data directory/m);
});

/// A control plane of the test's (cloud/provider.ts's paths): each enroll and join answered as `answer` says, what was
/// asked of it kept.
async function plane(answer: (path: string, body: any) => { status: number; body: unknown }) {
  const asked: { path: string; body: any }[] = [];
  const server = httpServer((req, res) => {
    let text = "";
    req.on("data", (d) => (text += d));
    req.on("end", () => {
      const body = JSON.parse(text);
      asked.push({ path: req.url!, body });
      const a = answer(req.url!, body);
      res.writeHead(a.status, { "content-type": "application/json" }).end(JSON.stringify(a.body));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  after(() => server.close());
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked };
}

/// Whether `signature` is the station's (its id, the Ed25519 key's public half) over `message`.
function signedBy(id: string, message: string, signature: string): boolean {
  const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(id, "hex")]), format: "der", type: "spki" });
  return verify(null, Buffer.from(message), key, Buffer.from(signature, "hex"));
}

/// The program run to its end without holding this process (the control plane of the test's answers meanwhile).
function runSoon(args: string[]): Promise<{ code: number | null; out: string; err: string }> {
  return new Promise((resolve) => {
    const child = spawn(binary!, args, { env: noNode(), stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let out = "";
    let err = "";
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (err += d));
    child.on("close", (code) => resolve({ code, out, err }));
  });
}

/// What console.log printed of an async `f`.
async function loggedSoon(f: () => Promise<unknown>): Promise<string> {
  const lines: string[] = [];
  const was = console.log;
  console.log = (...a: unknown[]) => void lines.push(a.map(String).join(" "));
  try {
    await f();
  } finally {
    console.log = was;
  }
  return lines.join("\n") + (lines.length > 0 ? "\n" : "");
}

test("enroll, with --lock, --rig, --join and --stay, as cli.ts enrolls: the same proof asked, the same cloud.json written, the same words", { skip }, async () => {
  const p = await plane((path, body) => {
    if (body.token === "refused") return { status: 400, body: { error: "token_not_found" } };
    if (path.endsWith("/join")) return { status: 200, body: { workspace: `w-${body.token}`, workspace_name: `团队 ${body.token}`, name: "mac" } };
    return { status: 200, body: { workspace: "w1", workspace_name: "团队", name: "mac", relay_url: "https://relay.example", relay_urls: ["https://relay.example"], grant_keys: { k: 1 }, ...(body.rig ? { rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A" } } : {}) } };
  });
  const lock = "ab".repeat(32);
  const rig = "cd".repeat(32);
  // each command on two data directories of one key: the program's, and cli.ts's
  const pair = () => {
    const mb = fresh("enroll-mb");
    const ts = fresh("enroll-ts");
    run(["id", "--data", mb]);
    mkdirSync(join(ts, "mesh"), { recursive: true });
    copyFileSync(join(mb, "mesh", "secret.key"), join(ts, "mesh", "secret.key"));
    return { mb, ts, id: loadKey(mb).id };
  };
  const same = (d: { mb: string; ts: string }, what: string) => {
    const read = (dir: string, ...p: string[]) => (existsSync(join(dir, ...p)) ? readFileSync(join(dir, ...p), "utf8") : null);
    assert.deepEqual(JSON.parse(read(d.mb, "mesh", "cloud.json")!), JSON.parse(read(d.ts, "mesh", "cloud.json")!), `${what}: cloud.json`);
    for (const f of ["lock-pending.json"]) assert.equal(read(d.mb, "mesh", f), read(d.ts, "mesh", f), `${what}: ${f}`);
  };
  const lastTwo = () => {
    const [a, b] = p.asked.slice(-2);
    return [a!, b!];
  };
  const proofs = (d: { id: string }, token: string) => {
    const [a, b] = lastTwo();
    assert.equal(a.path, b.path);
    assert.deepEqual({ ...a.body, signature: "" }, { ...b.body, signature: "" }, "the same asked of the plane");
    for (const x of [a, b]) assert.ok(signedBy(d.id, `stillfail-station-enroll-v1:${p.origin}:${token}:${d.id}`, x.body.signature), "its proof the station's");
    return a;
  };
  // a station
  const one = pair();
  const said = await runSoon(["enroll", `${p.origin}/`, "t1", "--data", one.mb]);
  assert.equal(said.code, 0, said.err);
  assert.equal(said.out, await loggedSoon(() => tsEnroll(one.ts, p.origin, "t1")));
  assert.equal(proofs(one, "t1").path, "/v1/stations/enroll");
  same(one, "enrolled");
  // one more workspace, beside it (--join), and --stay (the installers'), which joins where it is in one
  for (const [flag, token] of [["--join", "t2"], ["--stay", "t3"]] as const) {
    const out = await runSoon(["enroll", p.origin, token, flag, "--data", one.mb]);
    assert.equal(out.code, 0, out.err);
    const joined = await joinWorkspace(one.ts, token, undefined, { atMachine: true });
    assert.equal(joined.workspace, `w-${token}`);
    assert.equal(proofs(one, token).path, "/v1/stations/join");
    assert.equal(lastTwo()[0].body.locks, true);
    same(one, flag);
  }
  // with a lock's hash: pinned once the plane brings it, its code said
  const locked = pair();
  const lockedSaid = await runSoon(["enroll", p.origin, "t4", "--lock", lock, "--data", locked.mb]);
  assert.equal(lockedSaid.out, await loggedSoon(() => tsEnroll(locked.ts, p.origin, "t4", "stillfail", lock)));
  same(locked, "--lock");
  // a rig, its person's lock's hash
  const rigged = pair();
  const rigSaid = await runSoon(["enroll", p.origin, "t5", "--rig", rig, "--data", rigged.mb]);
  assert.equal(rigSaid.out, await loggedSoon(() => tsEnroll(rigged.ts, p.origin, "t5", "stillfail", undefined, rig)));
  assert.equal(proofs(rigged, "t5").body.rig, true);
  same(rigged, "--rig");
  // a rig is not made a station, nor a station a rig, while it is in its workspace
  const turned = await runSoon(["enroll", p.origin, "t6", "--data", rigged.mb]);
  assert.equal(turned.code, 1);
  await assert.rejects(() => tsEnroll(rigged.ts, p.origin, "t6"), (e: Error) => turned.err.includes(e.message));
  // refused by the plane, its words said
  const refused = await runSoon(["enroll", p.origin, "refused", "--data", pair().mb]);
  assert.equal(refused.code, 1);
  assert.match(refused.err, /still\.fail cloud answered 400: \{"error":"token_not_found"\}/);
  // usage: no token, a provider not known, a lock's hash not one
  for (const args of [["enroll", p.origin], ["enroll", p.origin, "t", "--provider", "nobody"], ["enroll", p.origin, "t", "--lock", "xyz"]]) assert.equal((await runSoon([...args, "--data", fresh("u")])).code, 2);
  // its version, its release's (`--app`'s BUILD), as ops/version.ts says it
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9412\n");
  assert.equal((await runSoon(["enroll", p.origin, "t7", "--app", app, "--data", pair().mb])).code, 0);
  assert.equal(p.asked.at(-1)!.body.version, "0.1.9412");
});

test("the parts' registry (parts.mbt) as parts.ts keeps it: tools offered, what is carried over and taken up, door places, cards, streams", { skip }, async () => {
  assert.deepEqual(await ok("parts"), {
    tools: ["always", "offered"],
    toolsOff: ["always"],
    carried: { a: { n: 1 }, b: "two" },
    tookEarly: { late: { kept: true } },
    tookNow: { a: { n: 2 } },
    door: ["/peer", "/peer/x", null, null],
    card: ["retire", null],
    stream: [true, false],
    twice: ["a is carried over twice", "the overview's f is said twice"],
    mayView: [true, false],
    overview: { f: "zh:me" },
    ended: ["s1"],
    connected: 2,
    doorUrl: "http://127.0.0.1:1/mcp",
  });
});

test("channel: said, set on the config when no station takes the ask, said again", { skip }, () => {
  const data = fresh("data");
  const app = fresh("app");
  assert.equal(run(["channel", "--app", app, "--data", data]).out.trim(), "stable");
  const set = run(["channel", "beta", "--app", app, "--data", data]);
  assert.equal(set.code, 0, set.err);
  assert.equal(set.out.trim(), "beta");
  assert.equal(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).updateChannel, "beta");
  assert.equal(run(["channel", "--app", app, "--data", data]).out.trim(), "beta");
  const bad = run(["channel", "nightly", "--app", app, "--data", data]);
  assert.equal(bad.code, 1);
  assert.match(bad.err, /nightly/);
  assert.equal(run(["channel", "a", "b", "--data", data]).code, 2);
  // update: in no workspace, refused as cli.ts refuses it
  const update = run(["update", "--app", app, "--data", data]);
  assert.equal(update.code, 1);
  assert.equal(update.err.trim(), `Error: ${(zhStation as Record<string, string>)["station.updates.notJoined"]}`);
  assert.equal(run(["update", "--data", data]).code, 2);
});

/// station_main/words_catalog.mbt as the catalog makes it.
function wordsCatalog(): string {
  const esc = (s: string) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `// The station's words (client/i18n/catalog/{zh,en}/station.json), as the program carries them: what the TypeScript
// station bundles with itself (ops/i18n.ts). Written from the catalog as it is; station/test/mb-station-e2e.test.ts
// holds it to the catalog (a change there writes this again: the test says how).

///|
pub let station_zh : String = "${esc(JSON.stringify(zhStation))}"

///|
pub let station_en : String = "${esc(JSON.stringify(enStation))}"
`;
}

test("the words the program carries are the catalog's", { skip }, async () => {
  // station_main/words_catalog.mbt is written from the catalog: STILLFAIL_WRITE_WORDS=1 writes it again, after a
  // change there (the program built again after it).
  const file = join(import.meta.dirname, "..", "mb", "src", "station_main", "words_catalog.mbt");
  if (process.env.STILLFAIL_WRITE_WORDS === "1") writeFileSync(file, wordsCatalog());
  assert.equal(readFileSync(file, "utf8"), wordsCatalog(), "words_catalog.mbt is the catalog's: STILLFAIL_WRITE_WORDS=1 writes it again");
  const words = await ok("words");
  assert.deepEqual(words.zh, zhStation);
  assert.deepEqual(words.en, enStation);
  for (const ms of [0, 1_794_925_142_744, 951_782_400_000, -86_400_001]) assert.equal(await ok("iso", { ms }), new Date(ms).toISOString());
});

test("the loopback port says what ops/loopback.ts says", { skip }, async () => {
  const place = { origin: "https://app.still.fail/", workspace: "w1", workspace_name: "团队", station: "s1" };
  const cases: [string, string | null, boolean, unknown, "zh" | "en"][] = [
    ["/healthz", null, true, null, "zh"],
    ["/healthz", null, false, null, "zh"],
    ["/admin/api/x", null, true, place, "en"],
    ["/admin/chats/c1", "a=1", true, place, "zh"],
    ["/admin/settings/accounts/p1", null, true, place, "zh"],
    ["/admin/settings/memory", null, true, place, "zh"],
    ["/admin/bots/b", null, true, place, "zh"],
    ["/", null, true, place, "zh"],
    ["/admin", null, true, null, "en"],
    ["/admin", null, true, { ...place, removed_at: 1_794_900_000 }, "zh"],
    ["/elsewhere", null, true, place, "zh"],
  ];
  for (const [path, query, ready, p, lang] of cases) {
    const ts = loopbackAnswer(path, query, ready, p as any, lang);
    const mb = await ok("loopback", { path, query, ready, place: p, lang });
    assert.deepEqual({ status: mb.status, body: mb.body, location: mb.headers.location }, { status: ts.status, body: ts.body, location: ts.headers.location }, `${path} ${JSON.stringify(p)}`);
  }
});

// ── the hooks ──

/// A repository with rules at its root and below.
function repository(): string {
  const repo = fresh("repo");
  mkdirSync(join(repo, ".git"));
  mkdirSync(join(repo, "app", "deep"), { recursive: true });
  writeFileSync(join(repo, "AGENTS.md"), "# Root rules\n\n- one\n- two\n");
  writeFileSync(join(repo, "app", "CLAUDE.md"), "@AGENTS.md\n");
  writeFileSync(join(repo, "app", "AGENTS.md"), `# App\n\n${"A paragraph of the app's rules, long enough to be cut between paragraphs.\n\n".repeat(220)}`);
  writeFileSync(join(repo, "app", "deep", "x.ts"), "x");
  return repo;
}

test("the hooks: subagent-hook.mjs and repo-rules-hook.mjs, as Node runs them, run by the program itself", { skip }, () => {
  const hooks = join(import.meta.dirname, "..", "src", "agents");
  const subagent = join(hooks, "subagent-hook.mjs");
  for (const [input, writes] of [
    [{ agent_id: "a1", tool_name: "mcp__stillfail__chat_post" }, undefined],
    [{ agent_id: "", tool_name: "mcp__stillfail__chat_post" }, undefined],
    [{ tool_name: "mcp__stillfail__chat_state" }, undefined],
    [{ agent_id: "a2", tool_name: "mcp__stillfail__slack_api", tool_input: { method: " chat.postMessage " } }, "chat.,reactions.add"],
    [{ agent_id: "a2", tool_name: "mcp__stillfail__slack_api", tool_input: { method: "conversations.history" } }, "chat.,reactions.add"],
    [{ agent_id: "a3", tool_name: "mcp__stillfail__slack_api", tool_input: { method: "chat.update" } }, undefined],
    [{ agent_id: "a4" }, undefined],
  ] as const) {
    const args = writes === undefined ? [] : [writes];
    const node = spawnSync(process.execPath, [subagent, ...args], { input: JSON.stringify(input), encoding: "utf8" });
    const mb = run([subagent, ...args], { input: JSON.stringify(input) });
    assert.equal(mb.code, 0);
    assert.equal(mb.out, node.stdout, JSON.stringify(input));
  }
  assert.equal(run([subagent], { input: "not json" }).out, "");

  const rules = join(hooks, "repo-rules-hook.mjs");
  const repo = repository();
  // each side its own temporary directory (where the hook keeps what it told): compared after each call
  const nodeTmp = fresh("tmp-node");
  const mbTmp = fresh("tmp-mb");
  const steps: Record<string, unknown>[] = [
    { hook_event_name: "PostToolUse", session_id: "s1", cwd: repo, tool_input: { file_path: join(repo, "app", "deep", "x.ts") } },
    { hook_event_name: "PostToolUse", session_id: "s1", cwd: repo, tool_input: { command: "ls app/deep" } },
    { hook_event_name: "PostToolUse", session_id: "s1", cwd: repo, tool_input: { command: "echo hi" } },
    { hook_event_name: "PostToolUse", session_id: "s1", cwd: repo, tool_input: { file_path: join(repo, "AGENTS.md") } },
    { hook_event_name: "SessionStart", session_id: "s1", source: "compact" },
    { hook_event_name: "PostToolUse", session_id: "s1", agent_id: "sub/1", cwd: join(repo, "app"), tool_input: { path: "deep" } },
    { hookEventName: "PostToolUse", conversationId: "c1", toolCall: { args: { TargetFile: join(repo, "app", "deep", "x.ts") } } },
    { hookEventName: "PostInvocation", conversationId: "c1" },
    { hook_event_name: "PostToolUse", session_id: "s2", cwd: tmpdir(), tool_input: { file_path: "/nowhere/at/all" } },
  ];
  for (const [i, step] of steps.entries()) {
    const node = spawnSync(process.execPath, [rules], { input: JSON.stringify(step), encoding: "utf8", env: { ...process.env, TMPDIR: nodeTmp } });
    const mb = run([rules], { input: JSON.stringify(step), env: noNode({ TMPDIR: mbTmp }) });
    assert.equal(mb.code, 0, mb.err);
    assert.equal(mb.out, node.stdout, `step ${i}: ${JSON.stringify(step)}`);
    const kept = (dir: string) => {
      const d = join(dir, "stillfail-repo-rules");
      return existsSync(d) ? Object.fromEntries(spawnSync("ls", [d], { encoding: "utf8" }).stdout.split("\n").filter(Boolean).map((f) => [f, JSON.parse(readFileSync(join(d, f), "utf8"))])) : {};
    };
    assert.deepEqual(kept(mbTmp), kept(nodeTmp), `what step ${i} kept`);
  }
  assert.equal(run([rules], { input: "{", env: noNode({ TMPDIR: mbTmp }) }).out, "");
  assert.equal(run([rules], { input: JSON.stringify({ hookEventName: "PostToolUse" }), env: noNode({ TMPDIR: mbTmp, STILLFAIL_REPO_RULES: "0" }) }).out, "{}");
});

// ── local links and the images ──

test("local links made into attachments, as the mesh addon (local.rs) makes them, its refusals in its words", { skip }, async () => {
  const dir = fresh("links");
  mkdirSync(join(dir, "films"));
  mkdirSync(join(dir, "other"));
  writeFileSync(join(dir, "films/新建对话-手机.mp4"), "film");
  writeFileSync(join(dir, "report.pdf"), "report");
  writeFileSync(join(dir, "a b.txt"), "space");
  writeFileSync(join(dir, "other/report.pdf"), "two");
  writeFileSync(join(dir, "code.rs"), "fn main() {}");
  const file = join(dir, "report.pdf");
  const cases: [string, string[]][] = [
    ["[手机](films/新建对话-手机.mp4)\n[网页](https://example.com/a) [节](#a) <a@b.co>", []],
    ["[报告](report.pdf)", [file]],
    ["[手机](films/missing.mp4)", []],
    ["[站点](www.example.com)", []],
    [`[report](${file}) and ![img](${file})`, []],
    [`[report](file://${file})`, []],
    [`[bad](file://host${file})`, []],
    [`[spaces](<${join(dir, "a b.txt")}>)`, []],
    [`[code](${join(dir, "code.rs")}:12:3)`, []],
    [`[code](${join(dir, "code.rs")}:12:x)`, []],
    ["[missing](/tmp/stillfail-no-such-report.txt)", []],
    [`[report](${join(dir, "other/report.pdf")})`, [file]],
    [`[report][r]\n\n[r]: ${file}`, []],
    [`\`[report](${file})\`\n\n\`\`\`\n[report](${file})\n\`\`\``, []],
    [`[esc](${file.replace("report", "rep\\ort")})`, []],
    [`[nested [inner](${file})](https://x.y)`, []],
    [`<file://${file}>`, []],
    ["/o/route and [route](/o/w/s/k) [proto](//cdn.example.com/x)", []],
    [`[t](${file} "a title")`, []],
  ];
  for (const [text, paths] of cases) {
    let ts: unknown;
    try {
      ts = { ok: loadMesh().prepareLocalLinks(text, [...paths], dir) };
    } catch (e) {
      ts = { error: (e as Error).message };
    }
    const said = await harness().send("prepareLocalLinks", { text, paths, workspace: dir });
    const mb = said.error !== undefined ? { error: said.error } : { ok: said.ok };
    assert.deepEqual(mb, ts, text);
  }
});

/// A PNG of `w`×`h` (RGBA), stripes and a gradient, clear on its left third where `clear`.
function png(w: number, h: number, clear = false): Buffer {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const i = y * (w * 4 + 1) + 1 + x * 4;
      raw[i] = Math.floor((x * 255) / w);
      raw[i + 1] = Math.floor((y * 255) / h);
      raw[i + 2] = (Math.floor(x / 7) + Math.floor(y / 5)) % 2 === 0 ? 200 : 30;
      raw[i + 3] = clear && x < w / 3 ? 64 : 255;
    }
  }
  const crc = (b: Buffer) => {
    let c = ~0;
    for (const byte of b) {
      c ^= byte;
      for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c >>> 0;
  };
  const chunk = (type: string, body: Buffer) => {
    const t = Buffer.concat([Buffer.from(type), body]);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(body.length);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(t));
    return Buffer.concat([len, t, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr.set([8, 6, 0, 0, 0], 8);
  // (stored, level 0: far over 24 KiB, as a screenshot of a large screen is)
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 0 })), chunk("IEND", Buffer.alloc(0))]);
}

test("what the launcher kept of its recoveries, said as launcher-events.ts says it: once, its own fields, at its level", { skip }, async () => {
  const lines = [
    JSON.stringify({ at: 1795091426000, kind: "node_hung_killed", level: "error", pid: 4242, version: "0.1.1000", uptimeMs: 3600000, heartbeatTimeoutMs: 90000, healthAgeMs: 92000, rssBytes: 734003200, openFds: 812, heldMaxMs: 1200, front: "ok", presenceOnline: true, relayConflict: false }),
    JSON.stringify({ at: 2, kind: "node_crashed", pid: 7, how: "was ended by signal 9", taken: true, failures: 0, home: "/Users/someone", nested: { a: 1 } }),
    JSON.stringify({ at: 3, kind: "front_gone", level: "error", retries: 2 }),
    JSON.stringify({ at: 4, kind: "retiring_killed", level: "info", pid: 9, version: "0.1.9", exitTimeoutMs: 30000 }),
    JSON.stringify({ at: 5, kind: "handoff_failed", reason: "the new station exited with 1 before it was ready" }),
    "{\"at\":1,\"kind\":\"node_cra",
    "",
    "[1,2]",
    "null",
    "{\"at\":6}",
    "{\"at\":7,\"kind\":\"\"}",
  ];
  for (const line of lines) assert.deepEqual(await ok("launcherEventLine", { line }), launcherEventOf(line), line);
  const mb = fresh("data");
  const ts = fresh("data");
  for (const data of [mb, ts]) {
    mkdirSync(join(data, "run"));
    writeFileSync(join(data, "run", "launcher-events.jsonl"), lines.join("\n") + "\n");
  }
  const said: { level: string; message: string; fields: Record<string, unknown> }[] = [];
  const n = await reportLauncherEvents(ts, (level, message, fields) => void said.push({ level, message, fields }));
  assert.equal(n, 5);
  assert.deepEqual(await ok("launcherEvents", { data: mb }), { n, said });
  assert.deepEqual(readdirSync(join(mb, "run")), [], "the file taken and removed");
  assert.deepEqual(await ok("launcherEvents", { data: mb }), { n: 0, said: [] }, "said once");
  assert.deepEqual(await ok("launcherEvents", { data: join(mb, "none") }), { n: 0, said: [] }, "no run/ at all");
});

test("the images' thumbnails and ThumbHashes, as the mesh addon (thumbs.rs) makes them: the same choices and sizes", { skip }, async () => {
  const dir = fresh("thumbs");
  const files: [string, Buffer][] = [["photo.png", png(1600, 900)], ["clear.png", png(1000, 800, true)], ["small.png", png(10, 10)], ["moving.gif", png(400, 400)], ["broken.jpg", Buffer.alloc(40_000, 0x11)], ["tall.png", png(300, 2000)]];
  for (const [name, bytes] of files) writeFileSync(join(dir, name), bytes);
  const size = (b: Buffer) => (b[0] === 0x89 ? [b.readUInt32BE(16), b.readUInt32BE(20)] : jpegSize(b));
  for (const [name] of files) {
    const image = join(dir, name);
    const ts = await loadMesh().thumbnail(image, join(dir, "ts"));
    const mb = await ok("thumbnail", { image, dir: join(dir, "mb") });
    assert.equal(mb === null, ts === null, `${name}: made or not`);
    if (ts === null) continue;
    assert.equal(mb.type, ts.type, name);
    assert.deepEqual(size(readFileSync(mb.path)), size(readFileSync(ts.path)), `${name}'s size`);
    assert.equal(mb.path, join(dir, "mb", `${createHash("sha256").update(image).digest("hex").slice(0, 32)}.${ts.type === "image/png" ? "png" : "jpg"}`));
    assert.ok(readFileSync(mb.path).length < readFileSync(image).length);
    // kept: asked again, the same
    assert.deepEqual(await ok("thumbnail", { image, dir: join(dir, "mb") }), mb);
  }
  for (const [name] of files) {
    const image = join(dir, name);
    const ts = await loadMesh().thumbhash(image, null);
    const mb = await ok("thumbhash", { image, dir: null });
    assert.equal(mb === null, ts === null, `${name}: hashed or not`);
    if (ts === null) continue;
    assert.deepEqual([mb.width, mb.height], [ts.width, ts.height], name);
    // the same bytes as thumbhash 0.1 makes of image's `thumbnail` (both ported in f32): its header whole, each
    // varying factor's nibble within one (f32's cos is libm's here and Rust's there, an ulp apart at most)
    const a = Buffer.from(mb.hash, "base64");
    const b = Buffer.from(ts.hash, "base64");
    assert.equal(a.length, b.length, `${name}'s hash's length`);
    const head = (b[2]! & 0x80) !== 0 ? 6 : 5;
    assert.deepEqual([...a.subarray(0, head)], [...b.subarray(0, head)], `${name}'s header`);
    for (let i = head; i < a.length; i++) {
      for (const shift of [0, 4]) assert.ok(Math.abs(((a[i]! >> shift) & 15) - ((b[i]! >> shift) & 15)) <= 1, `${name}'s factor at ${i}: ${mb.hash} ${ts.hash}`);
    }
  }
});

function jpegSize(b: Buffer): [number, number] {
  let i = 2;
  while (i < b.length) {
    const marker = b[i + 1]!;
    const len = b.readUInt16BE(i + 2);
    if (marker >= 0xc0 && marker <= 0xc2) return [b.readUInt16BE(i + 7), b.readUInt16BE(i + 5)];
    i += 2 + len;
  }
  return [0, 0];
}

// ── the machine ──

test("what sys.c says of the machine, as node:os says it", { skip }, async () => {
  const m = await ok("machine");
  assert.equal(m.cpus.length, os.cpus().length);
  assert.equal(m.totalmem, os.totalmem());
  assert.ok(m.freemem > 0 && m.freemem <= m.totalmem);
  assert.ok(m.rss > 0);
  assert.ok(m.cpus.every((c: any) => c.times.user >= 0 && c.times.idle > 0) && m.cpus.some((c: any) => c.times.user > 0));
  assert.equal(m.loadavg.length, 3);
  assert.ok(Math.abs(m.uptime - os.uptime()) < 5);
  assert.equal(await ok("hostname"), os.hostname());
  assert.equal(await ok("homedir"), os.homedir());
  assert.equal(await ok("tmpdir"), os.tmpdir());
  assert.deepEqual(await ok("platform"), { platform: process.platform, arch: process.arch });
  assert.ok(Math.abs((await ok("wallMs")) - Date.now()) < 5_000);
  const lan = await ok("lanAddrs");
  const nodeLan = Object.values(os.networkInterfaces()).flat().filter((a) => a !== undefined && !a.internal).map((a) => a!.address);
  for (const a of lan) assert.ok(nodeLan.some((n) => n.split("%")[0] === a.address.split("%")[0]), `${a.address} is one node:os names`);
  const disk = await ok("diskOf", { path: tmpdir() });
  assert.ok(disk.total > 0 && disk.free > 0 && disk.free <= disk.total);
  assert.equal(await ok("diskOf", { path: "/no/such/place" }), null);
  await ok("envSet", { name: "SF_E2E", value: "值 1" });
  assert.equal(await ok("env", { name: "SF_E2E" }), "值 1");
  assert.equal(await ok("env", { name: "SF_NONE" }), null);
  const usage = await ok("processUsage", { pids: [process.pid, 999_999_9] });
  if (process.platform === "darwin") assert.ok(usage[0].cpuNs > 0 && usage[0].footprint > 0);
  else assert.equal(usage[0], null);
  assert.equal(usage[1], null);
});

test("children started, followed to their end, given input and signals; a lock of a file held between two processes", { skip }, async () => {
  const dir = fresh("procs");
  const echo = await ok("spawn", { program: "/bin/sh", args: ["-c", 'printf "%s|%s" "$SF_X" "$(pwd)"; printf err >&2; exit 3'], env: { SF_X: "x 值" }, cwd: dir });
  assert.deepEqual([echo.code, echo.signal, echo.stdout, echo.stderr], [3, null, `x 值|${(await import("node:fs")).realpathSync(dir)}`, "err"]);
  const cat = await ok("spawn", { program: "cat", args: [], env: { PATH: "/bin:/usr/bin" }, input: "given on stdin\n" });
  assert.equal(cat.stdout, "given on stdin\n");
  const appended = join(dir, "out.log");
  await ok("spawn", { program: "/bin/sh", args: ["-c", "echo one"], stdout: appended });
  await ok("spawn", { program: "/bin/sh", args: ["-c", "echo two"], stdout: appended });
  assert.equal(readFileSync(appended, "utf8"), "one\ntwo\n");
  const missing = await harness().send("spawn", { program: "/no/such/program", args: [] });
  assert.match(missing.error, /^ENOENT/);
  // a group of its own, ended with its children
  const sleeper = await ok("spawn", { program: "/bin/sh", args: ["-c", "sleep 30 & sleep 30 & wait"], env: { PATH: "/bin:/usr/bin" }, group: true, detach: true });
  const group = () => spawnSync("pgrep", ["-g", String(sleeper.pid)], { encoding: "utf8" }).stdout.trim().split("\n").filter((p) => p !== "");
  try {
    assert.equal(await ok("pidAlive", { pid: sleeper.pid }), true);
    // (both children in its group before the group is signalled: a child the shell forks as the signal walks the group
    // is not in it yet, takes no signal pending on the shell, and is left sleeping in the group once the shell ends)
    for (let i = 0; i < 100 && group().length < 3; i++) await new Promise((r) => setTimeout(r, 20));
    assert.equal(group().length, 3, "the shell and both its children in its group");
    assert.equal(await ok("kill", { pid: sleeper.pid, signal: "SIGTERM", group: true }), true);
    for (let i = 0; i < 100 && (await ok("pidAlive", { pid: sleeper.pid })); i++) await new Promise((r) => setTimeout(r, 20));
    // (a zombie until it is waited for: the program's thread waits for it)
    // (its children, orphaned as it ended, reaped by the system a moment after)
    for (let i = 0; i < 100 && group().length > 0; i++) await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(group(), [], "nothing of its group left");
  } finally {
    // (what a failed assertion leaves of the group, not left sleeping past the test)
    try {
      process.kill(-sleeper.pid, "SIGKILL");
    } catch {}
  }
  assert.equal(await ok("parentPid"), process.pid);
  // the lock: taken, then a second process waits for it until it is let go
  const lock = join(dir, "pack.lock");
  const held = await ok("fileLock", { path: lock });
  const other = spawn(harnessProgram!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "inherit"], env: noNode() });
  children.push(other);
  const lines = createInterface({ input: other.stdout! });
  const got: string[] = [];
  lines.on("line", (l) => got.push(l));
  other.stdin!.write(`${JSON.stringify({ id: 1, op: "fileLock", path: lock })}\n`);
  await new Promise((r) => setTimeout(r, 300));
  assert.deepEqual(got, [], "the second waits while the first holds it");
  assert.equal(await ok("fileUnlock", held), true);
  for (let i = 0; i < 200 && got.length === 0; i++) await new Promise((r) => setTimeout(r, 10));
  assert.deepEqual(JSON.parse(got[0]!), { id: 1, ok: { handle: 1 } });
  other.stdin!.end();
  if (other.exitCode === null && other.signalCode === null) await new Promise<void>((r) => other.once("exit", () => r()));
  assert.equal((readFileSync(lock).length), 0, "never written");
});

test("stdin writes are non-blocking, drain multi-chunk input, and kill stalled children past STILLFAIL_STDIN_MOST", { skip }, async () => {
  const r = await ok("stdinBackpressure");
  assert.equal(r.catOk, true, "multi-chunk write to cat drains cleanly and closes with EOF");
  assert.equal(r.rejected, true, "writing past STILLFAIL_STDIN_MOST returns false");
  assert.ok(r.writeMs < 2_000, `writes must not block the event loop (took ${r.writeMs}ms)`);
  assert.ok(r.totalMs < 5_000, `stalled child must be killed promptly (took ${r.totalMs}ms)`);
  assert.equal(r.stalledCode, null);
  assert.equal(r.stalledSignal, "SIGKILL");
  assert.equal(r.stalledAlive, false, "no orphan process left alive");
  assert.equal(r.quickCode, 0);
  assert.equal(r.quickSignal, null);
  assert.equal(r.lateWrite, false, "exited child without end_input cleans up stdin handle");
});

// ── run, under a launcher of the test's ──

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; heard: (what: string, text: string) => Promise<void>; stderr: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts): its two listeners bound here and handed down
/// (closed here once it has them), its control channel the fourth's pipe.
async function launch(data: string, app: string, more: string[] = []): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat", ...more], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300" }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = controlPipe(child);
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  const errWaiters: (() => void)[] = [];
  child.stderr!.on("data", (d) => {
    err += d;
    for (const w of errWaiters.splice(0)) w();
  });
  const heard = (what: string, text: string) =>
    new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never heard: ${what}; stderr ${err}`)), 15_000);
      const look = () => {
        if (err.includes(text)) {
          clearTimeout(timer);
          resolve();
        } else errWaiters.push(look);
      };
      look();
    });
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 15_000);
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
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, heard, stderr: () => err };
}

function get(port: number | { socket: string }, path: string, body?: string, token?: string): Promise<{ status: number; body: string; headers: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { "content-type": "application/json", ...(token !== undefined ? { authorization: `Bearer ${token}` } : {}) };
    const req = request({ ...(typeof port === "number" ? { host: "127.0.0.1", port } : { socketPath: port.socket }), path, method: body === undefined ? "GET" : "POST", headers }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text, headers: res.headers }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

test("run: ready, serving, its heartbeat, the loopback port, the status socket, the agents' door; a handover with what it carries; a stop that leaves nothing", { skip }, async () => {
  const data = fresh("run");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9400\n");
  const a = await launch(data, app);
  assert.deepEqual(await a.next("ready", (m) => m.ready === true), { ready: true, version: "0.1.9400" });
  const admin = await a.next("admin", (m) => m.serving === "admin");
  const mcp = await a.next("mcp", (m) => m.serving === "mcp");
  await a.next("a heartbeat", (m) => m.heartbeat === true);
  // what it wrote of itself
  assert.deepEqual(JSON.parse(readFileSync(join(data, "run", "ports.json"), "utf8")), { admin: admin.port });
  assert.deepEqual(JSON.parse(readFileSync(join(data, "run", "mcp.json"), "utf8")), { port: mcp.port });
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid);
  const health = JSON.parse(readFileSync(join(data, "run", "health.json"), "utf8"));
  assert.equal(health.pid, a.child.pid);
  assert.ok(Math.abs(health.updatedAt - Date.now()) < 5_000);
  // its descriptors and resident memory, from the system's own counters
  assert.ok(Number.isInteger(health.openFds) && health.openFds > 0, `openFds ${health.openFds}`);
  assert.ok(Number.isInteger(health.rssBytes) && health.rssBytes > 0, `rssBytes ${health.rssBytes}`);
  // the loopback port
  assert.equal((await get(admin.port, "/healthz")).status, 200);
  const unjoined = await get(admin.port, "/admin");
  assert.equal(unjoined.status, 404);
  assert.equal(unjoined.body, loopbackAnswer("/admin", null, true, null, "zh").body);
  // the agents' door: a session's bearer token or nothing (tools/mcp.ts `McpEndpoint`)
  const anonymous = await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }));
  assert.equal(anonymous.status, 401);
  assert.deepEqual(JSON.parse(anonymous.body), { error: "unknown session token" });
  assert.equal((await get(mcp.port, "/health")).status, 200);
  // the store it opened, the schema made: a session the TypeScript's store writes there is the status socket's
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: data, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  store.setRunning("s1", true);
  // its token is the door's bearer: the endpoint's methods, and the agents' tools
  const init = JSON.parse((await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }), "t1")).body);
  assert.equal(init.result.serverInfo.name, "still.fail");
  const tools = JSON.parse((await get(mcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }), "t1")).body).result.tools.map((t: { name: string }) => t.name);
  for (const core of ["chat_post", "chat_state", "chat_history", "chat_list", "chat_read", "session_send", "chat_create", "chat_archive", "chat_configure", "job_start", "job_list", "job_log", "job_stop", "station_list", "station_task", "station_file", "search", "skill_read", "workspace_limit", "secret_list", "feishu_api", "slack_api"]) assert.ok(tools.includes(core), `${core} listed: ${tools.join(",")}`);
  for (const hidden of ["station_retire", "adb_devices", "phone_use", "secret_reask"]) assert.ok(!tools.includes(hidden), `${hidden} hidden: ${tools.join(",")}`);
  const running = store.runningSessions();
  const status = JSON.parse((await get({ socket: join(data, "run", "status.sock") }, "/v1/status")).body);
  assert.equal(status.version, "0.1.9400");
  assert.equal(status.enrolled, false);
  assert.deepEqual(status.agents, { busy: 1, warm: 0, total: 1 });
  assert.equal(status.tasks[0].session, "s1");
  assert.deepEqual([status.tasks[0].title, status.tasks[0].since], [running[0]!.title, running[0]!.lastActiveAt]);
  assert.equal((await get({ socket: join(data, "run", "status.sock") }, "/healthz")).body, "ok\n");
  store.close();
  // `stillfail status` while it runs (the launcher's station.json, as the launcher writes it)
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: a.child.pid, version: "0.1.9400" }));
  assert.equal(run(["status", "--data", data]).out, `${tsStatus(data)}\n`);
  // a second process of its own, no launcher: refused, the station held
  const second = run(["run", "--app", app, "--data", data]);
  assert.equal(second.code, 3);
  rmSync(join(data, "run", "station.json"));
  // `stillfail heap`: asked of the running station, its answer's file said
  const heap = run(["heap", "--data", data]);
  assert.equal(heap.code, 0, heap.err);
  const snapshot = JSON.parse(readFileSync(heap.out.trim(), "utf8"));
  assert.equal(snapshot.pid, a.child.pid);

  // a handover: the next process started beside it waits for it to go
  const b = await launch(data, app);
  await b.next("ready", (m) => m.ready === true);
  await b.next("taking, while the one before is there", (m) => m.taking === true);
  assert.equal(b.said.some((m) => m.serving === "mcp"), false, "its door not open while the one before holds the sessions");
  a.tell({ op: "handover" });
  const carry = await a.next("carry", (m) => m.carry !== undefined);
  assert.deepEqual(Object.keys(carry.carry).sort(), ["live.plans", "live.tails", "vault"], "what its parts carry, by part (where the live view read each checklist and transcript to; the vault's grants and boxes waiting)");
  assert.ok(Array.isArray(carry.carry["live.plans"]) && Array.isArray(carry.carry["live.tails"]), JSON.stringify(carry.carry));
  assert.equal(typeof carry.carry.vault, "object");
  assert.notEqual(carry.carry.vault, null);
  assert.equal(await a.ended, 0);
  assert.equal(existsSync(join(data, "run", "hub.json")) && JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid === a.child.pid, false, "its sessions' file let go");
  b.tell({ op: "carried", carried: carry.carry });
  const bMcp = await b.next("serving the agents' door", (m) => m.serving === "mcp");
  const bAdmin = b.said.find((m) => m.serving === "admin");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, b.child.pid);
  assert.equal(existsSync(join(data, "run", "handover.json")), false, "the handover taken up");
  assert.equal((await get(bAdmin.port, "/healthz")).status, 200);
  assert.equal((await get(bMcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }))).status, 401);
  assert.deepEqual(JSON.parse((await get(bMcp.port, "/mcp", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "ping" }), "t1")).body).result, {});
  b.tell({ op: "drain" });
  assert.deepEqual(await b.next("drained", (m) => m.drained !== undefined), { drained: "idle" });
  b.tell({ op: "hup" });
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
  for (const p of [a.child.pid!, b.child.pid!]) assert.throws(() => process.kill(p, 0), "no process left");
  assert.equal(existsSync(join(data, "run", "hub.json")), false);
});

test("run: a stop lets go of run/hub.json only once its sessions are let go, so a station started meanwhile waits for it", { skip: skip || (process.platform === "win32" ? "its children held by SIGSTOP" : false) }, async () => {
  const data = fresh("held");
  const app = fresh("app");
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  await a.next("mcp", (m) => m.serving === "mcp");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid);
  // its winding down held: its processes (the sessions' program, the readers) stopped, so letting go of them waits
  // (one that ended since `ps` looked, a short command of its own, is left out); `copies.start()` spawns
  // `--builder replica-export` only after `door_ready`, and it is the one `wait_live_p5_5_closed()` awaits on stop: wait for it
  let rows: string[][] = [];
  for (let i = 0; i < 250; i++) {
    rows = spawnSync("ps", ["-A", "-o", "pid=,ppid=,command="], { encoding: "utf8" }).stdout.split("\n").map((l) => l.trim().split(/\s+/)).filter((r) => r[1] === String(a.child.pid));
    if (rows.some((r) => r.includes("replica-export"))) break;
    await new Promise((r) => setTimeout(r, 20));
  }
  assert.ok(rows.some((r) => r.includes("replica-export")), `its processes (waiting for replica-export): ${JSON.stringify(rows)}`);
  const kids = rows.map((r) => Number(r[0])).filter((k) => {
    try {
      process.kill(k, "SIGSTOP");
      return true;
    } catch {
      return false;
    }
  });
  assert.ok(kids.length > 0, `its processes: ${JSON.stringify(rows)}`);
  a.tell({ op: "stop" });
  await a.heard("stopping", "stopping");
  // still winding down: its sessions' file still names it (the next station's `held_by_hub`)
  assert.equal(a.child.exitCode, null, "still there");
  assert.equal(existsSync(join(data, "run", "hub.json")) && JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, a.child.pid, "its sessions' file kept while it winds down");
  // a station started now waits for it instead of taking the sessions (and the runners) up beside it
  const b = await launch(data, app);
  await b.next("ready", (m) => m.ready === true);
  await b.next("taking, while the one before winds down", (m) => m.taking === true);
  assert.equal(b.said.some((m) => m.serving === "mcp"), false, "its door not open while the one before holds the sessions");
  for (const k of kids) {
    try {
      process.kill(k, "SIGCONT");
    } catch {}
  }
  assert.equal(await a.ended, 0);
  await b.next("serving the agents' door once the one before is gone", (m) => m.serving === "mcp");
  assert.equal(JSON.parse(readFileSync(join(data, "run", "hub.json"), "utf8")).pid, b.child.pid);
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
  assert.equal(existsSync(join(data, "run", "hub.json")), false, "let go of as it ends");
});

test("run: a database already at this version opens while another process holds its write lock", { skip }, async () => {
  const data = fresh("locked");
  const app = fresh("app");
  // the database as a station that ran here left it (every part's tables made)
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  await a.next("mcp", (m) => m.serving === "mcp");
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
  // a process of the station before (a backfill, one held by SIGSTOP) mid-write: the next station opens it all the same
  const holder = new DatabaseSync(join(data, "stillfail.db"));
  holder.exec("BEGIN IMMEDIATE");
  let b: Launched;
  try {
    b = await launch(data, app);
    await b.next("ready", (m) => m.ready === true);
    assert.equal(b.stderr().includes("database is locked"), false, b.stderr());
  } finally {
    holder.exec("ROLLBACK");
    holder.close();
  }
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0);
});

test("run on its own: SIGTERM stops it; a launcher gone stops it", { skip }, async () => {
  const data = fresh("own");
  const app = fresh("app");
  const own = spawn(binary!, ["run", "--app", app, "--data", data], { stdio: ["ignore", "ignore", "pipe"], env: noNode() });
  children.push(own);
  for (let i = 0; i < 300 && !existsSync(join(data, "run", "mcp.json")); i++) await new Promise((r) => setTimeout(r, 20));
  const port = JSON.parse(readFileSync(join(data, "run", "ports.json"), "utf8")).admin;
  assert.equal((await get(port, "/healthz")).status, 200);
  own.kill("SIGTERM");
  assert.equal(await new Promise((r) => own.on("exit", r)), 0);
  const launched = await launch(fresh("gone"), app);
  await launched.next("ready", (m) => m.ready === true);
  controlPipe(launched.child).destroy();
  assert.equal(await launched.ended, 0, "the launcher's channel closed: it stops");
});
