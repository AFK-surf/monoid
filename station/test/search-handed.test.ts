// The station's search (the MoonBit program's, #6381: search/search.ts) leaves out the chats it handed to another
// station: it reads a chat's workspace off its sessions' rows, which say `handed:<ws>` once it went (store `handOff`),
// so no asker sees it, before and after the candidate scopes and the session list are prepared. The reference walk
// (test/reference/search-sources.ts, what the program's answers are compared with) is held to the same.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { historySessionSnapshot, makeStore } from "./reference/store.ts";
import { type Asker, type Hit, pick } from "../src/search/match.ts";
import { SearchScopePreparation } from "./reference/search-scope-prepare.ts";
import { Search } from "../src/search/search.ts";
import { auditSessionListStep } from "./reference/backfill/session-list-index.ts";
import { Store } from "../src/store/store.ts";
import { stationDocs } from "./reference/search-sources.ts";

const binary = mbReaderBinary();

/// Two chats of workspace w and two of the home one, each with a job; one of each handed to station b. In a file, for
/// the program reads the station's database as the station keeps it.
function station() {
  const data = mkdtempSync(join(tmpdir(), "search-handed-"));
  const writer = Store.open(join(data, "stillfail.db"), join(data, "archive"));
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
  return { data, writer, threads, close: () => { writer.close(); rmSync(data, { recursive: true, force: true }); } };
}

const askers: Asker[] = [{ workspace: "w", home: false, scopes: [] }, { workspace: "w", home: true, scopes: [] }];
const wanted = (asker: Asker) => asker.home ? ["kept", "kept-home"] : ["kept"];

/// The candidate scopes and the session list prepared, as the station's builders prepare them.
function prepare(db: Store["db"]) {
  const preparation = new SearchScopePreparation(db);
  let done = false;
  for (let i = 0; i < 100 && !done; i++) done = preparation.step().done;
  assert.ok(done);
  for (let i = 0; i < 20 && !auditSessionListStep(db, 64).done; i++);
}

/// What each asker finds of chats and jobs, by `find`, held to the chats kept.
async function holds(find: (asker: Asker, kind: string) => Hit[] | Promise<Hit[]>, threads: Record<string, number>, said: string) {
  for (const asker of askers) {
    const want = wanted(asker);
    const chats = (await find(asker, "chat")).map((h) => h.thread as number).sort();
    assert.deepEqual(chats, want.map((k) => threads[k]!).sort(), `chats, ${said}, home ${asker.home}`);
    const jobs = (await find(asker, "job")).map((h) => h.key).sort();
    assert.deepEqual(jobs, want.map((k) => `j:job-${k}`).sort(), `jobs, ${said}, home ${asker.home}`);
  }
}

test("the station's search leaves out the chats it handed to another station: their chats, messages, jobs and histories",
  { skip: binary === null ? "the MoonBit program is not built here" : false }, async () => {
    const f = station();
    try {
      const read = makeStore(f.writer.db, f.data);
      for (const prepared of [false, true]) {
        if (prepared) prepare(f.writer.db);
        const said = prepared ? "prepared" : "not prepared";
        // The program, started on the station's data as it is now (stopped with its builders before it is prepared here).
        const program = new Search({ data: f.data });
        program.start();
        try {
          await holds((asker, kind) => program.query("needle", asker, { kinds: [kind], limit: 50 }).then((found) => found.groups.flatMap((g) => g.hits)), f.threads, `the program, ${said}`);
        } finally { await program.stop(); }
        await holds((asker, kind) => pick(stationDocs(read, f.data, {}, new Set([kind]), asker), ["needle"], asker, { limit: 50 }).flatMap((g) => g.hits), f.threads, `the reference, ${said}`);
        for (const asker of askers) {
          const histories = historySessionSnapshot(read, asker);
          try {
            assert.deepEqual([...histories].map((s) => s.key).sort(), wanted(asker).sort(), `histories, ${said}, home ${asker.home}`);
          } finally { histories.close(); }
        }
      }
    } finally { f.close(); }
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
