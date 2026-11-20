import assert from "node:assert/strict";
import { test } from "node:test";
import { CommaSurface } from "../src/comma/surface.ts";

const message = { messages: [{ text: "synthetic private message" }] };
const request = { type: "request", id: "read", method: "task.read", params: { task: "1" } };
const socket = (sent: any[]) => ({ send: (data: string) => sent.push(JSON.parse(data)) });
const surface = (read: () => Promise<any>, inScope: () => boolean) => new CommaSurface({
  connect: "one", server: "http://127.0.0.1", token: "test", name: "one",
  tasks: {} as never, store: {} as never, models: () => [],
  chats: { read, say: async () => ({}) }, inScope,
});
const tick = () => new Promise<void>((resolve) => setImmediate(resolve));

test("a workspace change after the Router read completes is checked before its reply", async () => {
  let allowed = true, checks = 0;
  const sent: any[] = [];
  const sock = socket(sent);
  const s = surface(async () => message, () => {
    if (++checks === 2) queueMicrotask(() => { allowed = false; });
    return allowed;
  });
  (s as any).socket_ = sock;
  (s as any).frame(sock, request, () => {});
  await tick();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].type, "error");
  assert.equal(JSON.stringify(sent).includes("synthetic private message"), false);
});

test("a Router read in an unchanged workspace replies normally", async () => {
  const sent: any[] = [];
  const sock = socket(sent);
  const s = surface(async () => message, () => true);
  (s as any).socket_ = sock;
  (s as any).frame(sock, request, () => {});
  await tick();
  assert.deepEqual(sent, [{ id: "read", type: "response", result: message }]);
});

for (const fails of [false, true]) {
  test(`an old socket's ${fails ? "failed" : "completed"} Router read is not sent to its replacement`, async () => {
    const oldSent: any[] = [], newSent: any[] = [];
    const old = socket(oldSent), replacement = socket(newSent);
    let finish!: () => void;
    const gate = new Promise<void>((resolve) => { finish = resolve; });
    const s = surface(async () => { await gate; if (fails) throw new Error("read failed"); return message; }, () => true);
    (s as any).socket_ = old;
    (s as any).frame(old, request, () => {});
    (s as any).socket_ = replacement;
    finish();
    await tick();
    assert.deepEqual(oldSent, []);
    assert.deepEqual(newSent, []);
  });
}

test("capabilities omits stillfail_workspace when out of scope or workspaceMeta returns null, and closed unsubscribes", () => {
  let allowed = false;
  const sent: any[] = [];
  const sock = socket(sent);
  const listeners: (() => void)[] = [];
  let unsubscribed = 0;
  const s = new CommaSurface({
    connect: "one",
    server: "http://127.0.0.1",
    token: "test",
    name: "one",
    tasks: { taking: () => [] } as never,
    store: {} as never,
    models: () => [],
    inScope: () => allowed,
    workspaceMeta: () => ({ id: "ws_1", name: "Team", station: "one", stations: [{ id: "s1", name: "one" }] }),
    onWorkspaceMetaChange: (changed) => {
      listeners.push(changed);
      return () => {
        unsubscribed++;
      };
    },
  });
  (s as any).frame(sock, { type: "connected", device_id: "d1", connector_run_id: "r1" }, () => {});
  const firstMeta = sent.find((f) => f.type === "metadata");
  assert.ok(firstMeta);
  assert.equal("stillfail_workspace" in firstMeta.capabilities, false);
  assert.equal(listeners.length, 1);

  // Out of scope notifications are ignored.
  listeners[0]!();
  assert.equal(sent.filter((f) => f.type === "metadata").length, 1);

  // When closed, listener is unsubscribed and subsequent callback does not throw or send.
  allowed = true;
  (s as any).closed();
  assert.equal(unsubscribed, 1);
  assert.doesNotThrow(() => listeners[0]!());
  assert.equal(sent.filter((f) => f.type === "metadata").length, 1);
});
