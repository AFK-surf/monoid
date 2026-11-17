// scripts/native.ts's download of a prebuilt part against a server of its own on 127.0.0.1 (the store, GitHub's
// release download and its API, and the signed URL the API redirects an asset to): a place that answers 5xx is asked
// again and its part taken when it comes (preview's ios, main eb3f3a3a, 43992166607, 2026-11-17: the release's one 504,
// then the API's 403, said ghostty-vt was not prebuilt); the API is asked again the same way, its token never sent on to
// the signed URL; a 404 is asked once, and the part is then not prebuilt.
//   node scripts/native-download-test.mjs
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const t = mkdtempSync(join(tmpdir(), "native-download-test-"));
const PART = "iroh-wasm", TARGET = "wasm32", KEY = "0123456789abcdef01234567";
const NAME = `${PART}-${TARGET}-${KEY}.tar.gz`;
const FILES = ["stillfail_iroh_wasm.js", "stillfail_iroh_wasm.d.ts", "stillfail_iroh_wasm_bg.wasm", "stillfail_iroh_wasm_bg.wasm.d.ts"];

// the part's archive: its four files, each saying its name
const src = join(t, "src");
mkdirSync(src);
for (const f of FILES) writeFileSync(join(src, f), `${f}\n`);
const tar = spawnSync("tar", ["-czf", join(t, NAME), "-C", src, ...FILES]);
if (tar.status !== 0) throw new Error(`tar: ${tar.stderr}`);
const tgz = readFileSync(join(t, NAME));
const digest = `sha256:${createHash("sha256").update(tgz).digest("hex")}`;

// Each case is a release of its own name (STILLFAIL_NATIVE_RELEASE), and an asset id of its own in the API:
//   flaky: the download 504 twice, then the archive
//   api: the download always 504; the API's release 502 once, then the release, its asset a 302 to the signed URL
//   absent: the download 404
const CASES = { flaky: 1, api: 2, absent: 3 };
const served = []; // [case, what, n, extra]
const counts = new Map();
const count = (k) => { const n = (counts.get(k) ?? 0) + 1; counts.set(k, n); return n; };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const auth = req.headers.authorization ?? "";
  let m;
  if (u.pathname === `/store/${NAME}`) { served.push(["*", "store", count("store")]); res.writeHead(404).end(); return; }
  if ((m = u.pathname.match(/^\/o\/r\/releases\/download\/([a-z]+)\/(.+)$/)) && m[2] === NAME) {
    const c = m[1], n = count(`${c} download`);
    served.push([c, "download", n]);
    if (c === "flaky" && n >= 3) { res.writeHead(200, { "content-type": "application/gzip" }).end(tgz); return; }
    res.writeHead(c === "absent" ? 404 : 504).end("gateway");
    return;
  }
  if ((m = u.pathname.match(/^\/api\/repos\/o\/r\/releases\/tags\/([a-z]+)$/))) {
    const c = m[1], n = count(`${c} release`);
    served.push([c, "release", n, auth]);
    if (c !== "api") { res.writeHead(404).end(); return; }
    if (n === 1) { res.writeHead(502).end("bad gateway"); return; }
    res.writeHead(200, { "content-type": "application/json" })
      .end(JSON.stringify({ assets: [{ name: NAME, id: CASES[c], digest }] }));
    return;
  }
  if ((m = u.pathname.match(/^\/api\/repos\/o\/r\/releases\/assets\/(\d+)$/))) {
    served.push(["api", "asset", count("asset"), auth]);
    res.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/signed/${m[1]}?sig=x` }).end();
    return;
  }
  if ((m = u.pathname.match(/^\/signed\/(\d+)$/))) {
    served.push(["api", "signed", count("signed"), auth]);
    res.writeHead(200, { "content-type": "application/octet-stream" }).end(tgz);
    return;
  }
  served.push(["?", u.pathname, 0]);
  res.writeHead(404).end();
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;

// native.ts file-key for that case, with a cache of its own; what it said, and how it ended
const fetchKey = (release) => new Promise((done) => {
  const cache = join(t, `cache-${release}`);
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (k.startsWith("STILLFAIL_") || k === "CI") delete env[k];
  Object.assign(env, {
    STILLFAIL_NATIVE_CACHE: cache, STILLFAIL_NATIVE_STORE: `${base}/store`, STILLFAIL_NATIVE_GITHUB: base,
    STILLFAIL_NATIVE_GITHUB_API: `${base}/api`, STILLFAIL_NATIVE_REPO: "o/r", STILLFAIL_NATIVE_RELEASE: release,
    STILLFAIL_NATIVE_RETRY_MS: "1", GH_TOKEN: "t0ken",
  });
  const child = spawn(process.execPath, [join(root, "scripts/native.ts"), "file-key", PART, TARGET, KEY], { env });
  let out = "", err = "";
  child.stdout.on("data", (b) => { out += b; });
  child.stderr.on("data", (b) => { err += b; });
  child.on("close", (status) => done({ status, out: out.trim(), err, cache }));
});

let fails = 0;
const check = (c, ok, what, got) => {
  if (ok) return;
  fails++;
  console.error(`native-download-test: ${c}: ${what}`);
  console.error(got.err.replace(/^/gm, "  said: "));
  for (const s of served.filter((s) => s[0] === c || s[0] === "*")) console.error(`  served: ${s.join(" ")}`);
};
const of = (c, what) => served.filter((s) => s[0] === c && s[1] === what);
const unpacked = (got) => got.status === 0 && got.out === join(got.cache, PART, `${TARGET}-${KEY}`, FILES[0]) &&
  FILES.every((f) => existsSync(join(got.cache, PART, `${TARGET}-${KEY}`, f)) &&
    readFileSync(join(got.cache, PART, `${TARGET}-${KEY}`, f), "utf8") === `${f}\n`);

const started = Date.now();
{
  const got = await fetchKey("flaky");
  check("flaky", unpacked(got), "not taken whole after the download's two 504s", got);
  check("flaky", of("flaky", "download").length === 3, `the download asked ${of("flaky", "download").length} times, not 3`, got);
  check("flaky", of("flaky", "release").length === 0, "the API asked though the download gave it", got);
}
{
  const got = await fetchKey("api");
  check("api", unpacked(got), "not taken whole from the API after its 502", got);
  check("api", of("api", "download").length === 3, `the download asked ${of("api", "download").length} times, not 3`, got);
  check("api", of("api", "release").length === 2, `the API's release asked ${of("api", "release").length} times, not 2`, got);
  check("api", of("api", "asset").every((s) => s[3] === "Bearer t0ken"), "the API asked without the token", got);
  check("api", of("api", "signed").length === 1 && of("api", "signed").every((s) => s[3] === ""), "the token sent on to the signed URL", got);
}
{
  const got = await fetchKey("absent");
  check("absent", got.status !== 0 && /is not prebuilt/.test(got.err), `ended ${got.status}, not saying it is not prebuilt`, got);
  check("absent", of("absent", "download").length === 1, `the 404 asked ${of("absent", "download").length} times, not once`, got);
  check("absent", of("absent", "release").length === 0, "the API asked after a 404", got);
}
server.close();
rmSync(t, { recursive: true, force: true });
if (fails) process.exit(1);
console.log(`native-download-test: 3 cases (${Date.now() - started} ms)`);
