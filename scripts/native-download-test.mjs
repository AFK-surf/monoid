// scripts/native.ts's download of a prebuilt part against a server of its own on 127.0.0.1 (the store, GitHub's
// release download and its API, and the signed URL the API redirects an asset to): a place that answers 5xx is asked
// again and its part taken when it comes (preview's ios, main eb3f3a3a, 43992166607, 2026-11-17: the release's one 504,
// then the API's 403, said ghostty-vt was not prebuilt); the API is asked again the same way, its token never sent on to
// the signed URL; a 404 is asked once, and the part is then not prebuilt.
//   node scripts/native-download-test.mjs
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { selectPruneTargets } from "./native.ts";

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
//   paged: the download always 504; /releases/tags/paged truncates assets[] (omitting NAME), while /releases/42/assets paginates 2 pages
//   prune: /releases/tags/prune returns id=99 with empty assets[]; /releases/99/assets paginates 2 pages and prune deletes older assets
//   absent: the download 404
const CASES = { flaky: 1, api: 2, absent: 3, paged: 4 };
const served = []; // [case, what, n, extra]
const deletedIds = [];
const counts = new Map();
const count = (k) => { const n = (counts.get(k) ?? 0) + 1; counts.set(k, n); return n; };
const PRUNE_PAGES = {
  1: [
    { id: 101, name: "mbui-film-darwin-arm64-aaaaaaaaaaaaaaaaaaaaaaaa.tar.gz", created_at: "2026-11-20T00:00:00Z" },
    { id: 102, name: "mbui-film-darwin-arm64-bbbbbbbbbbbbbbbbbbbbbbbb.tar.gz", created_at: "2026-11-21T00:00:00Z" },
  ],
  2: [
    { id: 102, name: "mbui-film-darwin-arm64-bbbbbbbbbbbbbbbbbbbbbbbb.tar.gz", created_at: "2026-11-21T00:00:00Z" }, // duplicate across page boundary
    { id: 103, name: "mbui-film-darwin-arm64-cccccccccccccccccccccccc.tar.gz", created_at: "2026-11-22T00:00:00Z" },
    { id: 104, name: "mbui-film-darwin-arm64-dddddddddddddddddddddddd.tar.gz", created_at: "2026-11-23T00:00:00Z" },
  ],
};
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
    if (c === "paged") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: 42, assets: [] }));
      return;
    }
    if (c === "prune") {
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ id: 99, assets: [] }));
      return;
    }
    if (c !== "api") { res.writeHead(404).end(); return; }
    if (n === 1) { res.writeHead(502).end("bad gateway"); return; }
    res.writeHead(200, { "content-type": "application/json" })
      .end(JSON.stringify({ assets: [{ name: NAME, id: CASES[c], digest }] }));
    return;
  }
  if ((m = u.pathname.match(/^\/api\/repos\/o\/r\/releases\/(\d+)\/assets$/))) {
    const relId = Number(m[1]);
    const page = Number(u.searchParams.get("page") ?? "1");
    const port = server.address().port;
    if (relId === 42) {
      served.push(["paged", "assets-page", page, auth]);
      if (page === 1) {
        res.writeHead(200, {
          "content-type": "application/json",
          link: `<http://127.0.0.1:${port}/api/repos/o/r/releases/42/assets?per_page=100&page=2>; rel="next"`,
        }).end(JSON.stringify([{ name: "other-linux-x64-000000000000000000000000.tar.gz", id: 999 }]));
      } else if (count("paged page 2") === 1) {
        // First page-2 attempt returns 502; releaseThroughApi must retry rather than treat as absent.
        res.writeHead(502).end("bad gateway");
      } else {
        res.writeHead(200, { "content-type": "application/json" })
          .end(JSON.stringify([{ name: NAME, id: CASES.paged, digest }]));
      }
      return;
    }
    if (relId === 99) {
      served.push(["prune", "assets-page", page, auth]);
      const headers = { "content-type": "application/json" };
      if (page === 1) {
        headers.link = `<http://127.0.0.1:${port}/api/repos/o/r/releases/99/assets?per_page=100&page=2>; rel="next"`;
      }
      res.writeHead(200, headers).end(JSON.stringify(PRUNE_PAGES[page] ?? []));
      return;
    }
  }
  if ((m = u.pathname.match(/^\/api\/repos\/o\/r\/releases\/assets\/(\d+)$/))) {
    if (req.method === "DELETE") {
      deletedIds.push(Number(m[1]));
      served.push(["prune", "delete", Number(m[1]), auth]);
      res.writeHead(204).end();
      return;
    }
    const id = Number(m[1]);
    served.push([id === CASES.paged ? "paged" : "api", "asset", count("asset"), auth]);
    res.writeHead(302, { location: `http://127.0.0.1:${server.address().port}/signed/${m[1]}?sig=x` }).end();
    return;
  }
  if ((m = u.pathname.match(/^\/signed\/(\d+)$/))) {
    const id = Number(m[1]);
    served.push([id === CASES.paged ? "paged" : "api", "signed", count("signed"), auth]);
    res.writeHead(200, { "content-type": "application/octet-stream" }).end(tgz);
    return;
  }
  served.push(["?", u.pathname, 0]);
  res.writeHead(404).end();
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const base = `http://127.0.0.1:${server.address().port}`;

// native.ts subcommand for that case, with a cache of its own; what it said, and how it ended
const runNative = (release, args, extraEnv = {}) => new Promise((done) => {
  const cache = join(t, `cache-${release}`);
  const env = { ...process.env };
  for (const k of Object.keys(env)) if (k.startsWith("STILLFAIL_") || k === "CI" || k === "GH_TOKEN" || k === "GITHUB_TOKEN") delete env[k];
  Object.assign(env, {
    STILLFAIL_NATIVE_CACHE: cache, STILLFAIL_NATIVE_STORE: `${base}/store`, STILLFAIL_NATIVE_GITHUB: base,
    STILLFAIL_NATIVE_GITHUB_API: `${base}/api`, STILLFAIL_NATIVE_REPO: "o/r", STILLFAIL_NATIVE_RELEASE: release,
    STILLFAIL_NATIVE_RETRY_MS: "1", GH_TOKEN: "t0ken",
  }, extraEnv);
  for (const [k, v] of Object.entries(extraEnv)) if (v === undefined) delete env[k];
  const child = spawn(process.execPath, [join(root, "scripts/native.ts"), ...args], { env });
  let out = "", err = "";
  child.stdout.on("data", (b) => { out += b; });
  child.stderr.on("data", (b) => { err += b; });
  child.on("close", (status) => done({ status, out: out.trim(), err, cache }));
});
const fetchKey = (release) => runNative(release, ["file-key", PART, TARGET, KEY]);

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
{
  const got = await fetchKey("paged");
  check("paged", unpacked(got), "not taken whole via paginated /releases/<id>/assets fallback after page-2 502", got);
  check("paged", of("paged", "assets-page").length === 4, `paginated assets asked ${of("paged", "assets-page").length} pages across 2 attempts, not 4`, got);
  check("paged", of("paged", "signed").length === 1 && of("paged", "signed").every((s) => s[3] === ""), "the token sent on to the signed URL", got);
}
{
  const got = await runNative("prune", ["prune", "2"]);
  const sorted = [...deletedIds].sort((a, b) => a - b);
  check("prune", got.status === 0, `prune exited ${got.status}`, got);
  check("prune", of("prune", "assets-page").length === 2, `prune read ${of("prune", "assets-page").length} pages, not 2`, got);
  check("prune", sorted.length === 2 && sorted[0] === 101 && sorted[1] === 102, `prune deleted [${sorted.join(",")}], expected [101,102]`, got);
}
{
  // gh CLI fallback (no GH_TOKEN/GITHUB_TOKEN): rejects --slurp with --jq, emits NDJSON, and records DELETE calls.
  const binDir = join(t, "fake-gh-bin");
  const delLog = join(t, "gh-deleted.log");
  mkdirSync(binDir, { recursive: true });
  const fakeGh = join(binDir, "gh");
  writeFileSync(fakeGh, `#!/usr/bin/env node
const { appendFileSync } = require("node:fs");
const args = process.argv.slice(2);
if (args.includes("--slurp") && (args.includes("--jq") || args.includes("--template"))) {
  process.stderr.write("the \`--slurp\` option is not supported with \`--jq\` or \`--template\`\\n");
  process.exit(1);
}
if (args[0] === "api" && args.includes("repos/o/r/releases/tags/gh-fallback")) {
  process.stdout.write("99\\n");
  process.exit(0);
}
if (args[0] === "api" && args.includes("--paginate") && args.includes("repos/o/r/releases/99/assets?per_page=100")) {
  const rows = ${JSON.stringify([...PRUNE_PAGES[1], ...PRUNE_PAGES[2]])};
  for (const r of rows) process.stdout.write(JSON.stringify(r) + "\\n");
  process.exit(0);
}
if (args[0] === "api" && args.includes("DELETE")) {
  const ep = args.find((a) => a.startsWith("repos/o/r/releases/assets/")) ?? "";
  appendFileSync(${JSON.stringify(delLog)}, ep.split("/").pop() + "\\n");
  process.exit(0);
}
process.stderr.write("unexpected fake gh call: " + args.join(" ") + "\\n");
process.exit(1);
`);
  chmodSync(fakeGh, 0o755);
  const got = await runNative("gh-fallback", ["prune", "2"], {
    GH_TOKEN: undefined,
    GITHUB_TOKEN: undefined,
    PATH: `${binDir}:${process.env.PATH ?? ""}`,
  });
  const ghDeleted = existsSync(delLog)
    ? readFileSync(delLog, "utf8").trim().split("\n").filter(Boolean).map(Number).sort((a, b) => a - b)
    : [];
  check("gh-fallback", got.status === 0, `gh-fallback prune exited ${got.status}`, got);
  check("gh-fallback", ghDeleted.join(",") === "101,102", `gh-fallback deleted [${ghDeleted.join(",")}], expected [101,102]`, got);
}
{
  // selectPruneTargets unit checks: dedup, only scoping under cap, global cap sweep across unmentioned groups, and min-keep floor.
  const mk = (id, group, day) => ({ id, name: `${group}-${String(id).padStart(24, "0")}.tar.gz`, created_at: `2026-11-${String(day).padStart(2, "0")}T00:00:00Z` });
  const assets = [
    mk(1, "reader-linux-x64", 1), mk(2, "reader-linux-x64", 2), mk(3, "reader-linux-x64", 3), mk(3, "reader-linux-x64", 3),
    mk(10, "mbui-film-darwin-arm64", 1), mk(11, "mbui-film-darwin-arm64", 2), mk(12, "mbui-film-darwin-arm64", 3), mk(13, "mbui-film-darwin-arm64", 4),
  ];
  const scoped = selectPruneTargets(assets, 2, new Set(["reader-linux-x64"]), 100).map((a) => a.id).sort((a, b) => a - b);
  check("selectPruneTargets", scoped.join(",") === "1", `under-cap scoped deleted [${scoped.join(",")}], expected [1]`, { err: "" });
  const swept = selectPruneTargets(assets, 2, new Set(["reader-linux-x64"]), 6).map((a) => a.id).sort((a, b) => a - b);
  check("selectPruneTargets", swept.join(",") === "1,10,11", `over-cap sweep deleted [${swept.join(",")}], expected [1,10,11]`, { err: "" });
  // Even tighter cap (3) must preserve MIN_KEEP_UNDER_CAP=2 per group (leaving 4 assets total: 2+2).
  const floored = selectPruneTargets(assets, 3, undefined, 3).map((a) => a.id).sort((a, b) => a - b);
  check("selectPruneTargets", floored.join(",") === "1,10,11", `floor trim deleted [${floored.join(",")}], expected [1,10,11]`, { err: "" });
}
server.close();
rmSync(t, { recursive: true, force: true });
if (fails) process.exit(1);
console.log(`native-download-test: 7 cases (${Date.now() - started} ms)`);
