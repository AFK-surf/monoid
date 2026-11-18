// Station apps as the core asks them (src/ops.ts `app.*`) and follows them (src/views/apps.ts `told`): the station's
// routes (station/src/api/routes/apps.ts) and only the watched app's changes.
import assert from "node:assert/strict";
import { test } from "node:test";
import { request } from "../src/ops.ts";
import { told } from "../src/views/apps.ts";

const station = "w/s";

test("each app call is the station's route", () => {
  const r = (name: string, params: Record<string, unknown>) => {
    const q = request(name, { station, ...params })!;
    return [q.method, q.path, q.body];
  };
  assert.deepEqual(r("app.list", {}), ["GET", "/apps", null]);
  assert.deepEqual(r("app.get", { id: "todo" }), ["GET", "/apps/todo", null]);
  assert.deepEqual(r("app.get", { id: "todo", rev: 2 }), ["GET", "/apps/todo?rev=2", null]);
  assert.deepEqual(r("app.versions", { id: "todo" }), ["GET", "/apps/todo/versions", null]);
  assert.deepEqual(r("app.publish", { id: "todo", rev: 1 }), ["POST", "/apps/todo/current", { rev: 1 }]);
  assert.deepEqual(r("app.docs", { id: "todo", collection: "items" }), ["GET", "/apps/todo/docs/items", null]);
  assert.deepEqual(r("app.putDoc", { id: "todo", collection: "items", doc: "a b", data: { x: 1 }, base: 0 }), ["PUT", "/apps/todo/docs/items/a%20b", { data: { x: 1 }, base: 0 }]);
  assert.deepEqual(r("app.deleteDoc", { id: "todo", collection: "items", doc: "a" }), ["DELETE", "/apps/todo/docs/items/a", null]);
  assert.deepEqual(r("app.llm", { id: "todo", key: "chat:1", prompt: "hi", max_tokens: 9 }), ["POST", "/apps/todo/llm", { session: "chat:1", prompt: "hi", max_tokens: 9 }]);
  assert.throws(() => request("app.llm", { station, id: "todo", prompt: "hi" }));
});

test("a watch hears its own app's changes only", () => {
  assert.deepEqual(told("app", { id: "todo", rev: 3, current: 2 }, "todo"), { type: "app", id: "todo", rev: 3, current: 2 });
  assert.deepEqual(told("app-doc", { app: "todo", collection: "items", id: "a", rev: 4, deleted: true }, "todo"), { type: "app-doc", app: "todo", collection: "items", id: "a", rev: 4, deleted: true });
  assert.equal(told("app", { id: "other", rev: 1, current: 1 }, "todo"), null);
  assert.equal(told("app-doc", { app: "other", collection: "c", id: "a" }, "todo"), null);
  assert.equal(told("stars", { workspace: "w" }, "todo"), null);
});
