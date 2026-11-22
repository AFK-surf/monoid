// Unit tests for src/host/win_reports.c pure C JSON, UUID, timestamp, and reports.json logic.
// Built and run on Linux via `cc -Wall -Wextra -Werror -std=c11 -Iapps/mbui/src/host apps/mbui/core/reports_test_win.c`
// and on Windows via `apps/mbui/scripts/win.sh reports` (cl.exe -W4 -WX -utf-8 + check_crt).

#define SF_REPORTS_PURE
#include "../src/host/win_reports.c"

static int bad = 0;

static void check(const char *what, int cond) {
  if (!cond) {
    printf("reports_test_win: FAIL: %s\n", what);
    bad = 1;
  }
}

static void check_eq(const char *what, const char *got, const char *want) {
  if ((got == NULL) != (want == NULL) || (got && strcmp(got, want) != 0)) {
    printf("reports_test_win: FAIL: %s\n  got : %s\n  want: %s\n", what, got ? got : "(null)", want ? want : "(null)");
    bad = 1;
  }
}

static void test_json_escape(void) {
  sf_buf b;
  sf_buf_init(&b, 16);
  const char input[] = "a\"b\\c\bd\fe\nf\rg\th\x01\x1f中文";
  sf_buf_put_json_str(&b, input);
  char *out = sf_buf_take(&b);
  check_eq("json escape", out, "\"a\\\"b\\\\c\\bd\\fe\\nf\\rg\\th\\u0001\\u001f中文\"");
  free(out);
}

static void test_uuid_and_iso(void) {
  uint8_t z[16];
  memset(z, 0, sizeof z);
  char u1[37];
  sf_win_format_uuid(z, u1);
  check_eq("uuid zero bytes", u1, "00000000-0000-4000-8000-000000000000");

  uint8_t f[16];
  memset(f, 0xFF, sizeof f);
  char u2[37];
  sf_win_format_uuid(f, u2);
  check_eq("uuid 0xFF bytes", u2, "ffffffff-ffff-4fff-bfff-ffffffffffff");
  check("uuid length 36", strlen(u2) == 36);
  check("uuid version 4", u2[14] == '4');
  check("uuid variant rfc4122", u2[19] == '8' || u2[19] == '9' || u2[19] == 'a' || u2[19] == 'b');

  char ts[25];
  sf_win_format_iso_utc(2026, 11, 21, 5, 7, 9, 42, ts);
  check_eq("iso utc", ts, "2026-11-21T05:07:09.042Z");
}

static void test_batch_exception(void) {
  const char *here = "{\"release\":\"0.1.10925 (10925)\",\"app\":\"windows\",\"$os\":\"Windows\"}";
  char *j = sf_win_build_batch_exception("phc_key", "acct-1", "11111111-2222-4333-8444-555555555555",
                                         "2026-11-21T12:00:00.000Z", "CoreFailed", "boom \"line\"\n2", "core_failed", here);
  check("exception non-null", j != NULL);
  const char *want =
      "{\"api_key\":\"phc_key\",\"batch\":[{\"event\":\"$exception\",\"distinct_id\":\"acct-1\","
      "\"uuid\":\"11111111-2222-4333-8444-555555555555\",\"timestamp\":\"2026-11-21T12:00:00.000Z\","
      "\"properties\":{\"release\":\"0.1.10925 (10925)\",\"app\":\"windows\",\"$os\":\"Windows\","
      "\"reason\":\"core_failed\",\"$exception_level\":\"error\",\"$exception_list\":[{\"type\":\"CoreFailed\","
      "\"value\":\"boom \\\"line\\\"\\n2\",\"mechanism\":{\"handled\":true,\"synthetic\":true,\"type\":\"stillfail\"}}]}}]}";
  check_eq("CoreFailed batch", j, want);
  free(j);

  // Empty here_json should not produce a leading comma
  char *j2 = sf_win_build_batch_exception("phc_key", "windows-anonymous", "00000000-0000-4000-8000-000000000000",
                                          "2026-11-21T12:00:00.000Z", "UiFault", "layout", "ui_fault", "{}");
  check("UiFault empty here non-null", j2 != NULL);
  check("UiFault no stray comma", j2 && strstr(j2, "\"properties\":{\"reason\":\"ui_fault\"") != NULL);
  free(j2);

  // UTF-8 safe truncation at 1000 bytes: 998 ASCII 'a' + 3-byte Chinese "中" (0xE4 0xB8 0xAD) + 'z'
  // Byte 998..1000 straddles 1000, so truncation must stop at 998.
  char big[1100];
  memset(big, 'a', 998);
  memcpy(big + 998, "\xE4\xB8\xAD", 3);
  big[1001] = 'z';
  big[1002] = '\0';
  check("utf8 trunc straddling 3-byte char", sf_utf8_trunc_len(big, 1000) == 998);

  // 997 ASCII 'a' + 3-byte Chinese "中" (bytes 997,998,999) + 'z' (byte 1000) -> exact 1000 bytes kept.
  memset(big, 'a', 997);
  memcpy(big + 997, "\xE4\xB8\xAD", 3);
  big[1000] = 'z';
  big[1001] = '\0';
  check("utf8 trunc exact 3-byte boundary", sf_utf8_trunc_len(big, 1000) == 1000);

  // 998 ASCII 'a' + 4-byte emoji U+1F600 (0xF0 0x9F 0x98 0x80) -> stops at 998.
  memset(big, 'a', 998);
  memcpy(big + 998, "\xF0\x9F\x98\x80", 4);
  big[1002] = '\0';
  check("utf8 trunc straddling 4-byte char", sf_utf8_trunc_len(big, 1000) == 998);

  char *j3 = sf_win_build_batch_exception("phc_key", "acct-1", "00000000-0000-4000-8000-000000000000",
                                          "2026-11-21T12:00:00.000Z", "CoreFailed", big, "core_failed", "{}");
  check("truncated batch non-null", j3 != NULL);
  const char *vpos = j3 ? strstr(j3, "\"value\":\"") : NULL;
  check("truncated value present", vpos != NULL);
  if (vpos) {
    vpos += 9;
    const char *vend = strchr(vpos, '"');
    check("truncated value length 998", vend != NULL && (size_t)(vend - vpos) == 998);
  }
  free(j3);
}

static void test_batch_hang(void) {
  const char *here = "{\"app\":\"windows\",\"$os\":\"Windows\"}";
  const char *payload = "  {\"ms\":420,\"slow_frames\":[12,34],\"unheld\":{\"chat\":[3,1024]}}  ";
  char *j = sf_win_build_batch_hang("phc_key", "acct-1", "11111111-2222-4333-8444-555555555555",
                                    "2026-11-21T12:00:00.000Z", "ui_hang", payload, here);
  const char *want =
      "{\"api_key\":\"phc_key\",\"batch\":[{\"event\":\"ui_hang\",\"distinct_id\":\"acct-1\","
      "\"uuid\":\"11111111-2222-4333-8444-555555555555\",\"timestamp\":\"2026-11-21T12:00:00.000Z\","
      "\"properties\":{\"app\":\"windows\",\"$os\":\"Windows\","
      "\"ms\":420,\"slow_frames\":[12,34],\"unheld\":{\"chat\":[3,1024]}}}]}";
  check_eq("ui_hang batch", j, want);
  free(j);

  // Empty payload `{}` should not leave a trailing comma
  char *j_empty = sf_win_build_batch_hang("phc_key", "acct-1", "11111111-2222-4333-8444-555555555555",
                                          "2026-11-21T12:00:00.000Z", "ui_hang_summary", " { } ", here);
  const char *want_empty =
      "{\"api_key\":\"phc_key\",\"batch\":[{\"event\":\"ui_hang_summary\",\"distinct_id\":\"acct-1\","
      "\"uuid\":\"11111111-2222-4333-8444-555555555555\",\"timestamp\":\"2026-11-21T12:00:00.000Z\","
      "\"properties\":{\"app\":\"windows\",\"$os\":\"Windows\"}}]}";
  check_eq("ui_hang_summary empty payload", j_empty, want_empty);
  free(j_empty);

  // Invalid payloads rejected
  check("reject NULL payload", sf_win_build_batch_hang("k", "d", "u", "t", "ui_hang", NULL, here) == NULL);
  check("reject empty payload", sf_win_build_batch_hang("k", "d", "u", "t", "ui_hang", "", here) == NULL);
  check("reject array payload", sf_win_build_batch_hang("k", "d", "u", "t", "ui_hang", "[1,2]", here) == NULL);
  check("reject unclosed payload", sf_win_build_batch_hang("k", "d", "u", "t", "ui_hang", "{\"a\":1", here) == NULL);
  check("reject scalar payload", sf_win_build_batch_hang("k", "d", "u", "t", "ui_hang", "123", here) == NULL);
}

static void test_reports_json_roundtrip(void) {
  int reporting = -1;
  char acct[128];

  sf_win_parse_reports_json(NULL, &reporting, acct, sizeof acct);
  check("null defaults reporting=1", reporting == 1);
  check_eq("null defaults account empty", acct, "");

  sf_win_parse_reports_json("{}", &reporting, acct, sizeof acct);
  check("empty obj defaults reporting=1", reporting == 1);
  check_eq("empty obj defaults account empty", acct, "");

  sf_win_parse_reports_json(" { \"sent\" : [\"id1\", \"id2\"], \"reporting\" : false , \"account\" : \"user\\\"a\\\\b\" } ",
                            &reporting, acct, sizeof acct);
  check("parse reporting=false", reporting == 0);
  check_eq("parse escaped account", acct, "user\"a\\b");

  char *fmt = sf_win_format_reports_json(0, "user\"a\\b");
  check_eq("format reports.json", fmt, "{\"reporting\":false,\"account\":\"user\\\"a\\\\b\"}");
  int r2 = 1;
  char a2[128];
  sf_win_parse_reports_json(fmt, &r2, a2, sizeof a2);
  check("roundtrip reporting=0", r2 == 0);
  check_eq("roundtrip account", a2, "user\"a\\b");
  free(fmt);

  char *fmt2 = sf_win_format_reports_json(1, "");
  check_eq("format reports.json without account", fmt2, "{\"reporting\":true}");
  free(fmt2);
}

static void test_exception_names_and_crash_json(void) {
  char name[64];
  sf_win_format_exception_name(0xC0000005u, name, sizeof name);
  check_eq("access violation name", name, "EXCEPTION_ACCESS_VIOLATION");
  sf_win_format_exception_name(0xC00000FDu, name, sizeof name);
  check_eq("stack overflow name", name, "EXCEPTION_STACK_OVERFLOW");
  sf_win_format_exception_name(0xC0000409u, name, sizeof name);
  check_eq("stack buffer overrun name", name, "STATUS_STACK_BUFFER_OVERRUN");
  sf_win_format_exception_name(0xE06D7363u, name, sizeof name);
  check_eq("unknown exception fallback", name, "EXCEPTION_0xE06D7363");

  sf_win_crash_rec rec;
  memset(&rec, 0, sizeof rec);
  snprintf(rec.kind, sizeof rec.kind, "crash");
  snprintf(rec.uuid, sizeof rec.uuid, "11111111-2222-4333-8444-555555555555");
  snprintf(rec.at, sizeof rec.at, "2026-11-22T10:00:00.123Z");
  rec.exception_code = 0xC0000005u;
  snprintf(rec.exception_name, sizeof rec.exception_name, "EXCEPTION_ACCESS_VIOLATION");
  snprintf(rec.fault_module, sizeof rec.fault_module, "stillfail.exe");
  rec.fault_offset = 0x1234;
  rec.frame_count = 2;
  snprintf(rec.frames[0].module, sizeof rec.frames[0].module, "stillfail.exe");
  rec.frames[0].offset = 0x1234;
  snprintf(rec.frames[1].module, sizeof rec.frames[1].module, "stillfail_shell.dll");
  rec.frames[1].offset = 0x5678;

  char json_buf[2048];
  size_t n = sf_win_write_crash_json_buf(&rec, json_buf, sizeof json_buf);
  check("crash json written", n > 0);

  sf_win_crash_rec parsed;
  check("crash json parse ok", sf_win_parse_crash_json(json_buf, &parsed) == 1);
  check_eq("parsed kind", parsed.kind, "crash");
  check_eq("parsed uuid", parsed.uuid, "11111111-2222-4333-8444-555555555555");
  check_eq("parsed at", parsed.at, "2026-11-22T10:00:00.123Z");
  check("parsed exception_code", parsed.exception_code == 0xC0000005u);
  check_eq("parsed exception_name", parsed.exception_name, "EXCEPTION_ACCESS_VIOLATION");
  check_eq("parsed fault_module", parsed.fault_module, "stillfail.exe");
  check("parsed fault_offset", parsed.fault_offset == 0x1234);
  check("parsed frame_count", parsed.frame_count == 2);
  check_eq("parsed frame 0 mod", parsed.frames[0].module, "stillfail.exe");
  check("parsed frame 0 off", parsed.frames[0].offset == 0x1234);
  check_eq("parsed frame 1 mod", parsed.frames[1].module, "stillfail_shell.dll");
  check("parsed frame 1 off", parsed.frames[1].offset == 0x5678);

  char fp[256];
  sf_win_build_crash_fingerprint(&parsed, fp, sizeof fp);
  check_eq("crash fingerprint", fp, "windows:EXCEPTION_ACCESS_VIOLATION:stillfail.exe + 0x1234|stillfail_shell.dll + 0x5678");

  const char *here = "{\"app\":\"windows\",\"$os\":\"Windows\"}";
  char *batch = sf_win_build_batch_crash("phc_key", "acct-1", &parsed, here);
  check("crash batch non-null", batch != NULL);
  check("crash batch fatal", batch && strstr(batch, "\"$exception_level\":\"fatal\"") != NULL);
  check("crash batch reason", batch && strstr(batch, "\"reason\":\"crash\"") != NULL);
  check("crash batch fp", batch && strstr(batch, "\"$exception_fingerprint\":\"windows:EXCEPTION_ACCESS_VIOLATION:stillfail.exe + 0x1234|stillfail_shell.dll + 0x5678\"") != NULL);
  check("crash batch seh mechanism", batch && strstr(batch, "\"type\":\"seh\"") != NULL);
  free(batch);

  // watchdog_hang record roundtrip & batch
  sf_win_crash_rec wd;
  memset(&wd, 0, sizeof wd);
  snprintf(wd.kind, sizeof wd.kind, "watchdog_hang");
  snprintf(wd.uuid, sizeof wd.uuid, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee");
  snprintf(wd.at, sizeof wd.at, "2026-11-22T10:05:00.000Z");
  wd.hang_ms = 3100;
  size_t wn = sf_win_write_crash_json_buf(&wd, json_buf, sizeof json_buf);
  check("watchdog json written", wn > 0);
  sf_win_crash_rec wp;
  check("watchdog json parse ok", sf_win_parse_crash_json(json_buf, &wp) == 1);
  check_eq("wd kind", wp.kind, "watchdog_hang");
  check("wd hang_ms", wp.hang_ms == 3100);
  sf_win_build_crash_fingerprint(&wp, fp, sizeof fp);
  check_eq("wd fingerprint", fp, "windows:MainThreadHang:watchdog");
  char *wbatch = sf_win_build_batch_crash("phc_key", "acct-1", &wp, here);
  check("wd batch non-null", wbatch != NULL);
  check("wd batch reason", wbatch && strstr(wbatch, "\"reason\":\"watchdog_hang\"") != NULL);
  check("wd batch hang_ms", wbatch && strstr(wbatch, "\"hang_ms\":3100") != NULL);
  check("wd batch type", wbatch && strstr(wbatch, "\"type\":\"MainThreadHang\"") != NULL);
  check("wd batch mechanism", wbatch && strstr(wbatch, "\"type\":\"watchdog\"") != NULL);
  free(wbatch);

  // Invalid crash JSON rejected
  check("reject bad kind", sf_win_parse_crash_json("{\"kind\":\"other\",\"uuid\":\"u\",\"at\":\"t\"}", &parsed) == 0);
  check("reject zero watchdog hang", sf_win_parse_crash_json("{\"kind\":\"watchdog_hang\",\"uuid\":\"u\",\"at\":\"t\",\"hang_ms\":0}", &parsed) == 0);
}

static void test_watchdog_state(void) {
  sf_win_wd_state st;
  memset(&st, 0, sizeof st);
  uint64_t hang_ms = 0;

  // Inactive window never triggers
  check("inactive ignored", sf_win_wd_on_probe(&st, 0, 1, 3000, 10000, &hang_ms) == 0);
  // Short timeout (<2500ms) never triggers
  check("short timeout ignored", sf_win_wd_on_probe(&st, 1, 1, 2400, 11000, &hang_ms) == 0);
  // Real >=2500ms foreground hang triggers once
  check("hang fires", sf_win_wd_on_probe(&st, 1, 1, 2600, 15000, &hang_ms) == 1);
  check("hang_ms reported", hang_ms == 2600);
  // Continued stall is deduplicated
  check("stall deduped", sf_win_wd_on_probe(&st, 1, 1, 2600, 18000, &hang_ms) == 0);
  // Recovery re-arms
  check("recovery resets", sf_win_wd_on_probe(&st, 1, 0, 5, 20000, &hang_ms) == 0);
  // 4 more stalls in 10 min fire (total 5)
  uint64_t t = 25000;
  for (int i = 0; i < 4; i++) {
    check("rate limit allows up to 5", sf_win_wd_on_probe(&st, 1, 1, 2700, t, &hang_ms) == 1);
    sf_win_wd_on_probe(&st, 1, 0, 5, t + 1000, &hang_ms);
    t += 5000;
  }
  // 6th within 10 min suppressed
  check("6th suppressed", sf_win_wd_on_probe(&st, 1, 1, 2800, t, &hang_ms) == 0);
  sf_win_wd_on_probe(&st, 1, 0, 5, t + 1000, &hang_ms);
  // After 10-minute window passes, allowed again
  check("after window fires", sf_win_wd_on_probe(&st, 1, 1, 2900, 15000 + SF_WIN_WD_WINDOW_MS + 1000, &hang_ms) == 1);
  check("after window hang_ms", hang_ms == 2900);
}

int main(void) {
  test_json_escape();
  test_uuid_and_iso();
  test_batch_exception();
  test_batch_hang();
  test_reports_json_roundtrip();
  test_exception_names_and_crash_json();
  test_watchdog_state();
  if (!bad) printf("reports_test_win: ok\n");
  return bad;
}
