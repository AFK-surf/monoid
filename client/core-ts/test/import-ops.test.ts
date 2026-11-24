// Operation mapping tests for Settings > Import (import.sources, import.list, import.run).
import assert from "node:assert/strict";
import { test } from "node:test";
import { request } from "../src/ops.ts";

test("import operations map to station /imports endpoints", () => {
  const sources = request("import.sources", { station: "ws/st" });
  assert.deepEqual(sources, {
    target: { station: "ws/st" },
    method: "GET",
    path: "/imports",
    body: null,
    fallback: null,
    effect: { kind: "none" },
  });

  const listActive = request("import.list", { station: "ws/st", source: "t3" });
  assert.deepEqual(listActive, {
    target: { station: "ws/st" },
    method: "GET",
    path: "/imports/t3/sessions",
    body: null,
    fallback: null,
    effect: { kind: "none" },
  });

  const listArchived = request("import.list", { station: "ws/st", source: "t3", includeArchived: true });
  assert.equal(listArchived?.path, "/imports/t3/sessions?includeArchived=1");

  const runAll = request("import.run", { station: "ws/st", source: "t3", includeArchived: false });
  assert.deepEqual(runAll, {
    target: { station: "ws/st" },
    method: "POST",
    path: "/imports/t3/run",
    body: { includeArchived: false },
    fallback: null,
    effect: { kind: "none" },
  });

  const runSelected = request("import.run", { station: "ws/st", source: "t3", ids: ["a", "b"] });
  assert.deepEqual(runSelected?.body, { ids: ["a", "b"] });
});
