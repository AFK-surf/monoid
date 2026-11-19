// The liquid glass library's parts (src/lg) in a window, over the gallery's wallpaper (src/pages):
// MBUI_LG_PAGE=overview (the default), dialog, interactive or film; MBUI_DARK=1 the dark look.
//   APP=gallery MBUI_APP_MOD=libs/liquid-glass libs/mbui/scripts/mac.sh run

///|
fn main {
  @lg.set_dark(Some(@ui.env("MBUI_DARK") == "1"))
  let name = @ui.env("MBUI_LG_PAGE")
  @ui.run_tree("Liquid Glass", fn(root) { @pages.page(root, if name == "" { "overview" } else { name }) })
}
