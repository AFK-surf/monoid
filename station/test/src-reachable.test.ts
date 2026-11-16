// Every file in src/ is the station's: reached from the composition root (src/main.ts) and something of it in the
// bundle, or only types. What only the tests use (a TypeScript reader or builder the MoonBit program replaced, a
// constant the tests move their clock by) is in test/, test/reference/ for what the program is compared with.
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { build, stop, transform } from "esbuild";

// A path of the file system (`C:\…` on Windows, where a URL's pathname is `/C:/…`); a file of src/ is named with `/`
// on every system, as esbuild's metafile names it.
const ROOT = fileURLToPath(new URL("..", import.meta.url));
const posix = (path: string) => path.replaceAll("\\", "/");
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
    .filter((file) => file.endsWith(".ts") && !file.endsWith(".d.ts")).map((file) => posix(join("src", file))).sort();
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

// A step that built an index in TypeScript before a MoonBit builder took it over is the tests' (test/reference/backfill/):
// beside what the station runs of its file (an install, a read), esbuild leaves it out of the bundle and the test above
// cannot see it there, so none is declared in src/store/ at all.
test("src/store/ declares no backfill step", async () => {
  const files = (await readdir(join(ROOT, "src", "store"), { recursive: true }))
    .filter((file) => file.endsWith(".ts") && !file.endsWith(".d.ts")).map((file) => posix(join("src", "store", file))).sort();
  assert.ok(files.length > 50, "src/store/ is read");
  const steps: string[] = [];
  for (const file of files) {
    (await readFile(join(ROOT, file), "utf8")).split("\n").forEach((line, at) => {
      for (const [, name] of line.matchAll(/\b(?:function\*?|const|let|var|class)\s+(\w+(?:Step|Preparation))\b/g)) {
        steps.push(`${file}:${at + 1} ${name}`);
      }
    });
  }
  assert.deepEqual(steps, [], "a backfill step in src/store/: move it to test/reference/backfill/");
});
