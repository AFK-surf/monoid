// scripts/delta.ts's search and records in C: the suffix array (SA-IS), the 3-byte buckets and bsdiff's matching, each
// written as delta.ts writes it (read that file for the why of every step), deflating the records in 1 MiB chunks.
// delta.ts compiles it once (ensureNativeDelta) and hands it the old and made bytes and the runs it found, falling
// back to its own search where there is no C compiler or zlib.
//   delta-fast [--verify] OLD MADE RUNS OUT
//   delta-fast --files [--verify] OLD MADE FILES OUT
//   delta-fast --check-only OLD MADE CHUNKS
// RUNS: the runs found (wholeFiles, sameBlocks), in delta.ts's order (by made, but for a block sameBlocks followed back
// over a run found before it, which the search takes as delta.ts's does), 12 bytes each, little-endian
// { u32 made; u32 old; u32 len }; empty: none (the whole old blob sorted).
// FILES: the old blob's file ranges, 8 bytes each, little-endian { u32 at; u32 len } (empty: no wholeFiles, only
// sameBlocks); delta-fast computes wholeFiles and sameBlocks itself in C before sorting and searching.
// OUT: the delta's chunks { u32 raw_len; u32 packed_len; raw deflate }, without the header or the end chunk.
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define CHUNK (1 << 20)
#define PREFIXES (1 << 24)
#define PREFIXED_FROM (1 << 20)
#define WINDOW 256
#define BLOCK 256
#define HASH_MUL 0x01000193u

static void die(const char *what) {
  fprintf(stderr, "delta-fast: %s%s%s\n", what, errno ? ": " : "", errno ? strerror(errno) : "");
  exit(1);
}

static void *alloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) { errno = ENOMEM; die("out of memory"); }
  return p;
}

static void *zalloc(size_t n) {
  void *p = calloc(n ? n : 1, 1);
  if (!p) { errno = ENOMEM; die("out of memory"); }
  return p;
}

typedef struct { const uint8_t *p; size_t n; } Mapped;

static Mapped map(const char *path) {
  Mapped m = { NULL, 0 };
  int fd = open(path, O_RDONLY);
  if (fd < 0) die(path);
  struct stat st;
  if (fstat(fd, &st) != 0) die(path);
  if (st.st_size > 0x7ffffffe) { errno = EFBIG; die(path); }
  m.n = (size_t)st.st_size;
  if (m.n > 0) {
    void *p = mmap(NULL, m.n, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) die(path);
    m.p = p;
  } else {
    static const uint8_t none[1] = { 0 };
    m.p = none;
  }
  close(fd);
  return m;
}

// --- the suffix array: SA-IS, as delta.ts's sais, for bytes and for the names of its recursion ---

#define SAIS_BODY(T)                                                                                      \
  if (n == 0) return;                                                                                     \
  if (n == 1) { sa[0] = 0; return; }                                                                      \
  if (n == 2) { if (s[0] < s[1]) { sa[0] = 0; sa[1] = 1; } else { sa[0] = 1; sa[1] = 0; } return; }       \
  uint32_t *t = zalloc(((size_t)(n + 31) >> 5) * 4);                                                      \
  for (int32_t i = n - 2, next = 0; i >= 0; i--) {                                                        \
    T a = s[i], b = s[i + 1];                                                                             \
    next = a < b ? 1 : a > b ? 0 : next;                                                                  \
    if (next) t[i >> 5] |= 1u << (i & 31);                                                                \
  }                                                                                                       \
  int32_t *sumL = zalloc(((size_t)upper + 2) * 4), *sumS = zalloc(((size_t)upper + 2) * 4);               \
  for (int32_t i = 0; i < n; i++) if (!SBIT(i)) sumS[s[i]]++; else sumL[(int64_t)s[i] + 1]++;              \
  for (int32_t c = 0; c <= upper; c++) { sumS[c] += sumL[c]; if (c < upper) sumL[c + 1] += sumS[c]; }      \
  int32_t *buf = alloc(((size_t)upper + 2) * 4);                                                          \
  int32_t m = 0;                                                                                          \
  for (int32_t i = 1; i < n; i++) if (ISLMS(i)) m++;                                                      \
  int32_t *lms = alloc((size_t)m * 4);                                                                    \
  for (int32_t i = 1, k = 0; i < n; i++) if (ISLMS(i)) lms[k++] = i;                                      \
  INDUCE(lms, m);                                                                                         \
  if (m == 0) { free(t); free(sumL); free(sumS); free(buf); free(lms); return; }                          \
  int32_t *sorted = alloc((size_t)m * 4);                                                                 \
  for (int32_t i = 0, k = 0; i < n; i++) if (ISLMS(sa[i])) sorted[k++] = sa[i];                           \
  int32_t top = 0;                                                                                        \
  sa[sorted[0] >> 1] = 0;                                                                                 \
  for (int32_t i = 1; i < m; i++) {                                                                       \
    int32_t l = sorted[i - 1], r = sorted[i];                                                             \
    int same = 0;                                                                                         \
    for (int32_t d = 0;; d++) {                                                                           \
      if (l + d == n || r + d == n || s[l + d] != s[r + d]) break;                                        \
      if (d > 0) {                                                                                        \
        int el = ISLMS(l + d), er = ISLMS(r + d);                                                         \
        if (el || er) { same = el && er; break; }                                                         \
      }                                                                                                   \
    }                                                                                                     \
    if (!same) top++;                                                                                     \
    sa[r >> 1] = top;                                                                                     \
  }                                                                                                       \
  int32_t *names = alloc((size_t)m * 4);                                                                  \
  for (int32_t i = 0; i < m; i++) names[i] = sa[lms[i] >> 1];                                             \
  int32_t *order = alloc((size_t)m * 4);                                                                  \
  if (top + 1 == m) for (int32_t i = 0; i < m; i++) order[names[i]] = i;                                  \
  else sais_i32(names, m, top, order);                                                                    \
  free(names);                                                                                            \
  for (int32_t i = 0; i < m; i++) sorted[i] = lms[order[i]];                                              \
  free(order);                                                                                            \
  INDUCE(sorted, m);                                                                                      \
  free(sorted); free(t); free(sumL); free(sumS); free(buf); free(lms);

#define SBIT(i) ((t[(uint32_t)(i) >> 5] >> ((uint32_t)(i) & 31)) & 1u)
#define ISLMS(i) ((i) > 0 && SBIT(i) && !SBIT((i) - 1))
#define INDUCE(list, count)                                                                     \
  do {                                                                                          \
    for (int32_t i_ = 0; i_ < n; i_++) sa[i_] = -1;                                             \
    memcpy(buf, sumS, ((size_t)upper + 2) * 4);                                                 \
    for (int32_t i_ = 0; i_ < (count); i_++) { int32_t d_ = (list)[i_]; sa[buf[s[d_]]++] = d_; } \
    memcpy(buf, sumL, ((size_t)upper + 2) * 4);                                                 \
    sa[buf[s[n - 1]]++] = n - 1;                                                                \
    for (int32_t i_ = 0; i_ < n; i_++) {                                                        \
      int32_t v_ = sa[i_];                                                                      \
      if (v_ >= 1 && !SBIT(v_ - 1)) sa[buf[s[v_ - 1]]++] = v_ - 1;                              \
    }                                                                                           \
    memcpy(buf, sumL, ((size_t)upper + 2) * 4);                                                 \
    for (int32_t i_ = n - 1; i_ >= 0; i_--) {                                                   \
      int32_t v_ = sa[i_];                                                                      \
      if (v_ >= 1 && SBIT(v_ - 1)) sa[--buf[(int64_t)s[v_ - 1] + 1]] = v_ - 1;                  \
    }                                                                                           \
  } while (0)

static void sais_i32(const int32_t *s, int32_t n, int32_t upper, int32_t *sa) { SAIS_BODY(int32_t) }
static void sais_u8(const uint8_t *s, int32_t n, int32_t upper, int32_t *sa) { SAIS_BODY(uint8_t) }

// --- the 3-byte buckets (delta.ts's prefixStarts) ---

static int32_t *prefix_starts(const uint8_t *sorted, int32_t m) {
  int32_t *starts = zalloc(((size_t)PREFIXES + 1) * 4);
  for (int32_t r = 0; r + 2 < m; r++) starts[((sorted[r] << 16) | (sorted[r + 1] << 8) | sorted[r + 2]) + 1]++;
  if (m >= 2) starts[((sorted[m - 2] << 16) | (sorted[m - 1] << 8)) + 1]++;
  if (m >= 1) starts[(sorted[m - 1] << 16) + 1]++;
  starts[0] = 1;
  for (int32_t p = 1; p <= PREFIXES; p++) starts[p] += starts[p - 1];
  return starts;
}

// --- the runs, and what of the old blob is outside them (delta.ts's outside) ---

typedef struct { int64_t made, old, len; } Run;
typedef struct { int64_t start, end; } Span;

typedef struct { Run *data; int64_t len, cap; } RunVec;

static void runs_push(RunVec *v, Run r) {
  if (v->len == v->cap) {
    v->cap = v->cap ? v->cap * 2 : 64;
    Run *p = realloc(v->data, (size_t)v->cap * sizeof(Run));
    if (!p) { errno = ENOMEM; die("out of memory"); }
    v->data = p;
  }
  v->data[v->len++] = r;
}

static uint32_t roll_hash(const uint8_t *b, int len) {
  uint32_t h = 0;
  for (int i = 0; i < len; i++) h = h * HASH_MUL + b[i];
  return h;
}

static uint32_t hash_pow(int len) {
  uint32_t top = 1;
  for (int i = 0; i < len; i++) top *= HASH_MUL;
  return top;
}

static int is_flat(const uint8_t *b, int len) {
  uint8_t first = b[0];
  for (int i = 1; i < len; i++) if (b[i] != first) return 0;
  return 1;
}

static size_t next_pow2(size_t n) {
  size_t c = 16;
  while (c < n) c <<= 1;
  return c;
}

// --- wholeFiles and sameBlocks in C (delta.ts's wholeFiles, sameBlocks) ---

typedef struct { uint32_t at, len, hash; } FileEntry;
typedef struct { uint32_t hash, start, count; } WholeSlot;

static int by_hash_len_at(const void *a, const void *b) {
  const FileEntry *x = a, *y = b;
  if (x->hash != y->hash) return x->hash < y->hash ? -1 : 1;
  if (x->len != y->len) return x->len > y->len ? -1 : 1;
  if (x->at != y->at) return x->at < y->at ? -1 : 1;
  return 0;
}

static RunVec find_whole_files(const uint8_t *old, int64_t oldsize, const uint8_t *made, int64_t newsize, const uint8_t *files_buf, size_t files_bytes) {
  RunVec out = { NULL, 0, 0 };
  if (files_bytes % 8 != 0) { errno = 0; die("the files list is not 8-byte records"); }
  int64_t nfiles = (int64_t)(files_bytes / 8);
  if (nfiles == 0 || newsize < WINDOW) {
    for (int64_t i = 0; i < nfiles; i++) {
      const uint8_t *b = files_buf + i * 8;
      uint32_t at = (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
      uint32_t len = (uint32_t)b[4] | (uint32_t)b[5] << 8 | (uint32_t)b[6] << 16 | (uint32_t)b[7] << 24;
      if ((int64_t)at + (int64_t)len > oldsize) { errno = 0; die("a file range goes past the old blob"); }
    }
    return out;
  }
  uint32_t *bits = zalloc((size_t)(1u << 17) * sizeof(uint32_t));
  FileEntry *entries = alloc((size_t)nfiles * sizeof(FileEntry));
  size_t valid = 0;
  for (int64_t i = 0; i < nfiles; i++) {
    const uint8_t *b = files_buf + i * 8;
    uint32_t at = (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
    uint32_t len = (uint32_t)b[4] | (uint32_t)b[5] << 8 | (uint32_t)b[6] << 16 | (uint32_t)b[7] << 24;
    if ((int64_t)at + (int64_t)len > oldsize) { errno = 0; die("a file range goes past the old blob"); }
    if (len < WINDOW || is_flat(old + at, WINDOW)) continue;
    uint32_t h = roll_hash(old + at, WINDOW);
    bits[h >> 15] |= 1u << ((h >> 10) & 31);
    entries[valid++] = (FileEntry){ at, len, h };
  }
  if (valid == 0) { free(bits); free(entries); return out; }
  qsort(entries, valid, sizeof(FileEntry), by_hash_len_at);
  size_t cap = next_pow2(valid * 2);
  uint32_t mask = (uint32_t)(cap - 1);
  WholeSlot *table = zalloc(cap * sizeof(WholeSlot));
  for (size_t i = 0; i < valid; ) {
    uint32_t h = entries[i].hash;
    size_t start = i;
    while (i < valid && entries[i].hash == h) i++;
    uint32_t idx = (h ^ (h >> 16)) & mask;
    while (table[idx].count != 0) idx = (idx + 1) & mask;
    table[idx] = (WholeSlot){ h, (uint32_t)start, (uint32_t)(i - start) };
  }
  uint32_t top = hash_pow(WINDOW);
  int64_t p = 0;
  uint32_t h = roll_hash(made, WINDOW);
  for (;;) {
    const FileEntry *found = NULL;
    if (bits[h >> 15] & (1u << ((h >> 10) & 31))) {
      uint32_t idx = (h ^ (h >> 16)) & mask;
      while (table[idx].count != 0) {
        if (table[idx].hash == h) {
          uint32_t start = table[idx].start, end = start + table[idx].count;
          for (uint32_t j = start; j < end; j++) {
            uint32_t fat = entries[j].at, flen = entries[j].len;
            if (p + (int64_t)flen <= newsize && memcmp(old + fat, made + p, flen) == 0) { found = &entries[j]; break; }
          }
          break;
        }
        idx = (idx + 1) & mask;
      }
    }
    if (found) {
      runs_push(&out, (Run){ p, (int64_t)found->at, (int64_t)found->len });
      p += (int64_t)found->len;
      if (p + WINDOW > newsize) break;
      h = roll_hash(made + p, WINDOW);
    } else {
      if (p + WINDOW >= newsize) break;
      h = h * HASH_MUL - (uint32_t)made[p] * top + (uint32_t)made[p + WINDOW];
      p++;
    }
  }
  free(bits);
  free(entries);
  free(table);
  return out;
}

typedef struct { uint32_t hash, off_plus_1; } BlockSlot;

static void look_gap(const uint8_t *old, int64_t oldsize, const uint8_t *made, int64_t from, int64_t to,
                     const uint32_t *bits, const BlockSlot *table, uint32_t mask, uint32_t top, RunVec *out) {
  int64_t p = from;
  if (to - p < BLOCK) return;
  uint32_t h = roll_hash(made + p, BLOCK);
  for (;;) {
    int64_t o = -1;
    if (bits[h >> 15] & (1u << ((h >> 10) & 31))) {
      uint32_t idx = (h ^ (h >> 16)) & mask;
      while (table[idx].off_plus_1 != 0) {
        if (table[idx].hash == h) { o = (int64_t)(table[idx].off_plus_1 - 1u); break; }
        idx = (idx + 1) & mask;
      }
    }
    if (o >= 0 && memcmp(old + o, made + p, BLOCK) == 0) {
      int64_t back = 0;
      int64_t most = (p - from) < o ? (p - from) : o;
      while (back < most && made[p - back - 1] == old[o - back - 1]) back++;
      int64_t len = BLOCK;
      int64_t ahead = (to - p) < (oldsize - o) ? (to - p) : (oldsize - o);
      while (len < ahead && made[p + len] == old[o + len]) len++;
      runs_push(out, (Run){ p - back, o - back, back + len });
      p += len;
      if (p + BLOCK > to) return;
      h = roll_hash(made + p, BLOCK);
    } else {
      if (p + BLOCK >= to) return;
      h = h * HASH_MUL - (uint32_t)made[p] * top + (uint32_t)made[p + BLOCK];
      p++;
    }
  }
}

static RunVec find_same_blocks(const uint8_t *old, int64_t oldsize, const uint8_t *made, int64_t newsize, const Run *wf, int64_t nwf) {
  RunVec out = { NULL, 0, 0 };
  if (newsize < BLOCK || oldsize < BLOCK) {
    for (int64_t i = 0; i < nwf; i++) runs_push(&out, wf[i]);
    return out;
  }
  uint32_t *bits = zalloc((size_t)(1u << 17) * sizeof(uint32_t));
  size_t nblocks = (size_t)(oldsize / BLOCK);
  size_t cap = next_pow2(nblocks * 2);
  uint32_t mask = (uint32_t)(cap - 1);
  BlockSlot *table = zalloc(cap * sizeof(BlockSlot));
  for (int64_t at = 0; at + BLOCK <= oldsize; at += BLOCK) {
    if (is_flat(old + at, BLOCK)) continue;
    uint32_t h = roll_hash(old + at, BLOCK);
    uint32_t idx = (h ^ (h >> 16)) & mask;
    int exists = 0;
    while (table[idx].off_plus_1 != 0) {
      if (table[idx].hash == h) { exists = 1; break; }
      idx = (idx + 1) & mask;
    }
    if (!exists) {
      table[idx].hash = h;
      table[idx].off_plus_1 = (uint32_t)at + 1u;
      bits[h >> 15] |= 1u << ((h >> 10) & 31);
    }
  }
  uint32_t top = hash_pow(BLOCK);
  int64_t at = 0;
  for (int64_t i = 0; i < nwf; i++) {
    look_gap(old, oldsize, made, at, wf[i].made, bits, table, mask, top, &out);
    runs_push(&out, wf[i]);
    at = wf[i].made + wf[i].len;
  }
  look_gap(old, oldsize, made, at, newsize, bits, table, mask, top, &out);
  free(bits);
  free(table);
  return out;
}

static int by_start(const void *a, const void *b) {
  const Span *x = a, *y = b;
  if (x->start != y->start) return x->start < y->start ? -1 : 1;
  if (x->end != y->end) return x->end < y->end ? -1 : 1;
  return 0;
}

// --- the chunks out ---

typedef struct {
  FILE *out;
  uint8_t *buf, *packed;
  size_t fill, bound;
  z_stream zs;
} Chunker;

static void put_u32(uint8_t *b, uint32_t v) { b[0] = v; b[1] = v >> 8; b[2] = v >> 16; b[3] = v >> 24; }

static void flush(Chunker *c) {
  if (c->fill == 0) return;
  if (deflateReset(&c->zs) != Z_OK) die("deflateReset");
  c->zs.next_in = c->buf;
  c->zs.avail_in = (uInt)c->fill;
  c->zs.next_out = c->packed;
  c->zs.avail_out = (uInt)c->bound;
  if (deflate(&c->zs, Z_FINISH) != Z_STREAM_END) die("deflate did not finish a chunk");
  size_t packed = c->bound - c->zs.avail_out;
  uint8_t head[8];
  put_u32(head, (uint32_t)c->fill);
  put_u32(head + 4, (uint32_t)packed);
  if (fwrite(head, 1, 8, c->out) != 8 || fwrite(c->packed, 1, packed, c->out) != packed) die("writing the chunks");
  c->fill = 0;
}

static void extra(Chunker *c, const uint8_t *from, int64_t n) {
  while (n > 0) {
    size_t k = CHUNK - c->fill;
    if ((int64_t)k > n) k = (size_t)n;
    memcpy(c->buf + c->fill, from, k);
    c->fill += k;
    from += k;
    n -= (int64_t)k;
    if (c->fill == CHUNK) flush(c);
  }
}

static void diff(Chunker *c, const uint8_t *made, const uint8_t *old, int64_t n) {
  while (n > 0) {
    size_t k = CHUNK - c->fill;
    if ((int64_t)k > n) k = (size_t)n;
    uint8_t *to = c->buf + c->fill;
    for (size_t i = 0; i < k; i++) to[i] = (uint8_t)(made[i] - old[i]);
    c->fill += k;
    made += k;
    old += k;
    n -= (int64_t)k;
    if (c->fill == CHUNK) flush(c);
  }
}

static void record(Chunker *c, int64_t x, int64_t y, int64_t z) {
  uint8_t b[24];
  int64_t v[3] = { x, y, z };
  for (int j = 0; j < 3; j++) {
    uint64_t u = (uint64_t)v[j];
    for (int i = 0; i < 8; i++) b[j * 8 + i] = (uint8_t)(u >> (8 * i));
  }
  extra(c, b, 24);
}

// --- bsdiff (delta.ts's bsdiff) ---

typedef struct {
  const uint8_t *old, *made;
  int64_t oldsize, newsize;
  const int32_t *I;
  int64_t In;
  const int32_t *starts;
  const Run *known;
  int64_t nknown, k;
} Search;

static int64_t matchlen(const Search *S, int64_t o, int64_t s) {
  int64_t n = S->oldsize - o < S->newsize - s ? S->oldsize - o : S->newsize - s, i = 0;
  const uint8_t *a = S->old + o, *b = S->made + s;
  while (i + 8 <= n) {
    uint64_t x, y;
    memcpy(&x, a + i, 8);
    memcpy(&y, b + i, 8);
    if (x != y) break;
    i += 8;
  }
  while (i < n && a[i] == b[i]) i++;
  return i;
}

static uint64_t be64(const uint8_t *p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v = v << 8 | p[i];
  return v;
}

// (the first 8 bytes compared here: most searches end in them, and a call to memcmp for each step was half of the
// whole search's time)
static int below(const Search *S, int64_t o, int64_t s) {
  int64_t n = S->oldsize - o < S->newsize - s ? S->oldsize - o : S->newsize - s;
  if (n >= 8) {
    uint64_t x = be64(S->old + o), y = be64(S->made + s);
    if (x != y) return x < y;
  }
  return n > 0 && memcmp(S->old + o, S->made + s, (size_t)n) < 0;
}

static int64_t search(Search *S, int64_t scan, int64_t *pos) {
  while (S->k < S->nknown && S->known[S->k].made + S->known[S->k].len <= scan) S->k++;
  if (S->k < S->nknown && S->known[S->k].made <= scan) {
    const Run *run = &S->known[S->k];
    *pos = run->old + (scan - run->made);
    int64_t n = run->made + run->len - scan;
    return n + matchlen(S, *pos + n, scan + n);
  }
  int64_t st = 0, en = S->In - 1;
  if (S->starts && scan + 3 <= S->newsize) {
    int32_t p = (S->made[scan] << 16) | (S->made[scan + 1] << 8) | S->made[scan + 2];
    st = (int64_t)S->starts[p] - 1;
    en = S->starts[p + 1] < S->In - 1 ? S->starts[p + 1] : S->In - 1;
  }
  while (en - st >= 2) {
    int64_t x = st + ((en - st) >> 1);
#if defined(__GNUC__)
    // (either half's middle asked for while this one is compared: each step is a miss of the cache)
    __builtin_prefetch(&S->I[st + ((x - st) >> 1)]);
    __builtin_prefetch(&S->I[x + ((en - x) >> 1)]);
#endif
    if (below(S, S->I[x], scan)) st = x; else en = x;
  }
  int64_t x = matchlen(S, S->I[st], scan), y = matchlen(S, S->I[en], scan);
  if (x > y) { *pos = S->I[st]; return x; }
  *pos = S->I[en];
  return y;
}

static void bsdiff(Search *S, Chunker *out) {
  const uint8_t *old = S->old, *made = S->made;
  int64_t oldsize = S->oldsize, newsize = S->newsize;
#define AT(i) ((i) >= 0 && (i) < oldsize ? (int)old[i] : -1)
  int64_t scan = 0, len = 0, pos = 0, lastscan = 0, lastpos = 0, lastoffset = 0;
  while (scan < newsize) {
    int64_t oldscore = 0, scsc = (scan += len);
    for (; scan < newsize; scan++) {
      len = search(S, scan, &pos);
      for (; scsc < scan + len; scsc++) if (AT(scsc + lastoffset) == made[scsc]) oldscore++;
      if ((len == oldscore && len != 0) || len > oldscore + 8) break;
      if (AT(scan + lastoffset) == made[scan]) oldscore--;
    }
    if (len == oldscore && scan != newsize) continue;
    int64_t s = 0, Sf = 0, lenf = 0;
    for (int64_t i = 0; lastscan + i < scan && lastpos + i < oldsize;) {
      if (old[lastpos + i] == made[lastscan + i]) s++;
      i++;
      if (s * 2 - i > Sf * 2 - lenf) { Sf = s; lenf = i; }
    }
    int64_t lenb = 0;
    if (scan < newsize) {
      int64_t Sb = 0;
      s = 0;
      for (int64_t i = 1; scan >= lastscan + i && pos >= i; i++) {
        if (old[pos - i] == made[scan - i]) s++;
        if (s * 2 - i > Sb * 2 - lenb) { Sb = s; lenb = i; }
      }
    }
    if (lastscan + lenf > scan - lenb) {
      int64_t overlap = lastscan + lenf - (scan - lenb), Ss = 0, lens = 0;
      s = 0;
      for (int64_t i = 0; i < overlap; i++) {
        if (made[lastscan + lenf - overlap + i] == old[lastpos + lenf - overlap + i]) s++;
        if (made[scan - lenb + i] == old[pos - lenb + i]) s--;
        if (s > Ss) { Ss = s; lens = i + 1; }
      }
      lenf += lens - overlap;
      lenb -= lens;
    }
    int64_t y = scan - lenb - (lastscan + lenf);
    record(out, lenf, y, pos - lenb - (lastpos + lenf));
    diff(out, made + lastscan, old + lastpos, lenf);
    extra(out, made + lastscan + lenf, y);
    lastscan = scan - lenb;
    lastpos = pos - lenb;
    lastoffset = pos - scan;
  }
#undef AT
}

// --- verifying chunks (equivalent to station/src/updates/delta.ts patch()) ---

static uint32_t get_u32(const uint8_t *b) {
  return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}

static void verify_fail(const char *unlink_path, const char *what) {
  if (unlink_path) unlink(unlink_path);
  errno = 0;
  die(what);
}

static void verify_fail_at(const char *unlink_path, const char *what, int64_t offset) {
  if (unlink_path) unlink(unlink_path);
  fprintf(stderr, "delta-fast: %s at %lld\n", what, (long long)offset);
  exit(1);
}

typedef struct {
  const uint8_t *data;
  size_t total, at;
  uint8_t *buf;
  size_t buf_len, pos;
  z_stream is;
  const char *unlink_path;
} VerifyReader;

static int vr_next_chunk(VerifyReader *vr) {
  if (vr->at == vr->total) return 0;
  if (vr->total - vr->at < 8) verify_fail(vr->unlink_path, "a chunk header is cut short");
  uint32_t raw_len = get_u32(vr->data + vr->at);
  uint32_t packed_len = get_u32(vr->data + vr->at + 4);
  vr->at += 8;
  if (raw_len == 0 || raw_len > CHUNK) verify_fail(vr->unlink_path, "invalid chunk raw_len");
  if ((size_t)packed_len > vr->total - vr->at) verify_fail(vr->unlink_path, "a chunk is cut short");
  if (inflateReset(&vr->is) != Z_OK) verify_fail(vr->unlink_path, "inflateReset");
  vr->is.next_in = (Bytef *)(vr->data + vr->at);
  vr->is.avail_in = (uInt)packed_len;
  vr->is.next_out = vr->buf;
  vr->is.avail_out = (uInt)raw_len;
  int zr = inflate(&vr->is, Z_FINISH);
  if (zr != Z_STREAM_END || vr->is.avail_in != 0 || vr->is.avail_out != 0) {
    verify_fail(vr->unlink_path, "a chunk does not inflate to its raw_len");
  }
  vr->at += packed_len;
  vr->buf_len = raw_len;
  vr->pos = 0;
  return 1;
}

static size_t vr_take(VerifyReader *vr, size_t max) {
  while (vr->pos == vr->buf_len) {
    if (!vr_next_chunk(vr)) verify_fail(vr->unlink_path, "the delta's stream ends early");
  }
  size_t avail = vr->buf_len - vr->pos;
  return max < avail ? max : avail;
}

static int64_t read_i64_checked(const uint8_t *b, const char *unlink_path) {
  uint32_t lo = get_u32(b);
  uint32_t hi_u = get_u32(b + 4);
  int32_t hi = (int32_t)hi_u;
  if (hi > 0x1fffff || hi < -0x200000) verify_fail(unlink_path, "a record's number is too large");
  return (int64_t)(((uint64_t)hi_u << 32) | (uint64_t)lo);
}

static void verify_chunks(const uint8_t *old, int64_t oldsize, const uint8_t *made, int64_t newsize,
                          const char *chunks_path, int unlink_on_fail) {
  const char *unlink_path = unlink_on_fail ? chunks_path : NULL;
  int fd = open(chunks_path, O_RDONLY);
  if (fd < 0) {
    int saved = errno;
    if (unlink_path) unlink(unlink_path);
    errno = saved;
    die(chunks_path);
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    int saved = errno;
    close(fd);
    if (unlink_path) unlink(unlink_path);
    errno = saved;
    die(chunks_path);
  }
  if (st.st_size > 0x7ffffffe) {
    close(fd);
    if (unlink_path) unlink(unlink_path);
    errno = EFBIG;
    die(chunks_path);
  }
  size_t total = (size_t)st.st_size;
  static const uint8_t none[1] = { 0 };
  const uint8_t *data = none;
  if (total > 0) {
    void *mp = mmap(NULL, total, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mp == MAP_FAILED) {
      int saved = errno;
      close(fd);
      if (unlink_path) unlink(unlink_path);
      errno = saved;
      die(chunks_path);
    }
    data = mp;
  }
  close(fd);

  VerifyReader vr = { 0 };
  vr.data = data;
  vr.total = total;
  vr.buf = alloc(CHUNK);
  vr.unlink_path = unlink_path;
  if (inflateInit2(&vr.is, -15) != Z_OK) verify_fail(unlink_path, "inflateInit2");

  int64_t o = 0, p = 0;
  uint8_t ctrl[24];
  while (o < newsize) {
    for (size_t got = 0; got < 24;) {
      size_t k = vr_take(&vr, 24 - got);
      memcpy(ctrl + got, vr.buf + vr.pos, k);
      vr.pos += k;
      got += k;
    }
    int64_t x = read_i64_checked(ctrl, unlink_path);
    int64_t y = read_i64_checked(ctrl + 8, unlink_path);
    int64_t z = read_i64_checked(ctrl + 16, unlink_path);
    if (x < 0 || y < 0) verify_fail(unlink_path, "a record with a negative length");
    if (x > newsize - o || y > newsize - o - x) verify_fail(unlink_path, "a record goes past made_size");
    for (int64_t left = x; left > 0;) {
      size_t want = left < CHUNK ? (size_t)left : CHUNK;
      size_t k = vr_take(&vr, want);
      const uint8_t *b = vr.buf + vr.pos;
      if (p >= 0 && (int64_t)k <= oldsize && p <= oldsize - (int64_t)k) {
        for (size_t i = 0; i < k; i++) {
          if ((uint8_t)(b[i] + old[p + (int64_t)i]) != made[o + (int64_t)i]) {
            verify_fail_at(unlink_path, "what the delta makes differs from the package", o + (int64_t)i);
          }
        }
      } else {
        for (size_t i = 0; i < k; i++) {
          uint8_t ob = (p <= oldsize - 1 - (int64_t)i && p + (int64_t)i >= 0) ? old[p + (int64_t)i] : 0;
          if ((uint8_t)(b[i] + ob) != made[o + (int64_t)i]) {
            verify_fail_at(unlink_path, "what the delta makes differs from the package", o + (int64_t)i);
          }
        }
      }
      if (p > INT64_MAX - (int64_t)k) verify_fail(unlink_path, "old offset overflow");
      vr.pos += k;
      p += (int64_t)k;
      o += (int64_t)k;
      left -= (int64_t)k;
    }
    for (int64_t left = y; left > 0;) {
      size_t want = left < CHUNK ? (size_t)left : CHUNK;
      size_t k = vr_take(&vr, want);
      if (memcmp(vr.buf + vr.pos, made + o, k) != 0) {
        verify_fail_at(unlink_path, "what the delta makes differs from the package", o);
      }
      vr.pos += k;
      o += (int64_t)k;
      left -= (int64_t)k;
    }
    if ((z > 0 && p > INT64_MAX - z) || (z < 0 && p < INT64_MIN - z)) {
      verify_fail(unlink_path, "old offset overflow");
    }
    p += z;
  }
  if (vr.pos != vr.buf_len || vr.at != vr.total) {
    verify_fail(unlink_path, "the delta's stream goes on past made_size");
  }
  inflateEnd(&vr.is);
  free(vr.buf);
  if (total > 0) munmap((void *)data, total);
}

int main(int argc, char **argv) {
  int files_mode = 0, verify_mode = 0, check_only = 0;
  int argi = 1;
  while (argi < argc && argv[argi][0] == '-') {
    if (strcmp(argv[argi], "--files") == 0) files_mode = 1;
    else if (strcmp(argv[argi], "--verify") == 0) verify_mode = 1;
    else if (strcmp(argv[argi], "--check-only") == 0) check_only = 1;
    else break;
    argi++;
  }
  int rest = argc - argi;
  if (check_only) {
    if (files_mode || verify_mode || rest != 3) {
      fprintf(stderr, "usage: delta-fast [--verify] OLD MADE RUNS OUT | delta-fast --files [--verify] OLD MADE FILES OUT | delta-fast --check-only OLD MADE CHUNKS\n");
      return 2;
    }
    errno = 0;
    Mapped old = map(argv[argi]), made = map(argv[argi + 1]);
    verify_chunks(old.p, (int64_t)old.n, made.p, (int64_t)made.n, argv[argi + 2], 0);
    return 0;
  }
  if (rest != 4) {
    fprintf(stderr, "usage: delta-fast [--verify] OLD MADE RUNS OUT | delta-fast --files [--verify] OLD MADE FILES OUT | delta-fast --check-only OLD MADE CHUNKS\n");
    return 2;
  }
  errno = 0;
  const char *old_path = argv[argi];
  const char *made_path = argv[argi + 1];
  const char *third_path = argv[argi + 2];
  const char *out_path = argv[argi + 3];
  Mapped old = map(old_path), made = map(made_path), third = map(third_path);
  int64_t oldsize = (int64_t)old.n;
  Run *runs = NULL;
  int64_t nruns = 0;
  if (files_mode) {
    RunVec wf = find_whole_files(old.p, oldsize, made.p, (int64_t)made.n, third.p, third.n);
    RunVec sb = find_same_blocks(old.p, oldsize, made.p, (int64_t)made.n, wf.data, wf.len);
    free(wf.data);
    runs = sb.data;
    nruns = sb.len;
  } else {
    if (third.n % 12 != 0) { errno = 0; die("the runs file is not 12-byte records"); }
    nruns = (int64_t)(third.n / 12);
    runs = alloc((size_t)nruns * sizeof(Run));
    for (int64_t i = 0; i < nruns; i++) {
      const uint8_t *b = third.p + i * 12;
      uint32_t v[3];
      for (int j = 0; j < 3; j++) v[j] = (uint32_t)b[j * 4] | (uint32_t)b[j * 4 + 1] << 8 | (uint32_t)b[j * 4 + 2] << 16 | (uint32_t)b[j * 4 + 3] << 24;
      runs[i] = (Run){ v[0], v[1], v[2] };
      if (runs[i].old + runs[i].len > oldsize || runs[i].made + runs[i].len > (int64_t)made.n ||
          memcmp(old.p + runs[i].old, made.p + runs[i].made, (size_t)runs[i].len) != 0) {
        errno = 0;
        die("a run is out of place or not the old bytes it says");
      }
    }
  }

  // what of the old blob is outside the runs, and whether that is sorted alone (delta.ts's makeDelta, WHOLE_ENOUGH)
  Span *taken = alloc((size_t)(nruns + 1) * sizeof(Span));
  for (int64_t i = 0; i < nruns; i++) taken[i] = (Span){ runs[i].old, runs[i].old + runs[i].len };
  qsort(taken, (size_t)nruns, sizeof(Span), by_start);
  taken[nruns] = (Span){ oldsize, oldsize };
  int64_t o = 0, m = 0;
  for (int64_t i = 0; i <= nruns; i++) {
    if (taken[i].start > o) m += taken[i].start - o;
    if (taken[i].end > o) o = taken[i].end;
  }
  int64_t covered = oldsize - m;
  int sparse = covered > 0 && covered * 8 >= oldsize;

  int32_t *I, *starts = NULL;
  int64_t In;
  if (sparse) {
    uint8_t *reduced = alloc((size_t)m);
    int32_t *at = alloc((size_t)m * 4);
    int64_t r = 0;
    o = 0;
    for (int64_t i = 0; i <= nruns; i++) {
      if (taken[i].start > o) {
        memcpy(reduced + r, old.p + o, (size_t)(taken[i].start - o));
        for (int64_t j = o; j < taken[i].start; j++) at[r++] = (int32_t)j;
      }
      if (taken[i].end > o) o = taken[i].end;
    }
    In = m + 1;
    I = alloc((size_t)In * 4);
    I[0] = (int32_t)oldsize;
    sais_u8(reduced, (int32_t)m, 255, I + 1);
    for (int64_t i = 1; i <= m; i++) I[i] = at[I[i]];
    free(at);
    if (m >= PREFIXED_FROM) starts = prefix_starts(reduced, (int32_t)m);
    free(reduced);
  } else {
    In = oldsize + 1;
    I = alloc((size_t)In * 4);
    I[0] = (int32_t)oldsize;
    sais_u8(old.p, (int32_t)oldsize, 255, I + 1);
    if (oldsize >= PREFIXED_FROM) starts = prefix_starts(old.p, (int32_t)oldsize);
  }
  free(taken);

  Chunker c = { 0 };
  c.out = fopen(out_path, "wb");
  if (!c.out) die(out_path);
  if (deflateInit2(&c.zs, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) { errno = 0; die("deflateInit2"); }
  c.bound = deflateBound(&c.zs, CHUNK);
  c.buf = alloc(CHUNK);
  c.packed = alloc(c.bound);

  // (the whole old blob sorted: searched without the runs, as delta.ts's bsdiff(old, made))
  Search S = { old.p, made.p, oldsize, (int64_t)made.n, I, In, starts, runs, sparse ? nruns : 0, 0 };
  bsdiff(&S, &c);
  flush(&c);
  deflateEnd(&c.zs);
  if (fflush(c.out) != 0 || fclose(c.out) != 0) die("writing the chunks");
  free(c.buf);
  free(c.packed);
  free(I);
  free(starts);
  free(runs);
  if (verify_mode) verify_chunks(old.p, oldsize, made.p, (int64_t)made.n, out_path, 1);
  return 0;
}
