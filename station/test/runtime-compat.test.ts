import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { runtimeList } from "./reference/runtime-view.ts";
import { Admin } from "../src/api/admin.ts";
import { runtimeCompatible, clientRuntimes } from "../src/api/runtime-compat.ts";
import { json, type Request } from "../src/api/request.ts";
import { RUNTIME_KINDS } from "../src/agents/runtime.ts";
import { SHAPES } from "../../client/core-ts/src/shapes/schema.ts";
import { conform } from "../../client/core-ts/src/conform.ts";
import { changedOf, digest } from "./reference/digest.ts";
const viewer = { sub: "u", email: "u@x", name: "", role: "owner", workspace: "w", device: "d" };
const request = (path: string, headers: Record<string,string> = {}, method = "GET", body: unknown = {}): Request => ({ path, headers, method, query: [], body: Buffer.from(JSON.stringify(body)), viewer, lang: "en" });
const modern = { "stillfail-runtimes": RUNTIME_KINDS.join(","), "stillfail-profile-services": "1" };
const data = JSON.parse(readFileSync(new URL("./fixtures/overview.json", import.meta.url), "utf8")).overview;
function overview() {
  const value = structuredClone(data);
  value.profiles.push({ ...structuredClone(value.profiles[0]), id: "hermes", runtime: "hermes", runtimes: ["hermes"] });
  return value;
}
const body = (a: ReturnType<typeof runtimeCompatible>) => JSON.parse(String(a.body));

test("an old runtime enum rejects Hermes, while the station's legacy view remains readable", () => {
  const before = SHAPES.RuntimeKind;
  assert.equal(before.kind, "enum");
  SHAPES.RuntimeKind = { ...before, kind: "enum", values: [...clientRuntimes({})], default: null };
  try {
    const value = overview();
    assert.match((conform("Overview", value) as {error:string}).error, /profiles\[1\].runtime: unknown variant `hermes`/);
    const projected = body(runtimeCompatible(request("/overview"), json(200, JSON.stringify(value))));
    assert.ok("ok" in conform("Overview", projected));
    assert.equal(projected.profiles.length, 1);
    assert.equal(value.profiles.length, 2, "shared source remains intact");
    assert.equal(body(runtimeCompatible(request("/connects/cc", {}, "PUT"), json(200, JSON.stringify(value)))).profiles.length, 1);
    const sent = json(200, JSON.stringify(value));
    assert.equal(runtimeCompatible(request("/overview",modern), sent), sent, "negotiated reader gets the original answer");
  } finally { SHAPES.RuntimeKind = before; }
});

test("unsupported required sessions are omitted or give an update error; user payloads remain untouched", () => {
  const sessions = [{key:"cc",runtime:"claude"}, {key:"hm",runtime:"hermes"}];
  assert.deepEqual(body(runtimeCompatible(request("/sessions"),json(200,JSON.stringify(sessions)))),[sessions[0]]);
  assert.equal(runtimeCompatible(request("/sessions/hm"),json(200,JSON.stringify({session:sessions[1]}))).status,426);
  const transcript = json(200,JSON.stringify({runtime:"hermes",input:{runtime:"hermes"}}));
  assert.equal(runtimeCompatible(request("/sessions/hm/timeline"),transcript),transcript);
  assert.equal(runtimeCompatible(request("/modules/custom"),transcript),transcript);
  const messages = {entries:[{authorRuntime:"hermes",authorName:"Hermes",text:'{"runtime":"hermes"}',card:{runtime:"hermes"}}]};
  const projected = body(runtimeCompatible(request("/threads/1/entries"),json(200,JSON.stringify(messages))));
  assert.equal(projected.entries[0].authorRuntime,undefined);
  assert.equal(projected.entries[0].authorName,"Hermes");
  assert.equal(projected.entries[0].text,messages.entries[0].text);
  assert.deepEqual(projected.entries[0].card,messages.entries[0].card);
});

test("SSE replay and live frames are projected per reader, preserving IDs and split Unicode", async () => {
  const raw = `id: run.1\nevent: overview\ndata: ${JSON.stringify(overview())}\n\nid: run.2\nevent: session\ndata: {"key":"hm","runtime":"hermes"}\n\nid: run.3\nevent: thread\ndata: {"id":1,"entries":[{"authorRuntime":"hermes","text":"你好"}]}\n\n`;
  const bytes = Buffer.from(raw);
  async function* chunks() { for (let i=0;i<bytes.length;i+=7) yield bytes.subarray(i,i+7); }
  const result = runtimeCompatible(request("/events"),{status:200,headers:{"content-type":"text/event-stream"},body:chunks()});
  let text=""; for await (const chunk of result.body) text+=chunk.toString();
  assert.ok(text.includes("id: run.2\nevent: session-removed\ndata: {\"key\":\"hm\"}"));
  assert.ok(text.includes("你好"));
  assert.ok(!text.includes('"authorRuntime":"hermes"'));
  const first = JSON.parse(text.split("data: ")[1].split("\n")[0]);
  assert.equal(first.profiles.length,1);
});

test("relayed events are projected piece by piece, one text for every older stream told the same, and their end reaches the stream", async () => {
  const told = `id: run.7\nevent: session\ndata: {"key":"hm","runtime":"hermes"}\n\nid: run.8\nevent: thread\ndata: {"id":1,"entries":[{"authorRuntime":"hermes","text":"hi"}]}\n\n`;
  const stream = () => {
    const sends: ((text: string) => void)[] = [];
    let returned = false;
    const body: any = {
      [Symbol.asyncIterator]: () => body,
      next: async () => ({ done: true, value: undefined }),
      return: async () => { returned = true; return { done: true, value: undefined }; },
      relay: (send: (text: string) => void) => { sends.push(send); },
    };
    return { body, tell: (text: string) => sends.forEach((s) => s(text)), returned: () => returned };
  };
  const a = stream(), b = stream();
  const got: string[][] = [[], []];
  const ra = runtimeCompatible(request("/events"), { status: 200, headers: { "content-type": "text/event-stream" }, body: a.body }).body as any;
  const rb = runtimeCompatible(request("/events"), { status: 200, headers: { "content-type": "text/event-stream" }, body: b.body }).body as any;
  ra.relay((t: string) => got[0]!.push(t), () => {});
  rb.relay((t: string) => got[1]!.push(t), () => {});
  a.tell(told);
  b.tell(told);
  assert.equal(got[0]!.length, 1);
  assert.ok(got[0]![0]!.includes("id: run.7\nevent: session-removed\ndata: {\"key\":\"hm\"}\n\n"));
  assert.ok(!got[0]![0]!.includes('"authorRuntime":"hermes"'));
  assert.ok(got[0]![0]!.endsWith("\n\n"));
  assert.equal(got[1]![0], got[0]![0], "the same event told two older streams alike");
  const session = `id: run.9\nevent: session\ndata: {"key":"cc","runtime":"claude"}\n\n`;
  a.tell(session);
  b.tell(session);
  assert.ok(got[0]![1] === got[1]![1], "one event's piece is the one kept string");
  const live = `id: run.10\nevent: live\ndata: {"runtime":"hermes"}\n\n`;
  a.tell(live);
  assert.equal(got[0]![2], live, "what frame leaves as it is goes out as it came");
  await ra.return();
  assert.ok(a.returned(), "ending the projected stream ends the one it reads");
});

test("Admin applies compatibility to initial reads, account responses, batches and digest refreshes", async () => {
  const sessions = [{key:"cc",runtime:"claude"},{key:"hm",runtime:"hermes"}];
  let held: unknown;
  const readers = { data: "/tmp/runtime-compat", names:new Map(), read:async(op:string,args:any) => {
    if(op==="sessions") return JSON.stringify(sessions);
    if(op==="session") return JSON.stringify({session:sessions.find(s=>s.key===args.key)});
    if(op==="changed") {held=args.held;return JSON.stringify(changedOf(runtimeList(args.op,sessions,args.runtimes),"key",args.held));}
    return "[]";
  }};
  const admin = new Admin(readers as any, {agents:{overview:async()=>overview()} as any});
  const initial = await admin.handle(request("/overview")); assert.equal(body(initial).profiles.length,1);
  const current = await admin.handle(request("/overview",modern)); assert.equal(body(current).profiles.length,2);
  const batch = await admin.handle(request("/batch",{},"POST",{gets:["/sessions/cc","/sessions/hm"]}));
  assert.deepEqual(body(batch).answers[0].body,{session:sessions[0]}); assert.equal(body(batch).answers[1].status,426);
  let writes = 0;
  (admin as any).routes.push({ method:"POST", pattern:/^\/profiles\/compat-test$/, handle:async()=>{ writes++; return json(200,JSON.stringify({id:"new",overview:overview()})); } });
  const key = {"idempotency-key":"same-operation"};
  const oldWrite = await admin.handle(request("/profiles/compat-test",key,"POST"));
  const newWrite = await admin.handle(request("/profiles/compat-test",{...key,...modern},"POST"));
  assert.equal(writes,1);
  assert.equal(body(oldWrite).overview.profiles.length,1);
  assert.equal(body(newWrite).overview.profiles.length,2);
  const oldHeld = Object.fromEntries(sessions.map(s=>[s.key,digest(s)]));
  const changed = await admin.handle(request("/changed/sessions",{},"POST",{held:oldHeld}));
  assert.deepEqual(held,oldHeld); assert.deepEqual(body(changed),{order:["cc"],rows:[]});
  const newChanged = await admin.handle(request("/changed/sessions",modern,"POST",{held:oldHeld}));
  assert.deepEqual(body(newChanged),{order:["cc","hm"],rows:[]});
});
