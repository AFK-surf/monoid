// ui.monoid · STANDARD STAGE entry point (desktop window via mac.sh and WebGL 2 via scripts/web.sh).
// Environment / URL query:
//   MBUI_DARK=1          start in dark appearance
//   MBUI_ACCENT=<key>    OKLCH accent key ("" vermilion, "blue", "teal", "purple", "pink")
//   MBUI_STD_SCENE=0|1|2 initial scene (0: Controls, 1: Tokens, 2: Overlays)

///|
fn parse_scene(s : String) -> Int {
  match s {
    "1" | "tokens" => 1
    "2" | "overlays" => 2
    _ => 0
  }
}

///|
fn main {
  let dark = @ui.env("MBUI_DARK") == "1"
  let accent = @ui.env("MBUI_ACCENT")
  let first_scene = parse_scene(@ui.env("MBUI_STD_SCENE"))
  @sf.set_language(Some("en"))
  @sf.set_product("ui.monoid")
  @sf.set_dark(Some(dark))
  if accent != "" {
    @sf.set_accent(accent)
  }
  @ui.run_tree(
    "ui.monoid — Standard UI",
    fn(root) {
      give_ui_face()
      @sf.set_dark(Some(dark))
      if accent != "" {
        @sf.set_accent(accent)
      }
      @studio_pages.studio(root, first_scene~)
    },
    theme=@sf.ui_theme_now,
  )
}
