// V4 visual font settings page:
// - Sticky top header + 3-zone interactive live preview card (界面 / 正文 / 代码), separated by a 1px hairline
// - Scrollable body: 4 visual style cards (Aa 字 dual-script specimens), 3-role × 2-script pairing matrix,
//   contextual font picker with 32×32 glyph badges, and visual typography & ratio controls.

///|
/// Index into `font_presets` currently hovered (-1 = none). Hovering a style card previews all 6 slots in the sticky
/// card with zero `fonts.fetch` and zero `words_forgotten`.
let preset_trying : @signals.Signal[Int] = @signals.signal(-1, same=fn(a, b) { a == b })

///|
fn font_script_short_key(place : String, is_cjk : Bool) -> String {
  if is_cjk {
    "web-pages.appearance.fonts.scriptShort.cjk"
  } else if place == "code" {
    "web-pages.appearance.fonts.scriptShort.mono"
  } else {
    "web-pages.appearance.fonts.scriptShort.latin"
  }
}

///|
fn font_slot_sample_key(place : String, is_cjk : Bool) -> String {
  if is_cjk {
    "web-pages.appearance.fonts.sampleCjk"
  } else if place == "code" {
    "web-pages.appearance.fonts.sampleCode"
  } else {
    "web-pages.appearance.fonts.sampleLatin"
  }
}

///|
fn font_slot_glyph(place : String, is_cjk : Bool) -> String {
  if is_cjk {
    "字"
  } else if place == "code" {
    "</>"
  } else {
    "Aa"
  }
}

///|
/// V4 sticky-preview 字体 settings page: top sticky header + 3-zone live preview card above a clipped scroll body.
fn fonts_page_v4_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  match said {
    Some(f) => v.reacts(fn() { @sf.PageSaid::{ title: @sf.t("web-pages.appearance.fonts.title"), about: "", back: "" } }, f)
    None => ()
  }
  v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
  let wide_now = fn() { @sf.width_is_wide(width) }
  let scroll = @view.Scroll::list()
  let prefs = fn() { (core.topic)("prefs", Map([])).get().value }
  let chosen_of = fn(slot : String) { text(field(prefs(), "fonts"), slot) }
  let faces_view = fn() { field(prefs(), "faces") }
  let typo = fn() { field(prefs(), "typography") }
  let all = fn() { items(faces_view(), "list") }
  let files_state = fn() { (core.topic)("fonts", Map([])).get().value }
  let place = fn() { @settings.font_places[@settings.fonts_at.get()] }
  let script = fn() { @settings.fonts_script_at.get() }
  let active_slot = fn() { if script() == 1 { font_cjk_slot_of(place()) } else { place() } }
  let shown_in = fn(id : String) {
    let mut face = 0
    for i, f in all() {
      if text(Some(f), "id") == id {
        face = (core.face_preview)(id, i, items(Some(f), "files").iter().any(fn(x) { number(Some(x), "weight") == 0.0 }))
      }
    }
    face
  }
  let name_of_id = fn(id : String) -> String {
    if id == "" {
      return @sf.t("web-pages.appearance.fonts.default")
    }
    if id.has_prefix(local_prefix) {
      return id.unsafe_substring(start=local_prefix.length(), end=id.length())
    }
    for f in all() {
      if text(Some(f), "id") == id {
        return text(Some(f), "name")
      }
    }
    id
  }
  let own_of = fn(p : String) { if p == "code" { (core.own_code_face)() } else { 0 } }
  let own = fn() { own_of(place()) }
  let as_chosen = fn(p : String) {
    let id = chosen_of(p)
    if id == "" || (core.face_here)(id) {
      0
    } else {
      shown_in(id)
    }
  }
  let cjk_host_face = fn(id : String) -> Int {
    if id == "" || id == "none" {
      return 0
    }
    if @sfbase.faces_in[4] == id && @ui.face_given(@hostapi.face_ui_cjk) {
      return @hostapi.face_ui_cjk
    }
    if @sfbase.faces_in[5] == id && @ui.face_given(@hostapi.face_text_cjk) {
      return @hostapi.face_text_cjk
    }
    if @sfbase.faces_in[6] == id && @ui.face_given(@hostapi.face_code_cjk) {
      return @hostapi.face_code_cjk
    }
    if id.has_prefix(local_prefix) {
      return local_tried(id.unsafe_substring(start=local_prefix.length(), end=id.length()))
    }
    shown_in(id)
  }
  let live_cjk_scale = fn(p : String) -> Double {
    let key = font_cjk_scale_key(p)
    match cjk_scale_drag.get() {
      Some((k, pct)) if k == key => pct / 100.0
      Some((k, pct)) if p == "text" &&
        k == "uiCjkScale" &&
        chosen_of("textCjk") == "" &&
        text(faces_view(), "uiCjk") != "" &&
        !font_typo_bool(typo(), "textCjkScaleOwn", false) => pct / 100.0
      _ => font_typo_num(typo(), key, 100.0) / 100.0
    }
  }
  let live_cjk_weight = fn(p : String) -> Int {
    font_typo_num(typo(), font_cjk_weight_key(p), 0.0).round().to_int()
  }
  let preview_face_opt = fn(id : String?, role : String) -> Int {
    match id {
      Some(s) if s != "" =>
        match shown_in(s) {
          0 => own_of(role)
          f => f
        }
      _ => own_of(role)
    }
  }
  let try_primary_face = fn() -> Int? {
    if script() != 0 {
      return None
    }
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
    let pi = preset_trying.get()
    if pi >= 0 && pi < font_presets.length() {
      return preview_face_opt(font_presets[pi].ui, "ui")
    }
    match (place(), try_primary_face()) {
      ("ui", Some(f)) => f
      _ => as_chosen("ui")
    }
  }
  let text_face = fn() {
    let pi = preset_trying.get()
    if pi >= 0 && pi < font_presets.length() {
      let pr = font_presets[pi]
      let id = match pr.text {
        Some(s) => Some(s)
        None => pr.ui
      }
      return Some(preview_face_opt(id, "text"))
    }
    match (place(), try_primary_face()) {
      ("text", Some(f)) => Some(f)
      ("ui", Some(f)) if chosen_of("text") == "" => Some(f)
      _ => {
        let face = if chosen_of("text") == "" { ui_face() } else { as_chosen("text") }
        if face == 0 { None } else { Some(face) }
      }
    }
  }
  let code_face = fn() {
    let pi = preset_trying.get()
    if pi >= 0 && pi < font_presets.length() {
      return Some(preview_face_opt(font_presets[pi].code, "code"))
    }
    match (place(), try_primary_face()) {
      ("code", Some(f)) => Some(f)
      _ => {
        let face = as_chosen("code")
        if face == 0 { None } else { Some(face) }
      }
    }
  }
  let cjk_override_for = fn(role : String) -> @view.CjkOverride? {
    let pi = preset_trying.get()
    if pi >= 0 && pi < font_presets.length() {
      let pr = font_presets[pi]
      let cjk_id = match role {
        "ui" => pr.ui_cjk
        "text" =>
          match pr.text_cjk {
            Some(s) => Some(s)
            None => pr.ui_cjk
          }
        _ => pr.code_cjk
      }
      return match cjk_id {
        Some(id) if id != "" => Some({ face: cjk_host_face(id), scale: 1.0, weight_off: 0 })
        _ => Some({ face: 0, scale: 1.0, weight_off: 0 })
      }
    }
    let scale = live_cjk_scale(role)
    let weight_off = live_cjk_weight(role)
    let tried = if script() == 1 { fonts_trying.get() } else { "" }
    let trying_this = tried != "" && (
      place() == role || (place() == "ui" && role == "text" && chosen_of("textCjk") == "")
    )
    if trying_this {
      if tried == "\u{2}" {
        return Some({ face: 0, scale: 1.0, weight_off: 0 })
      }
      if tried == "\u{1}" {
        if role == "text" && place() == "text" {
          let ui_id = text(faces_view(), "uiCjk")
          let f = cjk_host_face(ui_id)
          return Some({ face: f, scale, weight_off })
        }
        return Some({ face: 0, scale: 1.0, weight_off: 0 })
      }
      let f = if tried.has_prefix(local_prefix) {
        local_tried(tried.unsafe_substring(start=local_prefix.length(), end=tried.length()))
      } else {
        cjk_host_face(tried)
      }
      return if f > 0 { Some({ face: f, scale, weight_off }) } else { None }
    }
    let active_id = text(faces_view(), font_cjk_slot_of(role))
    if active_id != "" {
      let f = cjk_host_face(active_id)
      if f > 0 {
        return Some({ face: f, scale, weight_off })
      }
    }
    None
  }
  let ui_cjk = fn() { cjk_override_for("ui") }
  let text_cjk = fn() { cjk_override_for("text") }
  let code_cjk = fn() { cjk_override_for("code") }
  let preview_prose_scale = fn() {
    match text_size_drag.get() {
      Some(pct) => pct / 100.0
      None => font_typo_num(typo(), "textSize", 100.0) / 100.0
    }
  }
  let preview_code_scale = fn() {
    match code_scale_drag.get() {
      Some(pct) => pct / 100.0
      None => font_typo_num(typo(), "codeScale", 100.0) / 100.0
    }
  }
  let preview_line_scale = fn() {
    match text(typo(), "lineHeight") {
      "compact" => 0.92
      "relaxed" => 1.14
      _ => 1.0
    }
  }
  let any_customized = fn() -> Bool {
    if !font_preset_matches(font_presets[0], chosen_of) {
      return true
    }
    font_typo_custom_count(typo()) > 0
  }
  let reset_all = fn() {
    @settings.set_fonts_preset(core, preset_patch(font_presets[0]), reset_cjk_optics=true)
    @settings.set_typography(core, Json::null())
  }
  let over_faces : @signals.Signal[Bool] = @signals.signal(false)
  let in_pane = v.lent(@sf.pane_lent).unwrap_or(false)
  v.pick(wide_now, fn(p, is_wide) {
    @sf.look_lent(p, @sf.look_for(if is_wide { 1000.0 } else { 320.0 }))
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    // Helper to place content in the page's centered column (matching wide_page_node / narrow_page_node).
    let in_col = fn(parent : @view.View, make : (@view.View) -> Unit) {
      if is_wide {
        let side = if in_pane { 0.0 } else { @sf.desk_lane_in }
        parent.box(fn(lane) {
          lane.row(Is(true)).padding(Is((side, 0.0, side, 0.0))).lies_along(Is(Middle)) |> ignore
          lane.box(fn(col) {
            col
            .grow(Is(1.0))
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .max_width(Is(Some(@sf.desk_lane_most)))
            .padding(Is((@sf.desk_column_in, 0.0, @sf.desk_column_in, 0.0)))
            |> ignore
            make(col)
          })
          |> ignore
        })
        |> ignore
      } else {
        parent.box(fn(room) {
          room.padding(Is((12.0, 0.0, 12.0, 0.0))) |> ignore
          make(room)
        })
        |> ignore
      }
    }
    // === 1. Sticky top section (header + live 3-zone preview + 1px hairline) ===
    p.box(fn(sticky) {
      sticky.shrink(Is(0.0)) |> ignore
      // Frame top inset (status bar / safe area)
      sticky.show(at_once=true, fn() { frame().top > 0.0 }, fn(top_sp) {
        top_sp.height(By(fn() { Some(frame().top) })) |> ignore
      })
      // Compact page header
      in_col(sticky, fn(col) {
        font_sticky_header_node(col, is_wide, on_back, frame, any_customized, reset_all)
      })
      // Sticky live preview card (tallest-locked while hovering cards/rows or dragging sliders)
      in_col(sticky, fn(col) {
        col.box(fn(wrap) {
          wrap.padding(Is((0.0, 0.0, 0.0, if is_wide { 12.0 } else { 10.0 }))) |> ignore
          wrap.by_room(fn(held, room) {
            held.box(fn(cell) {
              let chat : Ref[@view.View?] = Ref(None)
              let tallest = Ref(0.0)
              cell.box(fn(card_host) {
                chat.val = Some(card_host)
                font_preview_v4_node(
                  card_host,
                  place,
                  script,
                  ui_face,
                  text_face,
                  code_face,
                  ui_cjk,
                  text_cjk,
                  code_cjk,
                  preview_prose_scale,
                  preview_code_scale,
                  preview_line_scale,
                )
              })
              |> ignore
              cell.min_height(By(fn() {
                match chat.val {
                  Some(card_host) => {
                    let tall = room.tall(card_host)
                    let lock_tall = over_faces.get() ||
                      preset_trying.get() >= 0 ||
                      cjk_scale_drag.get() is Some(_) ||
                      text_size_drag.get() is Some(_) ||
                      code_scale_drag.get() is Some(_)
                    if lock_tall {
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
        })
        |> ignore
      })
      // 1px hairline separating sticky preview from scrollable controls
      sticky.box(fn(sep) { @sf.style_node(sep, fn() { @sf.rule_line }) }) |> ignore
    })
    |> ignore
    // === 2. Clipped scrollable controls area ===
    p.box(fn(body_wrap) {
      body_wrap.grow(Is(1.0)).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
      body_wrap.scrolls(scroll, slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(inner) {
        in_col(inner, fn(col) {
          col.padding(By(fn() {
            let foot = (if is_wide { 80.0 } else { 30.0 }) + frame().foot
            (0.0, if is_wide { 16.0 } else { 12.0 }, 0.0, foot)
          }))
          .gap(Is(if is_wide { 18.0 } else { 14.0 }))
          |> ignore
          // Block 1: 4 visual style cards
          font_style_cards_node(col, core, is_wide, all, files_state, chosen_of, shown_in)
          // Block 2: 3-role × 2-script pairing matrix
          font_pairing_matrix_node(col, is_wide, place, script, chosen_of, name_of_id)
          // Block 3: Current-slot contextual font picker
          col.box(fn(picker_sec) {
            @sf.style_node(picker_sec, fn() { fp_v4_section })
            @sf.words_node(
              picker_sec,
              fn() {
                @sf.t(
                  "web-pages.appearance.fonts.picker.forSlot",
                  args=[
                    ("place", @sf.t("web-pages.appearance.fonts." + place())),
                    ("script", @sf.t(font_script_short_key(place(), script() == 1))),
                  ],
                )
              },
              fn() { fp_v4_sec_heading },
            )
            |> ignore
            picker_sec.box(fn(faces) {
              faces.points(Is(true)) |> ignore
              faces.reacts(fn() { faces.pointed_in() }, fn(on) { over_faces.set(on) })
              faces.owns(fn() { over_faces.set(false) }) |> ignore
              @sf.group_node(faces, fn(g) {
                g.pick(active_slot, fn(held, slot) {
                  @sf.group_rows_node(held, fn(rows) {
                    face_rows_node(
                      rows,
                      core,
                      slot,
                      place(),
                      script() == 1,
                      all,
                      own,
                      shown_in,
                      files_state,
                      chosen_of,
                      name_of_id,
                    )
                  })
                })
              })
            })
            |> ignore
          })
          |> ignore
          // Block 4: Collapsible visual typography & ratio details
          font_advanced_node(col, core, place, faces_view, chosen_of, typo, ui_face, text_face, code_face, cjk_host_face)
        })
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// Compact sticky header: Wide shows title + optional back + right "恢复默认" when customized; Narrow shows back +
/// title + optional right "恢复默认" when customized.
fn font_sticky_header_node(
  parent : @view.View,
  is_wide : Bool,
  on_back : () -> Unit,
  frame : () -> PageFrame,
  any_customized : () -> Bool,
  reset_all : () -> Unit,
) -> Unit {
  parent.show(at_once=true, fn() { !frame().named || any_customized() }, fn(head) {
    @sf.style_node(head, fn() { if is_wide { fp_v4_head_wide } else { fp_v4_head_narrow } })
    // Left side: optional back button + page title (hidden if frame bar already names the page)
    head.box(fn(left) {
      @sf.style_node(left, fn() { fp_v4_head_left })
      left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      left.show(at_once=true, fn() { !frame().named && frame().back is Some(_) }, fn(bk) {
        @sf.action_box_node(
          bk,
          fn() { frame().back.unwrap_or("") },
          fn(_) { on_back() },
          fn(btn) {
            let hot = fn() { @sf.lit_node(btn) }
            @sf.style_node(btn, fn() { if hot() { fp_v4_back_hot } else { fp_v4_back } })
            @sf.icon_node(btn, "chevron-left", 16.0, By(fn() { @sf.theme().p.muted })) |> ignore
          },
        )
        |> ignore
      })
      left.show(at_once=true, fn() { !frame().named }, fn(tw) {
        @sf.words_node(
          tw,
          fn() { @sf.t("web-pages.appearance.fonts.title") },
          fn() { if is_wide { fp_v4_title_wide } else { fp_v4_title_narrow } },
        )
        |> ignore
      })
    })
    |> ignore
    // Right side: lightweight reset button shown only when any font or typography differs from default
    head.show(at_once=true, any_customized, fn(rw) {
      @sf.action_box_node(
        rw,
        fn() { @sf.t("web-pages.appearance.fonts.resetAll") },
        fn(_) { reset_all() },
        fn(btn) {
          let hot = fn() { @sf.lit_node(btn) }
          @sf.style_node(btn, fn() { if hot() { fp_v4_reset_hot } else { fp_v4_reset } })
          @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn() { fp_v4_reset_words }) |> ignore
        },
      )
      |> ignore
    })
  })
}

///|
/// Interactive 3-zone sticky live preview card: clicking each zone switches active role (`界面` / `正文` / `代码`)
/// and highlights it with a 2.5pt left accent bar (zero horizontal layout shift).
fn font_preview_v4_node(
  parent : @view.View,
  place : () -> String,
  script : () -> Int,
  ui_face : () -> Int,
  text_face : () -> Int?,
  code_face : () -> Int?,
  ui_cjk : () -> @view.CjkOverride?,
  text_cjk : () -> @view.CjkOverride?,
  code_cjk : () -> @view.CjkOverride?,
  prose_scale : () -> Double,
  code_scale : () -> Double,
  line_scale : () -> Double,
) -> Unit {
  let select_role = fn(idx : Int) {
    if @signals.untracked(fn() { @settings.fonts_at.get() }) != idx {
      fonts_trying.set("")
      @settings.fonts_at.set(idx)
    }
  }
  let editing_badge = fn() {
    @sf.t(
      "web-pages.appearance.fonts.previewEditing",
      args=[
        ("place", @sf.t("web-pages.appearance.fonts." + place())),
        ("script", @sf.t(font_script_short_key(place(), script() == 1))),
      ],
    )
  }
  let zone_box = fn(col : @view.View, role_idx : Int, role_key : String, body : (@view.View) -> Unit) {
    let active = fn() { @settings.fonts_at.get() == role_idx }
    @sf.action_box_node(
      col,
      fn() { @sf.t("web-pages.appearance.fonts." + role_key) },
      fn(_) { select_role(role_idx) },
      fn(z) {
        @sf.style_node(z, fn() { if active() { fp_v4_zone_on } else { fp_v4_zone } })
        z.radius(Is(10.0)).min_width(Is(Some(0.0))) |> ignore
        // Fixed 2.5pt left accent bar (transparent when inactive -> zero horizontal shift)
        z.box(fn(bar) {
          bar
          .width(Is(Some(2.5)))
          .shrink(Is(0.0))
          .radius(Is(2.0))
          .ground(By(fn() { if active() { @sf.theme().p.accent } else { 0L } }))
          |> ignore
        })
        |> ignore
        z.box(fn(content) {
          content.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
          body(content)
        })
        |> ignore
      },
    )
    |> ignore
  }
  parent.box(fn(card) {
    @sf.style_node(card, fn() { fp_v4_preview_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    // Zone 1: 界面 (agent header + timestamp + editing badge)
    zone_box(card, 0, "ui", fn(c) {
      c.box(fn(top_row) {
        @sf.style_node(top_row, fn() { fp_v4_who_row })
        top_row.box(fn(who) {
          @sf.style_node(who, fn() { fp_who_line })
          who.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          face_in_node(who, fn() { "Claude" }, ui_face, fp_who_words, cjk=ui_cjk) |> ignore
          face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_time_words, cjk=ui_cjk)
          |> ignore
        })
        |> ignore
        top_row.box(fn(badge) {
          @sf.style_node(badge, fn() { fp_v4_edit_badge })
          badge.shrink(Is(0.0)) |> ignore
          @sf.words_node(badge, editing_badge, fn() { fp_v4_edit_badge_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // Zone 2: 正文 (user bubble + agent prose)
    zone_box(card, 1, "text", fn(c) {
      c.box(fn(mine) {
        @sf.style_node(mine, fn() { fp_mine_room })
        mine.box(fn(clear) { clear.width_share(Is(fp_mine_clear_share / 100.0)).shrink(Is(0.0)) |> ignore }) |> ignore
        mine.box(fn(bubble) {
          @sf.style_node(bubble, fn() { fp_v4_bubble })
          face_in_node(
            bubble,
            fn() { @sf.t("web-pages.appearance.fonts.sampleMine") },
            fn() { text_face().unwrap_or(0) },
            @sf.body,
            person=fn() { text_face() is None },
            cjk=text_cjk,
            size_scale=prose_scale,
            line_scale~,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
      @sf.markdown_node(
        c,
        fn() {
          @sf.t("web-pages.appearance.fonts.sampleText") + "\n\n" + @sf.t("web-pages.appearance.fonts.sampleAfter")
        },
        size=fn() { body_size * prose_scale() },
        text_face~,
        code_face~,
        typography=fn() {
          {
            prose_scale: prose_scale(),
            code_scale: code_scale(),
            line_scale: line_scale(),
            text_cjk: text_cjk(),
            code_cjk: code_cjk(),
          }
        },
      )
      |> ignore
    })
    // Zone 3: 代码 (3-line TypeScript code block with ligatures + CJK comment)
    zone_box(card, 2, "code", fn(c) {
      @sf.markdown_node(
        c,
        fn() { fp_sample_code },
        size=fn() { body_size * prose_scale() },
        text_face~,
        code_face~,
        typography=fn() {
          {
            prose_scale: prose_scale(),
            code_scale: code_scale(),
            line_scale: line_scale(),
            text_cjk: text_cjk(),
            code_cjk: code_cjk(),
          }
        },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// 4 visual style cards: Wide 4-column row, Narrow 2×2 grid. Each card renders dual-script `Aa 字` in the preset's
/// preview faces, hovers live into the sticky preview with 0 fetches / 0 words_forgotten, and clicks to apply.
fn font_style_cards_node(
  parent : @view.View,
  core : Core,
  is_wide : Bool,
  all : () -> Array[Json],
  files_state : () -> Json?,
  chosen_of : (String) -> String,
  shown_in : (String) -> Int,
) -> Unit {
  let card_at = fn(row : @view.View, idx : Int) {
    let p = font_presets[idx]
    let on = fn() { font_preset_matches(p, chosen_of) }
    let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + p.key) }
    let sub = fn() { @sf.t("web-pages.appearance.fonts.preset." + p.key + "Sub") }
    let bytes = fn() {
      let kept = items(files_state(), "kept")
      preset_needed_bytes(p, all(), kept, core.face_here)
    }
    let latin_face = fn() {
      match p.ui {
        Some(id) => shown_in(id)
        None => 0
      }
    }
    let cjk_face = fn() {
      let cid = match p.text_cjk {
        Some(id) => Some(id)
        None => p.ui_cjk
      }
      match cid {
        Some(id) => shown_in(id)
        None => 0
      }
    }
    row.box(fn(slot_wrap) {
      slot_wrap.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      slot_wrap.reacts(fn() { @sf.lit_in_node(slot_wrap) }, fn(lit) {
        if lit {
          preset_trying.set(idx)
        } else if preset_trying.untracked() == idx {
          preset_trying.set(-1)
        }
      })
      slot_wrap.owns(fn() {
        if preset_trying.untracked() == idx {
          preset_trying.set(-1)
        }
      })
      |> ignore
      @sf.action_box_node(
        slot_wrap,
        title,
        fn(_) { @settings.set_fonts_preset(core, preset_patch(p), reset_cjk_optics=true) },
        fn(card) {
          let lit = fn() { @sf.lit_node(card) }
          @sf.style_node(card, fn() {
            if on() {
              fp_v4_style_card_on
            } else if lit() {
              fp_v4_style_card_hot
            } else {
              fp_v4_style_card
            }
          })
          card.edge(By(fn() {
            if on() {
              (1.5, @sf.theme().p.accent)
            } else if lit() {
              (0.5, @sf.theme().p.line_strong)
            } else {
              (0.5, @sf.theme().p.line)
            }
          }))
          |> ignore
          // Top row: large dual-script specimen "Aa 字" + right checkmark / subtle size hint
          card.box(fn(top) {
            @sf.style_node(top, fn() { fp_v4_style_top })
            top.box(fn(spec) {
              @sf.style_node(spec, fn() { fp_v4_spec_row })
              face_in_node(spec, fn() { "Aa" }, latin_face, fp_v4_spec_words) |> ignore
              face_in_node(spec, fn() { "字" }, cjk_face, fp_v4_spec_words) |> ignore
            })
            |> ignore
            top.show(at_once=true, on, fn(ck) {
              @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.accent })) |> ignore
            })
            top.show(at_once=true, fn() { !on() && bytes() > 0.0 }, fn(sz) {
              @sf.words_node(sz, fn() { face_size(bytes()) }, fn() { fp_preset_size }) |> ignore
            })
          })
          |> ignore
          // Title + concise subtitle
          @sf.words_node(card, title, fn() { if on() { fp_preset_title_on } else { fp_preset_title } }) |> ignore
          @sf.words_node(card, sub, fn() { fp_v4_style_sub }) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v4_section })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.presets") }, fn() { fp_v4_sec_heading }) |> ignore
    if is_wide {
      sec.box(fn(row) {
        @sf.style_node(row, fn() { fp_v4_cards_row_wide })
        for i in 0..<4 {
          card_at(row, i)
        }
      })
      |> ignore
    } else {
      sec.box(fn(grid) {
        @sf.style_node(grid, fn() { fp_v4_cards_grid_narrow })
        grid.box(fn(r1) {
          @sf.style_node(r1, fn() { fp_v4_cards_row_narrow })
          card_at(r1, 0)
          card_at(r1, 1)
        })
        |> ignore
        grid.box(fn(r2) {
          @sf.style_node(r2, fn() { fp_v4_cards_row_narrow })
          card_at(r2, 2)
          card_at(r2, 3)
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// 3-role × 2-script font pairing overview card: replaces the old 2-row segmented tabs with a scannable overview of
/// all 6 font slots. Clicking any slot activates it in the picker below and highlights the matching preview zone.
fn font_pairing_matrix_node(
  parent : @view.View,
  is_wide : Bool,
  place : () -> String,
  script : () -> Int,
  chosen_of : (String) -> String,
  name_of_id : (String) -> String,
) -> Unit {
  let slot_display = fn(role : String, is_cjk : Bool) -> String {
    let slot = if is_cjk { font_cjk_slot_of(role) } else { role }
    let raw = chosen_of(slot)
    if raw == "" {
      if role == "text" {
        @sf.t("web-pages.appearance.fonts.followUi")
      } else {
        @sf.t("web-pages.appearance.fonts.default")
      }
    } else if raw == "none" {
      @sf.t("web-pages.appearance.fonts.cjkNone")
    } else {
      name_of_id(raw)
    }
  }
  let slot_btn = fn(row : @view.View, role_idx : Int, role : String, script_idx : Int) {
    let is_cjk = script_idx == 1
    let active = fn() { place() == role && script() == script_idx }
    let prefix = fn() { @sf.t(font_script_short_key(role, is_cjk)) }
    let val = fn() { slot_display(role, is_cjk) }
    let label = fn() { prefix() + " · " + val() }
    @sf.action_box_node(
      row,
      label,
      fn(_) {
        fonts_trying.set("")
        @settings.fonts_at.set(role_idx)
        @settings.fonts_script_at.set(script_idx)
      },
      fn(btn) {
        let hot = fn() { @sf.lit_node(btn) }
        @sf.style_node(btn, fn() {
          if active() {
            fp_v4_slot_btn_on
          } else if hot() {
            fp_v4_slot_btn_hot
          } else {
            fp_v4_slot_btn
          }
        })
        btn.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).radius(Is(10.0)).edge(By(fn() {
          if active() {
            (1.0, @sf.theme().p.accent)
          } else if hot() {
            (0.5, @sf.theme().p.line_strong)
          } else {
            (0.5, @sf.theme().p.line)
          }
        }))
        |> ignore
        @sf.words_node(btn, prefix, fn() { if active() { fp_v4_slot_tag_on } else { fp_v4_slot_tag } }) |> ignore
        @sf.words_node(btn, val, fn() { if active() { fp_v4_slot_val_on } else { fp_v4_slot_val } }) |> ignore
      },
    )
    |> ignore
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v4_section })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.matrix.title") }, fn() { fp_v4_sec_heading }) |> ignore
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v4_matrix_card })
      card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      let roles : Array[(Int, String, String)] = [
        (0, "ui", "web-pages.appearance.fonts.matrix.uiSub"),
        (1, "text", "web-pages.appearance.fonts.matrix.textSub"),
        (2, "code", "web-pages.appearance.fonts.matrix.codeSub"),
      ]
      for item in roles {
        let (idx, role, sub_key) = item
        card.box(fn(r) {
          @sf.style_node(r, fn() { if is_wide { fp_v4_matrix_row_wide } else { fp_v4_matrix_row_narrow } })
          r.box(fn(meta) {
            @sf.style_node(meta, fn() { if is_wide { fp_v4_matrix_meta_wide } else { fp_v4_matrix_meta_narrow } })
            if is_wide {
              meta.width(Is(Some(128.0))).shrink(Is(0.0)) |> ignore
            }
            @sf.words_node(meta, fn() { @sf.t("web-pages.appearance.fonts." + role) }, fn() { fp_v4_matrix_role })
            |> ignore
            @sf.words_node(meta, fn() { @sf.t(sub_key) }, fn() { fp_v4_matrix_sub }) |> ignore
          })
          |> ignore
          r.box(fn(slots) {
            @sf.style_node(slots, fn() { fp_v4_matrix_slots })
            slots.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            slot_btn(slots, idx, role, 0)
            slot_btn(slots, idx, role, 1)
          })
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// 32×32 rounded glyph specimen badge (`Aa`, `字`, or `</>`) rendered in the font's own face.
fn face_glyph_badge_node(
  parent : @view.View,
  glyph : () -> String,
  face : () -> Int,
  active : () -> Bool,
) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { if active() { fp_v4_glyph_badge_on } else { fp_v4_glyph_badge } })
    b.width(Is(Some(28.0))).height(Is(Some(28.0))).shrink(Is(0.0)) |> ignore
    face_in_node(b, glyph, face, if active() { fp_v4_glyph_words_on } else { fp_v4_glyph_words }) |> ignore
  })
  |> ignore
}

///|
/// Visual slider row with small/large flank glyphs (`A` / `A` or `</>` / `</>`) and tabular `%` readout.
fn font_visual_slider_row_node(
  parent : @view.View,
  label : () -> String,
  left_glyph : String,
  right_glyph : String,
  value : () -> Double,
  on_change : (Double) -> Unit,
  on_commit : (Double) -> Unit,
  min~ : Double,
  max~ : Double,
  step~ : Double,
) -> Unit {
  parent.box(fn(col) {
    @sf.style_node(col, fn() { fp_slider_col })
    col.box(fn(head) {
      @sf.style_node(head, fn() { fp_slider_head })
      head.box(fn(l) {
        l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(l, label, fn() { fp_adv_row_label }) |> ignore
      })
      |> ignore
      let val_w = @sf.words_node(head, fn() { "\{value().round().to_int()}%" }, fn() { fp_adv_row_value })
      @sf.on_baseline(val_w, Body, Meta, weight=400, own_weight=500).words_tabular(Is(Some(true))) |> ignore
    })
    |> ignore
    col.box(fn(track_row) {
      @sf.style_node(track_row, fn() { fp_v4_slider_track_row })
      @sf.words_node(track_row, fn() { left_glyph }, fn() { fp_v4_glyph_sm }) |> ignore
      track_row.box(fn(mid) {
        mid.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.value_slider_node(
          mid,
          label,
          value,
          on_change,
          min~,
          max~,
          step~,
          format=fn(n) { "\{n}%" },
          on_commit~,
        )
        |> ignore
      })
      |> ignore
      @sf.words_node(track_row, fn() { right_glyph }, fn() { fp_v4_glyph_lg }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Visual 3-card line-height selector (`紧凑` / `标准` / `舒展`), each drawing 3 horizontal bars with 2px / 4px / 6px gaps.
fn font_line_height_cards_node(
  parent : @view.View,
  label : () -> String,
  chosen : () -> String,
  choose : (String) -> Unit,
) -> Unit {
  parent.box(fn(col) {
    @sf.style_node(col, fn() { fp_v4_lh_col })
    @sf.words_node(col, label, fn() { fp_adv_row_label }) |> ignore
    col.box(fn(row) {
      @sf.style_node(row, fn() { fp_v4_lh_row })
      let opts : Array[(String, String, Double)] = [
        ("compact", "web-pages.appearance.fonts.advanced.lineCompact", 2.0),
        ("normal", "web-pages.appearance.fonts.advanced.lineNormal", 4.0),
        ("relaxed", "web-pages.appearance.fonts.advanced.lineRelaxed", 6.0),
      ]
      for opt in opts {
        let (key, lkey, bar_gap) = opt
        let on = fn() {
          let cur = chosen()
          if key == "normal" { cur == "" || cur == "normal" } else { cur == key }
        }
        @sf.action_box_node(
          row,
          fn() { @sf.t(lkey) },
          fn(_) { choose(key) },
          fn(card) {
            let hot = fn() { @sf.lit_node(card) }
            @sf.style_node(card, fn() {
              if on() {
                fp_v4_lh_card_on
              } else if hot() {
                fp_v4_lh_card_hot
              } else {
                fp_v4_lh_card
              }
            })
            card.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).edge(By(fn() {
              if on() {
                (1.0, @sf.theme().p.accent)
              } else if hot() {
                (0.5, @sf.theme().p.line_strong)
              } else {
                (0.5, @sf.theme().p.line)
              }
            }))
            |> ignore
            // 3-bar icon with exact 2px / 4px / 6px spacing
            card.box(fn(bars) {
              bars.gap(Is(bar_gap)).height(Is(Some(18.0))).lies_along(Is(Middle)).lines_up(Is(Some(Middle))) |> ignore
              for w in [22.0, 22.0, 15.0] {
                bars.box(fn(line) {
                  line
                  .width(Is(Some(w)))
                  .height(Is(Some(2.0)))
                  .radius(Is(1.0))
                  .ground(By(fn() { if on() { @sf.theme().p.accent } else { @sf.theme().p.muted } }))
                  |> ignore
                })
                |> ignore
              }
            })
            |> ignore
            @sf.words_node(card, fn() { @sf.t(lkey) }, fn() { if on() { fp_v4_slot_val_on } else { fp_v4_slot_val } })
            |> ignore
          },
        )
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// Live `Aa 字体` CJK-Latin ratio comparison pill for the active role's CJK scale & weight offset.
fn font_cjk_ratio_badge_node(
  parent : @view.View,
  primary_face : () -> Int,
  cjk_override : () -> @view.CjkOverride?,
) -> Unit {
  parent.box(fn(pill) {
    @sf.style_node(pill, fn() { fp_v4_ratio_pill })
    pill.shrink(Is(0.0)) |> ignore
    face_in_node(pill, fn() { "Aa 字体" }, primary_face, fp_v4_ratio_words, cjk=cjk_override) |> ignore
  })
  |> ignore
}

///|
/// Visual `正文Abc` vs `正文 Abc` comparison pills for the CJK-Latin auto-space switch.
fn font_autospace_pills_node(parent : @view.View, on : () -> Bool) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() { fp_v4_cmp_row })
    row.box(fn(p_off) {
      @sf.style_node(p_off, fn() { if !on() { fp_v4_cmp_pill_on } else { fp_v4_cmp_pill } })
      @sf.words_node(
        p_off,
        fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceOff") },
        fn() { if !on() { fp_v4_cmp_words_on } else { fp_v4_cmp_words } },
      )
      |> ignore
    })
    |> ignore
    row.box(fn(p_on) {
      @sf.style_node(p_on, fn() { if on() { fp_v4_cmp_pill_on } else { fp_v4_cmp_pill } })
      @sf.words_node(
        p_on,
        fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceOn") },
        fn() { if on() { fp_v4_cmp_words_on } else { fp_v4_cmp_words } },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Live `=>  !==  ===` ligature preview pill rendered in the current code face.
fn font_ligature_sample_node(parent : @view.View, code_face : () -> Int?) -> Unit {
  parent.box(fn(pill) {
    @sf.style_node(pill, fn() { fp_v4_cmp_pill })
    face_in_node(pill, fn() { "=>  !==  ===" }, fn() { code_face().unwrap_or(0) }, fp_v4_lig_words) |> ignore
  })
  |> ignore
}

///|
fn font_typo_custom_count(t : Json?) -> Int {
  let mut n = 0
  if font_typo_num(t, "textSize", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if font_typo_num(t, "codeScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if text(t, "lineHeight") != "" && text(t, "lineHeight") != "normal" {
    n = n + 1
  }
  if font_typo_num(t, "uiCjkScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if font_typo_num(t, "textCjkScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if font_typo_num(t, "codeCjkScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if font_typo_num(t, "uiCjkWeight", 0.0).round().to_int() != 0 {
    n = n + 1
  }
  if font_typo_num(t, "textCjkWeight", 0.0).round().to_int() != 0 {
    n = n + 1
  }
  if font_typo_num(t, "codeCjkWeight", 0.0).round().to_int() != 0 {
    n = n + 1
  }
  if !font_typo_bool(t, "cjkAutoSpace", true) {
    n = n + 1
  }
  if !font_typo_bool(t, "codeLigatures", true) {
    n = n + 1
  }
  n
}

// --- V4 Styles ---

///|
// kept across runs: a value (no field of it changes)
let fp_v4_head_wide : @ui.Style = @ui.css("row w=Full pt=S4 pb=S2_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_head_narrow : @ui.Style = @ui.css("row w=Full pt=S2 pb=S2 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_head_left : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_back : @ui.Style = @ui.css("row p=S1 radius=Md align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_back_hot : @ui.Style = fp_v4_back.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let fp_v4_title_wide : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_title_narrow : @ui.TextStyle = @ui.text_style(size=Title, weight=Semibold, color=Fg, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_reset : @ui.Style = @ui.css("px=S2_5 py=S1 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_reset_hot : @ui.Style = fp_v4_reset.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let fp_v4_reset_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_preview_card : @ui.Style = @ui.css("w=Full p=S2 gap=S1 radius=Xl2 bg=Card")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_zone : @ui.Style = @ui.css("row w=Full gap=S2 p=S1 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_zone_on : @ui.Style = fp_v4_zone.then(@ui.css("bg=AccentBg"))

///|
// kept across runs: a value (no field of it changes)
let fp_v4_who_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_edit_badge : @ui.Style = @ui.css("px=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_edit_badge_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_bubble : @ui.Style = @ui.css("radius=Md bg=Bg px=S3 py=S1_5")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_section : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_sec_heading : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cards_row_wide : @ui.Style = @ui.css("row w=Full gap=S2_5 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cards_grid_narrow : @ui.Style = @ui.css("w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cards_row_narrow : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_style_card : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=Card")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_style_card_hot : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_style_card_on : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=AccentBg")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_style_top : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter pb=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_spec_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_spec_words : @ui.TextStyle = @ui.text_style(size=Heading, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_style_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_card : @ui.Style = @ui.css("w=Full p=S2 gap=S2 radius=Xl2 bg=Card")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_row_wide : @ui.Style = @ui.css("row w=Full gap=S3 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_row_narrow : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_meta_wide : @ui.Style = @ui.css("gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_meta_narrow : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_role : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_slots : @ui.Style = @ui.css("row gap=S2 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=Surface align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn_hot : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=Hover align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn_on : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=AccentBg align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_tag : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_tag_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_val : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slot_val_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_badge : @ui.Style = @ui.css("mt=S2 radius=Full bg=Surface align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_badge_on : @ui.Style = @ui.css("mt=S2 radius=Full bg=AccentBg align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_words_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_slider_track_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_sm : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_lg : @ui.TextStyle = @ui.text_style(size=Title, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lh_col : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lh_row : @ui.Style = @ui.css("row w=Full gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lh_card : @ui.Style = @ui.css("py=S2 px=S2 gap=S1_5 radius=Lg bg=Surface align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lh_card_hot : @ui.Style = @ui.css("py=S2 px=S2 gap=S1_5 radius=Lg bg=Hover align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lh_card_on : @ui.Style = @ui.css("py=S2 px=S2 gap=S1_5 radius=Lg bg=AccentBg align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_head : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_pill : @ui.Style = @ui.css("px=S2_5 py=S1 radius=Md bg=Surface")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_row : @ui.Style = @ui.css("row gap=S1_5 pt=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_pill : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Sm bg=Surface")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_pill_on : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Sm bg=AccentBg")

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_words_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_v4_lig_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)
