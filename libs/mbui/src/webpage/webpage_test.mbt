// What the package asks of its host, under a host of the test's own: what it says set, what it is told kept. (Not a
// Tester: its program would link all of ui to test six calls passed on.)

///|
struct Page {
  said : Map[String, String]
  told : Array[(String, String)]
}

///|
impl @hostapi.Host for Page with app_said(self, name) {
  self.said.get(name).unwrap_or("")
}

///|
impl @hostapi.Host for Page with app_tell(self, name, arg) {
  self.told.push((name, arg))
}

///|
fn page() -> Page {
  let p = { said: {}, told: [] }
  @hostapi.set_host(p)
  p
}

///|
test "where the page is, as the host says it; nothing where it says none" {
  let p = page()
  assert_eq(@webpage.location(), "")
  p.said["mbui.page.location"] = "/a?b#c"
  assert_eq(@webpage.location(), "/a?b#c")
}

///|
test "the title, the colour and the history asked of the host, in order" {
  let p = page()
  @webpage.set_title("收件箱")
  @webpage.set_theme_color("#101012")
  @webpage.history_push("/a")
  @webpage.history_replace("/b?x=1")
  @webpage.history_back()
  assert_eq(p.told, [
    ("mbui.page.title", "收件箱"),
    ("mbui.page.theme_color", "#101012"),
    ("mbui.page.history_push", "/a"),
    ("mbui.page.history_replace", "/b?x=1"),
    ("mbui.page.history_back", ""),
  ])
}
