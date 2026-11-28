// 快捷键, one page made once on every screen: each action
// of the core's keymap (the prefs' `keymap`) gets new keys by pressing them (`keys.set`). ⌘/'s list of them is the
// shell's (sfdesk shortcuts.mbt keys_dialog_node).

///|
/// An action's keys changed (`keys.set`: none, its own again; no action, every one's), what the core says of it
/// (keys another action had, moved here) said.
fn set_keys(core : Core, action : String?, keys : Json) -> Unit {
  let params = match action {
    Some(a) => obj([("action", str(a)), ("keys", keys)])
    None => obj([])
  }
  (core.call)("keys.set", params, fn(r) {
    match r {
      Ok(v) =>
        match text(Some(v), "said") {
          "" => ()
          said => (core.say)(said)
        }
      Err(_) => ()
    }
  })
}

///|
/// 快捷键 made once as nodes of the window's tree (page_node, laid out by the `width` its
/// frame gives it, narrow where none is given): first how a message is sent (Enter, or ⌘Enter: the prefs' `sendKey`,
/// the keys of both said under it), then each group of the core's keymap a section, its actions' rows
/// (keys_rows_node), what the keys do said under the first, and 全部恢复默认 there once any was changed. An action's
/// keys pressed, the next key press is its new keys: Esc leaves them, ⌫ clears them, keys another action had are moved
/// here (the core says so); pressed again, or this page no longer the one on top of its stack (`active`: another put
/// over it, it gone back off), it records none. 恢复默认 an action's own again. Kept on this device. What it says of
/// itself told `said`. Under how a message is sent, at the top of the keys' list, the field to look through them by: its words find the actions whose name or keys in
/// words hold them; its keyboard key at its end (按键搜索), pressed, has each key press after it said there as a key
/// cap shows it, finding the actions those keys do, till Esc or the key again (the window's keys stand aside meanwhile,
/// as while an action records). A group none of whose actions is found is not shown; nothing found, that said.
pub fn shortcuts_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  active~ : () -> Bool,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  // (what this page records, while it is the one that does: another made of the same page its own)
  keys_recorders.val += 1
  let me = keys_recorders.val
  let win_id = @ui.current_window_id()
  let record = fn(action : String) {
    keys_recorder.val = me
    @settings.keys_recording_window.set(win_id)
    keys_recording.set(action)
  }
  let stop = fn() {
    if keys_recorder.val == me {
      keys_recorder.val = 0
      @settings.keys_recording_window.set(0)
      keys_recording.set("")
    }
  }
  let prefs = fn() { (core.topic)("prefs", Map([])).get().value }
  let keymap = fn() { field(prefs(), "keymap") }
  let listed = fn() { key_actions(prefs()).filter(fn(a) { flag(Some(a), "listed") }) }
  let groups = fn() { items(keymap(), "groups") }
  let any = fn() { listed().iter().any(fn(a) { flag(Some(a), "changed") }) }
  // what is looked for: the field's words, or the keys pressed (`by_keys`, a binding: Shift+Mod+H) while it says them
  let query = @ui.Field::new()
  let by_keys : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
  let searching_keys = fn() { keys_recording.get() == keys_searching && keys_recorder.val == me }
  let looked = fn() { by_keys.get() != "" || query.text().trim(chars=" \t\n").to_owned() != "" }
  let found = fn(a : Json) -> Bool {
    let keys = by_keys.get()
    if keys != "" {
      return strings(Some(a), "keys").contains(keys)
    }
    // (each word typed, apart by spaces, in its name or what its keys say in words)
    let said = (text(Some(a), "name") + " " + text(Some(a), "text")).to_lower()
    for w in query.text().to_lower().split(" ") {
      for w in w.split("\u{3000}") {
        let w = w.trim(chars="\t\n").to_owned()
        if w != "" && !said.contains(w) {
          return false
        }
      }
    }
    true
  }
  let shown_in = fn(group : String) {
    listed().filter(fn(a) { text(Some(a), "group") == group && found(a) })
  }
  // how the composer sends: one of two ways (`sendKey`), not keys of its own
  let send = fn() { field(keymap(), "send") }
  let sending = fn(v : @view.View) {
    @sf.setting_choice_node(
      v,
      fn() { @sf.t("web-main.shortcuts.sending") },
      fn() { items(send(), "choices").map(fn(c) { text(Some(c), "name") }) },
      fn() {
        let cs = items(send(), "choices")
        if cs.is_empty() {
          0
        } else {
          let cur = text(send(), "by")
          cs.search_by(fn(c) { text(Some(c), "by") == cur }).unwrap_or(0)
        }
      },
      fn(i) {
        let by = text(@signals.untracked(fn() { items(send(), "choices") }).get(i), "by")
        @settings.set_pref(core, "sendKey", if by == "mod" { "mod" } else { "" })
      },
      note=fn() { text(send(), "text") },
      alone=true,
    )
  }
  // (the next key press, while one records: none of it anything else's (pressed, window_zoom's stand aside))
  v.on_key(fn(k) {
    let recording = keys_recording.untracked()
    if recording == "" || keys_recorder.val != me {
      return false
    }
    if k.code == @ui.key_escape && k.mods == 0 {
      stop()
      return true
    }
    // (looking by the keys pressed: each press the keys looked for, said in the field as a key cap shows them)
    if recording == keys_searching {
      return match binding_of(k.code, k.mods) {
        Some(b) => {
          by_keys.set(b)
          query.set(binding_label(b))
          true
        }
        None => false
      }
    }
    // ⌫: none
    if k.code == 1 && k.mods == 0 {
      stop()
      set_keys(core, Some(recording), Json::array([]))
      return true
    }
    match binding_of(k.code, k.mods) {
      Some(b) => {
        stop()
        set_keys(core, Some(recording), Json::array([Json::string(b)]))
        true
      }
      // (a modifier alone: the keys still to come)
      None => false
    }
  })
  |> ignore
  // (no longer on top of its stack, parked/covered, or let go: what it records, none; another's left as it is)
  v.reacts(active, fn(on) { if !on { stop() } })
  v.on_rest(stop, while_covered=true) |> ignore
  v.owns(stop) |> ignore
  @sf.page_node(
    v,
    fn() { @sf.t("web-main.shortcuts.title") },
    fn() {
      // (how a message is sent first, apart from the keys: a core before the choice says none; then the field to look
      // through the keys by, at the top of their list)
      let keys = []
      if send() is Some(_) {
        keys.push("send")
      }
      let top = keys.length()
      keys.push("search")
      groups().eachi(fn(i, g) {
        let group = text(Some(g), "group")
        if shown_in(group).length() > 0 {
          keys.push("\{i}/" + group)
        }
      })
      if keys.length() == top + 1 && looked() {
        keys.push("none")
      }
      keys
    },
    fn(b, key) {
      match key {
        "search" => {
          shortcuts_search_node(b, query, fn() { by_keys.set("") }, searching_keys, stop, fn() {
            if searching_keys() {
              stop()
            } else {
              keys_recorder.val = me
              @settings.keys_recording_window.set(win_id)
              keys_recording.set(keys_searching)
            }
          })
          return
        }
        "send" => {
          sending(b)
          return
        }
        "none" => {
          @sf.empty_node(b, fn(e) {
            @sf.words_node(e, fn() { @sf.t("web-main.shortcuts.searchNone") }, fn() { shortcuts_none }) |> ignore
          })
          return
        }
        _ => ()
      }
      let i = @string.parse_int(key[:key.find("/").unwrap_or(0)]) catch { _ => 0 }
      let group = fn() { text(groups().get(i), "group") }
      let first = i == 0
      @sf.section_node(
        b,
        fn() { text(groups().get(i), "name") },
        fn(s) {
          @sf.keys_rows_node(s, fn(l) {
            l.each(fn() { shown_in(group()) }, fn(a) { text(Some(a), "action") }, fn(
              r,
              a,
            ) {
              let action = text(Some(a.untracked()), "action")
              @sf.keys_row_node(
                r,
                fn() { text(Some(a.get()), "name") },
                fn() { text(Some(a.get()), "text") },
                fn() { strings(Some(a.get()), "keys").length() == 0 },
                fn() { keys_recording.get() == action && keys_recorder.val == me },
                fn() {
                  if keys_recording.untracked() == action && keys_recorder.val == me {
                    stop()
                  } else {
                    record(action)
                  }
                },
                fn() { flag(Some(a.get()), "changed") },
                fn() { set_keys(core, Some(action), Json::null()) },
                fn() { @sf.t("web-main.shortcuts.reset") },
                fn() { @sf.t("web-main.shortcuts.recording") },
              )
            })
          })
        },
        about=fn() { if first { @sf.t("web-main.shortcuts.hint") } else { "" } },
        actions?=if first {
          Some((any, fn(a) { @sf.text_toggle_node(a, fn() { @sf.t("web-main.shortcuts.resetAll") }, fn() { set_keys(core, None, Json::null()) }) }))
        } else {
          None
        },
      )
    },
    on_back~,
    frame~,
    said?,
    width?,
  )
}

///|
/// 快捷键's field to look through its actions by in `parent` (@sf.search_input_node over `query`), `cleared` told as
/// the person changes its words (what the keys pressed said there is no longer what is looked for); beside it the
/// keyboard key (按键搜索), as tall as the field, lit while `searching` (the keys pressed are what is looked for), `press`
/// as it is pressed. The field given the focus, or its words changed or cleared, while the keys pressed are looked
/// for: that `stop`s, the field's to type in again. Escape in it: the keys' search stopped, else its words emptied.
fn shortcuts_search_node(
  parent : @view.View,
  query : @ui.Field,
  cleared : () -> Unit,
  searching : () -> Bool,
  stop : () -> Unit,
  press : () -> Unit,
) -> Unit {
  parent.box(fn(page) {
    @sf.style_node(page, fn() { shortcuts_search_page })
    page.box(fn(f) {
      // (the row's room but the key's, as narrow as that leaves it)
      f.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      // (while the keys pressed are what is looked for, it says so in its own place: the field takes no typing then)
      let words = fn() {
        cleared()
        if searching() {
          stop()
        }
      }
      let typed = @sf.search_input_node(
        f,
        query,
        fn() {
          if searching() {
            @sf.t("web-main.shortcuts.searchPressing")
          } else {
            @sf.t("web-main.shortcuts.search")
          }
        },
        edited=fn(_) { words() },
        cleared=words,
        escape=fn() {
          if searching() {
            stop()
            true
          } else if query.text() != "" {
            query.set("")
            cleared()
            true
          } else {
            false
          }
        },
      )
      // (the field come to again, by a press or Tab: the keys pressed no longer what is looked for)
      typed.reacts(fn() { typed.focused() }, fn(on) {
        if on && @signals.untracked(searching) {
          stop()
        }
      })
      |> ignore
    })
    |> ignore
    // (its sizes the native input's, the same all the run: read once, as the field's own clear key takes them)
    let l = @signals.untracked(fn() { @sf.theme().chat_list })
    let key : Ref[@view.View?] = Ref(None)
    key.val = Some(@sf.icon_button_node(
      page,
      "keyboard",
      fn() {
        if searching() {
          @sf.t("web-main.shortcuts.searchKeysStop")
        } else {
          @sf.t("web-main.shortcuts.searchKeys")
        }
      },
      fn() {
        press()
        // (the focus off the field, on the key, while the keys pressed are what is looked for: the field takes none)
        if searching() {
          key.val.map(fn(k) { k.ask_focus() }) |> ignore
        }
      },
      size=l.band_h,
      icon_size=l.band_icon,
      on=searching,
    ))
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let shortcuts_search_page : @ui.Style = @ui.css("row w=Full pb=S3 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let shortcuts_none : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
/// The page made once that records now (shortcuts_node's own count, what keys_recording says is its), and how many
/// were made.
// kept across runs: said as a page records; the count goes on
let keys_recorder : Ref[Int] = Ref(0)

///|
// kept across runs: it goes on counting
let keys_recorders : Ref[Int] = Ref(0)
