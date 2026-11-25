// Collapsible project/folder drawers for the sidebar chat list (Route A on PR #8600's workspace projects model):
// groups chats into Pinned, named project drawers (enriched with PROJECTS.jsonl `note` and `refs` folder paths),
// Cross-project (`project == ""`), and Unclassified (`project == None`), plus the chat-row "Move to project" picker,
// project metadata editor (`project.setInfo`), and drawer `+` quick-new-chat with preset auto-matching.

///|
/// The kind of a sidebar drawer section.
#derive(Eq)
pub(all) enum DrawerKind {
  Pinned
  Project(String)
  Cross
  Unclassified
}

///|
/// One collapsible drawer section in the sidebar chat list.
#derive(Eq)
pub(all) struct DrawerSection {
  key : String
  kind : DrawerKind
  label : String
  folder_hint : String
  note : String
  refs : Array[String]
  items : Array[ChatItem]
  unread_count : Int
  busy_count : Int
  wait_count : Int
  alert_count : Int
}

///|
/// Extract the last non-empty path segment of a directory path or URL (`station:~/code/monoid` -> `monoid`).
fn ref_basename(raw : String) -> String {
  let mut s = raw.trim().to_owned()
  if s == "" {
    return ""
  }
  // Strip optional `<station>:` prefix (e.g. `studio:~/code/monoid` or `mac:/Users/a/app`), preserving URLs.
  if !s.has_prefix("http://") && !s.has_prefix("https://") {
    match s.find(":") {
      Some(idx) if idx > 0 => {
        let rest = s.clamped_view(start=idx + 1).to_owned()
        if rest.has_prefix("~/") || rest.has_prefix("/") || rest.has_prefix("\\") {
          s = rest
        }
      }
      _ => ()
    }
  }
  // Strip query / fragment on URLs.
  match s.find("?") {
    Some(idx) => s = s.clamped_view(end=idx).to_owned()
    None => ()
  }
  match s.find("#") {
    Some(idx) => s = s.clamped_view(end=idx).to_owned()
    None => ()
  }
  // Strip trailing slashes and optional `.git`.
  while s.has_suffix("/") || s.has_suffix("\\") {
    s = s.clamped_view(end=s.length() - 1).to_owned()
  }
  if s.has_suffix(".git") && s.length() > 4 {
    s = s.clamped_view(end=s.length() - 4).to_owned()
  }
  let mut last = ""
  for part in s.split("/") {
    let p = part.to_owned()
    if p != "" && p != "~" {
      for sub in p.split("\\") {
        let sp = sub.to_owned()
        if sp != "" {
          last = sp
        }
      }
    }
  }
  last
}

///|
/// Derive a concise folder basename hint from `refs` for a project drawer, omitting it when identical to `project_name`.
pub fn folder_hint_of(project_name : String, refs : Array[String]) -> String {
  let lower_name = project_name.to_lower()
  // Prefer local/station directory paths over HTTP(S) URLs.
  let mut url_fallback = ""
  for r in refs {
    let trimmed = r.trim().to_owned()
    if trimmed == "" {
      continue
    }
    let base = ref_basename(trimmed)
    if base == "" || base.to_lower() == lower_name {
      continue
    }
    if trimmed.has_prefix("http://") || trimmed.has_prefix("https://") {
      if url_fallback == "" {
        url_fallback = base
      }
    } else {
      return base
    }
  }
  url_fallback
}

///|
/// Build a `DrawerSection` with aggregated unread/busy/wait/alert counts.
fn make_drawer_section(
  key : String,
  kind : DrawerKind,
  label : String,
  note : String,
  refs : Array[String],
  items : Array[ChatItem],
) -> DrawerSection {
  let mut unread_count = 0
  let mut busy_count = 0
  let mut wait_count = 0
  let mut alert_count = 0
  for item in items {
    if item.unread {
      unread_count += 1
    }
    match @sfbase.row_tone(item) {
      "alert" => alert_count += 1
      "wait" => wait_count += 1
      "busy" => busy_count += 1
      _ => ()
    }
  }
  let folder_hint = match kind {
    Project(name) => folder_hint_of(name, refs)
    _ => ""
  }
  { key, kind, label, folder_hint, note, refs, items, unread_count, busy_count, wait_count, alert_count }
}

///|
/// Group chronological `days` into collapsible project/folder drawers:
/// 1. Pinned chats (if any) at top
/// 2. Named projects with chats, ordered by most recently active chat
/// 3. Registered empty projects from `PROJECTS.jsonl` (only when `include_empty` is true)
/// 4. Explicit cross-project chats (`project == Some("")`, if any)
/// 5. Unclassified chats (`project == None`, if any) at bottom
pub fn group_into_drawers(
  days : Array[ChatDay],
  projects : Array[@sfbase.ProjectInfo],
  include_empty : Bool,
) -> Array[DrawerSection] {
  let info_by_name : Map[String, @sfbase.ProjectInfo] = Map([])
  for p in projects {
    info_by_name[p.name] = p
  }
  let pinned_items : Array[ChatItem] = []
  let project_order : Array[String] = []
  let project_items : Map[String, Array[ChatItem]] = Map([])
  let cross_items : Array[ChatItem] = []
  let unclassified_items : Array[ChatItem] = []
  for day in days {
    for item in day.items {
      if item.pinned == Some(true) {
        pinned_items.push(item)
      } else {
        match item.project {
          Some(raw) => {
            let name = raw.trim().to_owned()
            if name == "" {
              cross_items.push(item)
            } else {
              match project_items.get(name) {
                Some(arr) => arr.push(item)
                None => {
                  project_order.push(name)
                  project_items[name] = [item]
                }
              }
            }
          }
          None => unclassified_items.push(item)
        }
      }
    }
  }
  let sections : Array[DrawerSection] = []
  if !pinned_items.is_empty() {
    sections.push(make_drawer_section("pinned", Pinned, @sf.t("web-main.drawers.pinned"), "", [], pinned_items))
  }
  for name in project_order {
    let items = project_items.get(name).unwrap_or([])
    let (note, refs) = match info_by_name.get(name) {
      Some(info) => (info.note, info.refs)
      None => ("", [])
    }
    sections.push(make_drawer_section("p:" + name, Project(name), name, note, refs, items))
  }
  if include_empty {
    for p in projects {
      if !project_items.contains(p.name) {
        sections.push(make_drawer_section("p:" + p.name, Project(p.name), p.name, p.note, p.refs, []))
      }
    }
  }
  if !cross_items.is_empty() {
    sections.push(make_drawer_section("cross", Cross, @sf.t("web-main.drawers.cross"), "", [], cross_items))
  }
  if !unclassified_items.is_empty() {
    sections.push(
      make_drawer_section("unclassified", Unclassified, @sf.t("web-main.drawers.unclassified"), "", [], unclassified_items),
    )
  }
  sections
}

///|
/// Flatten `sections` and `collapsed` keys into sidebar scroll line keys (`"d/<key>"` and `"r/<row_name>"`).
pub fn drawer_keys(sections : Array[DrawerSection], collapsed : Set[String]) -> Array[String] {
  let out : Array[String] = []
  for s in sections {
    out.push("d/" + s.key)
    if !collapsed.contains(s.key) {
      for item in s.items {
        out.push("r/" + @sfbase.row_name(item))
      }
    }
  }
  out
}

///|
/// Tooltip text for a project drawer header (description + bound folders/links).
pub fn drawer_tip_text(s : DrawerSection) -> String {
  let lines : Array[String] = []
  if s.note != "" {
    lines.push(s.note)
  }
  for r in s.refs {
    if r != "" {
      lines.push(r)
    }
  }
  lines.join("\n")
}

///|
/// Leading icon name for a drawer section kind.
fn drawer_icon(kind : DrawerKind) -> String {
  match kind {
    Pinned => "pin"
    Project(_) => "folder"
    Cross => "boxes"
    Unclassified => "chats"
  }
}

///|
/// Urgent/unread summary dot color when a drawer is collapsed (`0L` = none).
fn drawer_dot_color(s : DrawerSection) -> Int64 {
  let p = @sf.theme().p
  if s.alert_count > 0 {
    p.red
  } else if s.wait_count > 0 {
    p.warn_ink
  } else if s.busy_count > 0 || s.unread_count > 0 {
    p.accent
  } else {
    0L
  }
}

///|
/// Best-effort match of an existing user preset in `newChat` against `project_name` and `refs` folder basenames.
fn match_preset_for_project(v : Json?, project_name : String, refs : Array[String]) -> (String, String)? {
  let targets : Set[String] = Set([])
  let p_low = project_name.trim().to_owned().to_lower()
  if p_low != "" {
    targets.add(p_low)
  }
  for r in refs {
    let base = ref_basename(r).to_lower()
    if base != "" {
      targets.add(base)
    }
  }
  if targets.is_empty() {
    return None
  }
  for item in items(v, "presets") {
    let o = Some(item)
    let id = text(o, "id")
    if id == "" {
      continue
    }
    let name = text(o, "name").trim().to_owned().to_lower()
    let dir_name = text(o, "dirName").trim().to_owned().to_lower()
    let summary = text(o, "summary").trim().to_owned().to_lower()
    if targets.contains(name) || targets.contains(dir_name) || targets.contains(summary) {
      return Some((id, text(o, "station")))
    }
  }
  None
}

///|
/// Start a new chat pre-targeted to `project_name` in workspace `ws_id`, auto-selecting a matching preset if available.
pub fn open_new_chat_in_project(
  src : Source,
  ws_id : String,
  project_name : String,
  refs : Array[String],
) -> Unit {
  @sfbase.fresh_reset()
  @sfbase.set_new_chat_project(ws_id, Some(project_name))
  let nc = @signals.untracked(fn() { src.topic("newChat", new_chat_asked(ws_id)).get().value })
  match match_preset_for_project(nc, project_name, refs) {
    Some((preset_id, preset_station)) => {
      if text(nc, "preset") != preset_id {
        let params : Map[String, Json] = {
          "scope": Json::string(ws_id),
          "preset": Json::string(preset_id),
        }
        if preset_station != "" {
          params["presetStation"] = Json::string(preset_station)
        }
        (src.call)("newChat.pick", Json::object(params), @sfbase.answer_unread)
      }
    }
    None => ()
  }
  open_page(NewChat)
}

///|
/// Find an online station address in workspace `ws_id` from currently listed chats, or fall back to the `stations` topic.
fn online_station_for(src : Source, ws_id : String) -> String {
  for item in listed.val {
    if workspace_of(item.station) == ws_id && item.offline is None && item.station != "" {
      return item.station
    }
  }
  let stations = @signals.untracked(fn() { src.topic("stations", { "scope": Json::string(ws_id) }).get().value })
  match stations {
    Some(Array(arr)) =>
      for s in arr {
        let o = Some(s)
        let addr = text(o, "station")
        if addr != "" && flag(o, "online") {
          return addr
        }
      }
    _ => ()
  }
  ""
}

///|
/// Open the dialog to edit a project's description (`note`) and bound folders/links (`refs`), writing via `project.setInfo`.
fn open_edit_project_info(
  src : Source,
  ws_id : String,
  project_name : String,
  initial_note : String,
  initial_refs : Array[String],
  from~ : @sf.Anchor,
) -> Unit {
  let note_field = @ui.Field::new()
  note_field.set(initial_note)
  let refs_field = @ui.Field::new()
  refs_field.set(initial_refs.join("\n"))
  let saving : @signals.Signal[Bool] = @signals.signal(false)
  let submit = fn(close : () -> Unit) {
    if saving.untracked() {
      return
    }
    let station = online_station_for(src, ws_id)
    if station == "" {
      toast_later(@sf.t("web-main.drawers.noStation"))
      return
    }
    let note = note_field.text().trim().to_owned()
    let refs : Array[String] = []
    for line in refs_field.text().split("\n") {
      let t = line.trim().to_owned()
      if t != "" {
        refs.push(t)
      }
    }
    let params : Map[String, Json] = {
      "station": Json::string(station),
      "name": Json::string(project_name),
    }
    if note == "" {
      params["clearNote"] = Json::boolean(true)
    } else {
      params["note"] = Json::string(note)
    }
    if refs.is_empty() {
      params["clearRefs"] = Json::boolean(true)
    } else {
      params["refs"] = Json::array(refs.map(Json::string))
    }
    saving.set(true)
    (src.call)("project.setInfo", Json::object(params), fn(res) {
      saving.set(false)
      match res {
        Ok(_) => {
          toast_later(@sf.t("web-main.drawers.infoSaved"))
          close()
        }
        Err(e) =>
          toast_later(
            @sf.t("web-main.act.failed", args=[("what", @sf.t("web-main.drawers.infoVerb")), ("error", text(Some(e), "message"))]),
          )
      }
    })
  }
  @sf.panel_nodes(
    @sf.t("web-main.drawers.editInfoTitle", args=[("name", project_name)]),
    fn(body, close) {
      body.box(fn(col) {
        @sf.style_node(col, fn() { drawer_edit_form })
        @sf.field_node(col, fn() { @sf.t("web-main.drawers.noteLabel") }, fn(f) {
          @sf.input_node(
            f,
            note_field,
            placeholder_by=fn() { @sf.t("web-main.drawers.notePlaceholder") },
            submitted=fn(_) { submit(close) },
          )
          |> ignore
        })
        @sf.field_node(col, fn() { @sf.t("web-main.drawers.refsLabel") }, fn(f) {
          @sf.textarea_node(
            f,
            refs_field,
            rows=4,
            most=8,
            placeholder_by=fn() { @sf.t("web-main.drawers.refsPlaceholder") },
          )
          |> ignore
        })
      })
      |> ignore
    },
    from~,
    form=true,
    foot=fn(f, close) {
      f.box(fn(row) {
        @sf.style_node(row, fn() { drawer_edit_foot })
        @sf.button_node(row, fn() { @sf.t("common.cancel") }, close, tone=Ghost) |> ignore
        @sf.button_node(row, fn() { @sf.t("common.save") }, fn() { submit(close) }, tone=Primary, busy=fn() { saving.get() })
        |> ignore
      })
      |> ignore
    },
  )
}

///|
/// Context menu on a drawer header (new chat, edit project info, expand/collapse all).
fn open_drawer_menu(
  src : Source,
  ws_id : String,
  s : DrawerSection,
  all_keys : () -> Array[String],
  from : @sf.Beside,
) -> Unit {
  let items : Array[@sf.MenuItem?] = []
  match s.kind {
    Project(name) => {
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.drawers.newChatShort"), icon="plus", fn() {
            open_new_chat_in_project(src, ws_id, name, s.refs)
          }),
        ),
      )
      items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.drawers.editInfo"), icon="edit", further=true, fn() {
            open_edit_project_info(src, ws_id, name, s.note, s.refs, from=@sf.Anchor::Unanchored)
          }),
        ),
      )
      rule_after(items)
    }
    _ => ()
  }
  items.push(
    Some(
      @sf.menu_item_of(@sf.t("web-main.drawers.expandAll"), icon="chevron-down", fn() {
        @sfbase.set_all_drawers_collapsed(src, ws_id, all_keys(), false)
      }),
    ),
  )
  items.push(
    Some(
      @sf.menu_item_of(@sf.t("web-main.drawers.collapseAll"), icon="chevron-right", fn() {
        @sfbase.set_all_drawers_collapsed(src, ws_id, all_keys(), true)
      }),
    ),
  )
  @sf.menu(items, from~, title=s.label)
}

///|
/// Collapsible project/folder drawer header row in the sidebar chat list.
/// Uses `@sf.action_box_node` for the main toggle and a sibling `@sf.icon_button_node` for quick `+` new chat on named
/// projects, keeping touch targets >= 44pt with clean separation and zero nested interactive controls.
fn drawer_header_node(
  parent : @view.View,
  src : Source,
  ws_id : String,
  section : () -> DrawerSection,
  collapsed : () -> Bool,
  all_keys : () -> Array[String],
  at : @sf.ListAt,
  tips : @sf.TipLayer,
) -> Unit {
  ignore(at)
  parent.box(fn(row) {
    @sf.style_node(row, fn() { drawer_header_wrap })
    row.min_height(By(fn() { Some(@sf.theme().items.least) })) |> ignore
    let toggle_label = fn() {
      let s = section()
      if collapsed() {
        @sf.t("web-main.drawers.expand", args=[("name", s.label)])
      } else {
        @sf.t("web-main.drawers.collapse", args=[("name", s.label)])
      }
    }
    let open_ctx = fn(from : @sf.Beside) {
      open_drawer_menu(src, ws_id, @signals.untracked(section), all_keys, from)
    }
    let btn = @sf.action_box_node(
      row,
      toggle_label,
      fn(_) { @sfbase.toggle_drawer_collapsed(src, ws_id, @signals.untracked(section).key) },
      expanded=fn() { !collapsed() },
      on_hold=fn() {
        let (x, y, w, h) = row.placed_window_now()
        open_ctx(@sf.Beside::At(x, y, w, h))
      },
      fn(b) {
        @sf.style_node(b, fn() { drawer_toggle_box }, in_row=true)
        b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).fits(Is(true)).min_height(By(fn() { Some(@sf.theme().items.least) }))
        |> ignore
        @sf.hover_ground_node(b)
        b.on_menu(fn(m) { open_ctx(@sf.at_point(m.wx, m.wy)) }) |> ignore
        // Chevron (rotates/switches cleanly between collapsed and expanded)
        @sf.icon_node(
          b,
          "chevron-down",
          drawer_chevron_size,
          By(fn() { @sf.theme().p.subtle }),
          name_now=fn() { if collapsed() { "chevron-right" } else { "chevron-down" } },
        )
        |> ignore
        // Section kind icon (folder / pin / boxes / chats)
        @sf.icon_node(
          b,
          "folder",
          drawer_icon_size,
          By(fn() {
            match section().kind {
              Project(_) => @sf.theme().p.muted
              _ => @sf.theme().p.subtle
            }
          }),
          name_now=fn() { drawer_icon(section().kind) },
        )
        |> ignore
        // Drawer title (keeps full readability before optional folder hint takes space)
        @sf.words_node(b, fn() { section().label }, fn() { drawer_title_words })
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        |> ignore
        // Optional subtle folder path hint: drops cleanly when narrow so project title never truncates needlessly
        b.show(fn() { section().folder_hint != "" }, at_once=true, fn(hint) {
          hint.drops(Is(1)).shrink(Is(3.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(hint, fn() { section().folder_hint }, fn() { drawer_hint_words })
          .shrink(Is(1.0))
          .min_width(Is(Some(0.0)))
          |> ignore
        })
        // Spacer pushing count & status dot to the trailing edge
        b.box(fn(sp) { sp.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }) |> ignore
        // Semantic dot when collapsed with urgent/busy/unread chats inside
        b.show(fn() { collapsed() && drawer_dot_color(section()) != 0L }, at_once=true, fn(dot) {
          @sf.style_node(dot, fn() { drawer_status_dot })
          dot.ground(By(fn() { drawer_dot_color(section()) })) |> ignore
        })
        // Count
        @sf.words_node(b, fn() { section().items.length().to_string() }, fn() { drawer_count_words })
        .shrink(Is(0.0))
        |> ignore
      },
    )
    @sf.tip_node(tips, btn, fn() { drawer_tip_text(section()) }) |> ignore
    // Quick "+" new-chat action on named project drawers (separate sibling button, never nested)
    row.show(fn() { section().kind is Project(_) }, at_once=true, fn(act_slot) {
      act_slot.shrink(Is(0.0)) |> ignore
      @sf.icon_button_node(
        act_slot,
        "plus",
        fn() {
          match section().kind {
            Project(name) => @sf.t("web-main.drawers.newChat", args=[("project", name)])
            _ => @sf.t("web-main.drawers.newChatShort")
          }
        },
        fn() {
          let s = @signals.untracked(section)
          match s.kind {
            Project(name) => open_new_chat_in_project(src, ws_id, name, s.refs)
            _ => ()
          }
        },
        tips~,
        icon_size=14.0,
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// Call `chat.classify` to move `item` (thread `th`) to a named project, cross-project (`Some("")`), or unclassified (`None`).
fn classify_chat(src : Source, item : ChatItem, th : Double, target : String?) -> Unit {
  let params : Map[String, Json] = {
    "station": Json::string(item.station),
    "thread": Json::number(th),
  }
  let done = match target {
    Some(name) if name != "" => {
      params["project"] = Json::string(name)
      @sf.t("web-main.chat.projectMoved", args=[("project", name)])
    }
    Some(_) => {
      params["project"] = Json::string("")
      @sf.t("web-main.chat.projectCross")
    }
    None => {
      params["clearProject"] = Json::boolean(true)
      @sf.t("web-main.chat.projectCleared")
    }
  }
  act(
    src,
    @sf.t("web-main.chat.moveProjectVerb"),
    "",
    "chat.classify",
    Json::object(params),
    done~,
    at_once=true,
  )
}

///|
/// Show the "Move to project" menu for chat `item` (thread `th`): loads workspace projects on demand if not already
/// subscribed, combines with projects seen in the current sidebar list, and offers existing projects, Cross-project,
/// Remove from project, and New project.
pub fn open_project_picker(
  src : Source,
  item : ChatItem,
  th : Double,
  from~ : @sf.Beside,
  along? : @ui.Along = Start,
) -> Unit {
  let ws = workspace_of(item.station)
  let show_menu = fn(projects : Array[@sfbase.ProjectInfo]) {
    let names : Set[String] = Set([])
    for p in projects {
      if p.name != "" {
        names.add(p.name)
      }
    }
    for row in listed.val {
      if workspace_of(row.station) == ws {
        match row.project {
          Some(p) if p.trim().to_owned() != "" => names.add(p.trim().to_owned())
          _ => ()
        }
      }
    }
    let sorted : Array[String] = []
    for n in names {
      sorted.push(n)
    }
    sorted.sort()
    let menu_items : Array[@sf.MenuItem?] = []
    for name in sorted {
      let current = item.project == Some(name)
      menu_items.push(
        Some(
          @sf.menu_item_of(name, icon=if current { "check" } else { "folder" }, checked=current, fn() {
            if !current {
              classify_chat(src, item, th, Some(name))
            }
          }),
        ),
      )
    }
    if !sorted.is_empty() {
      rule_after(menu_items)
    }
    let is_cross = item.project == Some("")
    menu_items.push(
      Some(
        @sf.menu_item_of(
          @sf.t("web-main.drawers.cross"),
          icon=if is_cross { "check" } else { "boxes" },
          checked=is_cross,
          fn() {
            if !is_cross {
              classify_chat(src, item, th, Some(""))
            }
          },
        ),
      ),
    )
    if item.project is Some(_) {
      menu_items.push(
        Some(
          @sf.menu_item_of(@sf.t("web-main.chat.projectClear"), icon="close", fn() {
            classify_chat(src, item, th, None)
          }),
        ),
      )
    }
    rule_after(menu_items)
    menu_items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-main.chat.projectNew"), icon="folder-plus", further=true, fn() {
          @sf.ask(
            @sf.t("web-main.chat.projectNewTitle"),
            @sf.t("common.save"),
            fn(raw) {
              let cleaned = raw.trim(chars=" \n\t").to_owned()
              if cleaned == "" || cleaned.contains(",") {
                return
              }
              classify_chat(src, item, th, Some(cleaned))
            },
            placeholder=@sf.t("web-main.chat.projectNewField"),
            hint=@sf.t("web-main.chat.projectNewHint"),
          )
        }),
      ),
    )
    @sf.menu(menu_items, from~, title=@sf.t("web-main.chat.moveProject"), along~)
  }
  if ws == "" || @signals.untracked(fn() { @sfbase.chat_drawers_on(src) }) {
    let projects : Array[@sfbase.ProjectInfo] = if ws == "" { [] } else { @signals.untracked(fn() { @sfbase.projects_of(src, ws).projects }) }
    show_menu(projects)
    return
  }
  let (answered, leases) = @sfbase.asked_now(src, [("projects", { "scope": Json::string(ws) })])
  let let_go = fn() { leases.each(fn(l) { l.cancel() }) }
  @sfbase.press_wait(answered, fn() {
    let v = match @signals.untracked(fn() { leases[0].follow() }) {
      Some(t) => t.value
      None => None
    }
    let_go()
    let projects : Array[@sfbase.ProjectInfo] = items(v, "projects").filter_map(fn(j) {
      let name = text(Some(j), "name").trim().to_owned()
      if name == "" { None } else { Some({ name, note: text(Some(j), "note"), refs: [] }) }
    })
    show_menu(projects)
  }, let_go~)
  |> ignore
}

///|
/// Dismissible project pill shown on the New Chat page when opened from a project drawer's `+` button.
fn new_chat_project_pill_node(parent : @view.View, ws_id : String, tips : @sf.TipLayer) -> Unit {
  parent.show(fn() { @sfbase.new_chat_project_of(ws_id) is Some(_) }, fn(pill) {
    @sf.style_node(pill, fn() { new_project_pill })
    @sf.icon_node(pill, "folder", 14.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
    @sf.words_node(
      pill,
      fn() {
        match @sfbase.new_chat_project_of(ws_id) {
          Some(p) => @sf.t("web-main.drawers.newChatProject", args=[("project", p)])
          None => ""
        }
      },
      fn() { new_project_pill_words },
    )
    |> ignore
    @sf.icon_button_node(
      pill,
      "close",
      fn() { @sf.t("web-main.drawers.clearNewChatProject") },
      fn() { @sfbase.set_new_chat_project(ws_id, None) },
      tips~,
      icon_size=13.0,
    )
    |> ignore
  })
}

///|
let drawer_chevron_size : Double = 12.0

///|
let drawer_icon_size : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let drawer_header_wrap : @ui.Style = @ui.css("row w=Full pt=S2 pb=S0_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let drawer_toggle_box : @ui.Style = @ui.css("row px=S2 py=S1 gap=S1_5 align=ACenter radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let drawer_title_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let drawer_hint_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let drawer_count_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=false, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let drawer_status_dot : @ui.Style = @ui.css("w=S1_5 h=S1_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let drawer_edit_form : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let drawer_edit_foot : @ui.Style = @ui.css("row w=Full gap=S2 justify=JEnd align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let new_project_pill : @ui.Style = @ui.css("row pl=S3 pr=S1 py=S0_5 gap=S1_5 align=ACenter radius=Full bg=A(Accent,O10) border=B0_5 border_color=A(Accent,O25)")

///|
// kept across runs: a value (no field of it changes)
let new_project_pill_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false, w=Cut)
