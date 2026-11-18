import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { readersOf } from "./reference.ts";
const binary = mbReaderBinary();
test("native mesh reads isolate scopes, exclude revoked identities, and bound batches", { skip: binary === null ? "MoonBit reader is not built" : false }, async () => {
  const data = mkdtempSync(join(tmpdir(), "mb-reader-mesh-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const program = readersOf(data, binary);
  const scope = "ab".repeat(32), other = "cd".repeat(32), node = "ef".repeat(32), issuer = "01".repeat(32);
  const read = async (args: unknown) => JSON.parse(await program.read("internalMeshControl", args, "en"));
  try {
    store.db.prepare("INSERT INTO mesh_announcements VALUES (?, ?, 1, ?, ?)").run(scope, node, "signed body", "signature");
    store.db.prepare("INSERT INTO mesh_announcements VALUES (?, ?, 1, ?, ?)").run(other, node, "foreign body", "foreign signature");
    assert.deepEqual(await read({ kind: "announcements", scope, nodes: [node] }), [{ body: "signed body", signature: "signature" }]);
    assert.deepEqual(await read({ kind: "announcements", scope, nodes: [issuer] }), []);
    assert.equal(await read({ kind: "announcements", scope, nodes: Array(257).fill(node) }), null);
    store.db.prepare("INSERT INTO mesh_relay_registrations VALUES (?, ?, ?, 1, 'relay', 'member', 0)").run(scope, node, issuer);
    assert.equal((await read({ kind: "registration", scope, node, issuer })).generation, 1);
    assert.equal(await read({ kind: "registration", scope: other, node, issuer }), null);
    assert.equal(await read({ kind: "registration", scope, node, issuer: node }), null);
    store.db.prepare("UPDATE mesh_relay_registrations SET revoked=1").run();
    assert.equal(await read({ kind: "registration", scope, node, issuer }), null);
  } finally { program.close(); store.close(); rmSync(data, { recursive: true, force: true }); }
});
