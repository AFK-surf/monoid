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

int main(void) {
  test_json_escape();
  test_uuid_and_iso();
  test_batch_exception();
  test_batch_hang();
  test_reports_json_roundtrip();
  if (!bad) printf("reports_test_win: ok\n");
  return bad;
}
