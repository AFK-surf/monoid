// The liquid glass library's parts (src/lg) in a window, over the gallery's wallpaper (src/pages), under the gallery's
// bar choosing the page and the look (src/pages gallery.mbt). As it starts: MBUI_LG_PAGE=overview (the default),
// dialog, interactive or film; MBUI_DARK=1 the dark look; MBUI_LG_CHROME=0 no bar. On the web these are the page's
// query (?MBUI_LG_PAGE=interactive&MBUI_DARK=1: scripts/web.sh).
//   APP=gallery MBUI_APP_MOD=libs/liquid-glass libs/mbui/scripts/mac.sh run

///|
fn main {
  @lg.set_dark(Some(@ui.env("MBUI_DARK") == "1"))
  let name = @ui.env("MBUI_LG_PAGE")
  let first = if name == "" { "overview" } else { name }
  let chrome = @ui.env("MBUI_LG_CHROME") != "0"
  @ui.run_tree("Liquid Glass", fn(root) { @pages.gallery(root, first, chrome~) })
}
