// Deltas from an installed build to a release's package: the file format, bsdiff's matching (Colin Percival's
// algorithm, written here), and a package's raw form (what a delta makes). The reference applier is the station's
// (station/src/updates/delta.ts, which applies the station's own deltas), taken from there; the apps carry appliers of
// their own (C, Java) for this format.
//   delta.ts make  --old DIR --new FILE --out DELTA          old blob: DIR's regular files (not symlinks), sorted by path
//   delta.ts make  --old-apk APK --new APK --out DELTA [--deflate-check node|none]
//   delta.ts apply --old DIR|--old-apk APK --delta DELTA --out FILE
//   delta.ts info DELTA                                      the header, as JSON
//   delta.ts raw ARCHIVE OUT                                 the raw form of a package: a .tar.gz's tar (gunzipped), a
//                                                            .zip with every entry stored (storedZip)
// The format (little-endian):
//   "SFDELTA1"; u32 n_files, n × { u16 len; utf8 path }; u32 n_inflate, n × { u64 at; u64 packed_len };
//   u64 old_size; sha256 of the old blob; u32 n_deflate, n × { u64 at; u64 raw_len }; u64 made_size;
//   chunks { u32 raw_len; u32 packed_len; raw deflate } ended by raw_len = 0.
// The chunks' raw bytes are bsdiff's records in Endsley's layout, uncompressed: { i64 x, y, z; x diff bytes; y extra
// bytes }, i64 two's complement. Chunks are at most 1 MiB raw so an applier's memory is bounded; a record may span them.
// An apk's old blob is the old apk with its n_inflate ranges inflated in place; its made bytes are the new apk with
// the entries whose deflated bytes changed inflated, written out with the n_deflate ranges deflated again. Only a
// deflater giving the same bytes as the one that made the apk makes it again: node's (level 6) makes the tests' zips;
// a real APK is checked by the Java applier the app carries (`--deflate-check none` here checks the bsdiff alone).
// Making: the old files found whole in the made bytes (wholeFiles: an old tree's files, an apk's entries), and the old
// bytes found as they were between them (sameBlocks: what a build left of a big binary, shifted), are matched where they
// were found, and only the rest of the old blob is sorted for bsdiff to search (sparseSuffixArray), each search starting
// in the bucket of its first 3 bytes. From PREFIXED_FROM old bytes the search, the records and their deflating are
// scripts/delta-fast.c's, the same steps in C (ensureNativeDelta), where a C compiler with zlib is at hand.
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { accessSync, constants as fsConstants, existsSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { crc32, deflateRawSync, gunzipSync, inflateRawSync } from "node:zlib";
import { CHUNK, type Header, MAGIC, type Range, apply, applyFile, parseHeader, patch, readOld } from "../station/src/updates/delta.ts";

export { CHUNK, type Header, type Range, type Sink, apply, applyFile, parseHeader, patch, readOld } from "../station/src/updates/delta.ts";

const TWO32 = 4294967296;
const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

// --- the suffix array: SA-IS (Nong, Zhang, Chan), linear whatever the repeats (megabytes of zeros in a binary) ---

/** The suffix array of `blob` with the empty suffix first, as bsdiff searches it: I[0] = n. */
export function suffixArray(blob: Uint8Array): Int32Array {
  const I = new Int32Array(blob.length + 1);
  I[0] = blob.length;
  sais(blob, blob.length, 255, I.subarray(1));
  if (blob.length >= PREFIXED_FROM) starting.set(I, prefixStarts(blob));
  return I;
}

function sais(s: Uint8Array | Int32Array, n: number, upper: number, sa: Int32Array): void {
  if (n === 0) return;
  if (n === 1) { sa[0] = 0; return; }
  if (n === 2) { if (s[0]! < s[1]!) { sa[0] = 0; sa[1] = 1; } else { sa[0] = 1; sa[1] = 0; } return; }
  // t's bit i: suffix i is S-type (smaller than suffix i+1); the virtual sentinel after s makes s[n-1] L-type. Bits,
  // not a byte each: the inducing reads them at random, an eighth as much memory to miss in.
  const t = new Uint32Array((n + 31) >>> 5);
  for (let i = n - 2, next = 0; i >= 0; i--) {
    const a = s[i]!, b = s[i + 1]!;
    next = a < b ? 1 : a > b ? 0 : next;
    if (next) t[i >>> 5]! |= 1 << (i & 31);
  }
  const S = (i: number) => (t[i >>> 5]! >>> (i & 31)) & 1;
  // sumL[c]: where bucket c begins; sumS[c]: where its S-type part begins.
  const sumL = new Int32Array(upper + 2), sumS = new Int32Array(upper + 2);
  for (let i = 0; i < n; i++) if (!S(i)) sumS[s[i]!]!++; else sumL[s[i]! + 1]!++;
  for (let c = 0; c <= upper; c++) { sumS[c]! += sumL[c]!; if (c < upper) sumL[c + 1]! += sumS[c]!; }
  const buf = new Int32Array(upper + 2);
  const induce = (lms: Int32Array, m: number) => {
    sa.fill(-1, 0, n);
    buf.set(sumS);
    for (let i = 0; i < m; i++) { const d = lms[i]!; sa[buf[s[d]!]!++] = d; }
    buf.set(sumL);
    sa[buf[s[n - 1]!]!++] = n - 1;
    for (let i = 0; i < n; i++) { const v = sa[i]!; if (v >= 1 && !S(v - 1)) sa[buf[s[v - 1]!]!++] = v - 1; }
    buf.set(sumL);
    for (let i = n - 1; i >= 0; i--) { const v = sa[i]!; if (v >= 1 && S(v - 1)) sa[--buf[s[v - 1]! + 1]!] = v - 1; }
  };
  const isLms = (i: number) => i > 0 && S(i) === 1 && S(i - 1) === 0;
  let m = 0;
  for (let i = 1; i < n; i++) if (isLms(i)) m++;
  const lms = new Int32Array(m);
  for (let i = 1, k = 0; i < n; i++) if (isLms(i)) lms[k++] = i;
  induce(lms, m);
  if (m === 0) return;
  const sorted = new Int32Array(m);
  for (let i = 0, k = 0; i < n; i++) if (isLms(sa[i]!)) sorted[k++] = sa[i]!;
  // Each LMS substring named by its rank among them, equal substrings one name: kept in sa (free now) at its position's
  // half, two LMS positions never being next to each other, then read out in the text's order.
  let top = 0;
  sa[sorted[0]! >>> 1] = 0;
  for (let i = 1; i < m; i++) {
    const l = sorted[i - 1]!, r = sorted[i]!;
    // (the same up to and with the next LMS position, that of both at once; the sentinel is like no other)
    let same = false;
    for (let d = 0; ; d++) {
      if (l + d === n || r + d === n || s[l + d] !== s[r + d]) break;
      if (d > 0) {
        const el = isLms(l + d), er = isLms(r + d);
        if (el || er) { same = el && er; break; }
      }
    }
    if (!same) top++;
    sa[r >>> 1] = top;
  }
  const names = new Int32Array(m);
  for (let i = 0; i < m; i++) names[i] = sa[lms[i]! >>> 1]!;
  const order = new Int32Array(m);
  if (top + 1 === m) for (let i = 0; i < m; i++) order[names[i]!] = i;
  else sais(names, m, top, order);
  for (let i = 0; i < m; i++) sorted[i] = lms[order[i]!]!;
  induce(sorted, m);
}

// --- the old files found whole ---

/** `len` bytes of the made blob from `made` that are the old file at `old`, byte for byte. */
export type Run = { made: number; old: number; len: number };

/** The window a file's start is looked for by: files shorter than it are not looked for. */
export const WINDOW = 256;
const HASH = 0x01000193;

/**
 * Runs of `made` that are a whole old file (`files`: their ranges in `old`), sorted by `made`, not overlapping: the
 * first WINDOW bytes of each file are indexed by a rolling hash, which is rolled over `made`; at a hit the whole file
 * is compared. Where several files match there, the longest, then the first in `old`.
 */
export function wholeFiles(old: Uint8Array, files: Range[], made: Uint8Array): Run[] {
  const W = WINDOW, out: Run[] = [];
  if (made.length < W) return out;
  const hash = (b: Uint8Array, at: number) => {
    let h = 0;
    for (let i = 0; i < W; i++) h = (Math.imul(h, HASH) + b[at + i]!) | 0;
    return h;
  };
  let top = 1; // HASH ** W, what the byte leaving the window weighed
  for (let i = 0; i < W; i++) top = Math.imul(top, HASH);
  // (a bit for each value of a hash's top 22 bits, so that the scan touches no Map at most bytes)
  const bits = new Uint32Array(1 << 17), starting = new Map<number, Range[]>();
  for (const f of files) {
    if (f.len < W) continue;
    // (a window of one byte said over, zeros mostly, is at every place of such a stretch of `made`, each a compare as
    // long as the stretch: such a file is not looked for)
    let flat = true;
    for (let i = 1; i < W && flat; i++) flat = old[f.at + i] === old[f.at];
    if (flat) continue;
    const h = hash(old, f.at);
    bits[h >>> 15]! |= 1 << ((h >>> 10) & 31);
    const list = starting.get(h);
    if (list) list.push(f); else starting.set(h, [f]);
  }
  for (const list of starting.values()) list.sort((a, b) => b.len - a.len || a.at - b.at);
  const view = Buffer.from(made.buffer, made.byteOffset, made.length), oldView = Buffer.from(old.buffer, old.byteOffset, old.length);
  let p = 0, h = hash(made, 0);
  for (;;) {
    let found: Range | undefined;
    if (bits[h >>> 15]! & (1 << ((h >>> 10) & 31))) {
      for (const f of starting.get(h) ?? []) {
        if (p + f.len <= made.length && view.compare(oldView, f.at, f.at + f.len, p, p + f.len) === 0) { found = f; break; }
      }
    }
    if (found) {
      out.push({ made: p, old: found.at, len: found.len });
      p += found.len;
      if (p + W > made.length) break;
      h = hash(made, p);
    } else {
      if (p + W >= made.length) break;
      h = (Math.imul(h, HASH) - Math.imul(made[p]!, top) + made[p + W]!) | 0;
      p++;
    }
  }
  return out;
}

/** The blocks old bytes are found by where no whole file was: a run found is at least this long. */
export const BLOCK = 256;

/**
 * `runs` (sorted by `made`, not overlapping) with the stretches of `made` between them that are old bytes as they were,
 * a BLOCK at least, put in: the old blob's BLOCK-aligned blocks are indexed by a rolling hash, which is rolled over each
 * stretch; a block found there is followed back and forward as far as the bytes agree. What a build changed in a big
 * binary leaves most of it as it was, shifted: those bytes need no search, nor to be sorted for one.
 */
export function sameBlocks(old: Uint8Array, made: Uint8Array, runs: Run[]): Run[] {
  const B = BLOCK, out: Run[] = [];
  if (made.length < B || old.length < B) return runs;
  const hash = (b: Uint8Array, at: number) => {
    let h = 0;
    for (let i = 0; i < B; i++) h = (Math.imul(h, HASH) + b[at + i]!) | 0;
    return h;
  };
  let top = 1;
  for (let i = 0; i < B; i++) top = Math.imul(top, HASH);
  const bits = new Uint32Array(1 << 17), first = new Map<number, number>();
  for (let at = 0; at + B <= old.length; at += B) {
    // (a block of one byte said over is in every such stretch, each a compare: not indexed)
    let flat = true;
    for (let i = 1; i < B && flat; i++) flat = old[at + i] === old[at];
    if (flat) continue;
    const h = hash(old, at);
    if (first.has(h)) continue;
    first.set(h, at);
    bits[h >>> 15]! |= 1 << ((h >>> 10) & 31);
  }
  const view = Buffer.from(made.buffer, made.byteOffset, made.length), oldView = Buffer.from(old.buffer, old.byteOffset, old.length);
  const look = (from: number, to: number) => {
    let p = from;
    if (to - p < B) return;
    let h = hash(made, p);
    for (;;) {
      const o = bits[h >>> 15]! & (1 << ((h >>> 10) & 31)) ? first.get(h) : undefined;
      if (o !== undefined && view.compare(oldView, o, o + B, p, p + B) === 0) {
        let back = 0;
        const most = Math.min(p - from, o);
        while (back < most && made[p - back - 1] === old[o - back - 1]) back++;
        let len = B;
        const ahead = Math.min(to - p, old.length - o);
        while (len < ahead && made[p + len] === old[o + len]) len++;
        out.push({ made: p - back, old: o - back, len: back + len });
        p += len;
        if (p + B > to) return;
        h = hash(made, p);
      } else {
        if (p + B >= to) return;
        h = (Math.imul(h, HASH) - Math.imul(made[p]!, top) + made[p + B]!) | 0;
        p++;
      }
    }
  };
  let at = 0;
  for (const r of runs) {
    look(at, r.made);
    out.push(r);
    at = r.made + r.len;
  }
  look(at, made.length);
  return out;
}

/** The ranges of an old blob of `size` bytes outside `runs`' files, and how many bytes they hold. */
function outside(size: number, runs: Run[]) {
  const taken = runs.map((r) => [r.old, r.old + r.len] as const).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const gaps: [number, number][] = [];
  let o = 0, m = 0;
  for (const [start, end] of [...taken, [size, size] as const]) {
    if (start > o) { gaps.push([o, start]); m += start - o; }
    o = Math.max(o, end);
  }
  return { gaps, m };
}

/**
 * The suffix array of the old bytes outside `runs`' files, each suffix by its offset in `old`, I[0] = old.length (the
 * empty suffix), as bsdiff searches it.
 */
export function sparseSuffixArray(old: Uint8Array, runs: Run[]): Int32Array {
  const { gaps, m } = outside(old.length, runs);
  const reduced = new Uint8Array(m), at = new Int32Array(m);
  let r = 0;
  for (const [start, end] of gaps) {
    reduced.set(old.subarray(start, end), r);
    for (let i = start; i < end; i++) at[r++] = i;
  }
  // Sorted as the reduced bytes, not the whole old: only where a comparison runs past a reduced range's end does that
  // differ, which makes a search find a shorter match, never a wrong one (matchlen, below and the records read `old`).
  const I = new Int32Array(m + 1);
  I[0] = old.length;
  sais(reduced, m, 255, I.subarray(1));
  for (let i = 1; i <= m; i++) I[i] = at[I[i]!]!;
  if (m >= PREFIXED_FROM) starting.set(I, prefixStarts(reduced));
  return I;
}

/** The 3-byte prefixes a search starts by: 2^24 of them, a bucket each in the suffix array (64 MB of starts, made for
 * what is sorted from PREFIXED_FROM bytes: under it the whole search stays in the cache). */
const PREFIXES = 1 << 24;
export const PREFIXED_FROM = 1 << 20;
/** A suffix array's buckets by the first 3 bytes of what was sorted (big-endian, a suffix shorter than 3 padded with
 * zeros: it sorts first in that bucket), where its maker knew them: I[starts[p]] is the first suffix of p. */
const starting = new WeakMap<Int32Array, Int32Array>();

function prefixStarts(sorted: Uint8Array): Int32Array {
  const m = sorted.length, starts = new Int32Array(PREFIXES + 1);
  // (counted a slot ahead, so that the sum below leaves each its start)
  for (let r = 0; r + 2 < m; r++) starts[((sorted[r]! << 16) | (sorted[r + 1]! << 8) | sorted[r + 2]!) + 1]!++;
  if (m >= 2) starts[((sorted[m - 2]! << 16) | (sorted[m - 1]! << 8)) + 1]!++;
  if (m >= 1) starts[(sorted[m - 1]! << 16) + 1]!++;
  starts[0] = 1;
  for (let p = 1; p <= PREFIXES; p++) starts[p]! += starts[p - 1]!;
  return starts;
}

// --- bsdiff ---

/** bsdiff's records turning `old` into `made`, cut in chunks (each with its 8-byte head), without the end chunk;
 * with `known` (wholeFiles), a position in one of its runs is matched there without a search. */
export function bsdiff(old: Buffer, made: Buffer, I: Int32Array = suffixArray(old), known: Run[] = []): Buffer[] {
  const oldsize = old.length, newsize = made.length;
  const out = chunker(), starts = starting.get(I);
  let pos = 0;
  const matchlen = (o: number, s: number) => {
    const n = Math.min(oldsize - o, newsize - s);
    let i = 0;
    while (i < n && old[o + i] === made[s + i]) i++;
    return i;
  };
  // old[o..] < made[s..] over the shorter of the two, as memcmp: a short look first, native for long equal runs.
  const below = (o: number, s: number) => {
    const n = Math.min(oldsize - o, newsize - s), quick = Math.min(n, 32);
    for (let i = 0; i < quick; i++) if (old[o + i] !== made[s + i]) return old[o + i]! < made[s + i]!;
    return n > quick && old.compare(made, s + quick, s + n, o + quick, o + n) < 0;
  };
  // (scan never goes back: the run that may hold it is found by going forward)
  let k = 0;
  const search = (scan: number) => {
    while (k < known.length && known[k]!.made + known[k]!.len <= scan) k++;
    const run = known[k];
    if (run && run.made <= scan) {
      pos = run.old + (scan - run.made);
      const n = run.made + run.len - scan;
      return n + matchlen(pos + n, scan + n);
    }
    // (from the bucket of its first 3 bytes: the bounds the whole search would come to, without its first two dozen
    // steps, each a miss of the cache once the array is tens of MB. Only where a suffix sorted ran past a reduced range's
    // end could the two differ: a shorter match)
    let st = 0, en = I.length - 1;
    if (starts && scan + 3 <= newsize) {
      const p = (made[scan]! << 16) | (made[scan + 1]! << 8) | made[scan + 2]!;
      st = starts[p]! - 1;
      en = Math.min(starts[p + 1]!, I.length - 1);
    }
    while (en - st >= 2) {
      const x = st + ((en - st) >> 1);
      if (below(I[x]!, scan)) st = x; else en = x;
    }
    const x = matchlen(I[st]!, scan), y = matchlen(I[en]!, scan);
    if (x > y) { pos = I[st]!; return x; }
    pos = I[en]!;
    return y;
  };
  const at = (i: number) => (i >= 0 && i < oldsize ? old[i]! : -1);
  let scan = 0, len = 0, lastscan = 0, lastpos = 0, lastoffset = 0;
  while (scan < newsize) {
    let oldscore = 0, scsc = (scan += len);
    for (; scan < newsize; scan++) {
      len = search(scan);
      for (; scsc < scan + len; scsc++) if (at(scsc + lastoffset) === made[scsc]) oldscore++;
      if ((len === oldscore && len !== 0) || len > oldscore + 8) break;
      if (at(scan + lastoffset) === made[scan]) oldscore--;
    }
    if (len === oldscore && scan !== newsize) continue;
    // The match found extends forward from the last one (lenf) and back from this one (lenb) while at least half its
    // bytes agree; where the two overlap, the split keeps whichever agrees more.
    let s = 0, Sf = 0, lenf = 0;
    for (let i = 0; lastscan + i < scan && lastpos + i < oldsize;) {
      if (old[lastpos + i] === made[lastscan + i]) s++;
      i++;
      if (s * 2 - i > Sf * 2 - lenf) { Sf = s; lenf = i; }
    }
    let lenb = 0;
    if (scan < newsize) {
      let Sb = 0;
      s = 0;
      for (let i = 1; scan >= lastscan + i && pos >= i; i++) {
        if (old[pos - i] === made[scan - i]) s++;
        if (s * 2 - i > Sb * 2 - lenb) { Sb = s; lenb = i; }
      }
    }
    if (lastscan + lenf > scan - lenb) {
      const overlap = lastscan + lenf - (scan - lenb);
      let Ss = 0, lens = 0;
      s = 0;
      for (let i = 0; i < overlap; i++) {
        if (made[lastscan + lenf - overlap + i] === old[lastpos + lenf - overlap + i]) s++;
        if (made[scan - lenb + i] === old[pos - lenb + i]) s--;
        if (s > Ss) { Ss = s; lens = i + 1; }
      }
      lenf += lens - overlap;
      lenb -= lens;
    }
    const y = scan - lenb - (lastscan + lenf);
    out.record(lenf, y, pos - lenb - (lastpos + lenf));
    out.diff(made, lastscan, old, lastpos, lenf);
    out.extra(made, lastscan + lenf, y);
    lastscan = scan - lenb;
    lastpos = pos - lenb;
    lastoffset = pos - scan;
  }
  return out.end();
}

function putI64(b: Buffer, at: number, v: number) {
  const hi = Math.floor(v / TWO32);
  b.writeUInt32LE(v - hi * TWO32, at);
  b.writeInt32LE(hi, at + 4);
}

function chunker() {
  const parts: Buffer[] = [], buf = Buffer.allocUnsafe(CHUNK), ctrl = Buffer.alloc(24);
  let fill = 0;
  const flush = () => {
    if (fill === 0) return;
    // (any deflate is the format's, the appliers inflating what comes. Level 6, as delta-fast.c's: on 120 MB of a far
    // base's records level 8 took 6 times as long for about 5% less (2026-11-19); level 9 3 times level 8 again)
    const packed = deflateRawSync(buf.subarray(0, fill), { level: 6 }), head = Buffer.alloc(8);
    head.writeUInt32LE(fill, 0);
    head.writeUInt32LE(packed.length, 4);
    parts.push(head, packed);
    fill = 0;
  };
  const extra = (from: Uint8Array, at: number, n: number) => {
    for (let done = 0; done < n;) {
      const k = Math.min(n - done, CHUNK - fill);
      buf.set(from.subarray(at + done, at + done + k), fill);
      fill += k;
      done += k;
      if (fill === CHUNK) flush();
    }
  };
  return {
    record(x: number, y: number, z: number) {
      putI64(ctrl, 0, x);
      putI64(ctrl, 8, y);
      putI64(ctrl, 16, z);
      extra(ctrl, 0, 24);
    },
    diff(made: Uint8Array, s: number, old: Uint8Array, o: number, n: number) {
      for (let done = 0; done < n;) {
        const k = Math.min(n - done, CHUNK - fill);
        for (let i = 0; i < k; i++) buf[fill + i] = made[s + done + i]! - old[o + done + i]!;
        fill += k;
        done += k;
        if (fill === CHUNK) flush();
      }
    },
    extra,
    end() {
      flush();
      return parts;
    },
  };
}

// --- the header ---

export function encodeHeader(h: Header): Buffer {
  const parts: Buffer[] = [MAGIC];
  const u32 = (v: number) => { const b = Buffer.alloc(4); b.writeUInt32LE(v); parts.push(b); };
  const u64 = (v: number) => { const b = Buffer.alloc(8); putI64(b, 0, v); parts.push(b); };
  const ranges = (list: Range[]) => { u32(list.length); for (const r of list) { u64(r.at); u64(r.len); } };
  u32(h.files.length);
  for (const f of h.files) {
    const name = Buffer.from(f);
    if (name.length > 0xffff) throw new Error(`a path too long for a delta: ${f}`);
    const len = Buffer.alloc(2);
    len.writeUInt16LE(name.length);
    parts.push(len, name);
  }
  ranges(h.inflate);
  u64(h.oldSize);
  parts.push(Buffer.from(h.oldSha256, "hex"));
  ranges(h.deflate);
  u64(h.madeSize);
  return Buffer.concat(parts);
}

/** A sink that refuses anything but `want`, byte for byte; `done` says whether all of it came. */
function expecting(want: Uint8Array) {
  let o = 0;
  return {
    sink(b: Uint8Array) {
      if (o + b.length > want.length || Buffer.compare(b, want.subarray(o, o + b.length)) !== 0) throw new Error(`what the delta makes differs from the package at ${o}`);
      o += b.length;
    },
    done() { if (o !== want.length) throw new Error(`the delta makes ${o} bytes, the package is ${want.length}`); },
  };
}

// --- making ---

/** A folder's regular files (not symlinks, nor what is under a symlinked folder), '/'-separated, sorted bytewise. */
export function treeFiles(root: string): string[] {
  const out: string[] = [];
  const walk = (rel: string) => {
    for (const e of readdirSync(rel ? join(root, rel) : root, { withFileTypes: true })) {
      const path = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) walk(path);
      else if (e.isFile()) out.push(path);
    }
  };
  walk("");
  return out.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
}

const END = Buffer.alloc(8);

/** Below this share of the old blob found whole, the whole of it is sorted, as without `oldFiles`. */
const WHOLE_ENOUGH = 1 / 8;

/**
 * A delta's bytes; `oldFiles`, the ranges of the old blob's files, lets those found whole in `made` go unsorted.
 * `madeFile`: where `made` is on disk already, for delta-fast.c to read rather than a copy.
 */
export function makeDelta(old: Buffer, made: Buffer, files: string[], inflate: Range[], deflate: Range[], oldFiles?: Range[], madeFile?: string): Buffer {
  const head = encodeHeader({ files, inflate, oldSize: old.length, oldSha256: sha256(old), deflate, madeSize: made.length });
  const runs = sameBlocks(old, made, oldFiles ? wholeFiles(old, oldFiles, made) : []);
  const native = old.length >= PREFIXED_FROM || process.env.STILLFAIL_DELTA_FAST_FORCE === "1" ? nativeChunks(old, made, runs, madeFile) : null;
  lastMaker = native ? "native" : "js";
  if (native) return Buffer.concat([head, native, END]);
  const covered = old.length - outside(old.length, runs).m;
  const body = covered > 0 && covered >= old.length * WHOLE_ENOUGH ? bsdiff(old, made, sparseSuffixArray(old, runs), runs) : bsdiff(old, made);
  return Buffer.concat([head, ...body, END]);
}

/** Which made the last delta's chunks: delta-fast.c or this file's bsdiff (the tests see the native one was used). */
export let lastMaker: "native" | "js" | null = null;

const fastSource = fileURLToPath(new URL("./delta-fast.c", import.meta.url));
const nativeBins = new Map<string, string | null>();

/**
 * delta-fast.c compiled, once for its source (`cacheDir`/stillfail-delta-fast-<its sha256's first 16>; the system's temp
 * by default), or null: STILLFAIL_DELTA_JS=1, Windows, or no C compiler or zlib here, where this file's bsdiff makes
 * the chunks. STILLFAIL_DELTA_FAST_BIN names one compiled already (release-deltas.ts hands it its makers).
 */
export function ensureNativeDelta(cacheDir?: string): string | null {
  if (process.env.STILLFAIL_DELTA_JS === "1") return null;
  const given = process.env.STILLFAIL_DELTA_FAST_BIN;
  if (given) {
    try { accessSync(given, fsConstants.X_OK); return given; } catch { /* not there: compiled here */ }
  }
  if (process.platform === "win32" || !existsSync(fastSource)) return null;
  const dir = cacheDir ?? tmpdir();
  if (nativeBins.has(dir)) return nativeBins.get(dir)!;
  const bin = join(dir, `stillfail-delta-fast-${sha256(readFileSync(fastSource)).slice(0, 16)}`);
  let found: string | null = bin;
  if (!existsSync(bin)) {
    // (into a name of its own, then renamed: makers compiling at once each leave a whole binary)
    const tmp = `${bin}.tmp.${process.pid}`;
    const r = spawnSync("cc", ["-O3", "-std=c11", "-o", tmp, fastSource, "-lz"], { encoding: "utf8" });
    if (r.status === 0) renameSync(tmp, bin);
    else {
      rmSync(tmp, { force: true });
      console.error(`delta: delta-fast.c not compiled (${r.error?.message ?? r.stderr.trim().split("\n").at(-1)}): the deltas are made in JavaScript`);
      found = null;
    }
  }
  nativeBins.set(dir, found);
  return found;
}

/** The chunks delta-fast.c makes of `old` to `made` with `runs`, or null (no binary, or it failed: said once). */
function nativeChunks(old: Buffer, made: Buffer, runs: Run[], madeFile?: string): Buffer | null {
  const bin = ensureNativeDelta();
  if (!bin) return null;
  const dir = mkdtempSync(join(tmpdir(), "delta-fast-"));
  try {
    const runsBin = Buffer.alloc(runs.length * 12);
    runs.forEach((r, i) => { runsBin.writeUInt32LE(r.made, i * 12); runsBin.writeUInt32LE(r.old, i * 12 + 4); runsBin.writeUInt32LE(r.len, i * 12 + 8); });
    const oldPath = join(dir, "old"), runsPath = join(dir, "runs"), outPath = join(dir, "out");
    let madePath = madeFile;
    writeFileSync(oldPath, old);
    writeFileSync(runsPath, runsBin);
    if (!madePath) writeFileSync((madePath = join(dir, "made")), made);
    execFileSync(bin, [oldPath, madePath, runsPath, outPath], { stdio: ["ignore", "ignore", "pipe"] });
    return readFileSync(outPath);
  } catch (e) {
    const err = e as { stderr?: Buffer; message: string };
    if (!nativeFailed) console.error(`delta: delta-fast failed (${err.stderr?.toString().trim() || err.message}): the deltas are made in JavaScript`);
    nativeFailed = true;
    return null;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
let nativeFailed = false;

/** A delta from the folder `oldDir` to the file `newFile`, written to `out` once applying it gives that file. */
export function makeTree(oldDir: string, newFile: string, out: string): void {
  const files = treeFiles(oldDir);
  const neu = readFileSync(newFile);
  const data = files.map((f) => readFileSync(join(oldDir, f))), ranges: Range[] = [];
  for (let at = 0, i = 0; i < data.length; at += data[i]!.length, i++) ranges.push({ at, len: data[i]!.length });
  writeFileSync(out, makeDelta(Buffer.concat(data), neu, files, [], [], ranges, newFile));
  verified(out, () => {
    const d = readFileSync(out), h = parseHeader(d), want = expecting(neu);
    apply(h, readOld(h, { dir: oldDir }), d, want.sink);
    want.done();
  });
}

function verified(out: string, check: () => void) {
  try { check(); } catch (e) {
    rmSync(out, { force: true });
    throw new Error(`the delta made does not give the package: ${(e as Error).message}`);
  }
}

export type ZipEntry = { name: string; method: number; at: number; packed: number; raw: number };

/** Where a zip's end of central directory is, and what it says; zip64 is refused. */
function endRecord(zip: Buffer) {
  let e = -1;
  for (let i = zip.length - 22; i >= 0 && i >= zip.length - 22 - 0xffff; i--) {
    if (zip.readUInt32LE(i) === 0x06054b50 && i + 22 + zip.readUInt16LE(i + 20) === zip.length) { e = i; break; }
  }
  if (e < 0) throw new Error("not a zip (no end of central directory)");
  if (e >= 20 && zip.readUInt32LE(e - 20) === 0x07064b50) throw new Error("a zip64 archive (not taken)");
  const count = zip.readUInt16LE(e + 10), size = zip.readUInt32LE(e + 12), offset = zip.readUInt32LE(e + 16);
  if (count === 0xffff || size === 0xffffffff || offset === 0xffffffff) throw new Error("a zip64 archive (not taken)");
  if (offset + size > e) throw new Error("the zip's central directory is out of place");
  return { e, count, size, offset };
}

/** A zip's entries from its central directory, with where each one's data is; zip64 is refused. */
export function zipEntries(zip: Buffer): ZipEntry[] {
  const { e, count, offset } = endRecord(zip);
  const out: ZipEntry[] = [];
  for (let p = offset, i = 0; i < count; i++) {
    if (p + 46 > e || zip.readUInt32LE(p) !== 0x02014b50) throw new Error("the zip's central directory is broken");
    const method = zip.readUInt16LE(p + 10), packed = zip.readUInt32LE(p + 20), raw = zip.readUInt32LE(p + 24);
    const nameLen = zip.readUInt16LE(p + 28), local = zip.readUInt32LE(p + 42);
    if (packed === 0xffffffff || raw === 0xffffffff || local === 0xffffffff) throw new Error("a zip64 entry (not taken)");
    if (local + 30 > zip.length || zip.readUInt32LE(local) !== 0x04034b50) throw new Error("a zip entry's local header is missing");
    const at = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    if (at + packed > zip.length) throw new Error("a zip entry's data goes past the end");
    out.push({ name: zip.toString("latin1", p + 46, p + 46 + nameLen), method, at, packed, raw });
    p += 46 + nameLen + zip.readUInt16LE(p + 30) + zip.readUInt16LE(p + 32);
  }
  return out;
}

/** `zip` with each entry's data replaced by its inflated bytes, and where those bytes are in the result. */
function inflated(zip: Buffer, entries: { at: number; packed: number; data: Buffer }[]) {
  const parts: Buffer[] = [], ranges: Range[] = [];
  let p = 0, o = 0;
  for (const e of entries) {
    if (e.at < p) throw new Error("the zip's entries overlap");
    parts.push(zip.subarray(p, e.at), e.data);
    o += e.at - p;
    ranges.push({ at: o, len: e.data.length });
    o += e.data.length;
    p = e.at + e.packed;
  }
  parts.push(zip.subarray(p));
  return { blob: Buffer.concat(parts), ranges };
}

/** The entries deflated in both apks whose deflated bytes differ (the transparent ones), in each apk's order. */
export function transparent(oldZip: Buffer, newZip: Buffer) {
  const once = (list: ZipEntry[]) => {
    const seen = new Map<string, ZipEntry | null>();
    for (const e of list) seen.set(e.name, seen.has(e.name) ? null : e);
    return seen;
  };
  const olds = once(zipEntries(oldZip)), news = once(zipEntries(newZip));
  const pairs: { old: ZipEntry & { data: Buffer }; neu: ZipEntry & { data: Buffer } }[] = [];
  for (const [name, a] of olds) {
    const b = news.get(name);
    if (!a || !b || a.method !== 8 || b.method !== 8) continue;
    const pa = oldZip.subarray(a.at, a.at + a.packed), pb = newZip.subarray(b.at, b.at + b.packed);
    if (pa.equals(pb)) continue;
    let da: Buffer, db: Buffer;
    try { da = inflateRawSync(pa); db = inflateRawSync(pb); } catch { continue; }
    if (da.length !== a.raw || db.length !== b.raw) continue;
    pairs.push({ old: { ...a, data: da }, neu: { ...b, data: db } });
  }
  return {
    old: pairs.map((x) => x.old).sort((x, y) => x.at - y.at),
    neu: pairs.map((x) => x.neu).sort((x, y) => x.at - y.at),
  };
}

/** Where each entry's data of `zip` is in its old blob (`inflate`: the entries inflated in it, as a delta's header says
 * them): shifted by what the entries inflated before it grew; theirs inflated. */
export function entriesInBlob(zip: Buffer, inflate: Range[]): Range[] {
  const grown = new Set(inflate.map((r) => r.at)), out: Range[] = [];
  let shift = 0, last = -1;
  for (const e of zipEntries(zip).sort((a, b) => a.at - b.at)) {
    if (e.at === last) continue;
    last = e.at;
    const len = grown.has(e.at) ? e.raw : e.packed;
    out.push({ at: e.at + shift, len });
    shift += len - e.packed;
  }
  return out;
}

/** A delta from one apk to another, written to `out` once applying it checks (`node`: the new apk made again with
 * node's deflater; `none`: bspatch's made bytes only). Returns how many entries were transparent. */
export function makeApk(oldApk: string, newApk: string, out: string, check: "node" | "none" = "node"): number {
  const oldZip = readFileSync(oldApk), newZip = readFileSync(newApk);
  const t = transparent(oldZip, newZip);
  const old = inflated(oldZip, t.old), made = inflated(newZip, t.neu);
  const inflate = t.old.map((e) => ({ at: e.at, len: e.packed }));
  writeFileSync(out, makeDelta(old.blob, made.blob, [], inflate, made.ranges, entriesInBlob(oldZip, inflate)));
  verified(out, () => {
    const d = readFileSync(out), h = parseHeader(d), blob = readOld(h, { apk: oldApk });
    const want = expecting(check === "node" ? newZip : made.blob);
    if (check === "node") apply(h, blob, d, want.sink);
    else patch(h, blob, d, want.sink);
    want.done();
  });
  return t.old.length;
}

// --- the raw form ---

/** Whether a zip extra field (`len` bytes at `at`) carries zip64's sizes (header 0x0001). */
function zip64Extra(zip: Buffer, at: number, len: number) {
  for (let p = at; p + 4 <= at + len; p += 4 + zip.readUInt16LE(p + 2)) if (zip.readUInt16LE(p) === 0x0001) return true;
  return false;
}

/**
 * `zip` with every entry stored: what a delta makes of a zipped package, so that what changed in one file changes only
 * its bytes. The same entries in the same order (the central directory's), each with its name, times, extra fields,
 * external attributes (Unix modes, symlinks) and comment kept; method 0, the CRC and sizes in the local header and no
 * data descriptor after it (as `zip` and `ditto` write when they stream); the central directory and end record said
 * again for where things are now. What is between or before the entries is not kept. Deterministic, and an already
 * stored zip without descriptors comes back as it was. Zip64, encryption and methods other than deflate are refused.
 */
export function storedZip(zip: Buffer): Buffer {
  const { e, count, offset } = endRecord(zip);
  if (zip.readUInt16LE(e + 4) !== 0 || zip.readUInt16LE(e + 6) !== 0 || zip.readUInt16LE(e + 8) !== count) throw new Error("a zip spanning disks (not taken)");
  const parts: Buffer[] = [], central: Buffer[] = [];
  let at = 0;
  for (let p = offset, i = 0; i < count; i++) {
    if (p + 46 > e || zip.readUInt32LE(p) !== 0x02014b50) throw new Error("the zip's central directory is broken");
    const flags = zip.readUInt16LE(p + 8), method = zip.readUInt16LE(p + 10), crc = zip.readUInt32LE(p + 16);
    const packed = zip.readUInt32LE(p + 20), raw = zip.readUInt32LE(p + 24), local = zip.readUInt32LE(p + 42);
    const nameLen = zip.readUInt16LE(p + 28), extraLen = zip.readUInt16LE(p + 30), size = 46 + nameLen + extraLen + zip.readUInt16LE(p + 32);
    if (p + size > e) throw new Error("the zip's central directory is broken");
    const name = zip.toString("utf8", p + 46, p + 46 + nameLen);
    // (bit 0: encrypted; bit 6: strong encryption)
    if (flags & 0x41) throw new Error(`an encrypted zip entry (not taken): ${name}`);
    if (packed === 0xffffffff || raw === 0xffffffff || local === 0xffffffff || zip64Extra(zip, p + 46 + nameLen, extraLen)) throw new Error(`a zip64 entry (not taken): ${name}`);
    if (method !== 0 && method !== 8) throw new Error(`a zip entry packed by method ${method} (not taken): ${name}`);
    if (local + 30 > zip.length || zip.readUInt32LE(local) !== 0x04034b50) throw new Error(`a zip entry's local header is missing: ${name}`);
    const head = 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    if (local + head > zip.length || zip64Extra(zip, local + 30 + zip.readUInt16LE(local + 26), zip.readUInt16LE(local + 28))) throw new Error(`a zip64 entry (not taken): ${name}`);
    if (local + head + packed > zip.length) throw new Error(`a zip entry's data goes past the end: ${name}`);
    // The sizes are the central directory's: a local header followed by a data descriptor says none.
    const body = zip.subarray(local + head, local + head + packed);
    let data = body;
    if (method === 8) {
      try { data = inflateRawSync(body, { maxOutputLength: Math.max(1, raw) }); } catch { throw new Error(`a zip entry does not inflate: ${name}`); }
    }
    if (data.length !== raw || crc32(data) !== crc) throw new Error(`a zip entry is not the size or CRC its zip says: ${name}`);
    const lh = Buffer.from(zip.subarray(local, local + head));
    // (bit 3: a data descriptor follows; bits 1 and 2: how hard deflate tried, nothing for a stored entry)
    lh.writeUInt16LE(lh.readUInt16LE(6) & ~0x000e, 6);
    lh.writeUInt16LE(0, 8);
    lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(raw, 18);
    lh.writeUInt32LE(raw, 22);
    const ch = Buffer.from(zip.subarray(p, p + size));
    ch.writeUInt16LE(flags & ~0x000e, 8);
    ch.writeUInt16LE(0, 10);
    ch.writeUInt32LE(raw, 20);
    ch.writeUInt32LE(at, 42);
    parts.push(lh, data);
    central.push(ch);
    at += head + raw;
    if (at > 0xfffffffe) throw new Error("the zip stored would need zip64 (not taken)");
    p += size;
  }
  const cd = Buffer.concat(central), end = Buffer.from(zip.subarray(e));
  end.writeUInt32LE(cd.length, 12);
  end.writeUInt32LE(at, 16);
  return Buffer.concat([...parts, cd, end]);
}

/** A package's raw form, what a delta to it makes: a .tar.gz's tar (gunzipped), a .zip stored (storedZip). */
export function rawOf(archive: string): Buffer {
  if (/\.(tar\.gz|tgz)$/.test(archive)) return gunzipSync(readFileSync(archive));
  if (archive.endsWith(".zip")) return storedZip(readFileSync(archive));
  throw new Error(`not a package whose raw form is known (.tar.gz, .zip): ${archive}`);
}

/** The header and the chunks' sizes, as `info` prints them. */
export function info(d: Buffer) {
  const h = parseHeader(d);
  let at = h.payload!, chunks = 0, raw = 0;
  for (;;) {
    if (at + 8 > d.length) throw new Error("the delta has no end chunk");
    const r = d.readUInt32LE(at), packed = d.readUInt32LE(at + 4);
    at += 8 + packed;
    if (r === 0) break;
    chunks++;
    raw += r;
  }
  return {
    size: d.length, files: h.files, inflate: h.inflate.map((r) => ({ at: r.at, packed_len: r.len })), old_size: h.oldSize,
    old_sha256: h.oldSha256, deflate: h.deflate.map((r) => ({ at: r.at, raw_len: r.len })), made_size: h.madeSize,
    chunks, payload_bytes: d.length - h.payload!, raw_bytes: raw,
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const flag = (name: string) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : undefined; };
  const usage = (): never => {
    console.error("usage: delta.ts make --old DIR|--old-apk APK --new FILE --out DELTA [--deflate-check node|none] | apply --old DIR|--old-apk APK --delta DELTA --out FILE | info DELTA | raw ARCHIVE OUT");
    process.exit(2);
  };
  const out = flag("--out");
  try {
    const dir = flag("--old"), apk = flag("--old-apk");
    if (!dir === !apk && args[0] !== "info" && args[0] !== "raw") usage();
    const from = dir ? { dir } : { apk: apk! };
    switch (args[0]) {
      case "make": {
        const neu = flag("--new") ?? usage(), to = out ?? usage(), check = flag("--deflate-check") ?? "node";
        if (check !== "node" && check !== "none") usage();
        if (dir) makeTree(dir, neu, to);
        else console.error(`delta: ${makeApk(apk!, neu, to, check as "node" | "none")} entries inflated`);
        const i = info(readFileSync(to));
        console.error(`delta: ${to}: ${i.size} bytes (${i.chunks} chunks), makes ${i.made_size} bytes from ${i.old_size}`);
        break;
      }
      case "apply":
        applyFile(from, flag("--delta") ?? usage(), out ?? usage());
        break;
      case "info":
        console.log(JSON.stringify(info(readFileSync(args[1] ?? usage())), null, 2));
        break;
      case "raw": {
        const [archive, to] = [args[1] ?? usage(), args[2] ?? usage()];
        writeFileSync(to, rawOf(archive));
        break;
      }
      default:
        usage();
    }
  } catch (e) {
    if (out && args[0] === "make") rmSync(out, { force: true });
    console.error(`delta: ${(e as Error).message}`);
    process.exit(1);
  }
}
