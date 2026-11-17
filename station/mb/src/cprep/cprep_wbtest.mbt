// cprep on made-up C as moonc writes it. (That mbc then splits the reader's C so that a function that raises new
// leaves the other units as they were is station/mb/build.sh's, run on the reader itself.)

///|
let prelude : String =
  #|#include <stdint.h>
  #|#include "moonbit.h"
  #|

///|
fn prog(results : Array[(String, Bool)], body? : String = "  return r;") -> Bytes {
  let s = StringBuilder()
  s.write_string(prelude)
  s.write_string("struct _M0TP11a1T;\n\nstruct _M0TWiEQP11a1T;\n\n")
  let first = results[0].0
  s.write_string(
    "struct _M0TWiEQP11a1T {\n  struct moonbit_result_\{first}(* code)(\n    struct _M0TWiEQP11a1T*,\n    int32_t\n  );\n};\n\n",
  )
  for r in results {
    let (n, broken) = r
    if broken {
      s.write_string(
        "struct moonbit_result_\{n} {\n  int tag;\n  union {\n    struct _M0TP11a1T* ok;\n    void* err;\n    \n  } data;\n  \n};\n\n",
      )
    } else {
      s.write_string(
        "struct moonbit_result_\{n} {\n  int tag;\n  union { struct _M0TP11a1T* ok; void* err;  } data;\n  \n};\n\n",
      )
    }
  }
  s.write_string("static struct moonbit_result_\{first} _M0FP11b4call(int32_t);\n\n")
  s.write_string("const char _M0G3[] = \"moonbit_result_7 // not code\";\n\n")
  s.write_string(
    "static struct moonbit_result_\{first} _M0FP11b4call(int32_t x) {\n  struct moonbit_result_\{first} r;\n  /* moonbit_result_8 */\n  r.tag = x; // moonbit_result_9\n\{body}\n}\n\n",
  )
  s.write_string("void moonbit_init() {\n}\n")
  @utf8.encode(s.to_string())
}

///|
fn str(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
fn count(hay : String, needle : String) -> Int {
  let mut n = 0
  let mut rest = hay.exact_view()
  while rest.find(needle.exact_view()) is Some(k) {
    n += 1
    rest = rest.exact_view(start=k + needle.length())
  }
  n
}

///|
test "a result is a function type, named as code names it, never in a literal or a comment" {
  let (out, named) = prep(prog([("3", false)]))
  let o = str(out)
  assert_eq(named, [])
  assert_true(o.contains("struct _M0TWresult$3 { int tag; union { struct _M0TP11a1T* ok; void* err; } data; };"))
  assert_true(o.contains("static struct _M0TWresult$3 _M0FP11b4call(int32_t);"))
  assert_true(o.contains("\"moonbit_result_7 // not code\""))
  assert_true(o.contains("/* moonbit_result_8 */"))
  assert_true(o.contains("// moonbit_result_9"))
  assert_false(o.contains("moonbit_result_3"))
  // (a function type's definition on one line too)
  assert_true(o.contains("struct _M0TWiEQP11a1T { struct _M0TWresult$3(* code)( struct _M0TWiEQP11a1T*, int32_t ); };"))
  // (the prelude as it was, CSPLIT_OPTNONE said after it)
  assert_true(o.has_prefix(prelude + "#if defined(__clang__)\n#define CSPLIT_OPTNONE __attribute__((optnone))\n"))
}

///|
test "two numberings and line breaks of one definition are one text" {
  // (moonc broke the line of one numbered 185 where it did not that of one numbered 3: mbc keeps a definition once by
  // its text, and names a function type by it)
  let (a, _) = prep(prog([("3", false)]))
  let (b, _) = prep(prog([("185", true), ("9", false)]))
  let one = str(a)
  let two = str(b).replace_all(old="$185", new="$3")
  let def = "struct _M0TWresult$3 { int tag; union { struct _M0TP11a1T* ok; void* err; } data; };"
  assert_eq(count(one, def), 1)
  assert_eq(count(two, def), 1)
  assert_true(two.contains("struct _M0TWresult$9 { int tag; union { struct _M0TP11a1T* ok; void* err; } data; };"))
}

///|
test "a huge function's prototype says CSPLIT_OPTNONE; one under it, a global's data and moonbit_init do not" {
  let big = "  r.tag = 1;\n".repeat(64)
  let (out, named) = prep(prog([("3", false)], body=big + "  return r;"), huge=512)
  let o = str(out)
  assert_eq(named, ["_M0FP11b4call"])
  assert_true(o.contains("static CSPLIT_OPTNONE struct _M0TWresult$3 _M0FP11b4call(int32_t);"))
  assert_eq(count(o, "CSPLIT_OPTNONE struct"), 1)
  assert_true(o.contains("const char _M0G3[] ="))
  assert_true(o.contains("void moonbit_init() {"))
  let (small, none) = prep(prog([("3", false)]), huge=512)
  assert_eq(none, [])
  assert_false(str(small).contains("CSPLIT_OPTNONE struct"))
}

///|
test "a huge function with no prototype is given one before it" {
  let src = @utf8.encode(
    prelude +
    "struct _M0TP11a1T;\n\nint32_t _M0FP11c3big(int32_t x) {\n" +
    "  x = x + 1;\n".repeat(64) +
    "  return x;\n}\n\nint32_t moonbit_data[] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150 };\n",
  )
  let (out, named) = prep(src, huge=512)
  assert_eq(named, ["_M0FP11c3big"])
  assert_true(str(out).contains("CSPLIT_OPTNONE int32_t _M0FP11c3big(int32_t x);\n\nint32_t _M0FP11c3big(int32_t x) {"))
}
