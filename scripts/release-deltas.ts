// The deltas of a release (scripts/delta.ts: from what an installed build has to the package of this one), made as its
// feeds are put: for every feed in a release directory (scripts/release.sh's RELEASE_DIR layout: the apps'
// **/latest.json, station.json, station-beta.json) the deltas from the builds before it, written beside it under their
// names in the bucket, and the feed amended to offer them, for scripts/release-put.sh to put (the files first, the
// feeds last). What a delta turns into what (the delta's spec: scripts/delta.ts, its appliers):
//   Mac       the .app's regular files in the zip (paths from the .app)          → the zip with every entry stored
//   Linux     what apps/mbui/linux/install.sh copies into the app's folder        → the tar in the .tar.gz
//             (LINUX_INSTALLED below: the two are one list, kept together)
//   Windows   the installer's files (flat, by name) and `Uninstall <APP_NAME>.exe` → the raw installer (`--raw`:
//             (its program alone: apps/mbui/windows/setup.c)                        <exe>.raw.zst beside it)
//   Android   the APK                                                             → the APK, checked by the app's own
//                                                                                    applier (dev.mbui.Delta, Java)
//   station   the regular files under the archive's stillfail/                    → the tar (Windows: the stored zip)
// A delta is not needed to update: the feed is whole without one, so nothing here fails a release. What goes wrong for
// one delta or one feed is a warning (::warning:: under GitHub Actions) and that delta is left out; what was made is
// said a line a feed (and in $GITHUB_STEP_SUMMARY), so that deltas no longer made are seen.
//   node scripts/release-deltas.ts <release dir> [--releases URL|DIR] [--bases N] [--jobs N] [--deadline SECONDS] [--into DIR]
// --releases: where the releases are now (default https://app.still.fail/releases; a directory for tests and dev
//   clouds): the feed published there is the build before, its own deltas' `from` the ones before that (newest first,
//   --bases of them, 10 by default), each package fetched from there (one not there is passed over). A package of this
//   release not in the directory (CI's apps put theirs before: scripts/release-put.sh --files) is fetched from there too,
//   checked against its feed.
// --jobs: deltas made at once, each a process of its own (~2 GB for a 60 MB package): the cores, the memory, 4 at most.
//   What is made does not depend on it. --deadline: what is not made by then is left out (a warning each), so that the
//   job running it is not ended by its own time limit.
// --into: where the deltas and the amended feeds are written (default: the release directory itself).
// The station's archives are put under the same name each release, so each one is kept under its own as well
// (station/archive/<channel>/<build>-<sha256>-<platform>.<ext>: what later releases make their deltas from), its
// deltas beside it (….from-<build>-<its sha256's first 16>.delta), each delta in the feed saying its archive's sha256
// (`base`, which the station passes over). scripts/release-prune.ts deletes what no feed names any more.
// The station's feed also carries `earlier`: the signed words of the releases before it (newest first, --bases of them:
// the published feed's own and its `earlier`), each as its feed said it ({version, release, signature, key}), which a
// station verifies to go back to one of them (station/src/updates/release.ts planBack), its archive downloaded under
// its own name; release-prune.ts keeps the archives these name.
// Run twice on the same directory, the second run changes nothing (a delta already made and in the feed is kept).
// --platform P (one of STATION_PLATFORMS): the station's feeds alone, and of them P's deltas alone, so that each
//   platform's are made on a runner of its own (pipeline.yml's deltas-station, 10 bases × 4 platforms did not fit one
//   runner's --deadline). The feed is not amended: what this run would have put in it (its `earlier`, P's deltas) is
//   written beside it as <feed>.deltas.<P>.json, which --merge puts in the feed.
//   node scripts/release-deltas.ts --merge DIR   each <feed>.deltas.<P>.json in DIR put in its feed there (`earlier`,
//                                                P's deltas), the feed as one run of every platform would have amended
//                                                it, and deleted; a platform with none keeps what the feed said
//   node scripts/release-deltas.ts --zst RAW OUT     RAW compressed (zstd) to OUT: the Windows raw installer's .raw.zst
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, createReadStream, createWriteStream, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { Agent as HttpAgent, request as httpRequest, type IncomingMessage } from "node:http";
import { Agent as HttpsAgent, request as httpsRequest } from "node:https";
import { availableParallelism, tmpdir, totalmem } from "node:os";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { gunzipSync, inflateRawSync, zstdCompressSync, zstdDecompressSync } from "node:zlib";
import { ensureNativeDelta, makeApk, makeTreeFromBuffer, rawOf, storedZip, type Range } from "./delta.ts";

/** What apps/mbui/linux/install.sh copies into the app's folder (`stillfail`, `lib*.so*`, `core.hbc`, `VERSION`): the
 * files an installed Linux app has, which its deltas are made from. The two change together. */
export const LINUX_INSTALLED = /^(stillfail|lib[^/]*\.so[^/]*|core\.hbc|VERSION)$/;
/** `file`, a feed's of `build`, as build `from`'s was named: the name a base is fetched by, and kept by
 * (scripts/release-prune.ts). The build's number where it stands alone in the file's own name. */
export const baseFile = (file: string, build: number, from: number) => file.replace(new RegExp(`(?<![0-9])${build}(?![0-9])(?=[^/]*$)`), String(from));
/** A delta is kept only when it is less than this much of its package. */
const KEPT_BELOW = 0.8;
const STATION_PLATFORMS = ["darwin-arm64", "linux-x64", "linux-arm64", "win32-x64"];
const GB = 1024 ** 3;

const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
const mb = (n: number) => `${(n / 1e6).toFixed(1)} MB`;
const why = (e: unknown) => (e instanceof Error ? e.message : String(e));

// --- the packages' contents ---

type ZipFile = { name: string; mode: number; dir: boolean; data: () => Buffer };
/** A zip's entries, each with its Unix mode (0 when it says none) and a way to its bytes. */
export function zipFiles(zip: Buffer): ZipFile[] {
  let e = -1;
  for (let i = zip.length - 22; i >= 0 && i >= zip.length - 22 - 0xffff; i--) if (zip.readUInt32LE(i) === 0x06054b50) { e = i; break; }
  if (e < 0) throw new Error("not a zip");
  const count = zip.readUInt16LE(e + 10), out: ZipFile[] = [];
  for (let p = zip.readUInt32LE(e + 16), i = 0; i < count; i++) {
    if (zip.readUInt32LE(p) !== 0x02014b50) throw new Error("the zip's central directory is broken");
    const method = zip.readUInt16LE(p + 10), packed = zip.readUInt32LE(p + 20), raw = zip.readUInt32LE(p + 24);
    const nameLen = zip.readUInt16LE(p + 28), local = zip.readUInt32LE(p + 42), madeBy = zip.readUInt16LE(p + 4) >> 8;
    const name = zip.toString("utf8", p + 46, p + 46 + nameLen);
    const mode = madeBy === 3 ? zip.readUInt32LE(p + 38) >>> 16 : 0;
    const at = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    out.push({
      name, mode, dir: name.endsWith("/"),
      data: () => {
        const body = zip.subarray(at, at + packed);
        if (method === 0) return Buffer.from(body);
        if (method === 8) return inflateRawSync(body, { maxOutputLength: Math.max(1, raw) });
        throw new Error(`${name}: packed by method ${method}`);
      },
    });
    p += 46 + nameLen + zip.readUInt16LE(p + 30) + zip.readUInt16LE(p + 32);
  }
  return out;
}
const isLink = (mode: number) => (mode & 0o170000) === 0o120000;

export type TarEntry = { name: string; type: string; link: string; data: Buffer };
/** A tar's entries (ustar, pax's path and linkpath, GNU's long names); `type` "0" for a regular file. */
export function tarEntries(tar: Buffer): TarEntry[] {
  const out: TarEntry[] = [];
  let long: string | null = null, longLink: string | null = null, pax: Record<string, string> = {};
  const cstr = (b: Buffer) => { const z = b.indexOf(0); return b.toString("utf8", 0, z < 0 ? b.length : z); };
  for (let p = 0; p + 512 <= tar.length;) {
    const h = tar.subarray(p, p + 512);
    if (h.every((b) => b === 0)) break;
    const field = (at: number, n: number) => cstr(h.subarray(at, at + n));
    let size: number;
    if (h[124]! & 0x80) { size = 0; for (let i = 125; i < 136; i++) size = size * 256 + h[i]!; }
    else size = parseInt(field(124, 12).trim() || "0", 8);
    const type = h[156] === 0 ? "0" : String.fromCharCode(h[156]!);
    const data = tar.subarray(p + 512, p + 512 + size);
    p += 512 + Math.ceil(size / 512) * 512;
    if (type === "L") { long = cstr(data); continue; }
    if (type === "K") { longLink = cstr(data); continue; }
    if (type === "x") {
      pax = {};
      for (let q = 0; q < data.length;) {
        const sp = data.indexOf(0x20, q), len = parseInt(data.toString("utf8", q, sp), 10);
        if (!(len > 0)) break;
        const rec = data.toString("utf8", sp + 1, q + len - 1), eq = rec.indexOf("=");
        pax[rec.slice(0, eq)] = rec.slice(eq + 1);
        q += len;
      }
      continue;
    }
    if (type === "g") continue;
    let name = field(0, 100);
    if (h.toString("latin1", 257, 263) === "ustar\0" && field(345, 155)) name = `${field(345, 155)}/${name}`;
    out.push({ name: pax.path ?? long ?? name, type, link: pax.linkpath ?? longLink ?? field(157, 100), data });
    long = longLink = null;
    pax = {};
  }
  return out;
}

/** A raw installer's parts (apps/mbui/windows/setup.c: its program, then MAGIC_RAW, the files stored, its offset and
 * MAGIC_RAW again). */
export function rawInstaller(raw: Buffer): { stub: Buffer; files: { name: string; data: Buffer }[] } {
  const MAGIC = "MBSETUP0";
  const n = raw.length;
  if (n < 16 || raw.toString("latin1", n - 8) !== MAGIC) throw new Error("not a raw installer (MBSETUP0)");
  const at = Number(raw.readBigUInt64LE(n - 16));
  if (at > n - 28 || raw.toString("latin1", at, at + 8) !== MAGIC) throw new Error("a raw installer whose payload is not where it says");
  const count = raw.readUInt32LE(at + 8), files: { name: string; data: Buffer }[] = [];
  let p = at + 12;
  for (let i = 0; i < count; i++) {
    const nl = raw.readUInt16LE(p);
    const name = raw.toString("utf16le", p + 2, p + 2 + nl * 2);
    p += 2 + nl * 2;
    const size = Number(raw.readBigUInt64LE(p)), packed = Number(raw.readBigUInt64LE(p + 8));
    p += 16;
    if (size !== packed || p + size > n - 16) throw new Error(`a raw installer's file is not stored whole: ${name}`);
    files.push({ name, data: raw.subarray(p, p + size) });
    p += size;
  }
  return { stub: raw.subarray(0, at), files };
}

/** Whether a path is one a delta may name (no "..", not absolute) and not macOS's metadata (._ files). */
const fine = (path: string) => path !== "" && !path.startsWith("/") && !path.split("/").some((s) => s === "" || s === "." || s === "..") && !path.split("/").some((s) => s.startsWith("._"));

type Kind = "mac" | "linux" | "win" | "android" | "station";

/** Extract the installed files of `kind` from `path`, calling `put(rel, data)` for each valid entry in archive order. */
function extractInstalled(kind: Exclude<Kind, "android">, path: string, put: (rel: string, data: Buffer) => void): void {
  const fromZip = (zip: Buffer, under: (name: string) => string | null) => {
    for (const f of zipFiles(zip)) {
      const rel = under(f.name);
      if (rel !== null && !f.dir && !isLink(f.mode) && fine(rel)) put(rel, f.data());
    }
  };
  switch (kind) {
    case "mac": {
      // (the regular files of the one .app at the top: its folder's name is the app's)
      const all = zipFiles(readFileSync(path));
      const top = all.map((f) => /^([^/]+\.app)\//.exec(f.name)?.[1]).find((n) => n);
      if (!top) throw new Error("no .app in the zip");
      for (const f of all) {
        const rel = f.name.startsWith(`${top}/`) ? f.name.slice(top.length + 1) : null;
        if (rel !== null && !f.dir && !isLink(f.mode) && fine(rel)) put(rel, f.data());
      }
      return;
    }
    case "linux": {
      // (install.sh's cp follows a link: what one names is copied as a file)
      const entries = tarEntries(gunzipSync(readFileSync(path)));
      const top = entries.find((e) => e.name.includes("/"))?.name.split("/")[0];
      const byName = new Map(entries.map((e) => [e.name.replace(/\/$/, ""), e]));
      for (const e of entries) {
        const parts = e.name.split("/");
        if (parts.length !== 2 || parts[0] !== top || !LINUX_INSTALLED.test(parts[1]!)) continue;
        let f: TarEntry | undefined = e;
        for (let hops = 0; f && (f.type === "2" || f.type === "1") && hops < 8; hops++) {
          f = f.type === "2" ? byName.get(`${top}/${f.link}`) : byName.get(f.link.replace(/^\.\//, ""));
        }
        if (f?.type === "0" && fine(parts[1]!)) put(parts[1]!, f.data);
      }
      return;
    }
    case "win": {
      const raw = zstdDecompressSync(readFileSync(path));
      const { stub, files } = rawInstaller(raw);
      for (const f of files) if (fine(f.name)) put(f.name, f.data);
      const env = files.find((f) => f.name === "setup.env")?.data.toString("utf8") ?? "";
      const name = /^APP_NAME=(.*)$/m.exec(env)?.[1]?.replace(/[\r ]+$/, "");
      if (!name) throw new Error("the installer's setup.env says no APP_NAME");
      const uninst = `Uninstall ${name}.exe`;
      if (fine(uninst)) put(uninst, stub);
      return;
    }
    case "station": {
      const under = (name: string) => (name.startsWith("stillfail/") ? name.slice("stillfail/".length) : null);
      if (path.endsWith(".zip")) return fromZip(readFileSync(path), under);
      const entries = tarEntries(gunzipSync(readFileSync(path)));
      const byName = new Map(entries.map((e) => [e.name.replace(/^\.\//, ""), e]));
      for (const e of entries) {
        const rel = under(e.name.replace(/^\.\//, ""));
        // (a hard link is a file of its own once unpacked)
        const f = e.type === "1" ? byName.get(e.link.replace(/^\.\//, "")) : e;
        if (rel !== null && f?.type === "0" && fine(rel)) put(rel, f.data);
      }
      return;
    }
  }
}

/** The files an installed build of `kind` has, out of its package (`path`), written into `dir`. */
export function layInstalled(kind: Kind, path: string, dir: string): void {
  if (kind === "android") throw new Error("an APK is its own installed form");
  extractInstalled(kind, path, (rel, data) => {
    mkdirSync(dirname(join(dir, rel)), { recursive: true });
    writeFileSync(join(dir, rel), data);
  });
}

/** The files an installed build of `kind` has, out of its package (`path`), assembled in memory (bytewise sorted, as
 * `layInstalled` + `treeFiles` would produce without writing to disk). */
export function layInstalledEntries(kind: Exclude<Kind, "android">, path: string): { files: string[]; ranges: Range[]; old: Buffer } {
  const map = new Map<string, Buffer>();
  extractInstalled(kind, path, (rel, data) => { map.set(rel, data); });
  const files = [...map.keys()].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
  const data = files.map((f) => map.get(f)!);
  const ranges: Range[] = [];
  for (let at = 0, i = 0; i < data.length; at += data[i]!.length, i++) ranges.push({ at, len: data[i]!.length });
  return { files, ranges, old: Buffer.concat(data) };
}

/** What a delta to the package of `kind` makes: its raw form. */
function rawPackage(kind: Kind, path: string): Buffer {
  switch (kind) {
    case "mac": return storedZip(readFileSync(path));
    case "linux": return gunzipSync(readFileSync(path));
    case "win": return zstdDecompressSync(readFileSync(path));
    case "station": return rawOf(path);
    case "android": return readFileSync(path);
  }
}

// --- one delta, in a process of its own (--pair) or a persistent worker (--worker) ---

type Pair = { kind: Kind; base: string; made: string; out: string; classes?: string | undefined };

const DELTA_BATCH_JAVA = `package dev.mbui;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

public final class DeltaBatch {
    public static void main(String[] args) throws Exception {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isEmpty()) continue;
            String[] parts = line.split("\\t", -1);
            if (parts.length != 3) {
                System.out.println("ERR bad request");
                System.out.flush();
                continue;
            }
            try {
                File out = new File(parts[2]).getAbsoluteFile();
                Delta.apply(new File(parts[0]), new File(parts[1]), out, out.getParentFile());
                System.out.println("OK");
            } catch (Throwable e) {
                String msg = e.getMessage() == null ? e.toString() : e.getMessage();
                System.out.println("ERR " + msg.replace('\\r', ' ').replace('\\n', ' '));
            }
            System.out.flush();
        }
    }
}
`;

/** A persistent JVM running dev.mbui.DeltaBatch so a worker amortizes JVM startup and JZlib JIT across Android bases. */
class JavaBatch {
  private proc: ReturnType<typeof spawn> | null = null;
  private classes: string | null = null;
  private err = "";
  private buf = "";
  private pending: ((res: string | null) => void) | null = null;

  private ensure(classes: string) {
    if (this.proc && this.classes === classes) return this.proc;
    this.kill();
    const proc = spawn("java", ["-Xmx256m", "-cp", classes, "dev.mbui.DeltaBatch"], { stdio: ["pipe", "pipe", "pipe"] });
    this.proc = proc;
    this.classes = classes;
    this.err = "";
    this.buf = "";
    proc.stderr!.on("data", (d: Buffer) => { this.err = (this.err + d.toString("utf8")).slice(-2000); });
    proc.stdout!.on("data", (d: Buffer) => {
      this.buf += d.toString("utf8");
      const nl = this.buf.indexOf("\n");
      if (nl >= 0) {
        const line = this.buf.slice(0, nl).replace(/\r$/, "");
        this.buf = this.buf.slice(nl + 1);
        const cb = this.pending;
        this.pending = null;
        if (cb) cb(line === "OK" ? null : line.startsWith("ERR ") ? line.slice(4) : line || "unexpected Java batch response");
      }
    });
    proc.on("close", (code, sig) => {
      if (this.proc === proc) { this.proc = null; this.classes = null; }
      const cb = this.pending;
      this.pending = null;
      if (cb) cb(this.err.trim().split("\n").at(-1) || `Java batch exited (${code ?? sig})`);
    });
    proc.on("error", (e) => {
      if (this.proc === proc) { this.proc = null; this.classes = null; }
      const cb = this.pending;
      this.pending = null;
      if (cb) cb(why(e));
    });
    return proc;
  }

  apply(classes: string, base: string, delta: string, out: string): Promise<string | null> {
    return new Promise((resolve) => {
      const proc = this.ensure(classes);
      this.pending = resolve;
      proc.stdin!.write(`${base}\t${delta}\t${out}\n`);
    });
  }

  private kill() {
    if (!this.proc) return;
    try { this.proc.kill("SIGKILL"); } catch { /* already gone */ }
    this.proc = null;
    this.classes = null;
  }

  async close(): Promise<void> {
    const proc = this.proc;
    if (!proc) return;
    this.proc = null;
    this.classes = null;
    await new Promise<void>((resolve) => {
      proc.once("close", () => resolve());
      try { proc.stdin!.end(); } catch { resolve(); }
    });
  }
}

async function makePair(p: Pair, javaBatch?: JavaBatch): Promise<void> {
  if (p.kind === "android") {
    makeApk(p.base, p.made, p.out, "skip");
    // the APK the app's own applier makes of it (its deflater, JZlib), byte for byte the release's, or no delta
    const check = `${p.out}.apk`;
    const noControl = !/[\t\r\n]/.test(`${p.base}${p.out}${check}`);
    let javaErr: string | null;
    if (javaBatch && noControl) {
      javaErr = await javaBatch.apply(p.classes!, p.base, p.out, check);
    } else {
      const r = spawnSync("java", ["-Xmx256m", "-cp", p.classes!, "dev.mbui.Delta", "apply", p.base, p.out, check], { encoding: "utf8" });
      javaErr = r.status === 0 ? null : r.stderr.trim().split("\n").at(-1) || `java exited (${r.status ?? r.signal})`;
    }
    const same = javaErr === null && existsSync(check) && readFileSync(check).equals(readFileSync(p.made));
    rmSync(check, { force: true });
    if (!same) {
      rmSync(p.out, { force: true });
      throw new Error(`the Java applier does not make the APK of it (${javaErr ?? "other bytes"})`);
    }
    return;
  }
  const { files, ranges, old } = layInstalledEntries(p.kind, p.base);
  makeTreeFromBuffer(files, ranges, old, p.made, p.out);
}

// --- where the releases are ---

type Source = {
  /** The file `name` there, into `to`: false when it is not there. */
  fetch(name: string, to: string, signal: AbortSignal): Promise<boolean>;
  text(name: string, signal: AbortSignal): Promise<string | null>;
  has(name: string, signal: AbortSignal): Promise<boolean>;
  close?(): void;
};

function source(where: string): Source {
  if (!/^https?:\/\//.test(where)) {
    return {
      async fetch(name, to) {
        if (!existsSync(join(where, name))) return false;
        copyFileSync(join(where, name), to);
        return true;
      },
      async text(name) { return existsSync(join(where, name)) ? readFileSync(join(where, name), "utf8") : null; },
      async has(name) { return existsSync(join(where, name)); },
    };
  }
  // node:http(s) and not fetch: Node 24's undici asserts (`!this.paused`, Parser.finish) on a TLS socket's end while a
  // body is paused, thrown in the socket's event and not on the request's promise, which ended the whole run. Keep-alive
  // agents reuse TCP/TLS connections across bases, destroyed in Run.done(); at most 5 redirects.
  const httpAgent = new HttpAgent({ keepAlive: true, maxSockets: 16 });
  const httpsAgent = new HttpsAgent({ keepAlive: true, maxSockets: 16 });
  const url = (name: string) => `${where.replace(/\/+$/, "")}/${name}`;
  const request = (u: string, method: "GET" | "HEAD", signal: AbortSignal, headers: Record<string, string> = {}, hops = 0): Promise<IncomingMessage> =>
    new Promise((resolve, reject) => {
      const isHttps = u.startsWith("https:");
      const get = isHttps ? httpsRequest : httpRequest;
      const agent = isHttps ? httpsAgent : httpAgent;
      const req = get(u, { method, signal, agent, headers: { "user-agent": "stillfail-release-deltas", ...headers } }, (res) => {
        const status = res.statusCode ?? 0, to = res.headers.location;
        if ([301, 302, 303, 307, 308].includes(status) && to) {
          res.resume();
          if (hops >= 5) return reject(new Error(`${u}: more than 5 redirects`));
          return resolve(request(new URL(to, u).href, status === 303 && method !== "HEAD" ? "GET" : method, signal, headers, hops + 1));
        }
        resolve(res);
      });
      req.on("error", reject);
      req.end();
    });
  /** `name`'s response when it is there (2xx), null when it is not (404); any other status is an error. */
  const get = async (name: string, method: "GET" | "HEAD", signal: AbortSignal, headers?: Record<string, string>) => {
    const res = await request(url(name), method, signal, headers);
    const status = res.statusCode ?? 0;
    if (status >= 200 && status < 300) return res;
    res.resume();
    if (status === 404) return null;
    throw Object.assign(new Error(`${url(name)}: ${status}`), { status });
  };
  return {
    async fetch(name, to, signal) {
      const res = await get(name, "GET", signal);
      if (!res) return false;
      await pipeline(res, createWriteStream(to), { signal });
      return true;
    },
    async text(name, signal) {
      const res = await get(name, "GET", signal);
      if (!res) return null;
      const chunks: Buffer[] = [];
      for await (const c of res) chunks.push(c as Buffer);
      return Buffer.concat(chunks).toString("utf8");
    },
    async has(name, signal) {
      let res: IncomingMessage | null;
      try { res = await get(name, "HEAD", signal); } catch (e) {
        if ((e as { status?: number }).status !== 405 && (e as { status?: number }).status !== 501) throw e;
        res = await get(name, "GET", signal, { range: "bytes=0-0" });
      }
      res?.resume();
      return res !== null;
    },
    close() {
      httpAgent.destroy();
      httpsAgent.destroy();
    },
  };
}

function hashFile(path: string): Promise<{ sha256: string; size: number }> {
  return new Promise((resolve, reject) => {
    const h = createHash("sha256");
    let size = 0;
    createReadStream(path).on("data", (b) => { h.update(b as Buffer); size += b.length; }).on("end", () => resolve({ sha256: h.digest("hex"), size })).on("error", reject);
  });
}

/** A feed's signed words (base64 JSON), not verified: what it says of its files. */
const wordsOf = (feed: any): any => {
  try { return typeof feed?.release === "string" ? JSON.parse(Buffer.from(feed.release, "base64").toString("utf8")) : null; } catch { return null; }
};

/** A release's signed words as its feed said them: what a station verifies (station/src/updates/signed.ts). */
type Signed = { version: string; release: string; signature: string; key: string };
const signedOf = (feed: any): Signed | null =>
  ["version", "release", "signature", "key"].every((k) => typeof feed?.[k] === "string") ? { version: feed.version, release: feed.release, signature: feed.signature, key: feed.key } : null;

/** `from` moved to `to`, its directory made. `this.work` is in the system's temp (C: on Windows' runners) and `--into`
 * may be on another disk ($RUNNER_TEMP, D:), where a rename fails with EXDEV (preview 44334978946's windows, every
 * delta left out): there it is copied beside `to` and renamed into place, so `to` is never seen half written. */
export function moveInto(from: string, to: string, rename: (a: string, b: string) => void = renameSync): void {
  mkdirSync(dirname(to), { recursive: true });
  try {
    rename(from, to);
  } catch (e) {
    if ((e as NodeJS.ErrnoException)?.code !== "EXDEV") throw e;
    const staged = `${to}.${process.pid}.new`;
    copyFileSync(from, staged);
    renameSync(staged, to);
    rmSync(from, { force: true });
  }
}

/** The `earlier` of the station's feed of `build`: `prev` (the feed published before it) and its own `earlier`, those
 * older than `build`, each build once, newest first, `most` of them. */
export function earlierOf(build: number, prev: any, most: number): Signed[] {
  const all = [signedOf(prev), ...(Array.isArray(prev?.earlier) ? prev.earlier.map(signedOf) : [])];
  const seen = new Set<number>();
  const out: { build: number; signed: Signed }[] = [];
  for (const signed of all) {
    const b = Number(wordsOf(signed)?.build);
    if (signed === null || !Number.isSafeInteger(b) || b >= build || seen.has(b)) continue;
    seen.add(b);
    out.push({ build: b, signed });
  }
  return out.sort((a, b) => b.build - a.build).slice(0, most).map((e) => e.signed);
}

// --- the run ---

type Base = { build: number; names: string[]; sha256?: string; size?: number; rawSha256?: string; path?: string; missing?: boolean };
type Made = { from: number; file: string; sha256: string; size: number; base?: string };
type Target = {
  feed: string;
  label: string;
  kind: Kind;
  build: number;
  /** The package (its raw form made of it at `made`), and its size as downloaded. */
  package: string;
  packageSize: number;
  made: string;
  bases: Base[];
  /** Where a delta from `base` goes, under the bucket's names. */
  name: (b: Base) => string;
  entry: (b: Base, file: string, sha256: string, size: number) => Made;
  /** What the feed offers already (a run before this one), by the delta's file. */
  had: Map<string, Made>;
  outcome: Map<Base, string>;
  made_: Made[];
  platform?: string;
};

export type Options = { releases: string; bases: number; jobs: number; deadline: number | null; into: string; platform?: string | null };

class Run {
  readonly warnings: string[] = [];
  readonly lines: string[] = [];
  /** The station's feeds' `earlier`, by feed (stationTargets). */
  readonly earlier = new Map<string, Signed[]>();
  private readonly work = mkdtempSync(join(tmpdir(), "release-deltas-"));
  private readonly abort = new AbortController();
  private readonly src: Source;
  private seq = 0;
  private classes: string | null | undefined;
  private readonly children = new Set<ReturnType<typeof spawn>>();
  private readonly timer: ReturnType<typeof setTimeout> | null;

  private readonly dir: string;
  private readonly o: Options;

  constructor(dir: string, o: Options) {
    this.dir = dir;
    this.o = o;
    this.src = source(o.releases);
    // (from the start: what is fetched counts as well)
    this.timer = o.deadline === null ? null : setTimeout(() => {
      this.warn(`--deadline ${o.deadline} s reached: what is not made yet is left out`);
      this.abort.abort();
      for (const c of this.children) c.kill("SIGKILL");
    }, o.deadline * 1000);
  }

  warn(text: string) {
    this.warnings.push(text);
    console.error(process.env.GITHUB_ACTIONS ? `::warning::release-deltas: ${text}` : `release-deltas: warning: ${text}`);
  }

  private tmp(name: string) { return join(this.work, `${++this.seq}-${name.replace(/[^\w.-]/g, "_")}`); }

  /** `name` of this release: in the directory, else fetched (and checked against `want`). */
  private async ours(name: string, want?: { sha256?: string; size?: number }): Promise<string> {
    let path = join(this.dir, name);
    if (!existsSync(path)) {
      path = this.tmp(name);
      if (!(await this.src.fetch(name, path, this.abort.signal))) throw new Error(`${name} is neither here nor at ${this.o.releases}`);
    }
    if (want?.sha256 !== undefined || want?.size !== undefined) {
      const got = await hashFile(path);
      if ((want.sha256 !== undefined && got.sha256 !== want.sha256) || (want.size !== undefined && got.size !== want.size)) throw new Error(`${name} is not the one its feed names`);
    }
    return path;
  }

  /** The first of a base's names there, checked by what is known of it; it is marked missing when none is. */
  private async fetchBase(t: Target, b: Base) {
    for (const name of b.names) {
      const to = this.tmp(name);
      let got: boolean;
      try { got = await this.src.fetch(name, to, this.abort.signal); } catch (e) {
        t.outcome.set(b, this.abort.signal.aborted ? "out of time" : `not fetched (${why(e)})`);
        b.missing = true;
        return;
      }
      if (!got) continue;
      if (b.sha256 !== undefined) {
        const h = await hashFile(to);
        if (h.sha256 !== b.sha256) { rmSync(to, { force: true }); continue; }
      }
      if (b.rawSha256 !== undefined && sha256(zstdDecompressSync(readFileSync(to))) !== b.rawSha256) {
        rmSync(to, { force: true });
        continue;
      }
      b.path = to;
      return;
    }
    b.missing = true;
    t.outcome.set(b, "not there");
  }

  /** The bases of a release of `build`: the published feed's build, then the ones its deltas are from; newest first,
   * older than `build`, at most --bases. */
  private bases(build: number, list: Base[]): Base[] {
    const seen = new Set<number>();
    return list.filter((b) => b.build < build && !seen.has(b.build) && (seen.add(b.build), true)).sort((a, b) => b.build - a.build).slice(0, this.o.bases);
  }

  async appTarget(feedName: string, feed: any): Promise<Target | null> {
    const label = feedName.replace(/\/latest\.json$/, "");
    const file = String(feed.file ?? "");
    const build = Number(feed.versionCode);
    if (!Number.isSafeInteger(build) || !file) throw new Error("not a feed of an app (versionCode, file)");
    const kind: Kind | null = file.endsWith(".zip") ? "mac" : file.endsWith("-win.exe") ? "win" : file.endsWith(".apk") ? "android" : file.endsWith("-linux.tar.gz") ? "linux" : null;
    if (!kind) throw new Error(`no deltas are made for ${file}`);
    const published = await this.src.text(feedName, this.abort.signal);
    let prev: any = null;
    if (published !== null) {
      try { prev = JSON.parse(published); } catch { throw new Error(`the feed at ${this.o.releases} is not JSON`); }
    }
    // (Windows: the raw installer beside its installer, `<exe>.raw.zst`, which is what its deltas make and are made from)
    const pkgName = (f: string) => (kind === "win" ? `${f}.raw.zst` : f);
    const list: Base[] = [];
    if (prev && Number.isSafeInteger(prev.versionCode) && typeof prev.file === "string") {
      const signedRaw = kind === "win" ? wordsOf(prev.signed)?.raw?.sha256 : undefined;
      list.push({ build: prev.versionCode, names: [pkgName(prev.file)], ...(kind === "win" ? { rawSha256: signedRaw } : { sha256: prev.sha256 }) });
      for (const d of Array.isArray(prev.deltas) ? prev.deltas : []) {
        if (Number.isSafeInteger(d?.from)) list.push({ build: d.from, names: [pkgName(baseFile(prev.file, prev.versionCode, d.from))] });
      }
    }
    // (a feed of this very build published already: the bases its deltas are from, by this release's names)
    for (const b of list) if (prev?.versionCode === build) b.names = [pkgName(baseFile(file, build, b.build))];
    const bases = this.bases(build, list);
    if (bases.length === 0) {
      this.lines.push(`${label} ${build}: no deltas (${prev ? "none older published" : `no feed published at ${this.o.releases}`}); package ${mb(feed.size)}`);
      return null;
    }
    // this release's package, checked against its feed, and what its deltas make
    let pkg: string;
    if (kind === "win") {
      const raw = wordsOf(feed.signed)?.raw;
      if (feed.signed !== undefined && !raw) throw new Error("its signed words say no raw installer (scripts/release-sign.ts file --raw): no delta would be taken");
      pkg = await this.ours(pkgName(file));
      const made = this.tmp("made");
      writeFileSync(made, rawPackage(kind, pkg));
      if (raw && sha256(readFileSync(made)) !== raw.sha256) throw new Error("its .raw.zst is not the raw installer its signed words say");
      return this.target(feedName, label, kind, build, pkg, feed.size, made, bases, feed, file);
    }
    pkg = await this.ours(file, { sha256: feed.sha256, size: feed.size });
    const made = kind === "android" ? pkg : this.tmp("made");
    if (kind !== "android") writeFileSync(made, rawPackage(kind, pkg));
    return this.target(feedName, label, kind, build, pkg, feed.size, made, bases, feed, file);
  }

  private target(feedName: string, label: string, kind: Kind, build: number, pkg: string, size: number, made: string, bases: Base[], feed: any, file: string): Target {
    const had = new Map<string, Made>();
    for (const d of Array.isArray(feed.deltas) ? feed.deltas : []) if (typeof d?.file === "string") had.set(d.file, d);
    return {
      feed: feedName, label, kind, build, package: pkg, packageSize: size, made, bases, had, outcome: new Map(), made_: [],
      name: (b) => `${file}.from-${b.build}.delta`,
      entry: (b, f, sha, n) => ({ from: b.build, file: f, sha256: sha, size: n }),
    };
  }

  /** The station's feed: a target for each platform its words name. */
  async stationTargets(feedName: string, feed: any): Promise<Target[]> {
    const channel = feedName === "station.json" ? "stable" : "beta";
    const words = wordsOf(feed);
    if (!words?.builds) throw new Error("not signed: its archives' hashes are not known, nor would a station take it");
    const build = Number(words.build);
    const published = await this.src.text(feedName, this.abort.signal);
    let prev: any = null;
    if (published !== null) {
      try { prev = JSON.parse(published); } catch { throw new Error(`the feed at ${this.o.releases} is not JSON`); }
    }
    const prevWords = wordsOf(prev);
    this.earlier.set(feedName, earlierOf(build, prev, this.o.bases));
    const inPlace = (p: string) => `${channel === "beta" ? "beta/" : ""}stillfail-station-${p}${p.startsWith("win32") ? ".zip" : ".tar.gz"}`;
    const archive = (b: number, sha: string, p: string) => `station/archive/${channel}/${b}-${sha}-${p}${p.startsWith("win32") ? ".zip" : ".tar.gz"}`;
    const out: Target[] = [];
    for (const platform of this.o.platform ? [this.o.platform] : STATION_PLATFORMS) {
      const it = words.builds[platform];
      if (!it) continue;
      const label = `${feedName.replace(/\.json$/, "")} ${platform}`;
      try {
        const pkg = await this.ours(inPlace(platform), { sha256: it.sha256, size: it.size });
        // its archive under a name of its own, for the releases after it (unless it is there already)
        const own = archive(build, it.sha256, platform);
        if (!existsSync(join(this.o.into, own)) && !(await this.src.has(own, this.abort.signal))) {
          mkdirSync(dirname(join(this.o.into, own)), { recursive: true });
          copyFileSync(pkg, join(this.o.into, own));
        }
        const list: Base[] = [];
        const before = prevWords?.builds?.[platform];
        if (before && Number.isSafeInteger(prevWords.build)) {
          // (its own name, else the name it was put under: still that release's until this one is put)
          list.push({ build: prevWords.build, sha256: before.sha256, names: [archive(prevWords.build, before.sha256, platform), inPlace(platform)] });
        }
        for (const d of Array.isArray(prev?.deltas?.[platform]) ? prev.deltas[platform] : []) {
          if (Number.isSafeInteger(d?.from) && /^[0-9a-f]{64}$/.test(d?.base ?? "")) list.push({ build: d.from, sha256: d.base, names: [archive(d.from, d.base, platform)] });
        }
        const bases = this.bases(build, list.filter((b) => b.sha256 !== it.sha256));
        if (bases.length === 0) {
          this.lines.push(`${label} ${build}: no deltas (${prev ? "none older published" : `no feed published at ${this.o.releases}`}); package ${mb(it.size)}`);
          continue;
        }
        const made = this.tmp("made");
        writeFileSync(made, rawPackage("station", pkg));
        if (it.rawSha256 !== undefined && sha256(readFileSync(made)) !== it.rawSha256) throw new Error("its raw form is not the one its signed words say");
        const had = new Map<string, Made>();
        for (const d of Array.isArray(feed.deltas?.[platform]) ? feed.deltas[platform] : []) if (typeof d?.file === "string") had.set(d.file, d);
        out.push({
          feed: feedName, label, kind: "station", build, package: pkg, packageSize: it.size, made, bases, had, outcome: new Map(), made_: [], platform,
          name: (b) => `${archive(build, it.sha256, platform).replace(/\.(tar\.gz|zip)$/, "")}.from-${b.build}-${b.sha256!.slice(0, 16)}.delta`,
          entry: (b, f, sha, n) => ({ from: b.build, file: f, sha256: sha, size: n, base: b.sha256! }),
        });
      } catch (e) {
        this.warn(`${label}: no deltas: ${why(e)}`);
        this.lines.push(`${label} ${build}: no deltas (${why(e)})`);
      }
    }
    return out;
  }

  /** Delta.java, DeltaBatch.java and JZlib compiled once (null: no javac here, and no Android delta). */
  private javaClasses(): string | null {
    if (this.classes !== undefined) return this.classes;
    const root = fileURLToPath(new URL("..", import.meta.url));
    const jz = join(root, "libs/mbui/android/jzlib/src/com/jcraft/jzlib");
    const out = join(this.work, "classes");
    const batchSrc = join(this.work, "java-src/dev/mbui/DeltaBatch.java");
    try {
      mkdirSync(dirname(batchSrc), { recursive: true });
      writeFileSync(batchSrc, DELTA_BATCH_JAVA);
      const srcs = [join(root, "libs/mbui/android/app/src/main/java/dev/mbui/Delta.java"), batchSrc, ...readdirSync(jz).filter((f) => f.endsWith(".java")).map((f) => join(jz, f))];
      const r = spawnSync("javac", ["-nowarn", "-encoding", "UTF-8", "-d", out, ...srcs], { encoding: "utf8" });
      if (r.status !== 0) throw new Error(r.error ? r.error.message : r.stderr.trim().split("\n").at(-1));
      return (this.classes = out);
    } catch (e) {
      this.warn(`the Java applier was not compiled (${why(e)}): no Android delta, which only it can check`);
      return (this.classes = null);
    }
  }

  /** Every pair made, --jobs persistent workers overlapped with bounded base prefetching, newest bases first. */
  async make(targets: Target[]) {
    const pairs: { t: Target; b: Base; rank: number }[] = [];
    for (const t of targets) t.bases.forEach((b, rank) => pairs.push({ t, b, rank }));
    pairs.sort((x, y) => x.rank - y.rank || targets.indexOf(x.t) - targets.indexOf(y.t));
    // (a delta in the feed already, its file here and as the feed says: kept, not made again)
    const todo = pairs.filter(({ t, b }) => {
      const name = t.name(b), had = t.had.get(name);
      for (const at of [join(this.o.into, name), join(this.dir, name)]) {
        if (had && existsSync(at) && statSync(at).size === had.size && sha256(readFileSync(at)) === had.sha256) {
          if (at !== join(this.o.into, name)) { mkdirSync(dirname(join(this.o.into, name)), { recursive: true }); copyFileSync(at, join(this.o.into, name)); }
          t.made_.push(t.entry(b, name, had.sha256, had.size));
          t.outcome.set(b, `${mb(had.size)}`);
          return false;
        }
      }
      return true;
    });
    if (todo.length === 0) return;

    const children = this.children;
    const abort = this.abort;
    // (delta-fast.c compiled once for the whole run, its makers handed the binary; none: they make them in JavaScript)
    const fast = ensureNativeDelta(this.work);
    const env = fast ? { ...process.env, STILLFAIL_DELTA_FAST_BIN: fast } : process.env;
    const jobs = Math.max(1, this.o.jobs);
    const prefetchCap = jobs + 2;

    // Bounded prefetch queue: at most `jobs + 2` bases in-flight or sitting on disk waiting for a CPU worker.
    let fetchIdx = 0;
    let unconsumed = 0;
    let activeFetchers = 0;
    let fetchDone = false;
    const ready: { idx: number; t: Target; b: Base }[] = [];
    const slotWaiters: (() => void)[] = [];
    const itemWaiters: (() => void)[] = [];
    const wakeSlot = () => { while (unconsumed < prefetchCap && slotWaiters.length) slotWaiters.shift()!(); };
    const wakeItem = () => { while (ready.length && itemWaiters.length) itemWaiters.shift()!(); };
    const wakeAll = () => {
      while (slotWaiters.length) slotWaiters.shift()!();
      while (itemWaiters.length) itemWaiters.shift()!();
    };
    abort.signal.addEventListener("abort", wakeAll, { once: true });

    const prefetcher = async () => {
      activeFetchers++;
      try {
        for (;;) {
          if (fetchIdx >= todo.length) break;
          while (unconsumed >= prefetchCap && !abort.signal.aborted) {
            await new Promise<void>((r) => slotWaiters.push(r));
          }
          if (fetchIdx >= todo.length) break;
          const idx = fetchIdx++;
          const { t, b } = todo[idx]!;
          if (abort.signal.aborted) {
            t.outcome.set(b, "out of time");
            continue;
          }
          unconsumed++;
          await this.fetchBase(t, b);
          if (b.missing) {
            unconsumed--;
            wakeSlot();
            continue;
          }
          if (abort.signal.aborted) {
            if (b.path) rmSync(b.path, { force: true });
            t.outcome.set(b, "out of time");
            unconsumed--;
            wakeSlot();
            continue;
          }
          ready.push({ idx, t, b });
          ready.sort((x, y) => x.idx - y.idx);
          wakeItem();
        }
      } finally {
        activeFetchers--;
        if (activeFetchers === 0) {
          fetchDone = true;
          wakeAll();
        }
      }
    };

    const take = async (): Promise<{ t: Target; b: Base } | null> => {
      for (;;) {
        if (ready.length > 0) {
          const item = ready.shift()!;
          unconsumed--;
          wakeSlot();
          return item;
        }
        if (fetchDone) return null;
        await new Promise<void>((r) => itemWaiters.push(r));
      }
    };

    type WorkerReply = { id: number; ok: boolean; error?: string };
    const createWorker = () => {
      let proc: ReturnType<typeof spawn> | null = null;
      let err = "";
      let buf = "";
      let reqId = 0;
      let pending: { id: number; resolve: (said: string | null) => void } | null = null;

      const start = () => {
        if (proc) return proc;
        const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "--worker"], { stdio: ["pipe", "pipe", "pipe"], env });
        proc = child;
        err = "";
        buf = "";
        children.add(child);
        child.stderr!.on("data", (d: Buffer) => { err = (err + d.toString("utf8")).slice(-2000); });
        child.stdout!.on("data", (d: Buffer) => {
          buf += d.toString("utf8");
          for (;;) {
            const nl = buf.indexOf("\n");
            if (nl < 0) break;
            const line = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (!line) continue;
            const p = pending;
            pending = null;
            if (!p) continue;
            try {
              const msg = JSON.parse(line) as WorkerReply;
              p.resolve(msg.ok ? null : msg.error || "failed");
            } catch {
              p.resolve(err.trim().split("\n").at(-1) || "invalid worker response");
            }
          }
        });
        child.on("close", (code, sig) => {
          children.delete(child);
          if (proc === child) proc = null;
          const p = pending;
          pending = null;
          if (p) p.resolve(abort.signal.aborted ? "out of time" : err.trim().split("\n").at(-1) || `ended (${code ?? sig})`);
        });
        child.on("error", (e) => {
          children.delete(child);
          if (proc === child) proc = null;
          const p = pending;
          pending = null;
          if (p) p.resolve(abort.signal.aborted ? "out of time" : why(e));
        });
        return child;
      };

      return {
        run(pair: Pair): Promise<string | null> {
          return new Promise((resolve) => {
            const child = start();
            const id = ++reqId;
            pending = { id, resolve };
            child.stdin!.write(`${JSON.stringify({ id, pair })}\n`);
          });
        },
        async close(): Promise<void> {
          const child = proc;
          if (!child) return;
          proc = null;
          await new Promise<void>((resolve) => {
            child.once("close", () => resolve());
            if (abort.signal.aborted) {
              try { child.kill("SIGKILL"); } catch { resolve(); }
            } else {
              try { child.stdin!.end(); } catch { resolve(); }
            }
          });
        },
      };
    };

    const workerCount = Math.min(jobs, todo.length);
    const workers = Array.from({ length: workerCount }, () => createWorker());
    const runWorker = async (w: ReturnType<typeof createWorker>) => {
      try {
        for (;;) {
          const item = await take();
          if (!item) break;
          const { t, b } = item;
          if (this.abort.signal.aborted) {
            if (b.path) rmSync(b.path, { force: true });
            t.outcome.set(b, "out of time");
            continue;
          }
          const classes = t.kind === "android" ? this.javaClasses() : undefined;
          if (classes === null) {
            if (b.path) rmSync(b.path, { force: true });
            t.outcome.set(b, "not checked (no javac)");
            continue;
          }
          const out = this.tmp("delta");
          const said = await w.run({ kind: t.kind, base: b.path!, made: t.made, out, classes });
          rmSync(b.path!, { force: true });
          if (said !== null) {
            if (said !== "out of time") this.warn(`${t.label} from ${b.build}: no delta: ${said}`);
            t.outcome.set(b, said === "out of time" ? said : "failed");
            continue;
          }
          const size = statSync(out).size;
          if (size >= KEPT_BELOW * t.packageSize) {
            rmSync(out, { force: true });
            t.outcome.set(b, `not kept (${mb(size)}, ${KEPT_BELOW * 100}% of the package or more)`);
            continue;
          }
          const name = t.name(b);
          moveInto(out, join(this.o.into, name));
          t.made_.push(t.entry(b, name, sha256(readFileSync(join(this.o.into, name))), size));
          t.outcome.set(b, mb(size));
        }
      } finally {
        await w.close();
      }
    };

    const fetcherCount = Math.min(prefetchCap, todo.length);
    await Promise.all([
      ...Array.from({ length: fetcherCount }, () => prefetcher()),
      ...workers.map((w) => runWorker(w)),
    ]);
  }

  /** The feed amended: its deltas the ones made now (newest first); an app's `raw` beside them (but Android's). */
  amend(feedName: string, feed: any, targets: Target[]) {
    const { raw: _r, deltas: _d, ...rest } = feed;
    let amended: any;
    if (feedName.startsWith("station")) {
      const deltas: Record<string, Made[]> = {};
      for (const t of targets) if (t.made_.length) deltas[t.platform!] = [...t.made_].sort((a, b) => b.from - a.from);
      const { earlier: _e, ...words } = rest;
      const earlier = this.earlier.get(feedName) ?? [];
      if (this.o.platform) {
        // (one platform's: beside the feed, for --merge; release-put.sh --files leaves it, a feed by its name, out)
        const platform = this.o.platform, mine = deltas[platform] ?? [];
        if (earlier.length === 0 && mine.length === 0) return;
        const to = join(this.o.into, fragmentName(feedName, platform));
        mkdirSync(dirname(to), { recursive: true });
        writeFileSync(`${to}.new`, `${JSON.stringify({ earlier, platform, deltas: mine } satisfies Fragment)}\n`);
        renameSync(`${to}.new`, to);
        return;
      }
      amended = { ...words, ...(earlier.length ? { earlier } : {}), ...(Object.keys(deltas).length ? { deltas } : {}) };
    } else {
      const t = targets[0];
      const made = t ? [...t.made_].sort((a, b) => b.from - a.from) : [];
      if (made.length === 0) amended = rest;
      else {
        const raw = readFileSync(t!.made);
        amended = { ...rest, ...(t!.kind === "android" ? {} : { raw: { sha256: sha256(raw), size: raw.length } }), deltas: made };
      }
    }
    if (JSON.stringify(amended) === JSON.stringify(feed) && this.o.into === this.dir) return;
    if (JSON.stringify(amended) === JSON.stringify(feed) && !existsSync(join(this.o.into, feedName))) return;
    const to = join(this.o.into, feedName);
    mkdirSync(dirname(to), { recursive: true });
    writeFileSync(`${to}.new`, `${JSON.stringify(amended)}\n`);
    renameSync(`${to}.new`, to);
  }

  say(t: Target) {
    const parts = t.bases.map((b) => `from ${b.build} ${t.outcome.get(b) ?? "not made"}`);
    this.lines.push(`${t.label} ${t.build}: ${parts.join(", ")}; package ${mb(t.packageSize)}`);
  }

  done() {
    if (this.timer) clearTimeout(this.timer);
    for (const c of this.children) {
      try { c.kill("SIGKILL"); } catch { /* already gone */ }
    }
    this.children.clear();
    this.src.close?.();
    rmSync(this.work, { recursive: true, force: true });
  }
}

/** What a run of one platform (--platform) would have put in the station's feed, beside it. */
type Fragment = { earlier: Signed[]; platform: string; deltas: Made[] };
const fragmentName = (feedName: string, platform: string) => `${feedName.replace(/\.json$/, "")}.deltas.${platform}.json`;
const FRAGMENT = /^(station(?:-beta)?)\.deltas\.([^.]+)\.json$/;

/** Each <feed>.deltas.<platform>.json in `dir` put in its feed there, as one run of every platform would have amended
 * it (its `earlier`, each platform's deltas, in STATION_PLATFORMS' order, newest first), and deleted, whatever came of
 * it: a fragment left there would be put as a feed (release-put.sh's feed()). A platform with no fragment (its job
 * failed) keeps what the feed said of it; nothing here fails a release. */
export function mergeDeltas(dir: string): { lines: string[]; warnings: string[] } {
  const lines: string[] = [], warnings: string[] = [];
  const byFeed = new Map<string, string[]>();
  for (const name of existsSync(dir) ? readdirSync(dir).sort() : []) {
    const m = FRAGMENT.exec(name);
    if (m) byFeed.set(`${m[1]}.json`, [...(byFeed.get(`${m[1]}.json`) ?? []), name]);
  }
  for (const [feedName, names] of byFeed) {
    try {
      const path = join(dir, feedName);
      if (!existsSync(path)) throw new Error("no such feed here");
      const feed = JSON.parse(readFileSync(path, "utf8"));
      const { raw: _r, deltas: had, earlier: hadEarlier, ...words } = feed;
      const deltas: Record<string, Made[]> = { ...(had && typeof had === "object" ? had : {}) };
      let earlier: Signed[] = Array.isArray(hadEarlier) ? hadEarlier : [];
      const said: string[] = [];
      for (const name of names) {
        let f: Fragment;
        try { f = JSON.parse(readFileSync(join(dir, name), "utf8")); } catch (e) { warnings.push(`${name}: not read: ${why(e)}`); continue; }
        if (!STATION_PLATFORMS.includes(f.platform) || !Array.isArray(f.deltas)) { warnings.push(`${name}: not a station platform's deltas`); continue; }
        if (Array.isArray(f.earlier) && f.earlier.length) earlier = f.earlier;
        if (f.deltas.length) deltas[f.platform] = [...f.deltas].sort((a, b) => b.from - a.from);
        else delete deltas[f.platform];
        said.push(`${f.platform} ${f.deltas.length}`);
      }
      const order = (k: string) => (STATION_PLATFORMS.includes(k) ? STATION_PLATFORMS.indexOf(k) : STATION_PLATFORMS.length);
      const sorted = Object.fromEntries(Object.entries(deltas).sort(([a], [b]) => order(a) - order(b)));
      const amended = { ...words, ...(earlier.length ? { earlier } : {}), ...(Object.keys(sorted).length ? { deltas: sorted } : {}) };
      writeFileSync(`${path}.new`, `${JSON.stringify(amended)}\n`);
      renameSync(`${path}.new`, path);
      lines.push(`${feedName}: merged (${said.join(", ") || "nothing"})`);
    } catch (e) {
      warnings.push(`${feedName}: deltas not merged: ${why(e)}`);
    } finally {
      for (const name of names) rmSync(join(dir, name), { force: true });
    }
  }
  return { lines, warnings };
}

/** The feeds of a release directory: the apps' (…/latest.json) and the station's. */
function feedsIn(dir: string): string[] {
  const out: string[] = [];
  const walk = (rel: string) => {
    for (const e of readdirSync(rel ? join(dir, rel) : dir, { withFileTypes: true })) {
      const path = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(path);
      else if (e.isFile() && (/(^|\/)latest\.json$/.test(path) || path === "station.json" || path === "station-beta.json")) out.push(path);
    }
  };
  walk("");
  return out.sort();
}

export async function releaseDeltas(dir: string, o: Options): Promise<{ lines: string[]; warnings: string[] }> {
  const run = new Run(dir, o);
  try {
    const feeds: { name: string; feed: any; targets: Target[] }[] = [];
    for (const name of feedsIn(dir).filter((n) => !o.platform || n.startsWith("station"))) {
      try {
        const feed = JSON.parse(readFileSync(join(dir, name), "utf8"));
        const targets = name.startsWith("station") ? await run.stationTargets(name, feed) : [await run.appTarget(name, feed)].filter((t): t is Target => t !== null);
        feeds.push({ name, feed, targets });
      } catch (e) {
        run.warn(`${name}: no deltas: ${why(e)}`);
        run.lines.push(`${name.replace(/\/latest\.json$|\.json$/, "")}: no deltas (${why(e)})`);
      }
    }
    await run.make(feeds.flatMap((f) => f.targets));
    for (const f of feeds) {
      try { run.amend(f.name, f.feed, f.targets); } catch (e) { run.warn(`${f.name}: not amended: ${why(e)}`); }
      for (const t of f.targets) run.say(t);
    }
  } finally {
    run.done();
  }
  return { lines: run.lines, warnings: run.warnings };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const usage = (): never => {
    console.error("usage: release-deltas.ts <release dir> [--releases URL|DIR] [--bases N] [--jobs N] [--deadline SECONDS] [--into DIR] [--platform P] | --merge DIR | --zst RAW OUT");
    process.exit(2);
  };
  if (args[0] === "--pair") {
    try { await makePair(JSON.parse(readFileSync(args[1] ?? usage(), "utf8"))); } catch (e) { console.error(why(e)); process.exit(1); }
    process.exit(0);
  }
  if (args[0] === "--worker") {
    const javaBatch = new JavaBatch();
    const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
    try {
      for await (const line of rl) {
        if (!line.trim()) continue;
        const { id, pair } = JSON.parse(line) as { id: number; pair: Pair };
        try {
          await makePair(pair, javaBatch);
          process.stdout.write(`${JSON.stringify({ id, ok: true })}\n`);
        } catch (e) {
          process.stdout.write(`${JSON.stringify({ id, ok: false, error: why(e) })}\n`);
        }
      }
    } finally {
      await javaBatch.close();
    }
    process.exit(0);
  }
  if (args[0] === "--zst") {
    const [raw, out] = [args[1] ?? usage(), args[2] ?? usage()];
    writeFileSync(out, zstdCompressSync(readFileSync(raw)));
    process.exit(0);
  }
  if (args[0] === "--merge") {
    const r = mergeDeltas(args[1] ?? usage());
    for (const w of r.warnings) console.error(`${process.env.GITHUB_ACTIONS ? "::warning::" : ""}release-deltas: ${w}`);
    for (const line of r.lines) console.log(`deltas: ${line}`);
    process.exit(0);
  }
  const flag = (name: string) => { const i = args.indexOf(name); return i >= 0 ? (args[i + 1] ?? usage()) : undefined; };
  const dir = args[0] && !args[0].startsWith("--") ? args[0] : usage();
  const number = (name: string, fallback: number | null) => {
    const v = flag(name);
    if (v === undefined) return fallback;
    const n = Number(v);
    return Number.isFinite(n) && n > 0 ? n : usage();
  };
  // (each maker ~2 GB at its most, a 60 MB package: no more at once than the memory holds, nor than the cores; 4 at
  // most, a GitHub runner's cores, as the CI Macs are shared)
  const jobs = Math.max(1, Math.min(4, availableParallelism(), Math.floor(totalmem() / (2 * GB))));
  const o: Options = {
    releases: flag("--releases") ?? "https://app.still.fail/releases",
    bases: number("--bases", 10)!,
    jobs: number("--jobs", jobs)!,
    deadline: number("--deadline", null),
    into: flag("--into") ?? dir,
    platform: flag("--platform") ?? null,
  };
  if (o.platform && !STATION_PLATFORMS.includes(o.platform)) usage();
  mkdirSync(o.into, { recursive: true });
  let result: { lines: string[]; warnings: string[] } = { lines: [], warnings: [] };
  try {
    result = await releaseDeltas(dir, o);
  } catch (e) {
    // (whatever it was: the feeds stay as they were, and the release goes on)
    console.error(`${process.env.GITHUB_ACTIONS ? "::warning::" : ""}release-deltas: no deltas: ${why(e)}`);
    result.lines.push(`no deltas: ${why(e)}`);
  }
  for (const line of result.lines) console.log(`deltas: ${line}`);
  if (process.env.GITHUB_STEP_SUMMARY && result.lines.length) {
    writeFileSync(process.env.GITHUB_STEP_SUMMARY, `${result.lines.map((l) => `- deltas: ${l}`).join("\n")}\n`, { flag: "a" });
  }
}
