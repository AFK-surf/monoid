// Binary archives travel through temporary R2 storage. The run artifact holds only the
// filenames, digests and read receipts. A consumer needs no credentials and installs a file only after verifying it.
// One file with only node: imports: next-mac-cache.yml runs it copied out of the commit, alone.
import { createHash, randomUUID } from "node:crypto";
import { Resolver } from "node:dns/promises";
import { createReadStream, realpathSync } from "node:fs";
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { request as httpsRequest } from "node:https";
import { dirname, join } from "node:path";
import { Readable } from "node:stream";
import { fileURLToPath } from "node:url";

const origin = "https://app.still.fail";
const endpoint = origin + "/releases/ci-natives";
const monoidOrigin = "https://app.monoid.build";
const monoidEndpoint = monoidOrigin + "/releases/ci-natives";
const monoidReceiptPrefix = "monoid/";
const asset = /^[a-z0-9-]+-[a-f0-9]{24}\.tar\.gz$/;
const receipt = /^[0-9]{10}-([0-9a-f]{40})\/[0-9a-f-]{36}$/;
const r2Host = /^[0-9a-f]{32}\.r2\.cloudflarestorage\.com$/;
const redirects = [301, 302, 303, 307, 308];

const log = (line) => process.stderr.write("native-handoff: " + line + "\n");
const reason = (error) => (error?.message ?? String(error)) + (error?.cause?.message ? " (" + error.cause.message + ")" : "");

/** The DNS server STILLFAIL_DIRECT_DNS names for release and R2 requests, or "" for the machine's routing. */
function directDns(url) {
  const dns = process.env.STILLFAIL_DIRECT_DNS;
  return dns && url.protocol === "https:" && (url.hostname === "app.still.fail" || url.hostname === "app.monoid.build" || r2Host.test(url.hostname)) ? dns : "";
}

/** Up to two IPv4 addresses of `host` from `dns`, given up after `ms` or when `signal` aborts. */
async function directAddresses(dns, host, ms, signal) {
  signal?.throwIfAborted();
  const resolver = new Resolver({ timeout: 2000, tries: 2 });
  resolver.setServers([dns]);
  // (cancelled, the lookup rejects after the race is decided: handled here, not left to end the process)
  const lookup = resolver.resolve4(host);
  lookup.catch(() => {});
  let timer, stop;
  const given = new Promise((_, fail) => {
    timer = setTimeout(() => { resolver.cancel(); fail(new Error("no answer from " + dns + " in " + ms + " ms")); }, ms);
    stop = () => { resolver.cancel(); fail(signal.reason); };
    signal?.addEventListener("abort", stop, { once: true });
  });
  try {
    return (await Promise.race([lookup, given])).slice(0, 2);
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener("abort", stop);
  }
}

/** One request to `address` with the URL's own Host and TLS name; any HTTP answer but a redirect is the Response. */
function directRequest(url, address, init, routeMs, idleMs) {
  const signal = AbortSignal.any([AbortSignal.timeout(routeMs), ...(init.signal ? [init.signal] : [])]);
  const headers = Object.fromEntries(new Headers(init.headers));
  headers.host = url.host;
  let body = init.body ?? null;
  if (typeof body === "string") body = Buffer.from(body);
  else if (body !== null && !(body instanceof Uint8Array)) throw new TypeError("Unsupported body for a direct request");
  if (body !== null && headers["content-length"] === undefined) headers["content-length"] = String(body.byteLength);
  return new Promise((ok, fail) => {
    const request = httpsRequest({ hostname: address, port: url.port || 443, servername: url.hostname,
      path: url.pathname + url.search, method: init.method ?? "GET", headers, signal }, (response) => {
      const status = response.statusCode ?? 0;
      if (redirects.includes(status)) {
        response.resume();
        // The server's own answer, as fetch's redirect: "error" would refuse it: no other route is tried.
        const location = r2Host.test(url.hostname) ? "" : " to " + response.headers.location;
        fail(Object.assign(new Error("HTTP " + status + ": redirected" + location), { status, redirect: true }));
        return;
      }
      // The route's deadline and the caller's signal hold over the body too: a stalled read is cut, not waited on.
      const stop = () => response.destroy(signal.reason);
      signal.addEventListener("abort", stop, { once: true });
      response.once("close", () => signal.removeEventListener("abort", stop));
      const resultHeaders = new Headers();
      for (const [name, value] of Object.entries(response.headers)) {
        if (Array.isArray(value)) for (const item of value) resultHeaders.append(name, item);
        else if (value !== undefined) resultHeaders.set(name, value);
      }
      const nobody = [204, 205, 304].includes(status);
      if (nobody) response.resume();
      ok(new Response(nobody ? null : Readable.toWeb(response), { status, headers: resultHeaders }));
    });
    request.setTimeout(idleMs, () => request.destroy(new Error("no bytes moved in " + idleMs + " ms")));
    request.on("error", fail);
    request.end(body ?? undefined);
  });
}

const preferredRoutes = new Map();

function usualRequest(at, init, usualMs) {
  const signal = AbortSignal.any([AbortSignal.timeout(usualMs), ...(init.signal ? [init.signal] : [])]);
  return fetch(at, { ...init, redirect: "error", signal });
}

/**
 * fetch, but a request to the releases Worker or R2 S3 under STILLFAIL_DIRECT_DNS (the CI Mac) goes
 * to each of that server's first two addresses in turn and then by the machine's own routing, as native.ts's
 * fetchNative and release-put.sh's cf_curl do: through the home network's proxy an upload stalled until its deadline
 * (release/2026-11-25's natives-mac-reader, 45428114521 and 45432440965). A route that answers anything ends it; one
 * that fails is said and the next tried. Once a route succeeds for an origin, later chunks try it first so a multi-part
 * upload does not repeat dead direct timeouts on every chunk (falling back to the other routes if it later fails).
 * Redirects are refused, as fetch's redirect: "error".
 */
export async function fetchHandoff(at, init = {}, options = {}) {
  const { dnsMs = 5_000, routeMs = 15_000, idleMs = 8_000, usualMs = 120_000 } = options;
  const url = new URL(at), dns = directDns(url);
  if (!dns) return fetch(at, init);
  const method = init.method ?? "GET";
  const upload = r2Host.test(url.hostname);
  const destination = upload ? "R2 object" : url.pathname;
  const routeError = upload ? (error) => error?.name ?? "error" : reason;
  const routeKey = dns + "\0" + url.origin;
  const preferred = preferredRoutes.get(routeKey);
  let triedDirect = "", triedUsual = false, lastError = null;
  if (preferred?.kind === "direct") {
    try {
      const response = await directRequest(url, preferred.address, init, routeMs, idleMs);
      if (response.status >= 500) preferredRoutes.delete(routeKey);
      return response;
    } catch (error) {
      if (error?.redirect || init.signal?.aborted) throw error;
      preferredRoutes.delete(routeKey);
      triedDirect = preferred.address;
      lastError = error;
      log(method + " " + destination + " at " + preferred.address + " failed (" + routeError(error) + "); trying the next route");
    }
  } else if (preferred?.kind === "usual") {
    try {
      const response = await usualRequest(at, init, usualMs);
      if (response.status >= 500) preferredRoutes.delete(routeKey);
      return response;
    } catch (error) {
      if (init.signal?.aborted) throw error;
      preferredRoutes.delete(routeKey);
      triedUsual = true;
      lastError = error;
      log(method + " " + destination + " by the usual route failed (" + routeError(error) + "); trying direct routes");
    }
  }
  let addresses = [];
  try {
    addresses = await directAddresses(dns, url.hostname, dnsMs, init.signal ?? undefined);
    if (!addresses.length) log("no IPv4 address of " + url.hostname + " from " + dns + "; by the usual route");
  } catch (error) {
    if (init.signal?.aborted) throw error;
    log("resolving " + url.hostname + " at " + dns + " failed (" + reason(error) + "); by the usual route");
  }
  for (const address of addresses) {
    if (address === triedDirect) continue;
    try {
      const response = await directRequest(url, address, init, routeMs, idleMs);
      if (response.status < 500) preferredRoutes.set(routeKey, { kind: "direct", address });
      return response;
    } catch (error) {
      if (error?.redirect || init.signal?.aborted) throw error;
      lastError = error;
      log(method + " " + destination + " at " + address + " failed (" + routeError(error) + "); trying the next route");
    }
  }
  if (triedUsual) throw lastError ?? new Error("all handoff routes failed");
  const response = await usualRequest(at, init, usualMs);
  if (response.status < 500) preferredRoutes.set(routeKey, { kind: "usual" });
  return response;
}

const getTimeoutsMs = [20_000, 30_000, 45_000, 60_000];
// Direct routes (STILLFAIL_DIRECT_DNS on Shanghai/Mini1 runners) already abort stalled sockets in idleMs (8 s);
// a healthy 4 MB chunk over evening international egress can stream steadily for 25-40 s, so routeMs starts at 60 s
// instead of aborting healthy streams at 20 s and 30 s (#45632883823, #8703).
const directGetTimeoutsMs = [60_000, 60_000, 90_000];
const writeTimeoutsMs = [60_000, 60_000, 60_000];
const knownTargets = [
  "ios-sim-arm64", "android-arm64", "darwin-arm64", "darwin-x64",
  "linux-arm64", "linux-x64", "win32-arm64", "win32-x64", "ios-arm64", "wasm32",
];

/** The `{ part, target, key }` encoded in a native archive filename, or null when unrecognized. */
export function archiveMeta(name) {
  const match = /^([a-z0-9-]+)-([a-f0-9]{24})\.tar\.gz$/.exec(name);
  if (!match) return null;
  const [, stem, key] = match;
  for (const target of knownTargets) {
    if (stem.endsWith("-" + target) && stem.length > target.length + 1) {
      return { part: stem.slice(0, -(target.length + 1)), target, key };
    }
  }
  return null;
}

/** The target triple encoded in a native archive filename, or null when unrecognized. */
export function archiveTarget(name) {
  return archiveMeta(name)?.target ?? null;
}

function resolvePartSet(spec) {
  if (!spec) return null;
  const raw = typeof spec === "string" ? spec.split(",") : Array.from(spec);
  const parts = new Set();
  for (const item of raw) {
    const trimmed = String(item).trim();
    if (trimmed) parts.add(trimmed);
  }
  return parts.size ? parts : null;
}

/** Allowed targets for `restore`, or null to download every archive in the manifests. */
export function resolveTargets(spec, host = `${process.platform}-${process.arch}`) {
  if (!spec || spec === "all") return null;
  const allowed = new Set();
  for (const raw of String(spec).split(",")) {
    const item = raw.trim();
    if (!item) continue;
    if (item === "all") return null;
    if (item === "host") {
      allowed.add(host);
      allowed.add("wasm32");
    } else {
      allowed.add(item);
    }
  }
  return allowed.size ? allowed : null;
}

async function transfer(url, options, consume, policy = {}) {
  const direct = directDns(new URL(url));
  const method = options.method ?? "GET";
  const timeouts = policy.timeoutsMs ?? (method === "GET" ? (direct ? directGetTimeoutsMs : getTimeoutsMs) : writeTimeoutsMs);
  const maxAttempts = timeouts.length;
  const backoffMs = policy.backoffMs ?? ((attempt) => attempt * 1000);
  const callerSignal = options.signal;
  for (let attempt = 1; ; attempt++) {
    callerSignal?.throwIfAborted();
    try {
      // Directly, pass the escalating attempt deadline to fetchHandoff's routeMs so retries do not stay pinned at 15 s;
      // otherwise GETs cut stalls fast and retry via AbortSignal.timeout.
      const timeoutMs = timeouts[Math.min(attempt - 1, timeouts.length - 1)];
      const signal = direct
        ? callerSignal
        : callerSignal
          ? AbortSignal.any([AbortSignal.timeout(timeoutMs), callerSignal])
          : AbortSignal.timeout(timeoutMs);
      const fetcher = policy.fetcher ?? fetchHandoff;
      const response = await fetcher(
        url,
        { ...options, redirect: "error", ...(signal ? { signal } : {}) },
        direct ? { routeMs: timeoutMs } : undefined,
      );
      if (response.ok) return await consume(response);
      const text = (await response.text().catch(() => "")).trim().slice(0, 200);
      throw Object.assign(new Error("HTTP " + response.status + (text ? ": " + text : "")), { status: response.status });
    } catch (error) {
      const status = error?.status;
      if (direct && !callerSignal?.aborted && !(status && status < 500 && status !== 429)) {
        preferredRoutes.delete(direct + "\0" + new URL(url).origin);
      }
      if (callerSignal?.aborted || attempt >= maxAttempts || (status && status < 500 && status !== 429)) throw error;
      const delay = backoffMs(attempt);
      log(method + " " + new URL(url).pathname + " attempt " + attempt + " failed (" + reason(error) + "); again in " + (delay / 1000) + " s");
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { callerSignal?.removeEventListener("abort", stop); resolve(); }, delay);
        const stop = () => { clearTimeout(timer); reject(callerSignal.reason); };
        callerSignal?.addEventListener("abort", stop, { once: true });
      });
    }
  }
}

/** A new OIDC token of this run's, for the releases Worker. */
async function oidcToken(audience) {
  const oidc = new URL(process.env.ACTIONS_ID_TOKEN_REQUEST_URL);
  oidc.searchParams.set("audience", audience);
  const { value } = await transfer(oidc, { headers: { authorization: "Bearer " + process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN } }, (r) => r.json());
  return value;
}

async function requestUpload(bytes, token) {
  try {
    return await transfer(monoidEndpoint, { method: "POST", headers: { authorization: "Bearer " + token, "content-type": "application/json" },
      body: JSON.stringify({ length: bytes.byteLength }) }, (response) => response.json());
  } catch (error) {
    if (error?.status === 404) return null;
    throw error;
  }
}

async function uploadToR2(upload, key, bytes) {
  let url;
  try { url = new URL(upload); } catch { throw new Error("Invalid R2 upload URL"); }
  if (url.protocol !== "https:" || !r2Host.test(url.hostname) || url.port || url.username || url.password || url.hash ||
      url.pathname !== "/stillfail-releases/staged/ci-natives/" + key || !url.searchParams.has("X-Amz-Signature")) {
    throw new Error("Invalid R2 upload URL");
  }
  let response;
  try {
    response = await fetchHandoff(url, { method: "PUT", headers: { "content-length": String(bytes.byteLength), "if-none-match": "*" },
      body: bytes, redirect: "error", signal: AbortSignal.timeout(40_000) });
  } catch {
    throw new Error("The direct R2 upload did not respond");
  }
  await response.body?.cancel().catch(() => {});
  // Each URL names a fresh, immutable object. A retry can find the preceding route's completed write.
  if (!response.ok && response.status !== 412) throw new Error("R2 upload returned HTTP " + response.status);
}

async function put(dir, manifest) {
  const files = await readdir(dir);
  if (!files.length) return;
  let direct = process.env.STILLFAIL_NATIVE_DIRECT_R2 === "1";
  let token = await oidcToken(direct ? monoidOrigin : origin);
  const entries = [];
  for (const name of files) {
    if (!asset.test(name)) throw new Error("Unexpected native archive name: " + name);
    const chunks = [];
    const hash = createHash("sha256");
    for await (const bytes of createReadStream(join(dir, name), { highWaterMark: 4 * 1024 * 1024 })) {
      hash.update(bytes);
      // A 401 can be the Worker's clock behind GitHub's or a token run out over a long upload: a new token, twice.
      let part;
      for (let retry = 0; ; retry++) {
        try {
          part = direct ? await requestUpload(bytes, token) : null;
          if (!part) {
            if (direct) {
              log("monoid has no direct R2 upload configured; using the still.fail upload endpoint");
              direct = false;
              token = await oidcToken(origin);
            }
            part = await transfer(endpoint, { method: "PUT", headers: { authorization: "Bearer " + token }, body: bytes }, (r) => r.json());
          }
          break;
        } catch (error) {
          if (error?.status !== 401 || retry === 2) throw error;
          await new Promise((resolve) => setTimeout(resolve, 2000 * (retry + 1)));
          token = await oidcToken(direct ? monoidOrigin : origin);
        }
      }
      if (receipt.exec(part.receipt)?.[1] !== process.env.GITHUB_SHA) throw new Error("Invalid native upload receipt");
      if (direct) await uploadToR2(part.upload, part.receipt, bytes);
      chunks.push(direct ? monoidReceiptPrefix + part.receipt : part.receipt);
    }
    if (!chunks.length) throw new Error("Empty native archive: " + name);
    entries.push({ name, sha256: hash.digest("hex"), chunks });
    console.log((chunks.every((key) => key.startsWith(monoidReceiptPrefix)) ? "Staged directly in R2: " : "Staged in R2: ") + name);
  }
  await writeFile(manifest, JSON.stringify(entries));
}

function receiptLocation(key) {
  return key.startsWith(monoidReceiptPrefix)
    ? { endpoint: monoidEndpoint, receipt: key.slice(monoidReceiptPrefix.length) }
    : { endpoint, receipt: key };
}

export async function restore(dir, sha, options = {}) {
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error("Missing source commit for native artifacts");
  const allowed = resolveTargets(options.targets, options.host);
  const excludedParts = resolvePartSet(options.excludeParts);
  const cacheDir = options.cacheDir !== undefined ? String(options.cacheDir) : (process.env.STILLFAIL_NATIVE_CACHE ?? "");
  const rawConcurrency = options.concurrency ?? 4;
  const concurrency = Number.isFinite(rawConcurrency) ? Math.max(1, Math.floor(rawConcurrency)) : 4;
  const policy = {
    ...(options.getTimeoutsMs ? { timeoutsMs: options.getTimeoutsMs } : {}),
    ...(options.backoffMs ? { backoffMs: options.backoffMs } : {}),
    ...(options.fetcher ? { fetcher: options.fetcher } : {}),
  };
  const restored = new Set();
  const files = await readdir(dir).catch((error) => { if (error.code === "ENOENT") return []; throw error; });
  for (const manifest of files.filter((f) => /^natives(?:-mac|-mac-reader|-win-reader|-harness|-(?:linux-x64|linux-arm64|win32-x64|android-arm64|wasm32))?\.r2\.json$/.test(f))) {
    const entries = JSON.parse(await readFile(join(dir, manifest), "utf8"));
    for (const { name, sha256, chunks } of entries) {
      if (!asset.test(name) || !/^[a-f0-9]{64}$/.test(sha256) || !Array.isArray(chunks) || !chunks.length ||
          !chunks.every((key) => typeof key === "string" && receipt.exec(receiptLocation(key).receipt)?.[1] === sha)) throw new Error("Invalid native manifest");
      const meta = archiveMeta(name);
      if (allowed && meta && !allowed.has(meta.target)) continue;
      if (excludedParts && meta && excludedParts.has(meta.part)) continue;
      if (restored.has(name)) continue;
      // When STILLFAIL_NATIVE_CACHE is set (shared NVMe across ci-1 runners), scripts/native.ts checks the cache before
      // STILLFAIL_NATIVE_INBOX. Skip re-downloading via R2 if the entry is already complete and unlocked: touch .access
      // first (so a concurrent trimCache sees fresh mtime before deleting), then verify no .lock is held and manifest
      // is still present.
      if (cacheDir && meta) {
        const entryDir = join(cacheDir, meta.part, `${meta.target}-${meta.key}`);
        const cachedManifest = join(entryDir, "manifest.json");
        if ((await stat(cachedManifest).catch(() => null))?.isFile()) {
          const access = join(cacheDir, ".access", meta.part, `${meta.target}-${meta.key}`);
          await mkdir(dirname(access), { recursive: true }).then(() => writeFile(access, "")).catch(() => {});
          const locked = Boolean(await stat(`${entryDir}.lock`).catch(() => null));
          if (!locked && (await stat(cachedManifest).catch(() => null))?.isFile()) {
            restored.add(name);
            console.log("Already in native cache: " + name);
            continue;
          }
        }
      }
      const results = new Array(chunks.length);
      let next = 0;
      let firstError = null;
      const abort = new AbortController();
      const worker = async () => {
        while (firstError === null) {
          const index = next++;
          if (index >= chunks.length) break;
          const { endpoint: host, receipt: key } = receiptLocation(chunks[index]);
          try {
            results[index] = Buffer.from(await transfer(host + "/" + key, { signal: abort.signal }, (r) => r.arrayBuffer(), policy));
          } catch (error) {
            if (firstError === null) {
              firstError = error;
              abort.abort(error);
            }
            break;
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(concurrency, chunks.length) }, worker));
      if (firstError !== null) throw firstError;
      const tmp = join(dir, randomUUID() + ".part");
      try {
        const hash = createHash("sha256");
        const file = await open(tmp, "wx");
        try {
          for (const bytes of results) {
            hash.update(bytes);
            await file.writeFile(bytes);
          }
        } finally { await file.close(); }
        if (hash.digest("hex") !== sha256) throw new Error("Native archive failed SHA-256 verification: " + name);
        await rename(tmp, join(dir, name));
        restored.add(name);
        console.log("Verified from R2: " + name);
      } finally { await rm(tmp, { force: true }); }
    }
  }
}

/** Whether this file is the program run (also copied alone, next-mac-cache.yml), not imported by a test. */
function isMain() {
  try {
    return Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch { return false; }
}

if (isMain()) {
  const [op, dir, arg, ...rest] = process.argv.slice(2);
  if (op === "put" && rest.length === 0) await put(dir, arg);
  else if (op === "get") {
    let targets, excludeParts;
    for (let i = 0; i < rest.length; i++) {
      if (rest[i] === "--targets" && i + 1 < rest.length) targets = rest[++i];
      else if (rest[i] === "--exclude-parts" && i + 1 < rest.length) excludeParts = rest[++i];
      else throw new Error("Usage: native-handoff.mjs put DIR MANIFEST | get DIR COMMIT [--targets SPEC] [--exclude-parts PARTS]");
    }
    await restore(dir, arg, { targets, excludeParts });
  } else throw new Error("Usage: native-handoff.mjs put DIR MANIFEST | get DIR COMMIT [--targets SPEC] [--exclude-parts PARTS]");
}
