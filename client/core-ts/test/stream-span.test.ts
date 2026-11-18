// A station's event stream let go of before it opened: its request's span still ends, said so.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Fiber } from "effect";
import type { Inner } from "../src/core.ts";
import { Runner } from "../src/runtime.ts";
import { StationAddr } from "../src/station/addr.ts";
import { Requests } from "../src/station/requests.ts";
import type { StationWire } from "../src/station/wire.ts";
import { FakeHost } from "../src/testing.ts";
import { EXPORT_MS, Tracer } from "../src/trace.ts";
import { parseJson } from "../src/util.ts";

test("an_event_stream_let_go_of_before_it_opened_ends_its_span_as_interrupted", async () => {
  const host = new FakeHost();
  const runner = new Runner(host.time.clock);
  const tracer = new Tracer(host, runner, 1);
  const bodies: unknown[] = [];
  tracer.setExport((b) => Effect.sync(() => void bodies.push(parseJson(b))));
  const asked: string[] = [];
  // A wire whose request is never answered (a link's `slow` wins its race: link.ts `#follow`).
  const wire = { request: (_station: StationAddr, head: { path: string }) => (asked.push(head.path), Effect.never) } as unknown as StationWire;
  const ended: number[] = [];
  const status = { begin: () => ({ end: () => void ended.push(1) }) };
  const core = { host, runner, tracer, workspaces: { ofStation: () => ({ status }) } } as unknown as Inner;
  const requests = new Requests(core, wire);
  const fiber = runner.fork(Effect.scoped(requests.stream(StationAddr.parse("ws/st"), "/events", null)));
  await host.time.pass(1_000, 10);
  assert.deepEqual(asked, ["/admin/api/events"]);
  await runner.run(Fiber.interrupt(fiber));
  assert.equal(ended.length, 1, "what it was waited on as ended");
  await host.time.pass(EXPORT_MS + 20, 100);
  const spans = bodies.flatMap((b) => (b as { resourceSpans: { scopeSpans: { spans: Record<string, unknown>[] }[] }[] }).resourceSpans.flatMap((r) => r.scopeSpans.flatMap((s) => s.spans)));
  assert.equal(spans.length, 1, JSON.stringify(spans));
  const span = spans[0]! as { name: string; status: { code: number }; attributes: { key: string; value: Record<string, unknown> }[] };
  assert.equal(span.name, "GET /admin/api/events");
  assert.equal(span.status.code, 2, "failed");
  const at = Object.fromEntries(span.attributes.map((a) => [a.key, Object.values(a.value)[0]]));
  assert.equal(at["stillfail.interrupted"], true);
  assert.equal(at["stillfail.stream"], true);
});
