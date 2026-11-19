// Binary archives travel through the releases Worker's temporary R2 storage. The run artifact holds only the
// filenames, digests and read receipts. A consumer needs no credentials and installs a file only after verifying it.
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { open, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const origin = "https://app.still.fail";
const endpoint = origin + "/releases/ci-natives";
const asset = /^[a-z0-9-]+-[a-f0-9]{24}\.tar\.gz$/;
const receipt = /^[0-9]{10}-([0-9a-f]{40})\/[0-9a-f-]{36}$/;

async function transfer(url, options, consume) {
  for (let attempt = 1; ; attempt++) {
    let response;
    try {
      response = await fetch(url, { ...options, redirect: "error", signal: AbortSignal.timeout(60_000) });
      if (response.ok) return await consume(response);
      await response.body?.cancel();
      throw new Error("HTTP " + response.status);
    } catch (error) {
      if (attempt === 3 || (response && !response.ok && response.status < 500 && response.status !== 429)) throw error;
    }
  }
}

async function put(dir, manifest) {
  const files = await readdir(dir);
  if (!files.length) return;
  const oidc = new URL(process.env.ACTIONS_ID_TOKEN_REQUEST_URL);
  oidc.searchParams.set("audience", origin);
  const { value: token } = await transfer(oidc, { headers: { authorization: "Bearer " + process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN } }, (r) => r.json());
  const entries = [];
  for (const name of files) {
    if (!asset.test(name)) throw new Error("Unexpected native archive name: " + name);
    const chunks = [];
    const hash = createHash("sha256");
    for await (const bytes of createReadStream(join(dir, name), { highWaterMark: 16 * 1024 * 1024 })) {
      hash.update(bytes);
      const part = await transfer(endpoint, { method: "PUT", headers: { authorization: "Bearer " + token }, body: bytes }, (r) => r.json());
      if (receipt.exec(part.receipt)?.[1] !== process.env.GITHUB_SHA) throw new Error("Invalid native upload receipt");
      chunks.push(part.receipt);
    }
    if (!chunks.length) throw new Error("Empty native archive: " + name);
    entries.push({ name, sha256: hash.digest("hex"), chunks });
    console.log("Staged in R2: " + name);
  }
  await writeFile(manifest, JSON.stringify(entries));
}

async function restore(dir, sha) {
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error("Missing source commit for native artifacts");
  const files = await readdir(dir).catch((error) => { if (error.code === "ENOENT") return []; throw error; });
  for (const manifest of files.filter((f) => /^natives(-mac|-win-reader|-harness)?\.r2\.json$/.test(f))) {
    const entries = JSON.parse(await readFile(join(dir, manifest), "utf8"));
    for (const { name, sha256, chunks } of entries) {
      if (!asset.test(name) || !/^[a-f0-9]{64}$/.test(sha256) || !Array.isArray(chunks) || !chunks.length ||
          !chunks.every((key) => typeof key === "string" && receipt.exec(key)?.[1] === sha)) throw new Error("Invalid native manifest");
      const tmp = join(dir, randomUUID() + ".part");
      try {
        const hash = createHash("sha256");
        const file = await open(tmp, "wx");
        try {
          for (const key of chunks) {
            const bytes = Buffer.from(await transfer(endpoint + "/" + key, {}, (r) => r.arrayBuffer()));
            hash.update(bytes);
            await file.writeFile(bytes);
          }
        } finally { await file.close(); }
        if (hash.digest("hex") !== sha256) throw new Error("Native archive failed SHA-256 verification: " + name);
        await rename(tmp, join(dir, name));
        console.log("Verified from R2: " + name);
      } finally { await rm(tmp, { force: true }); }
    }
  }
}

const [op, dir, arg] = process.argv.slice(2);
if (op === "put") await put(dir, arg);
else if (op === "get") await restore(dir, arg);
else throw new Error("Usage: native-handoff.mjs put DIR MANIFEST | get DIR COMMIT");
