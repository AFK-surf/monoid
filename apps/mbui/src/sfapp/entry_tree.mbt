// The ways in as nodes of the window's tree (app_state_tree's): signed out, the sign-in page (sfpages' sign_in_node);
// signed in with no workspace yet, the landing (sfpages' no_workspace_node). Each inside the system's bars (under the
// status bar, over the navigation bar and the keyboard over it, as within_bars keeps them), on the window's ground;
// where the window's buttons are in the app's top row, its top drags it, under all of it; over it, nodes of the
// window's tree (app_tree's): the library's presenters, the toasts and, signed in, the finger's loupe.

///|
/// What the frame is told of the app at a way in drawn by the window's tree's nodes, as the frame begins (view_in's):
/// no first page waiting nor its pictures, the frame
/// not drawing the ground alone.
fn entry_said() -> Unit {
  first_waiting.val = false
  frame_bare.val = false
  @sfbase.held_pictures_waiting.val = []
}

///|
/// Whether the app signed in is at its landing: no workspace in view, every account answered with none
/// (not in a window of its own).
fn landing_now(src : Source) -> Bool {
  if @sfbase.first_lone_page() is Some(_) {
    return false
  }
  let (current, all, answered, _) = workspace_in_view(src)
  current is None && src.topic("workspaces", {}).get().value is Some(_) && answered && all.is_empty()
}

///|
/// A way in in node `v`: `page` made in the room the system's bars leave (what is presented over it, and the loupe, the
/// window's tree's over all of it: app_tree's).
fn entry_tree(v : @view.View, page : (@view.View) -> Unit) -> Unit {
  v.ground(By(fn() { @sf.theme().p.bg })) |> ignore
  v.show(fn() { @ui.window_inset_now() }, fn(o) {
    o.over(Is(true)) |> ignore
    o.box(fn(b) { b.height(By(fn() { Some(window_band_now()) })).moves_window(Is(true)) |> ignore }) |> ignore
  })
  within_bars_tree(v, page)
}

///|
/// Signed out (app_state's SignedOut) in node `v`: the sign-in page; an invitation's link opened signed out, its sheet
/// saying to sign in first (signed_out_links), as one is given.
fn signed_out_tree(v : @view.View, src : Source) -> Unit {
  entry_tree(v, fn(body) { @sfpages.sign_in_node(body, src) |> ignore })
  v.reacts(fn() { links_wait() }, fn(waits) { if waits { signed_out_links(src) } })
}

///|
/// Signed in with no workspace yet (signed_in's landing) in node `v`: the landing; an invitation's link pasted
/// (用邀请链接加入: its sheet).
fn landing_tree(v : @view.View, src : Source) -> Unit {
  entry_tree(v, fn(body) {
    @sfpages.no_workspace_node(body, src, fn() { src.topic("workspaces", {}).get().value }, open_invite_link) |> ignore
  })
}
