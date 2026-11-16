// What the station's main thread waits on as it shares profiles and skills with the other stations of its workspaces
// (src/share/index.ts): nothing of node:fs's synchronous calls (station/AGENTS.md, the main thread waits on nothing)
// but config.json's own (ConfigFile `stamp`, `update`: its write is one step with what it holds). A copied skill's
// link was made, checked and taken away there, a shared login read for its hash and its account at every pass, one
// handed over written there before `share.take` answered.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { lstat, readFile, readlink, rename, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { authFile as cursorAuthFile } from "../src/accounts/cursor.ts";
import { grokAuthFile } from "../src/accounts/profiles.ts";
import { Cloud } from "../src/cloud/state.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { readerBinary } from "../src/read/mb-reader.ts";
import { Sharing } from "../src/share/index.ts";
import { syncCalls } from "./main-thread-sync.ts";

const A = "a".repeat(64);
const B = "b".repeat(64);
const WS = "w";

const dirs: string[] = [];
const made: Sharing[] = [];
after(async () => {
  await Promise.all(made.map((s) => s.close()));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// A cloud that only lists the two stations of one workspace.
function cloudFor(station: string): Cloud {
  const peers = [{ id: A, name: "studio" }, { id: B, name: "mini" }];
  return Object.defineProperties(Object.create(Cloud.prototype), Object.getOwnPropertyDescriptors({
    peersCurrent: true,
    lock: null,
    state: { station, workspace: WS, workspace_name: WS, peers, revocations: [], joined: [] },
    listen: () => () => {},
  })) as Cloud;
}

type Station = { data: string; config: ConfigFile; sharing: Sharing };

function station(id: string, others: Map<string, Station>, profiles: unknown[] = []): Station {
  const data = mkdtempSync(join(tmpdir(), "share-main-thread-"));
  dirs.push(data);
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles }));
  const config = new ConfigFile(data);
  config.check = checkConfig;
  mkdirSync(join(data, "agent", "skills"), { recursive: true });
  const sharing = new Sharing({
    data, config, cloud: cloudFor(id),
    ask: async (to, _ws, request) => {
      const other = others.get(to);
      if (!other) throw new Error("peer unavailable");
      return other.sharing.handle(id, request, WS);
    },
    agentHome: () => join(data, "agent"),
    env: {},
    claudeToken: async (p) => ({ token: `token-of-${p.id}`, expiresAt: Date.now() + 2 * 3600_000 }),
    codexRenewRunning: async () => false,
    status: async () => ({ check: { state: "ok" }, quota: null }),
    changed: () => {},
    binary,
  });
  made.push(sharing);
  return { data, config, sharing };
}

/// The skills' program, found once before: where it is (src/read/mb-reader.ts `mbReaderBinary`) is not what is held here.
const binary = readerBinary();

const settle = async (...stations: Station[]) => {
  for (let i = 0; i < 4; i++) {
    await new Promise((r) => setImmediate(r));
    await Promise.all(stations.map((s) => s.sharing.reconcile()));
  }
  await Promise.all(stations.map((s) => s.sharing.stateWritten()));
};

/// The calls but config.json's own.
const others = (calls: string[]) => calls.filter((c) => !/ConfigFile\.(stamp|update)/.test(c));

/// The watches a station keeps, and its own ways to them.
const watching = (s: Station) => s.sharing as unknown as { watchers: Map<string, unknown>; stopWatch(key: string): void; watchBorrowed(id: string, dir: string): Promise<void>; watchHosted(name: string, dir: string): Promise<void> };
const watched = (s: Station) => [...watching(s).watchers.keys()].sort();

const skill = (text: string) => `---\nname: ember\ndescription: 项目记忆：ember\n---\n${text}\n`;

test("a skill shared, copied and linked, renamed, shown under a name taken and taken away waits on no file", async () => {
  const all = new Map<string, Station>();
  const a = station(A, all);
  const b = station(B, all);
  all.set(A, a).set(B, b);
  const skills = join(a.data, "agent", "skills");
  const theirs = join(b.data, "agent", "skills");
  mkdirSync(join(skills, "ember"));
  writeFileSync(join(skills, "ember", "SKILL.md"), skill("first"));
  mkdirSync(join(skills, "own"));
  mkdirSync(join(skills, "again"));
  writeFileSync(join(skills, "own", "SKILL.md"), skill("A's"));
  // One of B's own under a name A shares too: B's wins, A is told so.
  mkdirSync(join(theirs, "own"));
  writeFileSync(join(theirs, "own", "SKILL.md"), skill("B's"));

  const linked: Record<string, string | null> = {};
  const at = async (name: string) => {
    try {
      return (await lstat(join(theirs, name))).isSymbolicLink() ? await readlink(join(theirs, name)) : "other";
    } catch {
      return null;
    }
  };
  let renamedTo = "";
  const calls = await syncCalls(async () => {
    await a.sharing.shareSkill("ember", true, null);
    await a.sharing.shareSkill("own", true, null);
    await settle(a, b);
    linked.ember = await at("ember");
    linked.own = await at("own");
    // Renamed on its host: linked under its new name there, the old link taken away.
    await rename(join(skills, "ember"), join(skills, "flame"));
    await settle(a, b);
    await settle(a, b);
    renamedTo = (await at("flame")) ?? "";
    linked.emberAfter = await at("ember");
    // A watch begun as each stops (its directory being looked at as the share stops, or the copy is taken away): not
    // made once it is looked at.
    const id = a.config.raw().sharedSkills.flame.id;
    watching(b).stopWatch(`borrowed:${id}`);
    watching(a).stopWatch("hosted:own");
    const [, , , begun] = [
      watching(b).watchBorrowed(id, join(b.data, "share", id, "skill")),
      watching(a).watchHosted("own", join(skills, "own")),
      // No longer shared: the copy and its link gone.
      a.sharing.shareSkill("own", false, null),
      a.sharing.shareSkill("flame", false, null),
    ];
    await begun;
    await settle(a, b);
  });
  assert.deepEqual(others(calls), []);
  assert.match(linked.ember ?? "", /share\/sh-[0-9a-f]+\/skill$/, "linked to its copy");
  assert.equal(linked.own, "other", "B's own stays");
  assert.match(renamedTo, /share\/sh-[0-9a-f]+\/skill$/);
  assert.equal(linked.emberAfter, null, "the old name's link taken away");
  assert.equal(await at("flame"), null, "taken away with the share");
  assert.equal(readFileSync(join(theirs, "own", "SKILL.md"), "utf8"), skill("B's"));
  assert.equal(existsSync(join(b.data, "share", renamedTo.split("/").at(-2)!)), false, "its copy gone");
  assert.deepEqual(watched(a), [], "nothing shared is followed");
  assert.deepEqual(watched(b), [], "no copy is followed");
  // Closed while a watch is begun: none made after.
  writeFileSync(join(skills, "again", "SKILL.md"), skill("again"), { flag: "w" });
  await a.sharing.shareSkill("again", true, null);
  assert.deepEqual(watched(a), ["hosted:again"]);
  watching(a).stopWatch("hosted:again");
  const late = watching(a).watchHosted("again", join(skills, "again"));
  await a.sharing.close();
  await late;
  assert.deepEqual(watched(a), [], "nothing followed once closed");
});

const jwt = (claims: object) => ["{}", JSON.stringify(claims), "s"].map((p) => Buffer.from(p).toString("base64url")).join(".");
const CLAUDE = { id: "max", name: "Claude Max", runtime: "claude", access: { kind: "subscription" }, home: "homes/max", env: {} };
const CODEX = { id: "plus", name: "ChatGPT Plus", runtime: "codex", access: { kind: "subscription" }, home: "homes/plus", env: {} };
const GROK = { id: "g", name: "SuperGrok", runtime: "grok", access: { kind: "subscription" }, home: "homes/g", env: {} };
const CURSOR = { id: "cur", name: "Cursor", runtime: "cursor", access: { kind: "subscription" }, home: "homes/cur", env: {} };

test("subscriptions shared, lent, hashed by their logins, named by their accounts and handed over wait on no file", async () => {
  const all = new Map<string, Station>();
  const a = station(A, all, [CLAUDE, CODEX, GROK, CURSOR]);
  // B has the SuperGrok account already (the same one taken), and a Cursor account of its own.
  const b = station(B, all, [{ ...GROK, id: "bg", home: "homes/bg" }, { ...CURSOR, id: "bcur", home: "homes/bcur" }]);
  all.set(A, a).set(B, b);
  const write = (path: string, text: string) => (mkdirSync(dirname(path), { recursive: true }), writeFileSync(path, text));
  const home = (s: Station, id: string) => join(s.data, "homes", id);
  write(join(home(a, "max"), ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "x", refreshToken: "r" } }));
  write(join(home(a, "max"), ".claude.json"), JSON.stringify({ oauthAccount: { emailAddress: "max@x.test" } }));
  const codexLogin = (exp: number) => JSON.stringify({ tokens: { id_token: jwt({ email: "plus@x.test" }), access_token: jwt({ exp }), account_id: "acct", refresh_token: "r" } });
  write(join(home(a, "plus"), "auth.json"), codexLogin(Math.floor(Date.now() / 1000) + 2 * 86400));
  write(grokAuthFile(home(a, "g")), JSON.stringify({ x: { email: "g@x.test" } }));
  write(grokAuthFile(home(b, "bg")), JSON.stringify({ x: { email: "g@x.test" } }));
  write(cursorAuthFile(home(a, "cur")), JSON.stringify({ apiKey: "k", email: "cur@x.test" }));
  write(cursorAuthFile(home(b, "bcur")), JSON.stringify({ apiKey: "k2", email: "other@x.test" }));

  let lentUntil = 0;
  let lentRefresh = "";
  let copyEmail = "";
  let token = "";
  const moved: Record<string, unknown> = {};
  const calls = await syncCalls(async () => {
    await a.sharing.shareProfile("max", true, null);
    await a.sharing.shareProfile("plus", true, null);
    await settle(a, b);
    // The Codex login renewed on its host: its copies told a new version (its hash is its login's).
    await writeFile(join(home(a, "plus"), "auth.json"), codexLogin(Math.floor(Date.now() / 1000) + 3 * 86400));
    await settle(a, b);
    const copy = b.config.raw().profiles.find((p: any) => p.share?.id !== undefined && p.runtime === "codex");
    lentUntil = await b.sharing.lendCodex({ ...copy, home: join(b.data, copy.home) });
    copyEmail = copy.share.email;
    lentRefresh = JSON.parse(await readFile(join(b.data, copy.home, "auth.json"), "utf8")).tokens.refresh_token;
    const claude = b.config.raw().profiles.find((p: any) => p.share?.id !== undefined && p.runtime === "claude");
    token = (await b.sharing.lendClaude(claude)).token;
    // Handed over: a shared one (share.take), one not shared whose account B has (taken as it), one B has not.
    moved.max = await a.sharing.moveProfile("max", B);
    moved.plus = await a.sharing.moveProfile("plus", B);
    moved.g = await a.sharing.moveProfile("g", B);
    moved.cur = await a.sharing.moveProfile("cur", B);
    await settle(a, b);
  });
  assert.deepEqual(others(calls), []);
  assert.ok(lentUntil > Date.now() + 2 * 86400_000, "the renewed login lent");
  assert.equal(lentRefresh, "lent-by-another-station");
  const taken = b.config.raw().profiles.find((p: any) => p.runtime === "codex");
  assert.equal(JSON.parse(readFileSync(join(b.data, taken.home, "auth.json"), "utf8")).tokens.refresh_token, "r", "handed over whole: B renews it now");
  assert.equal(token, "token-of-max");
  const copies = b.config.raw().profiles;
  assert.equal(copyEmail, "plus@x.test", "named by its id token");
  const max = copies.find((p: any) => p.runtime === "claude");
  assert.equal(max.share.borrowed, undefined, "hosted there now");
  assert.equal(JSON.parse(readFileSync(join(b.data, max.home, ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "r");
  assert.equal(a.config.raw().profiles.find((p: any) => p.id === "max")?.share?.email, "max@x.test", "named by its account record");
  const plus = a.config.raw().profiles.find((p: any) => p.id === "plus");
  assert.equal(plus?.share?.borrowed, true, "the Codex one borrowed from B now");
  assert.equal(plus?.share?.email, "plus@x.test", "named by its login read before it went");
  assert.equal(existsSync(join(home(a, "plus"), "auth.json")), false, "its login gone from A");
  assert.deepEqual(moved.g, { id: "bg" }, "the same account's taken");
  assert.equal((moved.cur as { id: string }).id, "cur");
  assert.equal(JSON.parse(readFileSync(cursorAuthFile(join(b.data, "homes", "cur")), "utf8")).email, "cur@x.test");
  assert.equal(a.config.raw().profiles.some((p: any) => p.id === "g" || p.id === "cur"), false, "gone from A");
});
