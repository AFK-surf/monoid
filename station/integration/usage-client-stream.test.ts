// Exercise the client and station together, including the station's real streaming compression and reader worker.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { HostError, CoreError } from "../../client/core-ts/src/error.ts";
import { HostWire } from "../../client/core-ts/src/station/wire.ts";
import { subscribe } from "../../client/core-ts/test/helpers.ts";
import { base, started } from "../../client/core-ts/test/station-fixture.ts";
import { error, json, type Request } from "../src/api/request.ts";
import { usageRoutes } from "../src/api/routes/usage.ts";
import { compressed } from "../src/mesh/compress.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { readersOf } from "../test/reference.ts";
import { Store } from "../src/store/store.ts";

test("a client receives compressed usage from the station at once, its rows and its year from the quarters", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "usage-client-stream-"));
  const store = Store.open(join(dir, "stillfail.db"));
  // (the station's readers where the program is built here, else the reads as the reader thread answered them before)
  const readers = readersOf(dir, mbReaderBinary());
  let opened = 0;
  const tools = { read: async (request: Request, op: string, args: unknown) => {
    try { return json(200, await readers.read(op, args, request.lang, { signal: request.signal })); }
    catch (cause) {
      const e = cause as Error & { status?: number };
      return error(e.status ?? 500, e.message);
    }
  } };
  const route = usageRoutes(tools as never, () => false).find((r) => r.pattern.test("/usage"))!;
  class StationUsageWire extends HostWire {
    override request(...args: Parameters<HostWire["request"]>) {
      const head = args[1];
      if (!head.path.startsWith("/admin/api/usage?")) return super.request(...args);
      opened++;
      return Effect.gen(function* () {
        const url = new URL(head.path, "https://station.test");
        const headers = Object.fromEntries(head.headers.map(([key, value]) => [key.toLowerCase(), value]));
        const request = { method: head.method, path: "/usage", query: [...url.searchParams], headers, body: Buffer.alloc(0),
          viewer: { workspace: "ws", home: false }, lang: "en" } as unknown as Request;
        const answer = yield* Effect.tryPromise({
          try: async () => compressed(await route.handle(request, []), headers, "/usage"),
          catch: (cause) => CoreError.host(String(cause)),
        });
        assert.equal(answer.headers["content-encoding"], "zstd");
        assert.ok(!Buffer.isBuffer(answer.body));
        const body = (answer.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
        yield* Effect.addFinalizer(() => Effect.promise(async () => { await body.return?.(); }));
        return { status: answer.status, headers: Object.entries(answer.headers), via: null,
          body: { take: Effect.tryPromise({ try: async () => {
            const part = await body.next();
            return part.done ? null : part.value;
          }, catch: (cause) => new HostError(String(cause)) }) } };
      });
    }
  }
  const { host, core } = await started(base(), 0, (h) => new StationUsageWire(h));
  const stop = new Promise<never>((_, reject) => t.signal.addEventListener("abort", () => reject(t.signal.reason), { once: true }));
  let complete!: (value: any) => void;
  const sawComplete = new Promise<any>((resolve) => { complete = resolve; });
  const data = core.inner.data;
  const set = data.set.bind(data);
  data.set = (topic, value, confirmed) => {
    set(topic, value, confirmed);
    if (topic.topic === "stationUsage" && value != null) complete(value);
  };
  try {
    const now = host.nowMs();
    store.insertSession({ key: "a", connect: "ember", runtime: "claude", profile: "cc", workspace: "/w", token: "a",
      ws: "ws", createdAt: 0, lastActiveAt: 0 });
    store.recordUsage("/a", { session: "a", offset: 1, model: "m" }, "claude", [[{ id: "c", at: now - 60_000, model: "m", subagent: false,
      fast: false, input: 2, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 3, calls: 1, context: null, window: null },
    { turn: null, person: "p", thread: null, profile: "cc" }]]);
    const ui = core.connect();
    subscribe(core, ui, 1, { topic: "stationUsage", station: "ws/st" });
    await host.settle();
    const ready = await Promise.race([sawComplete, stop]);
    assert.equal(opened, 1);
    assert.notEqual(ready.detailsPreparing, true);
    assert.equal(ready.rows.reduce((n: number, row: { calls: number }) => n + row.calls, 0), 1);
    assert.deepEqual(ready.history.days.map((day: { calls: number; tokens: number }) => [day.calls, day.tokens]), [[1, 5]]);
  } finally {
    data.set = set;
    await core.close();
    readers.close();
    store.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
