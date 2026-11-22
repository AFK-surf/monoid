// An agent's request about a vault item as a card: to use one
// or to keep one ( 申请和授权, agent 存入). One card wherever such a request is answered: in place of the
// agent's post in its chat and among the vault page's waiting requests. A card of words
// (@sf.card): what is asked in its title, the command it is for, a risk only where there is one, and the answer at its
// foot: the answer most give as the one solid button (允许 / 存入), the other beside it (拒绝 / 不存), how long a use is
// allowed a choice beside them that starts at the longest the item is given for (`vault.approve`, `vault.deny`). Only
// the viewer's own request can be answered, and only in an app keeping keys; elsewhere a line says whose it is or where
// it is approved. A secret to keep while the vault is not on on this device: 开启密钥库, to the vault's page. One the
// person types in (the agent has none): its field over the answer (a login's account too, where the agent named none; a
// file, the button that picks it, its name and size once picked), 存入 once something is in it, Enter as 存入; what was
// typed goes only with `vault.approve`, and is let go once it went.

///|
/// What a request's card says: the item's name, how it would be given (`mode`), the command it is
/// for; one to keep a secret, what it is (`save_kind`: login, token, ssh_key, file), its account (a file: its name),
/// and whether the person types it in (`typed`; a file: picks it); another station of the workspace its commands run
/// on, by name (empty: the chat's).
#derive(Eq)
pub(all) struct Asked {
  name : String
  reason : String
  timeout_kind : String
  timeout_seconds : Int
  approved_timeout_kind : String
  approved_timeout_seconds : Int
  mode : String
  command : String
  how_text : String
  save_kind : String
  save_vault_name : String
  save_shared : Bool
  save_targets : Array[(String, String, Bool)]
  username : String
  filename : String
  typed : Bool
  /// with `typed`, a service the person signs in to for it instead (slack)
  oauth : String
  station : String
  /// one to rename the item or change its about (secret_describe): its name as it would be (`new_name`), its about
  /// as it would be and as it was (`new_about`, `was_about`)
  describe : Bool
  new_name : String
  new_about : String
  was_about : String
  /// one to delete the item (secret_delete)
  remove : Bool
  /// a request to list personal secrets from other workspaces (`secret_list` other_workspaces)
  browse : Bool
  browse_hint : String
  browse_workspaces : Int
  browse_items : Int
  /// source workspace and personal vault metadata for a cross-workspace secret request
  cross_workspace : String
  cross_workspace_name : String
  cross_vault_name : String
}

///|
/// Whether what is asked writes the item (one to keep, one to rename): answered once, with no length of use.
pub fn Asked::writes(self : Asked) -> Bool {
  self.save_kind != "" || self.describe || self.remove
}

///|
/// One to rename the item: whether its name would change.
fn Asked::renames(self : Asked) -> Bool {
  self.describe && self.new_name != "" && self.new_name != self.name
}

///|
/// One to rename the item: whether its about would change.
fn Asked::reabouts(self : Asked) -> Bool {
  self.describe && self.new_about != self.was_about
}

///|
/// One to rename the item, its title (the user, 2026-11-12: 「这 ui…是人能看懂的吗」, 「遣词正经一点」): 修改密钥的名称与说明, 修改密钥的名称, or 修改密钥 … 的说明
/// (its name heavier than the words around it), what changes said under it a part each.
fn describe_title_runs(ask : Asked, named : (String) -> @ui.Run, words : (String) -> @ui.Run) -> Array[@ui.Run] {
  if ask.renames() && ask.reabouts() {
    [words(tr("android-settings.vault.ask.describe.both"))]
  } else if ask.renames() {
    [words(tr("android-settings.vault.ask.describe.name"))]
  } else {
    fill_named("android-settings.vault.ask.describe.about", [("name", ask.name)], named, words)
  }
}

///|
/// A part's line as it was (`was`: crossed out, quiet) or as it would be (`strong`: heavier, a name's): each on a line of
/// its own, all of them where the card's words start, so the card has one edge (the user, 2026-11-12:
/// 「感觉视觉上还不够清晰」, 「你这样会导致对齐是错的」).
fn describe_words_runs(was : Bool, words : String, strong? : Bool = false) -> Array[@ui.Run] {
  let t = @sf.theme()
  if was {
    [@ui.span(words, color=t.p.muted, strike=true)]
  } else {
    [@ui.span(words, weight=if strong { 600 } else { 400 }, color=t.p.text)]
  }
}

///|
/// Its name's lines: as it is, then as it would be.
fn describe_name_lines(ask : Asked) -> Array[Array[@ui.Run]] {
  [describe_words_runs(true, ask.name), describe_words_runs(false, ask.new_name, strong=true)]
}

///|
/// Its about's lines: as it was where it said one, then as it would be (that it goes, quiet).
fn describe_about_lines(ask : Asked) -> Array[Array[@ui.Run]] {
  let out = if ask.was_about != "" { [describe_words_runs(true, ask.was_about)] } else { [] }
  if ask.new_about == "" {
    out.push([@ui.span(tr("android-settings.vault.ask.describe.noAbout"), color=@sf.theme().p.muted)])
  } else {
    out.push(describe_words_runs(false, ask.new_about))
  }
  out
}

///|
// kept across runs: a value (no field of it changes)
let ask_describe_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, w=Full)

///|
/// A part of what renaming changes, apart from what is over it by room alone (no ground of its own: the card's one edge
/// for all its words): what it is (名称, 说明), quiet, over its lines.
// kept across runs: a value (no field of it changes)
let ask_describe_part : @ui.Style = @ui.css("w=Full gap=S0_5 pt=S3")

///|
/// A secret to keep that the person types in here (`save.typed`: the agent has none): its kind, and the account the
/// agent named (empty: a login's is asked for too).
#derive(Eq)
pub(all) struct Typed {
  kind : String
  username : String
  /// a service the person signs in to for it in place of typing it in (slack: `vault_oauth_of`), "" none
  oauth : String
}

///|
/// The secret to type in of request `save` (its `save`), or None where it is not the person's to type.
pub fn typed_of(save : Json?) -> Typed? {
  if flag(save, "typed") {
    Some({ kind: text(save, "kind"), username: text(save, "username"), oauth: text(save, "oauth") })
  } else {
    None
  }
}

///|
/// The secret to type in of what is asked, or None.
fn Asked::typed_in(self : Asked) -> Typed? {
  if self.typed {
    Some({ kind: self.save_kind, username: self.username, oauth: self.oauth })
  } else {
    None
  }
}

///|
/// The length of use picked for each request (a rig's, a phone's too, keyed `rig/<id>`, `phone/<id>`): read by what is
/// made once of a card; put back by `reset`.
let vault_picked : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// How long each requested timeout is chosen to be, in minutes (授权时限's): read by what is made once of a card as by
/// the old view's; put back by `reset`.
let vault_timeout_minutes : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
// kept across runs: an immutable style
let vault_timeout_panel : @ui.Style = @ui.css("w=Full gap=S4")

///|
/// What was tapped on each request while the core has it (`true`: the yes, `false`: the no), till it answers
/// (VaultActions' pending: the core's doing comes a frame later); put back by `reset`.
let vault_pending : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// What the person types in for each request whose secret is theirs to type, by request and field (`/secret`,
/// `/username`): kept only till it went with `vault.approve`; put back by `reset`.
let vault_typed : @sf.LiveMap[String, @ui.Field] = @sf.LiveMap::new()

///|
/// The file picked for each request whose secret is a file the person picks: its bytes in base64 and its name, kept
/// only till it went with `vault.approve`. Put back by `reset`.
let vault_files : @sf.LiveMap[String, (String, String)] = @sf.LiveMap::new()

///|
/// A single personal secret selected in the cross-workspace browse picker.
priv struct BrowsePickedItem {
  workspace : String
  vault : String
  item : String
  name : String
}

///|
/// The selection chosen in the cross-workspace browse picker for a request.
priv struct BrowsePick {
  workspaces : Int
  items : Array[BrowsePickedItem]
}

///|
/// The personal secrets manually selected for each cross-workspace browse request; put back by `reset`.
let vault_browse_picked : @sf.LiveMap[String, BrowsePick] = @sf.LiveMap::new()

///|
/// Generation counter for in-flight `vault.browseCandidates` reads so stale callbacks do not open a panel.
let vault_browse_seq : Ref[Int] = Ref(0)

///|
/// The target vault manually picked for each save request: (vault_id, vault_name, is_workspace); put back by `reset`.
let vault_target_picked : @sf.LiveMap[String, (String, String, Bool)] = @sf.LiveMap::new()

///|
/// Keyed vaults this device can save a secret into, personal vaults first and workspace vaults after
/// (empty when plain mode is on, since plain mode has no vaults).
fn vault_save_targets(core : Core, ws : String) -> Array[(String, String, Bool)] {
  let v = vaults_of(core, ws)
  if flag(v, "plain") {
    return []
  }
  let personal : Array[(String, String, Bool)] = []
  let workspace : Array[(String, String, Bool)] = []
  for row in items(v, "vaults") {
    if flag(Some(row), "keyed") {
      let is_ws = text(Some(row), "scope") == "workspace"
      let entry = (text(Some(row), "id"), text(Some(row), "name"), is_ws)
      if is_ws {
        workspace.push(entry)
      } else {
        personal.push(entry)
      }
    }
  }
  personal + workspace
}

///|
fn vault_ask_reset() -> Unit {
  vault_timeout_minutes.clear()
  vault_picked.clear()
  vault_target_picked.clear()
  vault_browse_picked.clear()
  vault_browse_seq.val = 0
  vault_pending.clear()
  vault_typed.clear()
  vault_files.clear()
}

///|
/// How a request is answered here, what its card's foot is.
#derive(Eq, Debug)
pub(all) enum Answer {
  /// 允许 / 存入 and 拒绝 / 不存: a use given for as long as `lasts` at the longest (unused for a secret to keep)
  Approve(String)
  /// a secret to keep while this device's vault is not on: 开启密钥库, to the vault's page, first
  SetUp
  /// approved only in an app that keeps keys (a web page keeps none)
  Elsewhere
  /// a secret to keep its station sealed to the person's devices set up then, this one not among them: approved on
  /// one of those (or here once the station has this device's certificate and seals it again)
  NotHere
  /// this device does not hold a key to this encrypted vault yet: approve on an authorized device or get access in Vault
  NoKey
  /// cross-workspace browse request with no eligible personal secrets in other workspaces on this device
  Empty
  /// decided already, its card not saying so yet
  Decided
  /// another's to answer: whose (the card's 由…决定)
  Theirs(String)
}

///|
/// How a request is answered here as its card says it (`answer`, `lasts`: its `vaultAsk`'s), the core having answered
/// that with its message from the vault it holds: nothing more is asked of it. Not the viewer's (`mine`), `who`'s.
pub fn card_answer(answer : String, lasts : String, mine : Bool, who? : String? = None) -> Answer {
  if !mine {
    return match who {
      Some(w) => Theirs(w)
      None => Decided
    }
  }
  match answer {
    "setUp" => SetUp
    "elsewhere" => Elsewhere
    "notHere" => NotHere
    "noKey" => NoKey
    "empty" => Empty
    _ => Approve(lasts)
  }
}

///|
/// How request `request` in workspace `ws` is answered here, from the vaults topic (the vault page's, which lists the
/// requests from it; a card from before its station said what it asks), whether it is one to keep and its secret to type
/// in: None while the topic has not come.
fn topic_answer(core : Core, ws : String, request : String, mine : Bool, who : String?) -> (Answer, Bool, Typed?)? {
  let view = vaults_of(core, ws)
  if view is None {
    return None
  }
  // a web page keeps no keys (the plain library's, without security mode, are approved anywhere)
  if !flag(view, "available") && !flag(view, "plain") {
    return Some((Elsewhere, false, None))
  }
  let row = items(view, "requests").iter().find_first(fn(r) { text(Some(r), "id") == request })
  if !mine || (row is None && !vault_pending.contains(request)) {
    return Some(
      (
        match who {
          Some(w) if !mine => Theirs(w)
          _ => Decided
        },
        false,
        None,
      ),
    )
  }
  // cross-workspace personal secret browse request: does not require local workspace vault setup
  if field(row, "browse") is Some(_) {
    if !flag(view, "available") {
      return Some((Elsewhere, false, None))
    } else if flag(row, "noKey") {
      return Some((NoKey, false, None))
    } else if count(row, "browseItems") == 0 {
      return Some((Empty, false, None))
    } else {
      return Some((Approve(""), false, None))
    }
  }
  // cross-workspace personal secret use request: only needs the source vault key on this device
  if field(row, "cross") is Some(_) {
    if flag(row, "noKey") {
      return Some((NoKey, false, None))
    } else {
      return Some((Approve(text(row, "lasts")), false, None))
    }
  }
  // (one to rename the item is answered as one to keep: written into the vault, by a device set up)
  let save = field(row, "save") is Some(_) || field(row, "describe") is Some(_) || flag(row, "remove")
  let typed = typed_of(field(row, "save"))
  let is_save = field(row, "save") is Some(_)
  if !is_save && flag(row, "noKey") {
    Some((NoKey, save, typed))
  } else if save && !flag(view, "plain") && !flag(view, "setUp") {
    Some((SetUp, save, typed))
  } else if save && flag(row, "notHere") {
    Some((NotHere, save, typed))
  } else if flag(row, "noKey") {
    Some((NoKey, save, typed))
  } else {
    Some((Approve(text(row, "lasts")), save, typed))
  }
}

///|
/// What is said when the person manually chose a shared workspace vault on a save card, or "" otherwise.
fn vault_save_shared_text(ask : Asked, request : String) -> String {
  if ask.save_kind != "" && request != "" {
    match vault_target_picked.get(request) {
      Some((_, name, true)) =>
        if name != "" {
          fill("android-settings.vault.ask.saveSharedNamed", [("name", name)])
        } else {
          tr("android-settings.vault.ask.saveShared")
        }
      _ => ""
    }
  } else {
    ""
  }
}

///|
/// Summary of selected cross-workspace personal secrets for a pending browse request, or "" when not applicable.
fn vault_browse_summary(ask : Asked, request : String) -> String {
  if !ask.browse {
    return ""
  }
  match vault_browse_picked.get(request) {
    Some(p) => {
      let n = p.items.length()
      if n == 0 {
        ""
      } else if p.workspaces == 1 && n == 1 {
        fill("android-settings.vault.ask.browseSummaryOneItem", [("name", p.items[0].name)])
      } else if p.workspaces == 1 {
        fill("android-settings.vault.ask.browseSummaryOneWs", [("n", n.to_string())])
      } else {
        fill("android-settings.vault.ask.browseSummary", [("w", p.workspaces.to_string()), ("n", n.to_string())])
      }
    }
    None =>
      if ask.browse_items <= 0 {
        ""
      } else if ask.browse_workspaces <= 1 {
        fill("android-settings.vault.ask.browseSummaryOneWs", [("n", ask.browse_items.to_string())])
      } else {
        fill("android-settings.vault.ask.browseSummary", [("w", ask.browse_workspaces.to_string()), ("n", ask.browse_items.to_string())])
      }
  }
}

///|
/// Cross-workspace source notice for a cross-workspace secret use request, or "" otherwise.
fn vault_cross_source_text(ask : Asked) -> String {
  if !ask.browse && ask.cross_workspace != "" {
    let ws_name = if ask.cross_workspace_name != "" { ask.cross_workspace_name } else { ask.cross_workspace }
    fill("android-settings.vault.ask.crossFrom", [("workspace", ws_name)])
  } else {
    ""
  }
}


///|
/// How a request ended, in words: the item's name in the words' strong ink (ended_name), the rest
/// quiet.
pub fn vault_outcome_words(ask : Asked, status : String, scope : String) -> Array[@ui.Run] {
  let save = ask.save_kind != ""
  let scope = if scope == "once" || scope == "hour" { scope } else { "chat" }
  let said = fn(key, args) { fill_named(key, args, ended_name, fn(w) { @ui.span(w) }) }
  match status {
    "withdrawn" => [@ui.span(tr("android-settings.vault.ask.withdrawn"))]
    "granted" if ask.browse =>
      if ask.browse_items == 1 {
        [@ui.span(tr("android-settings.vault.ask.browseGrantedOne"))]
      } else {
        [@ui.span(fill("android-settings.vault.ask.browseGranted", [("n", ask.browse_items.to_string())]))]
      }
    "denied" if ask.browse => [@ui.span(tr("android-settings.vault.ask.browseDenied"))]
    "granted" if ask.remove => said("android-settings.vault.ask.removed", [("name", ask.name)])
    "denied" if ask.remove => said("android-settings.vault.ask.notRemoved", [("name", ask.name)])
    "granted" if ask.describe => said("android-settings.vault.ask.changed", [("name", ask.name)])
    "denied" if ask.describe => said("android-settings.vault.ask.notChanged", [("name", ask.name)])
    "granted" if save =>
      said("android-settings.vault.ask.kept", [
        ("kind", tr("android-settings.vault.ask.kind." + ask.save_kind)),
        ("name", ask.name),
      ])
    "granted" if ask.approved_timeout_seconds > 0 => {
      let days = ask.approved_timeout_seconds % 86400 == 0
      let hours = ask.approved_timeout_seconds % 3600 == 0
      let n = if days { ask.approved_timeout_seconds / 86400 } else if hours { ask.approved_timeout_seconds / 3600 } else { ask.approved_timeout_seconds / 60 }
      let time = fill(if days { "android-settings.vault.timeout.nDays" } else if hours { "android-settings.vault.timeout.nHours" } else { "android-settings.vault.timeout.nMinutes" }, [("n", n.to_string())])
      let how = fill("android-settings.vault.timeout.approved." + ask.approved_timeout_kind, [("time", time)])
      said("android-settings.vault.ask.granted", [("name", ask.name), ("scope", how)])
    }
    "granted" if ask.timeout_seconds > 0 && scope != "once" => said("android-settings.vault.ask.timedGranted", [("name", ask.name)])
    "granted" => said("android-settings.vault.ask.granted", [("name", ask.name), ("scope", tr("android-settings.vault.scope." + scope))])
    "denied" if save => said("android-settings.vault.ask.notKept", [("name", ask.name)])
    "denied" => said("android-settings.vault.ask.denied", [("name", ask.name)])
    _ => [@ui.span(tr("android-settings.vault.ask.expired"))]
  }
}

///|
/// An item's name in a line saying how its request ended: set apart from the quiet words around it by the strong ink
/// and a heavier weight, not by quotes (the user, 2026-10-30: 「名字不要再用方括号括起来，而是用 GUI 的方式来处理」).
fn ended_name(name : String) -> @ui.Run {
  @ui.span(name, weight=500, color=@sf.theme().p.text)
}

///|
/// The workspace's vaults as the core has them (`vaults`: its requests, whether keys are kept here).
fn vaults_of(core : Core, ws : String) -> Json? {
  (core.topic)("vaults", { "workspace": str(ws) }).get().value
}

///|
/// The command, one line of it, 12 and quiet.
// kept across runs: a value (no field of it changes)
let ask_command : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4_75, color=Muted, wrap=false, max_lines=1, w=Full)

///|
/// What the person types in, over the answer: its fields 8 apart, the card's width.
// kept across runs: a value (no field of it changes)
let ask_typed : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// A file to pick: its name and size, then the button that picks it, 8 apart.
// kept across runs: a value (no field of it changes)
let ask_file : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let ask_file_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false, w=Cut)

///|
/// How long, on a line of its own over the buttons where it has not the room beside them: the foot's lines apart.
// kept across runs: a value (no field of it changes)
let ask_over : @ui.Style = @ui.css("row mb=S2")

///|
/// The length of use of request `request` chosen in a panel (授权时限, a form: in the window's middle, a sheet with a
/// finger), as `minutes` (at most `max_minutes`) and `scope` (once, idle, fixed) say it now: 时长, one of the presets or
/// 自定义 (its minutes or hours typed, the unit at the head's end: a choice of the two, what is typed turned into the
/// other as it is chosen); 失效方式 (idle or fixed) where it is not once. 完成 keeps them for the card (vault_picked,
/// vault_timeout_minutes), not pressed while what is typed is out of bounds. What it holds nodes of the window's tree,
/// made once as it opens (@sf.panel_nodes), its choices signals of its own: what it shows as 完成 closes it is what it
/// shows on its way out.
fn vault_timeout_open(request : String, minutes : Int, max_minutes : Int, scope : String) -> Unit {
  let same = fn(a : String, b : String) { a == b }
  let unit = @signals.signal(if minutes % 60 == 0 { "hours" } else { "minutes" }, same~)
  let field = @ui.Field::new(text=(if minutes % 60 == 0 { minutes / 60 } else { minutes }).to_string())
  // (what the field holds, as it is typed and as it is put in it here: what binds reads this)
  let typed = @signals.signal(field.text(), same~)
  let chosen = @signals.signal(if scope == "fixed" { "fixed" } else { "idle" }, same~)
  let duration = @signals.signal(if scope == "once" { "once" } else { minutes.to_string() }, same~)
  let duration_words = fn(n : Int) -> String {
    let days = n % 1440 == 0
    let hours = n % 60 == 0
    fill(if days { "android-settings.vault.timeout.nDays" } else if hours { "android-settings.vault.timeout.nHours" } else { "android-settings.vault.timeout.nMinutes" }, [("n", (if days { n / 1440 } else if hours { n / 60 } else { n }).to_string())])
  }
  let presets = [60, 1440, 2160, 10080, 43200]
  let values = presets.filter(fn(n) { n <= max_minutes && n != minutes && (presets.contains(minutes) || n != 2160) })
  values.push(minutes)
  values.sort()
  let options = [("once", tr("android-settings.vault.scope.once"))]
  for n in values {
    options.push((n.to_string(), duration_words(n)))
  }
  options.push(("custom", tr("android-settings.vault.timeout.custom")))
  // (what is typed in minutes, as the unit it is in says: none where it is longer than five figures)
  let typed_minutes = fn(words : String, u : String) {
    if words.length() > 5 { 0 } else { int_of(words, 0) * (if u == "hours" { 60 } else { 1 }) }
  }
  @sf.panel_nodes(
    tr("android-settings.vault.timeout.title"),
    from=Unanchored,
    form=true,
    fn(v, _) {
      v.box(fn(b) {
        @sf.style_node(b, fn() { @sf.panel_words_in_node(b).then(vault_timeout_panel) })
        @sf.field_node(b, fn() { tr("android-settings.vault.timeout.duration") }, fn(f) {
          @sf.select_node(f, fn() { duration.get() }, fn() { options }, fn(x) { duration.set(x) }, label=fn() {
            tr("android-settings.vault.timeout.duration")
          })
        })
        b.show(fn() { duration.get() == "custom" }, fn(s) {
          @sf.field_node(
            s,
            fn() { tr("android-settings.vault.timeout.custom") },
            fn(f) {
              @sf.input_node(f, field, label=tr("android-settings.vault.timeout.custom"), solid=true, edited=fn(w) {
                typed.set(w)
              })
              |> ignore
            },
            aside=fn(a) {
              @sf.chooser_node(
                a,
                fn() { tr("android-settings.vault.timeout." + unit.get()) },
                fn() { ["hours", "minutes"].map(fn(u) { (u, tr("android-settings.vault.timeout." + u)) }) },
                fn() { unit.get() },
                fn(u) {
                  let was = unit.untracked()
                  if u != was {
                    let current = typed_minutes(field.text(), was)
                    field.set(if u == "hours" && current % 60 != 0 { "" } else { (if u == "hours" { current / 60 } else { current }).to_string() })
                    typed.set(field.text())
                    unit.set(u)
                  }
                },
              )
              |> ignore
            },
          )
        })
        b.show(fn() { duration.get() != "once" }, fn(s) {
          @sf.field_node(s, fn() { tr("android-settings.vault.timeout.method") }, fn(f) {
            let method_row = fn(k : String) {
              @sf.choice_row_node(
                f,
                fn() { tr("android-settings.vault.timeout." + k) },
                fn() { chosen.get() == k },
                note=fn() { tr("android-settings.vault.timeout.detail." + k) },
                press=fn() { chosen.set(k) },
              )
            }
            method_row("idle")
            method_row("fixed")
          })
        })
      })
      |> ignore
    },
    foot=fn(v, close) {
      let n = fn() { if duration.get() == "custom" { typed_minutes(typed.get(), unit.get()) } else { int_of(duration.get(), 0) } }
      let once = fn() { duration.get() == "once" }
      @sf.button_node(
        v,
        fn() { tr("android-settings.vault.timeout.done") },
        fn() {
          let o = once()
          vault_picked[request] = if o { "once" } else { chosen.untracked() }
          if !o {
            vault_timeout_minutes[request] = @signals.untracked(n)
          }
          close()
        },
        tone=Primary,
        disabled=fn() { !once() && (n() < 1 || n() > max_minutes) },
      )
      |> ignore
    },
  )
}

///|
/// A candidate personal secret item returned by `vault.browseCandidates`.
priv struct BrowseCandidateItem {
  vault : String
  item : String
  name : String
  about : String
  how_text : String
}

///|
/// A candidate source workspace returned by `vault.browseCandidates`.
priv struct BrowseCandidateWorkspace {
  id : String
  name : String
  items : Array[BrowseCandidateItem]
}

///|
// kept across runs: immutable styles for the cross-workspace personal secret browse picker panel
let vault_browse_panel : @ui.Style = @ui.css("w=Full gap=S3")

///|
// kept across runs: an immutable style
let vault_browse_group : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: an immutable style
let vault_browse_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter min_h=S11")

///|
// kept across runs: an immutable style
let vault_browse_ws_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, weight=Medium, color=Fg, w=@sf.grow)

///|
// kept across runs: an immutable style
let vault_browse_ws_count : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: an immutable style
let vault_browse_items : @ui.Style = @ui.css("w=Full pl=S6 gap=S0_5")

///|
/// Read local eligible personal secrets from other workspaces (`vault.browseCandidates`) and open the picker panel
/// whole once answered, dropping the open if another overlay or a newer request superseded this press.
fn vault_browse_picker_open(core : Core, ws : String, request : String) -> Unit {
  if core.read_only != "" {
    (core.say)(core.read_only)
    return
  }
  vault_browse_seq.val += 1
  let seq = vault_browse_seq.val
  let shown = @sf.last_presented()
  (core.call)("vault.browseCandidates", obj([("workspace", str(ws))]), fn(res) {
    if vault_browse_seq.val != seq || @sf.last_presented() != shown {
      return
    }
    match res {
      Err(e) =>
        (core.say)(fill("android-misc.act.failed", [("what", tr("android-settings.vault.browse.title")), ("error", error_text(e))]))
      Ok(v) => vault_browse_picker_show(request, v)
    }
  })
}

///|
/// Open the cross-workspace personal secret picker panel for `request` with the candidate payload `v` returned by
/// `vault.browseCandidates`: supports workspace-level select/deselect and expanding each workspace to pick individual
/// secrets. Confirming stores the selection in `vault_browse_picked[request]` and closes the panel.
fn vault_browse_picker_show(request : String, v : Json) -> Unit {
  let workspaces : Array[BrowseCandidateWorkspace] = items(Some(v), "workspaces").map(fn(w) {
    let ws = Some(w)
    let ws_items : Array[BrowseCandidateItem] = items(ws, "items").map(fn(it) {
      let s = Some(it)
      {
        vault: text(s, "vault"),
        item: text(s, "item"),
        name: text(s, "name"),
        about: text(s, "about"),
        how_text: text(s, "howText"),
      }
    })
    { id: text(ws, "id"), name: text(ws, "name"), items: ws_items }
  })
  let unkeyed = count(Some(v), "unkeyedWorkspaces")
  let item_key = fn(ws_id : String, it : BrowseCandidateItem) { ws_id + "/" + it.vault + "/" + it.item }
  let picked : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  let existing = @signals.untracked(fn() { vault_browse_picked.get(request) })
  match existing {
    Some(prev) => {
      let kept : Map[String, Bool] = Map([])
      for p in prev.items {
        kept[p.workspace + "/" + p.vault + "/" + p.item] = true
      }
      for w in workspaces {
        for it in w.items {
          let k = item_key(w.id, it)
          picked[k] = kept.get(k).unwrap_or(false)
        }
      }
    }
    None =>
      for w in workspaces {
        for it in w.items {
          picked[item_key(w.id, it)] = true
        }
      }
  }
  let expanded : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()
  for w in workspaces {
    let mut n = 0
    for it in w.items {
      if picked.get(item_key(w.id, it)).unwrap_or(false) {
        n += 1
      }
    }
    // Auto-expand partially selected workspaces so the person immediately sees which items are excluded.
    if n > 0 && n < w.items.length() {
      expanded[w.id] = true
    }
  }
  let picked_total = fn() {
    let mut n = 0
    for w in workspaces {
      for it in w.items {
        if picked.get(item_key(w.id, it)).unwrap_or(false) {
          n += 1
        }
      }
    }
    n
  }
  @sf.panel_nodes(
    tr("android-settings.vault.browse.title"),
    from=Unanchored,
    form=true,
    fn(p, _) {
      p.box(fn(b) {
        @sf.style_node(b, fn() { @sf.panel_words_in_node(b).then(vault_browse_panel) })
        @sf.words_node(b, fn() { tr("android-settings.vault.browse.lead") }, fn() { @sf.ask_note }) |> ignore
        for w in workspaces {
          let ws_id = w.id
          let ws_name = w.name
          let ws_items = w.items
          let ws_total = ws_items.length()
          let ws_selected = fn() {
            let mut n = 0
            for it in ws_items {
              if picked.get(item_key(ws_id, it)).unwrap_or(false) {
                n += 1
              }
            }
            n
          }
          let all_on = fn() { ws_total > 0 && ws_selected() == ws_total }
          let is_open = fn() { expanded.get(ws_id).unwrap_or(false) }
          let toggle_open = fn() { expanded[ws_id] = !@signals.untracked(is_open) }
          b.box(fn(g) {
            @sf.style_node(g, fn() { vault_browse_group })
            g.box(fn(head) {
              @sf.style_node(head, fn() { vault_browse_head }, in_row=true)
              @sf.check_node(
                head,
                all_on,
                fn(on) {
                  for it in ws_items {
                    picked[item_key(ws_id, it)] = on
                  }
                },
                fn() { fill("android-settings.vault.browse.selectWorkspace", [("name", ws_name)]) },
              )
              @sf.words_node(head, fn() { ws_name }, fn() { vault_browse_ws_name }).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(head, fn() { ws_selected().to_string() + "/" + ws_total.to_string() }, fn() { vault_browse_ws_count }) |> ignore
              @sf.disclosure_key_node(
                head,
                fn() {
                  fill(
                    if is_open() { "android-settings.vault.browse.collapse" } else { "android-settings.vault.browse.expand" },
                    [("name", ws_name)],
                  )
                },
                is_open,
                toggle_open,
                side=18.0,
                icon_size=14.0,
              )
            })
            |> ignore
            g.show(is_open, fn(list) {
              @sf.style_node(list, fn() { vault_browse_items })
              list.each(
                fn() { ws_items.mapi(fn(i, _) { i }) },
                fn(i) { i },
                fn(row, idx) {
                  let it = ws_items[idx.untracked()]
                  let k = item_key(ws_id, it)
                  let note = if it.how_text != "" && it.about != "" {
                    it.how_text + " — " + it.about
                  } else if it.how_text != "" {
                    it.how_text
                  } else {
                    it.about
                  }
                  @sf.check_row_node(
                    row,
                    fn() { it.name },
                    fn() { picked.get(k).unwrap_or(false) },
                    fn(on) { picked[k] = on },
                    note=fn() { note },
                  )
                },
              )
            })
          })
          |> ignore
        }
        if unkeyed > 0 {
          @sf.words_node(
            b,
            fn() {
              if unkeyed == 1 {
                tr("android-settings.vault.browse.unkeyedOne")
              } else {
                fill("android-settings.vault.browse.unkeyed", [("n", unkeyed.to_string())])
              }
            },
            fn() { @sf.ask_note },
          )
          |> ignore
        }
      })
      |> ignore
    },
    foot=fn(f, close) {
      @sf.button_node(
        f,
        fn() { tr("android-settings.vault.browse.confirm") },
        fn() {
          let chosen : Array[BrowsePickedItem] = []
          let mut ws_count = 0
          for w in workspaces {
            let mut any_in_ws = false
            for it in w.items {
              if @signals.untracked(fn() { picked.get(item_key(w.id, it)).unwrap_or(false) }) {
                any_in_ws = true
                chosen.push({ workspace: w.id, vault: it.vault, item: it.item, name: it.name })
              }
            }
            if any_in_ws {
              ws_count += 1
            }
          }
          vault_browse_picked[request] = { workspaces: ws_count, items: chosen }
          close()
        },
        tone=Primary,
        disabled=fn() { picked_total() == 0 },
      )
      |> ignore
      @sf.button_node(f, fn() { tr("common.cancel") }, close, tone=Ghost) |> ignore
    },
  )
}

///|
/// How it ended, its words inline (past the message's picture) or at the row's start: the library's, by the names the
/// phone's card's line calls.
// kept across runs: a value (no field of it changes)
let ask_ended_past : @ui.Style = @sf.ask_ended_past

///|
// kept across runs: a value (no field of it changes)
let ask_ended_at : @ui.Style = @sf.ask_ended_at
