// The specimen drawn offscreen by mbui's film (@film.run: a Tester with this host's text and pictures, no window), for
// people to look at: libs/mbui/scripts/ext-film.sh with MBUI_APP_MOD=libs/app-ui APP=shots.
//
//   APPUI_PAGE=wide|narrow (wide: two columns)   MBUI_DARK=1 dark   MBUI_WIN=960x720   the film's own MBUI_* else

///|
fn main {
  let wide = @film.arg("APPUI_PAGE") != "narrow"
  @appui.set_dark(Some(@film.arg("MBUI_DARK") == "1"))
  @film.run(fn(_c) {  }, tree=fn(root) { @specimen.page(root, wide~) })
}
