// The component library's parts (libs/sf-ui/src), each on its own beside its states, for people to look at and press
// (src/sfstorybook: the page and its stories). No core: the real core's answers to its pure calls, kept (src/sfkept).
// Built for the browser by scripts/kit-web.sh and served at kit.monoid.zone (cloud/wrangler.kit.jsonc). ?STORY=<key>
// (MBUI_ env on the native hosts) opens that part first; MBUI_DARK=1 the dark theme; MBUI_PLATFORM=android|ios started
// as a phone's, touch its native input.

///|
fn main {
  @sf.kept_call.val = Some(@sfkept.answer)
  match @ui.env("MBUI_PLATFORM") {
    "android" => @ui.set_platform(Some(2))
    "ios" => @ui.set_platform(Some(1))
    _ => ()
  }
  @hostapi.window_setup(360.0, 560.0, 1280.0, 820.0)
  @ui.run_legacy_ctx("still.fail 组件", @sfstorybook.stories_view, tree=@sfstorybook.stories_tree(@ui.env("STORY")))
}
