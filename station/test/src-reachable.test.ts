// Every file in src/ is the station's: reached from the composition root (src/main.ts) and something of it in the
// bundle, or only types. What only the tests use (a TypeScript reader or builder the MoonBit program replaced, a
// constant the tests move their clock by) is in test/, test/reference/ for what the program is compared with.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { build, stop, transform } from "esbuild";

const ROOT = new URL("..", import.meta.url).pathname;
// (esbuild's service is a process of its own, ended with the file's tests)
after(() => stop());

test("every file of src/ with code is reached from src/main.ts and kept in its bundle", async () => {
  const bundle = await build({
    absWorkingDir: ROOT, entryPoints: ["src/main.ts"], bundle: true, platform: "node", format: "esm", write: false,
    metafile: true, packages: "external", logLevel: "silent",
  });
  const bundled = new Set(Object.keys(bundle.metafile.inputs));
  const [output] = Object.values(bundle.metafile.outputs);
  const files = (await readdir(join(ROOT, "src"), { recursive: true }))
    .filter((file) => file.endsWith(".ts") && !file.endsWith(".d.ts")).map((file) => join("src", file)).sort();
  assert.ok(files.length > 100 && bundled.has("src/main.ts"), "src/ is read and bundled");
  const unreached: string[] = [], empty: string[] = [];
  for (const file of files) {
    const reached = bundled.has(file), bytes = output!.inputs[file]?.bytesInOutput ?? 0;
    if (reached && bytes > 0) continue;
    // Only types: nothing of it runs, so nothing of it is bundled (an `import type` of it is erased).
    const { code } = await transform(await readFile(join(ROOT, file), "utf8"), { loader: "ts", format: "esm" });
    if (code.replace(/^export \{\s*\};?$/m, "").trim() === "") continue;
    (reached ? empty : unreached).push(file);
  }
  assert.deepEqual(unreached, [], "not reached from src/main.ts: move what only the tests use to test/");
  assert.deepEqual(empty, [], "reached but nothing of it bundled (a re-export, or code only the tests call)");
});
