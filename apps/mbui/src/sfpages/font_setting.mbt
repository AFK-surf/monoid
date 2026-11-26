// 字体 settings core state, FontPageCtx, face picker rows, and smart local font panel.

///|
fn font_setting_reset() -> Unit {
  fonts_trying.set("")
  preset_trying.set(-1)
  local_try_given.val = ""
  font_picker_open.set(-1)
  local_open.set(false)
  fx_local_up.val = false
  fx_code_up.val = false
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
/// Which role row in the 字体搭配 accordion is currently expanded (-1 = all collapsed, 0 = ui, 1 = text, 2 = code).
// kept across runs: said by the accordion; font_setting_reset puts it back
pub let font_picker_open : @signals.Signal[Int] = @signals.signal(-1, same=fn(a, b) { a == b })

///|
/// Whether the collapsible "更多排版细节" section is expanded (collapsed by default).
// kept across runs: said by the disclosure; font_setting_reset puts it back
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
  let cjk_scale_custom = ["uiCjkScale", "textCjkScale", "codeCjkScale"].iter().any(fn(k) {
    font_typo_num(typo, k, 100.0).round().to_int() != 100
  })
  if cjk_scale_custom {
    n = n + 1
  }
  let cjk_weight_custom = ["uiCjkWeight", "textCjkWeight", "codeCjkWeight"].iter().any(fn(k) {
    font_typo_num(typo, k, 0.0).round().to_int() != 0
  })
  if cjk_weight_custom {
    n = n + 1
  }
  n
}

///|
/// Number of customized visible controls inside the collapsible "阅读与排版" drawer (5 controls: codeScale,
/// global CJK scale, global CJK weight, cjkAutoSpace, codeLigatures; excludes outer textSize/lineHeight).
fn font_advanced_custom_count(typo : Json?) -> Int {
  let mut n = 0
  if font_typo_num(typo, "codeScale", 100.0).round().to_int() != 100 {
    n = n + 1
  }
  if !font_typo_bool(typo, "cjkAutoSpace", true) {
    n = n + 1
  }
  if !font_typo_bool(typo, "codeLigatures", true) {
    n = n + 1
  }
  let cjk_scale_custom = ["uiCjkScale", "textCjkScale", "codeCjkScale"].iter().any(fn(k) {
    font_typo_num(typo, k, 100.0).round().to_int() != 100
  })
  if cjk_scale_custom {
    n = n + 1
  }
  let cjk_weight_custom = ["uiCjkWeight", "textCjkWeight", "codeCjkWeight"].iter().any(fn(k) {
    font_typo_num(typo, k, 0.0).round().to_int() != 0
  })
  if cjk_weight_custom {
    n = n + 1
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
/// Human-readable label for a single slot trigger (`默认` / `跟随界面` / `随西文` / `Inter` / `思源黑体` / `宋体-简`),
/// plus whether that specific slot is currently downloading.
fn FontPageCtx::slot_button_label(self : FontPageCtx, place : String, is_cjk : Bool) -> (String, Bool) {
  let slot = if is_cjk { font_cjk_slot_of(place) } else { place }
  let id = self.chosen_of(slot)
  if id != "" && id != "none" {
    match field(field(self.files_state(), "fetching"), id) {
      Some(Number(p, ..)) =>
        return (@sf.t("android-settings.fonts.downloading", args=[("percent", (p * 100.0).to_int().to_string())]), true)
      _ => ()
    }
  }
  if id == "" {
    let key = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
    return (@sf.t(key), false)
  }
  if id == "none" {
    return (@sf.t("web-pages.appearance.fonts.cjkNone"), false)
  }
  if id.has_prefix(local_prefix) {
    let raw = id.unsafe_substring(start=local_prefix.length(), end=id.length())
    let (entries, has_meta, _) = local_font_entries()
    if has_meta {
      for e in entries {
        if e.name == raw {
          return (e.localized, false)
        }
      }
    }
    return (raw, false)
  }
  (self.name_of_id(id), false)
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
fn FontPageCtx::default_preview_face(self : FontPageCtx, role : String) -> Int {
  match role {
    "code" => (self.core.own_code_face)()
    "ui" =>
      match self.shown_in("inter") {
        0 => @hostapi.face_sys_default
        f => f
      }
    _ => @hostapi.face_sys_default
  }
}

///|
fn FontPageCtx::preview_face_opt(self : FontPageCtx, id : String?, role : String) -> Int {
  match id {
    Some(s) if s != "" =>
      match self.shown_in(s) {
        0 => self.default_preview_face(role)
        f => f
      }
    _ => self.default_preview_face(role)
  }
}

///|
fn FontPageCtx::try_primary_face(self : FontPageCtx) -> Int? {
  if self.script() != 0 {
    return None
  }
  match fonts_trying.get() {
    "" => None
    "\u{1}" =>
      if self.place() == "text" {
        Some(self.as_chosen("ui"))
      } else {
        Some(self.default_preview_face(self.place()))
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
fn FontPageCtx::ui_face(self : FontPageCtx) -> Int {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    return self.preview_face_opt(font_presets[pi].ui, "ui")
  }
  match (self.place(), self.try_primary_face()) {
    ("ui", Some(f)) => f
    _ => self.as_chosen("ui")
  }
}

///|
fn FontPageCtx::text_face(self : FontPageCtx) -> Int? {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    let pr = font_presets[pi]
    let id = match pr.text {
      Some(s) => Some(s)
      None => pr.ui
    }
    return Some(self.preview_face_opt(id, if pr.text is Some(_) { "text" } else { "ui" }))
  }
  match (self.place(), self.try_primary_face()) {
    ("text", Some(f)) => Some(f)
    ("ui", Some(f)) if self.chosen_of("text") == "" => Some(f)
    _ => {
      let face = if self.chosen_of("text") == "" { self.ui_face() } else { self.as_chosen("text") }
      if face == 0 { None } else { Some(face) }
    }
  }
}

///|
fn FontPageCtx::code_face(self : FontPageCtx) -> Int? {
  let pi = preset_trying.get()
  if pi >= 0 && pi < font_presets.length() {
    return Some(self.preview_face_opt(font_presets[pi].code, "code"))
  }
  match (self.place(), self.try_primary_face()) {
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
    Some((k, pct)) if k == "*" || k == key => pct / 100.0
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
/// Build a core-ts `typographyPut`-safe snapshot from a `prefs.typography` view object: strips read-only
/// `textCjkScaleOwn` / `textCjkWeightOwn` and preserves inheritance by emitting `Json::null()` when `*Own == false`.
fn sanitize_typography_snapshot(typo : Json?) -> Json? {
  match typo {
    Some(Object(m)) => {
      let out : Map[String, Json] = Map([])
      let scale_own = font_typo_bool(typo, "textCjkScaleOwn", true)
      let weight_own = font_typo_bool(typo, "textCjkWeightOwn", true)
      let allowed = [
        "textSize", "codeScale", "lineHeight", "uiCjkScale", "textCjkScale", "codeCjkScale",
        "uiCjkWeight", "textCjkWeight", "codeCjkWeight", "cjkAutoSpace", "codeLigatures",
      ]
      for k in allowed {
        if k == "textCjkScale" && !scale_own {
          out[k] = Json::null()
        } else if k == "textCjkWeight" && !weight_own {
          out[k] = Json::null()
        } else {
          match m.get(k) {
            Some(v) => out[k] = v
            None => ()
          }
        }
      }
      Some(Json::object(out))
    }
    _ => None
  }
}

///|
fn FontPageCtx::reset_all(self : FontPageCtx) -> Unit {
  let p = @signals.untracked(fn() { self.prefs() })
  fonts_undo_snap.set(Some((field(p, "fonts"), sanitize_typography_snapshot(field(p, "typography")))))
  (self.core.call)(
    "prefs.set",
    Json::object({ "fonts": Json::object(preset_patch(font_presets[0])), "typography": Json::null() }),
    @sfbase.answer_unread,
  )
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
      (self.core.call)("prefs.set", Json::object(patch), @sfbase.answer_unread)
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
/// Curated faces eligible for a given `(place, is_cjk)` slot:
/// - `西文` (`!is_cjk && place != "code"`): Latin-only proportional faces (never leaks CJK faces into Latin slot!)
/// - `等宽` (`!is_cjk && place == "code"`): monospace faces
/// - `中文` (`is_cjk`): CJK faces (for `code`, mono-CJK first; for `ui`/`text`, proportional CJK only).
fn curated_faces_for_slot(all : Array[Json], place : String, is_cjk : Bool) -> Array[Json] {
  if is_cjk {
    let cjk_all = all.filter(fn(f) { flag(Some(f), "hasCjk") })
    if place == "code" {
      cjk_all.filter(fn(f) { flag(Some(f), "mono") }) + cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
    } else {
      cjk_all.filter(fn(f) { !flag(Some(f), "mono") })
    }
  } else if place == "code" {
    all.filter(fn(f) { flag(Some(f), "mono") })
  } else {
    all.filter(fn(f) { !flag(Some(f), "mono") && !flag(Some(f), "hasCjk") })
  }
}

///|
/// Unified Popover / Sheet font picker for one slot (`place` + `is_cjk`):
/// - One search box at top filtering BOTH curated and local fonts
/// - One scrollable list: default/inherit row(s) -> curated fonts (strictly filtered by script!) -> local machine fonts
///   (auto-filtered by script when not searching, with a quiet inline "显示全部" toggle, zero pill stacking)
/// - Hovering any row previews live in the chat preview card above; clicking selects and closes the panel.
fn font_slot_picker_panel_node(
  v : @view.View,
  ctx : FontPageCtx,
  place : String,
  is_cjk : Bool,
  close : () -> Unit,
) -> Unit {
  let slot = if is_cjk { font_cjk_slot_of(place) } else { place }
  let sample_key = font_slot_sample_key(place, is_cjk)
  let chosen = fn() { ctx.chosen_of(slot) }
  let own = fn() { ctx.own_of(place) }
  let picked_local = fn() {
    let c = chosen()
    if c.has_prefix(local_prefix) { c.unsafe_substring(start=local_prefix.length(), end=c.length()) } else { "" }
  }
  let find_field = @ui.Field::new()
  let show_all_local : @signals.Signal[Bool] = @signals.signal(false, same=fn(a, b) { a == b })
  let can_local = @ui.can_list_local_fonts() || @signals.untracked(fn() { @ui.local_font_info_signal() }) != ""
  let entries = @signals.computed(fn(_) {
    if !can_local {
      ([], false, false)
    } else {
      local_font_entries()
    }
  })
  v.owns(fn() { fonts_trying.set("") }) |> ignore
  // Top search bar (searches both curated + local fonts in one place)
  v.box(fn(sbar) {
    @sf.style_node(sbar, fn() { local_search })
    @sf.input_node(sbar, find_field, placeholder=@sf.t("common.search"), small=true) |> ignore
  })
  |> ignore
  let find_q = fn() { find_field.text().trim(chars=" ").to_lower() }
  let curated_shown = fn() {
    let q = find_q()
    let base = curated_faces_for_slot(ctx.all(), place, is_cjk)
    if q == "" {
      base
    } else {
      base.filter(fn(f) {
        text(Some(f), "name").to_lower().contains(q) || text(Some(f), "id").to_lower().contains(q)
      })
    }
  }
  let local_shown = fn() {
    if !can_local {
      return []
    }
    let q = find_q()
    let (all_entries, has_meta, _) = entries.get()
    let found = if q != "" {
      all_entries.filter(fn(e) { e.name.to_lower().contains(q) || e.localized.to_lower().contains(q) })
    } else if !has_meta || show_all_local.get() {
      all_entries
    } else if is_cjk {
      all_entries.filter(fn(e) { e.cjk })
    } else if place == "code" {
      all_entries.filter(fn(e) { e.mono })
    } else {
      let latin_only = all_entries.filter(fn(e) { !e.mono && !e.cjk })
      if latin_only.length() > 0 { latin_only } else { all_entries.filter(fn(e) { !e.mono }) }
    }
    if found.length() > local_most { found[:local_most].to_owned() } else { found }
  }
  let pick_curated = fn(id : String) {
    fonts_trying.set("")
    clear_fonts_undo()
    if id != "" {
      @sfbase.face_retry(id)
    }
    @settings.set_font(ctx.core, slot, if id == "" { None } else { Some(id) })
    font_picker_open.set(-1)
    local_open.set(false)
    close()
  }
  v.box(fn(list) {
    list.max_height(Is(Some(local_list_most))) |> ignore
    list.scrolls(@view.Scroll::new(), slop=@ui.touch_slop(), bar=@ui.tree_scroll_bar(), fn(body) {
      // 1. Default / Follow-UI row(s) (shown when not filtering by search)
      body.show(at_once=true, fn() { find_q() == "" }, fn(defs) {
        @sf.group_rows_node(defs, fn(rows) {
          if is_cjk {
            if place == "text" {
              let follow_note = fn() {
                @sf.t("web-pages.appearance.fonts.cjkFollowUi", args=[("name", ctx.name_of_id(ctx.chosen_of("uiCjk")))])
              }
              face_panel_row_node(rows, "", fn() { @sf.t("web-pages.appearance.fonts.followUi") }, fn() { 0 }, fn() { chosen() == "" }, fn() { ("", false) }, fn() { pick_curated("") }, note_text=follow_note)
              face_panel_row_node(rows, "none", fn() { @sf.t("web-pages.appearance.fonts.cjkNone") }, fn() { 0 }, fn() { chosen() == "none" }, fn() { ("", false) }, fn() { pick_curated("none") }, tried_key="\u{2}", sample_key~)
            } else {
              face_panel_row_node(rows, "", fn() { @sf.t("web-pages.appearance.fonts.default") }, fn() { 0 }, fn() { chosen() == "" }, fn() { ("", false) }, fn() { pick_curated("") }, sample_key~)
            }
          } else {
            let none = if place == "text" { "web-pages.appearance.fonts.followUi" } else { "web-pages.appearance.fonts.default" }
            face_panel_row_node(rows, "", fn() { @sf.t(none) }, own, fn() { chosen() == "" }, fn() { ("", false) }, fn() { pick_curated("") }, sample_key~)
          }
        })
      })
      // 2. Curated section (strictly filtered for this slot)
      body.show(at_once=true, fn() { curated_shown().length() > 0 }, fn(csec) {
        csec.box(fn(chdr) {
          @sf.style_node(chdr, fn() { picker_sec_hdr })
          @sf.words_node(chdr, fn() { @sf.t("web-pages.appearance.fonts.curated") }, fn() { picker_sec_label }) |> ignore
        }) |> ignore
        let by_id = csec.keyed_by(curated_shown, fn(f) { text(Some(f), "id") })
        @sf.group_rows_node(csec, fn(rows) {
          rows.each(fn() { by_id.keys() }, fn(k) { k }, fn(r, id) {
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
            face_panel_row_node(r, id, fn() { text(fv(), "name") }, face, fn() { chosen() == id }, status, fn() { pick_curated(id) }, sample_key~)
          })
        })
      })
      // 3. Local machine fonts section (unified in the same list, auto-filtered by script!)
      if can_local {
        body.box(fn(lhdr) {
          @sf.style_node(lhdr, fn() { picker_sec_hdr })
          @sf.words_node(lhdr, fn() { @sf.t("web-pages.appearance.fonts.local") }, fn() { picker_sec_label }) |> ignore
          lhdr.show(at_once=true, fn() { entries.get().1 && find_q() == "" }, fn(tw) {
            @sf.action_box_node(
              tw,
              fn() {
                if show_all_local.get() {
                  if is_cjk { @sf.t("web-pages.appearance.fonts.localFilter.cjk") }
                  else if place == "code" { @sf.t("web-pages.appearance.fonts.localFilter.mono") }
                  else { @sf.t("web-pages.appearance.fonts.localFilter.latin") }
                } else {
                  @sf.t("web-pages.appearance.fonts.localFilter.all")
                }
              },
              fn(_) { show_all_local.set(!show_all_local.untracked()) },
              fn(btn) {
                @sf.style_node(btn, fn() { if @sf.lit_node(btn) { picker_filter_hot } else { picker_filter_btn } })
                @sf.words_node(btn, fn() {
                  if show_all_local.get() {
                    if is_cjk { @sf.t("web-pages.appearance.fonts.localFilter.cjk") }
                    else if place == "code" { @sf.t("web-pages.appearance.fonts.localFilter.mono") }
                    else { @sf.t("web-pages.appearance.fonts.localFilter.latin") }
                  } else {
                    @sf.t("web-pages.appearance.fonts.localFilter.all")
                  }
                }, fn() { picker_filter_words }) |> ignore
              },
            ) |> ignore
          })
        }) |> ignore
        body.pick(fn() { if entries.get().2 { 0 } else if local_shown().length() == 0 { 1 } else { 2 } }, fn(p, state) {
          if state != 2 {
            let key = if state == 0 { "web-pages.appearance.fonts.loadingLocal" } else { "web-pages.appearance.fonts.noMatch" }
            p.box(fn(n) {
              @sf.style_node(n, fn() { local_note_box })
              @sf.words_node(n, fn() { @sf.t(key) }, fn() { local_note }) |> ignore
            }) |> ignore
          } else {
            @sf.group_rows_node(p, fn(grows) {
              grows.each(local_shown, fn(e) { e.name }, fn(row, e) {
                let entry = e.untracked()
                let f = entry.name
                fonts_tried_by(row, local_prefix + f)
                @sf.action_box_node(row, fn() { entry.localized }, fn(_) {
                  fonts_trying.set("")
                  clear_fonts_undo()
                  @sfbase.face_retry(local_prefix + f)
                  @settings.set_font(ctx.core, slot, Some(local_prefix + f))
                  font_picker_open.set(-1)
                  local_open.set(false)
                  close()
                }, fn(b) {
                  let hot = fn() { f == picked_local() || @sf.lit_node(b) }
                  @sf.style_node(b, fn() { if hot() { local_row_hot } else { local_row } })
                  b.min_height(Is(Some(44.0))) |> ignore
                  b.box(fn(names) {
                    names.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                    @sf.words_node(names, fn() { entry.localized }, fn() { local_name }) |> ignore
                    if entry.localized != entry.name {
                      @sf.words_node(names, fn() { entry.name }, fn() { local_sub_name }) |> ignore
                    }
                  }) |> ignore
                  b.show(fn() { f == picked_local() }, fn(k) {
                    @sf.icon_node(k, "check", font_check, By(fn() { @sf.theme().p.accent_text })) |> ignore
                  })
                }) |> ignore
              })
            })
          }
        })
      } else {
        body.show(at_once=true, fn() { find_q() != "" && curated_shown().length() == 0 }, fn(empty) {
          @sf.style_node(empty, fn() { local_note_box })
          @sf.words_node(empty, fn() { @sf.t("web-pages.appearance.fonts.noMatch") }, fn() { local_note }) |> ignore
        })
      }
    }) |> ignore
  }) |> ignore
}

///|
fn face_panel_row_node(
  parent : @view.View,
  id : String,
  name : () -> String,
  face : () -> Int,
  on : () -> Bool,
  status : () -> (String, Bool),
  press : () -> Unit,
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
      press~,
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
  sample_key? : String = "web-pages.appearance.fonts.sampleRow",
  status? : () -> (String, Bool) = fn() { ("", false) },
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
      compact=true,
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
  mono? : Bool = false,
) -> @view.View {
  parent.box(fn(w) {
    w
    .words_runs(By(fn() {
      let f = face()
      [@ui.span(words(), face=if f == 0 { None } else { Some(f) }, mono~)]
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
        let ov = match cjk {
          Some(c) => c()
          None => None
        }
        {
          ..@view.runs_plain,
          words: match person {
            Some(p) => p()
            None => false
          },
          cjk: if mono { None } else { ov },
          code_cjk: if mono { ov } else { None },
        }
      }))
      |> ignore
    }
  })
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
// kept across runs: static styles for unified font picker panel
let picker_sec_hdr : @ui.Style = @ui.css("row w=Full px=S3 pt=S1_5 pb=S0_5 justify=JBetween align=ACenter")
// kept across runs: a value
let picker_sec_label : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Subtle, wrap=false)
// kept across runs: a value
let picker_filter_btn : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Full")
// kept across runs: a value
let picker_filter_hot : @ui.Style = picker_filter_btn.then(@ui.css("bg=Hover"))
// kept across runs: a value
let picker_filter_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value (all CJK chars 表单 appear in sampleText -> 0 missing glyphs in preview-*.ttf)
pub let fp_sample_code : String = "form.onsubmit = (e) => e.preventDefault(); // 表单 0O 1lI !=="

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
// kept across runs: said by the fixture for settings-fonts-code; font_setting_reset puts it back
pub let fx_code_up : Ref[Bool] = Ref(false)

///|
fn local_tried(family : String) -> Int {
  let slot = @sfbase.local_try_face
  if local_try_given.val != family {
    @ui.face_clear(slot)
    if @ui.face_add_family(slot, family) {
      @ui.face_set_ligatures(slot, @sfbase.code_ligatures_enabled())
      local_try_given.val = family
    } else {
      local_try_given.val = ""
    }
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

///|
// kept across runs: static styles for curated & inline local font rows
let font_check : Double = 15.0
// kept across runs: a value
let local_most : Int = 80
// kept across runs: a value
let local_list_most : Double = 265.0
// kept across runs: a value
let face_name_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, w=Full)
// kept across runs: a value
let face_sample_words : @ui.TextStyle = @ui.text_style(
  size=Meta,
  leading=L6,
  color=Muted,
  dark=@ui.text_patch(color=Over(Muted, A(Fg, O75))),
  w=Full,
  max_lines=1,
)
// kept across runs: a value
let face_status_room : @ui.Style = @ui.css("ml=S2")
// kept across runs: a value
let face_status_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let local_search : @ui.Style = @ui.css("w=Full pb=S1_5")
// kept across runs: a value
let local_row : @ui.Style = @ui.css("row w=Full px=S4 py=S2 gap=S2 align=ACenter justify=JBetween")
// kept across runs: a value
let local_row_hot : @ui.Style = local_row.then(@ui.css("bg=Hover"))
// kept across runs: a value
let local_name : @ui.TextStyle = @ui.text_style(size=Body, leading=L6, color=Fg, wrap=false, w=Full, max_lines=1)
// kept across runs: a value
let local_sub_name : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false, w=Full, max_lines=1)
// kept across runs: a value
let local_note_box : @ui.Style = @ui.css("w=Full px=S4 py=S3")
// kept across runs: a value
let local_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)
