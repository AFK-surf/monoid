// What a migration's plan is (move/scheduler.ts `plan`, over the modules move/station.ts makes) on a station with every
// case the chats plan knows, held to a dump of it as it was before its reads went by pages (each item: module, id,
// label, needs, cannot, state, wouldStop), so that how it reads never changes what it says.
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { sessionKey } from "../src/sessions/hub.ts";
import { MANUAL, comingWs } from "../src/store/rows.ts";
import { A, B, WS, world } from "./move-world.ts";

type Json = any;

/// A's chats and accounts with every case a plan knows (keys and paths fixed, so the dump says the same each run).
function cases() {
  const w = world();
  const a = w.get(A);
  const store = a.rig.store;
  const room = (n: string) => join(a.rig.dir, "sessions", n, "workspace");
  a.rig.raw.profiles.push(
    { id: "bor", runtime: "claude", home: "homes/bor", share: { id: "sh-b", borrowed: true, host: B } },
    { id: "solo", runtime: "claude", home: "homes/solo" },
  );
  a.rig.raw.connects.push(
    { id: "team", mode: "single-session", bind: { runtime: "claude" } },
    { id: "cm", comma: { token: "t" }, bind: { runtime: "claude" } },
  );
  let n = 0;
  const chat = (key: string, o: { connect?: string; profile?: string; ws?: string | null; workspace?: string; title?: string; surface?: string; ts?: string; home?: boolean; ran?: string[] } = {}) => {
    const i = n++;
    const connect = o.connect ?? "cl";
    store.insertSession({ key, connect, runtime: "claude", profile: o.profile ?? "cc", workspace: o.workspace ?? room(`s${i}`), token: `tok${i}`, createdAt: 1, lastActiveAt: 1, ws: o.ws === undefined ? null : o.ws, ...(o.title ? { title: o.title } : {}) });
    const ts = o.ts ?? `${1700000000 + i}.000100`;
    const t = store.openThreadOf(o.surface ?? "slack:T1", o.surface === "ember" ? "CHAT" : "C1", ts, null, "p@x", o.home === true ? key : null);
    store.joinThread(t.id, key, connect === "ember" ? "ember" : connect);
    for (const r of o.ran ?? []) store.ranIn(key, `run-${key}-${r}`, r);
    return t;
  };
  chat(sessionKey("cl", "C1", "1.1"), { title: "a Slack thread", ts: "1.1", ran: ["cx"] });
  chat(sessionKey("cl", "C1", "1.2"), { ts: "1.2", ws: WS, profile: "bor" });
  chat(sessionKey("gpt", "C1", "1.3"), { connect: "gpt", ts: "1.3", profile: "mine" });
  chat(sessionKey("cl", "C1", "1.4"), { ts: "1.4", workspace: "/elsewhere/proj" });
  const archived = sessionKey("cl", "C1", "1.5");
  chat(archived, { ts: "1.5", workspace: "/elsewhere/old" });
  store.setArchived(archived, true, MANUAL);
  chat("team:all", { connect: "team", ts: "1.6", profile: "solo" });
  chat(sessionKey("cm", "C9", "1.7"), { connect: "cm", ts: "1.7" });
  // (a still.fail chat two sessions share: one item, its sessions together)
  const shared = chat("chat:c-0001", { connect: "ember", surface: "ember", ts: "1.8", home: true, title: "a chat of two" });
  store.insertSession({ key: "chat:c-0002", connect: "ember", runtime: "codex", profile: "cx", workspace: room("s-two"), token: "tok-two", createdAt: 1, lastActiveAt: 1, ws: null });
  store.joinThread(shared.id, "chat:c-0002", "ember");
  // (handed to B: there; coming from B, not shown yet: not in the plan; of another workspace: not in it either)
  chat(sessionKey("cl", "C1", "1.9"), { ts: "1.9" });
  store.handOff([sessionKey("cl", "C1", "1.9")], B, WS, {});
  chat(sessionKey("cl", "C1", "2.0"), { ts: "2.0", ws: comingWs(WS) });
  chat(sessionKey("cl", "C1", "2.1"), { ts: "2.1", ws: "other-ws" });
  // (jobs of two chats)
  a.jobs.push({ id: "A-job-0", session: sessionKey("cl", "C1", "1.1"), name: "dev", cwd: room("s0"), command: "npm run dev" } as Json, { id: "A-job-1", session: "chat:c-0002", name: "watch", cwd: room("s-two"), command: "tsc -w" } as Json);
  mkdirSync(room("s0"), { recursive: true });
  // (linked worktrees, as git leaves them: a canonical clone of the repository cache with two chats' worktrees, one of
  // them archived; a clone outside the cache with a worktree in a chat's room; a chat's own repository in its room; a
  // worktree whose clone is gone)
  const clone = (dir: string, url: string) => {
    mkdirSync(join(dir, ".git"), { recursive: true });
    writeFileSync(join(dir, ".git", "config"), `[core]\n\tbare = false\n[remote "origin"]\n\turl = ${url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n`);
  };
  const worktree = (repo: string, name: string, at: string) => {
    mkdirSync(join(repo, ".git", "worktrees", name), { recursive: true });
    writeFileSync(join(repo, ".git", "worktrees", name, "gitdir"), `${join(at, ".git")}\n`);
    mkdirSync(at, { recursive: true });
    writeFileSync(join(at, ".git"), `gitdir: ${join(repo, ".git", "worktrees", name)}\n`);
  };
  const cache = join(a.rig.dir, "repos", "shared");
  clone(cache, "https://example.test/shared.git");
  const elsewhere = join(a.rig.dir, "elsewhere", "own");
  clone(elsewhere, "https://example.test/own.git");
  a.elsewhere = [elsewhere];
  const linked = (k: string, n: string) => chat(sessionKey("cl", "C1", k), { ts: k, workspace: room(n) });
  linked("3.1", "w1");
  worktree(cache, "w1", join(room("w1"), "shared"));
  linked("3.2", "w2");
  worktree(cache, "w2", join(room("w2"), "shared"));
  store.setArchived(sessionKey("cl", "C1", "3.2"), true, MANUAL);
  linked("3.3", "w3");
  worktree(elsewhere, "w3", join(room("w3"), "own"));
  linked("3.4", "w4");
  clone(room("w4"), "https://example.test/standalone.git");
  linked("3.5", "w5");
  mkdirSync(join(room("w5"), "old"), { recursive: true });
  writeFileSync(join(room("w5"), "old", ".git"), `gitdir: ${join(a.rig.dir, "gone", ".git", "worktrees", "old")}\n`);
  return { w, a };
}

/// A plan as lines, one an item, in its order.
const dump = (plan: Json) => plan.items.map((x: Json) => [x.module, x.id, x.label, x.needs.map((n: Json) => `${n.module} ${n.id}`).join(","), x.cannot ?? "", x.state, x.wouldStop.map((n: Json) => `${n.module} ${n.id}`).join(",")].join(" | ").replaceAll(A, "A").replaceAll(B, "B"));
const printDump = process.env.MOVE_PLAN_DUMP === "1";

test("a plan says of every chat, account, job and connect what it said before its reads went by pages", async () => {
  const { a } = cases();
  const got = dump(await a.moves.scheduler.plan(WS, B));
  if (printDump) console.log(`DUMP\n${got.join("\n")}\nEND`);
  assert.deepEqual(got, WANT);
});

const WANT: string[] = [
  "accounts | share:sh-cc | cc |  |  | there | ",
  "accounts | key:f663c3465c5f0b8b63e89ebd3a687043 | cx |  |  | there | chats chat:c-0001,chats cl:C1:1.1",
  "accounts | share:sh-b | bor |  |  | here | ",
  "accounts | machine:mine | mine |  | this machine's own login cannot go to another station: sign in there with the login tool | here | chats gpt:C1:1.3",
  "accounts | own:solo@A | solo |  |  | here | chats team:all",
  "chats | chat:c-0001 | a chat of two | accounts share:sh-cc,accounts key:f663c3465c5f0b8b63e89ebd3a687043 |  | here | ",
  "chats | cl:C1:1.1 | a Slack thread | accounts share:sh-cc,accounts key:f663c3465c5f0b8b63e89ebd3a687043 |  | here | jobs cl:C1:1.1#dev,connects cl@A",
  "chats | cl:C1:1.2 | cl:C1:1.2 | accounts share:sh-b |  | here | connects cl@A",
  "chats | cl:C1:1.4 | cl:C1:1.4 | accounts share:sh-cc | chat cl:C1:1.4 works in /elsewhere/proj, which is not this station's own: its files would not go; ask again with its files left behind if that is meant | here | connects cl@A",
  "chats | cl:C1:1.5 | cl:C1:1.5 | accounts share:sh-cc |  | here | connects cl@A",
  "chats | cl:C1:1.9 | cl:C1:1.9 | accounts share:sh-cc |  | there | connects cl@A",
  "chats | cl:C1:3.1 | cl:C1:3.1 | accounts share:sh-cc,repos repo:https://example.test/shared.git |  | here | connects cl@A",
  "chats | cl:C1:3.2 | cl:C1:3.2 | accounts share:sh-cc,repos repo:https://example.test/shared.git |  | here | connects cl@A",
  "chats | cl:C1:3.3 | cl:C1:3.3 | accounts share:sh-cc,repos repo:https://example.test/own.git |  | here | connects cl@A",
  "chats | cl:C1:3.4 | cl:C1:3.4 | accounts share:sh-cc |  | here | connects cl@A",
  "chats | cl:C1:3.5 | cl:C1:3.5 | accounts share:sh-cc |  | here | connects cl@A",
  "chats | cm:C9:1.7 | cm:C9:1.7 | accounts share:sh-cc |  | here | connects cm@A",
  "chats | gpt:C1:1.3 | gpt:C1:1.3 | accounts machine:mine |  | here | connects gpt@A",
  "chats | team:all | team:all | accounts own:solo@A,connects team@A |  | here | ",
  "jobs | cl:C1:1.1#dev | dev (npm run dev) | chats cl:C1:1.1 |  | here | ",
  "jobs | chat:c-0002#watch | watch (tsc -w) | chats chat:c-0002 |  | here | ",
  "connects | cl@A | cl | chats cl:C1:1.1,chats cl:C1:1.2,chats cl:C1:1.4,chats cl:C1:1.5,chats cl:C1:1.9,chats cl:C1:2.0,chats cl:C1:2.1,chats cl:C1:3.1,chats cl:C1:3.2,chats cl:C1:3.3,chats cl:C1:3.4,chats cl:C1:3.5 |  | here | ",
  "connects | gpt@A | gpt | chats gpt:C1:1.3 |  | here | ",
  "connects | team@A | team |  |  | here | chats team:all",
  "connects | cm@A | cm | chats cm:C9:1.7 |  | here | ",
  "repos | repo:https://example.test/shared.git | shared |  |  | here | ",
  "repos | repo:https://example.test/own.git | own |  |  | here | ",
  "agent-home | home:ws | the agents' memory, presets and skills |  |  | here | ",
  "settings | setting:askToName | askToName |  |  | here | ",
];
