// A web link's card over what draws it (peeks.mbt's web_peek) as nodes of the window's tree, made once: the library's
// hover card (@sf.hover_card_node: shown as a mouse has rested on its row hover_open_ms carrying no press, kept while
// the pointer is on the row or on the card, gone hover_close_ms after it has left both, at once by Escape or a press
// elsewhere; a finger shows none, nothing of the hand put on the row) beside its row on its `side`, over all of the
// window (over a sheet's modal layer too: a layer of its own, View::over_all). What it holds as link_card's: a pull
// request's or an issue's card (320 wide), a page's tile (content-sized, or 320 wide if pictured), the bones of the
// one it will be while it is read, its address to copy at its foot's end, drawn by the library's (@sfbase.peek_page_tile_node,
// @sfbase.peek_change_node); this is what is read for it and what that says. Read as peek_read reads it: as the pointer
// comes onto the row and while the card is there, let go of once neither, so the next time it shows it is read again;
// the pictures its value names asked as it is read (@sfbase.link_pictures_ask), the card showing as it does while it
// is read till they are here.

///|
/// A web link's card (web_peek's) over `row` (what draws it: the node the pointer rests on, what is pressed) while a
/// mouse rests on it, as the link's station `station` reads it (`href` the link, `words` what the row says of it, as
/// they are now): opened at its `side` (under it, else beside a list it would cover: a chat's things'); `peek` the kind
/// the core says it is (pull, issue) while it is read, its bones that one's then. Nothing for what is no web link, nor
/// from a station not known.
pub fn web_peek_node(
  row : @view.View,
  src : Source,
  station : String,
  href : () -> String,
  words : () -> String,
  side? : @view.Side = Bottom,
  peek? : () -> String = fn() { "" },
) -> Unit {
  if station == "" {
    return
  }
  peek_cards.val = peek_cards.val + 1
  let scope = "link-peek-node/" + peek_cards.val.to_string()
  let web = fn() {
    let h = href()
    h.has_prefix("https://") || h.has_prefix("http://")
  }
  // (its layer: unified transient hover layer via presented_nodes, falling back to root over_all only in standalone tests)
  let unified = @sf.transient_layer_of(row)
  let fallback : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() {
    match (unified.layer)() {
      Some(_) as l => l
      None =>
        match fallback.val {
          Some(_) as l => l
          None => {
            let l = peek_layer(row).box(fn(h) { h.over(Is(true)).over_all(Is(true)) |> ignore }).lives_with(row)
            fallback.val = Some(l)
            Some(l)
          }
        }
    }
  })
  // (what is read as the pointer comes onto the row, while it is: the pictures it names asked as it comes, so that they
  // are mostly here as the card opens)
  let warm : @signals.Signal[@signals.Computed[@sfbase.TopicState]?] = @signals.signal_by(None, same=fn(a, b) {
    match (a, b) {
      (None, None) => true
      (Some(x), Some(y)) => physical_equal(x, y)
      _ => false
    }
  })
  row.reacts(
    fn() {
      match warm.get() {
        Some(read) => read.get().value
        None => None
      }
    },
    fn(v) { @sfbase.link_pictures_ask(src, station, @signals.untracked(href), v) },
  )
  // (a page's tile is content-sized, or 320 wide if pictured; a pull request's or an issue's card is 320: by what the
  // core says it is as it opens, said once; on a mouse's pointer resting on the row while it is a web link, nothing of
  // the hand put on the row: what holds it says that)
  let hand = @sf.hover_card_node(
    tips,
    row,
    fn(inner) {
      let tile = @signals.untracked(fn() { peek() == "" || peek() == "run" })
      if !tile {
        inner.width(Is(Some(peek_change_w))) |> ignore
      }
      let read = @sfbase.hold(src, scope, "linkPreview", link_params(station, @signals.untracked(href)))
      link_card_node(inner, src, station, read, href, words, peek, fn(at) { link_copy_node(at, href) })
      // (gone, the pointer not on the row: what it read let go of)
      inner.owns(fn() {
        if !@signals.untracked(fn() { row.pointed_in() }) {
          @sfbase.let_go(src, scope)
        }
      })
      |> ignore
    },
    tile=true,
    side~,
    pointed=fn() { row.pointed_in() && web() },
  )
  row.reacts(fn() { (@sf.hovered_in_node(row), web(), (hand.card)() is Some(_)) }, fn(s) {
    let (over, web, made) = s
    // (read as the pointer comes onto it, so the card mostly opens with it there: Peeks.tsx Hover's `warm`)
    if over && web {
      warm.set(Some(@sfbase.hold(src, scope, "linkPreview", link_params(station, @signals.untracked(href)))))
    }
    // (neither pointed at nor drawn: what it read let go of)
    if !over && !made {
      warm.set(None)
      @sfbase.let_go(src, scope)
    }
  })
  // (its row let go: nothing read for it)
  row.owns(fn() {
    warm.set(None)
    @sfbase.let_go(src, scope)
  })
  |> ignore
}

///|
/// How many link cards have been made (web_peek_node), each one's reading named by its count (link-peek-node/<n>).
// kept across runs: it only names each card's reading apart from the others', never says what it shows
let peek_cards : Ref[Int] = Ref(0)

///|
/// What a pull request's or an issue's card holds is as wide as in a card 320 wide (@sf.hover_card_w), its panel's
/// padding off it: the card it is in as wide as it holds.
let peek_change_w : Double = match @sf.hover_card_w {
  Fixed(w) => w - 2.0 * @sf.panel_pad
  _ => 308.0
}

///|
/// What holds all of the window's tree `v` is in (its root): where a card goes over all of the window.
fn peek_layer(v : @view.View) -> @view.View {
  match v.parent() {
    Some(p) => peek_layer(p)
    None => v
  }
}

///|
/// What a link's card shows (link_card's): a pull request's card or an issue's; the bones of one (a pull request's
/// where `true`) while it is read and the core says it is one; else a page's tile.
#derive(Eq)
priv enum PeekShows {
  Change(Bool)
  Run
  RunSample
  Sample(Bool)
  Page
}

///|
/// The card (link_card's) in `parent`, of what `read` reads (`href`, `words`, `peek` as web_peek_node's) of station
/// `station`: what it shows made again as that changes kind, its words and facts as they are read, as it is while it is
/// read till the pictures they name are here (@sfbase.link_pictures_here_told); `copy` makes what copies it, at its foot's
/// end.
fn link_card_node(
  parent : @view.View,
  src : Source,
  station : String,
  read : @signals.Computed[@sfbase.TopicState],
  href : () -> String,
  words : () -> String,
  peek : () -> String,
  copy : (@view.View) -> Unit,
) -> Unit {
  // (the pictures its value names asked as it is read, as that changes: told to what reads them as each comes, none
  // asked as a binding runs)
  parent.reacts(fn() { (href(), read.get().value) }, fn(r) { @sfbase.link_pictures_ask(src, station, r.0, r.1) })
  let value = fn() -> Json? {
    match read.get().value {
      Some(Object(_)) as v if @sfbase.link_pictures_here_told(src, station, href(), v) => v
      _ => None
    }
  }
  // (a picture of it, as its image's key: "" none)
  let picture = fn(which : String) {
    @sfbase.picture_drawn(@sfbase.link_picture_told(src, station, href(), value(), which))
  }
  let shows = fn() {
    let v = value()
    match text(v, "kind") {
      "github_pull_request" => Change(true)
      "github_issue" => Change(false)
      "github_actions_run" => Run
      _ if v is None && read.get().error is None && peek() == "run" => RunSample
      _ => if v is None && read.get().error is None && peek() != "" { Sample(peek() == "pull") } else { Page }
    }
  }
  parent.pick(shows, fn(b, s) {
    @sf.style_node(b, fn() { @sfbase.peek_card_part })
    match s {
      Run => run_card_node(b, value, href, copy)
      RunSample => @sf.waiting_node(b, fn(bones) { run_card_node(bones, peek_sample, href, fn(_) {  }) })
      Change(pr) => change_card_node(b, value, pr, copy, fn() { picture("avatar") })
      // (while it is read: a made-up one's, in its bones)
      Sample(pr) => @sf.waiting_node(b, fn(bones) { change_card_node(bones, peek_sample, pr, fn(_) {  }, fn() { "" }) })
      Page => {
        // A content-sized hover cannot measure an aspect-ratio picture before it has a width. Give pictured pages
        // the normal card width, limited to the room available, so the scroll viewport includes the picture and tile.
        let pictured_width = fn() {
          if picture("image") != "" {
            Some(peek_change_w - 2.0 * @ui.Space::px(S2_5))
          } else {
            None
          }
        }
        b.width(By(pictured_width)).max_width(By(pictured_width), within=true) |> ignore
        // (what the core read of the page, where it says it is one)
        let page = fn() {
          let v = value()
          if text(v, "kind") == "page" {
            v
          } else {
            None
          }
        }
        @sfbase.peek_page_tile_node(
          b,
          fn() {
            match text(page(), "title") {
              "" => if words() != "" { words() } else { href() }
              x => x
            }
          },
          fn() {
            let site = text(page(), "site")
            if site != "" {
              site + " · " + destination(href())
            } else {
              destination(href())
            }
          },
          fn() { if page() is None { "" } else { picture("icon") } },
          fn() {
            let h = href()
            h.has_prefix("https://github.com/") || h.contains(".github.com/")
          },
          fn() { if page() is None { "" } else { picture("image") } },
          copy,
        )
      }
    }
  })
}

///|
/// The made-up pull request or issue a card's bones are made of while it is read (link_card's).
fn peek_sample() -> Json? {
  Some({
    "repository": Json::string(@sf.sample_words(8)),
    "number": 1,
    "title": Json::string(@sf.sample_words(18)),
    "time": { "updatedAt": { "ago": Json::string(@sf.sample_words(3)) } },
  })
}

///|
/// A pull request's (`pr`) or an issue's card (change_card's, @sfbase.peek_change_node) in `parent`, of `v` as it is read:
/// its state, where it is and when it last changed; its title; who opened it (`avatar`: their picture's image's key, ""
/// none) and its facts, `copy` at their line's end.
fn change_card_node(
  parent : @view.View,
  v : () -> Json?,
  pr : Bool,
  copy : (@view.View) -> Unit,
  avatar : () -> String,
) -> Unit {
  let state = fn() { text(v(), "state") }
  @sfbase.peek_change_node(
    parent,
    pr,
    state,
    fn() { @sf.t(if pr { pr_state_key(state()) } else { issue_state_key(state()) }) },
    fn() { text(v(), "repository") + " #" + count(v(), "number").to_string() },
    fn() { text(field(field(v(), "time"), "updatedAt"), "ago") },
    fn() { text(v(), "title") },
    fn() { peek_facts_of(v(), pr, avatar) },
    copy,
  )
}

///|
/// What facts `v` has (change_card's, in its order): who opened it; a pull request's (`pr`) size where it says one,
/// its files and how its checks stand; an issue's labels and how many comments it has. `avatar`: who opened it's
/// picture's image's key ("" none).
fn peek_facts_of(v : Json?, pr : Bool, avatar : () -> String) -> Array[@sfbase.PeekFact] {
  let out : Array[@sfbase.PeekFact] = []
  match field(v, "author") {
    Some(Object(_)) as a => out.push(Person(text(a, "login"), avatar()))
    _ => ()
  }
  if pr {
    if field(v, "additions") is Some(Number(_, ..)) || field(v, "deletions") is Some(Number(_, ..)) {
      out.push(Size(count(v, "additions"), count(v, "deletions")))
    }
    if field(v, "changedFiles") is Some(Number(_, ..)) {
      out.push(Chip(@sf.t("web-main.preview.files", args=[("count", count(v, "changedFiles").to_string())])))
    }
    match field(v, "checks") {
      Some(Object(_)) as ch =>
        out.push(
          if count(ch, "failed") > 0 {
            Checks("failed", @sf.t("web-main.preview.checks.failed", args=[("count", count(ch, "failed").to_string())]))
          } else if count(ch, "pending") > 0 {
            Checks("pending", @sf.t("web-main.preview.checks.pending", args=[("count", count(ch, "pending").to_string())]))
          } else {
            Checks("passed", @sf.t("web-main.preview.checks.passed", args=[("count", count(ch, "passed").to_string())]))
          },
        )
      _ => ()
    }
  } else {
    for l in items(v, "labels") {
      match l {
        String(s) => out.push(Chip(s))
        _ => ()
      }
    }
    if count(v, "comments") > 0 {
      out.push(Chip(@sf.t("web-main.preview.comments", args=[("count", count(v, "comments").to_string())])))
    }
  }
  out
}

///|
/// A state in a tinted pill (state_pill's, @sfbase.peek_state_pill_node) in `parent`, or (`own`) drawn in `parent` itself:
/// its glyph where `glyph` says one and its name (`words`), in the state's colours, each as it changes.
fn state_pill_node(
  parent : @view.View,
  state : () -> String,
  glyph : () -> String?,
  words : () -> String,
  own? : Bool = false,
  style? : @ui.Style = @sfbase.peek_state,
) -> Unit {
  @sfbase.peek_state_pill_node(parent, state, glyph, words, own~, style~)
}

///|
/// A web link's address to copy, on its card (link_copy's) in `parent`: 复制链接 to press, 已复制 for copied_ms once
/// copied. By the link, as link_copy's mark is: a card of it made again while that lasts (gone and pointed at again)
/// says 已复制 till its end (its words: the user, 2026-10-29: 图标改成文字复制链接吧).
fn link_copy_node(parent : @view.View, href : () -> String) -> Unit {
  @sfbase.peek_copy_node(parent, href, "common.link.copy", peek_copied_at)
}

///|
/// When each link's address was last copied from its card (link_copy_node's), by the link: what a card of it made again
/// says, as link_copy's mark by the link is kept.
// kept across runs: let go as the app begins anew (hover_reset)
let peek_copied_at : Map[String, Double] = Map([])
