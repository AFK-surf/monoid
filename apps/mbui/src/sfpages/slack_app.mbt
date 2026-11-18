// A connect's Slack app on the desktop (still.fail web/src/pages/SlackApp.tsx SlackAppSection, ConfigTokenForm, AppFields,
// AppForm; SlackApp.css.ts): folded on its page (it is changed now and then), its look and permissions edited here and
// written into the app's manifest with the viewer's configuration token (`connect.putSlackApp`, given what the form
// started from: the core writes only what differs); without one, a way to add it. The permissions' sections are the
// core's (the slackApp topic's and the connect wizard's `sections`); the icon is drawn by the library (app_icon.mbt).

///|
/// A Slack app's look and permissions being edited (AppFields' settings, and what its look keeps): what is typed (its
/// fields' words: its name, what it is for, its colour) and picked, the icon made (a data URL, "" none) and why it could
/// not be, and how the icon is coming along; each as it is now, followed.
priv struct SaDraft {
  /// the colour as it was last set (typed, or what was picked's)
  color : @signals.Signal[String]
  groups : @sf.LiveMap[String, Bool]
  icon : @signals.Signal[String]
  icon_error : @signals.Signal[String]
  /// the icon as shown (its picture's key), "" none
  shown : @signals.Signal[String]
  /// what was picked: an avatar's id, or a picture of the person's own (its key), "" neither
  picked : @signals.Signal[String]
  upload : @signals.Signal[String]
  upload_bg : @signals.Signal[String]
  /// the colour set by hand, not by what was picked
  colour_set : @signals.Signal[Bool]
  /// the picture being read to draw from: its source, how large, on what colour ("" none)
  reading : @signals.Signal[(String, Int, String)]
  mut asking : Bool
  /// the permissions unfolded
  perms : @signals.Signal[Bool]
  name_field : @ui.Field
  desc_field : @ui.Field
  hex_field : @ui.Field
}

///|
/// The groups `settings` (a Slack app's, as the core has them) turns on.
fn sa_groups(settings : Json?) -> Map[String, Bool] {
  let groups : Map[String, Bool] = Map([])
  match field(settings, "groups") {
    Some(Object(m)) =>
      for g, v in m {
        groups[g] = v == Json::boolean(true)
      }
    _ => ()
  }
  groups
}

///|
/// A draft of `settings` (a Slack app's, as the core has them), its fields filled with them.
fn sa_draft(settings : Json?) -> SaDraft {
  {
    color: @signals.signal(text(settings, "backgroundColor")),
    groups: @sf.LiveMap::from(sa_groups(settings)),
    icon: @signals.signal(""),
    icon_error: @signals.signal(""),
    shown: @signals.signal(""),
    picked: @signals.signal(""),
    upload: @signals.signal(""),
    upload_bg: @signals.signal(""),
    colour_set: @signals.signal(false),
    reading: @signals.signal(("", 0, "")),
    asking: false,
    perms: @signals.signal(false),
    name_field: @ui.Field::new(text=text(settings, "name")),
    desc_field: @ui.Field::new(text=text(settings, "description")),
    hex_field: @ui.Field::new(text=text(settings, "backgroundColor")),
  }
}

///|
/// The draft `d` started again from `settings`, as it was first made of them (还原; Slack's settings changed).
fn sa_draft_reset(d : SaDraft, settings : Json?) -> Unit {
  @signals.start_batch()
  d.color.set(text(settings, "backgroundColor"))
  d.groups.clear()
  for g, v in sa_groups(settings) {
    d.groups[g] = v
  }
  d.icon.set("")
  d.icon_error.set("")
  d.shown.set("")
  d.picked.set("")
  d.upload.set("")
  d.upload_bg.set("")
  d.colour_set.set(false)
  d.reading.set(("", 0, ""))
  d.asking = false
  d.perms.set(false)
  d.name_field.set(text(settings, "name"))
  d.desc_field.set(text(settings, "description"))
  d.hex_field.set(text(settings, "backgroundColor"))
  @signals.end_batch()
}

///|
/// What an app's look and permissions say of it, as the core takes its settings (the name in messages its name too).
fn sa_settings_of(name : String, description : String, color : String, groups : Map[String, Bool], settings : Json?) -> Json {
  let out : Map[String, Json] = Map([])
  for g, v in groups {
    out[g] = Json::boolean(v)
  }
  obj([
    ("name", str(name)),
    ("displayName", str(name)),
    ("description", str(description)),
    ("longDescription", str(text(settings, "longDescription"))),
    ("backgroundColor", str(color)),
    ("groups", Json::object(out)),
  ])
}

///|
/// What the draft says of the app, as the core takes its settings.
fn sa_settings(d : SaDraft, settings : Json?) -> Json {
  sa_settings_of(d.name_field.text(), d.desc_field.text(), d.color.get(), d.groups.copy(), settings)
}

///|
/// The drafts, by their form; the folds open, by station/connect; icons made, each its own picture's key.
// kept across runs: made as each form is first made; slack_app_reset empties it
let sa_drafts : Map[String, SaDraft] = Map([])

///|
// kept across runs: said by the fold's press; slack_app_reset empties it
let sa_open : Map[String, Bool] = Map([])

///|
/// What a form started from (its settings as text), by its key: a change there starts it again.
// kept across runs: said as each form starts; slack_app_reset empties it
let sa_started : Map[String, String] = Map([])

///|
/// The forms whose permissions Slack wants approved (their install links), by station/connect.
// kept across runs: said by 应用's answer; slack_app_reset empties it
let sa_approve : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
// kept across runs: counted by sa_icon_made; slack_app_reset puts it back
let sa_icons_made : Ref[Int] = Ref(0)

///|
fn slack_app_reset() -> Unit {
  sa_drafts.clear()
  sa_open.clear()
  sa_started.clear()
  sa_approve.clear()
  sa_token_errors.clear()
  sa_icons_made.val = 0
  @sf.app_icons_reset()
}

///|
/// The connect's Slack app, folded (SlackAppSection), as nodes in `b`: a row of its own on a card, its title and what it
/// is for, that opens it (open as it was left, kept with its connect); open, the app as Slack has it under it (read
/// through the station: being read, none, no configuration token to write it with, or why it could not be read), its
/// form, and Slack's page of it. Apart from what follows, as a section is. `page_w`: how wide its page is; its tips in
/// `tips`.
fn slack_app_node(b : @view.View, core : Core, station : String, id : String, page_w : () -> Double, tips : @sf.TipLayer) -> Unit {
  let me = station + "/" + id
  let open : @signals.Signal[Bool] = @signals.signal(sa_open.get(me).unwrap_or(false), same=fn(a, b) { a == b })
  @sf.apart_node(b, fn(a) {
    @sf.group_node(a, fn(g) {
      g.pick(fn() { open.get() }, fn(r, now) {
        @sf.link_row_node(
          r,
          fn() { "Slack app" },
          fn() {
            sa_open[me] = !now
            open.set(!now)
          },
          note=fn() { @sf.t("web-pages.slackApp.foldNote") },
          value=fn() { if now { @sf.t("web-pages.profiles.collapse") } else { "" } },
          chevron=!now,
        )
      })
    })
    a.show(fn() { open.get() }, fn(i) { slack_app_open_node(i, core, station, id, page_w, tips) })
  })
  |> ignore
}

///|
/// The Slack app's fold open (slack_app_node's) in `i`: the app as Slack has it, as the station reads it now; its page
/// in Slack under it where Slack gives one.
fn slack_app_open_node(i : @view.View, core : Core, station : String, id : String, page_w : () -> Double, tips : @sf.TipLayer) -> Unit {
  let topic = fn() { (core.topic)("slackApp", { "station": str(station), "connect": str(id) }).get() }
  let view = fn() { topic().value }
  let links = fn() { field(view(), "links") }
  let error = fn() {
    match topic().error {
      Some(e) => error_text(e)
      None => ""
    }
  }
  i.pick(
    fn() {
      if topic().error is Some(_) {
        "failed"
      } else if view() is None {
        "reading"
      } else {
        match text(view(), "state") {
          "no_app" => "no_app"
          "no_config_token" => "no_config_token"
          "error" => "error"
          _ => "form"
        }
      }
    },
    fn(p, k) {
      match k {
        "failed" => @sf.page_note_node(p, error, bad=fn() { true })
        "reading" => @sf.page_note_node(p, fn() { @sf.t("web-pages.slackApp.loading") })
        "no_app" =>
          @sf.page_note_node(p, fn() {
            match opt_text(view(), "error") {
              Some(e) => @sf.t("web-pages.slackApp.noApp", args=[("error", e)])
              None => @sf.t("web-pages.slackApp.notConnected")
            }
          })
        "no_config_token" =>
          sa_token_card_node(
            p,
            core,
            station,
            fn() { @sf.t("web-pages.slackApp.needsToken") },
            fn() { @sf.t("web-pages.slackApp.needsTokenNote") },
            fn() { @sf.t("web-pages.slackApp.addToken") },
            false,
          )
        "error" =>
          sa_token_card_node(
            p,
            core,
            station,
            fn() { @sf.t("web-pages.slackApp.readFailed", args=[("error", text(view(), "error"))]) },
            fn() { "" },
            fn() { @sf.t("web-pages.slackApp.replaceToken") },
            true,
          )
        _ => sa_form_node(p, core, station, id, fn() { field(view(), "settings") }, links, fn() { items(view(), "sections") }, page_w, tips)
      }
    },
  )
  let settings_url = fn() { opt_text(links(), "settings").unwrap_or("") }
  i.show(fn() { settings_url() != "" }, fn(o) {
    @sf.group_node(o, fn(g) {
      @sf.link_row_node(g, fn() { @sf.t("web-pages.slackApp.openInSlack") }, fn() { (core.open_link)(@signals.untracked(settings_url)) }, out=true)
    })
  })
}

///|
/// A card saying the app wants a configuration token (none, or one Slack refused: `bad`), and the button that adds one
/// (in a dialog: ConfigTokenForm), as nodes in `p`.
fn sa_token_card_node(
  p : @view.View,
  core : Core,
  station : String,
  words : () -> String,
  note : () -> String,
  action : () -> String,
  bad : Bool,
) -> Unit {
  @sf.page_card_node(p, footed=true, fn(k) {
    @sf.card_lines_node(k, fn() { "" }, words=fn() { if bad { "" } else { words() } }, note~, bad=fn() { if bad { words() } else { "" } })
    @sf.card_foot_node(k, fn(f) { @sf.button_node(f, action, fn() { config_token_dialog(core, station) }, card_words=true) |> ignore })
  })
}

///|
/// A Slack workspace's app configuration token added, in a dialog (SlackAppSection's Dialog: ConfigTokenForm).
fn config_token_dialog(core : Core, station : String) -> Unit {
  let key = "config-token/" + (desk_dialogs.val + 1).to_string()
  // (no foot: its button is beside the token, in its third step)
  open_dialog_bare_nodes(
    @sf.t("web-pages.slackApp.addTokenTitle"),
    wide=true,
    fn(v, shut) { config_token_form_node(v, core, station, key, shut) },
    on_gone=fn() { sa_token_errors.remove(key) },
  )
}

///|
/// What a configuration token form went through: why the station refused it ("" none), by the form's own key.
// kept across runs: said by its call's answer; let go as its dialog goes (config_token_dialog)
let sa_token_errors : @sf.LiveMap[String, String] = @sf.LiveMap::new()

///|
/// Adding a Slack workspace's app configuration token by its refresh token (ConfigTokenForm), as nodes in `v`: three
/// steps, each a number in a circle on its title's line, its title and what to do (Slack's apps page opened from the
/// first; the token pasted in the third, added from the button beside it). `flow`: the connect wizard's (its view as
/// it is now, how it is told to add it, how each change is told), which keeps the token and says whether it is ready
/// and what is wrong with it; else the station checks it as it is added, `saved` once it took it.
fn config_token_form_node(
  v : @view.View,
  core : Core,
  station : String,
  key : String,
  saved : () -> Unit,
  flow? : (() -> Json?, () -> Unit, (String) -> Unit),
) -> Unit {
  let tf = @ui.Field::new()
  let token = fn() { tf.text().trim(chars=" \t\n").to_owned() }
  let ready = fn() {
    match flow {
      Some((view, _, _)) => flag(view(), "configReady")
      None => token() != ""
    }
  }
  let wrong = fn() {
    match flow {
      Some((view, _, _)) => opt_text(view(), "configError").unwrap_or("")
      None => sa_token_errors.get(key).unwrap_or("")
    }
  }
  let busy = fn() {
    match flow {
      Some(_) => is_doing(core, ["connect.flow.config"], [("station", station)])
      None => is_doing(core, ["slack.addConfigToken"], [("station", station)])
    }
  }
  let add = fn() {
    match flow {
      Some((_, act, _)) => act()
      None => {
        let typed = token()
        sa_token_errors.remove(key)
        (core.call)("slack.addConfigToken", obj([("station", str(station)), ("refreshToken", str(typed))]), fn(r) {
          match r {
            Ok(_) => {
              tf.set("")
              (core.say)(@sf.t("web-pages.slackApp.tokenAdded"))
              saved()
            }
            Err(e) => sa_token_errors.set(key, error_text(e))
          }
        })
      }
    }
  }
  // (with the wizard: each change of the token told to it as it is typed)
  match flow {
    Some((_, _, edit)) => v.reacts(at_start=false, token, fn(t) { edit(t) })
    None => ()
  }
  v.box(fn(g) {
    @sf.style_node(g, fn() { sa_guide })
    sa_guide_step_node(g, 1, "web-pages.slackApp.step1", fn() { @sf.t("web-pages.slackApp.step1Note") }, fn(b) {
      @sf.button_node(b, fn() { @sf.t("web-pages.slackApp.openApps") }, fn() { (core.open_link)("https://api.slack.com/apps") }, tone=Primary, icon="external")
      |> ignore
    })
    sa_guide_step_node(g, 2, "web-pages.slackApp.step2", fn() { @sf.t("web-pages.slackApp.step2Note") }, fn(_) {  })
    sa_guide_step_node(g, 3, "web-pages.slackApp.step3", fn() { @sf.t("web-pages.slackApp.step3Note", args=[("name", "still.fail")]) }, fn(
      b,
    ) {
      b.box(fn(r) {
        @sf.style_node(r, fn() { sa_input_row })
        r.box(fn(i) {
          @sf.style_node(i, fn() { sa_input_grow }, in_row=true)
          @sf.input_node(i, tf, placeholder="xoxe-1-…", secret=true, label=@sf.t("web-pages.slackApp.step3")) |> ignore
        })
        |> ignore
        @sf.button_node(r, fn() { @sf.t("web-pages.slackApp.add") }, add, tone=Primary, busy~, disabled=fn() { !ready() }) |> ignore
      })
      |> ignore
      b.show(fn() { wrong() != "" }, fn(w) { @sf.words_node(w, wrong, fn() { desk_note_bad }) |> ignore })
    })
  })
  |> ignore
}

///|
/// One of the guide's steps (tokenGuide li, sa_guide_step's as nodes) in `g`: its number `n` in a 24 circle on the
/// neutral ground on its title's line, its title (`title`: its words' key) in 600, what to do muted, what `body` makes
/// under them.
fn sa_guide_step_node(g : @view.View, n : Int, title : String, note : () -> String, body : (@view.View) -> Unit) -> Unit {
  g.box(fn(r) {
    @sf.style_node(r, fn() { sa_step })
    // (its circle across its title's line's middle, as tall as that line at the system's size of words)
    @sf.step_circle_node(r, fn() { n.to_string() }, first_line=Ui, leading=L6) |> ignore
    r.box(fn(b) {
      @sf.style_node(b, fn() { sa_step_body }, in_row=true)
      @sf.words_node(b, fn() { @sf.t(title) }, fn() { desk_strong }) |> ignore
      @sf.words_node(b, note, fn() { desk_muted }) |> ignore
      body(b)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The app's form (AppForm, a card) as nodes in `p`: Slack asking for changed permissions to be approved (its page
/// opened from it); its look and permissions; why its icon could not be made; 还原 while changed, 应用 writing what
/// changed (the core compares it with what the form started from). Started again when Slack's settings change.
fn sa_form_node(
  p : @view.View,
  core : Core,
  station : String,
  id : String,
  settings : () -> Json?,
  links : () -> Json?,
  sections : () -> Array[Json],
  page_w : () -> Double,
  tips : @sf.TipLayer,
) -> Unit {
  let me = station + "/" + id
  let key = "slack-app/" + me
  let start = fn() {
    match settings() {
      Some(s) => s.stringify()
      None => ""
    }
  }
  let started = @signals.untracked(start)
  let d = match sa_drafts.get(key) {
    Some(d) if sa_started.get(key) == Some(started) => d
    _ => {
      let d = sa_draft(@signals.untracked(settings))
      sa_drafts[key] = d
      sa_started[key] = started
      d
    }
  }
  // (Slack's settings changed: the form started again from them)
  p.reacts(start, fn(now) {
    if sa_started.get(key) != Some(now) {
      sa_started[key] = now
      sa_draft_reset(d, @signals.untracked(settings))
    }
  })
  let busy = fn() { is_doing(core, ["connect.putSlackApp"], [("station", station), ("connect", id)]) }
  let now = fn() { sa_settings(d, settings()) }
  let dirty = fn() {
    let s = settings()
    now() != sa_settings_of(text(s, "name"), text(s, "description"), text(s, "backgroundColor"), sa_groups(s), s) ||
    d.icon.get() != ""
  }
  @sf.page_card_node(p, footed=true, fn(k) {
    k.show(fn() { sa_approve.get(me) is Some(_) }, fn(a) {
      a.box(fn(b) {
        @sf.style_node(b, fn() { sa_blue })
        b.ground(By(fn() { @sf.theme().p.blue_bg })) |> ignore
        @sf.icon_node(b, "shield-check", cd_icon, By(fn() { @sf.theme().p.blue })) |> ignore
        b.box(fn(w) {
          @sf.style_node(w, fn() { cd_effect_words }, in_row=true)
          @sf.words_node(w, fn() { @sf.t("web-pages.slackApp.approveNote") }, fn() { sa_blue_words }) |> ignore
        })
        |> ignore
        @sf.button_node(
          b,
          fn() { @sf.t("web-pages.slackApp.approve") },
          fn() {
            let install = sa_approve.get(me).unwrap_or("")
            sa_approve.remove(me)
            (core.open_link)(install)
          },
          tone=Primary,
        )
        |> ignore
      })
      |> ignore
    })
    app_fields_node(k, core, d, sections, fn() { sa_column(page_w()) - 2.0 * sa_card_in }, tips)
    k.show(fn() { d.icon_error.get() != "" }, fn(e) { @sf.card_lines_node(e, fn() { "" }, bad=fn() { d.icon_error.get() }) })
    @sf.card_foot_node(k, at_end=true, fn(f) {
      f.show(dirty, fn(r) {
        @sf.button_node(r, fn() { @sf.t("web-pages.slackApp.revert") }, fn() { sa_draft_reset(d, @signals.untracked(settings)) }, tone=Ghost)
        |> ignore
      })
      @sf.button_node(
        f,
        fn() { @sf.t("web-pages.slackApp.apply") },
        fn() {
          let (input0, from, links_now) = @signals.untracked(fn() { (now(), settings(), links()) })
          let input = match input0 {
            Object(m) => {
              let m2 = Map::from_iter(m.iter())
              let icon = d.icon.untracked()
              if icon != "" {
                m2["icon"] = str(icon)
              }
              Json::object(m2)
            }
            other => other
          }
          (core.call)(
            "connect.putSlackApp",
            obj([("station", str(station)), ("connect", str(id)), ("input", input), ("from", from.unwrap_or(Json::null()))]),
            fn(r) {
              match r {
                Ok(v) => {
                  let rv = Some(v)
                  let approve = flag(rv, "permissionsUpdated")
                  d.icon.set("")
                  d.icon_error.set(opt_text(rv, "iconError").unwrap_or(""))
                  let install = text(field(rv, "links"), "install")
                  if approve {
                    sa_approve[me] = if install != "" { install } else { text(links_now, "install") }
                    // (the desktop opens Slack's page in the system's browser, at any time)
                    (core.open_link)(sa_approve.get(me).unwrap_or(""))
                  }
                  (core.say)(@sf.t(if approve { "web-pages.slackApp.updatedApprove" } else { "web-pages.slackApp.updated" }))
                }
                Err(e) => (core.say)(error_text(e))
              }
            },
          )
        },
        tone=Primary,
        busy~,
        disabled=fn() { !dirty() },
      )
      |> ignore
    })
  })
}

///|
/// An app's look and permissions (app_fields', as nodes) in `k`: its heading; its avatar (pressed, a picture of the
/// person's own), its name, what it is for and its colour (following what was picked until set by hand, and back to it);
/// the avatars to start from (still.fail's buddies, the model makers); the permissions folded. `width`: how wide it is
/// drawn now; its tips in `tips`. `fresh`: a new app's (the new connect's), which starts as the general helper (else
/// the first avatar), on its colour, once the avatars are read; its own picture's choice then says 上传, not 保留.
fn app_fields_node(
  k : @view.View,
  core : Core,
  d : SaDraft,
  sections : () -> Array[Json],
  width : () -> Double,
  tips : @sf.TipLayer,
  fresh? : Bool = false,
) -> Unit {
  @sf.app_buddies_ask(fn(done) { (core.call)("buddies", obj([]), done) })
  let all = fn() { @sf.app_buddies_now() + @sf.app_makers }
  let find = fn(id : String) { @signals.untracked(all).iter().find_first(fn(a) { a.id == id }) }
  let colour = fn(bg : String) {
    d.color.set(bg)
    d.hex_field.set(bg)
  }
  // an avatar drawn on `bg`: a mark at once, a buddy once its picture is read
  let draw = fn(a : @sf.AppAvatar, bg : String) {
    if a.mark != "" {
      d.reading.set(("", 0, ""))
      match @sf.app_avatar_icon(a, bg, 0, 0, FixedArray::make(0, b'\x00')) {
        Some(icon) => sa_icon_made(d, icon)
        None => sa_icon_failed(d, @sf.t("web-pages.slackApp.drawFailed"))
      }
    } else {
      d.reading.set((@sf.avatars_base() + "/avatars/" + a.id + ".webp", @sf.app_icon_px, bg))
    }
  }
  let pick = fn(a : @sf.AppAvatar) {
    d.picked.set(a.id)
    d.upload.set("")
    let bg = if d.colour_set.untracked() { d.color.untracked() } else { a.bg }
    colour(bg)
    draw(a, bg)
  }
  // a new app starts as the general helper (else the first avatar), on its colour, once the avatars are read
  if fresh {
    let started = Ref(false)
    k.reacts(fn() { all().length() > @sf.app_makers.length() }, fn(read) {
      if read && !started.val {
        started.val = true
        let avatars = @signals.untracked(all)
        pick(find("general-helper").unwrap_or(avatars[0]))
      }
    })
  }
  // the picture being read, its pixels drawn into the icon once they are here (or why they could not be)
  k.pick(fn() { d.reading.get() }, fn(r, rd) {
    let (src, px, bg) = rd
    guard src != "" else { return }
    let read = @ui.tree_image_pixels(r, src, px)
    let state = fn() {
      match read() {
        None => 0
        Some(PixelsRead(_, _, _)) => 1
        Some(_) => 2
      }
    }
    r.reacts(state, fn(s) {
      match (s, @signals.untracked(read)) {
        (1, Some(PixelsRead(w, h, pixels))) => {
          let own = d.upload.untracked() != ""
          d.reading.set(("", 0, ""))
          if own {
            let icon = @sf.app_own_icon(w, h, pixels)
            let edge = @pixels.edge_colour(@sf.app_icon_px, @sf.app_icon_px, icon.pixels())
            d.upload_bg.set(edge)
            sa_icon_made(d, icon)
            if !d.colour_set.untracked() {
              colour(edge)
            }
          } else {
            match find(d.picked.untracked()) {
              Some(a) =>
                match @sf.app_avatar_icon(a, bg, w, h, pixels) {
                  Some(icon) => sa_icon_made(d, icon)
                  None => sa_icon_failed(d, @sf.t("web-pages.slackApp.drawFailed"))
                }
              None => ()
            }
          }
        }
        (2, _) => {
          let own = d.upload.untracked() != ""
          sa_icon_failed(d, @sf.t(if own { "web-pages.slackApp.readImageFailed" } else { "web-pages.slackApp.drawFailed" }))
        }
        _ => ()
      }
    })
  })
  // a picture of their own, from the system's picker
  let upload = fn() {
    if d.asking {
      return
    }
    let asked = (core.pick_picture)(fn(bytes) {
      d.asking = false
      match bytes {
        Some(b) => {
          sa_icons_made.val += 1
          let own = "mem:desk-slack-icon/own/\{sa_icons_made.val}"
          @ui.add_image(own, b)
          d.upload.set(own)
          d.picked.set("")
          d.reading.set((own, @sf.app_own_px, ""))
        }
        None => ()
      }
    })
    d.asking = asked
    if !asked {
      sa_icon_failed(d, @sf.t("web-pages.slackApp.readImageFailed"))
    }
  }
  // (typed in its colour's field: set by hand, what was picked drawn on it)
  k.reacts(fn() { d.hex_field.text().trim(chars=" ").to_owned() }, fn(typed) {
    if typed != d.color.untracked() {
      d.color.set(typed)
      d.colour_set.set(true)
      if @sf.hex_color(typed) is Some(_) {
        match find(d.picked.untracked()) {
          Some(a) => draw(a, typed)
          None => ()
        }
      }
    }
  })
  let ground = fn() { @sf.hex_color(d.color.get()).unwrap_or(@sf.theme().p.neutral_bg) }
  // (what it says on the colour chosen: a near black or white, whichever reads on it; the muted grey on none)
  let ink = fn() {
    match @sf.hex_color(d.color.get()) {
      Some(v) => @ui.ink_on(v, [0x24272BFFL, 0xFFFFFFFFL])
      None => @sf.theme().p.muted
    }
  }
  // its heading (as the phone's look: 头像), over what has a ground: so a card's corner it begins in holds words
  @sf.card_lines_node(k, fn() { @sf.t("android-settings.slack.icon") })
  k.box(fn(l) {
    @sf.style_node(l, fn() { sa_look })
    // its avatar (appAvatar: 136, the settings' corner, on the neutral ground behind its colour): pressed, a picture
    let ab = @sf.action_box_node(l, fn() { @sf.t("web-pages.slackApp.upload") }, fn(_) { upload() }, fn(a) {
      @sf.style_node(a, fn() { sa_avatar }, in_row=true)
      a.ground(By(ground)).clips(Is(true)) |> ignore
      a.pick(fn() { d.shown.get() }, fn(s, shown) {
        if shown != "" {
          s.box(fn(img) {
            img
            .over(Is(true))
            .image(Is(Some((shown, "", @sf.app_icon_px))))
            .image_covers(Is(true))
            .image_fades(Is(false))
            |> ignore
          })
          |> ignore
        } else {
          s.box(fn(e) {
            @sf.style_node(e, fn() { sa_avatar_empty })
            @sf.icon_node(e, "image-upload", sa_upload_icon, By(ink)) |> ignore
            @sf.words_node(e, fn() { @sf.t(if fresh { "web-pages.slackApp.uploadShort" } else { "web-pages.slackApp.keep" }) }, fn() { sa_avatar_words }).ink(By(ink)) |> ignore
          })
          |> ignore
        }
      })
    })
    @sf.tip_node(tips, ab, fn() { @sf.t("web-pages.slackApp.upload") }) |> ignore
    l.box(fn(m) {
      @sf.style_node(m, fn() { sa_look_main }, in_row=true)
      @sf.input_node(m, d.name_field, placeholder=@sf.t("web-pages.settings.workspace.name")) |> ignore
      @sf.input_node(m, d.desc_field, placeholder=@sf.t("web-pages.slackApp.descriptionPlaceholder")) |> ignore
      m.box(fn(c) {
        @sf.style_node(c, fn() { sa_colour })
        c.box(fn(w) {
          @sf.style_node(w, fn() { sa_swatch }, in_row=true)
          w.ground(By(ground)) |> ignore
        })
        |> ignore
        c.box(fn(h) {
          @sf.style_node(h, fn() { sa_hex }, in_row=true)
          @sf.input_node(h, d.hex_field, label=@sf.t("web-pages.slackApp.color")) |> ignore
        })
        |> ignore
        // what was picked's own colour, after one set by hand
        let recommended = fn() {
          match d.picked.get() {
            "" => d.upload_bg.get()
            id =>
              match all().iter().find_first(fn(a) { a.id == id }) {
                Some(a) => a.bg
                None => d.upload_bg.get()
              }
          }
        }
        c.show(fn() { d.colour_set.get() && recommended() != "" && recommended().to_lower() != d.color.get().to_lower() }, fn(r) {
          cd_text_button_node(r, fn() { @sf.t("web-pages.slackApp.recommended") }, fn() {
            let bg = @signals.untracked(recommended)
            d.colour_set.set(false)
            colour(bg)
            match find(d.picked.untracked()) {
              Some(a) => draw(a, bg)
              None => ()
            }
          })
        })
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
  sa_avatar_picker_node(k, d, all, width, pick, tips)
  sa_permissions_node(k, d, sections, tips)
}

///|
/// The avatars to start from (sa_avatar_picker's, as nodes) in `k`: 15 to a line in the room `width` says, fewer where
/// it is less, 6 apart, 16 over them, 10 under; each square, edged in the line (the one picked ringed in the ink, the
/// field's hover grey under the pointer), its picture or its maker's mark; named by its tip.
fn sa_avatar_picker_node(
  k : @view.View,
  d : SaDraft,
  all : () -> Array[@sf.AppAvatar],
  width : () -> Double,
  pick : (@sf.AppAvatar) -> Unit,
  tips : @sf.TipLayer,
) -> Unit {
  let side = fn() { (width() - sa_tile_gap * (sa_tile_columns - 1).to_double()) / sa_tile_columns.to_double() }
  k.box(fn(p) {
    @sf.style_node(p, fn() { sa_picker })
    p.box(fn(r) {
      @sf.style_node(r, fn() { sa_picker_row })
      r.wraps(Is(Some(sa_tile_gap))) |> ignore
      // (the one picked, by member: a change of it tells the two tiles it concerns)
      let picked_is = r.selected(fn() { Some(d.picked.get()) })
      // (each tile its own avatar, given it by the list as it is made)
      r.each(all, fn(a) { a.id }, fn(t, item) {
        let a = item.untracked()
        let label = if a.label.has_prefix("android-") { @sf.t(a.label) } else { a.label }
        let on = fn() { picked_is(a.id) }
        let tile = @sf.action_box_node(t, fn() { label }, selected=on, fn(_) { pick(a) }, fn(b) {
          // (its edge: picked, sa_tile_on's; under the pointer, sa_tile_lit's, its hovered{border_color=FieldHover})
          @sf.style_node(b, fn() { if on() { sa_tile_on } else if b.pointed() { sa_tile_lit } else { sa_tile } })
          b
          .width(By(fn() { Some(side()) }))
          .height(By(fn() { Some(side()) }))
          .ground(Is(@sf.hex_color(a.bg).unwrap_or(@sf.icon_fallback)))
          .clips(Is(true))
          |> ignore
          if a.mark != "" {
            b.pick(side, fn(m, w) {
              @sf.drawable_node(m, a.mark, w * sa_mark_share, tint?=if a.mono { Some(fn() { Some(sa_white) }) } else { None }) |> ignore
            })
          } else {
            b.box(fn(img) {
              img
              .over(Is(true))
              .scale(Is(sa_thumb_scale))
              .image(Is(Some((@sf.avatars_base() + "/avatars/" + a.id + ".thumb.webp", "", 256))))
              .image_covers(Is(true))
              |> ignore
            })
            |> ignore
          }
        })
        @sf.tip_node(tips, tile, fn() { label }) |> ignore
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// The permissions, folded (sa_permissions', as nodes) in `k`: how many are on of all; all turned on from its line
/// while some are off; open, each section its title and 全选 / 全不选 (the first group stays on), its groups three to a
/// line, each a box to tick and its name (需管理员 beside those only admins allow), what it allows on hover; the first a
/// tick without a box. Nothing while there are none.
fn sa_permissions_node(k : @view.View, d : SaDraft, sections : () -> Array[Json], tips : @sf.TipLayer) -> Unit {
  let every = fn() {
    let out : Array[String] = []
    for s in sections() {
      for g in items(Some(s), "groups") {
        out.push(text(Some(g), "id"))
      }
    }
    out
  }
  let on = fn() { every().filter(fn(g) { d.groups.get(g).unwrap_or(false) }).length() }
  k.show(fn() { every().length() > 0 }, fn(p) {
    p.box(fn(b) {
      @sf.style_node(b, fn() { sa_perms })
      b.box(fn(l) {
        @sf.style_node(l, fn() { sa_perms_line })
        let said = fn() { @sf.t("web-pages.slackApp.permissions", args=[("on", on().to_string()), ("all", every().length().to_string())]) }
        @sf.action_box_node(l, said, expanded=fn() { d.perms.get() }, fn(_) { d.perms.set(!d.perms.untracked()) }, fn(s) {
          @sf.style_node(s, fn() { sa_perms_summary }, in_row=true)
          @sf.icon_node(s, "chevron-right", cd_icon, By(fn() { @sf.theme().p.muted }), name_now=fn() {
            if d.perms.get() {
              "chevron-down"
            } else {
              "chevron-right"
            }
          })
          |> ignore
          @sf.words_node(s, said, fn() { sa_perms_said }) |> ignore
        })
        |> ignore
        l.show(fn() { on() < every().length() }, fn(a) {
          cd_text_button_node(a, fn() { @sf.t("web-pages.slackApp.allOn") }, fn() {
            for g in @signals.untracked(every) {
              d.groups[g] = true
            }
          })
        })
      })
      |> ignore
      b.show(fn() { d.perms.get() }, fn(o) {
        o.box(fn(ss) {
          @sf.style_node(ss, fn() { sa_perm_sections })
          ss.each(fn() { sections().mapi(fn(i, s) { (i, s) }) }, fn(x) { text(Some(x.1), "title") + "\u{1}" + x.0.to_string() }, fn(sec, x) {
            let sv = Some(@signals.untracked(fn() { x.get().1 }))
            let groups = items(sv, "groups")
            let all = fn() { groups.iter().all(fn(g) { d.groups.get(text(Some(g), "id")).unwrap_or(false) }) }
            sec.box(fn(s) {
              @sf.style_node(s, fn() { sa_perm_section })
              s.box(fn(h) {
                @sf.style_node(h, fn() { sa_perm_head })
                @sf.words_node(h, fn() { text(sv, "title") }, fn() { sa_perm_title }) |> ignore
                cd_text_button_node(h, fn() { @sf.t(if all() { "web-pages.settings.members.none" } else { "web-pages.settings.members.all" }) }, fn() {
                  let was = @signals.untracked(all)
                  for g in groups {
                    d.groups[text(Some(g), "id")] = flag(Some(g), "fixed") || !was
                  }
                })
              })
              |> ignore
              let mut i = 0
              while i < groups.length() {
                let row = groups[i:if i + 3 < groups.length() { i + 3 } else { groups.length() }].to_owned()
                s.box(fn(r) {
                  @sf.style_node(r, fn() { sa_perm_row })
                  for g in row {
                    sa_permission_node(r, d, Some(g), tips)
                  }
                  // (three to a line, a short line's room kept)
                  for _ in row.length()..<3 {
                    r.box(fn(e) { @sf.style_node(e, fn() { sa_perm_label }, in_row=true) }) |> ignore
                  }
                })
                |> ignore
                i = i + 3
              }
            })
            |> ignore
          })
        })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// A group of permissions (sa_permission's, as nodes) in `r`: its box ticked (the first, always on: a tick without a
/// box), its name, 需管理员 beside one only admins allow, the pointer's ground on it; what it allows over it while it is
/// pointed at (the core's tip).
fn sa_permission_node(r : @view.View, d : SaDraft, g : Json?, tips : @sf.TipLayer) -> Unit {
  let id = text(g, "id")
  let item = r.box(fn(b) {
    @sf.style_node(b, fn() { sa_perm_item }, in_row=true)
    @sf.hover_ground_node(b)
    if flag(g, "fixed") {
      @sf.icon_node(b, "check", cd_kind_icon, By(fn() { @sf.theme().p.accent })) |> ignore
    } else {
      @sf.check_node(b, fn() { d.groups.get(id).unwrap_or(false) }, fn(on) { d.groups[id] = on }, fn() { text(g, "label") })
    }
    b.box(fn(l) {
      @sf.style_node(l, fn() { sa_perm_label }, in_row=true)
      @sf.words_node(l, fn() { text(g, "label") }, fn() { sa_perm_words }) |> ignore
    })
    |> ignore
    if opt_text(g, "admin") is Some(_) {
      @sf.words_node(b, fn() { @sf.t("web-pages.slackApp.admin") }, fn() { sa_admin_words }) |> ignore
    }
  })
  @sf.tip_node(tips, item, fn() { text(g, "tip") }) |> ignore
}

///|
/// Words to press beside a row's (cd_text_button's, as a node) in `parent`: the meta's 13 underlined, muted, the
/// words' ink under the pointer; `press` done as they are pressed.
fn cd_text_button_node(parent : @view.View, label : () -> String, press : () -> Unit) -> Unit {
  @sf.action_box_node(parent, label, fn(_) { press() }, fn(b) {
    b.box(fn(w) {
      w
      .words_runs(By(fn() { [@ui.span(label(), underline=true)] }), look=@ui.style_words(cd_text_button_words))
      .ink(By(fn() { @ui.style_ink(if b.pointed() { cd_text_button_lit } else { cd_text_button_words }) }))
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// How wide a page `w` wide leaves its column (settings_page's desk_column, a page's width given).
fn sa_column(w : Double) -> Double {
  dmin(desk_column_most, dmin(w - 2.0 * desk_lane_in, desk_lane_most) - 2.0 * desk_column_in)
}

///|
/// An icon made: shown in the look, and kept as it goes to Slack.
fn sa_icon_made(d : SaDraft, icon : @pixels.Canvas) -> Unit {
  let (jpeg, url) = @sf.app_icon_jpeg(icon)
  sa_icons_made.val += 1
  let shown = "mem:desk-slack-icon/\{sa_icons_made.val}"
  @ui.add_image(shown, jpeg)
  d.shown.set(shown)
  d.icon.set(url)
  d.icon_error.set("")
}

///|
/// An icon that could not be made: why.
fn sa_icon_failed(d : SaDraft, words : String) -> Unit {
  d.reading.set(("", 0, ""))
  d.icon.set("")
  d.icon_error.set(words)
}

///|
/// The sizes: the avatar 136 (its upload mark 20), the avatars 15 to a line 6 apart (a mark 55% of its tile, a
/// buddy's picture 1.18 times it), the card's padding 20.
let sa_upload_icon : Double = 20.0

///|
let sa_tile_columns : Int = 15

///|
let sa_tile_gap : Double = 6.0

///|
let sa_mark_share : Double = 0.55

///|
let sa_thumb_scale : Double = 1.18

///|
let sa_card_in : Double = 20.0

///|
let sa_white : Int64 = 0xFFFFFFFFL

///|
/// The guide (tokenGuide: its steps 18 apart).
// kept across runs: a value (no field of it changes)
let sa_guide : @ui.Style = @ui.css("w=Full gap=S4_5")

///|
// kept across runs: a value (no field of it changes)
let sa_step : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let sa_step_body : @ui.Style = @ui.style(w=@sf.grow, gap=S1, align=AStart)

///|
/// The token's line (inputRow: the field as wide as is left, its button after it, 8 apart, 6 under the words).
// kept across runs: a value (no field of it changes)
let sa_input_row : @ui.Style = @ui.css("row w=Full pt=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sa_input_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
/// Slack asking for approval (callout blue: 12 by 14 in, 10 apart, a corner of 14, in the blue's ink).
// kept across runs: a value (no field of it changes)
let sa_blue : @ui.Style = @ui.css("row w=Full px=S3_5 py=S3 gap=S2_5 radius=Xl1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sa_blue_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)

///|
/// Its look (appLook: the avatar 136 and the rest, 16 apart; appLookMain: 8 apart; appColour: 8 apart, the swatch 28,
/// the hex field 96).
// kept across runs: a value (no field of it changes)
let sa_look : @ui.Style = @ui.css("row w=Full gap=S4 align=AStretch")

///|
// kept across runs: a value (no field of it changes)
let sa_avatar : @ui.Style = @ui.css("w=S32 h=S32 radius=Xl3 clip border=B1 border_color=Line align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let sa_avatar_empty : @ui.Style = @ui.css("gap=S1 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let sa_look_main : @ui.Style = @ui.style(w=@sf.grow, gap=S2)

///|
// kept across runs: a value (no field of it changes)
let sa_colour : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sa_swatch : @ui.Style = @ui.css("w=S7 h=S7 radius=Lg border=B1 border_color=Border")

///|
// kept across runs: a value (no field of it changes)
let sa_hex : @ui.Style = @ui.css("w=S24")

///|
// kept across runs: a value (no field of it changes)
let sa_picker : @ui.Style = @ui.css("w=Full pt=S4 pb=S2_5 gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let sa_picker_row : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let sa_tile : @ui.Style = @ui.css("radius=Lg clip border=B1 border_color=Line align=ACenter justify=JCenter hovered{border_color=FieldHover}")

///|
/// A tile under the pointer (sa_tile's hovered, as a node takes it).
// kept across runs: a value (no field of it changes)
let sa_tile_lit : @ui.Style = sa_tile.then(@ui.css("border_color=FieldHover"))

///|
// kept across runs: a value (no field of it changes)
let sa_tile_on : @ui.Style = sa_tile.then(@ui.css("border=B2 border_color=Fg"))

///|
/// What the avatar says while it has no picture (keep, upload: a note's words, in what reads on its colour), and 需管理员
/// beside a group only admins allow (a note's words): the dialog's look and the page's alike.
// kept across runs: a value (no field of it changes)
let sa_avatar_words : @ui.TextStyle = desk_note

///|
// kept across runs: a value (no field of it changes)
let sa_admin_words : @ui.TextStyle = desk_note

///|
/// The permissions (appPerms: the ui's 13; its line muted, 6 down; permSections 4 apart, 8 under it; a section's head
/// its title (h4) and its toggle; permGrid three to a line, 8 apart).
// kept across runs: a value (no field of it changes)
let sa_perms : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let sa_perms_line : @ui.Style = @ui.css("row w=Full py=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sa_perms_summary : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sa_perm_sections : @ui.Style = @ui.css("w=Full pt=S2 gap=S1")

///|
// kept across runs: a value (no field of it changes)
let sa_perm_section : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let sa_perm_head : @ui.Style = @ui.css("row w=Full pt=S2 gap=S2 align=ACenter justify=JBetween")

///|
// kept across runs: a value (no field of it changes)
let sa_perm_title : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Semibold, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sa_perm_row : @ui.Style = @ui.css("row w=Full gap=S2")

///|
/// A group (modelPoolItem: a third of the line, 32 high, 8 by 6 in, 8 apart, the pointer's ground on it).
// kept across runs: a value (no field of it changes)
let sa_perm_item : @ui.Style = @ui.style(w=@sf.grow).then(@ui.css("row h=S8 px=S2 gap=S2 radius=Lg align=ACenter hovered{bg=Hover}"))

///|
// kept across runs: a value (no field of it changes)
let sa_perm_label : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let sa_perm_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false)

///|
/// What a fold's line says beside its title (the ui's 13 muted, in a line).
// kept across runs: a value (no field of it changes)
let sa_perms_said : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)
