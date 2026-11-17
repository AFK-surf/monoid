// STILLFAIL_MESH_DSCP (src/mesh/native.ts bindStation): given to the bind as a number, anything not one refused.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { Bind, Endpoint } from "../src/mesh/endpoint.ts";
import { bindStation } from "../src/mesh/native.ts";

const options = (): Bind => ({ secretKey: Buffer.alloc(32), alpns: [], relayUrls: [] });

/// What each bind was given.
function recording() {
  const binds: Bind[] = [];
  return { binds, mesh: { bind: async (o: Bind) => (binds.push(o), {} as Endpoint) } };
}

test("the station's bind is given STILLFAIL_MESH_DSCP, and nothing of it where it is not set", async () => {
  const { binds, mesh } = recording();
  await bindStation(mesh, options(), { STILLFAIL_MESH_DSCP: "43" });
  await bindStation(mesh, options(), {});
  assert.equal(binds[0]?.dscp, 43);
  assert.ok(binds[1] !== undefined && !("dscp" in binds[1]));
});

test("a STILLFAIL_MESH_DSCP that is no number fails the bind, said, and binds nothing", async () => {
  const { binds, mesh } = recording();
  for (const dscp of ["", "x", "0x2b", "43 ", "-1", "4.5", "1000"]) {
    await assert.rejects(bindStation(mesh, options(), { STILLFAIL_MESH_DSCP: dscp }), /STILLFAIL_MESH_DSCP must be a DSCP, 1 to 63/);
  }
  assert.equal(binds.length, 0);
});
