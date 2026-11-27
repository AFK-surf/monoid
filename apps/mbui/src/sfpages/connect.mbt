// A connect's page, one in every frame, laid out by its width (web/src/pages/Connect.tsx ConnectPage, ConnectDetail, SlackSection,
// ConnectTrouble, TokenDialog, ModeChoices, RunSection, ModeDialog, ChooseSessionDialog, ConnectSessions,
// OwnerDialog; Connect.css.ts; FeishuConnect.tsx FeishuSection, SecretDialog; FeishuConnect.css.ts): back to the
// connects; who it is and whether it is up (its picture, its name, how it is, where it is reached, its station, who
// owns it; what is done to it less often in its ⋯); what its link needs (Slack's tokens, or why it fails); how it runs
// (its model, how its conversations become sessions and the one they go into); a Feishu connect's app; its latest
// sessions. Everything said is the core's (its `connect` view, the core's ModeWords and ModeChange). Made once as nodes
// of the window's tree in every frame (page_node); what has no node part yet (the tokens' fields, the model's picker,
// the Slack app's form: shared with the old views of the new connect's dialog and a new chat) hosted as its old view.

///|
/// A connect's page (ConnectPage, ConnectScreen) made once as nodes in node `v` (page_node, laid out by the `width`
/// its frame gives it, narrow where none is given), by its station and id, as the core's `connect` view says it now: a
/// wait until it is read (its station's overview), in its bones; what could not be read; one gone, that
/// it is not there; else its page. `here`: who and where, as that changes; `stint`: its time on top (the pictures
/// asked for on it); `tips`: the window's, else its own over it.
pub fn connect_node(
  v : @view.View,
  src : Source,
  core : Core,
  here : () -> Here,
  station : String,
  id : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  stint~ : () -> Int,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
) -> Unit {
  // (what is said of what the pointer rests on: the frame's, over the window; else drawn over the page in the page's own
  // node, each tip its holder over all of it there: history_node's)
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  let page_w = match width {
    Some(w) => w
    None => fn() { v.window_w() }
  }
  // (that connect alone, whole: its page's own ask; none while its station's overview is read, null where it is gone)
  let read = fn() { @settings.connect_read(core, here(), station, id) }
  let found = fn() {
    match read().value {
      Some(Object(_)) as c => c
      _ => None
    }
  }
  let error = fn() {
    match read().error {
      Some(e) => error_text(e)
      None => ""
    }
  }
  let back = fn() { @sf.t("web-pages.settings.nav.connects") }
  // (what it is now: read the first time, or what could not be; gone; found)
  let state = fn() {
    match read().value {
      None => if error() != "" { CdFailed } else { CdReading }
      Some(Object(_)) => CdFound
      Some(_) => CdGone
    }
  }
  v.pick(state, fn(p, st) {
    match st {
      CdFailed =>
        @sf.page_node(p, back, fn() { ["error"] }, fn(b, _) { @sf.page_note_node(b, error, bad=fn() { true }) }, on_back~, frame~, said?, width?, tips~)
      CdGone =>
        @sf.page_node(p, back, fn() { ["gone"] }, fn(b, _) {
          @sf.page_note_node(b, fn() { @sf.t("web-pages.connect.notFound", args=[("id", id)]) })
        }, on_back~, frame~, said?, width?, tips~)
      // (read the first time: a connect's page of made-up words, in its bones, through a core that answers nothing)
      CdReading => {
        let sample = Some(cd_sample())
        let quiet = core.quiet()
        let note = fn() -> @sf.WaitNote { { reading: true, text: @sf.t("web-pages.connect.loading"), failing: [] } }
        @sf.page_node(
          p,
          back,
          fn() { ["sample"] },
          fn(b, _) {
            @sf.waiting_node(b, fn(s) { cd_blocks(s, @sfbase.sample_source, quiet, here, fn() { sample }, tips, page_w) }, note~)
          },
          on_back~,
          frame~,
          said?,
          width?,
          tips~,
          head=fn(h) {
            @sf.waiting_node(h, fn(s) { cd_identity_node(s, quiet, here, "sample", fn() { sample }, tips, stint) }, note=fn() {
              { reading: true, text: "", failing: [] }
            })
          },
        )
      }
      CdFound => {
        // (while it is found: gone, the page is CdGone's and this one let go with its pick)
        let item = found
        let cv = fn() { field(item(), "connect") }
        // (named by what it is of where a frame's bar names it, 连接: its head of its own says its name)
        @sf.page_node(
          p,
          fn() { @sf.t("android-misc.bar.place.connects") },
          fn() { cd_keys(cv()) },
          fn(b, key) { cd_block(b, src, core, here, station, item, key, tips, page_w) },
          on_back~,
          frame~,
          said?,
          width?,
          tips~,
          actions=fn(a) { cd_menu_node(a, core, here, station, cv) },
          head=fn(h) { cd_identity_node(h, core, here, station, item, tips, stint) },
        )
      }
    }
  })
}

///|
/// What a connect's page is now (connect_node's).
#derive(Eq)
priv enum CdState {
  CdFailed
  CdReading
  CdGone
  CdFound
}

///|
/// A connect made up, for its page while the connects are read (in its bones).
fn cd_sample() -> Json {
  {
    "station": "sample",
    "stationName": Json::string(@sf.sample_words(4)),
    "connect": { "id": "sample", "name": Json::string(@sf.sample_words(8)), "kind": "slack", "connection": { "state": "connected" } },
  }
}

///|
/// The blocks of a connect's page (ConnectDetail), the same parts in the same order on every screen, by what they are:
/// what its link needs first where it does (Slack's tokens, or why it fails); how it runs; its app (a Feishu one's ID
/// and secret, a Slack one's look and permissions, folded); its latest sessions.
fn cd_keys(cv : Json?) -> Array[String] {
  let feishu = text(cv, "kind") == "feishu"
  // (a Comma connect has no app of its own: its line is all it connects with)
  let comma = text(cv, "kind") == "comma"
  // (a group connect's server and who it is there, in place of an app)
  let group = text(cv, "kind") == "group"
  let out : Array[String] = []
  if !feishu && !comma && !group && text(field(cv, "connection"), "state") == "no_tokens" {
    out.push("tokens")
  } else if cd_trouble(cv) != "" {
    out.push("trouble")
  }
  out.push("run")
  if feishu {
    if field(cv, "feishu") is Some(Object(_)) {
      out.push("feishu")
    }
  } else if group {
    if field(cv, "group") is Some(Object(_)) {
      out.push("group")
    }
  } else if !comma {
    out.push("app")
  }
  out.push("sessions")
  out
}

///|
/// A connect's page's blocks all at once (what is shown in their bones while it is read), its page `page_w` wide.
fn cd_blocks(
  v : @view.View,
  src : Source,
  core : Core,
  here : () -> Here,
  item : () -> Json?,
  tips : @sf.TipLayer,
  page_w : () -> Double,
) -> Unit {
  for key in cd_keys(field(@signals.untracked(item), "connect")) {
    cd_block(v, src, core, here, text(@signals.untracked(item), "station"), item, key, tips, page_w)
  }
}

///|
/// The block `key` of the page of `item` (as it is now) in `b`.
fn cd_block(
  b : @view.View,
  src : Source,
  core : Core,
  here : () -> Here,
  station : String,
  item : () -> Json?,
  key : String,
  tips : @sf.TipLayer,
  page_w : () -> Double,
) -> Unit {
  let cv = fn() { field(item(), "connect") }
  let id = @signals.untracked(fn() { text(cv(), "id") })
  match key {
    "tokens" => cd_slack_node(b, core, station, id, cv)
    "trouble" =>
      b.box(fn(k) {
        @sf.style_node(k, fn() { cd_amber })
        k.ground(By(fn() { @sf.theme().p.amber_bg })) |> ignore
        @sf.words_node(k, fn() { cd_trouble(cv()) }, fn() { cd_words }) |> ignore
      })
      |> ignore
    "run" => cd_run_node(b, src, core, here, station, item)
    "feishu" => cd_feishu_node(b, core, station, cv)
    "group" => cd_group_node(b, core, station, cv)
    "app" => slack_app_node(b, core, station, id, page_w, tips)
    _ => cd_sessions_node(b, core, station, item, tips)
  }
}

///|
/// Who it is and whether it is up (its head, `item` as it is now): its picture, its name, where people reach it and
/// its station; how it is (being reconnected, switched or saved: a ring and so; failed a moment ago: a red mark and so;
/// else its dot and state) and who owns it; its ⋯ at the end.
fn cd_identity_node(
  h : @view.View,
  core : Core,
  here : () -> Here,
  station : String,
  item : () -> Json?,
  tips : @sf.TipLayer,
  stint : () -> Int,
) -> Unit {
  let cv = fn() { field(item(), "connect") }
  let on = fn() { [("station", station), ("id", text(cv(), "id"))] }
  let doing = fn() {
    let saving = is_doing(core, ["connect.put"], on())
    if is_doing(core, ["connect.reconnect"], on()) {
      @sf.t("common.reconnecting")
    } else if saving && cd_switching.get(station + "/" + text(cv(), "id")).unwrap_or(false) {
      @sf.t(if flag(cv(), "enabled") { "web-pages.connect.disabling" } else { "web-pages.connect.enabling" })
    } else if saving {
      @sf.t("common.saving")
    } else {
      ""
    }
  }
  let failing = fn() {
    match failed_of(core, ["connect.reconnect"], on()) {
      Some(_) => @sf.t("web-pages.connect.reconnectFailedShort")
      None =>
        match failed_of(core, ["connect.put"], on()) {
          Some(_) => @sf.t("web-pages.connect.saveFailedShort")
          None => ""
        }
    }
  }
  @sf.own_head_node(
    h,
    fn(m, side) { cd_avatar_node(m, core, cv, side, stint) },
    fn() { text(cv(), "name") },
    lines=fn() { [join([text(cv(), "placeText"), text(item(), "stationName")], " · ")] },
    state=fn(st) {
      @sf.head_state_node(st, doing, failing, fn() { text(cv(), "presence") }, fn() { text(cv(), "statusText") }, fn(p) {
        doing_mark_node(p, fn() { false }, fn() { Some(failing()) }, tips~)
      })
      @sf.words_node(st, fn() { @sf.t("web-pages.connect.owner") }, fn() { @sf.head_state_words }) |> ignore
      cn_owner_node(st, core, fn() { field(cv(), "createdBy") }, tips, stint)
    },
    actions=fn(a) { cd_menu_node(a, core, here, station, cv) },
  )
}

///|
/// Whether the connect's last write was its turning on or off (said as such meanwhile), by station/id.
// kept across runs: said by the menu's 停用 and 启用; connect_reset empties it
let cd_switching : Map[String, Bool] = Map([])

///|
/// What is done to it less often (Menu), its ⋯ in `a`: pressed, its menu by it at its end, as the connect is then:
/// reconnecting it, its token (a Feishu one's secret) replaced, Slack (or its console) opened; it turned off or on,
/// handed to another; deleted, asked first.
fn cd_menu_node(a : @view.View, core : Core, here : () -> Here, station : String, cv : () -> Json?) -> Unit {
  @sf.icon_action_opens_node(a, "more", fn() { @sf.t("common.more") }, fn(m) {
    @sf.menu(cd_menu_items(core, @signals.untracked(here), station, @signals.untracked(cv)), from=Node(m), along=End)
  })
  |> ignore
}

///|
/// The connect's menu's items, as it is now (cd_menu_node's).
fn cd_menu_items(core : Core, here : Here, station : String, cv : Json?) -> Array[@sf.MenuItem?] {
  let id = text(cv, "id")
  let me = station + "/" + id
  let on = [("station", station), ("id", id)]
  let feishu = text(cv, "kind") == "feishu"
  let comma = text(cv, "kind") == "comma"
  let group = text(cv, "kind") == "group"
  let reconnecting = is_doing(core, ["connect.reconnect"], on)
  let saving = is_doing(core, ["connect.put"], on)
  let conn = field(cv, "connection")
  let up = text(conn, "state") == "connected" || text(conn, "state") == "reconnecting"
  let slack_url = if up { text(field(conn, "workspace"), "url") } else { "" }
  let console = text(field(cv, "feishu"), "console")
  let delete = fn() {
    let sessions = text_number(cv, "sessions")
    confirm(
      @sf.t("web-pages.connect.deleteConfirm"),
      if sessions > 0 {
        @sf.t(cd_kind_key("web-pages.connect.deleteBodySessions", cv), args=[("n", sessions.to_string())])
      } else {
        @sf.t(cd_kind_key("web-pages.connect.deleteBody", cv))
      },
      @sf.t("web-pages.connect.delete"),
      danger=true,
      facts=[(@sf.t("common.confirmFact.connect"), text(cv, "name"))],
      // back to the list at once: its row turns there until the station has dropped it
      fn() {
        (core.pop)()
        cd_act(core, station, id, @sf.t("web-pages.connect.delete"), "connect.delete", [], done=@sf.t("web-pages.connect.deleted"))
      },
    )
  }
  let items : Array[@sf.MenuItem?] = [
    Some(
      @sf.menu_item_of(@sf.t("web-pages.connect.reconnect"), icon="refresh", disabled=reconnecting, fn() {
        cd_act(core, station, id, @sf.t("web-pages.connect.reconnect"), "connect.reconnect", [], done=@sf.t("web-pages.connect.reconnected"))
      }),
    ),
  ]
  // (a Comma connect's line is made again in Comma: there is no token of its own to replace here)
  if group {
    items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.group.rebind"), icon="key", fn() { cd_rebind_dialog(core, station, cv) })))
  } else if !comma {
    items.push(Some(
      @sf.menu_item_of(@sf.t(if feishu { "web-pages.connect.feishu.replace" } else { "web-pages.connect.replaceToken" }), icon="key", fn() {
        if feishu {
          cd_secret_dialog(core, station, cv)
        } else {
          cd_token_dialog(core, station, cv)
        }
      }),
    ))
  }
  if !feishu && !comma && !group && slack_url != "" {
    items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.openSlack"), icon="external", fn() { (core.open_link)(slack_url) })))
  }
  if feishu && console != "" {
    items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.feishu.openConsole"), icon="external", fn() { (core.open_link)(console) })))
  }
  items.push(None)
  items.push(
    Some(
      if flag(cv, "enabled") {
        @sf.menu_item_of(@sf.t("web-pages.profiles.disable"), icon="power", disabled=saving, fn() {
          cd_switching[me] = true
          cd_put(core, station, id, obj([("enabled", Json::boolean(false))]), done=@sf.t(cd_kind_key("web-pages.connect.disabled", cv)))
        })
      } else {
        @sf.menu_item_of(@sf.t("web-pages.connect.enable"), icon="power", disabled=saving, fn() {
          cd_switching[me] = true
          cd_put(core, station, id, obj([("enabled", Json::boolean(true))]), done=@sf.t("web-pages.connect.enabled"))
        })
      },
    ),
  )
  items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.changeOwner"), icon="user", fn() { cd_owner_dialog(core, here, station, cv) })))
  // (to another station of its workspace, which runs it from then on; a station from before cannot)
  if flag(cv, "moves") {
    items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.move"), icon="arrow-right", fn() { cd_station_dialog(core, here, station, cv, true) })))
  }
  items.push(None)
  items.push(Some(@sf.menu_item_of(@sf.t("web-pages.connect.delete"), icon="trash", danger=true, delete)))
  items
}

///|
/// How it runs, in one card (RunSection: runCard), `item` as it is now: the model it runs and who runs it (the core's
/// pick of `connect:<id>`, its picker an old view's, hosted; none on its runtime: to its profiles), how its
/// conversations become sessions (更改; none for a Comma connect), in single-session the one they go into (切换;
/// being switched, a ring beside it); under them what a change reaches.
fn cd_run_node(b : @view.View, src : Source, core : Core, here : () -> Here, station : String, item : () -> Json?) -> Unit {
  let cv = fn() { field(item(), "connect") }
  let id = @signals.untracked(fn() { text(cv(), "id") })
  let changes = fn() { flag(item(), "runtimeChanges") }
  // whether its station runs a model on its runtime (on any, where its runtime may change): the runtimes its page says
  // it runs, each with its models (the core's `station`)
  let runs_none = fn() {
    let runtime = text(field(cv(), "bind"), "runtime")
    !items(@settings.station_of(core, here(), station), "runtimes")
    .iter()
    .any(fn(r) { (changes() || text(Some(r), "runtime") == runtime) && strings(Some(r), "models").length() > 0 })
  }
  let bind_on = [("station", station), ("connect", id)]
  let binding = fn() { is_doing(core, ["connect.bindSession"], bind_on) }
  @sf.section_node(b, fn() { @sf.t("web-pages.connect.run") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      // its model: picked here, or none its station runs for its runtime (to the station's profiles)
      g.pick(runs_none, fn(p, none) {
        if none {
          @sf.link_row_node(p, fn() { @sf.t("web-pages.profiles.models") }, fn() { (core.push)(Profiles(station)) }, note=fn() {
            @sf.t("web-pages.connect.noModelsFor", args=[("runtime", text(cv(), "runtimeText"))])
          })
        } else {
          // (its title, and at its end, in the room the title leaves, its model's control: said_row's `value`)
          @sf.said_row_node(p, fn() { @sf.t("web-pages.profiles.models") }, fn(e) {
            model_triple_node(e, src, station, "connect:" + id, saved=@sf.t("web-pages.connect.bindSaved"))
          })
        }
      })
      // how its conversations become sessions, switched in a dialog (a Comma connect's are one a Task, nothing to
      // switch: the station makes it so)
      g.show(fn() { text(cv(), "kind") != "comma" }, fn(m) {
        @sf.link_row_node(m, fn() { @sf.t("web-pages.connect.session") }, fn() { cd_mode_dialog(core, station, @signals.untracked(item)) }, value=fn() {
          text(cv(), "modeLabel")
        }, note=fn() { text(cv(), "modeSentence") })
      })
      // a Feishu connect's direct chats in threads or not, switched where it stands (its groups' way is the mode's): only
      // where its station says the switch (`feishu.directThreads`, false too), as one from before would take it and do
      // nothing
      g.show(fn() { field(field(cv(), "feishu"), "directThreads") is Some(True | False) }, fn(d) {
        @sf.switch_row_node(
          d,
          fn() { @sf.t("web-pages.connect.feishu.directThreads") },
          fn() { flag(field(cv(), "feishu"), "directThreads") },
          fn(on) {
            cd_put(
              core,
              station,
              id,
              obj([("feishu", obj([("directThreads", Json::boolean(on))]))]),
              done=@sf.t(if on { "web-pages.connect.feishu.directThreadsOn" } else { "web-pages.connect.feishu.directThreadsOff" }),
            )
          },
          note=fn() { @sf.t("web-pages.connect.feishu.directThreadsNote") },
          busy=fn() { is_doing(core, ["connect.put"], [("station", station), ("id", id)]) },
        )
      })
      // the station(s) its new conversations run on (workspace allowlist auto-assign or explicit manual allowlist),
      // editable by workspace owners/admins only; non-admins see a read-only row.
      g.show(fn() { text(cv(), "mode") != "single-session" && flag(cv(), "moves") && text(cv(), "kind") != "comma" && text(cv(), "kind") != "group" }, fn(s) {
        s.pick(fn() { @settings.manages(core, here()) == Some(true) }, fn(p, can_edit) {
          if can_edit {
            @sf.link_row_node(
              p,
              fn() { @sf.t("web-pages.connect.startsOn") },
              fn() { cd_station_dialog(core, @signals.untracked(here), station, @signals.untracked(cv), false) },
              // (a line of its own: station names may be long)
              note=fn() { cd_starts_on_label(core, here(), cv(), station) },
            )
          } else {
            @sf.link_row_node(
              p,
              fn() { @sf.t("web-pages.connect.startsOn") },
              fn() {  },
              note=fn() { cd_starts_on_label(core, here(), cv(), station) },
              goes=false,
              chevron=false,
            )
          }
        })
      })
      // the one they all go into: its chat, another chosen
      g.show(fn() { text(cv(), "mode") == "single-session" }, fn(s) {
        // (what its choice lists, held while 更换 can be pressed and let go of as it goes or the page does, so the
        // choice opens on them whole: asked as the dialog opened, its list grew by them a frame or two later)
        src.lease_topic("connectCandidates", @settings.connect_candidates_asked(@signals.untracked(here), station, id)).bind_to(s)
        let bound = fn() { field(item(), "bound") }
        s.pick(fn() { bound() is Some(Object(_)) }, fn(r, has_bound) {
          @sf.link_row_node(
            r,
            fn() { @sf.t("web-pages.connect.current") },
            fn() {
              let bv = @signals.untracked(bound)
              (core.open_chat)(station, text(bv, "key"), text(bv, "titleText"))
            },
            value=fn() { if has_bound { text(bound(), "titleText") } else { @sf.t("web-pages.connect.noSession") } },
            goes=has_bound,
          )
        })
        s.pick(binding, fn(r, busy) {
          @sf.link_row_node(
            r,
            fn() { @sf.t("web-pages.connect.switch") },
            fn() { cd_choose_dialog(core, @signals.untracked(here), station, @signals.untracked(item)) },
            chevron=false,
            goes=!busy,
            tail=fn(e) { doing_mark_node(e, binding, fn() { failed_of(core, ["connect.bindSession"], bind_on) }) },
          )
        })
      })
    })
    @sf.page_note_node(sec, fn() {
      // (what a change does to a single session's current one only where it runs one: a multi-session connect's, a
      // Comma one's among them, say none of it)
      let key = if changes() { "web-pages.connect.runtimeChanges" } else { "web-pages.connect.runtimeNote" }
      @sf.t(if text(cv(), "mode") == "single-session" { key } else { key + ".multi" }, args=[("runtime", text(cv(), "runtimeText"))])
    })
  })
}

///|
/// A Feishu connect's app (FeishuSection: in a run card, its labels 84 wide), `cv` as it is now: its App ID (its
/// console opened beside it), its App Secret masked (replaced beside it), which of Feishu or Lark it is on.
fn cd_feishu_node(b : @view.View, core : Core, station : String, cv : () -> Json?) -> Unit {
  let app = fn() { field(cv(), "feishu") }
  @sf.section_node(b, fn() { @sf.t("web-pages.connect.feishu.section") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.pick(fn() { text(app(), "console") }, fn(r, url) {
        if url != "" {
          @sf.link_row_node(r, fn() { "App ID" }, fn() { (core.open_link)(url) }, note=fn() { text(app(), "appId") }, value=fn() {
            @sf.t("web-pages.connect.feishu.openConsole")
          }, out=true)
        } else {
          @sf.link_row_node(r, fn() { "App ID" }, fn() {  }, goes=false, note=fn() { text(app(), "appId") })
        }
      })
      @sf.link_row_node(
        g,
        fn() { "App Secret" },
        fn() { cd_secret_dialog(core, station, @signals.untracked(cv)) },
        note=fn() { if text(app(), "appSecret") == "" { "••••••••" } else { text(app(), "appSecret") } },
        value=fn() { @sf.t("web-pages.connect.feishu.replace") },
        value_lit=true,
        chevron=false,
      )
      @sf.link_row_node(g, fn() { @sf.t("web-pages.connect.feishu.version") }, fn() {  }, value=fn() {
        if text(app(), "domain") == "lark" { "Lark" } else { @sf.t("web-pages.connect.feishu.name") }
      }, goes=false)
    })
  })
}

///|
/// A group connect's server (as Feishu's app is shown, in a run card): its ID, shortened, and its relays; who it is
/// there (or that it waits to join by its code), with binding it anew by another code beside it.
fn cd_group_node(b : @view.View, core : Core, station : String, cv : () -> Json?) -> Unit {
  let g = fn() { field(cv(), "group") }
  @sf.section_node(b, fn() { @sf.t("web-pages.connect.group.section") }, fn(sec) {
    @sf.group_node(sec, fn(r) {
      @sf.link_row_node(r, fn() { @sf.t("web-pages.connect.group.server") }, fn() {  }, goes=false, note=fn() {
        let id = text(g(), "server")
        if id.length() > 16 { id.clamped_view(start=0, end=8).to_owned() + "…" + id.clamped_view(start=id.length() - 8, end=id.length()).to_owned() } else { id }
      })
      @sf.link_row_node(r, fn() { @sf.t("web-pages.connect.group.relays") }, fn() {  }, goes=false, note=fn() { strings(g(), "relays").join("\n") })
      @sf.link_row_node(
        r,
        fn() { @sf.t("web-pages.connect.group.member") },
        fn() { cd_rebind_dialog(core, station, @signals.untracked(cv)) },
        note=fn() { if flag(g(), "joining") { @sf.t("web-pages.connect.group.joining") } else { text(cv(), "name") } },
        value=fn() { @sf.t("web-pages.connect.group.rebind") },
        value_lit=true,
        chevron=false,
      )
    })
  })
}

///|
/// A group connect bound anew by another join code (its device removed on the server, or to be another member):
/// kept, then it connects again; the dialog stays while it is saved, why it was refused under the field.
fn cd_rebind_dialog(core : Core, station : String, cv : Json?) -> Unit {
  let id = text(cv, "id")
  let code = @ui.Field::new()
  let error : @signals.Signal[String] = @signals.signal("")
  let typed = fn() { code.text().trim(chars=" \t\n").to_owned() }
  open_dialog_nodes(
    @sf.t("web-pages.connect.group.rebind"),
    description=@sf.t("web-pages.connect.group.rebindLead"),
    fn(v, _) {
      @sf.field_node(v, fn() { @sf.t("web-pages.connect.group.code") }, error=fn() { error.get() }, fn(m) {
        @sf.input_node(m, code, placeholder="XXXX-XXXX-XXXX-XXXX", label=@sf.t("web-pages.connect.group.code")) |> ignore
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("web-pages.connect.saveReconnect") },
        fn() {
          error.set("")
          let typed = @signals.untracked(typed)
          (core.call)("connect.put", obj([("station", str(station)), ("id", str(id)), ("input", obj([("group", obj([("code", str(typed))]))]))]), fn(
            r,
          ) {
            match r {
              Ok(_) => {
                (core.say)(@sf.t("web-pages.connect.group.rebound"))
                shut()
              }
              Err(e) => error.set(error_text(e))
            }
          })
        },
        tone=Primary,
        busy=fn() { is_doing(core, ["connect.put"], [("station", station), ("id", id)]) },
        disabled=fn() { typed() == "" },
      )
      |> ignore
    },
  )
}

///|
/// Its latest sessions (ConnectSessions), `item` as it is now: each its title, how it is in a pill, when it was last
/// active, opening its chat; five, the rest asked for (all shown as it was left, kept with its connect); none, that
/// none came yet.
fn cd_sessions_node(b : @view.View, core : Core, station : String, item : () -> Json?, tips : @sf.TipLayer) -> Unit {
  ignore(tips)
  let cv = fn() { field(item(), "connect") }
  let me = station + "/" + @signals.untracked(fn() { text(cv(), "id") })
  let all : @signals.Signal[Bool] = @signals.signal(cd_all_sessions.get(me).unwrap_or(false), same=fn(a, b) { a == b })
  let sessions = fn() { items(item(), "sessions") }
  @sf.section_node(b, fn() { @sf.t("web-pages.connect.recent") }, fn(sec) {
    @sf.group_node(sec, fn(g) {
      g.show(fn() { sessions().length() == 0 }, fn(r) {
        @sf.link_row_node(r, fn() { @sf.t(cd_kind_key("web-pages.connect.recentNone", cv()), args=[("name", text(cv(), "name"))]) }, fn() {  }, goes=false)
      })
      g.each(
        fn() {
          let s = sessions()
          if all.get() || s.length() <= cd_sessions_shown { s } else { s[:cd_sessions_shown].to_owned() }
        },
        fn(s) { text(Some(s), "key") },
        fn(r, s) { cd_session_row_node(r, core, station, fn() { Some(s.get()) }) },
      )
      g.show(fn() { sessions().length() > cd_sessions_shown }, fn(r) {
        @sf.link_row_node(
          r,
          fn() {
            if all.get() {
              @sf.t("web-pages.profiles.collapse")
            } else {
              @sf.t("web-pages.connect.showAll", args=[("n", sessions().length().to_string())])
            }
          },
          fn() {
            let now = !all.untracked()
            cd_all_sessions[me] = now
            all.set(now)
          },
          chevron=false,
        )
      })
    })
  })
}

///|
/// A session of it (listRow), `s` as it is now: its title, how it is in a pill (StatusText: its check or wait, else
/// its words), when it was last active at its end; pressed, its chat.
fn cd_session_row_node(r : @view.View, core : Core, station : String, s : () -> Json?) -> Unit {
  let tone = fn() -> @sf.PillTone {
    match text(s(), "tone") {
      "green" => Green
      "blue" => Blue
      "amber" => Amber
      "red" => Red
      "accent" => Accented
      _ => Neutral
    }
  }
  @sf.link_row_node(
    r,
    fn() { text(s(), "titleText") },
    fn() {
      let now = @signals.untracked(s)
      (core.open_chat)(station, text(now, "key"), text(now, "titleText"))
    },
    value=fn() { text(field(field(s(), "time"), "lastActiveAt"), "ago") },
    title_cut=true,
    value_cut=true,
    tail=fn(e) {
      // (its check or its wait before its words, and its tone: the pill made again as they change)
      let icon = fn() {
        match text(s(), "statusLead") {
          "done" => "check"
          "wait" => "wait"
          _ => ""
        }
      }
      // (giving way on its row as its title does, each cut short: neither takes the row from the other)
      e.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      e.pick(fn() { (icon(), tone()) }, fn(p, look) {
        p.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.pill_node(
          p,
          fn() {
            match text(s(), "statusLead") {
              "done" | "wait" => text(s(), "statusRest")
              _ => text(s(), "statusText")
            }
          },
          tone=look.1,
          icon=look.0,
        )
        |> ignore
      })
    },
  )
}

///|
/// A connect as its people see it (ui.tsx ConnectAvatar) in its head's tile `m`, `side` across: its bot's picture,
/// filling the tile with the tile's corners (the app's icon it is: a square, as Slack shows it), once it is here; its
/// kind's mark till then, and where it is not said.
fn cd_avatar_node(m : @view.View, core : Core, cv : () -> Json?, side : Double, stint : () -> Int) -> Unit {
  let key = fn() {
    match opt_text(cv(), "botImage") {
      Some(image) => (core.picture)(image, stint())
      None => ""
    }
  }
  @sf.bot_tile_node(m, key, side, fn(t, size) { cn_kind_node(t, fn() { text(cv(), "kind") }, size) }) |> ignore
}

///|
fn connect_reset() -> Unit {
  cd_switching.clear()
  cd_all_sessions.clear()
  slack_reset()
  slack_app_reset()
}

///|
/// The connect's call to the core with its station and id, said done by `done`.
fn cd_act(core : Core, station : String, id : String, what : String, name : String, more : Array[(String, Json)], done? : String = "") -> Unit {
  let p = [("station", str(station)), ("id", str(id))]
  p.append(more)
  @settings.act(core, what, name, obj(p), done~)
}

///|
/// Saved (useSaveConnect: `connect.put` with what changed), said by `done`.
fn cd_put(core : Core, station : String, id : String, input : Json, done? : String = "") -> Unit {
  cd_act(core, station, id, @sf.t("common.save"), "connect.put", [("input", input)], done~)
}

///|
/// Bare station id from either a bare id ("st2") or a `<workspace>/<station_id>` address ("ws1/st2").
fn cd_station_id(s : String) -> String {
  let trimmed = s.trim(chars=" \t\n").to_owned()
  match trimmed.rev_find("/") {
    Some(i) => trimmed.clamped_view(start=i + 1, end=trimmed.length()).to_owned()
    None => trimmed
  }
}

///|
/// A station of the workspace by its name (its id till its view is read), matching either bare id or `<ws>/<id>`.
fn cd_station_name(core : Core, here : Here, id_or_addr : String) -> String {
  let want = cd_station_id(id_or_addr)
  match @settings.stations_of(core, here).value {
    Some(Array(a)) =>
      match a.iter().find_first(fn(s) {
        let by_id = cd_station_id(text(Some(s), "id"))
        let by_addr = cd_station_id(text(Some(s), "station"))
        (by_id != "" && by_id == want) || (by_addr != "" && by_addr == want)
      }) {
        Some(s) if text(Some(s), "name") != "" => text(Some(s), "name")
        _ => id_or_addr
      }
    _ => id_or_addr
  }
}

///|
/// The allowlisted bare station ids a connect starts new conversations on: `startsOnStations` when non-empty, else
/// `startsOn`, else its own `station`.
fn cd_starts_on_stations(cv : Json?, station : String) -> Array[String] {
  let out : Array[String] = []
  for s in strings(cv, "startsOnStations") {
    let id = cd_station_id(s)
    if id != "" && !out.contains(id) {
      out.push(id)
    }
  }
  if out.length() > 0 {
    return out
  }
  let starts = cd_station_id(text(cv, "startsOn"))
  if starts != "" {
    [starts]
  } else {
    [cd_station_id(station)]
  }
}

///|
/// Human-readable summary of a connect's allowlisted start stations (auto allowlist, single name, two joined, or "A、B 等 N 台").
fn cd_starts_on_label(core : Core, here : Here, cv : Json?, station : String) -> String {
  if flag(cv, "startsOnAuto") {
    return @sf.t("web-pages.connect.startsOnAutoShort")
  }
  let ids = cd_starts_on_stations(cv, station)
  let names = ids.map(fn(s) { cd_station_name(core, here, s) })
  if names.length() == 0 {
    cd_station_name(core, here, station)
  } else if names.length() == 1 {
    names[0]
  } else if names.length() == 2 {
    names[0] + @sf.t("web-pages.connect.startsOnSep") + names[1]
  } else {
    @sf.t("web-pages.connect.startsOnMany", args=[("first", names[0]), ("second", names[1]), ("n", names.length().to_string())])
  }
}

///|
/// Whether two station allowlists contain the exact same set of station ids.
fn cd_same_stations(a : Array[String], b : Array[String]) -> Bool {
  a.length() == b.length() && a.iter().all(fn(x) { b.contains(x) })
}

///|
/// A station (or manual allowlist of stations) of its workspace picked for the connect: where its new conversations
/// run (`moving` false: explicit checklist of full stations, never auto-selecting all stations), or where it moves to
/// (`moving` true: single select among other online stations, the connect itself and its tokens going there).
fn cd_station_dialog(core : Core, here : Here, station : String, cv : Json?, moving : Bool) -> Unit {
  let id = text(cv, "id")
  let here_id = cd_station_id(station)
  if moving {
    let choices = fn() -> Array[(String, String)] {
      let all = match @settings.stations_of(core, here).value {
        Some(Array(a)) => a
        _ => []
      }
      let out : Array[(String, String)] = []
      for s in all {
        let sid = cd_station_id(text(Some(s), "station"))
        if sid != "" && sid != here_id && flag(Some(s), "online") && text(Some(s), "mode") != "tasks" {
          out.push((sid, cd_station_name(core, here, sid)))
        }
      }
      out
    }
    let picked : @signals.Signal[String] = @signals.signal(
      match choices().get(0) {
        Some(o) => o.0
        None => ""
      },
    )
    open_dialog_nodes(
      @sf.t("web-pages.connect.move"),
      description=@sf.t("web-pages.connect.moveLead"),
      fn(v, _) {
        v.pick(fn() { choices().length() == 0 }, fn(p, none) {
          if none {
            @sf.words_node(p, fn() { @sf.t("web-pages.connect.moveNone") }, fn() { cn_note }) |> ignore
          } else {
            @sf.field_node(p, fn() { @sf.t("web-pages.connect.station") }, fn(f) {
              @sf.select_node(f, fn() { picked.get() }, choices, fn(s) { picked.set(s) }, label=fn() { @sf.t("web-pages.connect.station") })
            })
          }
        })
      },
      fn(v, shut) {
        @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
        @sf.button_node(
          v,
          fn() { @sf.t("web-pages.connect.moveDo") },
          fn() {
            let to = cd_station_id(picked.get())
            // back to the list: the connect is the other station's from now on
            (core.pop)()
            cd_act(core, station, id, @sf.t("web-pages.connect.move"), "connect.move", [("to", str(to))], done=@sf.t("web-pages.connect.moved"))
            shut()
          },
          tone=Primary,
          disabled=fn() { picked.get() == "" },
        )
        |> ignore
      },
    )
    return
  }
  let initial_auto = flag(cv, "startsOnAuto")
  let initial = cd_starts_on_stations(cv, station)
  let auto_mode : @signals.Signal[Bool] = @signals.signal(initial_auto)
  let picked : @signals.Signal[Array[String]] = @signals.signal(initial)
  let auto_count = fn() -> Int {
    let all = match @settings.stations_of(core, here).value {
      Some(Array(a)) => a
      _ => []
    }
    let mut n = 0
    for s in all {
      if flag(Some(s), "acceptAutoChats") && text(Some(s), "mode") != "tasks" {
        n += 1
      }
    }
    n
  }
  let stations_list = fn() -> Array[(String, String)] {
    let all = match @settings.stations_of(core, here).value {
      Some(Array(a)) => a
      _ => []
    }
    let seen : Array[String] = [here_id]
    let out : Array[(String, String)] = [
      (here_id, @sf.t("web-pages.connect.startsHere", args=[("station", cd_station_name(core, here, here_id))])),
    ]
    for s in all {
      let sid = cd_station_id(text(Some(s), "station"))
      if sid != "" && !seen.contains(sid) && text(Some(s), "mode") != "tasks" {
        seen.push(sid)
        out.push((sid, cd_station_name(core, here, sid)))
      }
    }
    out
  }
  open_dialog_nodes(
    @sf.t("web-pages.connect.startsOn"),
    description=@sf.t("web-pages.connect.startsOnLead"),
    fn(v, _) {
      @sf.group_node(v, fn(g) {
        @sf.switch_row_node(
          g,
          fn() { @sf.t("web-pages.connect.startsOnAuto") },
          fn() { auto_mode.get() },
          fn(on) { auto_mode.set(on) },
          note=fn() {
            let n = auto_count()
            if n > 0 {
              @sf.t("web-pages.connect.startsOnAutoCount", args=[("n", n.to_string())])
            } else {
              @sf.t("web-pages.connect.startsOnAutoEmpty")
            }
          },
        )
      })
      v.show(fn() { !auto_mode.get() }, fn(m) {
        @sf.group_node(m, fn(g) {
          g.each(stations_list, fn(it) { it.0 }, at_once=true, fn(r, item) {
            let pair = item.untracked()
            let addr = pair.0
            let label = pair.1
            let checked = fn() { picked.get().contains(addr) }
            @sf.choice_row_node(
              r,
              fn() { label },
              fn() { false },
              compact=true,
              lead=fn(l) { @sf.check_mark_node(l, checked) },
              press=fn() {
                let cur = @signals.untracked(fn() { picked.get() })
                if cur.contains(addr) {
                  picked.set(cur.filter(fn(x) { x != addr }))
                } else {
                  picked.set([..cur, addr])
                }
              },
            )
          })
        })
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("common.save") },
        fn() {
          if @signals.untracked(fn() { auto_mode.get() }) {
            cd_put(
              core,
              station,
              id,
              obj([("autoStation", Json::boolean(true))]),
              done=@sf.t("web-pages.connect.startsOnAutoSaved"),
            )
          } else {
            let cur = @signals.untracked(fn() { picked.get() })
            cd_put(
              core,
              station,
              id,
              obj([("stations", Json::array(cur.map(str)))]),
              done=@sf.t(if cur.length() > 1 { "web-pages.connect.startsOnPoolSaved" } else { "web-pages.connect.startsOnSaved" }),
            )
          }
          shut()
        },
        tone=Primary,
        disabled=fn() {
          if auto_mode.get() {
            initial_auto
          } else {
            let cur = picked.get()
            cur.length() == 0 || (!initial_auto && cd_same_stations(cur, initial))
          }
        },
      )
      |> ignore
    },
  )
}

///|
/// A count the core gives as a number.
fn text_number(v : Json?, key : String) -> Int {
  match field(v, key) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

///|
/// A key of words that differ for a Feishu or a Comma connect: its `.feishu` or `.comma` twin for one (the web's
/// kindKey).
fn cd_kind_key(key : String, cv : Json?) -> String {
  match text(cv, "kind") {
    "feishu" => key + ".feishu"
    "comma" => key + ".comma"
    "group" => key + ".group"
    _ => key
  }
}

///|
/// Why its link fails, or comes back after it did (ConnectTrouble); "" while up.
fn cd_trouble(cv : Json?) -> String {
  let conn = field(cv, "connection")
  match text(conn, "state") {
    "error" => text(conn, "error")
    "reconnecting" if text(conn, "lastError") != "" =>
      @sf.t("web-pages.connect.retrying", args=[("error", text(conn, "lastError"))])
    _ => ""
  }
}

///|
/// The Slack link needing its tokens (SlackSection), as nodes in `b`: how to make the app, the tokens' fields, 保存并连接
/// checking them first (then they are saved and it connects).
fn cd_slack_node(b : @view.View, core : Core, station : String, id : String, cv : () -> Json?) -> Unit {
  let tk = slack_tokens_draft(core, station, "connect-slack/" + station + "/" + id, id, "", "", fn(_, open) { open() })
  let saving = fn() { is_doing(core, ["connect.put"], [("station", station), ("id", id)]) }
  @sf.section_node(b, fn() { @sf.t("web-pages.connect.slack") }, note=fn() { @sf.t("web-pages.connect.slackLead") }, fn(s) {
    @sf.page_card_node(s, footed=true, fn(k) {
      create_app_steps_node(k, core, station, fn() { text(cv(), "name") })
      token_fields_node(k, core, tk)
      @sf.card_foot_node(k, at_end=true, fn(f) {
        @sf.button_node(
          f,
          fn() { @sf.t("web-pages.connect.saveConnect") },
          fn() {
            tokens_check(core, tk, fn() {
              let input = obj([("slack", tokens_input(tk))])
              tokens_clear(core, tk)
              cd_put(core, station, id, input, done=@sf.t("web-pages.connect.tokenSavedConnecting"))
            })
          },
          tone=Primary,
          busy=fn() { tokens_busy(core, tk) || saving() },
          disabled=fn() { !tokens_ready(core, tk) },
        )
        |> ignore
      })
    })
  })
}

///|
/// Its Slack tokens replaced (TokenDialog: either one, the other kept, what is saved said in each while it is left
/// blank), checked before they are saved; it closes as they go, said done or not by a toast.
fn cd_token_dialog(core : Core, station : String, cv : Json?) -> Unit {
  let id = text(cv, "id")
  let key = "connect-tokens/" + (desk_dialogs.val + 1).to_string()
  let slack = field(cv, "slack")
  let tk = slack_tokens_draft(core, station, key, id, "", "", fn(_, open) { open() })
  open_dialog_nodes(
    @sf.t("web-pages.connect.replaceTitle"),
    description=@sf.t("web-pages.connect.replaceLead"),
    fn(v, _) { token_fields_node(v, core, tk, masked=(text(slack, "appToken"), text(slack, "botToken"))) },
    fn(v, shut) {
      @sf.button_node(
        v,
        fn() { @sf.t("common.cancel") },
        fn() {
          shut()
          tokens_drop(core, key)
        },
        tone=Ghost,
      )
      |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("web-pages.connect.saveReconnect") },
        fn() {
          tokens_check(core, tk, fn() {
            cd_put(core, station, id, obj([("slack", tokens_input(tk))]), done=@sf.t("web-pages.connect.tokenSavedReconnecting"))
            shut()
            tokens_drop(core, key)
          })
        },
        tone=Primary,
        busy=fn() { tokens_busy(core, tk) || is_doing(core, ["connect.put"], [("station", station), ("id", id)]) },
        disabled=fn() { !tokens_ready(core, tk) },
      )
      |> ignore
    },
    on_gone=fn() { tokens_drop(core, key) },
  )
}

///|
/// How its conversations become sessions, to choose from (ModeChoices; the core's ModeWords, as its kind says them,
/// `words` as they are now) in `parent`: one each (a Feishu connect's by its group or its thread) or all in one, the
/// latter with whether it waits for an @. `now`: the mode, the @, thread mode chosen now; `set` told those a choice
/// makes them.
fn mode_choices_node(
  parent : @view.View,
  words : () -> Json?,
  now : () -> (String, Bool, Bool),
  set : ((String, Bool, Bool)) -> Unit,
) -> Unit {
  let ways = fn() {
    let w = words()
    let multi = field(w, "multi")
    let by_thread = field(w, "threads")
    let single = field(w, "single")
    let out = [("multi-session", text(multi, "label"), text(multi, "description"))]
    if text(by_thread, "label") != "" {
      out.push(("threads", text(by_thread, "label"), text(by_thread, "description")))
    }
    out.push(("single-session", text(single, "label"), text(single, "description")))
    out
  }
  @sf.choices_node(
    parent,
    fn() {
      let (mode, _, threads) = now()
      if threads {
        "threads"
      } else {
        mode
      }
    },
    ways,
    fn(picked) {
      let (_, mention, _) = @signals.untracked(now)
      // (one each always waits for an @)
      set(
        match picked {
          "threads" => ("multi-session", true, true)
          "multi-session" => ("multi-session", true, false)
          _ => (picked, mention, false)
        },
      )
    },
    label=fn() { @sf.t("web-pages.connect.mode") },
    extra=fn(v) {
      guard v == "single-session" else { None }
      Some(fn(x) {
        @sf.switch_row_node(
          x,
          fn() { @sf.t("web-pages.connect.mentionOnly") },
          fn() { now().1 },
          fn(waits) {
            let (mode, _, _) = @signals.untracked(now)
            set((mode, waits, false))
          },
          note=fn() { text(words(), if now().1 { "mentionOn" } else { "mentionOff" }) },
          in_words=true,
        )
      })
    },
  )
}

///|
/// How its conversations become sessions, switched (ModeDialog): the ways to choose from, what switching does said
/// under them (the core's ModeChange), its button the core's words; it closes as it goes, said by a toast.
pub fn cd_mode_dialog(core : Core, station : String, item : Json?) -> Unit {
  let cv = field(item, "connect")
  let id = text(cv, "id")
  let next : @signals.Signal[(String, Bool, Bool)] = @signals.signal(
    (text(cv, "mode"), flag(cv, "requireMention"), flag(field(cv, "feishu"), "threads")),
  )
  let change = fn() -> Json? {
    let (mode, mention, threads) = next.get()
    items(item, "changes")
    .iter()
    .find_first(fn(ch) {
      text(Some(ch), "mode") == mode && flag(Some(ch), "threads") == threads && (mode == "multi-session" || flag(Some(ch), "requireMention") == mention)
    })
  }
  let effects = fn() { strings(change(), "effects") }
  open_dialog_nodes(
    @sf.t("web-pages.connect.modeTitle"),
    description=@sf.t("web-pages.connect.modeLead"),
    wide=true,
    fn(v, _) {
      mode_choices_node(v, fn() { field(cv, "modeWords") }, fn() { next.get() }, fn(n) { next.set(n) })
      // (what switching does, one notice for the way chosen: another way's comes in its place whole, none when it does
      // nothing)
      v.show(fn() { effects().length() > 0 }, fn(sh) {
        sh.pick(effects, fn(a, list) {
          @sf.style_node(a, fn() { cd_amber.then(@ui.style(bg=Data(@sf.theme().p.amber_bg))) })
          @sf.words_node(a, fn() { @sf.t("web-pages.connect.afterChange") }, fn() { cd_amber_title }) |> ignore
          a.box(fn(l) {
            @sf.style_node(l, fn() { cd_effects })
            l.each(fn() { list }, fn(x) { x }, at_once=true, fn(e, x) {
              @sf.style_node(e, fn() { cd_effect })
              @sf.words_node(e, fn() { "•" }, fn() { cd_bullet }) |> ignore
              e.box(fn(w) {
                @sf.style_node(w, fn() { cd_effect_words }, in_row=true)
                let words = x.untracked()
                @sf.words_node(w, fn() { words }, fn() { cd_words }) |> ignore
              })
              |> ignore
            })
          })
          |> ignore
        })
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { text(change(), "action") },
        fn() {
          let (mode, mention, threads) = next.get()
          let input = [("mode", str(mode)), ("requireMention", Json::boolean(mention))]
          if text(cv, "kind") == "feishu" {
            input.push(("feishu", obj([("threads", Json::boolean(threads))])))
          }
          cd_put(core, station, id, obj(input), done=@sf.t("web-pages.connect.modeChanged"))
          shut()
        },
        tone=Primary,
        disabled=fn() { !flag(change(), "changed") },
      )
      |> ignore
    },
  )
}

///|
/// A single-session connect's session chosen (ChooseSessionDialog): a new one (its name typed, or not), or one of
/// those it could go into (the one now marked 当前); it closes as it goes, the session's line turning meanwhile.
fn cd_choose_dialog(core : Core, here : Here, station : String, item : Json?) -> Unit {
  let cv = field(item, "connect")
  let id = text(cv, "id")
  let choice : @signals.Signal[String] = @signals.signal(
    match opt_text(cv, "session") {
      Some(s) => s
      None => "new"
    },
  )
  let title = @ui.Field::new()
  let options = fn() {
    let out = [("new", @sf.t("web-pages.connect.newSession"), @sf.t("web-pages.connect.newSessionLead"))]
    // (the sessions it could go into: asked ahead by its page while 更换 shows (cd_run_node), here as it opens)
    for s in @settings.connect_candidates(core, here, station, id).unwrap_or([]) {
      let sv = Some(s)
      let named = if flag(sv, "current") {
        text(sv, "titleText") + " · " + @sf.t("web-pages.connect.current")
      } else {
        text(sv, "titleText")
      }
      out.push((text(sv, "key"), named, text(sv, "description")))
    }
    out
  }
  open_dialog_nodes(
    @sf.t("web-pages.connect.chooseTitle"),
    description=@sf.t("web-pages.connect.chooseLead", args=[("name", text(cv, "name"))]),
    wide=true,
    fn(v, _) {
      @sf.choices_node(v, fn() { choice.get() }, options, fn(c) { choice.set(c) }, label=fn() { @sf.t("web-pages.connect.session") }, extra=fn(
        k,
      ) {
        guard k == "new" else { None }
        Some(fn(x) { @sf.input_node(x, title, placeholder=@sf.t("web-pages.connect.newSessionPlaceholder")) |> ignore })
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t(if choice.get() == "new" { "web-pages.connect.createUse" } else { "web-pages.connect.useThis" }) },
        fn() {
          let fresh = choice.get() == "new"
          @settings.act(
            core,
            @sf.t("web-pages.connect.switch"),
            "connect.bindSession",
            obj([
              ("station", str(station)),
              ("connect", str(id)),
              ("session", if fresh { Json::null() } else { str(choice.get()) }),
              ("title", str(title.text())),
            ]),
            done=@sf.t(if fresh { "web-pages.connect.sessionCreated" } else { "web-pages.connect.sessionSwitched" }),
          )
          shut()
        },
        tone=Primary,
        disabled=fn() { opt_text(cv, "session") == Some(choice.get()) },
      )
      |> ignore
    },
  )
}

///|
/// How many of its latest sessions show before the rest are asked for (SESSIONS_SHOWN).
let cd_sessions_shown : Int = 5

///|
/// The connects whose sessions are all shown, by station/id.
// kept across runs: said by 显示全部 and 收起; connect_reset empties it
let cd_all_sessions : Map[String, Bool] = Map([])

///|
/// It handed to another person (OwnerDialog): a member of the workspace picked, or any email while its members are not
/// read; 保存 once it is another, closing as it goes.
fn cd_owner_dialog(core : Core, here : Here, station : String, cv : Json?) -> Unit {
  let id = text(cv, "id")
  let people = fn() { items(workspace_view(core, here).value, "members") }
  let current = text(field(cv, "createdBy"), "id")
  let first = people()
  let owner : @signals.Signal[String] = @signals.signal(
    if current != "" {
      current
    } else {
      match first.get(0) {
        Some(p) => text(Some(p), "email")
        None => ""
      }
    },
  )
  let email = @ui.Field::new()
  if first.length() == 0 {
    email.set(owner.get())
  }
  // (the one picked, or the email typed while the members are not read)
  let to = fn() {
    let o = if people().length() > 0 { owner.get() } else { email.text() }
    o.trim(chars=" \t\n").to_owned()
  }
  open_dialog_nodes(
    @sf.t("web-pages.connect.changeOwner"),
    description=@sf.t("web-pages.connect.ownerLead"),
    fn(v, _) {
      v.pick(fn() { people().length() > 0 }, fn(p, listed) {
        if listed {
          @sf.field_node(p, fn() { @sf.t("web-pages.connect.ownerLabel") }, fn(f) {
            @sf.select_node(
              f,
              fn() { owner.get() },
              fn() {
                people().map(fn(m) {
                  let pv = Some(m)
                  let mail = text(pv, "email")
                  (mail, if text(pv, "name") != "" { @sf.t("web-pages.connect.person", args=[("name", text(pv, "name")), ("email", mail)]) } else { mail })
                })
              },
              fn(s) { owner.set(s) },
              label=fn() { @sf.t("web-pages.connect.ownerLabel") },
            )
          })
        } else {
          @sf.field_node(p, fn() { @sf.t("web-pages.connect.ownerEmail") }, fn(f) {
            @sf.input_node(f, email, placeholder="name@example.com") |> ignore
          })
        }
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("common.save") },
        fn() {
          let to = to()
          let chosen = people().iter().find_first(fn(p) { text(Some(p), "email").to_lower() == to.to_lower() })
          let name = match chosen {
            Some(p) if text(Some(p), "name") != "" => text(Some(p), "name")
            _ => to
          }
          cd_put(core, station, id, obj([("owner", obj([("id", str(to)), ("name", str(name))]))]), done=@sf.t("web-pages.connect.ownerChanged"))
          shut()
        },
        tone=Primary,
        disabled=fn() { to() == "" || to() == current },
      )
      |> ignore
    },
  )
}

///|
/// A Feishu connect's App Secret replaced (SecretDialog): checked by its station before it is kept, then it
/// reconnects; the dialog stays while it is, why it was refused under the field.
fn cd_secret_dialog(core : Core, station : String, cv : Json?) -> Unit {
  let id = text(cv, "id")
  let secret = @ui.Field::new()
  let error : @signals.Signal[String] = @signals.signal("")
  let typed = fn() { secret.text().trim(chars=" \t\n").to_owned() }
  open_dialog_nodes(
    @sf.t("web-pages.connect.feishu.replace"),
    description=@sf.t("web-pages.connect.feishu.replaceLead"),
    fn(v, _) {
      @sf.field_node(v, fn() { "App Secret" }, error=fn() { error.get() }, fn(f) {
        @sf.input_node(f, secret, placeholder=text(field(cv, "feishu"), "appSecret"), secret=true, label="App Secret") |> ignore
      })
    },
    fn(v, shut) {
      @sf.button_node(v, fn() { @sf.t("common.cancel") }, shut, tone=Ghost) |> ignore
      @sf.button_node(
        v,
        fn() { @sf.t("web-pages.connect.saveReconnect") },
        fn() {
          error.set("")
          (core.call)("feishu.putSecret", obj([("station", str(station)), ("id", str(id)), ("appSecret", str(typed()))]), fn(r) {
            match r {
              Ok(_) => {
                (core.say)(@sf.t("web-pages.connect.feishu.secretSaved"))
                shut()
              }
              Err(e) => error.set(error_text(e))
            }
          })
        },
        tone=Primary,
        busy=fn() { is_doing(core, ["feishu.putSecret"], [("station", station), ("id", id)]) },
        disabled=fn() { typed() == "" },
      )
      |> ignore
    },
  )
}

///|
/// A ring and a mark beside words (14).
let cd_icon : Double = 14.0

///|
/// The callout on amber (12 by 14 in, a corner of 14; its title in the amber's ink, its list 6 under it, 4 apart).
// kept across runs: a value (no field of it changes)
let cd_amber : @ui.Style = @ui.css("w=Full px=S3_5 py=S3 radius=Xl1_5")

///|
// kept across runs: a value (no field of it changes)
let cd_amber_title : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=WarnInk, w=Full)

///|
// kept across runs: a value (no field of it changes)
let cd_effects : @ui.Style = @ui.css("w=Full pt=S1_5 gap=S1")

///|
// kept across runs: a value (no field of it changes)
let cd_effect : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let cd_effect_words : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let cd_bullet : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false)

///|
/// What is wrong on its callout (the ui's 13, the words' ink).
// kept across runs: a value (no field of it changes)
let cd_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)
