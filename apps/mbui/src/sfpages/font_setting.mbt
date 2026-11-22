// 字体, one setting for every frame:
// a face chosen for each of three places (界面, 正文, 代码) and the chat they make seen as it is chosen. What it is for is
// one thing on every screen, so it is one design: the place in view by a choice of three; a chat as the faces set it
// right under that, where the eye is as a face is chosen; the place's faces in a group, each row its name and a line
// of it drawn in itself (how far it has come, what failed, its size where its files are not kept here, at its end;
// the chosen one checked). A row pointed at is tried in the chat first (where there is a pointer: lit_in_node). This machine's own faces
// (where the host lists them: keyboard and mouse's) are one row more, opening a list of them to find one in. What is chosen
// is the device's (`prefs.set {fonts}`). Its page (fonts_node) holds it, as nodes of the window's tree.

///|
fn font_setting_reset() -> Unit {
  fonts_trying.set("")
  local_try_given.val = ""
  local_open.set(false)
  fx_local_up.val = false
}

///|
/// The face pointed at in the faces' rows, tried in the chat before it is chosen ("" none; "\u{1}" the place's own;
/// `local:<family>` one of this machine's): said as the hand comes on a row and goes off it, the chat set in it then.
let fonts_trying : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// 字体's setting made once as nodes, a block at a time (fonts_node's and 外观's): the places' choice, the chat as their
/// faces set it, the faces of the place in view, each as the core says it now (the prefs, the fonts' files).
fn fonts_blocks_node(core : Core) -> (() -> Array[String], (@view.View, String) -> Unit) {
  let prefs = fn() { (core.topic)("prefs", Map([])).get().value }
  let chosen_of = fn(place : String) { text(field(prefs(), "fonts"), place) }
  let all = fn() { items(field(prefs(), "faces"), "list") }
  let files_state = fn() { (core.topic)("fonts", Map([])).get().value }
  let place = fn() { @settings.font_places[@settings.fonts_at.get()] }
  // each face shown in itself: its host face (its preview's), by its place in the list
  let shown_in = fn(id : String) {
    let mut face = 0
    for i, f in all() {
      if text(Some(f), "id") == id {
        face = (core.face_preview)(id, i, items(Some(f), "files").iter().any(fn(x) { number(Some(x), "weight") == 0.0 }))
      }
    }
    face
  }
  // the place's own: code's JetBrains Mono, the others' the app's words'
  let own = fn() { if place() == "code" { (core.own_code_face)() } else { 0 } }
  // as chosen, each place in its face as far as it is here: one whole is the app's already (0: as the app's words
  // are), one coming in its preview
  let as_chosen = fn(p : String) {
    let id = chosen_of(p)
    if id == "" || (core.face_here)(id) {
      0
    } else {
      shown_in(id)
    }
  }
  // the face pointed at, tried in its place: None none
  let try_face = fn() {
    let tried = fonts_trying.get()
    if tried == "\u{1}" {
      Some(own())
    } else if tried.has_prefix(local_prefix) {
      Some(local_tried(tried.unsafe_substring(start=local_prefix.length(), end=tried.length())))
    } else if tried != "" {
      Some(
        match shown_in(tried) {
          0 => own()
          f => f
        },
      )
    } else {
      None
    }
  }
  let ui_face = fn() {
    match (place(), try_face()) {
      ("ui", Some(f)) => f
      _ => as_chosen("ui")
    }
  }
  // None keeps the chosen face. Some(0) explicitly follows the interface, even if a separate text face is chosen.
  let text_face = fn() {
    match (place(), try_face()) {
      ("text", Some(f)) => Some(f)
      ("ui", Some(f)) if chosen_of("text") == "" => Some(f)
      _ => {
        let face = if chosen_of("text") == "" { ui_face() } else { as_chosen("text") }
        if face == 0 { None } else { Some(face) }
      }
    }
  }
  let code_face = fn() {
    match (place(), try_face()) {
      ("code", Some(f)) => Some(f)
      _ => {
        let face = as_chosen("code")
        if face == 0 { None } else { Some(face) }
      }
    }
  }
  // whether the pointer is over the faces (their box, the gaps between rows too), as it comes and goes
  let over_faces : @signals.Signal[Bool] = @signals.signal(false)
  let block = fn(b : @view.View, key : String) {
    match key {
      "place" =>
        @sf.page_choice_node(
          b,
          fn() { @settings.font_places.map(fn(p) { @sf.t("web-pages.appearance.fonts." + p) }) },
          fn() { @settings.fonts_at.get() },
          fn(picked) {
            if picked != @signals.untracked(fn() { @settings.fonts_at.get() }) {
              @settings.fonts_at.set(picked)
            }
          },
        )
      "preview" =>
        // held at its tallest while the pointer is over the faces (their box, the gaps between rows too): a face tried
        // sets its words otherwise (taller, wrapped elsewhere), moving the faces under it; let go, the row under the
        // pointer would be another, tried in turn, and the page would shake. As tall as it comes to again once the
        // pointer is off them.
        b.by_room(fn(held, room) {
          held.box(fn(cell) {
            let chat : Ref[@view.View?] = Ref(None)
            let tallest = Ref(0.0)
            cell.box(fn(p) {
              chat.val = Some(p)
              font_preview_node(p, ui_face, text_face, code_face)
            })
            |> ignore
            cell.min_height(By(fn() {
              match chat.val {
                Some(p) => {
                  let tall = room.tall(p)
                  if over_faces.get() {
                    tallest.val = dmax(tallest.val, tall)
                    Some(tallest.val)
                  } else {
                    tallest.val = tall
                    None
                  }
                }
                None => None
              }
            }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
      _ =>
        b.box(fn(faces) {
          // (pointed at as the pointer is over it or what it holds: the gaps between its rows too)
          faces.points(Is(true)) |> ignore
          faces.reacts(fn() { faces.pointed_in() }, fn(on) { over_faces.set(on) })
          faces.owns(fn() { over_faces.set(false) }) |> ignore
          @sf.group_node(faces, fn(g) {
            g.pick(place, fn(held, place) {
              // (as far apart as the group's own rows: a wide list's, group_rows_node's)
              @sf.group_rows_node(held, fn(rows) { face_rows_node(rows, core, place, all, own, shown_in, files_state, chosen_of) })
            })
          })
        })
        |> ignore
    }
  }
  (fn() { ["place", "preview", "faces"] }, block)
}

///|
/// 字体's faces of `place` in `rows`: its own first (跟随界面 or 默认, in `own()`), the faces the core lists for it, and
/// 本机字体 where the host lists them.
fn face_rows_node(
  rows : @view.View,
  core : Core,
  place : String,
  all : () -> Array[Json],
  own : () -> Int,
  shown_in : (String) -> Int,
  files_state : () -> Json?,
  chosen_of : (String) -> String,
) -> Unit {
  let chosen = fn() { chosen_of(place) }
  let none = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
  face_row_node(rows, core, place, "", fn() { @sf.t(none) }, own, fn() { chosen() == "" }, fn() { ("", false) })
  // (the place's faces kept by their ids: a row reads its own, told only as that one changes: View::keyed_by)
  let by_id = rows.keyed_by(fn() { all().filter(fn(f) { flag(Some(f), "mono") == (place == "code") }) }, fn(f) {
    text(Some(f), "id")
  })
  rows.each(
    fn() { by_id.keys() },
    fn(k) { k },
    fn(r, id) {
      let id = id.untracked()
      let fv = fn() { by_id.get(id) }
      let status = fn() {
        let st = files_state()
        let fetching = field(field(st, "fetching"), id)
        let failed = text(field(st, "failed"), id)
        let damaged = (core.face_failed)(id)
        match fetching {
          Some(Number(p, ..)) =>
            (@sf.t("android-settings.fonts.downloading", args=[("percent", (p * 100.0).to_int().to_string())]), false)
          _ =>
            if failed != "" {
              (@sf.t("android-settings.fonts.failed", args=[("error", failed)]), true)
            } else if damaged != "" {
              (@sf.t("android-settings.fonts.failed", args=[("error", damaged)]), true)
            } else if (core.face_here)(id) || items(st, "kept").contains(ToJson::to_json(id)) {
              ("", false)
            } else {
              (face_size(number(fv(), "bytes")), false)
            }
        }
      }
      // not shown in itself (its preview not here): in the place's own
      let face = fn() {
        match shown_in(id) {
          0 => own()
          x => x
        }
      }
      face_row_node(r, core, place, id, fn() { text(fv(), "name") }, face, fn() { chosen() == id }, status)
    },
  )
  // a face of this machine's own, where the host lists them (keyboard and mouse's)
  rows.show(fn() { @ui.local_font_families() != "" }, fn(l) { local_face_row_node(l, core, place, chosen) })
}

///|
/// A face of the place (FaceRow, the web's tile) in `parent`: its name and a line of it, each drawn in itself (`face()`,
/// a host face: 0 the app's words'); at its end how it stands (`status()`: its words, whether in red), the check where
/// it is the one chosen (`on()`); pointed at, tried in the chat; pressed, chosen (`id` "": the place's own).
fn face_row_node(
  parent : @view.View,
  core : Core,
  place : String,
  id : String,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  status : () -> (String, Bool),
) -> Unit {
  let tried = if id == "" { "\u{1}" } else { id }
  parent.box(fn(r) {
    fonts_tried_by(r, tried)
    face_choice_node(r, name, face, on, press=fn() { @settings.set_font(core, place, if id == "" { None } else { Some(id) }) }, status~)
  })
  |> ignore
}

///|
/// Node `r` pointed at (the hand on it: @sf.lit_in_node) tried in the chat as `tried`, as the hand comes on it; as it
/// goes off it, none tried, unless another came on meanwhile.
fn fonts_tried_by(r : @view.View, tried : String) -> Unit {
  r.reacts(fn() { @sf.lit_in_node(r) }, fn(lit) {
    if lit {
      fonts_trying.set(tried)
    } else if fonts_trying.untracked() == tried {
      fonts_trying.set("")
    }
  })
  r.owns(fn() {
    if fonts_trying.untracked() == tried {
      fonts_trying.set("")
    }
  })
  |> ignore
}

///|
/// A face's row in `parent` (choice_row_node's, with a note under its label): its name on its first line, with how it
/// stands (`status()`) and the check where it is the one chosen (`on()`) at that line's end, as an icon or a value
/// beside lines is (on their first line, never across their middle); a line of it under them, as wide as the row; both
/// drawn in `face()`.
fn face_choice_node(
  parent : @view.View,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  press~ : () -> Unit,
  status? : () -> (String, Bool) = fn() { ("", false) },
  held? : () -> Bool = fn() { false },
  grounded? : (@view.View) -> Unit = fn(_) { () },
) -> Unit {
  let sample = fn() { @sf.t("web-pages.appearance.fonts.sampleRow") }
  @sf.choice_row_node(
    parent,
    name,
    on,
    press~,
    note=sample,
    label_made=fn(line) { face_in_node(line, name, face, face_name_words) },
    note_made=fn(n) { face_in_node(n, sample, face, face_sample_words) },
    trail=fn(e) {
      e.show(fn() { status().0 != "" }, fn(room) {
        @sf.style_node(room, fn() { face_status_room })
        // (whole at its line's end: the name before it gives way, cut on its line)
        room.shrink(Is(0.0)) |> ignore
        @sf.words_node(room, fn() { status().0 }, fn() {
          if status().1 {
            face_status_words.then(@sf.bad)
          } else {
            face_status_words
          }
        })
        |> ignore
      })
    },
    held~,
    grounded~,
  )
}

///|
/// Words `words()` of `style` in `parent`, set in host face `face()` (0: as the paragraph's own are, Ctx::rich's
/// `face`); `person()`: whether they are a person's words, in the face chosen for those (Ctx::rich's `words`).
fn face_in_node(
  parent : @view.View,
  words : () -> String,
  face : () -> Int,
  style : @ui.TextStyle,
  person? : () -> Bool,
) -> @view.View {
  parent.box(fn(w) {
    w
    .words_runs(By(fn() {
      let f = face()
      [@ui.span(words(), face=if f == 0 { None } else { Some(f) })]
    }))
    .words_look(By(fn() { @ui.style_words(style) }))
    .ink(By(fn() { @ui.style_ink(style) }))
    |> ignore
    match person {
      Some(p) => w.runs_look(By(fn() { { ..@view.runs_plain, words: p() } })) |> ignore
      None => ()
    }
  })
}

///|
/// 本机字体 in `parent`: a row, the family chosen's name in itself where one is (else 本机字体); pressed, a list of the
/// families installed here beside it (local_faces_node), opened or closed as it is let go; a fixture's
/// (MBUI_FIXTURE=settings-local-fonts) opened at the moment it is made.
fn local_face_row_node(parent : @view.View, core : Core, place : String, chosen : () -> String) -> Unit {
  let picked = fn() {
    let c = chosen()
    if c.has_prefix(local_prefix) {
      c.unsafe_substring(start=local_prefix.length(), end=c.length())
    } else {
      ""
    }
  }
  // the place's own host face holds it once chosen (faces.mbt): its words drawn in it
  let face = fn() { if picked() != "" { @settings.font_places.search(place).unwrap_or(0) + 1 } else { 0 } }
  let name = fn() { if picked() != "" { picked() } else { @sf.t("web-pages.appearance.fonts.local") } }
  parent.box(fn(r) {
    // (its ground's box, what its list stands beside: under it, from its start, as the popover before it stood by the
    // row's lit ground; lit while its list is open)
    let ground : Ref[@view.View?] = Ref(None)
    face_choice_node(
      r,
      name,
      face,
      fn() { picked() != "" },
      press=fn() { local_open.set(!local_open.untracked()) },
      held=fn() { local_open.get() },
      grounded=fn(g) { ground.val = Some(g) },
    )
    // (open while it says so: beside the row, closed for anything else and said so, let go with the row)
    let mine = Ref(0)
    r.reacts(fn() { local_open.get() }, fn(on) {
      if !on {
        if mine.val != 0 && @sf.presented_open_of(mine.val) {
          @sf.close_presented_of(mine.val)
        }
        return
      }
      guard mine.val == 0 || !@sf.presented_open_of(mine.val) else { return }
      // (no title of its own: its row, beside it, says what it is, as the popover before it had none)
      @sf.panel_nodes(
        "",
        fn(v, close) { local_faces_node(v, core, place, picked, close) },
        from=Node(ground.val.unwrap_or(r)),
        w=local_panel_w,
        side=Bottom,
        along=Start,
        gone=fn() { local_open.set(false) },
      )
      mine.val = @sf.last_presented()
    })
    r.owns(fn() {
      if mine.val != 0 && @sf.presented_open_of(mine.val) {
        @sf.close_presented_of(mine.val)
      }
    })
    |> ignore
    if fx_local_up.val {
      fx_local_up.val = false
      r.at_moment(r.logic_at(), fn() { local_open.set(true) }) |> ignore
    }
  })
  |> ignore
}

///|
/// 本机字体's list in `v` (its panel's body): its field to find one, the families installed here it finds (the first
/// local_most, scrolling past local_list_most), `picked()` checked, each pointed at tried in the chat; one pressed the
/// place's face, the panel closed (`close`).
fn local_faces_node(v : @view.View, core : Core, place : String, picked : () -> String, close : () -> Unit) -> Unit {
  // its field to find one (localSearch): a small panel's search, as a pick's, its ground setting it apart from the
  // list; empty each time it opens (a Field is one editor's: the list before still leaving holds its own)
  let find_field = @ui.Field::new()
  v.box(fn(f) {
    @sf.style_node(f, fn() { local_search })
    @sf.input_node(f, find_field, placeholder=@sf.t("web-pages.appearance.fonts.searchLocal"), small=true) |> ignore
  })
  |> ignore
  let shown = fn() {
    let find = find_field.text().trim(chars=" ").to_lower()
    let found = local_families().filter(fn(f) { find == "" || f.to_lower().contains(find) })
    if found.length() > local_most {
      found[:local_most].to_owned()
    } else {
      found
    }
  }
  v.pick(fn() { shown().length() == 0 }, fn(p, none) {
    if none {
      p.box(fn(n) {
        @sf.style_node(n, fn() { local_note_box })
        @sf.words_node(n, fn() { @sf.t("web-pages.appearance.fonts.noMatch") }, fn() { local_note }) |> ignore
      })
      |> ignore
    } else {
      p.box(fn(list) {
        list.max_height(Is(Some(local_list_most))) |> ignore
        list.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(rows) {
          rows.each(shown, fn(f) { f }, fn(row, f) {
            let f = f.untracked()
            fonts_tried_by(row, local_prefix + f)
            @sf.action_box_node(row, fn() { f }, fn(_) {
              @settings.set_font(core, place, Some(local_prefix + f))
              close()
            }, fn(b) {
              let hot = fn() { f == picked() || @sf.lit_node(b) }
              @sf.style_node(b, fn() { (if hot() { local_row_hot } else { local_row }).then(@sf.pick_high()) })
              b.radius(Is(@sf.small_panel_inner(@sf.r_menu))) |> ignore
              @sf.words_node(b, fn() { f }, fn() { local_name }) |> ignore
              b.show(fn() { f == picked() }, fn(k) {
                @sf.icon_node(k, "check", font_check, By(fn() { @sf.theme().p.text })) |> ignore
              })
            })
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    }
  })
}

///|
/// A chat as the faces set it in `parent`: their message in its bubble, an agent's under its name and when, its words
/// as a chat's are (body_size), on a card of the page; their bubble in its top right corner the ladder's inset in (a
/// block of the ladder's, tall enough not to be a capsule), the agent's words 20 in. `ui_face()` is the interface's
/// host face (0: as chosen); `text_face()` and `code_face()` are tried in their words (None: as chosen, Some(0): the
/// app's face for that kind); each as it is now.
fn font_preview_node(parent : @view.View, ui_face : () -> Int, text_face : () -> Int?, code_face : () -> Int?) -> Unit {
  @sf.page_card_node(parent, fn(card) {
    card.box(fn(col) {
      @sf.style_node(col, fn() { fp_column })
      col.box(fn(mine) {
        @sf.style_node(mine, fn() { fp_mine_room })
        mine.box(fn(clear) { clear.width_share(Is(fp_mine_clear_share / 100.0)).shrink(Is(0.0)) |> ignore }) |> ignore
        mine.box(fn(bubble) {
          @sf.style_node(bubble, fn() { fp_bubble })
          face_in_node(bubble, fn() { @sf.t("web-pages.appearance.fonts.sampleMine") }, fn() { text_face().unwrap_or(0) }, @sf.body, person=fn() {
            text_face() is None
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      col.box(fn(agent) {
        @sf.style_node(agent, fn() { fp_agent })
        agent.box(fn(who) {
          @sf.style_node(who, fn() { fp_who_line })
          face_in_node(who, fn() { "Claude" }, ui_face, fp_who_words) |> ignore
          face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_time_words) |> ignore
        })
        |> ignore
        @sf.markdown_node(
          agent,
          fn() {
            @sf.t("web-pages.appearance.fonts.sampleText") + "\n\n" + fp_sample_code + "\n\n" + @sf.t("web-pages.appearance.fonts.sampleAfter")
          },
          size=fn() { body_size },
          text_face~,
          code_face~,
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
// kept across runs: a value (no field of it changes)
let fp_sample_code : String = "```ts\nform.onsubmit = (e) => {\n  e.preventDefault(); // 0O 1lI\n};\n```"

///|
/// The preview's two messages 12 apart: theirs at the end in a bubble (18 round on the page's ground, 14 by 10 in), out
/// of the card's other top corner; the agent's name (14 semibold in the accent's ink) and when (12 subtle) over its
/// words, 4 apart.
// kept across runs: a value (no field of it changes)
let fp_column : @ui.Style = @ui.css("w=Full gap=S3")


///|
// kept across runs: a value (no field of it changes)
let fp_mine_room : @ui.Style = @ui.css("row w=Full justify=JEnd")

///|
/// What their bubble leaves at the row's start, a share of the row (percent): as wide as the chat's at most
/// (MineBubble: 78% of the column), its words wrapping in what is left.
let fp_mine_clear_share : Double = 22.0

///|
/// The bubble out of its row, the ladder's inset in from the card's top right, not its words' 20: concentric with its
/// corner there, a block's 18 of the ladder's, all four alike (its row on the column's edges, as the agent's words).
// kept across runs: a value (no field of it changes)
let fp_bubble : @ui.Style = @ui.css("radius=Xl2 bg=Bg px=S3_5 py=S2_5").then(
  @ui.style(mt=@sf.room_of(@sf.corner_inset - @sf.card_pad), mr=@sf.room_of(@sf.corner_inset - @sf.card_pad)),
)

///|
// kept across runs: a value (no field of it changes)
let fp_agent : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_who_line : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_who_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=AccentText)

///|
// kept across runs: a value (no field of it changes)
let fp_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle)


///|
// kept across runs: a value (no field of it changes)
let face_name_words : @ui.TextStyle = @ui.text_style(size=Title, color=Fg, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let face_sample_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full, max_lines=1)

///|
/// How a face stands, at its row's end: 140 wide at most, the small's subtle on one line.
// kept across runs: a value (no field of it changes)
let face_status_room : @ui.Style = @ui.style(max_w=@sf.face_status_most)

///|
// kept across runs: a value (no field of it changes)
let face_status_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
/// What a face of this machine's own is said as in the prefs' `fonts` (client/core-ts/src/fonts.ts LOCAL).
let local_prefix : String = "local:"

///|
/// The host face a family of this machine's is tried in (the preview, as a row of the list is pointed at), and the
/// family it holds now ("" none).
let local_try_face : Int = 14

///|
// kept across runs: said by local_tried; font_setting_reset empties it
let local_try_given : Ref[String] = Ref("")

///|
/// Whether 本机字体's list is open (said by its row, and as it closes).
// kept across runs: said by the row and the list; font_setting_reset puts it back
pub let local_open : @signals.Signal[Bool] = @signals.signal(false)

///|
/// 本机字体's list put up by a fixture's mode (MBUI_FIXTURE=settings-local-fonts), as its row is made.
// kept across runs: said by the fixture, taken by the row; font_setting_reset puts it back
pub let fx_local_up : Ref[Bool] = Ref(false)

///|
/// The host face family `family` of this machine's is tried in (given to it once); 0 where the host has none of it.
fn local_tried(family : String) -> Int {
  if local_try_given.val != family {
    @ui.face_clear(local_try_face)
    local_try_given.val = if @ui.face_add_family(local_try_face, family) { family } else { "" }
  }
  if local_try_given.val == family {
    local_try_face
  } else {
    0
  }
}

///|
/// The families installed here (the host's: @ui.local_font_families), in its order.
fn local_families() -> Array[String] {
  let parsed = @json.parse(@ui.local_font_families()) catch { _ => Json::null() }
  // in the host's order: its person's language's (local_font_families)
  match parsed {
    Array(a) => a.filter_map(fn(x) { if x is String(s) { Some(s) } else { None } })
    _ => []
  }
}

///|
/// The marks in the list of this machine's faces (its field's, the chosen one's check): 14.
let font_check : Double = 14.0

///|
/// The list (localPanel: 300 wide; localList: 320 high at most; the first 400 found).
let local_panel_w : Double = 300.0

///|
let local_list_most : Double = 320.0

///|
let local_most : Int = 400

///|
/// (localSearch: the field at the panel's padding, its rows 6 under it)
// kept across runs: a value (no field of it changes)
let local_search : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
/// (localRow: a menu's item, as high as the screen's (@sf.pick_high), the chosen on the hover ground, its check at its
/// end; round as a small panel's inner corner: local_faces_node)
// kept across runs: a value (no field of it changes)
let local_row : @ui.Style = @ui.css("row w=Full px=S2_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let local_row_hot : @ui.Style = local_row.then(@ui.css("bg=Hover"))

///|
/// (localName: the body's size, cut short)
// kept across runs: a value (no field of it changes)
let local_name : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, color=Fg, wrap=false, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let local_note_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S2")

///|
// kept across runs: a value (no field of it changes)
let local_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
/// A face's size to fetch, in thousands as the fonts' own pages say it (kB, MB, GB: Android's
/// Formatter.formatShortFileSize), no decimals from 10 up, one below.
fn face_size(bytes : Double) -> String {
  let mut v = bytes
  let mut unit = "B"
  for u in ["kB", "MB", "GB"] {
    if v <= 900.0 {
      break
    }
    v = v / 1000.0
    unit = u
  }
  let n = if unit == "B" || v >= 10.0 {
    v.round().to_int().to_string()
  } else {
    let tenths = (v * 10.0).round().to_int()
    "\{tenths / 10}.\{tenths % 10}"
  }
  n + " " + unit
}
