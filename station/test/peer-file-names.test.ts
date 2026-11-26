// Local posts and files sent to another station keep their own copies when names coincide.
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import type { Hub } from "../src/sessions/hub.ts";
import { attach } from "../src/sessions/conversations.ts";
import { claim, putForPeer, sendAlong, sendable } from "../src/sessions/peer-files.ts";

async function place(t: TestContext) {
  const data = await mkdtemp(join(tmpdir(), "peer-file-names-"));
  t.after(() => rm(data, { recursive: true, force: true }));
  const source = join(data, "source");
  const destination = join(data, "destination");
  for (const [folder, contents] of [["before", "first contents"], ["after", "second contents"]] as const) {
    await mkdir(join(source, folder), { recursive: true });
    await writeFile(join(source, folder, "report.txt"), contents);
  }
  const hub = {
    now: () => 0,
    config: () => ({ dataDir: data }),
    store: { getSession: (key: string) => key === "from" ? { workspace: source } : key === "to" ? { workspace: destination } : null },
  } as unknown as Hub;
  const call = (_station: string, request: unknown) => putForPeer(hub, "near", request);
  const paths = ["before/report.txt", "after/report.txt"];
  return { hub, call, paths, destination };
}

const contents = (files: { path: string }[]) => Promise.all(files.map((file) => readFile(file.path, "utf8")));

test("a local post keeps both same-named files and repeated copies of one input", async (t) => {
  const { hub, paths } = await place(t);
  const kept = await attach(hub, "from", [...paths, paths[0]!], "to");
  assert.deepEqual(kept.map((file) => file.name), ["report.txt", "report.txt", "report.txt"]);
  assert.deepEqual(await contents(kept), ["first contents", "second contents", "first contents"]);
  assert.equal(new Set(kept.map((file) => file.path)).size, 3);
});

test("files sent together to another station retain distinct contents despite identical names", async (t) => {
  const { hub, call, paths } = await place(t);
  const sent = await sendAlong(call, "far", "from", "to", await sendable(hub, "from", paths));
  const kept = await claim(hub, "near", "from", "to", sent);
  assert.deepEqual(kept.map((file) => file.name), ["report.txt", "report.txt"]);
  assert.deepEqual(await contents(kept), ["first contents", "second contents"]);
  assert.notEqual(kept[0]!.path, kept[1]!.path);
  // A consumed transfer is still refused; staging it again must not replace the old attachment.
  await assert.rejects(claim(hub, "near", "from", "to", sent), /did not all arrive/);
  await putForPeer(hub, "near", { session: "from", to: "to", id: sent[0]!.id, offset: 0, data: Buffer.from("third contents").toString("base64"), final: true });
  const again = await claim(hub, "near", "from", "to", [sent[0]!]);
  assert.deepEqual(await contents([...kept, ...again]), ["first contents", "second contents", "third contents"]);
});

test("simultaneous local posts never replace an earlier copy", async (t) => {
  const { hub, paths } = await place(t);
  const posts = await Promise.all(paths.map((path) => attach(hub, "from", [path], "to")));
  const kept = posts.flat();
  assert.deepEqual(await contents(kept), ["first contents", "second contents"]);
  assert.notEqual(kept[0]!.path, kept[1]!.path);
});

test("remote names that sanitize alike stay in uploads and keep separate copies", async (t) => {
  const { hub, call, paths, destination } = await place(t);
  const sent = await sendAlong(call, "far", "from", "to", await sendable(hub, "from", paths));
  const names = ["../a\\b\u0000.txt", ".._a_b_.txt"];
  const kept = await claim(hub, "near", "from", "to", sent.map((file, i) => ({ ...file, name: names[i] })));
  assert.deepEqual(kept.map((file) => file.name), names);
  assert.deepEqual(await contents(kept), ["first contents", "second contents"]);
  assert.ok(kept.every((file) => dirname(file.path) === join(destination, "uploads") && !file.path.includes("\u0000")));
});
