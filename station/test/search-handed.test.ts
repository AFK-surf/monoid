import assert from "node:assert/strict";
import { test } from "node:test";
import { historySessionSnapshot, makeStore } from "../src/read/store.ts";
import { type Asker, pick } from "../src/search/match.ts";
import { SearchScopePreparation } from "../src/search/scope-prepare.ts";
import { stationDocs } from "../src/search/sources.ts";
import { auditSessionListStep } from "../src/store/session-list-index.ts";
import { Store } from "../src/store/store.ts";

/// Two chats of workspace w and two of the home one, each with a job; one of each handed to station b.
function station() {
  const writer = Store.open(":memory:");
  const job = writer.db.prepare(`INSERT INTO jobs(id,session_key,name,command,cwd,token,state,started_at,log)
    VALUES(?,?,'needle','run','/work',?,'exited',1,'')`);
  const threads: Record<string, number> = {};
  for (const [key, ws] of [["kept", "w"], ["gone", "w"], ["kept-home", null], ["gone-home", null]] as const) {
    writer.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: "/work", token: key, createdAt: 1, lastActiveAt: 1, ws });
    const thread = writer.openThreadOf("ember", "CHAT", key, "needle", null, key);
    writer.joinThread(thread.id, key, "ember");
    threads[key] = thread.id;
    job.run(`job-${key}`, key, `job-${key}`);
  }
  writer.handOff(["gone"], "b", "home", { gone: { thread: threads.gone!, there: 9 } });
  writer.handOff(["gone-home"], "b", "home", { "gone-home": { thread: threads["gone-home"]!, there: 10 } });
  return { writer, threads };
}

const found = (read: ReturnType<typeof makeStore>, asker: Asker, kind: string) =>
  pick(stationDocs(read, ".", {}, new Set([kind]), asker), ["needle"], asker, { limit: 50 }).flatMap((g) => g.hits);

test("the station's search leaves out the chats it handed to another station: their chats, messages, jobs and histories", () => {
  const { writer, threads } = station();
  try {
    const read = makeStore(writer.db, ".");
    for (const prepared of [false, true]) {
      if (prepared) {
        const preparation = new SearchScopePreparation(writer.db);
        let done = false;
        for (let i = 0; i < 100 && !done; i++) done = preparation.step().done;
        assert.ok(done);
        for (let i = 0; i < 20 && !auditSessionListStep(writer.db, 64).done; i++);
      }
      for (const asker of [{ workspace: "w", home: false, scopes: [] }, { workspace: "w", home: true, scopes: [] }] satisfies Asker[]) {
        const want = asker.home ? ["kept", "kept-home"] : ["kept"];
        const chats = found(read, asker, "chat").map((h) => h.thread).sort();
        assert.deepEqual(chats, want.map((k) => threads[k]).sort(), `chats, ${prepared ? "prepared" : "not prepared"}, home ${asker.home}`);
        const jobs = found(read, asker, "job").map((h) => h.key).sort();
        assert.deepEqual(jobs, want.map((k) => `j:job-${k}`).sort(), `jobs, home ${asker.home}`);
        const histories = historySessionSnapshot(read, asker);
        try {
          assert.deepEqual([...histories].map((s) => s.key).sort(), want.sort(), `histories, home ${asker.home}`);
        } finally { histories.close(); }
      }
    }
  } finally { writer.close(); }
});

test("a chat's row stops saying the station it came from as soon as it is handed on, wherever to", () => {
  const writer = Store.open(":memory:");
  try {
    writer.insertSession({ key: "s", connect: "ember", runtime: "claude", profile: "cc", workspace: "/work", token: "s", createdAt: 1, lastActiveAt: 1, ws: "w" });
    writer.db.prepare("UPDATE sessions SET came_from = 'a', began_on = 'a' WHERE key = 's'").run();
    assert.equal(writer.getSession("s")!.from, "a");
    writer.handOff(["s"], "c", "home", {});
    assert.equal(writer.getSession("s")!.from, undefined);
    // Where it began is kept: the station it goes to next tells from that whether it came back home.
    assert.equal((writer.db.prepare("SELECT began_on FROM sessions WHERE key = 's'").get() as { began_on: string }).began_on, "a");
  } finally { writer.close(); }
});
