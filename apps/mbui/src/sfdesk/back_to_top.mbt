// A place pressed again where it shows at its root (小屏's bar, the rail's lit place on 中屏 and 大屏): its list back to
// its top, as a platform's tab pressed again brings its list back up (UITabBarController's, a Mac's sidebar's).

///|
/// The sidebar's node as it is made (side_node's): where the rail's lit place pressed again finds the list it brings
/// back to its top (rail_back_to_top).
// kept across runs: let go with its node
let side_made : Ref[@view.View?] = Ref(None)

///|
/// The page's list `within` holds that a press could reach now (one no modal layer is over, in use: Tree::takes_keys),
/// the largest of them where it holds several (a sidebar's list beside its band); none given, the main one of the page
/// in front (Tree::list_in_front). None where no such list is drawn (a sidebar folded away).
fn back_to_top_list(tree : @view.Tree, within : @view.View?) -> @view.ListSeen? {
  match within {
    None => tree.list_in_front()
    Some(w) => {
      let mut best : @view.ListSeen? = None
      let mut most = -1.0
      for l in tree.lists_seen() {
        guard w.alive() && tree.holds(w.id(), l.list) && tree.takes_keys(l.list) else { continue }
        guard tree.drawn_of(l.list) is Some(d) else { continue }
        if d.w * d.h > most {
          most = d.w * d.h
          best = Some(l)
        }
      }
      best
    }
  }
}

///|
/// The list `within` holds (back_to_top_list) brought back to its top where it is scrolled away from it (ListSeen's
/// `at` past its `top`): gliding there from the press's moment where it is near, at once where it is far or motion is reduced (as a
/// page's list's go-to is, ListPlace::bring). Whether it was away and so is brought back; at its top, or none drawn,
/// nothing, false (what the press does then is the caller's).
pub fn list_back_to_top(within? : @view.View) -> Bool {
  guard @ui.view_tree() is Some(tree) else { return false }
  guard back_to_top_list(tree, within) is Some(l) else { return false }
  // (at its top already, as far up as the hand takes it: what is tucked over it kept out of sight)
  if l.at <= l.top + 0.5 {
    return false
  }
  tree.list_bring(l.list, 0, glide=!@ui.reduced_motion())
  true
}

///|
/// The rail's lit place `place` pressed again, what it shows at its root: its list back to its top where it is away from
/// it (list_back_to_top), the sidebar's where the place has one (not folded away: then none is drawn), the page's own
/// where the place is the page alone (place_bare_now) and nothing is opened over it. Whether it was brought back; else
/// the press does what it did (its sidebar folded or shown, back to the place's root).
fn rail_back_to_top(place : String) -> Bool {
  if place_bare_now(place) {
    app.nav.pages().length() <= 1 && list_back_to_top()
  } else {
    match side_made.val {
      Some(s) => list_back_to_top(within=s)
      None => false
    }
  }
}
