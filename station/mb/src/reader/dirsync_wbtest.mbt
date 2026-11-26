///|
test "dirsync reuse_key separates regular files from symlinks" {
  let h = "ce013625030ba8dba906f756967f9e9ca394464a"
  assert_eq(reuse_key(h, file_mode), "file:" + h)
  assert_eq(reuse_key(h, exec_mode), "file:" + h)
  assert_eq(reuse_key(h, link_mode), "link:" + h)
  assert_not_eq(reuse_key(h, file_mode), reuse_key(h, link_mode))
}

///|
test "dirsync sync_commit_pages respects UTF-8 byte budget across set, remove, final, and submodules" {
  let h = "1111111111111111111111111111111111111111"
  let id = "0123456789abcdef"
  let budget = 300
  let set : Array[Json] = [
    Json::array([jstr("目录/文件一😀.txt"), jstr(h), jstr(file_mode)]),
    Json::array([jstr("目录/\"引号\"\\转义😀.txt"), jstr(h), jstr(exec_mode)]),
    Json::array([jstr("目录/文件三😀.txt"), jstr(h), jstr(link_mode)]),
  ]
  let remove : Array[String] = [
    "旧目录/删除一😀.txt",
    "旧目录/删除二😀.txt",
    "旧目录/删除三😀.txt",
    "旧目录/删除四😀.txt",
  ]
  let subs : Array[(String, String, String)] = [
    ("vendor/sub-a", h, "https://example.invalid/org/sub-a.git"),
    ("vendor/sub-b", h, "https://example.invalid/org/sub-b.git"),
  ]
  let pages = sync_commit_pages(id, set, remove, subs, budget~)
  assert_true(pages.length() >= 3)
  for i, page in pages {
    let encoded = js_text(Json::object(page))
    assert_true(bytes_len(encoded) <= budget)
    assert_eq(page.get("final"), Some(jbool(i == pages.length() - 1)))
    if i < pages.length() - 1 {
      assert_eq(page.get("submodules"), None)
    } else {
      assert_true(page.get("submodules") is Some(Array(_)))
    }
  }
  // Submodules overflow forces an extra empty final page carrying submodules
  let small_set : Array[Json] = [Json::array([jstr("a.txt"), jstr(h), jstr(file_mode)])]
  let sub_pages = sync_commit_pages(id, small_set, [], subs, budget=300)
  assert_eq(sub_pages.length(), 2)
  assert_eq(sub_pages[0].get("final"), Some(jbool(false)))
  assert_eq(sub_pages[0].get("submodules"), None)
  assert_eq(sub_pages[1].get("final"), Some(jbool(true)))
  assert_eq(sub_pages[1].get("set"), Some(Json::array([])))
  assert_eq(sub_pages[1].get("remove"), Some(Json::array([])))
  assert_true(bytes_len(js_text(Json::object(sub_pages[0]))) <= 300)
  assert_true(bytes_len(js_text(Json::object(sub_pages[1]))) <= 300)

  // Single item exceeding budget is placed alone without looping
  let giant : Array[Json] = [
    Json::array([jstr("超长路径_" + "汉".repeat(80) + ".txt"), jstr(h), jstr(file_mode)]),
    Json::array([jstr("small.txt"), jstr(h), jstr(file_mode)]),
  ]
  let giant_pages = sync_commit_pages(id, giant, [], [], budget=160)
  assert_eq(giant_pages.length(), 2)
  assert_eq(giant_pages[0].get("set"), Some(Json::array([giant[0]])))
  assert_eq(giant_pages[1].get("set"), Some(Json::array([giant[1]])))
  assert_true(bytes_len(js_text(Json::object(giant_pages[1]))) <= 160)
}

///|
test "dirsync page_of respects UTF-8 byte budget with frame overhead" {
  let h = "2222222222222222222222222222222222222222"
  let entries : Array[Json] = [
    Json::array([jstr("中文路径一😀.txt"), jstr(h), jstr(file_mode)]),
    Json::array([jstr("中文路径二😀.txt"), jstr(h), jstr(file_mode)]),
    Json::array([jstr("中文路径三😀.txt"), jstr(h), jstr(file_mode)]),
  ]
  let budget = 140
  let mut after = 0
  let mut pages = 0
  while after < entries.length() {
    let page = page_of(entries, after, budget~)
    assert_true(bytes_len(js_text(page)) <= budget)
    pages += 1
    match field_of(page, "next") {
      Number(n, ..) => after = n.to_int()
      _ => break
    }
  }
  assert_eq(pages, 3)
}
