import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { overview } from "../src/api/overview.ts";
import { stationBuiltAt } from "../src/ops/version.ts";
import { Store } from "../src/store/store.ts";

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function freshDir(): string {
  const d = mkdtempSync(join(tmpdir(), "station-built-at-"));
  dirs.push(d);
  return d;
}

test("stationBuiltAt reads Unix ms from BUILT_AT and returns undefined in dev or invalid files", () => {
  const dir = freshDir();
  assert.equal(stationBuiltAt(dir), undefined);
  writeFileSync(join(dir, "BUILT_AT"), "1795000000000\n");
  assert.equal(stationBuiltAt(dir), 1795000000000);
  writeFileSync(join(dir, "BUILT_AT"), "0\n");
  assert.equal(stationBuiltAt(dir), undefined);
  writeFileSync(join(dir, "BUILT_AT"), "not-a-number\n");
  assert.equal(stationBuiltAt(dir), undefined);
});

test("overview includes builtAt when provided and positive, and omits it when undefined", async () => {
  const store = Store.open(":memory:");
  try {
    const hub: any = { processes: () => [], config: () => ({ dataDir: "/" }) };
    const cloud: any = { state: null };
    const config = () => ({ connects: [] });
    const viewer = {
      sub: "s1",
      email: "a@b.c",
      name: "A",
      role: "owner" as const,
      workspace: "ws1",
      device: "d1",
      home: true,
    };
    const without = (await overview({ store, hub, cloud, config }, viewer, "zh")) as Record<string, unknown>;
    assert.equal("builtAt" in without, false);

    const withBuiltAt = (await overview(
      { store, hub, cloud, config, builtAt: () => 1795000000000 },
      viewer,
      "zh",
    )) as Record<string, unknown>;
    assert.equal(withBuiltAt.builtAt, 1795000000000);

    const withZero = (await overview(
      { store, hub, cloud, config, builtAt: () => 0 },
      viewer,
      "zh",
    )) as Record<string, unknown>;
    assert.equal("builtAt" in withZero, false);
  } finally {
    store.close();
  }
});
