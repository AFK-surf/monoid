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

#define SF_WIN_QUEUE_CAP 64

static INIT_ONCE sf_cfg_once = INIT_ONCE_STATIC_INIT;
static char sf_posthog_host[512];
static char sf_posthog_key[256];

static INIT_ONCE sf_here_once = INIT_ONCE_STATIC_INIT;
static char *sf_here_cached = NULL;

static SRWLOCK sf_state_lock = SRWLOCK_INIT;
static int sf_state_loaded = 0;
static int sf_reporting_on = 1;
static char sf_persisted_account[256];
static char sf_signed_in[256];

static SRWLOCK sf_queue_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE sf_queue_cv = CONDITION_VARIABLE_INIT;
static char *sf_queue[SF_WIN_QUEUE_CAP];
static size_t sf_queue_head = 0;
static size_t sf_queue_count = 0;
static int sf_sender_started = 0;
static volatile LONG sf_sender_stop = 0;

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
        sf_win_parse_reports_json(buf, &sf_reporting_on, sf_persisted_account, sizeof sf_persisted_account);
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
  char *json = sf_win_format_reports_json(sf_reporting_on, sf_persisted_account);
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

static void sf_win_post_batch(char *body) {
  sf_win_cfg_ensure();
  if (!sf_posthog_host[0] || !body) return;
  char url_utf8[600];
  snprintf(url_utf8, sizeof url_utf8, "%s/batch/", sf_posthog_host);
  WCHAR wurl[600];
  if (MultiByteToWideChar(CP_UTF8, 0, url_utf8, -1, wurl, (int)(sizeof wurl / sizeof wurl[0])) <= 0) return;

  URL_COMPONENTS uc;
  memset(&uc, 0, sizeof uc);
  uc.dwStructSize = sizeof uc;
  WCHAR whost[256], wpath[512];
  uc.lpszHostName = whost;
  uc.dwHostNameLength = (DWORD)(sizeof whost / sizeof whost[0]);
  uc.lpszUrlPath = wpath;
  uc.dwUrlPathLength = (DWORD)(sizeof wpath / sizeof wpath[0]);
  if (!WinHttpCrackUrl(wurl, 0, 0, &uc)) return;

  HINTERNET s = WinHttpOpen(L"stillfail-reports/1", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                            WINHTTP_NO_PROXY_BYPASS, 0);
  if (!s) return;
  WinHttpSetTimeouts(s, 15000, 15000, 15000, 15000);
  HINTERNET c = WinHttpConnect(s, whost, uc.nPort, 0);
  HINTERNET r = c ? WinHttpOpenRequest(c, L"POST", wpath, NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                       uc.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0)
                  : NULL;
  if (r) {
    DWORD blen = (DWORD)strlen(body);
    if (WinHttpSendRequest(r, L"Content-Type: application/json\r\n", (DWORD)-1, body, blen, blen, 0)) {
      WinHttpReceiveResponse(r, NULL);
    }
    WinHttpCloseHandle(r);
  }
  if (c) WinHttpCloseHandle(c);
  WinHttpCloseHandle(s);
}

static DWORD WINAPI sf_win_sender_thread(LPVOID param) {
  (void)param;
  while (!InterlockedCompareExchange(&sf_sender_stop, 0, 0)) {
    char *body = NULL;
    AcquireSRWLockExclusive(&sf_queue_lock);
    while (sf_queue_count == 0 && !InterlockedCompareExchange(&sf_sender_stop, 0, 0)) {
      SleepConditionVariableSRW(&sf_queue_cv, &sf_queue_lock, INFINITE, 0);
    }
    if (sf_queue_count > 0) {
      body = sf_queue[sf_queue_head];
      sf_queue[sf_queue_head] = NULL;
      sf_queue_head = (sf_queue_head + 1) % SF_WIN_QUEUE_CAP;
      sf_queue_count--;
    }
    ReleaseSRWLockExclusive(&sf_queue_lock);
    if (body) {
      if (sf_win_reporting()) sf_win_post_batch(body);
      free(body);
    }
  }
  return 0;
}

static void sf_win_enqueue(char *body) {
  if (!body) return;
  AcquireSRWLockExclusive(&sf_queue_lock);
  if (!sf_sender_started) {
    HANDLE th = CreateThread(NULL, 0, sf_win_sender_thread, NULL, 0, NULL);
    if (th) {
      CloseHandle(th);
      sf_sender_started = 1;
    } else {
      ReleaseSRWLockExclusive(&sf_queue_lock);
      free(body);
      return;
    }
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
    return sf_win_has_key() ? 1 : 0;
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
  free(what);
  return 0;
}

#endif  // SF_REPORTS_PURE
