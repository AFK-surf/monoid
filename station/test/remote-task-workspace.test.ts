// Another station's task runs here under `remote:<workspace>:<station>:<session>` (jobs/remote.ts), a session this
// station has no row of: it is that workspace's, whichever this station's home is (store/rows.ts `seesMissing`), for
// what a path names (api/seen.ts), the job events (`jobSeen`) and GET /jobs (`openJobs`, by the workspace's up jobs'
// own range of the index). A key of no such form stays the home workspace's, as a session not there always was.
import assert from "node:assert/strict";
import { test } from "node:test";
import { openJobs } from "./reference/jobs.ts";
import { makeStore } from "./reference/store.ts";
import { WORKSPACE_UP_JOBS } from "./reference/backfill/workspace-up-jobs.ts";
import { elsewhere, jobSeen, sessionSeen } from "../src/api/seen.ts";
import { Store } from "../src/store/store.ts";

const viewer = (workspace: string, home?: boolean) => ({ sub: "a@example.test", email: "a@example.test", name: "A",
  role: "member", workspace, ...(home === undefined ? {} : { home }), device: "dev" } as const);
const HOME = viewer("w1", true), HOME_UNSAID = viewer("w1"), JOINED = viewer("w2", false), THIRD = viewer("w3", false),
  COLON = viewer("w2:st", false);

/// Each job's session, and who sees it.
const KEYS: [string, string[]][] = [
  ["remote:w1:st:a", ["w1"]],
  ["remote:w2:st:b", ["w2"]],
  ["remote:w3:st:c", ["w3"]],
  ["remote:w2:st:g:h", ["w2"]],
  ["remote:w2:st:é", ["w2"]],
  // of no such form: the home workspace's
  ["remote:w2", ["w1"]],
  ["remote:w2:st:", ["w1"]],
  ["remote:w2/x:st:d", ["w1"]],
  ["remote:w2:st/x:f", ["w1"]],
  ["remote::st:e", ["w1"]],
  ["remote:w2:st:a\nb", ["w1"]],
  ["nobody", ["w1"]],
  ["zzz", ["w1"]],
  // sessions here
  ["mine", ["w2"]],
  ["home", ["w1"]],
];

function world(): Store {
  const s = Store.open(":memory:");
  s.insertSession({ key: "mine", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "mine", createdAt: 1, lastActiveAt: 1, ws: "w2" });
  s.insertSession({ key: "home", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "home", createdAt: 1, lastActiveAt: 1, ws: null });
  KEYS.forEach(([key], i) => s.insertJob({ id: `j${i}`, sessionKey: key, name: key, command: "true", cwd: "/", port: i % 3 === 0 ? 5000 + i : null,
    token: `t${i}`, state: i % 3 === 0 ? "exited" : "running", pgid: null, exitCode: null, startedAt: 100 - i, endedAt: null, restarts: 0, log: "/dev/null", watch: false }));
  return s;
}
const seenBy = (ws: string) => KEYS.filter(([, who]) => who.includes(ws)).map(([key]) => key);
const idOf = (key: string) => `j${KEYS.findIndex(([k]) => k === key)}`;

test("another station's task is seen by its own workspace, a joined one or the home one", () => {
  const s = world();
  try {
    for (const v of [HOME, HOME_UNSAID, JOINED, THIRD, COLON]) {
      const ws = v.workspace === "w2:st" ? "none" : v.workspace;
      assert.deepEqual(KEYS.filter(([key]) => sessionSeen(s, v, key)).map(([key]) => key), seenBy(ws), `sessions, ${v.workspace}`);
      assert.deepEqual(KEYS.filter(([key]) => jobSeen(s, v, idOf(key))).map(([key]) => key), seenBy(ws), `jobs, ${v.workspace}`);
      assert.deepEqual(KEYS.filter(([key]) => elsewhere(s, `/jobs/${encodeURIComponent(idOf(key))}`, v) === null).map(([key]) => key), seenBy(ws), `paths, ${v.workspace}`);
    }
  } finally { s.close(); }
});

for (const ready of [true, false]) test(`GET /jobs lists another station's tasks to their workspace alone (prepared ${ready})`, () => {
  const s = world();
  try {
    if (!ready) s.db.exec("UPDATE workspace_up_meta SET ready=0");
    const returned: string[] = [];
    const observed = new Proxy(s.db, { get(target, property) {
      if (property === "prepare") return (sql: string) => {
        const statement = target.prepare(sql);
        if (!/\bFROM\s+jobs\b/i.test(sql) && sql !== WORKSPACE_UP_JOBS) return statement;
        return new Proxy(statement, { get(stmt, method) {
          const value = Reflect.get(stmt, method, stmt);
          if (method === "all") return (...args: any[]) => {
            const rows = value.apply(stmt, args);
            for (const row of rows) if (typeof row.session_key === "string") returned.push(row.session_key);
            return rows;
          };
          return typeof value === "function" ? value.bind(stmt) : value;
        } });
      };
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    } });
    const reader = makeStore(observed, ".");
    for (const v of [HOME, HOME_UNSAID, JOINED, THIRD, COLON]) {
      const ws = v.workspace === "w2:st" ? "none" : v.workspace;
      returned.length = 0;
      const listed = openJobs(reader, v, "en", false).map((j) => j.session as string);
      assert.deepEqual([...listed].sort(), seenBy(ws).sort(), `listed, ${v.workspace}`);
      // Read of SQLite: none of another workspace's but what only JavaScript can tell (a key not printable).
      const others = returned.filter((key) => !seenBy(ws).includes(key) && /^[\x20-\x7e]*$/.test(key));
      assert.deepEqual(others, [], `read, ${v.workspace}`);
    }
  } finally { s.close(); }
});

test("a workspace's up jobs are found by ranges of the covering index alone", (t) => {
  const s = world();
  try {
    for (const [ws, home] of [["w1", 1], ["w2", 0]] as const) {
      const plan = (s.db.prepare(`EXPLAIN QUERY PLAN ${WORKSPACE_UP_JOBS}`).all(ws, home) as { detail: string }[]).map((r) => r.detail);
      t.diagnostic(`${ws} home ${home}:\n  ${plan.join("\n  ")}`);
      const index = plan.filter((d) => /workspace_up_sessions\b/.test(d));
      assert.equal(index.length, 6, plan.join("\n"));
      for (const d of index) assert.match(d, /^SEARCH workspace_up_sessions USING COVERING INDEX workspace_up_sessions_scope \(scope=\? AND ws=\?/);
      // the remote ranges: by the session too
      assert.equal(index.filter((d) => /session[<>]\?/.test(d)).length, 4, plan.join("\n"));
      assert.deepEqual(plan.filter((d) => /^SCAN /.test(d)), ["SCAN w"], plan.join("\n"));
    }
  } finally { s.close(); }
});

test("a queued task says so until it starts, and started is when it did", () => {
  let now = 1_000;
  const s = Store.open(":memory:", null, { currentTimeMillisUnsafe: () => now } as never);
  try {
    const job = (id: string, queued: boolean) => s.insertJob({ id, sessionKey: "remote:w1:st:a", name: id, command: "true", cwd: "/", port: null,
      token: id, state: "running", pgid: null, exitCode: null, startedAt: now, endedAt: null, restarts: 0, log: "/dev/null", watch: false,
      ...(queued ? { queued: true, screen: false } : {}) });
    job("remote_q", true);
    job("remote_r", false);
    const listed = () => Object.fromEntries(openJobs(makeStore(s.db, "."), HOME, "en", false).map((j) => [j.id, j]));
    assert.equal(listed().remote_q!.queued, true);
    assert.equal("queued" in listed().remote_r!, false);
    now = 61_000;
    s.jobStarted("remote_q", 42, false);
    s.jobStarted("remote_r", 43, false);
    assert.equal(s.getJob("remote_q")!.startedAt, 61_000);
    assert.equal(s.getJob("remote_r")!.startedAt, 1_000, "one that never waited started when it was made");
    assert.equal("queued" in listed().remote_q!, false);
    assert.equal(listed().remote_q!.startedAt, 61_000);
    now = 90_000;
    s.jobStarted("remote_q", 44, true);
    assert.equal(s.getJob("remote_q")!.startedAt, 61_000, "started again, it keeps when it first started");
  } finally { s.close(); }
});
