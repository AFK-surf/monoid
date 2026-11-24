import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, sep } from "node:path";
import { test } from "node:test";
import {
  MbProcess,
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import type { ReaderSelectConfig } from "../src/read/reader-select.ts";
import { Search } from "../src/search/search.ts";
import { packFile } from "../src/sessions/archive.ts";
import { Store, newMessage } from "../src/store/store.ts";

function resolveDualBinaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const realMb = mbReaderBinary();
  const explicitPion = process.env.STILLFAIL_PION_READER?.trim();
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const realPion = pionBinary();

  if (realMb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here");
    return null;
  }
  if (explicitPion || requireDual) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is required (${explicitPion ?? "unset"}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(realMb), realpathSync(realPion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(realPion, ["--version"], { encoding: "utf8" });
  assert.match(ver, /modes:[^\n]*\bsearch\b/, `Pion --version must advertise search: ${ver}`);
  return { mb: realMb, pion: realPion };
}

function makeRecordingWrapper(dir: string, name: string, realBin: string, logFile: string): string {
  const wrapper = join(dir, name);
  const sh = [
    "#!/bin/sh",
    `printf '%s %s\\n' "$$" "$*" >> ${JSON.stringify(logFile)}`,
    `exec ${JSON.stringify(realBin)} "$@"`,
    "",
  ].join("\n");
  writeFileSync(wrapper, sh, "utf8");
  chmodSync(wrapper, 0o755);
  return wrapper;
}

function readSpawns(logFile: string): string[] {
  if (!existsSync(logFile)) return [];
  return readFileSync(logFile, "utf8").split("\n").map((s) => s.trim()).filter(Boolean);
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  resetReaderSelectionStateForTest();
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
}

class RawLineClient {
  readonly child: ReturnType<typeof spawn>;
  #buf = "";
  #lines: string[] = [];
  #waiters: ((line: string) => void)[] = [];

  constructor(bin: string, args: string[]) {
    this.child = spawn(bin, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.child.stdout!.setEncoding("utf8");
    this.child.stdout!.on("data", (chunk: string) => {
      this.#buf += chunk;
      for (;;) {
        const nl = this.#buf.indexOf("\n");
        if (nl < 0) break;
        const line = this.#buf.slice(0, nl);
        this.#buf = this.#buf.slice(nl + 1);
        const w = this.#waiters.shift();
        if (w) w(line);
        else this.#lines.push(line);
      }
    });
  }

  writeRaw(text: string): void {
    this.child.stdin!.write(text);
  }

  send(obj: unknown): void {
    this.child.stdin!.write(`${JSON.stringify(obj)}\n`);
  }

  nextLine(): Promise<string> {
    if (this.#lines.length > 0) return Promise.resolve(this.#lines.shift()!);
    return new Promise((resolve, reject) => {
      const onExit = (code: number | null) => {
        reject(new Error(`process exited prematurely (code=${code}) while awaiting line`));
      };
      this.child.once("exit", onExit);
      this.#waiters.push((line) => {
        this.child.off("exit", onExit);
        resolve(line);
      });
    });
  }

  async nextJson(): Promise<any> {
    return JSON.parse(await this.nextLine());
  }

  async close(): Promise<void> {
    if (this.child.exitCode !== null || this.child.signalCode !== null) return;
    await new Promise<void>((resolve) => {
      this.child.once("exit", () => resolve());
      this.child.stdin!.end();
    });
  }
}

function makeFixture() {
  const dir = mkdtempSync(join(tmpdir(), "w6-search-switch-"));
  const dbPath = join(dir, "stillfail.db");
  const store = Store.open(dbPath, join(dir, "archive"));

  const addSession = (key: string, runtime: string, ws: string | null, lastActiveAt: number) => {
    store.insertSession({
      key,
      connect: "ember",
      runtime,
      profile: "cc",
      workspace: `/w/${key}`,
      token: `tok-${key}`,
      createdAt: 1,
      lastActiveAt,
      ws,
    } as Parameters<Store["insertSession"]>[0]);
  };

  addSession("s-chat", "claude", "W1", 10);
  const tid = store.openThreadOf("ember", "ember", "s-chat", null, "a@x", "s-chat").id;
  store.joinThread(tid, "s-chat", "ember");

  // Populate 1,800 messages across 8 batches (256/batch) so a message scan yields >= 7 times at P1.
  let ts = 0;
  for (let i = 0; i < 1800; i++) {
    const body = i === 1750 ? "slowneedle final batch hit" : `filler message number ${i} padding text`;
    store.insertMessage({ ...newMessage(tid, String(++ts), "person", "a@x", body) } as ReturnType<typeof newMessage>);
  }
  // Message whose UTF-16 excerpt boundary cuts right through a surrogate pair (😀 at units 2..3, needle at unit 83).
  store.insertMessage({
    ...newMessage(tid, String(++ts), "person", "a@x", `xx😀${"a".repeat(79)}surrogateneedle`),
  } as ReturnType<typeof newMessage>);

  // Profile for fast single-step query B.
  writeFileSync(
    join(dir, "config.json"),
    JSON.stringify({
      profiles: [{ id: "fastprof", home: "homes/fast", runtime: "claude", name: "FastProfileHit" }],
    }),
  );

  // Two large multi-chunk history transcripts (> 512 KiB each -> multiple `text.next` chunks across P11)
  // Session A: large transcript with match only at the very end.
  // Session B: large transcript with a match at the end and a word near the chunk overlap boundary.
  const put = (path: string, text: string) => {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  };
  addSession("h-a", "claude", "W1", 100);
  store.ranIn("h-a", "ha1", "cc");
  store.setRuntimeSessionId("h-a", "ha1");
  const fillerLine = `${JSON.stringify({ type: "assistant", message: { content: "x".repeat(400) } })}\n`;
  const bigA = fillerLine.repeat(1400) + `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T10:00:00Z", message: { content: "alphaonlytoken" } })}\n`;
  put(join(dir, "transcripts", "claude", "-w-h-a", "ha1.jsonl"), bigA);

  addSession("h-b", "claude", "W1", 90);
  store.ranIn("h-b", "hb1", "cc");
  store.setRuntimeSessionId("h-b", "hb1");
  const bigB = fillerLine.repeat(1400) + `${JSON.stringify({ type: "assistant", timestamp: "2026-11-01T11:00:00Z", message: { content: "betaonlytoken overlapcheck" } })}\n`;
  put(join(dir, "transcripts", "claude", "-w-h-b", "hb1.jsonl"), bigB);

  return {
    dir,
    dbPath,
    store,
    close: () => {
      store.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

function openFdCount(pid: number): number | null {
  if (process.platform !== "linux") return null;
  try {
    return readdirSync(`/proc/${pid}/fd`).length;
  } catch {
    return null;
  }
}

test("deterministic no-sleep concurrency: fast query B overtakes slow query A; interleaved multi-chunk history cancel A preserves B and closes A text.* handles (0 FD leak)", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture();
  const asker = { workspace: "W1", home: true, scopes: [] };
  const client = new RawLineClient(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
  try {
    // 1. Slow message scan (A, id=1) + fast profile query (B, id=2) sent back-to-back in one write:
    //    B has 0 thread/job/memory batches and finishes in 2 steps (ProfileRun -> FinalPause),
    //    while A yields >= 7 times across P1 message batches -> B MUST return before A!
    const qSlow = JSON.stringify({ type: "query", id: 1, query: "slowneedle", asker, kinds: ["message"] });
    const qFast = JSON.stringify({ type: "query", id: 2, query: "FastProfileHit", asker, kinds: ["profile"] });
    client.writeRaw(`${qSlow}\n${qFast}\n`);

    const replies1: any[] = [];
    while (replies1.length < 2) {
      const m = await client.nextJson();
      if ("scopePending" in m || "sessionListPending" in m) continue;
      replies1.push(m);
    }
    assert.equal(replies1[0].id, 2, `fast query B must finish before slow query A; got order ${JSON.stringify(replies1.map((r) => r.id))}`);
    assert.equal(replies1[0].groups.length, 1);
    assert.equal(replies1[0].groups[0].kind, "profile");
    assert.equal(replies1[1].id, 1);
    assert.equal(replies1[1].groups.length, 1);
    assert.equal(replies1[1].groups[0].kind, "message");

    // 2. Two multi-chunk history queries A (id=10) & B (id=11) interleaved mid-`parts`, cancel A:
    //    A must fail with "the search took too long", B must succeed with intact tail/left!
    const fdBase = openFdCount(client.child.pid!);
    const qHistA = JSON.stringify({ type: "query", id: 10, query: "alphaonlytoken", asker, kinds: ["history"] });
    const qHistB = JSON.stringify({ type: "query", id: 11, query: "betaonlytoken overlapcheck", asker, kinds: ["history"] });
    const cHistA = JSON.stringify({ type: "cancel", id: 10 });
    client.writeRaw(`${qHistA}\n${qHistB}\n${cHistA}\n`);

    const histReplies = new Map<number, any>();
    while (histReplies.size < 2) {
      const m = await client.nextJson();
      if ("scopePending" in m || "sessionListPending" in m) continue;
      histReplies.set(m.id, m);
    }
    assert.equal(histReplies.get(10)?.error, "the search took too long");
    assert.equal(histReplies.get(11)?.error, undefined);
    assert.equal(histReplies.get(11)?.groups?.length, 1);
    assert.equal(histReplies.get(11)?.groups[0].kind, "history");
    assert.equal(histReplies.get(11)?.groups[0].hits.length, 1);
    assert.ok(histReplies.get(11)?.groups[0].hits[0].text.includes("betaonlytoken"));

    // 3. Repeatedly cancel 12 multi-chunk history queries and assert 0 FD leak on Linux (proving text.close is called).
    for (let i = 0; i < 12; i++) {
      const qid = 100 + i;
      client.writeRaw(
        `${JSON.stringify({ type: "query", id: qid, query: "alphaonlytoken", asker, kinds: ["history"] })}\n` +
        `${JSON.stringify({ type: "cancel", id: qid })}\n`,
      );
      const ans = await client.nextJson();
      assert.equal(ans.id, qid);
      assert.equal(ans.error, "the search took too long");
    }
    const fdAfter = openFdCount(client.child.pid!);
    if (fdBase !== null && fdAfter !== null) {
      assert.ok(fdAfter <= fdBase + 1, `expected no text.* FD leak across 12 cancelled history queries: before=${fdBase} after=${fdAfter}`);
    }
  } finally {
    await client.close();
    fx.close();
  }
});

test("protocol & wire 0-diff vs real MB: unknown/finished cancel silent, numeric vs string id, 1 vs 1.0 parity, empty keywords, same-chunk query+cancel, UTF-16 lone-surrogate excerpt", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture();
  const asker = { workspace: "W1", home: true, scopes: [] };

  const runSharedScenario = async (bin: string) => {
    const c = new RawLineClient(bin, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    try {
      const rawLines: string[] = [];
      // A. Unknown id cancel -> NO reply; followed by sentinel empty query id=900
      c.writeRaw(`{"type":"cancel","id":99999}\n{"type":"query","id":900,"query":"   ","asker":${JSON.stringify(asker)}}\n`);
      rawLines.push(await c.nextLine());

      // B. Cancel already-completed id=900 -> NO reply; followed by pre-cancelled empty query id=901 (empty words returns [] without checking cancel!)
      c.writeRaw(
        `{"type":"cancel","id":900}\n` +
        `{"type":"cancel","id":901}\n` +
        `{"type":"query","id":901,"query":"","asker":${JSON.stringify(asker)}}\n`,
      );
      rawLines.push(await c.nextLine());

      // C. Numeric `1` / `1.0` vs string `"1"`:
      //    cancel `1` cancels `1.0` (both stringify to `1` in MB & Pion), and consumes the cancel so a subsequent `1` succeeds;
      //    string `"1"` is a distinct key and is unaffected.
      c.writeRaw(
        `{"type":"cancel","id":1}\n` +
        `{"type":"query","id":1.0,"query":"FastProfileHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n` +
        `{"type":"query","id":1,"query":"FastProfileHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n` +
        `{"type":"query","id":"1","query":"FastProfileHit","asker":${JSON.stringify(asker)},"kinds":["profile"]}\n`,
      );
      const trio: string[] = [];
      while (trio.length < 3) {
        const line = await c.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        trio.push(line);
      }
      rawLines.push(...trio);

      // D. Same-chunk query + cancel -> "the search took too long"
      c.writeRaw(
        `{"type":"query","id":42,"query":"slowneedle","asker":${JSON.stringify(asker)},"kinds":["message"]}\n` +
        `{"type":"cancel","id":42}\n`,
      );
      for (;;) {
        const line = await c.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        rawLines.push(line);
        break;
      }
      return rawLines;
    } finally {
      await c.close();
    }
  };

  // Normalize MoonBit Failure source-location prefix (`src/search/match.mbt:...:... FAILED: `) when comparing error replies.
  const normalize = (lines: string[]) =>
    lines
      .map((l) => {
        const obj = JSON.parse(l);
        if (typeof obj.error === "string") {
          obj.error = obj.error.replace(/^.*FAILED:\s*/, "");
        }
        return obj;
      })
      .sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));

  try {
    const [mbOut, pionOut] = [await runSharedScenario(bins.mb), await runSharedScenario(bins.pion)];
    assert.deepEqual(
      normalize(pionOut),
      normalize(mbOut),
      "Pion and MB must produce 0-diff responses across all protocol/wire cases",
    );

    // E. Pion-side UTF-16 surrogate-pair excerpt cut boundary:
    //    `js_json::stringify_line` cleanly escapes the lone trailing surrogate as `\ude00` (matching JS JSON.stringify),
    //    whereas MB's UTF-8 stdout encoder aborts on lone surrogates.
    const pc = new RawLineClient(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    try {
      pc.writeRaw(`{"type":"query","id":77,"query":"surrogateneedle","asker":${JSON.stringify(asker)},"kinds":["message"]}\n`);
      let surrogateLine = "";
      for (;;) {
        const line = await pc.nextLine();
        const obj = JSON.parse(line);
        if ("scopePending" in obj || "sessionListPending" in obj) continue;
        surrogateLine = line;
        break;
      }
      assert.ok(surrogateLine.includes("\\ude00"), `expected lone surrogate escape in Pion wire output: ${surrogateLine}`);
      const parsed = JSON.parse(surrogateLine);
      assert.equal(parsed.id, 77);
      assert.equal(parsed.groups.length, 1);
      assert.equal(parsed.groups[0].hits.length, 1);
      assert.ok(parsed.groups[0].hits[0].text.includes("surrogateneedle"));
    } finally {
      await pc.close();
    }
  } finally {
    fx.close();
  }
});

test("cross-engine history search parity (including packed .zst) and production new Search hanging-probe cold-start/hot-reload hits Pion wrapper on first spawn", async (t) => {
  const bins = resolveDualBinaries(t);
  if (!bins) return;
  const fx = makeFixture();
  const wrapDir = mkdtempSync(join(tmpdir(), "w6-search-wrap-"));
  const mbLog = join(wrapDir, "mb.log");
  const pionLog = join(wrapDir, "pion.log");
  const mbWrap = makeRecordingWrapper(wrapDir, "mb-wrap.sh", bins.mb, mbLog);
  const pionWrap = makeRecordingWrapper(wrapDir, "pion-wrap.sh", bins.pion, pionLog);

  try {
    // Pack h-a transcript to .zst so both MB and Pion read packed history via seekable zstd
    await packFile(join(fx.dir, "transcripts", "claude", "-w-h-a", "ha1.jsonl"));

    // 1. Direct MB vs Pion history search parity on packed + plain transcripts
    const asker = { workspace: "W1", home: true, scopes: [] };
    const mbProc = new MbProcess(bins.mb, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    const pionProc = new MbProcess(bins.pion, ["--builder", "search", "--db", fx.dbPath, "--data", fx.dir, "--sep", sep]);
    const askOne = (proc: MbProcess, query: string) =>
      new Promise<any>((resolve) => {
        const handler = (m: any) => {
          if ("scopePending" in m || "sessionListPending" in m) return;
          proc.off("message", handler);
          resolve(m);
        };
        proc.on("message", handler);
        proc.postMessage({ type: "query", id: 1, query, asker, kinds: ["history"] });
      });
    try {
      const [mbA, pionA] = await Promise.all([askOne(mbProc, "alphaonlytoken"), askOne(pionProc, "alphaonlytoken")]);
      assert.deepEqual(pionA, mbA, "packed .zst history search must be 0-diff between MB and Pion");
      assert.equal(pionA.groups.length, 1);
      assert.equal(pionA.groups[0].hits.length, 1);
    } finally {
      await Promise.all([mbProc.terminate(), pionProc.terminate()]);
    }

    // 2. Production `new Search` with hanging probe + live hot-reload config:
    //    FIRST `--builder search` spawn MUST hit the Pion recording wrapper (0 MB spawns)!
    await withEnv(
      {
        STILLFAIL_MB_READER: mbWrap,
        STILLFAIL_PION_READER: pionWrap,
        STILLFAIL_READER_SEARCH: undefined,
        STILLFAIL_READER_ENGINE: undefined,
      },
      async () => {
        let releaseProbe!: () => void;
        let probeCalls = 0;
        setPionProbeRunnerForTest((bin) => {
          probeCalls++;
          return new Promise<ReadonlySet<string> | null>((resolve) => {
            releaseProbe = () => {
              const ver = execFileSync(bin, ["--version"], { encoding: "utf8" });
              const m = ver.match(/modes:([^\n\r]+)/);
              resolve(m ? new Set(m[1]!.split(",").map((s) => s.trim()).filter(Boolean)) : null);
            };
          });
        });

        let liveConfig: ReaderSelectConfig = { readers: { search: "pion" } };
        const search = new Search({ data: fx.dir, backfill: { readers: () => liveConfig } });
        try {
          const pending = search.query("FastProfileHit", asker, { kinds: ["profile"] });
          // Probe is hanging: neither MB nor Pion should have spawned `--builder search` yet
          await Promise.resolve();
          assert.equal(probeCalls, 1, "hanging probe should be triggered once");
          assert.equal(readSpawns(mbLog).length, 0, "MB must NOT be spawned while Pion probe is pending");

          // Release probe -> first `--builder search` spawn hits Pion!
          releaseProbe();
          const found = await pending;
          assert.equal(found.groups.length, 1);
          assert.equal(found.groups[0]!.kind, "profile");
          const pionSpawns = readSpawns(pionLog).filter((l) => l.includes("--builder search"));
          const mbSpawns = readSpawns(mbLog).filter((l) => l.includes("--builder search"));
          assert.equal(pionSpawns.length, 1, `expected first --builder search spawn to hit Pion wrapper; got ${JSON.stringify(pionSpawns)}`);
          assert.equal(mbSpawns.length, 0, `expected 0 MB --builder search spawns; got ${JSON.stringify(mbSpawns)}`);
        } finally {
          setPionProbeRunnerForTest(null);
          await search.stop();
        }
      },
    );
  } finally {
    fx.close();
    rmSync(wrapDir, { recursive: true, force: true });
  }
});
