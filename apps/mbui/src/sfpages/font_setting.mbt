// 字体 settings core state, FontPageCtx, face picker rows, and smart local font panel.

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
  fonts_undo_snap.set(None)
}

///|
/// The face pointed at in the faces' rows, tried in the preview card before it is chosen ("" none; "\u{1}" the slot's
/// default / followUi; "\u{2}" textCjk explicit "none"; `local:<family>` one of this machine's).
let fonts_trying : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// Index into `font_presets` currently hovered (-1 = none).
let preset_trying : @signals.Signal[Int] = @signals.signal(-1, same=fn(a, b) { a == b })

///|
/// Whether the collapsible "排版与字号细节" section is expanded (collapsed by default).
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
/// Snapshot `(old_fonts, old_typography)` saved before "全部恢复默认" for one-click "撤销".
let fonts_undo_snap : @signals.Signal[(Json?, Json?)?] = @signals.signal(None)

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
  { key: "default", ui: None, ui_cjk: None, text: None, text_cjk: None, code: None, code_cjk: None },
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
fn font_typo_custom_count(typo : Json?) -> Int {
  let mut n = 0
  if font_typo_num(typo, "textSize", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if font_typo_num(typo, "codeScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  let lh = text(typo, "lineHeight")
  if lh != "" && lh != "normal" {
    n = n + 1
  }
  if !font_typo_bool(typo, "cjkAutoSpace", true) {
    n = n + 1
  }
  if !font_typo_bool(typo, "codeLigatures", true) {
    n = n + 1
  }
  for k in ["uiCjkScale", "textCjkScale", "codeCjkScale"] {
    if font_typo_num(typo, k, 100.0).round().to_int() != 100 {
      n = n + 1
    }
  }
  for k in ["uiCjkWeight", "textCjkWeight", "codeCjkWeight"] {
    if font_typo_num(typo, k, 0.0).round().to_int() != 0 {
      n = n + 1
    }
  }
  n
}

///|
/// Flat context for the fonts settings page so every section uses top-level functions instead of nested closures.
priv struct FontPageCtx {
  core : Core
}

///|
fn FontPageCtx::prefs(self : FontPageCtx) -> Json? {
  (self.core.topic)("prefs", Map([])).get().value
}

///|
fn FontPageCtx::chosen_of(self : FontPageCtx, slot : String) -> String {
  text(field(self.prefs(), "fonts"), slot)
}

///|
fn FontPageCtx::faces_view(self : FontPageCtx) -> Json? {
  field(self.prefs(), "faces")
}

///|
fn FontPageCtx::typo(self : FontPageCtx) -> Json? {
  field(self.prefs(), "typography")
}

///|
fn FontPageCtx::all(self : FontPageCtx) -> Array[Json] {
  items(self.faces_view(), "list")
}

///|
fn FontPageCtx::files_state(self : FontPageCtx) -> Json? {
  (self.core.topic)("fonts", Map([])).get().value
}

///|
fn FontPageCtx::place(self : FontPageCtx) -> String {
  ignore(self)
  @settings.font_places[@settings.fonts_at.get()]
}

///|
fn FontPageCtx::script(self : FontPageCtx) -> Int {
  ignore(self)
  @settings.fonts_script_at.get()
}

///|
fn FontPageCtx::active_slot(self : FontPageCtx) -> String {
  if self.script() == 1 {
    font_cjk_slot_of(self.place())
  } else {
    self.place()
  }
}

///|
fn FontPageCtx::shown_in(self : FontPageCtx, id : String) -> Int {
  let mut face = 0
  for i, f in self.all() {
    if text(Some(f), "id") == id {
      face = (self.core.face_preview)(id, i, items(Some(f), "files").iter().any(fn(x) { number(Some(x), "weight") == 0.0 }))
    }
  }
  face
}

///|
fn FontPageCtx::name_of_id(self : FontPageCtx, id : String) -> String {
  if id == "" {
    return @sf.t("web-pages.appearance.fonts.default")
  }
  if id.has_prefix(local_prefix) {
    return id.unsafe_substring(start=local_prefix.length(), end=id.length())
  }
  for f in self.all() {
    if text(Some(f), "id") == id {
      return text(Some(f), "name")
    }
  }
  id
}

///|
fn FontPageCtx::own_of(self : FontPageCtx, p : String) -> Int {
  if p == "code" {
    (self.core.own_code_face)()
  } else {
    0
  }
}

///|
fn FontPageCtx::as_chosen(self : FontPageCtx, p : String) -> Int {
  let id = self.chosen_of(p)
  if id == "" || (self.core.face_here)(id) {
    0
  } else {
    self.shown_in(id)
  }
}

///|
fn FontPageCtx::cjk_host_face(self : FontPageCtx, id : String) -> Int {
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
  self.shown_in(id)
}

///|
/// Host face representing the real default for `role` during hover preview (bypasses any custom `face_ui` like Menlo).
fn FontPageCtx::default_preview_face(self : FontPageCtx, role : String, is_wide : Bool) -> Int {
  match role {
    "code" => (self.core.own_code_face)()
    "ui" =>
      if is_wide {
        match self.shown_in("inter") {
          0 => @hostapi.face_sys_default
          f => f
        }
      } else {
        @hostapi.face_sys_default
      }
    _ => @hostapi.face_sys_default
  }
}

///|
fn FontPageCtx::preview_face_opt(self : FontPageCtx, id : String?, role : String, is_wide : Bool) -> Int {
  match id {
    Some(s) if s != "" =>
      match self.shown_in(s) {
        0 => self.default_preview_face(role, is_wide)
        f => f
      }
    _ => self.default_preview_face(role, is_wide)
  }
}

///|
fn FontPageCtx::try_primary_face(self : FontPageCtx, is_wide : Bool) -> Int? {
  if self.script() != 0 {
    return None
  }
  match fonts_trying.get() {
    "" => None
    "\u{1}" =>
      if self.place() == "text" {
        Some(self.as_chosen("ui"))
      } else {
        Some(self.default_preview_face(self.place(), is_wide))
      }
    id if id.has_prefix(local_prefix) =>
      match local_tried(id.unsafe_substring(start=local_prefix.length(), end=id.length())) {
        0 => None
        f => Some(f)
      }
    id =>
      match self.shown_in(id) {
        0 => None
        f => Some(f)
      }
  }
}

///|
fn FontPageCtx::ui_face(self : FontPageCtx, is_wide : Bool) -> Int {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    return self.preview_face_opt(font_presets[pi].ui, "ui", is_wide)
  }
  match (self.place(), self.try_primary_face(is_wide)) {
    ("ui", Some(f)) => f
    _ => self.as_chosen("ui")
  }
}

///|
fn FontPageCtx::text_face(self : FontPageCtx, is_wide : Bool) -> Int? {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    let pr = font_presets[pi]
    let id = match pr.text {
      Some(s) => Some(s)
      None => pr.ui
    }
    return Some(self.preview_face_opt(id, if pr.text is Some(_) { "text" } else { "ui" }, is_wide))
  }
  match (self.place(), self.try_primary_face(is_wide)) {
    ("text", Some(f)) => Some(f)
    ("ui", Some(f)) if self.chosen_of("text") == "" => Some(f)
    _ => {
      let face = if self.chosen_of("text") == "" { self.ui_face(is_wide) } else { self.as_chosen("text") }
      if face == 0 { None } else { Some(face) }
    }
  }
}

///|
fn FontPageCtx::code_face(self : FontPageCtx, is_wide : Bool) -> Int? {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    return Some(self.preview_face_opt(font_presets[pi].code, "code", is_wide))
  }
  match (self.place(), self.try_primary_face(is_wide)) {
    ("code", Some(f)) => Some(f)
    _ => {
      let face = self.as_chosen("code")
      if face == 0 { None } else { Some(face) }
    }
  }
}

///|
fn FontPageCtx::live_cjk_scale(self : FontPageCtx, p : String) -> Double {
  let key = font_cjk_scale_key(p)
  match cjk_scale_drag.get() {
    Some((k, pct)) if k == key => pct / 100.0
    Some((k, pct)) if p == "text" &&
      k == "uiCjkScale" &&
      self.chosen_of("textCjk") == "" &&
      text(self.faces_view(), "uiCjk") != "" &&
      !font_typo_bool(self.typo(), "textCjkScaleOwn", false) => pct / 100.0
    _ => font_typo_num(self.typo(), key, 100.0) / 100.0
  }
}

///|
fn FontPageCtx::live_cjk_weight(self : FontPageCtx, p : String) -> Int {
  font_typo_num(self.typo(), font_cjk_weight_key(p), 0.0).round().to_int()
}

///|
fn FontPageCtx::cjk_override_for(self : FontPageCtx, role : String) -> @view.CjkOverride? {
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
      Some(id) if id != "" => Some({ face: self.cjk_host_face(id), scale: 1.0, weight_off: 0 })
      _ => Some({ face: 0, scale: 1.0, weight_off: 0 })
    }
  }
  let scale = self.live_cjk_scale(role)
  let weight_off = self.live_cjk_weight(role)
  let tried = if self.script() == 1 { fonts_trying.get() } else { "" }
  let trying_this = tried != "" && (
    self.place() == role || (self.place() == "ui" && role == "text" && self.chosen_of("textCjk") == "")
  )
  if trying_this {
    if tried == "\u{2}" {
      return Some({ face: 0, scale: 1.0, weight_off: 0 })
    }
    if tried == "\u{1}" {
      if role == "text" && self.place() == "text" {
        return Some({ face: self.cjk_host_face(text(self.faces_view(), "uiCjk")), scale, weight_off })
      }
      return Some({ face: 0, scale: 1.0, weight_off: 0 })
    }
    let f = if tried.has_prefix(local_prefix) {
      local_tried(tried.unsafe_substring(start=local_prefix.length(), end=tried.length()))
    } else {
      self.cjk_host_face(tried)
    }
    return if f > 0 { Some({ face: f, scale, weight_off }) } else { None }
  }
  let active_id = text(self.faces_view(), font_cjk_slot_of(role))
  if active_id != "" {
    let f = self.cjk_host_face(active_id)
    if f > 0 {
      return Some({ face: f, scale, weight_off })
    }
  }
  None
}

///|
fn FontPageCtx::preview_prose_scale(self : FontPageCtx) -> Double {
  match text_size_drag.get() {
    Some(pct) => pct / 100.0
    None => font_typo_num(self.typo(), "textSize", 100.0) / 100.0
  }
}

///|
fn FontPageCtx::preview_code_scale(self : FontPageCtx) -> Double {
  match code_scale_drag.get() {
    Some(pct) => pct / 100.0
    None => font_typo_num(self.typo(), "codeScale", 100.0) / 100.0
  }
}

///|
fn FontPageCtx::preview_line_scale(self : FontPageCtx) -> Double {
  match text(self.typo(), "lineHeight") {
    "compact" => 0.92
    "relaxed" => 1.14
    _ => 1.0
  }
}

///|
fn FontPageCtx::any_customized(self : FontPageCtx) -> Bool {
  !font_preset_matches(font_presets[0], fn(s) { self.chosen_of(s) }) || font_typo_custom_count(self.typo()) > 0
}

///|
fn FontPageCtx::reset_all(self : FontPageCtx) -> Unit {
  let p = @signals.untracked(fn() { self.prefs() })
  fonts_undo_snap.set(Some((field(p, "fonts"), field(p, "typography"))))
  @settings.set_fonts_preset(self.core, preset_patch(font_presets[0]), reset_cjk_optics=true)
  @settings.set_typography(self.core, Json::null())
}

///|
fn FontPageCtx::undo_reset(self : FontPageCtx) -> Unit {
  match fonts_undo_snap.untracked() {
    Some((old_fonts, old_typo)) => {
      fonts_undo_snap.set(None)
      let patch : Map[String, Json] = Map([])
      patch["fonts"] = match old_fonts {
        Some(f) => f
        None => Json::null()
      }
      patch["typography"] = match old_typo {
        Some(t) => t
        None => Json::null()
      }
      (self.core.call)("prefs.set", Json::object(patch), fn(_) { () })
    }
    None => ()
  }
}

///|
fn clear_fonts_undo() -> Unit {
  if fonts_undo_snap.untracked() is Some(_) {
    fonts_undo_snap.set(None)
  }
}

///|
fn open_advanced_if_fixture(_parent : @view.View) -> Unit {
  if fx_advanced_up.val {
    fx_advanced_up.val = false
    advanced_open.set(true)
  }
}

///|
/// 字体's faces of `slot` (`place` + `is_cjk`) in `rows`.
fn face_rows_node(rows : @view.View, ctx : FontPageCtx, slot : String, place : String, is_cjk : Bool) -> Unit {
  let sample_key = font_slot_sample_key(place, is_cjk)
  let glyph = fn() { font_slot_glyph(place, is_cjk) }
  let chosen = fn() { ctx.chosen_of(slot) }
  let own = fn() { ctx.own_of(place) }
  if is_cjk {
    if place == "text" {
      let follow_note = fn() {
        @sf.t("web-pages.appearance.fonts.cjkFollowUi", args=[("name", ctx.name_of_id(ctx.chosen_of("uiCjk")))])
      }
      face_row_node(rows, ctx.core, slot, "", fn() { @sf.t("web-pages.appearance.fonts.followUi") }, fn() { 0 }, fn() { chosen() == "" }, fn() { ("", false) }, glyph~, note_text=follow_note)
      face_row_node(rows, ctx.core, slot, "none", fn() { @sf.t("web-pages.appearance.fonts.cjkNone") }, fn() { 0 }, fn() { chosen() == "none" }, fn() { ("", false) }, glyph~, tried_key="\u{2}", sample_key~)
    } else {
      face_row_node(rows, ctx.core, slot, "", fn() { @sf.t("web-pages.appearance.fonts.default") }, fn() { 0 }, fn() { chosen() == "" }, fn() { ("", false) }, glyph~, sample_key~)
    }
  } else {
    let none = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
    face_row_node(rows, ctx.core, slot, "", fn() { @sf.t(none) }, own, fn() { chosen() == "" }, fn() { ("", false) }, glyph~, sample_key~)
  }
  let by_id = rows.keyed_by(
    fn() {
      if is_cjk {
        let cjk_all = ctx.all().filter(fn(f) { flag(Some(f), "hasCjk") })
        if place == "code" {
          cjk_all.filter(fn(f) { flag(Some(f), "mono") }) + cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
        } else {
          cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
        }
      } else {
        ctx.all().filter(fn(f) { flag(Some(f), "mono") == (place == "code") })
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
        let st = ctx.files_state()
        let fetching = field(field(st, "fetching"), id)
        let failed = text(field(st, "failed"), id)
        let damaged = (ctx.core.face_failed)(id)
        match fetching {
          Some(Number(p, ..)) =>
            (@sf.t("android-settings.fonts.downloading", args=[("percent", (p * 100.0).to_int().to_string())]), false)
          _ =>
            if failed != "" {
              (@sf.t("android-settings.fonts.failed", args=[("error", failed)]), true)
            } else if damaged != "" {
              (@sf.t("android-settings.fonts.failed", args=[("error", damaged)]), true)
            } else if (ctx.core.face_here)(id) || items(st, "kept").contains(ToJson::to_json(id)) {
              ("", false)
            } else {
              (face_size(number(fv(), "bytes")), false)
            }
        }
      }
      let face = fn() {
        match ctx.shown_in(id) {
          0 => own()
          x => x
        }
      }
      face_row_node(r, ctx.core, slot, id, fn() { text(fv(), "name") }, face, fn() { chosen() == id }, status, glyph~, sample_key~)
    },
  )
  rows.show(fn() { @ui.can_list_local_fonts() }, fn(l) {
    local_face_row_node(l, ctx.core, slot, place, is_cjk, chosen, glyph, sample_key)
  })
}

///|
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
      press=fn() {
        clear_fonts_undo()
        @settings.set_font(core, slot, if id == "" { None } else { Some(id) })
      },
      glyph~,
      sample_key~,
      status~,
      note_text?,
    )
  })
  |> ignore
}

///|
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
        room.shrink(Is(0.0)) |> ignore
        @sf.words_node(room, fn() { status().0 }, fn() {
          if status().1 { face_status_words.then(@sf.bad) } else { face_status_words }
        })
        |> ignore
      })
    },
    held~,
    grounded~,
  )
}

///|
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
    if c.has_prefix(local_prefix) { c.unsafe_substring(start=local_prefix.length(), end=c.length()) } else { "" }
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
/// Returns `(entries, has_meta, loading)`. Never falls back to synchronous `local_font_families()` while a real desktop
/// host is scanning `local_font_info()` in the background.
fn local_font_entries() -> (Array[LocalFontEntry], Bool, Bool) {
  if @ui.local_font_info_loading() {
    return ([], false, true)
  }
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
          out.push({ name, localized: if loc == "" { name } else { loc }, mono: flag(Some(item), "mono"), cjk: flag(Some(item), "cjk") })
        }
        if out.length() > 0 {
          return (out, true, false)
        }
      }
      _ => ()
    }
  }
  (local_families().map(fn(f) { { name: f, localized: f, mono: false, cjk: false } }), false, false)
}

///|
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
    let (all_entries, has_meta, _) = entries.get()
    let mode = if has_meta { filter_at.get() } else { 0 }
    let found = all_entries.filter(fn(e) {
      let ok = match mode {
        1 => e.cjk
        2 => e.mono
        _ => true
      }
      ok && (find == "" || e.name.to_lower().contains(find) || e.localized.to_lower().contains(find))
    })
    if found.length() > local_most { found[:local_most].to_owned() } else { found }
  }
  v.pick(fn() { if entries.get().2 { 0 } else if shown().length() == 0 { 1 } else { 2 } }, fn(p, state) {
    if state != 2 {
      let key = if state == 0 { "web-pages.appearance.fonts.loadingLocal" } else { "web-pages.appearance.fonts.noMatch" }
      p.box(fn(n) {
        @sf.style_node(n, fn() { local_note_box })
        @sf.words_node(n, fn() { @sf.t(key) }, fn() { local_note }) |> ignore
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
              clear_fonts_undo()
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
let local_prefix : String = "local:"

///|
// kept across runs: said by local_tried; font_setting_reset empties it
let local_try_given : Ref[String] = Ref("")

///|
// kept across runs: said by the row and the list; font_setting_reset puts it back
pub let local_open : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })

///|
// kept across runs: said by the fixture, taken by the row; font_setting_reset puts it back
pub let fx_local_up : Ref[Bool] = Ref(false)

///|
fn local_tried(family : String) -> Int {
  let slot = @sfbase.local_try_face
  if local_try_given.val != family {
    @ui.face_clear(slot)
    local_try_given.val = if @ui.face_add_family(slot, family) { family } else { "" }
  }
  if local_try_given.val == family { slot } else { 0 }
}

///|
fn local_families() -> Array[String] {
  let parsed = @json.parse(@ui.local_font_families()) catch { _ => Json::null() }
  match parsed {
    Array(a) => a.filter_map(fn(x) { if x is String(s) { Some(s) } else { None } })
    _ => []
  }
}

///|
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
