// Slash skills (`/name`) in the composer, following the attached agent's runtime (Antigravity, Claude Code, Codex, etc.)
// plus session, preset, workspace, and built-in skills. What is written is read as the core reads it (`skill.at`:
// refLinks.ts skillAt); the skills themselves come on demand from the station (`chat.skills`).

///|
/// One skill offered in the composer's `/` menu.
#derive(Eq)
pub(all) struct SkillOffer {
  name : String
  description : String
  /// "session" | "agent" | "workspace" | "project" | "builtin"
  source : String
  /// For a "session" skill, its chat's preset or project (else its folder's name) as the station says it; "" unknown.
  place : String
}

///|
/// What the core said of the `/` at a draft field's caret (`skill.at`), and which `/` had its menu closed by Escape or a
/// pick (-1 none).
priv struct SkillField {
  mut input : @ui.Field?
  at_of : @signals.Signal[String]
  at : @signals.Signal[(Int, String)?]
  closed : @signals.Signal[Int]
}

///|
/// Skills fetched from a station for one `(station, session, runtime, preset)` scope.
priv struct SkillCatalog {
  runtime : @signals.Signal[String]
  items : @signals.Signal[Array[SkillOffer]]
  loaded : @signals.Signal[Bool]
  failed : @signals.Signal[Bool]
  mut asking : Bool
}

///|
// kept across runs: put back by skills_reset
let skill_fields : Map[String, SkillField] = Map([])

///|
// kept across runs: put back by skills_reset
let skill_catalogs : Map[String, SkillCatalog] = Map([])

///|
pub fn skills_reset() -> Unit {
  skill_fields.clear()
  skill_catalogs.clear()
}

///|
fn skill_field(key : String) -> SkillField {
  match skill_fields.get(key) {
    Some(f) => f
    None => {
      let f : SkillField = {
        input: None,
        at_of: @signals.signal("", same=fn(a, b) { a == b }),
        at: @signals.signal(None),
        closed: @signals.signal(-1),
      }
      skill_fields[key] = f
      f
    }
  }
}

///|
fn skill_scope_key(station : String, session : String, runtime : String, preset : String) -> String {
  station + "\u{1}" + session + "\u{1}" + runtime + "\u{1}" + preset
}

///|
fn skill_catalog_of(scope : String) -> SkillCatalog {
  match skill_catalogs.get(scope) {
    Some(c) => c
    None => {
      let c : SkillCatalog = {
        runtime: @signals.signal("", same=fn(a, b) { a == b }),
        items: @signals.signal([]),
        loaded: @signals.signal(false, same=fn(a, b) { a == b }),
        failed: @signals.signal(false, same=fn(a, b) { a == b }),
        asking: false,
      }
      skill_catalogs[scope] = c
      c
    }
  }
}

///|
fn is_skill_space(u : Int) -> Bool {
  u == 32 || u == 9 || u == 10 || u == 13
}

///|
/// Registers draft `key`'s field so `skills_at` can read its caret and text from the first frame.
pub fn skills_follow(key : String, input : @ui.Field) -> Unit {
  skill_field(key).input = Some(input)
}

///|
/// Fast pre-check before asking the core's `skill.at`: whether `caret` in `words` may be at the end of a `/query` token
/// starting at index 0 or after whitespace (up to 64 code units after `/`, with no whitespace or slashes inside).
/// Avoids calling `skill.at` on normal typing, URLs, and file paths.
pub fn skills_may_be_at(words : String, caret : Int) -> Bool {
  let len = words.length()
  if caret <= 0 || caret > len {
    return false
  }
  let mut i = caret - 1
  let mut walked = 0
  while i >= 0 && walked <= 64 {
    let u = words.unsafe_get(i).to_int()
    if u == 47 {
      return i == 0 || is_skill_space(words.unsafe_get(i - 1).to_int())
    }
    if u == 92 || is_skill_space(u) {
      return false
    }
    i -= 1
    walked += 1
  }
  false
}

///|
/// The person's edit `e` of draft `key`'s field (`input`), tracking `/query` at the caret for the skill menu.
pub fn skills_edited(src : Source, key : String, input : @ui.Field, e : @ui.FieldEdit) -> Unit {
  let f = skill_field(key)
  f.input = Some(input)
  let (anchor, caret) = e.selection
  let now = e.now
  if anchor != caret {
    f.at.set(None)
    return
  }
  let asked = ref_key(now, caret)
  if !skills_may_be_at(now, caret) {
    f.closed.set(-1)
    f.at.set(None)
    f.at_of.set(asked)
    return
  }
  (src.call)("skill.at", { "text": Json::string(now), "caret": Json::number(caret.to_double()) }, fn(r) {
    match r {
      Ok(v) => {
        let at = match field(Some(v), "at") {
          Some(Object(_)) as o => Some((number(o, "start").to_int(), text(o, "query")))
          _ => None
        }
        if at is None {
          f.closed.set(-1)
        }
        f.at.set(at)
        f.at_of.set(asked)
      }
      Err(_) => ()
    }
  })
}

///|
/// The `/words` draft `key`'s field's caret is at the end of, as the core last read its words and caret (where `/` is,
/// what follows it). Keeps the previous reading while the next character is answered if that `/` is still before the
/// caret; None when in none or closed by Escape/pick.
pub fn skills_at(key : String) -> (Int, String)? {
  let f = skill_field(key)
  guard f.at.get() is Some((start, query)) else { return None }
  guard start != f.closed.get() else { return None }
  guard f.input is Some(input) else { return None }
  let (anchor, caret) = input.selection()
  if anchor != caret {
    return None
  }
  let words = input.text()
  let read_now = f.at_of.get() == ref_key(words, caret)
  if read_now || (start < caret && caret <= words.length() && words.at(start).to_int() == 47) {
    Some((start, query))
  } else {
    None
  }
}

///|
/// Closes the `/` menu of draft `key` for the `/` it is currently at (Escape), until the caret leaves it.
pub fn skills_close(key : String) -> Unit {
  let f = skill_field(key)
  match f.at.get() {
    Some((start, _)) => f.closed.set(start)
    None => ()
  }
}

///|
/// Whether the `/` menu of draft `key` was closed for the `/` at `start`.
pub fn skills_closed(key : String, start : Int) -> Bool {
  skill_field(key).closed.get() == start
}

///|
/// Inserts `/<name> ` in place of the `/<query>` starting at `start` up to the current caret.
pub fn skills_pick_now(key : String, input : @ui.Field, start : Int, name : String) -> Unit {
  let caret = input.selection().1
  let f = skill_field(key)
  f.closed.set(start)
  f.at.set(None)
  let now = input.text()
  if name == "" || start < 0 || start >= now.length() || now.at(start).to_int() != 47 || caret > now.length() || caret < start {
    return
  }
  let inserted = "/" + name + " "
  refs_put(
    key,
    input,
    now.exact_view(end=start).to_owned() + inserted + now.clamped_view(start=caret).to_owned(),
    caret=start + inserted.length(),
  )
}

///|
/// Fetches the skills for `(station, session, runtime, preset)` from the station on demand (`chat.skills`).
/// Re-fetches quietly when `refresh` is true so newly installed skills appear while cached rows stay visible.
pub fn skills_fetch(
  src : Source,
  station : String,
  session : String,
  runtime : String,
  preset : String,
  refresh? : Bool = false,
) -> Unit {
  if station == "" {
    return
  }
  let scope = skill_scope_key(station, session, runtime, preset)
  let c = skill_catalog_of(scope)
  if c.asking || (!refresh && (c.loaded.untracked() || c.failed.untracked())) {
    return
  }
  c.asking = true
  let params : Map[String, Json] = { "station": Json::string(station) }
  if session != "" {
    params["session"] = Json::string(session)
  } else {
    if runtime != "" {
      params["runtime"] = Json::string(runtime)
    }
    if preset != "" {
      params["preset"] = Json::string(preset)
    }
  }
  (src.call)("chat.skills", Json::object(params), fn(res) {
    c.asking = false
    match res {
      Ok(v) => {
        let rt = text(Some(v), "runtime")
        let list : Array[SkillOffer] = []
        for x in items(Some(v), "skills") {
          let o = Some(x)
          let name = text(o, "name")
          if name != "" {
            list.push({ name, description: text(o, "description"), source: text(o, "source"), place: text(o, "place") })
          }
        }
        c.runtime.set(rt)
        c.items.set(list)
        c.loaded.set(true)
        c.failed.set(false)
      }
      Err(_) =>
        if !c.loaded.untracked() {
          c.failed.set(true)
        }
    }
  })
}

///|
/// Current cached skill catalog state `(runtime, items, loaded, failed)` for `(station, session, runtime, preset)`.
pub fn skills_state(
  station : String,
  session : String,
  runtime : String,
  preset : String,
) -> (String, Array[SkillOffer], Bool, Bool) {
  if station == "" {
    return (runtime, [], true, false)
  }
  let c = skill_catalog_of(skill_scope_key(station, session, runtime, preset))
  let rt = c.runtime.get()
  (if rt != "" { rt } else { runtime }, c.items.get(), c.loaded.get(), c.failed.get())
}

///|
/// ASCII lowercase helper for case-insensitive skill matching without touching locale-dependent APIs.
fn ascii_lower(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    let u = ch.to_int()
    if u >= 65 && u <= 90 {
      sb.write_char((u + 32).unsafe_to_char())
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
/// Filters and ranks `skills` against `query`: exact name match, name prefix, name substring, then description substring.
pub fn skills_filter(skills : Array[SkillOffer], query : String, limit? : Int = 50) -> Array[SkillOffer] {
  let q = ascii_lower(query.trim(chars=" \t").to_owned())
  if q == "" {
    let out : Array[SkillOffer] = []
    for i = 0; i < skills.length() && i < limit; i = i + 1 {
      out.push(skills[i])
    }
    return out
  }
  let b0 : Array[SkillOffer] = []
  let b1 : Array[SkillOffer] = []
  let b2 : Array[SkillOffer] = []
  let b3 : Array[SkillOffer] = []
  for s in skills {
    let nl = ascii_lower(s.name)
    if nl == q {
      b0.push(s)
    } else if nl.has_prefix(q) {
      b1.push(s)
    } else if nl.contains(q) {
      b2.push(s)
    } else if ascii_lower(s.description).contains(q) {
      b3.push(s)
    }
  }
  let out : Array[SkillOffer] = []
  for bucket in [b0, b1, b2, b3] {
    for s in bucket {
      if out.length() >= limit {
        return out
      }
      out.push(s)
    }
  }
  out
}

///|
/// Display name of an attached agent runtime for the skill menu header and source pill.
pub fn skills_runtime_label(runtime : String) -> String {
  match runtime {
    "agy" => "Antigravity"
    "claude" => "Claude"
    "codex" => "Codex"
    "copilot" => "Copilot"
    "cursor" => "Cursor"
    "grok" => "Grok"
    "devin" => "Devin"
    "hermes" => "Hermes"
    "dsh" => "DSH"
    "pi" => "Pi"
    _ => ""
  }
}

///|
/// A preset's or project's name as a badge: at most about six wide letters (a Latin letter half of one), the rest cut
/// with `…`, so a long name never squeezes the skill's own name out of its row.
pub fn skills_badge_cut(name : String) -> String {
  let most = 12 // in half-widths
  let wide = fn(ch : Char) { if ch.to_int() < 0x2E80 { 1 } else { 2 } }
  let mut used = 0
  for ch in name {
    used += wide(ch)
  }
  if used <= most {
    return name
  }
  // what fits beside the `…` (one wide letter)
  let out = StringBuilder()
  let mut kept = 0
  for ch in name {
    if kept + wide(ch) + 2 > most {
      break
    }
    kept += wide(ch)
    out.write_char(ch)
  }
  out.to_string() + "…"
}

///|
/// Localized badge text for a skill's `source`, naming the attached runtime for `"agent"` skills and the chat's preset or
/// project (`place`) for `"session"` ones.
pub fn skills_source_label(source : String, runtime : String, place? : String = "") -> String {
  match source {
    "agent" => {
      let label = skills_runtime_label(runtime)
      if label != "" { label } else { @sf.t("web-main.skillMenu.source.agent") }
    }
    "session" => if place != "" { skills_badge_cut(place) } else { @sf.t("web-main.skillMenu.source.session") }
    "workspace" => @sf.t("web-main.skillMenu.source.workspace")
    "project" => @sf.t("web-main.skillMenu.source.project")
    "builtin" => @sf.t("web-main.skillMenu.source.builtin")
    _ => ""
  }
}
