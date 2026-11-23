// The mesh's spans.
import assert from "node:assert/strict";
import { mock, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { log } from "../src/ops/log.ts";
import { Traces, otlpBody, parseParent, recordTracePayload, route } from "../src/mesh/traces.ts";
import { McpEndpoint, type Tool } from "../src/tools/mcp.ts";

test("a traceparent is read as W3C says", () => {
  const parent = parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")!;
  assert.ok(parent.sampled);
  assert.equal(parent.span, "00f067aa0ba902b7");
  assert.equal(parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")!.sampled, false);
  for (const bad of ["", "00-zz-00f067aa0ba902b7-01", "00-00000000000000000000000000000000-00f067aa0ba902b7-01", "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"]) {
    assert.equal(parseParent(bad), null, bad);
  }
});

test("spans only when on and sampled", async () => {
  const parent = parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
  assert.equal(new Traces(false).start(parent), null);
  const on = new Traces(true);
  assert.equal(on.start(null), null);
  assert.equal(on.start(parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")), null);
  const span = on.start(parent)!;
  const traceparent = Traces.traceparent(span);
  assert.ok(traceparent.startsWith("00-4bf92f3577b34da6a3ce929d0e0e4736-") && traceparent.endsWith("-01"));
  on.end(span, "GET /admin/api/threads", [["http.response.status_code", 200]], false);
  const [recorded] = on.spans as any[];
  assert.equal(recorded.parentSpanId, "00f067aa0ba902b7");
  assert.equal(recorded.attributes[0].value.intValue, "200");
  assert.equal(traceparent.slice(36, 52), recorded.spanId);
  on.spans.length = 0;
  await on.close();
});

test("routes hide ids", () => {
  assert.equal(route("/admin/api/threads/42/messages?limit=50"), "/admin/api/threads/:id/messages");
  assert.equal(route("/admin/api/sessions/slack:T1:C1/files?name=a.pdf"), "/admin/api/sessions/:id/files");
});

const PARENT = parseParent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");

/// The monotonic clock spans are timed by, the batching wait's TestClock and what the traces said, the test's.
async function clocked(f: (o: { hr: { ns: bigint }; clock: TestClock.TestClock; flush: () => Promise<void>; said: () => [string, string, unknown][] }) => Promise<void>) {
  const hr = { ns: 1_000n };
  const hrtime = mock.method(process.hrtime, "bigint", () => hr.ns);
  const logged: [string, string, unknown][] = [];
  const info = mock.method(log, "info", (at: string, words: string, fields?: unknown) => void (at === "telemetry" && logged.push(["info", words, fields])));
  const warn = mock.method(log, "warn", (at: string, words: string, fields?: unknown) => void (at === "telemetry" && logged.push(["warn", words, fields])));
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const flush = async () => {
    await Effect.runPromise(clock.adjust(3_000));
    for (let i = 0; i < 6; i++) await new Promise<void>((r) => setImmediate(r));
  };
  try {
    await f({ hr, clock, flush, said: () => logged.splice(0) });
  } finally {
    hrtime.mock.restore();
    info.mock.restore();
    warn.mock.restore();
    await Effect.runPromise(Scope.close(scope, Exit.void));
  }
}

/// A span of `ms` that failed or not, ended.
function spanOf(traces: Traces, hr: { ns: bigint }, ms: number, failed: boolean, name = "GET /a") {
  const span = traces.start(PARENT);
  if (span === null) return;
  hr.ns += BigInt(ms) * 1_000_000n;
  traces.end(span, name, [], failed);
}

test("where only the tail is kept: a failed or slow span, never a quick one that did not fail", async () => {
  await clocked(async ({ hr, clock }) => {
    const tail = new Traces(true, { clock, tailOnly: true });
    spanOf(tail, hr, 20, false, "quick");
    spanOf(tail, hr, 20, true, "failed");
    spanOf(tail, hr, 999, false, "almost");
    spanOf(tail, hr, 1_000, false, "slow");
    assert.deepEqual((tail.spans as any[]).map((s) => s.name), ["failed", "slow"]);
    // (its span still timed and passed on downstream)
    assert.ok(tail.start(PARENT) !== null);
    await tail.close();
    const all = new Traces(true, { clock });
    spanOf(all, hr, 20, false, "quick");
    spanOf(all, hr, 20, true, "failed");
    assert.deepEqual((all.spans as any[]).map((s) => s.name), ["quick", "failed"]);
    await all.close();
    const slower = new Traces(true, { clock, tailOnly: true, slowMs: 5_000 });
    spanOf(slower, hr, 1_000, false, "slow");
    assert.equal(slower.spans.length, 0);
    await slower.close();
    const off = new Traces(false, { clock });
    assert.equal(off.start(PARENT), null);
    await off.close();
  });
});

test("a batch sent is not said; one that fails once goes at the next flush", async () => {
  await clocked(async ({ hr, clock, flush, said }) => {
    const traces = new Traces(true, { clock });
    const sent: unknown[][] = [];
    let failing = 1;
    traces.exportTo(async (batch) => {
      if (failing-- > 0) throw new Error("still.fail cloud answered 503");
      sent.push(batch);
    });
    spanOf(traces, hr, 5, false);
    spanOf(traces, hr, 5, false);
    await flush();
    assert.equal(sent.length, 0);
    assert.equal(traces.spans.length, 2, "put back");
    assert.deepEqual(said(), []);
    await flush();
    assert.deepEqual(sent.map((b) => b.length), [2]);
    assert.equal(traces.spans.length, 0);
    assert.deepEqual(said(), [], "no traces sent line");
    await traces.close();
  });
});

test("a batch that fails again is dropped, said once in 10 min; a 4xx is not sent again", async () => {
  await clocked(async ({ hr, clock, flush, said }) => {
    const traces = new Traces(true, { clock });
    let calls = 0;
    let error = "still.fail cloud answered 503";
    traces.exportTo(async () => {
      calls++;
      throw new Error(error);
    });
    spanOf(traces, hr, 5, false);
    await flush();
    await flush();
    assert.equal(calls, 2);
    assert.equal(traces.spans.length, 0);
    assert.deepEqual(said(), [["warn", "traces dropped", { error, count: 1 }]]);
    // (within 10 min: dropped, not said)
    spanOf(traces, hr, 5, false);
    await flush();
    await flush();
    assert.equal(calls, 4);
    assert.deepEqual(said(), []);
    // a 4xx: dropped at once
    error = "still.fail cloud answered 413";
    spanOf(traces, hr, 5, false);
    spanOf(traces, hr, 5, false);
    await flush();
    assert.equal(calls, 5);
    assert.equal(traces.spans.length, 0);
    assert.deepEqual(said(), []);
    hr.ns += 600_000_000_000n;
    spanOf(traces, hr, 5, false);
    await flush();
    assert.equal(calls, 6);
    assert.deepEqual(said(), [["warn", "traces dropped", { error, count: 1 }]]);
    await traces.close();
  });
});

test("an OTLP batch says what describes the station, an empty one left out", () => {
  assert.equal(otlpBody("s1", []), otlpBody("s1", [], []));
  const body = JSON.parse(otlpBody("s1", [{ a: 1 }], [["service.version", "0.1.1"], ["os.type", "darwin"], ["host.arch", ""], ["", "x"]]));
  assert.deepEqual(body.resourceSpans[0].resource.attributes, [
    { key: "service.name", value: { stringValue: "stillfail-mesh" } },
    { key: "stillfail.station", value: { stringValue: "s1" } },
    { key: "service.version", value: { stringValue: "0.1.1" } },
    { key: "os.type", value: { stringValue: "darwin" } },
  ]);
});

test("internal root spans omit parentSpanId, set kind=1, respect tailOnly + alwaysKeep + slowMs, and no-op when off", async () => {
  await clocked(async ({ hr, clock }) => {
    const off = new Traces(false, { clock });
    assert.equal(off.startRoot(), null);
    off.recordInternal(1_000n, 2_000n, "agent.open", [["stillfail.runtime", "claude"]], false, { alwaysKeep: true });
    recordTracePayload(off, { name: "turn.run", startMs: 10, endMs: 20, attributes: { "stillfail.runtime": "claude" }, failed: false, alwaysKeep: true, slowMs: -1 });
    assert.equal(off.spans.length, 0);
    await off.close();

    const tail = new Traces(true, { clock, tailOnly: true, slowMs: 1_000 });
    const s1 = tail.startRoot()!;
    hr.ns += 10_000_000n; // 10ms
    tail.endInternal(s1, "agent.open", [["stillfail.runtime", "claude"], ["stillfail.kind", "kick"]], false, { alwaysKeep: true });
    assert.equal(tail.spans.length, 1);
    const r1 = tail.spans[0] as any;
    assert.equal("parentSpanId" in r1, false);
    assert.equal(r1.kind, 1);
    assert.equal(r1.name, "agent.open");
    assert.equal(r1.status.code, 1);

    // Dropped when < slowMs (500ms) and not failed and !alwaysKeep
    const s2 = tail.startRoot()!;
    hr.ns += 499_000_000n;
    tail.endInternal(s2, "mcp.tool", [["stillfail.tool", "chat_post"]], false, { alwaysKeep: false, slowMs: 500 });
    assert.equal(tail.spans.length, 1);

    // Kept when >= slowMs (500ms)
    const s3 = tail.startRoot()!;
    hr.ns += 500_000_000n;
    tail.endInternal(s3, "mcp.tool", [["stillfail.tool", "chat_post"]], false, { alwaysKeep: false, slowMs: 500 });
    assert.equal(tail.spans.length, 2);

    // Payload helper records failed quick span with status=2 and omits null attributes
    recordTracePayload(tail, {
      name: "station.task",
      startMs: 100,
      endMs: 120,
      attributes: { "stillfail.task.small": true, "stillfail.task.screen": false, "stillfail.task.sync": false, "stillfail.task.exit_code": 1, "ignored": null },
      failed: true,
      alwaysKeep: true,
      slowMs: -1,
    });
    assert.equal(tail.spans.length, 3);
    const r3 = tail.spans[2] as any;
    assert.equal("parentSpanId" in r3, false);
    assert.equal(r3.kind, 1);
    assert.equal(r3.status.code, 2);
    assert.deepEqual(r3.attributes.map((a: any) => a.key), ["stillfail.task.small", "stillfail.task.screen", "stillfail.task.sync", "stillfail.task.exit_code"]);
    await tail.close();
  });
});

test("mcp.tool traces record tool name and runtime without leaking arguments or paths", async () => {
  await clocked(async ({ hr, clock }) => {
    const traces = new Traces(true, { clock, tailOnly: true, slowMs: 1_000 });
    const tools: Tool[] = [
      {
        name: "chat_post",
        description: "Post",
        inputSchema: { type: "object", properties: { text: { type: "string" } } },
        run: async () => {
          hr.ns += 550_000_000n; // 550ms -> kept by slowMs=500
          return "ok";
        },
      },
      {
        name: "secret_run",
        description: "Run",
        inputSchema: { type: "object", properties: { command: { type: "string" } } },
        run: async () => {
          hr.ns += 10_000_000n; // 10ms -> kept because failed
          throw new Error("failed at /Users/secret/path with sk_live_123");
        },
      },
    ];
    const mcp = new McpEndpoint(
      (token) => (token === "tok" ? "sess-secret-key" : undefined),
      tools,
      undefined,
      undefined,
      { traces: () => traces, runtimeOf: () => "claude" },
    );
    await mcp.handle("POST", "Bearer tok", JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "chat_post", arguments: { text: "private body" } } }));
    await mcp.handle("POST", "Bearer tok", JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "secret_run", arguments: { command: "echo sk_live_123" } } }));
    assert.equal(traces.spans.length, 2);
    const raw = JSON.stringify(traces.spans);
    assert.equal(raw.includes("sess-secret-key"), false);
    assert.equal(raw.includes("private body"), false);
    assert.equal(raw.includes("sk_live_123"), false);
    assert.equal(raw.includes("/Users/secret/path"), false);
    const [okSpan, errSpan] = traces.spans as any[];
    assert.equal(okSpan.name, "mcp.tool");
    assert.equal(okSpan.status.code, 1);
    assert.deepEqual(okSpan.attributes, [
      { key: "stillfail.tool", value: { stringValue: "chat_post" } },
      { key: "stillfail.runtime", value: { stringValue: "claude" } },
    ]);
    assert.equal(errSpan.name, "mcp.tool");
    assert.equal(errSpan.status.code, 2);
    assert.deepEqual(errSpan.attributes, [
      { key: "stillfail.tool", value: { stringValue: "secret_run" } },
      { key: "stillfail.runtime", value: { stringValue: "claude" } },
      { key: "error.type", value: { stringValue: "error" } },
    ]);
    await traces.close();
  });
});
