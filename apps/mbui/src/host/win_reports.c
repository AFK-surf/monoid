// still.fail's own host's side of src/stillfail/reports.mbt on Windows (src/stillfail/win_engine.c includes it after
// src/sfcore/win_engine.c / src/host/win_core.c): the window thread's hangs (`ui_hang`, `ui_hang_summary`) and handled
// errors (`CoreFailed`, `UiFault`) sent to still.fail's PostHog project via `/batch/` on a background thread.
//
// A build without PostHog's key (RCDATA "MBUI_ENV" `STILLFAIL_POSTHOG_KEY`, written by scripts/win.sh for still.fail's
// own stable and beta apps alone) sends nothing and answers `hello` 0 and `reporting` -1. When the person turns
// 「发送使用统计和错误报告」 off (persisted in `<app_data_dir>/reports.json` beside `core/`), events are dropped.
//
// Pure C (-W4 -WX) with Windows system libraries only (winhttp.lib, advapi32.lib, bcrypt.lib; zero VCRUNTIME/MSVCP
// dependency). Define SF_REPORTS_PURE to compile only the pure JSON/UUID/timestamp logic for unit tests.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ── compact dynamic string buffer & RFC 8259 JSON encoding (pure C) ──

typedef struct {
  char *data;
  size_t len;
  size_t cap;
  int oom;
} sf_buf;

static void sf_buf_init(sf_buf *b, size_t initial_cap) {
  b->len = 0;
  b->cap = initial_cap > 0 ? initial_cap : 64;
  b->oom = 0;
  b->data = (char *)malloc(b->cap);
  if (!b->data) {
    b->cap = 0;
    b->oom = 1;
  } else {
    b->data[0] = '\0';
  }
}

static int sf_buf_reserve(sf_buf *b, size_t extra) {
  if (b->oom) return 0;
  if (extra > SIZE_MAX - b->len - 1) {
    b->oom = 1;
    return 0;
  }
  size_t need = b->len + extra + 1;
  if (need <= b->cap) return 1;
  size_t ncap = b->cap ? b->cap : 64;
  while (ncap < need) {
    if (ncap > SIZE_MAX / 2) {
      ncap = need;
      break;
    }
    ncap *= 2;
  }
  char *p = (char *)realloc(b->data, ncap);
  if (!p) {
    b->oom = 1;
    return 0;
  }
  b->data = p;
  b->cap = ncap;
  return 1;
}

static void sf_buf_put_bytes(sf_buf *b, const char *s, size_t n) {
  if (n == 0 || !sf_buf_reserve(b, n)) return;
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = '\0';
}

static void sf_buf_put_str(sf_buf *b, const char *s) {
  if (s) sf_buf_put_bytes(b, s, strlen(s));
}

static void sf_buf_put_char(sf_buf *b, char c) {
  if (!sf_buf_reserve(b, 1)) return;
  b->data[b->len++] = c;
  b->data[b->len] = '\0';
}

static void sf_buf_put_json_str_n(sf_buf *b, const char *s, size_t n) {
  sf_buf_put_char(b, '"');
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)s[i];
    switch (c) {
      case '"': sf_buf_put_bytes(b, "\\\"", 2); break;
      case '\\': sf_buf_put_bytes(b, "\\\\", 2); break;
      case '\b': sf_buf_put_bytes(b, "\\b", 2); break;
      case '\f': sf_buf_put_bytes(b, "\\f", 2); break;
      case '\n': sf_buf_put_bytes(b, "\\n", 2); break;
      case '\r': sf_buf_put_bytes(b, "\\r", 2); break;
      case '\t': sf_buf_put_bytes(b, "\\t", 2); break;
      default:
        if (c < 0x20u) {
          char esc[7];
          snprintf(esc, sizeof esc, "\\u00%02x", (unsigned)c);
          sf_buf_put_bytes(b, esc, 6);
        } else {
          sf_buf_put_char(b, (char)c);
        }
        break;
    }
  }
  sf_buf_put_char(b, '"');
}

static void sf_buf_put_json_str(sf_buf *b, const char *s) {
  if (!s) s = "";
  sf_buf_put_json_str_n(b, s, strlen(s));
}

static char *sf_buf_take(sf_buf *b) {
  if (b->oom) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    return NULL;
  }
  char *out = b->data;
  b->data = NULL;
  b->len = 0;
  b->cap = 0;
  return out;
}

// ── pure helpers: UTF-8 truncation, UUID v4, ISO-8601 UTC, JSON object slicing ──

static size_t sf_utf8_trunc_len(const char *s, size_t max_bytes) {
  if (!s) return 0;
  size_t n = strlen(s);
  if (n <= max_bytes) return n;
  size_t end = max_bytes;
  // Back up over UTF-8 continuation bytes (10xxxxxx) so we never split a multi-byte sequence.
  while (end > 0 && (((unsigned char)s[end] & 0xC0u) == 0x80u)) end--;
  return end;
}

static int sf_is_ws(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

// Extracts the trimmed inner content of a JSON object `{ ... }`. Returns 1 if `json` is `{...}`, else 0.
static int sf_json_object_inner(const char *json, const char **inner_start, size_t *inner_len) {
  if (!json) return 0;
  const char *p = json;
  while (*p && sf_is_ws(*p)) p++;
  if (*p != '{') return 0;
  const char *end = p + strlen(p);
  while (end > p && sf_is_ws(end[-1])) end--;
  if (end - p < 2 || end[-1] != '}') return 0;
  const char *s = p + 1;
  const char *e = end - 1;
  while (s < e && sf_is_ws(*s)) s++;
  while (e > s && sf_is_ws(e[-1])) e--;
  *inner_start = s;
  *inner_len = (size_t)(e - s);
  return 1;
}

static void sf_win_format_uuid(const uint8_t bytes16[16], char out37[37]) {
  uint8_t b[16];
  memcpy(b, bytes16, 16);
  b[6] = (uint8_t)((b[6] & 0x0Fu) | 0x40u);
  b[8] = (uint8_t)((b[8] & 0x3Fu) | 0x80u);
  snprintf(out37, 37,
           "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
           (unsigned)b[0], (unsigned)b[1], (unsigned)b[2], (unsigned)b[3],
           (unsigned)b[4], (unsigned)b[5], (unsigned)b[6], (unsigned)b[7],
           (unsigned)b[8], (unsigned)b[9], (unsigned)b[10], (unsigned)b[11],
           (unsigned)b[12], (unsigned)b[13], (unsigned)b[14], (unsigned)b[15]);
}

static void sf_win_format_iso_utc(int year, int month, int day, int hour, int min, int sec, int ms, char out25[25]) {
  snprintf(out25, 25, "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, day, hour, min, sec, ms);
}

// ── PostHog /batch/ payload builders (pure C) ──

static char *sf_win_build_batch_exception(
    const char *api_key,
    const char *distinct_id,
    const char *uuid,
    const char *timestamp_iso,
    const char *type,
    const char *value,
    const char *reason,
    const char *here_json) {
  if (!api_key || !*api_key || !distinct_id || !uuid || !timestamp_iso || !type || !reason) return NULL;
  const char *h_inner = NULL;
  size_t h_len = 0;
  if (here_json && !sf_json_object_inner(here_json, &h_inner, &h_len)) return NULL;

  sf_buf b;
  sf_buf_init(&b, 512);
  sf_buf_put_str(&b, "{\"api_key\":");
  sf_buf_put_json_str(&b, api_key);
  sf_buf_put_str(&b, ",\"batch\":[{\"event\":\"$exception\",\"distinct_id\":");
  sf_buf_put_json_str(&b, distinct_id);
  sf_buf_put_str(&b, ",\"uuid\":");
  sf_buf_put_json_str(&b, uuid);
  sf_buf_put_str(&b, ",\"timestamp\":");
  sf_buf_put_json_str(&b, timestamp_iso);
  sf_buf_put_str(&b, ",\"properties\":{");
  if (h_len > 0) {
    sf_buf_put_bytes(&b, h_inner, h_len);
    sf_buf_put_char(&b, ',');
  }
  sf_buf_put_str(&b, "\"reason\":");
  sf_buf_put_json_str(&b, reason);
  sf_buf_put_str(&b, ",\"$exception_level\":\"error\",\"$exception_list\":[{\"type\":");
  sf_buf_put_json_str(&b, type);
  sf_buf_put_str(&b, ",\"value\":");
  const char *v = value ? value : "";
  sf_buf_put_json_str_n(&b, v, sf_utf8_trunc_len(v, 1000));
  sf_buf_put_str(&b, ",\"mechanism\":{\"handled\":true,\"synthetic\":true,\"type\":\"stillfail\"}}]}}]}");
  return sf_buf_take(&b);
}

static char *sf_win_build_batch_hang(
    const char *api_key,
    const char *distinct_id,
    const char *uuid,
    const char *timestamp_iso,
    const char *event_name,
    const char *payload_json,
    const char *here_json) {
  if (!api_key || !*api_key || !distinct_id || !uuid || !timestamp_iso || !event_name || !payload_json) return NULL;
  const char *p_inner = NULL;
  size_t p_len = 0;
  if (!sf_json_object_inner(payload_json, &p_inner, &p_len)) return NULL;
  const char *h_inner = NULL;
  size_t h_len = 0;
  if (here_json && !sf_json_object_inner(here_json, &h_inner, &h_len)) return NULL;

  sf_buf b;
  sf_buf_init(&b, 512 + p_len);
  sf_buf_put_str(&b, "{\"api_key\":");
  sf_buf_put_json_str(&b, api_key);
  sf_buf_put_str(&b, ",\"batch\":[{\"event\":");
  sf_buf_put_json_str(&b, event_name);
  sf_buf_put_str(&b, ",\"distinct_id\":");
  sf_buf_put_json_str(&b, distinct_id);
  sf_buf_put_str(&b, ",\"uuid\":");
  sf_buf_put_json_str(&b, uuid);
  sf_buf_put_str(&b, ",\"timestamp\":");
  sf_buf_put_json_str(&b, timestamp_iso);
  sf_buf_put_str(&b, ",\"properties\":{");
  if (h_len > 0) sf_buf_put_bytes(&b, h_inner, h_len);
  if (h_len > 0 && p_len > 0) sf_buf_put_char(&b, ',');
  if (p_len > 0) sf_buf_put_bytes(&b, p_inner, p_len);
  sf_buf_put_str(&b, "}}]}");
  return sf_buf_take(&b);
}

// ── reports.json parsing and formatting (pure C) ──

static const char *sf_rjson_ws(const char *p) {
  while (*p && sf_is_ws(*p)) p++;
  return p;
}

static const char *sf_rjson_skip_str(const char *p) {
  if (*p != '"') return NULL;
  for (p++; *p; p++) {
    if (*p == '\\' && p[1]) p++;
    else if (*p == '"') return p + 1;
  }
  return NULL;
}

static const char *sf_rjson_skip_val(const char *p) {
  p = sf_rjson_ws(p);
  if (*p == '"') return sf_rjson_skip_str(p);
  if (*p == '{' || *p == '[') {
    char close = *p == '{' ? '}' : ']';
    int is_obj = *p == '{';
    p = sf_rjson_ws(p + 1);
    if (*p == close) return p + 1;
    while (*p) {
      if (is_obj) {
        p = sf_rjson_skip_str(p);
        if (!p) return NULL;
        p = sf_rjson_ws(p);
        if (*p != ':') return NULL;
        p++;
      }
      p = sf_rjson_skip_val(p);
      if (!p) return NULL;
      p = sf_rjson_ws(p);
      if (*p == ',') p = sf_rjson_ws(p + 1);
      else if (*p == close) return p + 1;
      else return NULL;
    }
    return NULL;
  }
  const char *s = p;
  while (*p && *p != ',' && *p != '}' && *p != ']' && !sf_is_ws(*p)) p++;
  return p == s ? NULL : p;
}

static int sf_hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static int sf_parse_hex4(const char *p, unsigned *out) {
  unsigned v = 0;
  for (int i = 0; i < 4; i++) {
    int d = sf_hex_digit(p[i]);
    if (d < 0) return 0;
    v = (v << 4) | (unsigned)d;
  }
  *out = v;
  return 1;
}

static void sf_append_utf8(char *out, size_t cap, size_t *o, unsigned cp) {
  if (cap == 0) return;
  char tmp[4];
  size_t n = 0;
  if (cp < 0x80u) {
    tmp[0] = (char)cp;
    n = 1;
  } else if (cp < 0x800u) {
    tmp[0] = (char)(0xC0u | (cp >> 6));
    tmp[1] = (char)(0x80u | (cp & 0x3Fu));
    n = 2;
  } else if (cp < 0x10000u) {
    tmp[0] = (char)(0xE0u | (cp >> 12));
    tmp[1] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
    tmp[2] = (char)(0x80u | (cp & 0x3Fu));
    n = 3;
  } else {
    tmp[0] = (char)(0xF0u | (cp >> 18));
    tmp[1] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
    tmp[2] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
    tmp[3] = (char)(0x80u | (cp & 0x3Fu));
    n = 4;
  }
  if (*o + n < cap) {
    memcpy(out + *o, tmp, n);
    *o += n;
  }
}

static const char *sf_rjson_read_str(const char *p, char *out, size_t cap) {
  const char *end = sf_rjson_skip_str(p);
  if (!end) return NULL;
  if (!out || cap == 0) return end;
  size_t o = 0;
  for (const char *c = p + 1; c < end - 1; c++) {
    if (*c != '\\') {
      if (o + 1 < cap) out[o++] = *c;
      continue;
    }
    c++;
    if (c >= end - 1) break;
    switch (*c) {
      case 'n': if (o + 1 < cap) out[o++] = '\n'; break;
      case 'r': if (o + 1 < cap) out[o++] = '\r'; break;
      case 't': if (o + 1 < cap) out[o++] = '\t'; break;
      case 'b': if (o + 1 < cap) out[o++] = '\b'; break;
      case 'f': if (o + 1 < cap) out[o++] = '\f'; break;
      case 'u': {
        unsigned cp = 0xFFFDu;
        if (c + 4 < end - 1 && sf_parse_hex4(c + 1, &cp)) {
          c += 4;
          unsigned lo = 0;
          if (cp >= 0xD800u && cp < 0xDC00u && c + 6 < end - 1 && c[1] == '\\' && c[2] == 'u' && sf_parse_hex4(c + 3, &lo) &&
              lo >= 0xDC00u && lo < 0xE000u) {
            cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
            c += 6;
          }
        }
        sf_append_utf8(out, cap, &o, cp);
        break;
      }
      default:
        if (o + 1 < cap) out[o++] = *c;
        break;
    }
  }
  out[o] = '\0';
  return end;
}

static void sf_win_parse_reports_json(const char *text, int *reporting, char *account_buf, size_t account_cap) {
  if (reporting) *reporting = 1;
  if (account_buf && account_cap > 0) account_buf[0] = '\0';
  if (!text) return;
  const char *p = sf_rjson_ws(text);
  if (*p != '{') return;
  p = sf_rjson_ws(p + 1);
  while (*p == '"') {
    char key[64];
    key[0] = '\0';
    p = sf_rjson_read_str(p, key, sizeof key);
    if (!p) return;
    p = sf_rjson_ws(p);
    if (*p != ':') return;
    p = sf_rjson_ws(p + 1);
    if (strcmp(key, "reporting") == 0) {
      if (strncmp(p, "true", 4) == 0 && (p[4] == '\0' || p[4] == ',' || p[4] == '}' || sf_is_ws(p[4]))) {
        if (reporting) *reporting = 1;
      } else if (strncmp(p, "false", 5) == 0 && (p[5] == '\0' || p[5] == ',' || p[5] == '}' || sf_is_ws(p[5]))) {
        if (reporting) *reporting = 0;
      }
      p = sf_rjson_skip_val(p);
    } else if (strcmp(key, "account") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, account_buf, account_cap);
    } else {
      p = sf_rjson_skip_val(p);
    }
    if (!p) return;
    p = sf_rjson_ws(p);
    if (*p == ',') p = sf_rjson_ws(p + 1);
    else break;
  }
}

static char *sf_win_format_reports_json(int reporting, const char *account) {
  sf_buf b;
  sf_buf_init(&b, 128);
  sf_buf_put_str(&b, "{\"reporting\":");
  sf_buf_put_str(&b, reporting ? "true" : "false");
  if (account && *account) {
    sf_buf_put_str(&b, ",\"account\":");
    sf_buf_put_json_str(&b, account);
  }
  sf_buf_put_char(&b, '}');
  return sf_buf_take(&b);
}

// ── crash & watchdog records: pure C serialization, parsing, fingerprinting & rate-limit ──

#define SF_WIN_MAX_FRAMES 32
#define SF_WIN_MAX_KEPT 20
#define SF_WIN_WD_THRESHOLD_MS 2500ULL
#define SF_WIN_WD_WINDOW_MS (10ULL * 60ULL * 1000ULL)
#define SF_WIN_WD_MAX_PER_WINDOW 5

typedef struct {
  char module[64];
  uint64_t offset;
} sf_win_frame;

typedef struct {
  char kind[24];
  char uuid[37];
  char at[25];
  uint32_t exception_code;
  char exception_name[64];
  char fault_module[64];
  uint64_t fault_offset;
  uint64_t hang_ms;
  size_t frame_count;
  sf_win_frame frames[SF_WIN_MAX_FRAMES];
} sf_win_crash_rec;

typedef struct {
  int reported_this_stall;
  uint64_t report_times_ms[SF_WIN_WD_MAX_PER_WINDOW];
  int report_count;
} sf_win_wd_state;

static const char *sf_win_exception_name(uint32_t code) {
  switch (code) {
    case 0xC0000005u: return "EXCEPTION_ACCESS_VIOLATION";
    case 0xC000001Du: return "EXCEPTION_ILLEGAL_INSTRUCTION";
    case 0xC00000FDu: return "EXCEPTION_STACK_OVERFLOW";
    case 0xC0000094u: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
    case 0xC000008Cu: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
    case 0xC000008Du: return "EXCEPTION_FLT_DENORMAL_OPERAND";
    case 0xC000008Eu: return "EXCEPTION_FLT_DIVIDE_BY_ZERO";
    case 0xC0000090u: return "EXCEPTION_FLT_INVALID_OPERATION";
    case 0xC0000091u: return "EXCEPTION_FLT_OVERFLOW";
    case 0xC0000093u: return "EXCEPTION_FLT_UNDERFLOW";
    case 0xC0000096u: return "EXCEPTION_PRIV_INSTRUCTION";
    case 0xC0000006u: return "EXCEPTION_IN_PAGE_ERROR";
    case 0x80000002u: return "EXCEPTION_DATATYPE_MISALIGNMENT";
    case 0x80000003u: return "EXCEPTION_BREAKPOINT";
    case 0xC0000409u: return "STATUS_STACK_BUFFER_OVERRUN";
    case 0xC0000374u: return "STATUS_HEAP_CORRUPTION";
    default: return NULL;
  }
}

static void sf_win_format_exception_name(uint32_t code, char *buf, size_t cap) {
  if (!buf || cap == 0) return;
  const char *known = sf_win_exception_name(code);
  if (known) snprintf(buf, cap, "%s", known);
  else snprintf(buf, cap, "EXCEPTION_0x%08X", (unsigned)code);
}

// Fixed-buffer JSON writer (zero heap allocation, safe inside SetUnhandledExceptionFilter).
typedef struct {
  char *buf;
  size_t cap;
  size_t len;
  int overflow;
} sf_fbuf;

static void sf_fbuf_put_char(sf_fbuf *b, char c) {
  if (b->overflow || b->len + 1 >= b->cap) {
    b->overflow = 1;
    return;
  }
  b->buf[b->len++] = c;
  b->buf[b->len] = '\0';
}

static void sf_fbuf_put_str(sf_fbuf *b, const char *s) {
  if (!s) return;
  while (*s) sf_fbuf_put_char(b, *s++);
}

static void sf_fbuf_put_u64(sf_fbuf *b, uint64_t v) {
  char tmp[32];
  snprintf(tmp, sizeof tmp, "%llu", (unsigned long long)v);
  sf_fbuf_put_str(b, tmp);
}

static void sf_fbuf_put_json_str(sf_fbuf *b, const char *s) {
  if (!s) s = "";
  sf_fbuf_put_char(b, '"');
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    switch (c) {
      case '"': sf_fbuf_put_str(b, "\\\""); break;
      case '\\': sf_fbuf_put_str(b, "\\\\"); break;
      case '\b': sf_fbuf_put_str(b, "\\b"); break;
      case '\f': sf_fbuf_put_str(b, "\\f"); break;
      case '\n': sf_fbuf_put_str(b, "\\n"); break;
      case '\r': sf_fbuf_put_str(b, "\\r"); break;
      case '\t': sf_fbuf_put_str(b, "\\t"); break;
      default:
        if (c < 0x20u) {
          char esc[7];
          snprintf(esc, sizeof esc, "\\u00%02x", (unsigned)c);
          sf_fbuf_put_str(b, esc);
        } else {
          sf_fbuf_put_char(b, (char)c);
        }
        break;
    }
  }
  sf_fbuf_put_char(b, '"');
}

static size_t sf_win_write_crash_json_buf(const sf_win_crash_rec *rec, char *buf, size_t cap) {
  if (!rec || !buf || cap < 2) return 0;
  sf_fbuf b;
  b.buf = buf;
  b.cap = cap;
  b.len = 0;
  b.overflow = 0;
  buf[0] = '\0';
  sf_fbuf_put_str(&b, "{\"kind\":");
  sf_fbuf_put_json_str(&b, rec->kind);
  sf_fbuf_put_str(&b, ",\"uuid\":");
  sf_fbuf_put_json_str(&b, rec->uuid);
  sf_fbuf_put_str(&b, ",\"at\":");
  sf_fbuf_put_json_str(&b, rec->at);
  if (strcmp(rec->kind, "watchdog_hang") == 0) {
    sf_fbuf_put_str(&b, ",\"hang_ms\":");
    sf_fbuf_put_u64(&b, rec->hang_ms);
  } else {
    sf_fbuf_put_str(&b, ",\"exception_code\":");
    sf_fbuf_put_u64(&b, (uint64_t)rec->exception_code);
    sf_fbuf_put_str(&b, ",\"exception_name\":");
    sf_fbuf_put_json_str(&b, rec->exception_name);
    if (rec->fault_module[0]) {
      sf_fbuf_put_str(&b, ",\"fault_module\":");
      sf_fbuf_put_json_str(&b, rec->fault_module);
      sf_fbuf_put_str(&b, ",\"fault_offset\":");
      sf_fbuf_put_u64(&b, rec->fault_offset);
    }
    sf_fbuf_put_str(&b, ",\"frames\":[");
    size_t n = rec->frame_count > SF_WIN_MAX_FRAMES ? SF_WIN_MAX_FRAMES : rec->frame_count;
    for (size_t i = 0; i < n; i++) {
      if (i > 0) sf_fbuf_put_char(&b, ',');
      sf_fbuf_put_str(&b, "{\"module\":");
      sf_fbuf_put_json_str(&b, rec->frames[i].module);
      sf_fbuf_put_str(&b, ",\"offset\":");
      sf_fbuf_put_u64(&b, rec->frames[i].offset);
      sf_fbuf_put_char(&b, '}');
    }
    sf_fbuf_put_char(&b, ']');
  }
  sf_fbuf_put_char(&b, '}');
  return b.overflow ? 0 : b.len;
}

static const char *sf_rjson_read_u64(const char *p, uint64_t *out) {
  p = sf_rjson_ws(p);
  if (*p < '0' || *p > '9') return NULL;
  uint64_t v = 0;
  while (*p >= '0' && *p <= '9') {
    uint64_t d = (uint64_t)(*p - '0');
    if (v <= (UINT64_MAX - d) / 10ULL) v = v * 10ULL + d;
    p++;
  }
  if (out) *out = v;
  return p;
}

static int sf_win_parse_crash_json(const char *text, sf_win_crash_rec *out) {
  if (!out) return 0;
  memset(out, 0, sizeof *out);
  if (!text) return 0;
  const char *p = sf_rjson_ws(text);
  if (*p != '{') return 0;
  p = sf_rjson_ws(p + 1);
  while (*p == '"') {
    char key[64];
    key[0] = '\0';
    p = sf_rjson_read_str(p, key, sizeof key);
    if (!p) return 0;
    p = sf_rjson_ws(p);
    if (*p != ':') return 0;
    p = sf_rjson_ws(p + 1);
    if (strcmp(key, "kind") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, out->kind, sizeof out->kind);
    } else if (strcmp(key, "uuid") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, out->uuid, sizeof out->uuid);
    } else if (strcmp(key, "at") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, out->at, sizeof out->at);
    } else if (strcmp(key, "exception_name") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, out->exception_name, sizeof out->exception_name);
    } else if (strcmp(key, "fault_module") == 0 && *p == '"') {
      p = sf_rjson_read_str(p, out->fault_module, sizeof out->fault_module);
    } else if (strcmp(key, "exception_code") == 0) {
      uint64_t v = 0;
      p = sf_rjson_read_u64(p, &v);
      out->exception_code = (uint32_t)v;
    } else if (strcmp(key, "fault_offset") == 0) {
      p = sf_rjson_read_u64(p, &out->fault_offset);
    } else if (strcmp(key, "hang_ms") == 0) {
      p = sf_rjson_read_u64(p, &out->hang_ms);
    } else if (strcmp(key, "frames") == 0 && *p == '[') {
      p = sf_rjson_ws(p + 1);
      while (*p && *p != ']') {
        if (*p != '{') return 0;
        p = sf_rjson_ws(p + 1);
        sf_win_frame fr;
        memset(&fr, 0, sizeof fr);
        while (*p == '"') {
          char fk[32];
          fk[0] = '\0';
          p = sf_rjson_read_str(p, fk, sizeof fk);
          if (!p) return 0;
          p = sf_rjson_ws(p);
          if (*p != ':') return 0;
          p = sf_rjson_ws(p + 1);
          if (strcmp(fk, "module") == 0 && *p == '"') {
            p = sf_rjson_read_str(p, fr.module, sizeof fr.module);
          } else if (strcmp(fk, "offset") == 0) {
            p = sf_rjson_read_u64(p, &fr.offset);
          } else {
            p = sf_rjson_skip_val(p);
          }
          if (!p) return 0;
          p = sf_rjson_ws(p);
          if (*p == ',') p = sf_rjson_ws(p + 1);
          else break;
        }
        if (*p != '}') return 0;
        p = sf_rjson_ws(p + 1);
        if (out->frame_count < SF_WIN_MAX_FRAMES && fr.module[0]) {
          out->frames[out->frame_count++] = fr;
        }
        if (*p == ',') p = sf_rjson_ws(p + 1);
        else break;
      }
      if (*p != ']') return 0;
      p++;
    } else {
      p = sf_rjson_skip_val(p);
    }
    if (!p) return 0;
    p = sf_rjson_ws(p);
    if (*p == ',') p = sf_rjson_ws(p + 1);
    else break;
  }
  if (!out->uuid[0] || !out->at[0]) return 0;
  if (strcmp(out->kind, "crash") != 0 && strcmp(out->kind, "watchdog_hang") != 0) return 0;
  if (strcmp(out->kind, "watchdog_hang") == 0 && out->hang_ms == 0) return 0;
  return 1;
}

static void sf_win_build_crash_fingerprint(const sf_win_crash_rec *rec, char *out, size_t cap) {
  if (!out || cap == 0) return;
  out[0] = '\0';
  if (!rec) return;
  if (strcmp(rec->kind, "watchdog_hang") == 0) {
    snprintf(out, cap, "windows:MainThreadHang:watchdog");
    return;
  }
  const char *type = rec->exception_name[0] ? rec->exception_name : "Crash";
  sf_fbuf b;
  b.buf = out;
  b.cap = cap;
  b.len = 0;
  b.overflow = 0;
  if (rec->frame_count > 0) {
    sf_fbuf_put_str(&b, "windows:");
    sf_fbuf_put_str(&b, type);
    sf_fbuf_put_char(&b, ':');
    size_t lim = rec->frame_count < 6 ? rec->frame_count : 6;
    for (size_t i = 0; i < lim; i++) {
      if (i > 0) sf_fbuf_put_char(&b, '|');
      char seg[96];
      snprintf(seg, sizeof seg, "%s + 0x%llx", rec->frames[i].module, (unsigned long long)rec->frames[i].offset);
      sf_fbuf_put_str(&b, seg);
    }
  } else if (rec->fault_module[0]) {
    snprintf(out, cap, "windows:%s:%s + 0x%llx", type, rec->fault_module, (unsigned long long)rec->fault_offset);
  }
}

static char *sf_win_build_batch_crash(const char *api_key, const char *distinct_id, const sf_win_crash_rec *rec,
                                      const char *here_json) {
  if (!api_key || !*api_key || !distinct_id || !*distinct_id || !rec || !rec->uuid[0] || !rec->at[0]) return NULL;
  int is_wd = strcmp(rec->kind, "watchdog_hang") == 0;
  int is_crash = strcmp(rec->kind, "crash") == 0;
  if (!is_wd && !is_crash) return NULL;
  const char *h_inner = NULL;
  size_t h_len = 0;
  if (here_json && !sf_json_object_inner(here_json, &h_inner, &h_len)) return NULL;

  char fp[512];
  sf_win_build_crash_fingerprint(rec, fp, sizeof fp);

  sf_buf b;
  sf_buf_init(&b, 1024);
  sf_buf_put_str(&b, "{\"api_key\":");
  sf_buf_put_json_str(&b, api_key);
  sf_buf_put_str(&b, ",\"batch\":[{\"event\":\"$exception\",\"distinct_id\":");
  sf_buf_put_json_str(&b, distinct_id);
  sf_buf_put_str(&b, ",\"uuid\":");
  sf_buf_put_json_str(&b, rec->uuid);
  sf_buf_put_str(&b, ",\"timestamp\":");
  sf_buf_put_json_str(&b, rec->at);
  sf_buf_put_str(&b, ",\"properties\":{");
  if (h_len > 0) {
    sf_buf_put_bytes(&b, h_inner, h_len);
    sf_buf_put_char(&b, ',');
  }
  if (is_wd) {
    char num[32], val[96];
    snprintf(num, sizeof num, "%llu", (unsigned long long)rec->hang_ms);
    snprintf(val, sizeof val, "the main thread did not respond for %.1f s", (double)rec->hang_ms / 1000.0);
    sf_buf_put_str(&b, "\"reason\":\"watchdog_hang\",\"hang_ms\":");
    sf_buf_put_str(&b, num);
    sf_buf_put_str(&b, ",\"$exception_level\":\"error\",\"$exception_fingerprint\":");
    sf_buf_put_json_str(&b, fp);
    sf_buf_put_str(&b, ",\"$exception_list\":[{\"type\":\"MainThreadHang\",\"value\":");
    sf_buf_put_json_str(&b, val);
    sf_buf_put_str(&b, ",\"mechanism\":{\"handled\":false,\"synthetic\":false,\"type\":\"watchdog\"}}]}}]}");
  } else {
    const char *type = rec->exception_name[0] ? rec->exception_name : "Crash";
    char num[32], val[192];
    snprintf(num, sizeof num, "%u", (unsigned)rec->exception_code);
    if (rec->fault_module[0]) {
      snprintf(val, sizeof val, "%s (0x%08X) at %s + 0x%llx", type, (unsigned)rec->exception_code, rec->fault_module,
               (unsigned long long)rec->fault_offset);
    } else {
      snprintf(val, sizeof val, "%s (0x%08X)", type, (unsigned)rec->exception_code);
    }
    sf_buf_put_str(&b, "\"reason\":\"crash\",\"exception_code\":");
    sf_buf_put_str(&b, num);
    if (rec->fault_module[0]) {
      char off_num[32];
      snprintf(off_num, sizeof off_num, "%llu", (unsigned long long)rec->fault_offset);
      sf_buf_put_str(&b, ",\"fault_module\":");
      sf_buf_put_json_str(&b, rec->fault_module);
      sf_buf_put_str(&b, ",\"fault_offset\":");
      sf_buf_put_str(&b, off_num);
    }
    sf_buf_put_str(&b, ",\"frames\":[");
    size_t n = rec->frame_count > SF_WIN_MAX_FRAMES ? SF_WIN_MAX_FRAMES : rec->frame_count;
    for (size_t i = 0; i < n; i++) {
      if (i > 0) sf_buf_put_char(&b, ',');
      char off_num[32];
      snprintf(off_num, sizeof off_num, "%llu", (unsigned long long)rec->frames[i].offset);
      sf_buf_put_str(&b, "{\"binary\":");
      sf_buf_put_json_str(&b, rec->frames[i].module);
      sf_buf_put_str(&b, ",\"offset\":");
      sf_buf_put_str(&b, off_num);
      sf_buf_put_char(&b, '}');
    }
    sf_buf_put_str(&b, "],\"trace\":");
    sf_buf trace;
    sf_buf_init(&trace, 256);
    sf_buf_put_str(&trace, val);
    sf_buf_put_str(&trace, "\nCrashed thread:\n");
    for (size_t i = 0; i < n; i++) {
      char line[128];
      snprintf(line, sizeof line, "%-3u %s + 0x%llx\n", (unsigned)i, rec->frames[i].module,
               (unsigned long long)rec->frames[i].offset);
      sf_buf_put_str(&trace, line);
    }
    char *trace_str = sf_buf_take(&trace);
    sf_buf_put_json_str(&b, trace_str ? trace_str : "");
    free(trace_str);
    if (fp[0]) {
      sf_buf_put_str(&b, ",\"$exception_fingerprint\":");
      sf_buf_put_json_str(&b, fp);
    }
    sf_buf_put_str(&b, ",\"$exception_level\":\"fatal\",\"$exception_list\":[{\"type\":");
    sf_buf_put_json_str(&b, type);
    sf_buf_put_str(&b, ",\"value\":");
    sf_buf_put_json_str(&b, val);
    sf_buf_put_str(&b, ",\"mechanism\":{\"handled\":false,\"synthetic\":false,\"type\":\"seh\"}}]}}]}");
  }
  return sf_buf_take(&b);
}

static int sf_win_wd_on_probe(sf_win_wd_state *st, int active, int timed_out, uint64_t elapsed_ms,
                              uint64_t now_unbiased_ms, uint64_t *out_hang_ms) {
  if (out_hang_ms) *out_hang_ms = 0;
  if (!st) return 0;
  if (!active || !timed_out) {
    st->reported_this_stall = 0;
    return 0;
  }
  if (elapsed_ms < SF_WIN_WD_THRESHOLD_MS || st->reported_this_stall) return 0;
  int kept = 0;
  for (int i = 0; i < st->report_count; i++) {
    if (now_unbiased_ms >= st->report_times_ms[i] && (now_unbiased_ms - st->report_times_ms[i]) < SF_WIN_WD_WINDOW_MS) {
      st->report_times_ms[kept++] = st->report_times_ms[i];
    }
  }
  st->report_count = kept;
  st->reported_this_stall = 1;
  if (st->report_count < SF_WIN_WD_MAX_PER_WINDOW) {
    st->report_times_ms[st->report_count++] = now_unbiased_ms;
    if (out_hang_ms) *out_hang_ms = elapsed_ms;
    return 1;
  }
  return 0;
}

static int32_t sf_win_crash_mask_for_kind(const char *kind) {
  if (!kind) return 0;
  if (strcmp(kind, "crash") == 0) return 1;
  if (strcmp(kind, "watchdog_hang") == 0) return 2;
  if (strcmp(kind, "memory_runaway") == 0) return 4;
  if (strcmp(kind, "hang") == 0) return 8;
  return 0;
}

#ifndef SF_REPORTS_PURE

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <knownfolders.h>
#include "moonbit.h"

#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "user32.lib")

#define SF_WIN_QUEUE_CAP 64

static INIT_ONCE sf_cfg_once = INIT_ONCE_STATIC_INIT;
static char sf_posthog_host[512];
static char sf_posthog_key[256];

static INIT_ONCE sf_here_once = INIT_ONCE_STATIC_INIT;
static char *sf_here_cached = NULL;

static SRWLOCK sf_state_lock = SRWLOCK_INIT;
static int sf_state_loaded = 0;
static volatile LONG sf_reporting_on = 1;
static char sf_persisted_account[256];
static char sf_signed_in[256];

static SRWLOCK sf_queue_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE sf_queue_cv = CONDITION_VARIABLE_INIT;
static char *sf_queue[SF_WIN_QUEUE_CAP];
static size_t sf_queue_head = 0;
static size_t sf_queue_count = 0;
static int sf_sender_started = 0;
static volatile LONG sf_sender_stop = 0;
static volatile LONG sf_flush_crashes = 0;

static volatile LONG sf_monitor_installed = 0;
static volatile LONG sf_in_crash = 0;
static volatile LONG sf_crash_pending_read = 0;
static DWORD sf_main_tid = 0;
static WCHAR sf_crashes_dir[MAX_PATH];
static LPTOP_LEVEL_EXCEPTION_FILTER sf_prev_exception_filter = NULL;
static sf_win_crash_rec sf_crash_rec_static;
static char sf_crash_json_static[8192];

static char *sf_win_wstr_to_utf8_n(const WCHAR *w, int wlen) {
  if (!w || wlen == 0) {
    char *empty = (char *)malloc(1);
    if (empty) empty[0] = '\0';
    return empty;
  }
  int n = WideCharToMultiByte(CP_UTF8, 0, w, wlen, NULL, 0, NULL, NULL);
  if (n <= 0) {
    char *empty = (char *)malloc(1);
    if (empty) empty[0] = '\0';
    return empty;
  }
  char *out = (char *)malloc((size_t)n + 1);
  if (!out) return NULL;
  int got = WideCharToMultiByte(CP_UTF8, 0, w, wlen, out, n, NULL, NULL);
  out[got > 0 ? got : 0] = '\0';
  return out;
}

static char *sf_win_mb_to_utf8(moonbit_string_t s) {
  int32_t len = Moonbit_array_length(s);
  return sf_win_wstr_to_utf8_n((const WCHAR *)s, (int)len);
}

static void sf_win_env_copy_utf8(const wchar_t *name, char *dst, size_t cap) {
  if (cap == 0) return;
  dst[0] = '\0';
  const wchar_t *v = mb_win_env(name);
  if (!v || !*v) return;
  int n = WideCharToMultiByte(CP_UTF8, 0, v, -1, dst, (int)cap, NULL, NULL);
  if (n <= 0) dst[0] = '\0';
  else dst[cap - 1] = '\0';
}

static BOOL CALLBACK sf_win_cfg_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  sf_win_env_copy_utf8(L"STILLFAIL_POSTHOG_HOST", sf_posthog_host, sizeof sf_posthog_host);
  if (!sf_posthog_host[0]) {
    snprintf(sf_posthog_host, sizeof sf_posthog_host, "%s", "https://us.i.posthog.com");
  }
  size_t hlen = strlen(sf_posthog_host);
  while (hlen > 0 && sf_posthog_host[hlen - 1] == '/') {
    sf_posthog_host[--hlen] = '\0';
  }
  sf_win_env_copy_utf8(L"STILLFAIL_POSTHOG_KEY", sf_posthog_key, sizeof sf_posthog_key);
  return TRUE;
}

static void sf_win_cfg_ensure(void) {
  InitOnceExecuteOnce(&sf_cfg_once, sf_win_cfg_init_cb, NULL, NULL);
}

static int sf_win_has_key(void) {
  sf_win_cfg_ensure();
  return sf_posthog_key[0] != '\0';
}

// App data directory beside `core/`: `desktop_app_data()` (win_core.c) when MBUI_OWN=1, else `%LOCALAPPDATA%\<app_id>`.
static WCHAR *sf_win_reports_dir(void) {
  WCHAR *d = desktop_app_data();
  if (d) return d;
  PWSTR local = NULL;
  if (SHGetKnownFolderPath(&FOLDERID_LocalAppData, 0, NULL, &local) != S_OK) return NULL;
  const wchar_t *id = mb_win_app_id();
  if (!id || !*id) id = L"fail.still.mbui";
  size_t n = wcslen(local) + wcslen(id) + 2;
  WCHAR *dir = (WCHAR *)malloc(n * sizeof(WCHAR));
  if (dir) swprintf(dir, n, L"%ls\\%ls", local, id);
  CoTaskMemFree(local);
  return dir;
}

static void sf_win_state_load_locked(void) {
  if (sf_state_loaded) return;
  sf_state_loaded = 1;
  sf_reporting_on = 1;
  sf_persisted_account[0] = '\0';
  WCHAR *dir = sf_win_reports_dir();
  if (!dir) return;
  size_t pn = wcslen(dir) + 16;
  WCHAR *path = (WCHAR *)malloc(pn * sizeof(WCHAR));
  if (!path) {
    free(dir);
    return;
  }
  swprintf(path, pn, L"%ls\\reports.json", dir);
  free(dir);
  HANDLE f = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(path);
  if (f == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER sz;
  if (GetFileSizeEx(f, &sz) && sz.QuadPart > 0 && sz.QuadPart < 1024 * 1024) {
    char *buf = (char *)malloc((size_t)sz.QuadPart + 1);
    if (buf) {
      DWORD got = 0;
      if (ReadFile(f, buf, (DWORD)sz.QuadPart, &got, NULL)) {
        buf[got] = '\0';
        int rep = 1;
        sf_win_parse_reports_json(buf, &rep, sf_persisted_account, sizeof sf_persisted_account);
        sf_reporting_on = rep ? 1 : 0;
      }
      free(buf);
    }
  }
  CloseHandle(f);
}

static void sf_win_state_save_locked(void) {
  WCHAR *dir = sf_win_reports_dir();
  if (!dir) return;
  SHCreateDirectoryExW(NULL, dir, NULL);
  char *json = sf_win_format_reports_json((int)sf_reporting_on, sf_persisted_account);
  if (!json) {
    free(dir);
    return;
  }
  size_t pn = wcslen(dir) + 24;
  WCHAR *dst = (WCHAR *)malloc(pn * sizeof(WCHAR));
  WCHAR *tmp = (WCHAR *)malloc(pn * sizeof(WCHAR));
  if (dst && tmp) {
    swprintf(dst, pn, L"%ls\\reports.json", dir);
    swprintf(tmp, pn, L"%ls\\reports.json.tmp", dir);
    HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f != INVALID_HANDLE_VALUE) {
      DWORD want = (DWORD)strlen(json), put = 0;
      BOOL ok = WriteFile(f, json, want, &put, NULL) && put == want;
      CloseHandle(f);
      if (ok) MoveFileExW(tmp, dst, MOVEFILE_REPLACE_EXISTING);
      else DeleteFileW(tmp);
    }
  }
  free(dst);
  free(tmp);
  free(json);
  free(dir);
}

static int sf_win_reporting(void) {
  AcquireSRWLockExclusive(&sf_state_lock);
  sf_win_state_load_locked();
  int on = sf_reporting_on;
  ReleaseSRWLockExclusive(&sf_state_lock);
  return on;
}

static void sf_win_distinct_id(char *out, size_t cap) {
  AcquireSRWLockExclusive(&sf_state_lock);
  sf_win_state_load_locked();
  const char *src = sf_signed_in[0] ? sf_signed_in : sf_persisted_account[0] ? sf_persisted_account : "windows-anonymous";
  snprintf(out, cap, "%s", src);
  ReleaseSRWLockExclusive(&sf_state_lock);
}

static void sf_win_reg_bios_utf8(const wchar_t *value_name, char *out, size_t cap) {
  out[0] = '\0';
  WCHAR wbuf[256];
  DWORD bytes = (DWORD)sizeof wbuf;
  if (RegGetValueW(HKEY_LOCAL_MACHINE, L"HARDWARE\\DESCRIPTION\\System\\BIOS", value_name, RRF_RT_REG_SZ, NULL, wbuf, &bytes) != ERROR_SUCCESS) {
    return;
  }
  wbuf[(sizeof wbuf / sizeof wbuf[0]) - 1] = L'\0';
  int n = WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, out, (int)cap, NULL, NULL);
  if (n <= 0) out[0] = '\0';
  else out[cap - 1] = '\0';
}

static BOOL CALLBACK sf_win_here_init_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  const wchar_t *id = mb_win_app_id();
  int own = id && (wcscmp(id, L"fail.still.desktop") == 0 || wcscmp(id, L"fail.still.desktop.beta") == 0 ||
                   wcscmp(id, L"build.monoid.desktop") == 0 || wcscmp(id, L"build.monoid.desktop.beta") == 0);
  const char *app = own ? "windows" : "windows-mbui";
  const char *lib = own ? "stillfail-windows" : "stillfail-mbui-windows";

  char os_ver[64];
  os_ver[0] = '\0';
  typedef LONG(WINAPI * sf_rtl_get_version_fn)(OSVERSIONINFOW *);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  sf_rtl_get_version_fn rtl_get_ver = ntdll ? (sf_rtl_get_version_fn)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
  if (rtl_get_ver) {
    OSVERSIONINFOW vi;
    memset(&vi, 0, sizeof vi);
    vi.dwOSVersionInfoSize = sizeof vi;
    if (rtl_get_ver(&vi) == 0) {
      snprintf(os_ver, sizeof os_ver, "%lu.%lu.%lu", (unsigned long)vi.dwMajorVersion, (unsigned long)vi.dwMinorVersion,
               (unsigned long)vi.dwBuildNumber);
    }
  }

  char mfr[256], model[256];
  sf_win_reg_bios_utf8(L"SystemManufacturer", mfr, sizeof mfr);
  sf_win_reg_bios_utf8(L"SystemProductName", model, sizeof model);

  char version[128], build[64], release[220];
  sf_win_env_copy_utf8(L"MBUI_VERSION", version, sizeof version);
  sf_win_env_copy_utf8(L"MBUI_BUILD", build, sizeof build);
  snprintf(release, sizeof release, "%s (%s)", version, build);

  sf_buf b;
  sf_buf_init(&b, 384);
  sf_buf_put_str(&b, "{\"release\":");
  sf_buf_put_json_str(&b, release);
  sf_buf_put_str(&b, ",\"app\":");
  sf_buf_put_json_str(&b, app);
  sf_buf_put_str(&b, ",\"$app_version\":");
  sf_buf_put_json_str(&b, version);
  sf_buf_put_str(&b, ",\"$app_build\":");
  sf_buf_put_json_str(&b, build);
  sf_buf_put_str(&b, ",\"$os\":\"Windows\",\"$os_version\":");
  sf_buf_put_json_str(&b, os_ver);
  if (mfr[0]) {
    sf_buf_put_str(&b, ",\"$device_manufacturer\":");
    sf_buf_put_json_str(&b, mfr);
  }
  if (model[0]) {
    sf_buf_put_str(&b, ",\"$device_model\":");
    sf_buf_put_json_str(&b, model);
  }
  sf_buf_put_str(&b, ",\"$lib\":");
  sf_buf_put_json_str(&b, lib);
  sf_buf_put_char(&b, '}');
  sf_here_cached = sf_buf_take(&b);
  return TRUE;
}

static const char *sf_win_here(void) {
  InitOnceExecuteOnce(&sf_here_once, sf_win_here_init_cb, NULL, NULL);
  return sf_here_cached ? sf_here_cached : "{}";
}

static void sf_win_make_uuid(char out37[37]) {
  uint8_t raw[16];
  memset(raw, 0, sizeof raw);
  BCryptGenRandom(NULL, raw, (ULONG)sizeof raw, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  sf_win_format_uuid(raw, out37);
}

static void sf_win_now_iso(char out25[25]) {
  SYSTEMTIME st;
  GetSystemTime(&st);
  sf_win_format_iso_utc((int)st.wYear, (int)st.wMonth, (int)st.wDay, (int)st.wHour, (int)st.wMinute, (int)st.wSecond,
                        (int)st.wMilliseconds, out25);
}

static int sf_win_post_batch(const char *body) {
  sf_win_cfg_ensure();
  if (!sf_posthog_host[0] || !body) return 0;
  char url_utf8[600];
  snprintf(url_utf8, sizeof url_utf8, "%s/batch/", sf_posthog_host);
  WCHAR wurl[600];
  if (MultiByteToWideChar(CP_UTF8, 0, url_utf8, -1, wurl, (int)(sizeof wurl / sizeof wurl[0])) <= 0) return 0;

  URL_COMPONENTS uc;
  memset(&uc, 0, sizeof uc);
  uc.dwStructSize = sizeof uc;
  WCHAR whost[256], wpath[512];
  uc.lpszHostName = whost;
  uc.dwHostNameLength = (DWORD)(sizeof whost / sizeof whost[0]);
  uc.lpszUrlPath = wpath;
  uc.dwUrlPathLength = (DWORD)(sizeof wpath / sizeof wpath[0]);
  if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) return 0;

  HINTERNET s = WinHttpOpen(L"stillfail-reports/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                            WINHTTP_NO_PROXY_BYPASS, 0);
  if (!s) return 0;
  WinHttpSetTimeouts(s, 15000, 15000, 15000, 15000);
  HINTERNET c = WinHttpConnect(s, whost, uc.nPort, 0);
  HINTERNET r = c ? WinHttpOpenRequest(c, L"POST", wpath, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                       uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                  : NULL;
  int ok = 0;
  if (r) {
    DWORD blen = (DWORD)strlen(body);
    if (WinHttpSendRequest(r, L"Content-Type: application/json\r\n", (DWORD)-1, (LPVOID)body, blen, blen, 0) &&
        WinHttpReceiveResponse(r, NULL)) {
      DWORD status = 0;
      DWORD status_sz = sizeof status;
      if (WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                              &status, &status_sz, WINHTTP_NO_HEADER_INDEX)) {
        ok = (status >= 200 && status <= 299) ? 1 : 0;
      }
    }
    WinHttpCloseHandle(r);
  }
  if (c) WinHttpCloseHandle(c);
  WinHttpCloseHandle(s);
  return ok;
}

// Read-only scan of pending crash/watchdog files for crash_pending bitmask (returned at most once per process).
static int32_t sf_win_pending_crash_mask(void) {
  if (!sf_win_has_key() || !sf_win_reporting() || !sf_crashes_dir[0]) return 0;
  if (InterlockedExchange(&sf_crash_pending_read, 1) != 0) return 0;
  WCHAR pattern[MAX_PATH];
  if (swprintf(pattern, MAX_PATH, L"%ls\\*.json", sf_crashes_dir) < 0) return 0;
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern, &fd);
  if (h == INVALID_HANDLE_VALUE) return 0;
  int32_t mask = 0;
  int scanned = 0;
  do {
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    if (scanned >= SF_WIN_MAX_KEPT) break;
    WCHAR fpath[MAX_PATH];
    if (swprintf(fpath, MAX_PATH, L"%ls\\%ls", sf_crashes_dir, fd.cFileName) < 0) continue;
    HANDLE f = CreateFileW(fpath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) continue;
    LARGE_INTEGER sz;
    char *raw = NULL;
    if (GetFileSizeEx(f, &sz) && sz.QuadPart > 0 && sz.QuadPart < 64 * 1024) {
      raw = (char *)malloc((size_t)sz.QuadPart + 1);
      if (raw) {
        DWORD got = 0;
        if (ReadFile(f, raw, (DWORD)sz.QuadPart, &got, NULL)) raw[got] = '\0';
        else {
          free(raw);
          raw = NULL;
        }
      }
    }
    CloseHandle(f);
    if (!raw) continue;
    sf_win_crash_rec rec;
    if (sf_win_parse_crash_json(raw, &rec)) {
      mask |= sf_win_crash_mask_for_kind(rec.kind);
      scanned++;
    }
    free(raw);
  } while (FindNextFileW(h, &fd));
  FindClose(h);
  return mask;
}

static void sf_win_flush_crashes(void) {
  if (!sf_win_has_key() || !sf_win_reporting() || !sf_crashes_dir[0]) return;
  WCHAR pattern[MAX_PATH];
  if (swprintf(pattern, MAX_PATH, L"%ls\\*.json", sf_crashes_dir) < 0) return;
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern, &fd);
  if (h == INVALID_HANDLE_VALUE) return;

  char distinct_id[256];
  sf_win_distinct_id(distinct_id, sizeof distinct_id);
  const char *here = sf_win_here();
  int handled = 0;
  do {
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) continue;
    WCHAR fpath[MAX_PATH];
    if (swprintf(fpath, MAX_PATH, L"%ls\\%ls", sf_crashes_dir, fd.cFileName) < 0) continue;
    if (handled >= SF_WIN_MAX_KEPT) {
      DeleteFileW(fpath);
      continue;
    }
    HANDLE f = CreateFileW(fpath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) continue;
    LARGE_INTEGER sz;
    char *raw = NULL;
    if (GetFileSizeEx(f, &sz) && sz.QuadPart > 0 && sz.QuadPart < 64 * 1024) {
      raw = (char *)malloc((size_t)sz.QuadPart + 1);
      if (raw) {
        DWORD got = 0;
        if (ReadFile(f, raw, (DWORD)sz.QuadPart, &got, NULL)) raw[got] = '\0';
        else {
          free(raw);
          raw = NULL;
        }
      }
    }
    CloseHandle(f);
    if (!raw) {
      DeleteFileW(fpath);
      continue;
    }
    sf_win_crash_rec rec;
    if (!sf_win_parse_crash_json(raw, &rec)) {
      free(raw);
      DeleteFileW(fpath);
      continue;
    }
    free(raw);
    char *body = sf_win_build_batch_crash(sf_posthog_key, distinct_id, &rec, here);
    if (!body) continue;
    if (sf_win_post_batch(body)) {
      DeleteFileW(fpath);
      handled++;
    }
    free(body);
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

static DWORD WINAPI sf_win_sender_thread(LPVOID param) {
  (void)param;
  while (!InterlockedCompareExchange(&sf_sender_stop, 0, 0)) {
    char *body = NULL;
    int do_flush = 0;
    AcquireSRWLockExclusive(&sf_queue_lock);
    while (sf_queue_count == 0 && !InterlockedCompareExchange(&sf_flush_crashes, 0, 0) &&
           !InterlockedCompareExchange(&sf_sender_stop, 0, 0)) {
      SleepConditionVariableSRW(&sf_queue_cv, &sf_queue_lock, INFINITE, 0);
    }
    if (InterlockedExchange(&sf_flush_crashes, 0)) do_flush = 1;
    if (sf_queue_count > 0) {
      body = sf_queue[sf_queue_head];
      sf_queue[sf_queue_head] = NULL;
      sf_queue_head = (sf_queue_head + 1) % SF_WIN_QUEUE_CAP;
      sf_queue_count--;
    }
    ReleaseSRWLockExclusive(&sf_queue_lock);
    if (do_flush) sf_win_flush_crashes();
    if (body) {
      if (sf_win_reporting()) (void)sf_win_post_batch(body);
      free(body);
    }
  }
  return 0;
}

static int sf_win_ensure_sender_locked(void) {
  if (sf_sender_started) return 1;
  HANDLE th = CreateThread(NULL, 0, sf_win_sender_thread, NULL, 0, NULL);
  if (!th) return 0;
  CloseHandle(th);
  sf_sender_started = 1;
  return 1;
}

static void sf_win_trigger_flush_crashes(void) {
  InterlockedExchange(&sf_flush_crashes, 1);
  AcquireSRWLockExclusive(&sf_queue_lock);
  (void)sf_win_ensure_sender_locked();
  ReleaseSRWLockExclusive(&sf_queue_lock);
  WakeConditionVariable(&sf_queue_cv);
}

static void sf_win_enqueue(char *body) {
  if (!body) return;
  AcquireSRWLockExclusive(&sf_queue_lock);
  if (!sf_win_ensure_sender_locked()) {
    ReleaseSRWLockExclusive(&sf_queue_lock);
    free(body);
    return;
  }
  if (sf_queue_count == SF_WIN_QUEUE_CAP) {
    free(sf_queue[sf_queue_head]);
    sf_queue[sf_queue_head] = NULL;
    sf_queue_head = (sf_queue_head + 1) % SF_WIN_QUEUE_CAP;
    sf_queue_count--;
  }
  size_t tail = (sf_queue_head + sf_queue_count) % SF_WIN_QUEUE_CAP;
  sf_queue[tail] = body;
  sf_queue_count++;
  ReleaseSRWLockExclusive(&sf_queue_lock);
  WakeConditionVariable(&sf_queue_cv);
}

// Writes a crash/watchdog record atomically into `<sf_crashes_dir>\<uuid>.json` without heap allocations.
static int sf_win_persist_crash_buf(const sf_win_crash_rec *rec, char *json_buf, size_t json_cap) {
  if (!rec || !sf_crashes_dir[0] || !rec->uuid[0]) return 0;
  size_t len = sf_win_write_crash_json_buf(rec, json_buf, json_cap);
  if (len == 0) return 0;
  WCHAR wuuid[40];
  if (MultiByteToWideChar(CP_UTF8, 0, rec->uuid, -1, wuuid, (int)(sizeof wuuid / sizeof wuuid[0])) <= 0) return 0;
  WCHAR tmp[MAX_PATH], dst[MAX_PATH];
  if (swprintf(tmp, MAX_PATH, L"%ls\\%ls.json.tmp", sf_crashes_dir, wuuid) < 0) return 0;
  if (swprintf(dst, MAX_PATH, L"%ls\\%ls.json", sf_crashes_dir, wuuid) < 0) return 0;
  HANDLE f = CreateFileW(tmp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (f == INVALID_HANDLE_VALUE) return 0;
  DWORD put = 0;
  BOOL ok = WriteFile(f, json_buf, (DWORD)len, &put, NULL) && put == (DWORD)len;
  CloseHandle(f);
  if (ok) {
    if (MoveFileExW(tmp, dst, MOVEFILE_REPLACE_EXISTING)) return 1;
  }
  DeleteFileW(tmp);
  return 0;
}

static void sf_win_addr_to_mod(void *addr, char *mod_out, size_t mod_cap, uint64_t *off_out) {
  if (mod_out && mod_cap > 0) mod_out[0] = '\0';
  if (off_out) *off_out = 0;
  if (!addr) return;
  HMODULE hmod = NULL;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          (LPCWSTR)addr, &hmod) ||
      !hmod) {
    if (mod_out && mod_cap > 0) snprintf(mod_out, mod_cap, "unknown");
    if (off_out) *off_out = (uint64_t)(uintptr_t)addr;
    return;
  }
  if (off_out) *off_out = (uint64_t)((uintptr_t)addr - (uintptr_t)hmod);
  WCHAR wpath[MAX_PATH];
  DWORD n = GetModuleFileNameW(hmod, wpath, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    if (mod_out && mod_cap > 0) snprintf(mod_out, mod_cap, "unknown");
    return;
  }
  wpath[n] = L'\0';
  const WCHAR *base = wpath;
  for (const WCHAR *p = wpath; *p; p++) {
    if (*p == L'\\' || *p == L'/') base = p + 1;
  }
  if (mod_out && mod_cap > 0) {
    int got = WideCharToMultiByte(CP_UTF8, 0, base, -1, mod_out, (int)mod_cap, NULL, NULL);
    if (got <= 0) snprintf(mod_out, mod_cap, "unknown");
    else mod_out[mod_cap - 1] = '\0';
  }
}

static LONG WINAPI sf_win_unhandled_exception_filter(EXCEPTION_POINTERS *ep) {
  if (InterlockedExchange(&sf_in_crash, 1) == 0 && sf_reporting_on && sf_crashes_dir[0]) {
    memset(&sf_crash_rec_static, 0, sizeof sf_crash_rec_static);
    snprintf(sf_crash_rec_static.kind, sizeof sf_crash_rec_static.kind, "crash");
    sf_win_make_uuid(sf_crash_rec_static.uuid);
    sf_win_now_iso(sf_crash_rec_static.at);
    uint32_t code = (ep && ep->ExceptionRecord) ? (uint32_t)ep->ExceptionRecord->ExceptionCode : 0u;
    sf_crash_rec_static.exception_code = code;
    sf_win_format_exception_name(code, sf_crash_rec_static.exception_name, sizeof sf_crash_rec_static.exception_name);
    void *fault_addr = (ep && ep->ExceptionRecord) ? ep->ExceptionRecord->ExceptionAddress : NULL;
    if (fault_addr) {
      sf_win_addr_to_mod(fault_addr, sf_crash_rec_static.fault_module, sizeof sf_crash_rec_static.fault_module,
                         &sf_crash_rec_static.fault_offset);
    }
    void *raw_frames[SF_WIN_MAX_FRAMES];
    USHORT captured = RtlCaptureStackBackTrace(0, SF_WIN_MAX_FRAMES, raw_frames, NULL);
    size_t out_i = 0;
    if (fault_addr && (captured == 0 || raw_frames[0] != fault_addr)) {
      snprintf(sf_crash_rec_static.frames[0].module, sizeof sf_crash_rec_static.frames[0].module, "%s",
               sf_crash_rec_static.fault_module);
      sf_crash_rec_static.frames[0].offset = sf_crash_rec_static.fault_offset;
      out_i = 1;
    }
    for (USHORT i = 0; i < captured && out_i < SF_WIN_MAX_FRAMES; i++) {
      sf_win_addr_to_mod(raw_frames[i], sf_crash_rec_static.frames[out_i].module,
                         sizeof sf_crash_rec_static.frames[out_i].module, &sf_crash_rec_static.frames[out_i].offset);
      out_i++;
    }
    sf_crash_rec_static.frame_count = out_i;
    (void)sf_win_persist_crash_buf(&sf_crash_rec_static, sf_crash_json_static, sizeof sf_crash_json_static);
  }
  return sf_prev_exception_filter ? sf_prev_exception_filter(ep) : EXCEPTION_CONTINUE_SEARCH;
}

static BOOL CALLBACK sf_win_find_hwnd_cb(HWND w, LPARAM lp) {
  if (IsWindowVisible(w)) {
    *(HWND *)lp = w;
    return FALSE;
  }
  return TRUE;
}

static DWORD WINAPI sf_win_watchdog_thread(LPVOID param) {
  (void)param;
  sf_win_wd_state wd;
  memset(&wd, 0, sizeof wd);
  while (!InterlockedCompareExchange(&sf_sender_stop, 0, 0)) {
    Sleep(1000);
    if (InterlockedCompareExchange(&sf_sender_stop, 0, 0)) break;
    DWORD tid = sf_main_tid;
    if (tid == 0) continue;
    HWND hwnd = NULL;
    EnumThreadWindows(tid, sf_win_find_hwnd_cb, (LPARAM)&hwnd);
    int active = (hwnd != NULL && !IsIconic(hwnd) && GetForegroundWindow() == hwnd) ? 1 : 0;
    uint64_t hang_ms = 0;
    if (!active) {
      ULONGLONG now_t = 0;
      (void)QueryUnbiasedInterruptTime(&now_t);
      (void)sf_win_wd_on_probe(&wd, 0, 0, 0, (uint64_t)(now_t / 10000ULL), &hang_ms);
      continue;
    }
    ULONGLONG t0 = 0, t1 = 0;
    (void)QueryUnbiasedInterruptTime(&t0);
    DWORD_PTR res = 0;
    LRESULT ok = SendMessageTimeoutW(hwnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_NORMAL, 2500, &res);
    DWORD err = (ok == 0) ? GetLastError() : 0;
    (void)QueryUnbiasedInterruptTime(&t1);
    uint64_t elapsed_ms = (t1 >= t0) ? (uint64_t)((t1 - t0) / 10000ULL) : 0;
    uint64_t now_ms = (uint64_t)(t1 / 10000ULL);
    int still_active = (!IsIconic(hwnd) && GetForegroundWindow() == hwnd) ? 1 : 0;
    int timed_out = (ok == 0 && (err == ERROR_TIMEOUT || err == 0)) ? 1 : 0;
    if (sf_win_wd_on_probe(&wd, still_active, timed_out, elapsed_ms, now_ms, &hang_ms) && sf_win_reporting()) {
      sf_win_crash_rec rec;
      memset(&rec, 0, sizeof rec);
      snprintf(rec.kind, sizeof rec.kind, "watchdog_hang");
      sf_win_make_uuid(rec.uuid);
      sf_win_now_iso(rec.at);
      rec.hang_ms = hang_ms;
      char jbuf[512];
      if (sf_win_persist_crash_buf(&rec, jbuf, sizeof jbuf)) {
        sf_win_trigger_flush_crashes();
      }
    }
  }
  return 0;
}

static void sf_win_install_monitoring(void) {
  if (!sf_win_has_key()) return;
  if (InterlockedCompareExchange(&sf_monitor_installed, 1, 0) != 0) return;
  sf_main_tid = GetCurrentThreadId();
  (void)sf_win_reporting();
  WCHAR *dir = sf_win_reports_dir();
  if (dir) {
    if (swprintf(sf_crashes_dir, MAX_PATH, L"%ls\\crashes", dir) > 0) {
      SHCreateDirectoryExW(NULL, sf_crashes_dir, NULL);
    }
    free(dir);
  }
  sf_prev_exception_filter = SetUnhandledExceptionFilter(sf_win_unhandled_exception_filter);
  HANDLE wd = CreateThread(NULL, 0, sf_win_watchdog_thread, NULL, 0, NULL);
  if (wd) CloseHandle(wd);
}

static void sf_win_handled(const char *type, const char *value, const char *reason) {
  if (!sf_win_has_key() || !sf_win_reporting()) return;
  char distinct_id[256], uuid[37], ts[25];
  sf_win_distinct_id(distinct_id, sizeof distinct_id);
  sf_win_make_uuid(uuid);
  sf_win_now_iso(ts);
  char *body = sf_win_build_batch_exception(sf_posthog_key, distinct_id, uuid, ts, type, value, reason, sf_win_here());
  sf_win_enqueue(body);
}

static void sf_win_hang(const char *payload_json, const char *event_name) {
  if (!sf_win_has_key() || !sf_win_reporting()) return;
  char distinct_id[256], uuid[37], ts[25];
  sf_win_distinct_id(distinct_id, sizeof distinct_id);
  sf_win_make_uuid(uuid);
  sf_win_now_iso(ts);
  char *body = sf_win_build_batch_hang(sf_posthog_key, distinct_id, uuid, ts, event_name, payload_json, sf_win_here());
  sf_win_enqueue(body);
}

/// What the app tells (reports.mbt, as apple_reports.m): what it answers.
int32_t mb_stillfail_tell(moonbit_string_t what_, moonbit_string_t a_, moonbit_string_t b_, int32_t n, int32_t m) {
  (void)b_;
  (void)m;
  char *what = sf_win_mb_to_utf8(what_);
  if (!what) return 0;

  if (strcmp(what, "hello") == 0) {
    free(what);
    if (sf_win_has_key()) {
      sf_win_install_monitoring();
      return 1;
    }
    return 0;
  }
  if (strcmp(what, "reporting") == 0) {
    free(what);
    if (!sf_win_has_key()) return -1;
    return sf_win_reporting() ? 1 : 0;
  }
  if (strcmp(what, "set_reporting") == 0) {
    free(what);
    if (!sf_win_has_key()) return 0;
    AcquireSRWLockExclusive(&sf_state_lock);
    sf_win_state_load_locked();
    sf_reporting_on = n != 0 ? 1 : 0;
    sf_win_state_save_locked();
    ReleaseSRWLockExclusive(&sf_state_lock);
    return 0;
  }
  if (strcmp(what, "signed_in") == 0) {
    free(what);
    if (!sf_win_has_key()) return 0;
    sf_win_install_monitoring();
    char *account = sf_win_mb_to_utf8(a_);
    if (account && account[0]) {
      AcquireSRWLockExclusive(&sf_state_lock);
      sf_win_state_load_locked();
      snprintf(sf_signed_in, sizeof sf_signed_in, "%s", account);
      if (strcmp(sf_persisted_account, account) != 0) {
        snprintf(sf_persisted_account, sizeof sf_persisted_account, "%s", account);
        sf_win_state_save_locked();
      }
      ReleaseSRWLockExclusive(&sf_state_lock);
    }
    free(account);
    sf_win_trigger_flush_crashes();
    return 0;
  }
  if (strcmp(what, "core_failed") == 0) {
    free(what);
    char *reason = sf_win_mb_to_utf8(a_);
    if (reason) {
      sf_win_handled("CoreFailed", reason, "core_failed");
      free(reason);
    }
    return 0;
  }
  if (strcmp(what, "ui_fault") == 0) {
    free(what);
    char *cat = sf_win_mb_to_utf8(a_);
    if (cat) {
      sf_win_handled("UiFault", cat, "ui_fault");
      free(cat);
    }
    return 0;
  }
  if (strcmp(what, "hang") == 0) {
    free(what);
    char *json = sf_win_mb_to_utf8(a_);
    if (json) {
      sf_win_hang(json, "ui_hang");
      free(json);
    }
    return 0;
  }
  if (strcmp(what, "hang_summary") == 0) {
    free(what);
    char *json = sf_win_mb_to_utf8(a_);
    if (json) {
      sf_win_hang(json, "ui_hang_summary");
      free(json);
    }
    return 0;
  }
  if (strcmp(what, "bar_switch_ready") == 0) {
    free(what);
    return sf_win_has_key() ? 1 : 0;
  }
  if (strcmp(what, "bar_switch") == 0) {
    free(what);
    char *json = sf_win_mb_to_utf8(a_);
    if (json) {
      sf_win_hang(json, "bar_switch");
      free(json);
    }
    return 0;
  }
  if (strcmp(what, "crash_pending") == 0) {
    free(what);
    return sf_win_pending_crash_mask();
  }
  free(what);
  return 0;
}

#endif  // SF_REPORTS_PURE
