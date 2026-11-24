///|
fn set_old_mtime(path : Bytes) -> Unit raise {
  let (code, _) = run_capture([b"touch", b"-t", b"202001010000", path])
  assert_eq(code, 0)
}

///|
test "c_include_dirs extracts -I, -isystem, -iquote, and -include forms" {
  let (dirs, forced) = c_include_dirs([
    b"-O2",
    b"-I/inc1",
    b"-I",
    b"/inc2",
    b"-isystem/sys1",
    b"-isystem",
    b"/sys2",
    b"-iquote/q1",
    b"-iquote",
    b"/q2",
    b"-include/f1.h",
    b"-include",
    b"/f2.h",
    b"-DFOO=1",
  ])
  assert_eq(dirs, [b"/inc1", b"/inc2", b"/sys1", b"/sys2", b"/q1", b"/q2"])
  assert_eq(forced, [b"/f1.h", b"/f2.h"])
}

///|
test "core_obj fast path hits on unchanged inputs, touches out and MBC_STORE, and invalidates on any change" {
  if windows {
    return
  }
  let cc = match which(b"cc") {
    Some(p) => p
    None => return
  }
  let top = tmp_path("core-obj-fast")
  let inc_dir = path_join(top, b"inc")
  let forced_dir = path_join(top, b"forced")
  let store = path_join(top, b"store")
  let core_dir = path_join(top, b"__moonbit_link_core__")
  let log_file = path_join(top, b"mbc.log")
  makedirs(inc_dir)
  makedirs(forced_dir)
  makedirs(store)
  makedirs(core_dir)

  let hdr = path_join(inc_dir, b"val.h")
  let forced_hdr = path_join(forced_dir, b"extra.h")
  let c_file = path_join(top, b"prog.c")
  let out = path_join(core_dir, b"prog.o")
  let stamp = cat([out, b".mbc-core"])
  let objdir = cat([sub(out, 0, out.length() - 2), b".mbc"])

  let make_prog_c = fn(delta : Int) -> Bytes {
    utf8(
      "#include \"val.h\"\n" +
      prelude_src +
      "struct _M0TP1a1T;\n" +
      "struct _M0TP1a1T { int32_t x; };\n" +
      "int32_t _M0FP1a3add(int32_t a, int32_t b) { return a + b + VAL + EXTRA + \{delta}; }\n" +
      "void moonbit_init() {}\n" +
      "int main(int argc, char** argv) { (void)argc; (void)argv; return _M0FP1a3add(1, 2); }\n",
    )
  }

  assert_true(write_file(hdr, b"#define VAL 1\n"))
  assert_true(write_file(forced_hdr, b"#define EXTRA 10\n"))
  assert_true(write_file(c_file, make_prog_c(0)))

  let prev_store = getenv("MBC_STORE")
  let prev_log = getenv("MBC_LOG")
  let _ = c_setenv(b"MBC_STORE", store)
  let _ = c_setenv(b"MBC_LOG", log_file)

  let run_core = fn(extra_flag : String?) -> (Int, Bytes) {
    let _ = write_file(log_file, b"")
    hash_cache.clear()
    let args = [
      "--real",
      str(cc),
      "--",
      "-O1",
      "-I",
      str(inc_dir),
      "-include",
      str(forced_hdr),
    ]
    match extra_flag {
      Some(f) => args.push(f)
      None => ()
    }
    args.push("-c")
    args.push(str(c_file))
    args.push("-o")
    args.push(str(out))
    let code = run_wrap(args)
    (code, read_file(log_file).unwrap_or(b""))
  }

  // 1. Cold build: produces out, <out>.mbc-core with store_rels, and populates MBC_STORE.
  let (c1, log1) = run_core(None)
  assert_eq(c1, 0)
  assert_true(is_file(out))
  assert_true(is_file(stamp))
  assert_true(!contains(log1, b"built already from the same C and flags"))
  let stamp_lines = lines(read_file(stamp).unwrap())
  assert_true(stamp_lines.length() >= 2)
  let rels = stamp_lines[1:].to_owned().filter(fn(r) { r.length() > 0 })
  assert_true(rels.length() >= 1)
  for rel in rels {
    assert_true(is_dir(path_join(store, rel)))
  }

  // 2. Warm fast-path hit: remove objdir to prove split_jobs is skipped, backdate out & store entries,
  //    then verify fast path logs hit, does not recreate objdir, and refreshes mtimes of out & store entries.
  rmtree(objdir)
  assert_true(!is_dir(objdir))
  set_old_mtime(out)
  let old_out_mtime = stat(out).unwrap().1
  let old_store_mtimes = []
  for rel in rels {
    let d = path_join(store, rel)
    set_old_mtime(d)
    old_store_mtimes.push(stat(d).unwrap().1)
  }
  let (c2, log2) = run_core(None)
  assert_eq(c2, 0)
  assert_true(contains(log2, b"built already from the same C and flags"))
  assert_true(!is_dir(objdir))
  assert_true(stat(out).unwrap().1 > old_out_mtime)
  for i, rel in rels {
    let d = path_join(store, rel)
    assert_true(stat(d).unwrap().1 > old_store_mtimes[i])
  }

  // 3a. Negative: change c_file content -> must miss & rebuild.
  assert_true(write_file(c_file, make_prog_c(2)))
  let (c3, log3) = run_core(None)
  assert_eq(c3, 0)
  assert_true(!contains(log3, b"built already from the same C and flags"))
  assert_true(is_dir(objdir))
  // Immediate re-run hits fast path again.
  let (c3b, log3b) = run_core(None)
  assert_eq(c3b, 0)
  assert_true(contains(log3b, b"built already from the same C and flags"))

  // 3b. Negative: change #include header content -> must miss & rebuild.
  assert_true(write_file(hdr, b"#define VAL 2\n"))
  let (c4, log4) = run_core(None)
  assert_eq(c4, 0)
  assert_true(!contains(log4, b"built already from the same C and flags"))

  // 3b2. Negative: change -include header content -> must miss & rebuild.
  assert_true(write_file(forced_hdr, b"#define EXTRA 20\n"))
  let (c4b, log4b) = run_core(None)
  assert_eq(c4b, 0)
  assert_true(!contains(log4b, b"built already from the same C and flags"))

  // 3c. Negative: change compile flag -> must miss & rebuild.
  let (c5, log5) = run_core(Some("-DFLAG_CHANGED=1"))
  assert_eq(c5, 0)
  assert_true(!contains(log5, b"built already from the same C and flags"))
  // Re-run with same flag hits fast path.
  let (c5b, log5b) = run_core(Some("-DFLAG_CHANGED=1"))
  assert_eq(c5b, 0)
  assert_true(contains(log5b, b"built already from the same C and flags"))

  // 3d. Negative: tamper/truncate out file -> must miss & rebuild out.
  assert_true(write_file(out, b"corrupted"))
  let (c6, log6) = run_core(Some("-DFLAG_CHANGED=1"))
  assert_eq(c6, 0)
  assert_true(!contains(log6, b"built already from the same C and flags"))
  assert_true(read_file(out).unwrap() != b"corrupted")

  // 3e. Negative: delete one recorded unit dir from MBC_STORE -> must miss & repopulate MBC_STORE.
  let cur_rels = lines(read_file(stamp).unwrap())[1:]
    .to_owned()
    .filter(fn(r) { r.length() > 0 })
  assert_true(cur_rels.length() >= 1)
  let missing_dir = path_join(store, cur_rels[0])
  rmtree(missing_dir)
  assert_true(!is_dir(missing_dir))
  let (c7, log7) = run_core(Some("-DFLAG_CHANGED=1"))
  assert_eq(c7, 0)
  assert_true(!contains(log7, b"built already from the same C and flags"))
  assert_true(is_dir(missing_dir))

  // 4. Built without MBC_STORE first, then run with MBC_STORE -> must not skip populating MBC_STORE.
  let store2 = path_join(top, b"store2")
  makedirs(store2)
  let _ = c_setenv(b"MBC_STORE", b"")
  let (c8, log8) = run_core(Some("-DNO_STORE_FIRST=1"))
  assert_eq(c8, 0)
  assert_true(!contains(log8, b"built already from the same C and flags"))
  let stamp8 = lines(read_file(stamp).unwrap())
  assert_eq(stamp8.length(), 1)
  let _ = c_setenv(b"MBC_STORE", store2)
  let (c9, log9) = run_core(Some("-DNO_STORE_FIRST=1"))
  assert_eq(c9, 0)
  assert_true(!contains(log9, b"built already from the same C and flags"))
  let stamp9 = lines(read_file(stamp).unwrap())
  assert_true(stamp9.length() >= 2)
  let (c10, log10) = run_core(Some("-DNO_STORE_FIRST=1"))
  assert_eq(c10, 0)
  assert_true(contains(log10, b"built already from the same C and flags"))

  // 5. alt_argv hit (MBC_LIGHT_TESTS) records alt_argv's store_rel and touches it on fast-path hit.
  let prev_light = getenv("MBC_LIGHT_TESTS")
  let pkg_dir = path_join(top, b"pkg")
  let light_core_dir = path_join(pkg_dir, b"__moonbit_link_core__")
  let light_out = path_join(light_core_dir, b"prog.o")
  let light_stamp = cat([light_out, b".mbc-core"])
  let light_objdir = cat([sub(light_out, 0, light_out.length() - 2), b".mbc"])
  makedirs(light_core_dir)
  let store_alt = path_join(top, b"store-alt")
  makedirs(store_alt)
  let _ = c_setenv(b"MBC_STORE", store_alt)
  let _ = c_setenv(b"MBC_LIGHT_TESTS", b"")
  let run_light = fn() -> (Int, Bytes) {
    let _ = write_file(log_file, b"")
    hash_cache.clear()
    let code = run_wrap([
      "--real",
      str(cc),
      "--",
      "-O1",
      "-I",
      str(inc_dir),
      "-include",
      str(forced_hdr),
      "-c",
      str(c_file),
      "-o",
      str(light_out),
    ])
    (code, read_file(log_file).unwrap_or(b""))
  }
  // Populate store_alt at -O1.
  let (ca1, _) = run_light()
  assert_eq(ca1, 0)
  let o1_rels = lines(read_file(light_stamp).unwrap())[1:]
    .to_owned()
    .filter(fn(r) { r.length() > 0 })
  assert_true(o1_rels.length() >= 1)
  // Clear local outputs and rebuild as MBC_LIGHT_TESTS -> should take -O1 units via alt_argv.
  rmtree(light_objdir)
  let _ = c_remove(light_out)
  let _ = c_remove(light_stamp)
  let _ = c_remove(cat([light_out, b".mbc-link"]))
  let _ = c_setenv(b"MBC_LIGHT_TESTS", b"pkg/prog")
  let (ca2, log_a2) = run_light()
  assert_eq(ca2, 0)
  assert_true(contains(log_a2, b"from MBC_STORE"))
  let light_rels = lines(read_file(light_stamp).unwrap())[1:]
    .to_owned()
    .filter(fn(r) { r.length() > 0 })
  assert_eq(light_rels, o1_rels)
  // Fast-path hit under MBC_LIGHT_TESTS touches those alt_argv store dirs.
  for rel in light_rels {
    set_old_mtime(path_join(store_alt, rel))
  }
  let (ca3, log_a3) = run_light()
  assert_eq(ca3, 0)
  assert_true(contains(log_a3, b"built already from the same C and flags"))
  for rel in light_rels {
    assert_true(stat(path_join(store_alt, rel)).unwrap().1 > 1600000000000000000L)
  }

  // Restore env & cleanup.
  let _ = c_setenv(b"MBC_LIGHT_TESTS", prev_light.unwrap_or(b""))
  let _ = c_setenv(b"MBC_STORE", prev_store.unwrap_or(b""))
  let _ = c_setenv(b"MBC_LOG", prev_log.unwrap_or(b""))
  rmtree(top)
}
