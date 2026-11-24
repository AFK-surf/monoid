// 字体, one setting for every frame:
// curated font pairings (presets), a live mixed-script preview card (`tallest`-locked against hover jitter),
// purpose (界面 / 正文 / 代码) × script (西文与数字 / 中文与标点) dual-layer selection with smart local font filtering,
// and a collapsible optical-tuning & reading-typography section. Every change writes through `prefs.set` (`fonts` and
// `typography`) with zero global glyph cache invalidation during hover or slider drag.

///|
fn font_setting_reset() -> Unit {
  fonts_trying.set("")
  local_try_given.val = ""
  local_open.set(false)
  fx_local_up.val = false
  advanced_open.set(false)
  fx_advanced_up.val = false
  cjk_scale_drag.set(None)
  text_size_drag.set(None)
  code_scale_drag.set(None)
}

///|
/// The face pointed at in the faces' rows, tried in the chat before it is chosen ("" none; "\u{1}" the slot's default /
/// followUi; "\u{2}" textCjk explicit "none"; `local:<family>` one of this machine's).
let fonts_trying : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// Whether the collapsible "光学微调与阅读排版" section is expanded (collapsed by default).
pub let advanced_open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
/// Fixture hook to open the collapsible advanced typography section on mount (`MBUI_FIXTURE=settings-fonts-advanced`).
// kept across runs: said by the fixture, taken by the block; font_setting_reset puts it back
pub let fx_advanced_up : Ref[Bool] = Ref(false)

///|
/// Local drag preview signals for sliders: updated continuously during drag, cleared on commit (`prefs.set`).
let cjk_scale_drag : @signals.Signal[(String, Double)?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
let text_size_drag : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
let code_scale_drag : @signals.Signal[Double?] = @signals.signal(None, same=fn(a, b) { a == b })

///|
priv struct FontPreset {
  key : String
  ui : String?
  ui_cjk : String?
  text : String?
  text_cjk : String?
  code : String?
  code_cjk : String?
}

///|
// kept across runs: static table of curated pairings (all 7 published font IDs only)
let font_presets : Array[FontPreset] = [
  {
    key: "default",
    ui: None,
    ui_cjk: None,
    text: None,
    text_cjk: None,
    code: None,
    code_cjk: None,
  },
  {
    key: "sans",
    ui: Some("inter"),
    ui_cjk: Some("noto-sans-sc"),
    text: None,
    text_cjk: None,
    code: Some("jetbrains-mono"),
    code_cjk: None,
  },
  {
    key: "reading",
    ui: Some("inter"),
    ui_cjk: Some("noto-sans-sc"),
    text: Some("inter"),
    text_cjk: Some("noto-serif-sc"),
    code: Some("fira-code"),
    code_cjk: Some("maple-mono"),
  },
  {
    key: "handwriting",
    ui: Some("inter"),
    ui_cjk: Some("noto-sans-sc"),
    text: Some("inter"),
    text_cjk: Some("lxgw-wenkai"),
    code: Some("maple-mono"),
    code_cjk: None,
  },
]

///|
fn preset_patch(p : FontPreset) -> Map[String, Json] {
  let as_json = fn(v : String?) -> Json {
    match v {
      Some(s) => ToJson::to_json(s)
      None => Json::null()
    }
  }
  let m : Map[String, Json] = Map([])
  m["ui"] = as_json(p.ui)
  m["uiCjk"] = as_json(p.ui_cjk)
  m["text"] = as_json(p.text)
  m["textCjk"] = as_json(p.text_cjk)
  m["code"] = as_json(p.code)
  m["codeCjk"] = as_json(p.code_cjk)
  m
}

///|
fn font_preset_matches(p : FontPreset, chosen_of : (String) -> String) -> Bool {
  let eq = fn(want : String?, got : String) {
    match want {
      Some(s) => got == s
      None => got == ""
    }
  }
  eq(p.ui, chosen_of("ui")) &&
  eq(p.ui_cjk, chosen_of("uiCjk")) &&
  eq(p.text, chosen_of("text")) &&
  eq(p.text_cjk, chosen_of("textCjk")) &&
  eq(p.code, chosen_of("code")) &&
  eq(p.code_cjk, chosen_of("codeCjk"))
}

///|
fn preset_needed_bytes(
  p : FontPreset,
  all : Array[Json],
  kept : Array[Json],
  face_here : (String) -> Bool,
) -> Double {
  let ids : Array[String] = []
  for opt in [p.ui, p.ui_cjk, p.text, p.text_cjk, p.code, p.code_cjk] {
    match opt {
      Some(id) if id != "" && !ids.contains(id) => ids.push(id)
      _ => ()
    }
  }
  let mut total = 0.0
  for id in ids {
    if face_here(id) || kept.contains(ToJson::to_json(id)) {
      continue
    }
    for entry in all {
      if text(Some(entry), "id") == id {
        total = total + number(Some(entry), "bytes")
        break
      }
    }
  }
  total
}

///|
fn font_typo_num(typo : Json?, key : String, fallback : Double) -> Double {
  match field(typo, key) {
    Some(Number(n, ..)) => n
    _ => fallback
  }
}

///|
fn font_typo_bool(typo : Json?, key : String, fallback : Bool) -> Bool {
  match field(typo, key) {
    Some(True) => true
    Some(False) => false
    _ => fallback
  }
}

///|
fn font_cjk_slot_of(place : String) -> String {
  place + "Cjk"
}

///|
fn font_cjk_scale_key(place : String) -> String {
  place + "CjkScale"
}

///|
fn font_cjk_weight_key(place : String) -> String {
  place + "CjkWeight"
}

///|
/// 字体's setting made once as nodes, a block at a time (fonts_node's and 外观's):
/// curated presets, purpose/script switches, live mixed-script preview card, font list, and collapsible typography.
fn fonts_blocks_node(core : Core) -> (() -> Array[String], (@view.View, String) -> Unit) {
  let prefs = fn() { (core.topic)("prefs", Map([])).get().value }
  let chosen_of = fn(slot : String) { text(field(prefs(), "fonts"), slot) }
  let faces_view = fn() { field(prefs(), "faces") }
  let typo = fn() { field(prefs(), "typography") }
  let all = fn() { items(faces_view(), "list") }
  let files_state = fn() { (core.topic)("fonts", Map([])).get().value }
  let place = fn() { @settings.font_places[@settings.fonts_at.get()] }
  let script = fn() { @settings.fonts_script_at.get() }
  let active_slot = fn() { if script() == 1 { font_cjk_slot_of(place()) } else { place() } }
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
  // the place's own: code's JetBrains Mono, the others' the app's words'
  let own = fn() { if place() == "code" { (core.own_code_face)() } else { 0 } }
  // as chosen, each primary place in its face as far as it is here
  let as_chosen = fn(p : String) {
    let id = chosen_of(p)
    if id == "" || (core.face_here)(id) {
      0
    } else {
      shown_in(id)
    }
  }
  // Resolve a CJK id to its loaded host slot (4..6) or its preview slot (10..31) without global cache invalidation.
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
  // Primary hover face (only when editing Latin/primary script)
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
    match (place(), try_primary_face()) {
      ("ui", Some(f)) => f
      _ => as_chosen("ui")
    }
  }
  // None keeps the chosen face. Some(0) explicitly follows the interface, even if a separate text face is chosen.
  let text_face = fn() {
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
    match (place(), try_primary_face()) {
      ("code", Some(f)) => Some(f)
      _ => {
        let face = as_chosen("code")
        if face == 0 { None } else { Some(face) }
      }
    }
  }
  // Effective CJK override for a role (`ui`, `text`, `code`) in the live preview card.
  let cjk_override_for = fn(role : String) -> @view.CjkOverride? {
    let scale = live_cjk_scale(role)
    let weight_off = live_cjk_weight(role)
    let tried = if script() == 1 { fonts_trying.get() } else { "" }
    let trying_this = tried != "" && (
      place() == role || (place() == "ui" && role == "text" && chosen_of("textCjk") == "")
    )
    if trying_this {
      if tried == "\u{2}" {
        // Explicit "none": break inheritance from uiCjk
        return Some({ face: 0, scale: 1.0, weight_off: 0 })
      }
      if tried == "\u{1}" {
        if role == "text" && place() == "text" {
          // Hovering "跟随界面" on textCjk
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
    // Not hovering CJK for this role: preserve active CJK companion (especially when hovering a Primary font or dragging slider).
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
  // whether the pointer is over the faces (their box, the gaps between rows too), as it comes and goes
  let over_faces : @signals.Signal[Bool] = @signals.signal(false)
  let block = fn(b : @view.View, key : String) {
    match key {
      "presets" => font_presets_node(b, core, all, files_state, chosen_of)
      "preview" =>
        // held at its tallest while the pointer is over the faces or while dragging sliders
        b.by_room(fn(held, room) {
          held.box(fn(cell) {
            let chat : Ref[@view.View?] = Ref(None)
            let tallest = Ref(0.0)
            cell.box(fn(p) {
              chat.val = Some(p)
              font_preview_node(
                p,
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
                Some(p) => {
                  let tall = room.tall(p)
                  let lock_tall = over_faces.get() ||
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
      "controls" =>
        b.box(fn(bar) {
          @sf.style_node(bar, fn() { fp_controls_bar })
          bar.wraps(Is(Some(10.0))) |> ignore
          @sf.seg_node(
            bar,
            fn() { @settings.font_places.map(fn(p) { @sf.t("web-pages.appearance.fonts." + p) }) },
            fn() { @settings.fonts_at.get() },
            fn(picked) {
              if picked != @signals.untracked(fn() { @settings.fonts_at.get() }) {
                fonts_trying.set("")
                @settings.fonts_at.set(picked)
              }
            },
            said=@sf.t("web-pages.appearance.fonts.ui"),
          )
          |> ignore
          @sf.seg_node(
            bar,
            fn() {
              [
                @sf.t("web-pages.appearance.fonts.script.latin"),
                @sf.t("web-pages.appearance.fonts.script.cjk"),
              ]
            },
            fn() { @settings.fonts_script_at.get() },
            fn(picked) {
              if picked != @signals.untracked(fn() { @settings.fonts_script_at.get() }) {
                fonts_trying.set("")
                @settings.fonts_script_at.set(picked)
              }
            },
            said=@sf.t("web-pages.appearance.fonts.script.latin"),
          )
          |> ignore
        })
        |> ignore
      "faces" =>
        b.box(fn(faces) {
          // (pointed at as the pointer is over it or what it holds: the gaps between its rows too)
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
      _ =>
        font_advanced_node(b, core, place, faces_view, chosen_of, typo)
    }
  }
  (fn() { ["presets", "preview", "controls", "faces", "advanced"] }, block)
}

///|
/// Curated font pairings strip: each chip highlights when active and displays total unkept download size (hovering a
/// preset never triggers `fonts.fetch`).
fn font_presets_node(
  parent : @view.View,
  core : Core,
  all : () -> Array[Json],
  files_state : () -> Json?,
  chosen_of : (String) -> String,
) -> Unit {
  parent.box(fn(strip) {
    @sf.style_node(strip, fn() { fp_presets_strip })
    strip.min_width(Is(Some(0.0))) |> ignore
    strip.scrolls(@view.Scroll::across(), slop=@ui.touch_slop(), fn(row) {
      @sf.style_node(row, fn() { fp_presets_row })
      for p in font_presets {
        let on = fn() { font_preset_matches(p, chosen_of) }
        let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + p.key) }
        let bytes = fn() {
          let kept = items(files_state(), "kept")
          preset_needed_bytes(p, all(), kept, core.face_here)
        }
        @sf.action_box_node(
          row,
          title,
          fn(_) { @settings.set_fonts_preset(core, preset_patch(p), reset_cjk_optics=true) },
          fn(chip) {
            let lit = fn() { @sf.lit_node(chip) }
            @sf.style_node(chip, fn() {
              if on() {
                fp_preset_chip_on
              } else if lit() {
                fp_preset_chip_hot
              } else {
                fp_preset_chip
              }
            })
            chip.shrink(Is(0.0)).edge(By(fn() {
              if on() {
                (1.0, @sf.theme().p.accent)
              } else if lit() {
                (0.5, @sf.theme().p.line_strong)
              } else {
                (0.5, @sf.theme().p.line)
              }
            }))
            |> ignore
            @sf.words_node(chip, title, fn() { if on() { fp_preset_title_on } else { fp_preset_title } }) |> ignore
            chip.show(at_once=true, fn() { bytes() > 0.0 }, fn(sz) {
              let w = @sf.words_node(sz, fn() { face_size(bytes()) }, fn() { fp_preset_size })
              @sf.on_baseline(w, Ui, Meta, weight=500, own_weight=400) |> ignore
            })
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
/// Collapsible "光学微调与阅读排版" section (collapsed by default).
fn font_advanced_node(
  parent : @view.View,
  core : Core,
  place : () -> String,
  faces_view : () -> Json?,
  chosen_of : (String) -> String,
  typo : () -> Json?,
) -> Unit {
  if fx_advanced_up.val {
    fx_advanced_up.val = false
    advanced_open.set(true)
  }
  let custom_count = fn() -> Int {
    let t = typo()
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
  let summary = fn() -> String {
    let n = custom_count()
    if n == 0 {
      @sf.t("web-pages.appearance.fonts.default")
    } else {
      @sf.t("web-pages.appearance.fonts.advanced.summaryCustom", args=[("n", n.to_string())])
    }
  }
  @sf.group_node(parent, fn(g) {
    @sf.action_box_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.title") },
      fn(_) { @view.transition(fn() { advanced_open.set(!advanced_open.untracked()) }) },
      fn(head) {
        let hot = fn() { @sf.lit_node(head) }
        @sf.style_node(head, fn() { if hot() { fp_adv_head_hot } else { fp_adv_head } })
        head.box(fn(left) {
          left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn() { fp_adv_title }) |> ignore
        })
        |> ignore
        head.box(fn(right) {
          @sf.style_node(right, fn() { fp_adv_right })
          @sf.on_baseline(right, Title, Meta, weight=500, own_weight=400).shrink(Is(0.0)) |> ignore
          @sf.words_node(right, summary, fn() { fp_adv_summary }) |> ignore
          @sf.icon_node(right, "", 14.0, By(fn() { @sf.theme().p.subtle }), name_now=fn() {
            if advanced_open.get() { "chevron-down" } else { "chevron-right" }
          })
          |> ignore
        })
        |> ignore
      },
    )
    |> ignore
    g.show(fn() { advanced_open.get() }, fn(inner) {
      @sf.style_node(inner, fn() { fp_adv_body })
      // --- CJK optical tuning group ---
      inner.box(fn(cjk_sec) {
        @sf.style_node(cjk_sec, fn() { fp_adv_group })
        @sf.words_node(
          cjk_sec,
          fn() {
            @sf.t(
              "web-pages.appearance.fonts.advanced.cjkGroup",
              args=[("place", @sf.t("web-pages.appearance.fonts." + place()))],
            )
          },
          fn() { fp_adv_group_title },
        )
        |> ignore
        let has_cjk = fn() { text(faces_view(), font_cjk_slot_of(place())) != "" }
        cjk_sec.pick(has_cjk, fn(p, active) {
          if !active {
            @sf.words_node(p, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkHint") }, fn() { fp_adv_hint }) |> ignore
          } else {
            let scale_key = fn() { font_cjk_scale_key(place()) }
            let weight_key = fn() { font_cjk_weight_key(place()) }
            let cjk_scale_val = fn() -> Double {
              let k = scale_key()
              match cjk_scale_drag.get() {
                Some((dk, v)) if dk == k => v
                _ => font_typo_num(typo(), k, 100.0)
              }
            }
            font_slider_row_node(
              p,
              fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
              cjk_scale_val,
              fn(v) { cjk_scale_drag.set(Some((@signals.untracked(scale_key), v))) },
              fn(v) {
                let k = @signals.untracked(scale_key)
                cjk_scale_drag.set(None)
                let n = v.round().to_int()
                let m : Map[String, Json] = Map([])
                m[k] = ToJson::to_json(n)
                @settings.set_typography(core, Json::object(m))
              },
              min=85.0,
              max=115.0,
              step=5.0,
            )
            let weight_index = fn() -> Int {
              let w = font_typo_num(typo(), weight_key(), 0.0).round().to_int()
              if w < 0 { 0 } else if w > 0 { 2 } else { 1 }
            }
            font_seg_row_node(
              p,
              fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") },
              fn() {
                [
                  @sf.t("web-pages.appearance.fonts.advanced.weightLight"),
                  @sf.t("web-pages.appearance.fonts.advanced.weightAuto"),
                  @sf.t("web-pages.appearance.fonts.advanced.weightBold"),
                ]
              },
              weight_index,
              fn(idx) {
                let w = if idx == 0 { -100 } else if idx == 2 { 100 } else { 0 }
                let m : Map[String, Json] = Map([])
                m[@signals.untracked(weight_key)] = ToJson::to_json(w)
                @settings.set_typography(core, Json::object(m))
              },
            )
            // When text inherits uiCjk but has explicit optical overrides, offer "恢复跟随界面"
            let text_overridden = fn() {
              place() == "text" &&
              chosen_of("textCjk") == "" &&
              text(faces_view(), "uiCjk") != "" &&
              (
                font_typo_bool(typo(), "textCjkScaleOwn", false) ||
                font_typo_bool(typo(), "textCjkWeightOwn", false)
              )
            }
            p.show(at_once=true, text_overridden, fn(bar) {
              @sf.style_node(bar, fn() { fp_adv_action_row })
              @sf.button_node(
                bar,
                fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") },
                fn() {
                  @settings.set_typography(
                    core,
                    Json::object({ "textCjkScale": Json::null(), "textCjkWeight": Json::null() }),
                  )
                },
              )
              |> ignore
            })
          }
        })
      })
      |> ignore
      inner.box(fn(sep) { @sf.style_node(sep, fn() { @sf.rule_line }) }) |> ignore
      // --- Reading & code layout group ---
      inner.box(fn(read_sec) {
        @sf.style_node(read_sec, fn() { fp_adv_group })
        @sf.words_node(read_sec, fn() { @sf.t("web-pages.appearance.fonts.advanced.readingGroup") }, fn() { fp_adv_group_title })
        |> ignore
        font_slider_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
          fn() { text_size_drag.get().unwrap_or(font_typo_num(typo(), "textSize", 100.0)) },
          fn(v) { text_size_drag.set(Some(v)) },
          fn(v) {
            text_size_drag.set(None)
            @settings.set_typography(core, Json::object({ "textSize": ToJson::to_json(v.round().to_int()) }))
          },
          min=85.0,
          max=130.0,
          step=5.0,
        )
        font_slider_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
          fn() { code_scale_drag.get().unwrap_or(font_typo_num(typo(), "codeScale", 100.0)) },
          fn(v) { code_scale_drag.set(Some(v)) },
          fn(v) {
            code_scale_drag.set(None)
            @settings.set_typography(core, Json::object({ "codeScale": ToJson::to_json(v.round().to_int()) }))
          },
          min=85.0,
          max=110.0,
          step=5.0,
        )
        font_seg_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") },
          fn() {
            [
              @sf.t("web-pages.appearance.fonts.advanced.lineCompact"),
              @sf.t("web-pages.appearance.fonts.advanced.lineNormal"),
              @sf.t("web-pages.appearance.fonts.advanced.lineRelaxed"),
            ]
          },
          fn() {
            match text(typo(), "lineHeight") {
              "compact" => 0
              "relaxed" => 2
              _ => 1
            }
          },
          fn(idx) {
            let v = if idx == 0 { "compact" } else if idx == 2 { "relaxed" } else { "normal" }
            @settings.set_typography(core, Json::object({ "lineHeight": ToJson::to_json(v) }))
          },
        )
        font_switch_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") },
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceNote") },
          fn() { font_typo_bool(typo(), "cjkAutoSpace", true) },
          fn(on) { @settings.set_typography(core, Json::object({ "cjkAutoSpace": ToJson::to_json(on) })) },
        )
        // Web Canvas 2D draws per-cluster and cannot render multi-character code ligatures; hide on Web (platform 4).
        if @ui.platform() != 4 {
          font_switch_row_node(
            read_sec,
            fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") },
            fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigaturesNote") },
            fn() { font_typo_bool(typo(), "codeLigatures", true) },
            fn(on) { @settings.set_typography(core, Json::object({ "codeLigatures": ToJson::to_json(on) })) },
          )
        }
        read_sec.show(at_once=true, fn() { custom_count() > 0 }, fn(bar) {
          @sf.style_node(bar, fn() { fp_adv_action_row })
          @sf.button_node(
            bar,
            fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") },
            fn() { @settings.set_typography(core, Json::null()) },
          )
          |> ignore
        })
      })
      |> ignore
    })
  })
}

///|
fn font_slider_row_node(
  parent : @view.View,
  label : () -> String,
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
    @sf.value_slider_node(
      col,
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
}

///|
fn font_seg_row_node(
  parent : @view.View,
  label : () -> String,
  options : () -> Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() { fp_control_row })
    row.wraps(Is(Some(8.0))) |> ignore
    row.box(fn(l) {
      l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(l, label, fn() { fp_adv_row_label }) |> ignore
    })
    |> ignore
    @sf.seg_node(row, options, chosen, choose, said=@signals.untracked(label)) |> ignore
  })
  |> ignore
}

///|
fn font_switch_row_node(
  parent : @view.View,
  label : () -> String,
  note : () -> String,
  on : () -> Bool,
  turn : (Bool) -> Unit,
) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() { fp_switch_row })
    row.box(fn(left) {
      @sf.style_node(left, fn() { fp_switch_left })
      left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(left, label, fn() { fp_adv_row_label }) |> ignore
      @sf.words_node(left, note, fn() { fp_adv_hint }) |> ignore
    })
    |> ignore
    row.box(fn(sw) {
      sw.shrink(Is(0.0)) |> ignore
      @sf.switch_node(sw, on, turn, label, small=true)
    })
    |> ignore
  })
  |> ignore
}

///|
/// 字体's faces of `slot` (`place` + `is_cjk`) in `rows`.
fn face_rows_node(
  rows : @view.View,
  core : Core,
  slot : String,
  place : String,
  is_cjk : Bool,
  all : () -> Array[Json],
  own : () -> Int,
  shown_in : (String) -> Int,
  files_state : () -> Json?,
  chosen_of : (String) -> String,
  name_of_id : (String) -> String,
) -> Unit {
  let chosen = fn() { chosen_of(slot) }
  if is_cjk {
    if place == "text" {
      let ui_cjk_name = fn() { name_of_id(chosen_of("uiCjk")) }
      let follow_note = fn() {
        @sf.t("web-pages.appearance.fonts.cjkFollowUi", args=[("name", ui_cjk_name())])
      }
      face_row_node(
        rows,
        core,
        slot,
        "",
        fn() { @sf.t("web-pages.appearance.fonts.followUi") },
        fn() { 0 },
        fn() { chosen() == "" },
        fn() { ("", false) },
        note_text=follow_note,
      )
      face_row_node(
        rows,
        core,
        slot,
        "none",
        fn() { @sf.t("web-pages.appearance.fonts.cjkNone") },
        fn() { 0 },
        fn() { chosen() == "none" },
        fn() { ("", false) },
        tried_key="\u{2}",
      )
    } else {
      face_row_node(
        rows,
        core,
        slot,
        "",
        fn() { @sf.t("web-pages.appearance.fonts.default") },
        fn() { 0 },
        fn() { chosen() == "" },
        fn() { ("", false) },
      )
    }
  } else {
    let none = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
    face_row_node(rows, core, slot, "", fn() { @sf.t(none) }, own, fn() { chosen() == "" }, fn() { ("", false) })
  }
  // Catalog entries filtered by script & place:
  // - Latin mode: mono == (place == "code")
  // - CJK mode: hasCjk == true (on code, mono CJK faces like Maple Mono sorted first)
  let by_id = rows.keyed_by(
    fn() {
      if is_cjk {
        let cjk_all = all().filter(fn(f) { flag(Some(f), "hasCjk") })
        if place == "code" {
          let monos = cjk_all.filter(fn(f) { flag(Some(f), "mono") })
          let rest = cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
          monos + rest
        } else {
          cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
        }
      } else {
        all().filter(fn(f) { flag(Some(f), "mono") == (place == "code") })
      }
    },
    fn(f) { text(Some(f), "id") },
  )
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
      face_row_node(r, core, slot, id, fn() { text(fv(), "name") }, face, fn() { chosen() == id }, status)
    },
  )
  // a face of this machine's own, where the host lists them (keyboard and mouse's)
  rows.show(fn() { @ui.can_list_local_fonts() }, fn(l) {
    local_face_row_node(l, core, slot, place, is_cjk, chosen)
  })
}

///|
/// A face of the slot in `parent`: its name and a sample line drawn in itself (`face()`), status & check at its end;
/// pointed at, tried in the preview card; pressed, persisted via `set_font`.
fn face_row_node(
  parent : @view.View,
  core : Core,
  slot : String,
  id : String,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  status : () -> (String, Bool),
  tried_key? : String,
  note_text? : () -> String,
) -> Unit {
  let tried = match tried_key {
    Some(k) => k
    None => if id == "" { "\u{1}" } else { id }
  }
  parent.box(fn(r) {
    fonts_tried_by(r, tried)
    face_choice_node(
      r,
      name,
      face,
      on,
      press=fn() { @settings.set_font(core, slot, if id == "" { None } else { Some(id) }) },
      status~,
      note_text?,
    )
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
/// A face's row in `parent` (choice_row_node's, with a sample or custom note under its label).
fn face_choice_node(
  parent : @view.View,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  press~ : () -> Unit,
  status? : () -> (String, Bool) = fn() { ("", false) },
  held? : () -> Bool = fn() { false },
  grounded? : (@view.View) -> Unit = fn(_) { () },
  note_text? : () -> String,
) -> Unit {
  let sample = match note_text {
    Some(f) => f
    None => fn() { @sf.t("web-pages.appearance.fonts.sampleRow") }
  }
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
/// Words `words()` of `style` in `parent`, set in host face `face()` (0: as the paragraph's own are); `person()`:
/// whether they are a person's words; `cjk`: optional local CJK companion override (zero global cache invalidation).
fn face_in_node(
  parent : @view.View,
  words : () -> String,
  face : () -> Int,
  style : @ui.TextStyle,
  person? : () -> Bool,
  cjk? : () -> @view.CjkOverride?,
  size_scale? : () -> Double,
  line_scale? : () -> Double,
) -> @view.View {
  parent.box(fn(w) {
    w
    .words_runs(By(fn() {
      let f = face()
      [@ui.span(words(), face=if f == 0 { None } else { Some(f) })]
    }))
    .words_look(By(fn() {
      let base = @ui.style_words(style)
      let ss = match size_scale {
        Some(f) => f()
        None => 1.0
      }
      let ls = match line_scale {
        Some(f) => f()
        None => 1.0
      }
      if ss == 1.0 && ls == 1.0 {
        base
      } else {
        { ..base, size: base.size * ss, line: base.line * ss * ls }
      }
    }))
    .ink(By(fn() { @ui.style_ink(style) }))
    |> ignore
    if person is Some(_) || cjk is Some(_) {
      w.runs_look(By(fn() {
        {
          ..@view.runs_plain,
          words: match person {
            Some(p) => p()
            None => false
          },
          cjk: match cjk {
            Some(c) => c()
            None => None
          },
        }
      }))
      |> ignore
    }
  })
}

///|
/// 本机字体 in `parent`: opens the smart local font filter panel beside the row.
fn local_face_row_node(
  parent : @view.View,
  core : Core,
  slot : String,
  place : String,
  is_cjk : Bool,
  chosen : () -> String,
) -> Unit {
  let picked = fn() {
    let c = chosen()
    if c.has_prefix(local_prefix) {
      c.unsafe_substring(start=local_prefix.length(), end=c.length())
    } else {
      ""
    }
  }
  let slot_host_face = match slot {
    "ui" => @hostapi.face_ui
    "text" => @hostapi.face_text
    "code" => @hostapi.face_code
    "uiCjk" => @hostapi.face_ui_cjk
    "textCjk" => @hostapi.face_text_cjk
    "codeCjk" => @hostapi.face_code_cjk
    _ => 0
  }
  let face = fn() { if picked() != "" { slot_host_face } else { 0 } }
  let name = fn() { if picked() != "" { picked() } else { @sf.t("web-pages.appearance.fonts.local") } }
  parent.box(fn(r) {
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
    let mine = Ref(0)
    r.reacts(fn() { local_open.get() }, fn(on) {
      if !on {
        if mine.val != 0 && @sf.presented_open_of(mine.val) {
          @sf.close_presented_of(mine.val)
        }
        return
      }
      guard mine.val == 0 || !@sf.presented_open_of(mine.val) else { return }
      @sf.panel_nodes(
        "",
        fn(v, close) { local_faces_node(v, core, slot, place, is_cjk, picked, close) },
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
#derive(Eq)
priv struct LocalFontEntry {
  name : String
  localized : String
  mono : Bool
  cjk : Bool
}

///|
fn local_font_entries() -> (Array[LocalFontEntry], Bool) {
  let info_str = @ui.local_font_info_signal()
  if info_str != "" {
    let parsed = @json.parse(info_str) catch { _ => Json::null() }
    match parsed {
      Array(a) if a.length() > 0 => {
        let out : Array[LocalFontEntry] = []
        for item in a {
          let name = text(Some(item), "name")
          if name == "" {
            continue
          }
          let loc = text(Some(item), "localized")
          out.push({
            name,
            localized: if loc == "" { name } else { loc },
            mono: flag(Some(item), "mono"),
            cjk: flag(Some(item), "cjk"),
          })
        }
        if out.length() > 0 {
          return (out, true)
        }
      }
      _ => ()
    }
  }
  (
    local_families().map(fn(f) { { name: f, localized: f, mono: false, cjk: false } }),
    false,
  )
}

///|
/// Smart local font filter panel: non-blocking metadata via `@ui.local_font_info_signal()` with smooth fallback to
/// `local_font_families()`, 3 filter pills (全部 / 仅中文 / 仅等宽) smartly defaulted by active slot, and localized +
/// English family search.
fn local_faces_node(
  v : @view.View,
  core : Core,
  slot : String,
  place : String,
  is_cjk : Bool,
  picked : () -> String,
  close : () -> Unit,
) -> Unit {
  let find_field = @ui.Field::new()
  // Smart default filter: CJK tab -> 仅中文 (1), code Latin -> 仅等宽 (2), else 全部 (0).
  let default_filter = if is_cjk { 1 } else if place == "code" { 2 } else { 0 }
  let filter_at : @signals.Signal[Int] = @signals.signal(default_filter, same=fn(a, b) { a == b })
  v.box(fn(f) {
    @sf.style_node(f, fn() { local_search })
    @sf.input_node(f, find_field, placeholder=@sf.t("web-pages.appearance.fonts.searchLocal"), small=true) |> ignore
  })
  |> ignore
  let entries = @signals.computed(fn(_) { local_font_entries() })
  v.show(at_once=true, fn() { entries.get().1 }, fn(pills) {
    @sf.style_node(pills, fn() { local_filter_row })
    pills.wraps(Is(Some(6.0))) |> ignore
    @sf.filter_pill_node(
      pills,
      fn() { @sf.t("web-pages.appearance.fonts.localFilter.all") },
      fn(_) { filter_at.set(0) },
      picked=fn() { filter_at.get() == 0 },
      chevron=false,
    )
    |> ignore
    @sf.filter_pill_node(
      pills,
      fn() { @sf.t("web-pages.appearance.fonts.localFilter.cjk") },
      fn(_) { filter_at.set(1) },
      picked=fn() { filter_at.get() == 1 },
      chevron=false,
    )
    |> ignore
    @sf.filter_pill_node(
      pills,
      fn() { @sf.t("web-pages.appearance.fonts.localFilter.mono") },
      fn(_) { filter_at.set(2) },
      picked=fn() { filter_at.get() == 2 },
      chevron=false,
    )
    |> ignore
  })
  let shown = fn() {
    let find = find_field.text().trim(chars=" ").to_lower()
    let (all_entries, has_meta) = entries.get()
    let mode = if has_meta { filter_at.get() } else { 0 }
    let found = all_entries.filter(fn(e) {
      let ok_kind = match mode {
        1 => e.cjk
        2 => e.mono
        _ => true
      }
      if !ok_kind {
        return false
      }
      find == "" || e.name.to_lower().contains(find) || e.localized.to_lower().contains(find)
    })
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
          rows.each(shown, fn(e) { e.name }, fn(row, e) {
            let entry = e.untracked()
            let f = entry.name
            fonts_tried_by(row, local_prefix + f)
            @sf.action_box_node(row, fn() { entry.localized }, fn(_) {
              @settings.set_font(core, slot, Some(local_prefix + f))
              close()
            }, fn(b) {
              let hot = fn() { f == picked() || @sf.lit_node(b) }
              @sf.style_node(b, fn() { (if hot() { local_row_hot } else { local_row }).then(@sf.pick_high()) })
              b.radius(Is(@sf.small_panel_inner(@sf.r_menu))) |> ignore
              b.box(fn(names) {
                names.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.words_node(names, fn() { entry.localized }, fn() { local_name }) |> ignore
                if entry.localized != entry.name {
                  @sf.words_node(names, fn() { entry.name }, fn() { local_sub_name }) |> ignore
                }
              })
              |> ignore
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
/// Live mixed-script preview card: user bubble + agent header + Markdown prose + TypeScript code block with ligatures
/// and CJK comments. Hovering any online/local font or dragging typography sliders updates locally with zero global
/// cache invalidation (`words_forgotten`).
fn font_preview_node(
  parent : @view.View,
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
  @sf.page_card_node(parent, fn(card) {
    card.box(fn(col) {
      @sf.style_node(col, fn() { fp_column })
      col.box(fn(mine) {
        @sf.style_node(mine, fn() { fp_mine_room })
        mine.box(fn(clear) { clear.width_share(Is(fp_mine_clear_share / 100.0)).shrink(Is(0.0)) |> ignore }) |> ignore
        mine.box(fn(bubble) {
          @sf.style_node(bubble, fn() { fp_bubble })
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
      col.box(fn(agent) {
        @sf.style_node(agent, fn() { fp_agent })
        agent.box(fn(who) {
          @sf.style_node(who, fn() { fp_who_line })
          face_in_node(who, fn() { "Claude" }, ui_face, fp_who_words, cjk=ui_cjk) |> ignore
          face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_time_words, cjk=ui_cjk)
          |> ignore
        })
        |> ignore
        @sf.markdown_node(
          agent,
          fn() {
            @sf.t("web-pages.appearance.fonts.sampleText") + "\n\n" + fp_sample_code + "\n\n" + @sf.t("web-pages.appearance.fonts.sampleAfter")
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
      |> ignore
    })
    |> ignore
  })
}

///|
// kept across runs: a value (all CJK chars 表单 appear in sampleText -> 0 missing glyphs in preview-*.ttf)
pub let fp_sample_code : String = "```ts\nform.onsubmit = (e) => {\n  e.preventDefault(); // 表单 0O 1lI !==\n};\n```"

///|
// kept across runs: a value (no field of it changes)
let fp_column : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let fp_controls_bar : @ui.Style = @ui.css("row w=Full pt=S1 pb=S2_5 justify=JBetween align=ACenter gap=S2")

///|
// kept across runs: a value (no field of it changes)
let fp_presets_strip : @ui.Style = @ui.css("w=Full pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
let fp_presets_row : @ui.Style = @ui.css("row gap=S1_5 px=S0_5 py=S0_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_preset_chip : @ui.Style = @ui.css("row gap=S1 px=S3 py=S1_5 radius=Full bg=Surface align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_preset_chip_hot : @ui.Style = @ui.css("row gap=S1 px=S3 py=S1_5 radius=Full bg=Hover align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_preset_chip_on : @ui.Style = @ui.css("row gap=S1 px=S3 py=S1_5 radius=Full bg=AccentBg align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_preset_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_preset_title_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_preset_size : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_head : @ui.Style = @ui.css("row w=Full px=S4 py=S3 gap=S2 radius=Xl2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_adv_head_hot : @ui.Style = fp_adv_head.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let fp_adv_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Medium, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_right : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_adv_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_body : @ui.Style = @ui.css("w=Full px=S4 pb=S4 gap=S4")

///|
// kept across runs: a value (no field of it changes)
let fp_adv_group : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let fp_adv_group_title : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_hint : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_row_label : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let fp_adv_row_value : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let fp_slider_col : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_slider_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_control_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let fp_switch_row : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let fp_switch_left : @ui.Style = @ui.css("gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let fp_adv_action_row : @ui.Style = @ui.css("row w=Full justify=JEnd pt=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_mine_room : @ui.Style = @ui.css("row w=Full justify=JEnd")

///|
/// What their bubble leaves at the row's start, a share of the row (percent).
let fp_mine_clear_share : Double = 22.0

///|
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
/// The host face family `family` of this machine's is tried in (slot `@sfbase.local_try_face`, isolated from
/// `share_face`); 0 where the host has none of it.
fn local_tried(family : String) -> Int {
  let slot = @sfbase.local_try_face
  if local_try_given.val != family {
    @ui.face_clear(slot)
    local_try_given.val = if @ui.face_add_family(slot, family) { family } else { "" }
  }
  if local_try_given.val == family {
    slot
  } else {
    0
  }
}

///|
/// The families installed here (the host's: @ui.local_font_families), in its order.
fn local_families() -> Array[String] {
  let parsed = @json.parse(@ui.local_font_families()) catch { _ => Json::null() }
  match parsed {
    Array(a) => a.filter_map(fn(x) { if x is String(s) { Some(s) } else { None } })
    _ => []
  }
}

///|
let font_check : Double = 14.0

///|
let local_panel_w : Double = 300.0

///|
let local_list_most : Double = 320.0

///|
let local_most : Int = 400

///|
// kept across runs: a value (no field of it changes)
let local_search : @ui.Style = @ui.css("w=Full pb=S1_5")

///|
// kept across runs: a value (no field of it changes)
let local_filter_row : @ui.Style = @ui.css("row w=Full pb=S1_5 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let local_row : @ui.Style = @ui.css("row w=Full px=S2_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let local_row_hot : @ui.Style = local_row.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let local_name : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, color=Fg, wrap=false, w=Full, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let local_sub_name : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false, w=Full, max_lines=1)

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
