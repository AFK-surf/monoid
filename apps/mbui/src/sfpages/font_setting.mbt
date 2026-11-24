// 字体, one setting for every frame:
// curated font pairings (presets), a live mixed-script preview card (`tallest`-locked against hover jitter),
// purpose (界面 / 正文 / 代码) × script (西文与数字 / 中文与标点) dual-layer selection with smart local font filtering,
// and a collapsible optical-tuning & reading-typography section. Every change writes through `prefs.set` (`fonts` and
// `typography`) with zero global glyph cache invalidation during hover or slider drag.

///|
fn font_setting_reset() -> Unit {
  fonts_trying.set("")
  preset_trying.set(-1)
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
/// Collapsible V4 "排版与字号细节" section (collapsed by default; expanded by `settings-fonts-advanced` fixture).
fn font_advanced_node(
  parent : @view.View,
  core : Core,
  place : () -> String,
  faces_view : () -> Json?,
  chosen_of : (String) -> String,
  typo : () -> Json?,
  ui_face : () -> Int,
  text_face : () -> Int?,
  code_face : () -> Int?,
  cjk_host_face : (String) -> Int,
) -> Unit {
  if fx_advanced_up.val {
    fx_advanced_up.val = false
    advanced_open.set(true)
  }
  let custom_count = fn() -> Int { font_typo_custom_count(typo()) }
  let summary = fn() -> String {
    let n = custom_count()
    if n == 0 {
      @sf.t("web-pages.appearance.fonts.default")
    } else {
      @sf.t("web-pages.appearance.fonts.advanced.summaryCustom", args=[("n", n.to_string())])
    }
  }
  let active_primary_face = fn() -> Int {
    match place() {
      "text" => text_face().unwrap_or(0)
      "code" => code_face().unwrap_or(0)
      _ => ui_face()
    }
  }
  let active_cjk_preview = fn() -> @view.CjkOverride? {
    let p = place()
    let id = text(faces_view(), font_cjk_slot_of(p))
    if id == "" {
      return None
    }
    let f = cjk_host_face(id)
    if f <= 0 {
      return None
    }
    let k = font_cjk_scale_key(p)
    let scale = match cjk_scale_drag.get() {
      Some((dk, pct)) if dk == k => pct / 100.0
      _ => font_typo_num(typo(), k, 100.0) / 100.0
    }
    let weight_off = font_typo_num(typo(), font_cjk_weight_key(p), 0.0).round().to_int()
    Some({ face: f, scale, weight_off })
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
      // --- Reading & code layout group (visual sliders + 3-bar line-height cards + visual switch comparisons) ---
      inner.box(fn(read_sec) {
        @sf.style_node(read_sec, fn() { fp_adv_group })
        @sf.words_node(read_sec, fn() { @sf.t("web-pages.appearance.fonts.advanced.readingGroup") }, fn() { fp_adv_group_title })
        |> ignore
        font_visual_slider_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
          "A",
          "A",
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
        font_visual_slider_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
          "</>",
          "</>",
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
        font_line_height_cards_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") },
          fn() { text(typo(), "lineHeight") },
          fn(v) { @settings.set_typography(core, Json::object({ "lineHeight": ToJson::to_json(v) })) },
        )
        let autospace_on = fn() { font_typo_bool(typo(), "cjkAutoSpace", true) }
        font_switch_row_node(
          read_sec,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") },
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceNote") },
          autospace_on,
          fn(on) { @settings.set_typography(core, Json::object({ "cjkAutoSpace": ToJson::to_json(on) })) },
          extra=fn(e) { font_autospace_pills_node(e, autospace_on) },
        )
        // Web Canvas 2D draws per-cluster and cannot render multi-character code ligatures; hide on Web (platform 4).
        if @ui.platform() != 4 {
          font_switch_row_node(
            read_sec,
            fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") },
            fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigaturesNote") },
            fn() { font_typo_bool(typo(), "codeLigatures", true) },
            fn(on) { @settings.set_typography(core, Json::object({ "codeLigatures": ToJson::to_json(on) })) },
            extra=fn(e) {
              e.box(fn(row) {
                @sf.style_node(row, fn() { fp_v4_cmp_row })
                font_ligature_sample_node(row, code_face)
              })
              |> ignore
            },
          )
        }
      })
      |> ignore
      inner.box(fn(sep) { @sf.style_node(sep, fn() { @sf.rule_line }) }) |> ignore
      // --- CJK-Latin optical ratio group with live `Aa 字体` comparison badge ---
      inner.box(fn(cjk_sec) {
        @sf.style_node(cjk_sec, fn() { fp_adv_group })
        cjk_sec.box(fn(head) {
          @sf.style_node(head, fn() { fp_v4_ratio_head })
          head.box(fn(tw) {
            tw.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(
              tw,
              fn() {
                @sf.t(
                  "web-pages.appearance.fonts.advanced.cjkRatioTitle",
                  args=[("place", @sf.t("web-pages.appearance.fonts." + place()))],
                )
              },
              fn() { fp_adv_group_title },
            )
            |> ignore
          })
          |> ignore
          font_cjk_ratio_badge_node(head, active_primary_face, active_cjk_preview)
        })
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
        cjk_sec.show(at_once=true, fn() { custom_count() > 0 }, fn(bar) {
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
  extra? : (@view.View) -> Unit,
) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() { fp_switch_row })
    row.box(fn(left) {
      @sf.style_node(left, fn() { fp_switch_left })
      left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(left, label, fn() { fp_adv_row_label }) |> ignore
      @sf.words_node(left, note, fn() { fp_adv_hint }) |> ignore
      match extra {
        Some(f) => f(left)
        None => ()
      }
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
  let sample_key = font_slot_sample_key(place, is_cjk)
  let glyph = fn() { font_slot_glyph(place, is_cjk) }
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
        glyph~,
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
        glyph~,
        tried_key="\u{2}",
        sample_key~,
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
        glyph~,
        sample_key~,
      )
    }
  } else {
    let none = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
    face_row_node(rows, core, slot, "", fn() { @sf.t(none) }, own, fn() { chosen() == "" }, fn() { ("", false) }, glyph~, sample_key~)
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
      face_row_node(r, core, slot, id, fn() { text(fv(), "name") }, face, fn() { chosen() == id }, status, glyph~, sample_key~)
    },
  )
  // a face of this machine's own, where the host lists them (keyboard and mouse's)
  rows.show(fn() { @ui.can_list_local_fonts() }, fn(l) {
    local_face_row_node(l, core, slot, place, is_cjk, chosen, glyph, sample_key)
  })
}

///|
/// A face of the slot in `parent`: 32×32 glyph badge + name + context-specific sample line drawn in itself (`face()`),
/// status & check at its end; pointed at, tried in the preview card; pressed, persisted via `set_font`.
fn face_row_node(
  parent : @view.View,
  core : Core,
  slot : String,
  id : String,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  status : () -> (String, Bool),
  glyph~ : () -> String,
  sample_key? : String = "web-pages.appearance.fonts.sampleRow",
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
      glyph~,
      sample_key~,
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
  glyph~ : () -> String,
  sample_key? : String = "web-pages.appearance.fonts.sampleRow",
  status? : () -> (String, Bool) = fn() { ("", false) },
  held? : () -> Bool = fn() { false },
  grounded? : (@view.View) -> Unit = fn(_) { () },
  note_text? : () -> String,
) -> Unit {
  let sample = match note_text {
    Some(f) => f
    None => fn() { @sf.t(sample_key) }
  }
  @sf.choice_row_node(
    parent,
    name,
    on,
    press~,
    note=sample,
    lead=fn(l) { face_glyph_badge_node(l, glyph, face, on) },
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
  glyph : () -> String,
  sample_key : String,
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
      glyph~,
      sample_key~,
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
// kept across runs: a value (all CJK chars 表单 appear in sampleText -> 0 missing glyphs in preview-*.ttf)
pub let fp_sample_code : String = "```ts\nform.onsubmit = (e) => {\n  e.preventDefault(); // 表单 0O 1lI !==\n};\n```"

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
let fp_adv_action_row : @ui.Style = @ui.css("row w=Full justify=JEnd pt=S1 pb=S1 pr=S1")

///|
// kept across runs: a value (no field of it changes)
let fp_mine_room : @ui.Style = @ui.css("row w=Full justify=JEnd")

///|
/// What their bubble leaves at the row's start, a share of the row (percent).
let fp_mine_clear_share : Double = 22.0

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
