// The station's log as it leaves the machine (ops/log-export.ts): scrubbed, on unless turned off, held until it can go.
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LogExport, record, scrubText } from "../src/ops/log-export.ts";
import type { Line } from "../src/ops/log.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { diagnosticsView, routes } from "../src/api/routes/diagnostics.ts";
import type { Request } from "../src/api/request.ts";

const HOME = "/Users/alice";
const line = (message: string, fields: Record<string, unknown> = {}, level: Line["level"] = "INFO"): Line => ({ ms: 1_000, level, at: "share", message, fields });
const attrs = (r: ReturnType<typeof record>) => Object.fromEntries(r.attributes.map((a) => [a.key, Object.values(a.value)[0]]));

test("what leaves has no home, email, key or quoted text", () => {
  assert.equal(scrubText("open /Users/alice/.stillfail/run/x.json", HOME), "open ~/.stillfail/run/x.json");
  assert.equal(scrubText("client connected by bob@example.com", HOME), "client connected by <email>");
  assert.equal(scrubText("profile alice-example-com crashed", HOME), "profile <email> crashed");
  assert.equal(scrubText("token sk-ant-api03-abcdefghijklmnopqrstuv refused", HOME), "token <secret> refused");
  assert.equal(scrubText("bearer eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJhbGljZSJ9.c2ln", HOME), "bearer <secret>");
  assert.equal(scrubText(`Unexpected token, "my secret plan" is not valid JSON`, HOME), `Unexpected token, "…" is not valid JSON`);
  // What a station is said by stays: its id, the error's own words, numbers.
  assert.equal(scrubText("workspace peer roster is not current; waiting for the control plane", HOME), "workspace peer roster is not current; waiting for the control plane");
});

test("fields people wrote are not sent; a workspace goes by its id, not its name", () => {
  const r = record(line("a notice", { text: "the chat's words", name: "acme-customer", workspace: "Acme Inc", peer: "c3ba7d15c23f", ms: 12, error: "at /home/bob/x" }, "WARN"), HOME);
  assert.equal(r.severityText, "WARN");
  assert.equal(r.severityNumber, 13);
  assert.deepEqual(attrs(r), { "log.target": "share", "log.text": "…", "log.name": "…", "log.workspace": "…", "log.peer": "c3ba7d15c23f", "log.ms": "12", "log.error": "at ~/x" });
  assert.equal(attrs(record(line("x", { workspace: "01H00000000000000000000000" }), HOME))["log.workspace"], "01H00000000000000000000000");
  // Within an object too, its keys kept.
  assert.equal(attrs(record(line("x", { by: { email: "a@b.co", n: 1 } }), HOME))["log.by"], JSON.stringify({ email: "<email>", n: 1 }));
});

test("the station's managers turn it off and on from a client; the rest of telemetry stays as it was", async () => {
  const dir = mkdtempSync(join(tmpdir(), "diagnostics-"));
  try {
    const config = new ConfigFile(dir);
    config.update((raw) => { raw.telemetry = { errors: true }; });
    assert.deepEqual(diagnosticsView(config.raw()), { logs: true });
    let changed = 0;
    const route = routes({ config, changed: () => changed++ })[0]!;
    const request = (role: string, logs: unknown): Request => ({
      method: "PUT", path: "/diagnostics/settings", query: [], headers: {}, lang: "zh",
      body: Buffer.from(JSON.stringify({ logs })),
      viewer: { sub: "a", email: "a@x", name: "A", role, workspace: "w", device: "d" },
    });
    assert.equal((await route.handle(request("member", false), [])).status, 403);
    assert.equal((await route.handle(request("owner", "no"), [])).status, 400);
    assert.equal((await route.handle(request("admin", false), [])).status, 200);
    assert.deepEqual(new ConfigFile(dir).raw().telemetry, { errors: true, logs: false });
    assert.deepEqual(diagnosticsView(config.raw()), { logs: false });
    assert.equal((await route.handle(request("owner", true), [])).status, 200);
    assert.deepEqual(new ConfigFile(dir).raw().telemetry, { errors: true });
    assert.equal(changed, 2);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("lines wait for the control plane, go in batches with the station, and stop at once when turned off", async () => {
  let on = true;
  let station: string | null = null;
  const out = new LogExport();
  out.configure({ enabled: () => on, station: () => station, version: () => "0.1.9", home: HOME, os: "darwin", arch: "arm64", runtime: "nodejs", role: "rig" });
  const sent: any[] = [];
  out.add(line("before the mesh"));
  await out.flush();
  assert.equal(sent.length, 0);
  out.sendWith(async (body) => void sent.push(JSON.parse(body)));
  await out.flush();
  assert.equal(sent.length, 0, "not enrolled yet: kept");
  station = "st1";
  out.add(line("presence: online", {}, "WARN"));
  await out.flush();
  assert.equal(sent.length, 1);
  const resource = Object.fromEntries(sent[0].resourceLogs[0].resource.attributes.map((a: any) => [a.key, a.value.stringValue]));
  assert.deepEqual(resource, {
    "service.name": "stillfail-station", "service.version": "0.1.9", "stillfail.station": "st1",
    "os.type": "darwin", "host.arch": "arm64", "process.runtime.name": "nodejs", "stillfail.role": "rig",
  });
  assert.deepEqual(sent[0].resourceLogs[0].scopeLogs[0].logRecords.map((r: any) => r.body.stringValue), ["before the mesh", "presence: online"]);
  on = false;
  out.add(line("after it is off"));
  await out.flush();
  assert.equal(sent.length, 1);
  await out.shutdown();
});

test("a batch that cannot go goes next round; one refused is dropped, and lines past what waits are counted", async () => {
  const out = new LogExport();
  out.configure({ enabled: () => true, station: () => "st1", version: () => "0.1.9", home: HOME });
  let fail: Error | null = new TypeError("fetch failed");
  const sent: any[] = [];
  out.sendWith(async (body) => {
    if (fail) throw fail;
    sent.push(JSON.parse(body));
  });
  const bodies = () => sent.flatMap((b) => b.resourceLogs[0].scopeLogs[0].logRecords).map((r: any) => r.body.stringValue);
  // No way to the cloud: kept, and sent first once there is.
  out.add(line("kept"));
  await out.flush();
  fail = null;
  out.add(line("after"));
  await out.flush();
  assert.deepEqual(bodies(), ["kept", "after"]);
  // Refused: sending it again would be too.
  sent.length = 0;
  fail = Object.assign(new Error("still.fail cloud answered 400"), { status: 400 });
  out.add(line("refused"));
  await out.flush();
  fail = Object.assign(new Error("still.fail cloud answered 503"), { status: 503 });
  out.add(line("busy"));
  await out.flush();
  fail = null;
  for (let i = 0; i < 5_010; i++) out.add(line(`n${i}`));
  await out.flush();
  const records = sent.flatMap((b) => b.resourceLogs[0].scopeLogs[0].logRecords);
  assert.ok(!bodies().includes("refused"));
  // The oldest go first: "busy" and n0..n9 are past what waits.
  assert.equal(records[0].body.stringValue, "n10");
  assert.ok(sent.every((b) => b.resourceLogs[0].scopeLogs[0].logRecords.length <= 501));
  const said = records.find((r: any) => r.body.stringValue === "log lines dropped before they could be sent");
  assert.equal(said?.attributes.find((a: any) => a.key === "log.dropped")?.value.intValue, "11");
  assert.equal(records.filter((r: any) => r.body.stringValue.startsWith("n")).length, 5_000);
  await out.shutdown();
});

test("past what waits, the oldest INFO lines go before any warning or error", async () => {
  const out = new LogExport();
  out.configure({ enabled: () => true, station: () => "st1", version: () => "0.1.9", home: HOME });
  const sent: any[] = [];
  out.sendWith(async (body) => void sent.push(JSON.parse(body)));
  const records = () => sent.flatMap((b) => b.resourceLogs[0].scopeLogs[0].logRecords);
  for (let i = 0; i < 3; i++) out.add(line(`w${i}`, {}, "WARN"));
  for (let i = 0; i < 4_999; i++) out.add(line(`i${i}`));
  out.add(line("e0", {}, "ERROR"));
  out.add(line("i-last"));
  await out.flush();
  const dropped = (rs: any[]) => rs.find((r: any) => r.body.stringValue === "log lines dropped before they could be sent")?.attributes.find((a: any) => a.key === "log.dropped")?.value.intValue;
  const said = records().map((r: any) => r.body.stringValue).filter((t: string) => !t.startsWith("log lines dropped"));
  // Four over: the four oldest INFO lines went, every warning and error stayed, in their order.
  assert.deepEqual(said.slice(0, 4), ["w0", "w1", "w2", "i4"]);
  assert.deepEqual(said.slice(-2), ["e0", "i-last"]);
  assert.equal(said.length, 5_000);
  assert.equal(dropped(records()), "4");
  // Only warnings and errors: the oldest of them go.
  sent.length = 0;
  for (let i = 0; i < 5_002; i++) out.add(line(`x${i}`, {}, i % 2 === 0 ? "WARN" : "ERROR"));
  await out.flush();
  assert.equal(records()[0].body.stringValue, "x2");
  assert.equal(dropped(records()), "2");
  await out.shutdown();
});

test("a line of a trace carries its id as the record's own traceId, beside log.trace", () => {
  const id = "0af7651916cd43dd8448eb211c80319c";
  const r = record(line("a span's line", { trace: id }), HOME) as ReturnType<typeof record> & { traceId?: string };
  assert.equal(r.traceId, id);
  assert.equal(attrs(r)["log.trace"], id);
  for (const not of ["0".repeat(32), id.toUpperCase(), id.slice(1), 12]) assert.equal((record(line("x", { trace: not }), HOME) as { traceId?: string }).traceId, undefined, String(not));
});
