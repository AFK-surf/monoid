///|
test "default_words covers every built-in key in zh and en" {
  let prev = words_of.val
  set_words(default_words)
  set_language(Some("zh"))
  assert_eq(t("common.cancel"), "取消")
  assert_eq(t("common.copy"), "复制")
  assert_eq(t("web-pages.drive.reader.paper.white"), "纸白")
  for k, expected in default_words_zh {
    let got = t(k)
    assert_eq(got, expected)
    assert_true(got != "" && got != k, msg="zh key \{k} returned \{got}")
  }
  set_language(Some("en"))
  assert_eq(t("common.cancel"), "Cancel")
  assert_eq(t("common.copy"), "Copy")
  assert_eq(t("web-pages.drive.reader.paper.white"), "Paper")
  for k, _ in default_words_zh {
    let got = t(k)
    assert_true(got != "" && got != k, msg="en key \{k} returned \{got}")
  }
  set_language(None)
  set_words(prev)
}

///|
test "default_words substitutes placeholders, handles plural .one, and falls back to raw key" {
  let prev = words_of.val
  set_words(default_words)
  set_language(Some("zh"))
  assert_eq(t("web-main.file.remove", args=[("name", "a.txt")]), "移除 a.txt")
  assert_eq(t("web-main.quote.author", args=[("author", "Ana")]), "Ana：")
  assert_eq(t("web-pages.drive.reader.foundCount", args=[("n", "1")]), "找到 1 处")
  assert_eq(t("web-pages.drive.reader.foundCount", args=[("n", "3")]), "找到 3 处")
  assert_eq(t("web-pages.drive.reader.foundAt", args=[("query", "foo"), ("at", "2"), ("n", "5")]), "「foo」2 / 5")
  assert_eq(t("ui.monoid.nonexistent.key"), "ui.monoid.nonexistent.key")

  set_language(Some("en"))
  assert_eq(t("web-main.file.remove", args=[("name", "a.txt")]), "Remove a.txt")
  assert_eq(t("web-main.quote.author", args=[("author", "Ana")]), "Ana: ")
  assert_eq(t("web-pages.drive.reader.foundCount", args=[("n", "1")]), "1 found")
  assert_eq(t("web-pages.drive.reader.foundCount", args=[("n", "3")]), "3 found")
  assert_eq(t("web-pages.drive.reader.foundAt", args=[("query", "foo"), ("at", "2"), ("n", "5")]), "“foo” 2 of 5")
  assert_eq(t("ui.monoid.nonexistent.key"), "ui.monoid.nonexistent.key")
  set_language(None)
  set_words(prev)
}

///|
test "default_words works with t_around splitting" {
  let prev = words_of.val
  set_words(default_words)
  set_language(Some("zh"))
  assert_eq(t_around("web-pages.stations.latency", "latency"), ("当前延迟 ", ""))
  assert_eq(t_around("web-main.file.remove", "name"), ("移除 ", ""))
  assert_eq(t_around("common.cancel", "missing"), ("取消", ""))

  set_language(Some("en"))
  assert_eq(t_around("web-pages.stations.latency", "latency"), ("Latency ", ""))
  assert_eq(t_around("web-main.file.remove", "name"), ("Remove ", ""))
  assert_eq(t_around("common.cancel", "missing"), ("Cancel", ""))
  set_language(None)
  set_words(prev)
}

///|
test "set_words overrides default_words and increments words_told_count" {
  let prev = words_of.val
  set_words(default_words)
  set_language(Some("en"))
  assert_eq(t("common.cancel"), "Cancel")
  let before = words_told_count()
  set_words(fn(key, args) {
    if key == "common.cancel" {
      "Dismiss"
    } else {
      default_words(key, args)
    }
  })
  assert_eq(words_told_count(), before + 1)
  assert_eq(t("common.cancel"), "Dismiss")
  assert_eq(t("common.copy"), "Copy")
  set_language(None)
  set_words(prev)
}
