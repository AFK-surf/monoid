// What a link in a message is, while it is pointed at (still.fail web/src/Peeks.tsx LinkHover, LinkCard; ChatRef.tsx
// RefChip's RefPreview; Hover.css.ts): a small card over it. A web link's as the core reads it from the link's station
// (the `linkPreview` topic: GET /link-preview, kept, read again each time a card shows it): a page by its title, its
// site and icon, its picture over them; a GitHub pull request or issue as GitHub says it: its state, where it is and
// when it last changed, its title, who opened it and a few facts. Its pictures come beside (@sfbase.link_picture,
// peek_pictures.mbt), asked as the value is read; a card naming some shows once they are here, as it shows while it is
// read till then. A chat's as its whole row has it (`chatRow`), listed or not: its title,
// state and when it was last active, where it is, and the last thing said. Asked for as the pointer comes onto the
// link, so the card mostly opens with it there.

///|
fn link_params(station : String, href : String) -> Map[String, Json] {
  { "station": Json::string(station), "url": Json::string(href) }
}


///|
/// Where a link goes, as a card says it: its host and path (Peeks.tsx destination).
fn destination(href : String) -> String {
  let rest = match href.find("://") {
    Some(i) => href.exact_view(start=i + 3).to_owned()
    None => href
  }
  let rest = match rest.find("?") {
    Some(i) => rest.exact_view(end=i).to_owned()
    None => rest
  }
  let rest = match rest.find("#") {
    Some(i) => rest.exact_view(end=i).to_owned()
    None => rest
  }
  if rest.has_suffix("/") {
    rest.exact_view(end=rest.length() - 1).to_owned()
  } else {
    rest
  }
}

///|
/// A state's ink and ground.
fn state_colours(state : String) -> (Int64, Int64) {
  let p = @sf.theme().p
  match state {
    "open" | "passed" => (p.green_ink, p.green_bg)
    "merged" | "completed" => {
      let ink = if @sf.theme().dark { merged_dark } else { merged_light }
      (ink, @sf.tone_ground(ink))
    }
    "closed" | "failed" => (p.red, p.red_bg)
    "pending" => (p.warn_ink, p.amber_bg)
    _ => (p.muted, p.hover)
  }
}

///|
/// GitHub's purple for what was merged or completed, each theme's a step deeper or lighter than GitHub's
/// (#8250df, #a371f7) to read on its ground, the purple at the theme's tone opacity (@sf.tone_ground).
let merged_light : Int64 = 0x6830BFFFL

///|
let merged_dark : Int64 = 0xC4A9FFFFL

///|
fn pr_state_key(state : String) -> String {
  match state {
    "merged" => "web-main.preview.pr.merged"
    "closed" => "web-main.preview.pr.closed"
    "draft" => "web-main.preview.pr.draft"
    _ => "web-main.preview.pr.open"
  }
}

///|
fn issue_state_key(state : String) -> String {
  match state {
    "completed" => "web-main.preview.issue.completed"
    "not_planned" => "web-main.preview.issue.notPlanned"
    "closed" => "web-main.preview.issue.closed"
    _ => "web-main.preview.issue.open"
  }
}

///|
/// GitHub's own octicons for a pull request's state (MIT, primer/octicons: Peeks.tsx PR_GLYPH), 16 by 16.
fn pr_glyph(state : String) -> String? {
  Some(
    match state {
      "draft" => "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 14a2.25 2.25 0 1 1 0-4.5 2.25 2.25 0 0 1 0 4.5ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM14 7.5a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Zm0-4.25a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Z"
      "merged" => "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z"
      "closed" => "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 5.5a.75.75 0 0 1 .75.75v3.378a2.251 2.251 0 1 1-1.5 0V7.25a.75.75 0 0 1 .75-.75Zm-2.03-5.273a.75.75 0 0 1 1.06 0l.97.97.97-.97a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.97.97.97.97a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018l-.97-.97-.97.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l.97-.97-.97-.97a.75.75 0 0 1 0-1.06ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"
      _ => "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
    },
  )
}

///|
/// A 16 by 16 path filled in `ink`.
fn glyph_of(d : String, ink : Int64) -> @pixels.Vector {
  {
    w: 16.0,
    h: 16.0,
    layers: [{ d, fill: ink, stroke: 0L, width: 0.0, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }],
  }
}

///|
/// The file chip under the pointer, so returning to it refreshes even while its card is still open.
let hovered_file : Ref[(String, Double)?] = Ref(None)

///|
fn file_peek_params(station : String, session : String, path : String, line : Int?) -> Map[String, Json] {
  let p : Map[String, Json] = {
    "station": Json::string(station),
    "key": Json::string(session),
    "path": Json::string(path),
  }
  match line {
    Some(n) => p["line"] = Json::number(n.to_double())
    None => ()
  }
  p
}

///|
/// Whether a path names a directory (trailing `/` or Windows trailing `\`).
fn is_dir_path(path : String) -> Bool {
  path.has_suffix("/") || (@sfbase.dv_windows_path(path) && path.has_suffix("\\"))
}

///|
/// The last part of a path (a directory's without its trailing separator).
fn base_of(path : String) -> String {
  let trimmed = @sfbase.dv_trim_root(path)
  match @sfbase.base_name(trimmed) {
    "" => path
    n => n
  }
}

///|
/// A path as it is shown: a home directory (/Users/<name>, /home/<name>) as `~` (paths.ts shownPath).
fn shown_path(path : String) -> String {
  for home in ["/Users/", "/home/"] {
    if path.has_prefix(home) {
      let rest = path.exact_view(start=home.length()).to_owned()
      return match rest.find("/") {
        Some(i) => "~" + rest.exact_view(start=i).to_owned()
        None => "~"
      }
    }
  }
  path
}

// ── a chat's ───────────────────────────────────

///|
/// What the core reads a chat's link as (`link.parse`): asked; the chat's station, its key (its id, or its agent's
/// session), whether the link names that agent's execution history and the message it names; or no chat.
priv enum Named {
  Asking
  Chat(String, String, Bool, Double?)
  NoChat
}

///|
/// The chats links name, by the station of the chat they are in and the link: asked once each, as the pointer comes
/// onto one.
// kept across runs: what the core said of each link, the same each time it is asked
let chats_named : @sf.LiveMap[String, Named] = @sf.LiveMap::new()

///|
/// The chat `href` names, read in a chat of station `here` (a link with no station of its own, `…/chats/<id>`, one of
/// its): asked the core once (chats_named).
fn chat_named(src : Source, here : String, href : String) -> Named {
  let key = here + "\u{1}" + href
  match chats_named.get(key) {
    Some(named) => return named
    None => ()
  }
  chats_named[key] = Asking
  (src.call)("link.parse", { "url": Json::string(href) }, fn(r) {
    let t = match r {
      Ok(Object(_) as v) => Some(@sfbase.link_target(v))
      _ => None
    }
    chats_named[key] = match t {
      Some(t) if t.opens == "chat" && t.chat != "" => Chat(t.workspace + "/" + t.station, t.chat, t.history != "", t.message)
      Some(t) if t.opens == "item" && t.session != "" => Chat(t.workspace + "/" + t.station, t.session, t.history != "", t.message)
      // (`…/chats/<id>` alone: the chat's own station's)
      _ =>
        match href.find("/chats/") {
          Some(i) => {
            let id = href.exact_view(start=i + 7).to_owned()
            let id = match id.find("?") {
              Some(k) => id.exact_view(end=k).to_owned()
              None => id
            }
            let id = match id.find("#") {
              Some(k) => id.exact_view(end=k).to_owned()
              None => id
            }
            let id = if id.has_suffix("/") { id.exact_view(end=id.length() - 1).to_owned() } else { id }
            if id == "" {
              NoChat
            } else {
              Chat(here, id, href.contains("?history="), None)
            }
          }
          None => NoChat
        }
    }
  })
  Asking
}

///|
/// Whether a card in a chat of station `here` reads the row of a chat of station `station`: one of its own workspace.
/// Another workspace's is not asked of the core: its card says only that it is not in the list.
fn peek_ours(here : String, station : String) -> Bool {
  @sfbase.workspace_of(station) == @sfbase.workspace_of(here)
}

///|
/// A linked chat as its whole row (`chatRow`, as `s` says it) gives it: None while not answered (its station's chats
/// never listed yet); Some(None) where its station has no such chat unarchived (archived, being archived, gone) or the
/// core could not say; the chat, whether the workspace's list shows it or not.
fn peek_row(s : @sfbase.TopicState) -> ChatItem?? {
  match (s.value, s.error) {
    (Some(Object(_) as v), _) => Some(Some(@sfbase.chat_item(v)))
    (Some(_), _) | (_, Some(_)) => Some(None)
    _ => None
  }
}

// ── its look ──────────────────────────────────────────────

///|
// kept across runs: a value (no field of it changes)
let peek_tile_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=2)

///|
/// Its meta: the state, where it is (taking what is left, cut), when it changed; 8 apart, 12, muted.
// kept across runs: a value (no field of it changes)
let peek_meta : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// A pull request's or an issue's meta, its state's pill first: in the card's top left corner as far from both its
/// edges as makes it concentric with it (@sf.capsule_in), out past the panel's padding and the card's words' to there.
// kept across runs: a value (no field of it changes)
let peek_change_meta : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter").then(
  @ui.style(mt=@sf.room_of(peek_capsule_in), ml=@sf.room_of(peek_capsule_in)),
)

///|
/// How far a capsule 20 high in a card's corner (a state's pill, a fact's, a face) stands from where its words start,
/// out past them: concentric with the card's corner.
let peek_capsule_in : Double = @ui.capsule_in(@sf.r_menu, peek_capsule_h) - @sf.panel_pad - hover_words_in

///|
/// A capsule's height: a state's, a fact's, a face.
let peek_capsule_h : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let peek_ref : @ui.Style = @ui.css("clip=true").then(@ui.style(w=@sf.grow))

///|
// kept across runs: a value (no field of it changes)
let peek_meta_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// A state's pill: 20 high, full corners to stand concentric in its card's corner, no horizontal pad at the left so
// kept across runs: a value (no field of it changes)
let peek_state : @ui.Style = @ui.css("row h=S5 gap=S1 pl=S1_5 pr=S2 radius=Full align=ACenter")

///|
/// Its foot: what it is in words and its path to copy, in the card's bottom end corner as far from both its edges as
/// makes it concentric with it (@sf.capsule_in: the button 24 high), out past the panel's padding and the card's words'.
// kept across runs: a value (no field of it changes)
let peek_file_foot : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter").then(
  @ui.style(mb=@sf.room_of(peek_button_in), mr=@sf.room_of(peek_button_in)),
)

///|
let peek_button_in : Double = @ui.capsule_in(@sf.r_menu, 24.0) - @sf.panel_pad - hover_words_in
