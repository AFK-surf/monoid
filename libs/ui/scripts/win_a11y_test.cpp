// src/host/win_a11y.cpp's tests on Windows:
//   cl.exe -nologo -EHsc -W4 -WX -Isrc/host scripts/win_a11y_test.cpp -Foout/a11y/ -Feout/a11y/win_a11y_test.exe -link oleaut32.lib uiautomationcore.lib runtimeobject.lib
//   out/a11y/win_a11y_test.exe
// Verifies that UIA notifications are deferred out of mb_host_a11y_tree (draw_frame), survive COM re-entrancy that
// mutates/rehashes `items` and deletes nodes mid-flush, coalesce across frames before flush, and bound parent/child
// cycles.
#define MB_WIN_A11Y_TEST 1
#define _CRT_SECURE_NO_WARNINGS
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <oleauto.h>
#include <uiautomation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <vector>

typedef const wchar_t *moonbit_string_t;
static size_t Moonbit_array_length(moonbit_string_t s) { return wcslen(s); }

static int failed = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #c);             \
      fflush(stdout);                                                    \
      failed = 1;                                                        \
    }                                                                    \
  } while (0)

static int test_clients_listening = 1;
static int test_app_calls = 0;
static void (*test_posted_fn)(void *) = NULL;
static void *test_posted_arg = NULL;

struct RaisedProp {
  PROPERTYID prop;
  std::wstring was_s;
  std::wstring now_s;
};
static std::vector<RaisedProp> raised_props;
static int raised_struct = 0;
static int raised_focus = 0;
static void (*on_raise_prop_hook)(IRawElementProviderSimple *prov, PROPERTYID prop) = NULL;

static void test_bstr(const VARIANT &v, std::wstring *out) {
  if (v.vt == VT_BSTR && v.bstrVal) *out = std::wstring(v.bstrVal, SysStringLen(v.bstrVal));
}

static BOOL test_clients(void) { return test_clients_listening ? TRUE : FALSE; }
static HRESULT test_raise_prop(IRawElementProviderSimple *prov, PROPERTYID prop, VARIANT was, VARIANT now) {
  RaisedProp r;
  r.prop = prop;
  test_bstr(was, &r.was_s);
  test_bstr(now, &r.now_s);
  raised_props.push_back(r);
  if (on_raise_prop_hook) on_raise_prop_hook(prov, prop);
  return S_OK;
}
static HRESULT test_raise_struct(IRawElementProviderSimple *, StructureChangeType, int *, int) {
  raised_struct++;
  return S_OK;
}
static HRESULT test_raise_event(IRawElementProviderSimple *, EVENTID) {
  raised_focus++;
  return S_OK;
}

extern "C" {
void mb_post(const char *, const char *, size_t, const uint8_t *, size_t) {}
int mb_app_wid(void) { return 0; }
double mb_app_scale(void) { return 1.0; }
void mb_app_wake(void) {}
void mb_app_call(void (*fn)(void *), void *arg) {
  test_app_calls++;
  test_posted_fn = fn;
  test_posted_arg = arg;
}
}

#define MB_A11Y_CLIENTS_LISTENING() test_clients()
#define MB_A11Y_RAISE_PROP(prov, prop, was, now) test_raise_prop((prov), (prop), (was), (now))
#define MB_A11Y_RAISE_STRUCT(prov, kind, rid, len) test_raise_struct((prov), (kind), (rid), (len))
#define MB_A11Y_RAISE_EVENT(prov, ev) test_raise_event((prov), (ev))

#include "win_a11y.cpp"

static std::wstring make_node_line(int id, const wchar_t *role, const wchar_t *flags, const wchar_t *label,
                                   const std::wstring &kids) {
  std::wstring sep(1, (wchar_t)0x1F);
  std::wstring s = L"N" + sep + std::to_wstring(id) + sep + role + sep + flags + sep + L"0" + sep + L"0" + sep +
                   L"100" + sep + L"30" + sep + label + sep + sep + sep + sep + sep + sep + L"a" + sep +
                   std::to_wstring(id) + sep + kids + L"\n";
  return s;
}

static std::wstring make_tree(bool full, int focus_id, const std::wstring &body) {
  std::wstring sep(1, (wchar_t)0x1F);
  return L"T" + sep + (full ? L"1" : L"0") + sep + std::to_wstring(focus_id) + L"\n" + body;
}

static void run_posted(void) {
  void (*fn)(void *) = test_posted_fn;
  void *arg = test_posted_arg;
  test_posted_fn = NULL;
  test_posted_arg = NULL;
  if (fn) fn(arg);
}

static bool reentrant_fired = false;
static void reentrant_cb(IRawElementProviderSimple *prov, PROPERTYID) {
  if (reentrant_fired) return;
  reentrant_fired = true;
  // 1. Force many insertions and rehashes of `items` while flushing (simulating Navigate/ElementProviderFromPoint).
  for (int id = 10; id < 74; id++) {
    IRawElementProviderFragment *f = fragment_of(id);
    if (f) f->Release();
  }
  // 2. Re-enter mb_host_a11y_tree during UIA notification: remove nodes 1 and 2 (currently notifying + pending),
  //    and mutate node 3's label.
  std::wstring kids = L"3";
  for (int id = 10; id < 74; id++) kids += L"," + std::to_wstring(id);
  std::wstring body = make_node_line(0, L"Group", L"", L"", kids) + make_node_line(3, L"Button", L"", L"C2", L"");
  std::wstring upd = make_tree(false, 3, body);
  mb_host_a11y_tree(upd.c_str());

  // 3. Verify the currently-notifying provider is still alive (AddRef'd by a11y_flush) despite node removal.
  VARIANT v;
  VariantInit(&v);
  HRESULT hr = prov->GetPropertyValue(UIA_NamePropertyId, &v);
  CHECK(hr == UIA_E_ELEMENTNOTAVAILABLE);
  VariantClear(&v);

  // 4. Attempting a nested flush while flushing must be a no-op.
  a11y_flush(NULL);
}

int main(void) {
  root = new Root();
  asked = true;

  // Build initial tree: root -> 1, 2, 3, and 10..73 (64 extra nodes for rehashing).
  std::wstring kids = L"1,2,3";
  std::wstring body;
  for (int id = 10; id < 74; id++) kids += L"," + std::to_wstring(id);
  body += make_node_line(0, L"Group", L"", L"", kids);
  body += make_node_line(1, L"Button", L"", L"A0", L"");
  body += make_node_line(2, L"Button", L"", L"B0", L"");
  body += make_node_line(3, L"Button", L"", L"C0", L"");
  for (int id = 10; id < 74; id++) body += make_node_line(id, L"Button", L"", L"E", L"");
  std::wstring t0 = make_tree(true, 1, body);
  mb_host_a11y_tree(t0.c_str());

  // Must NOT raise UIA events synchronously during mb_host_a11y_tree.
  CHECK(raised_props.empty());
  CHECK(raised_struct == 0);
  CHECK(raised_focus == 0);
  CHECK(test_app_calls == 1 && test_posted_fn != NULL);
  run_posted();
  CHECK(raised_struct == 1);
  CHECK(raised_focus == 1);

  // Materialize providers for 1, 2, 3 so property changes are tracked for them.
  for (int id = 1; id <= 3; id++) {
    IRawElementProviderFragment *f = fragment_of(id);
    CHECK(f != NULL);
    f->Release();
  }

  // Test 1 + Test 2: Update labels of 1, 2, 3, verify deferred delivery and COM re-entrancy safety.
  raised_props.clear();
  raised_struct = 0;
  raised_focus = 0;
  test_app_calls = 0;
  std::wstring t1 = make_tree(false, 1,
                              make_node_line(1, L"Button", L"", L"A1", L"") +
                                  make_node_line(2, L"Button", L"", L"B1", L"") +
                                  make_node_line(3, L"Button", L"", L"C1", L""));
  mb_host_a11y_tree(t1.c_str());
  CHECK(raised_props.empty());
  CHECK(test_app_calls == 1 && test_posted_fn != NULL);

  on_raise_prop_hook = reentrant_cb;
  run_posted();
  on_raise_prop_hook = NULL;
  CHECK(reentrant_fired);
  // Node 1 or 2 was deleted during the first callback; the deleted sibling must be skipped, and a follow-up flush
  // must have been posted for the re-entrant tree update (C1 -> C2, structure change, focus 3).
  CHECK(test_posted_fn != NULL);
  CHECK(items.count(1) == 0 && items.count(2) == 0);
  CHECK(items.size() >= 65);

  raised_props.clear();
  raised_struct = 0;
  raised_focus = 0;
  run_posted();
  CHECK(raised_struct == 1);
  CHECK(raised_focus == 1);
  bool saw_c2 = false;
  for (const auto &p : raised_props) {
    if (p.prop == UIA_NamePropertyId && p.now_s == L"C2") saw_c2 = true;
  }
  CHECK(saw_c2);
  CHECK(test_posted_fn == NULL);

  // Test 3: Coalescing multiple updates before flush (C2 -> C3 -> C4 keeps was="C2", now="C4"; E -> E1 -> E drops).
  raised_props.clear();
  test_app_calls = 0;
  std::wstring t2 = make_tree(false, 3,
                              make_node_line(3, L"Button", L"", L"C3", L"") +
                                  make_node_line(10, L"Button", L"", L"E1", L""));
  std::wstring t3 = make_tree(false, 3,
                              make_node_line(3, L"Button", L"", L"C4", L"") +
                                  make_node_line(10, L"Button", L"", L"E", L""));
  mb_host_a11y_tree(t2.c_str());
  mb_host_a11y_tree(t3.c_str());
  CHECK(test_app_calls == 1);
  run_posted();
  CHECK(raised_props.size() == 1);
  if (raised_props.size() == 1) {
    CHECK(raised_props[0].was_s == L"C2" && raised_props[0].now_s == L"C4");
  }

  // Test 4: Cycle safety in shown_holder, shown_kids, and place_of.
  Node c1, c2;
  c1.id = 901;
  c1.parent = 902;
  c1.flags = L"v";
  c1.x = 1;
  c1.y = 2;
  c1.kids = {902};
  c2.id = 902;
  c2.parent = 901;
  c2.flags = L"v";
  c2.x = 3;
  c2.y = 4;
  c2.kids = {901};
  nodes[901] = c1;
  nodes[902] = c2;
  CHECK(shown_holder(&nodes[901]) == 0);
  double px = 0, py = 0;
  place_of(&nodes[901], &px, &py);
  std::vector<int> ck = shown_kids(901);
  CHECK(ck.empty());

  if (failed) return 1;
  printf("win_a11y: ok\n");
  return 0;
}
