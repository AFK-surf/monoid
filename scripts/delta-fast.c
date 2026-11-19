// scripts/delta.ts's search and records in C: the suffix array (SA-IS), the 3-byte buckets and bsdiff's matching, each
// written as delta.ts writes it (read that file for the why of every step), deflating the records in 1 MiB chunks.
// delta.ts compiles it once (ensureNativeDelta) and hands it the old and made bytes and the runs it found, falling
// back to its own search where there is no C compiler or zlib.
//   delta-fast OLD MADE RUNS OUT
// RUNS: the runs found (wholeFiles, sameBlocks), in delta.ts's order (by made, but for a block sameBlocks followed back
// over a run found before it, which the search takes as delta.ts's does), 12 bytes each, little-endian
// { u32 made; u32 old; u32 len }; empty: none (the whole old blob sorted). OUT: the delta's chunks
// { u32 raw_len; u32 packed_len; raw deflate }, without the header or the end chunk.
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

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: delta-fast OLD MADE RUNS OUT\n");
    return 2;
  }
  errno = 0;
  Mapped old = map(argv[1]), made = map(argv[2]), rf = map(argv[3]);
  if (rf.n % 12 != 0) { errno = 0; die("the runs file is not 12-byte records"); }
  int64_t nruns = (int64_t)(rf.n / 12);
  Run *runs = alloc((size_t)nruns * sizeof(Run));
  for (int64_t i = 0; i < nruns; i++) {
    const uint8_t *b = rf.p + i * 12;
    uint32_t v[3];
    for (int j = 0; j < 3; j++) v[j] = (uint32_t)b[j * 4] | (uint32_t)b[j * 4 + 1] << 8 | (uint32_t)b[j * 4 + 2] << 16 | (uint32_t)b[j * 4 + 3] << 24;
    runs[i] = (Run){ v[0], v[1], v[2] };
    if (runs[i].old + runs[i].len > (int64_t)old.n || runs[i].made + runs[i].len > (int64_t)made.n ||
        memcmp(old.p + runs[i].old, made.p + runs[i].made, (size_t)runs[i].len) != 0) {
      errno = 0;
      die("a run is out of place or not the old bytes it says");
    }
  }
  int64_t oldsize = (int64_t)old.n;

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
  c.out = fopen(argv[4], "wb");
  if (!c.out) die(argv[4]);
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
  return 0;
}
