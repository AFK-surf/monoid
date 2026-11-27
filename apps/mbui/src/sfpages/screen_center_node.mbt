// 控制中心 (screen_panel.mbt's center_open) and 按键 (keys_open) as nodes of the window's tree, made once in the panel
// its presenter gives it (@sf.panel_nodes: a sheet from the foot on 小屏, a panel beside what opened it on 中屏 and
// 大屏), each part following what it shows as that is told: the view's state (ScreenSess's `said`), the prefs, the
// link's figures, how long it has been seen, its sound and the stage's size (ScreenSess's and ScreenUi's signals).
// 控制中心 is what is done with the view and how its picture is asked, short enough to need no scrolling; the keys are
// 按键's, an entry of their own by the keyboard (pengxiao, 2026-11-12: 「常用键就不应该放控制中心，应该是个单独入口」).

///|
/// What 控制中心 holds in `v`: 快捷操作, tiles each there only where it applies (全屏, 粘贴, 发送文件, 静音, 麦克风, 触控板, 在新窗口打开),
/// a toggle lit while on; 画面, a row each for 画质, 帧率 and (where the station changes them) 缩放 and 分辨率, its choice at
/// its end, pressed its choices beside it; then 连接 (a step further in: the view's figures), who else is on it, 结束其他查看
/// and 断开. `from` what opened it; `done` closes it.
fn center_node(
  v : @view.View,
  s : ScreenSess,
  u : ScreenUi,
  from : @sf.Anchor,
  close : () -> Unit,
  done : () -> Unit,
) -> Unit {
  let src = s.src
  // (what reads the view's state reads it again as another is taken)
  let state = fn() {
    s.said.get() |> ignore
    s.state
  }
  // in a window of its own (a desktop's), as the web's ScreenPage: it leaves this one, so it is not open twice; the
  // page it is, its title and whether it goes once its screen is gone
  let alone : @sfbase.Page = Screen(u.at.unwrap_or({ station: s.station, screen: s.screen, title: "", until_gone: false }))
  let window = @sfbase.window_opens_for(alone)
  let tiles = fn() {
    state() |> ignore
    let ts : Array[String] = []
    if s.open_now() {
      ts.push("full")
    }
    // (a simulator's: a browser's tab has its address bar and ⟳ over its page, screen_browser.mbt)
    if s.opens_url() && !browser_shown(s) {
      ts.push("go")
      ts.push("reload")
    }
    // a browser's tab where its bar is narrow: → and ⟳ here while driving, ← and the address bar on it
    if browser_shown(s) && s.opens_url() && u.narrow_bar {
      ts.push("forward")
      ts.push("reload")
    }
    if s.pastes() {
      ts.push("paste")
    }
    if s.drops_to() is Some(_) {
      ts.push("send")
    }
    if s.audio_ready.get() {
      ts.push("mute")
    }
    // (driving a screen with a virtual microphone: this device's shared into it, on while lit)
    if s.mic_available() {
      ts.push("mic")
    }
    // (touch's: with a mouse it is the screen's pointer; a simulator is touched where it is)
    if @sf.soft_keyboard() && s.driving() && !s.simulator() {
      ts.push("pad")
    }
    if window {
      ts.push("window")
    }
    ts
  }
  v.show(fn() { tiles().length() > 0 }, fn(q) {
    @sf.panel_group_node(q, fn() { @sf.t("web-pages.screen.quick") }, fn(g) {
      g.pick(tiles, fn(b, ids) {
        tiles_node(b, ids.length(), 3, tile_gap, fn(row, i) {
          match ids[i] {
            "full" =>
              quick_tile_node(
                row,
                fn() { @sf.t(if full_now(u) { "android-misc.screen.unfull" } else { "android-misc.screen.full" }) },
                fn() { if full_now(u) { "shrink" } else { "expand" } },
                fn() { full_now(u) },
                fn() {
                  full_asked(u)
                  done()
                },
              )
            "go" =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.goUrlShort") }, fn() { "link" }, fn() { false }, fn() {
                done()
                go_url_asked(s, from)
              })
            "forward" =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.forward") }, fn() { "arrow-right" }, fn() { false }, fn() {
                browser_act(s, "screen.forward", @sf.t("web-pages.screen.forwardWhat"))
                done()
              })
            "reload" =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.reloadShort") }, fn() { "refresh" }, fn() { false }, fn() {
                reload_asked(s)
                done()
              })
            "paste" =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.paste") }, fn() { "paste" }, fn() { false }, fn() {
                paste_asked(s, u)
                done()
              })
            "send" =>
              quick_tile_node(row, fn() { @sf.t("android-misc.screen.sendFile") }, fn() { "upload" }, fn() { false }, fn() {
                done()
                send_asked(s)
              })
            "mute" =>
              quick_tile_node(
                row,
                fn() { @sf.t(if s.audio_muted.get() { "web-pages.drive.player.unmute" } else { "web-pages.drive.player.mute" }) },
                fn() { if s.audio_muted.get() { "volume-x" } else { "volume" } },
                fn() { s.audio_muted.get() },
                fn() { s.toggle_audio() },
              )
            "mic" =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.mic") }, fn() { s.mic_icon() }, fn() { s.mic_on.get() }, fn() {
                s.toggle_mic()
              })
            "pad" =>
              {
                // (lit as it is chosen, by ScreenSess::pad_set: what is chosen is told the core after this press,
                // ScreenSess::choose_pad)
                quick_tile_node(
                  row,
                  fn() { @sf.t("android-misc.screen.trackpad") },
                  fn() { "trackpad" },
                  fn() {
                    state() |> ignore
                    s.pad(src)
                  },
                  fn() {
                    let on = !s.pad(src)
                    s.pad_set.set(Some(on))
                    pad_chosen(s, u, on)
                  },
                )
              }
            _ =>
              quick_tile_node(row, fn() { @sf.t("web-pages.screen.window") }, fn() { "external" }, fn() { false }, fn() {
                done()
                if @sfbase.open_window(alone) {
                  close()
                }
              })
          }
        })
      })
    })
  })
  @sf.panel_group_node(v, fn() { @sf.t("web-pages.screen.picture") }, fn(g) {
    let quality_now = fn() {
      let quality = screen_quality(src)
      screen_qualities.search_by(fn(q) { q.0 == quality }).unwrap_or(0)
    }
    center_choice_node(
      g,
      "web-pages.screen.quality",
      fn() { @sf.t("web-pages.screen.quality." + screen_qualities[quality_now()].1) },
      fn() {
        screen_qualities.map(fn(q) {
          @sf.choice(q.1, @sf.t("web-pages.screen.quality." + q.1), note=@sf.t("web-pages.screen.qualityHint." + q.1))
        })
      },
      fn() { screen_qualities[quality_now()].1 },
      fn(k) {
        match screen_qualities.search_by(fn(q) { q.1 == k }) {
          Some(i) => prefs_chosen(s, "screenQuality", screen_qualities[i].0)
          None => ()
        }
      },
    )
    // 码率 ceiling (自动: encoder adapts to picture & link; explicit Mbps caps max bitrate)
    center_choice_node(
      g,
      "web-pages.screen.bitrate",
      fn() { bitrate_choice_words(screen_bitrate(src)) },
      fn() { screen_bitrate_choices.map(fn(m) { @sf.choice("\{m}", bitrate_choice_words(m), note=bitrate_note(m)) }) },
      fn() { "\{screen_bitrate(src)}" },
      fn(k) {
        match screen_bitrate_choices.search_by(fn(m) { "\{m}" == k }) {
          Some(i) => {
            let m = screen_bitrate_choices[i]
            prefs_set(s, "screenBitrate", "\{m}", if m == 0 { Json::null() } else { Json::number(m.to_double()) })
          }
          None => ()
        }
      },
    )
    // the most frames a second (自动: as many as the station and the link give)
    let fps_words = fn(f : Int) { if f == 0 { @sf.t("web-pages.screen.fps.auto") } else { "\{f}" } }
    center_choice_node(
      g,
      "web-pages.screen.fps",
      fn() { fps_words(screen_fps(src)) },
      fn() { screen_fps_choices.map(fn(f) { @sf.choice("\{f}", fps_words(f), note=fps_note(f)) }) },
      fn() { "\{screen_fps(src)}" },
      fn(k) {
        match screen_fps_choices.search_by(fn(f) { "\{f}" == k }) {
          Some(i) => {
            let f = screen_fps_choices[i]
            prefs_set(s, "screenFps", "\{f}", if f == 0 { Json::null() } else { Json::number(f.to_double()) })
          }
          None => ()
        }
      },
    )
    // 4:4:4 chroma: independent toggle when Apple VideoToolbox can decode H.265 4:4:4 from an Apple host
    g.show(
      fn() {
        if !screen_decodes_444() {
          return false
        }
        let low = screen_os(src, s.station).to_lower()
        low == "" || low.has_prefix("mac") || low.has_prefix("darwin")
      },
      fn(c) {
        @sf.panel_switch_row_node(
          c,
          fn() { @sf.t("web-pages.screen.chroma444") },
          fn() { screen_chroma444(src) },
          fn(on) { prefs_set(s, "screenChroma444", if on { "true" } else { "" }, if on { Json::boolean(true) } else { Json::null() }) },
          note=fn() { @sf.t("web-pages.screen.chroma444Note") },
        )
      },
    )
    // 受控端显示: remote system display resolution & scale grouped in a sub-panel so stream resolution isn't confused with changing host display
    let has_host_display = fn() {
      state() |> ignore
      s.resolution() is Some(_) || s.scale() is Some(_)
    }
    g.show(has_host_display, fn(hd) {
      @sf.panel_row_node(
        hd,
        fn() { @sf.t("web-pages.screen.hostDisplay") },
        fn() {
          done()
          host_display_panel_open(s, u, from)
        },
        note=fn() {
          state() |> ignore
          host_display_summary(s)
        },
        end="chevron-right",
      )
    })
  })
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    // 只看: off the viewer's bar (the user, 2026-11-13), the view drives it unless this is on; while someone else drives
    // it, 接管 on the bar instead
    g.show(fn() { state() |> ignore; s.choosable() && !s.can_take_over() }, fn(m) {
      @sf.panel_switch_row_node(m, fn() { @sf.t("android-misc.screen.look") }, fn() {
        state() |> ignore
        !s.controlling()
      }, fn(on) { control_chosen(s, u, !on) })
    })
    // 跨系统快捷键映射: shown when driving across Apple ↔ Windows/Linux/Android with a hardware keyboard (default on)
    g.show(fn() { state() |> ignore; !@sf.soft_keyboard() && s.driving() && screen_cross_os(s) }, fn(m) {
      @sf.panel_switch_row_node(
        m,
        fn() { @sf.t("web-pages.screen.keyMap") },
        fn() { screen_key_map_on(src) },
        fn(on) { prefs_chosen(s, "screenKeyMap", if on { "" } else { "off" }) },
        note=fn() {
          @sf.t(if screen_local_apple() == Some(true) { "web-pages.screen.keyMapNoteMac" } else { "web-pages.screen.keyMapNote" })
        },
      )
    })
    // ⌃ 保留为 Ctrl: shown on Mac/iPad driving Windows/Linux/Android while cross-OS shortcuts are on (default on so
    // terminal ⌃C/⌃D stay Ctrl instead of triggering Win; off maps ⌃ → Win)
    g.show(
      fn() {
        state() |> ignore
        !@sf.soft_keyboard() && s.driving() && screen_swaps_ctrl_meta(s) && screen_local_apple() == Some(true)
      },
      fn(m) {
        @sf.panel_switch_row_node(
          m,
          fn() { @sf.t("web-pages.screen.keepCtrl") },
          fn() { screen_keep_ctrl_on(src) },
          fn(on) { prefs_chosen(s, "screenKeepCtrl", if on { "" } else { "off" }) },
          note=fn() { @sf.t("web-pages.screen.keepCtrlNote") },
        )
      },
    )
    // 手柄: virtual controller driver status & opt-in mouse emulation (shown while driving a station that reports gamepad state)
    g.show(fn() { state() |> ignore; s.gamepad() is Some(_) }, fn(gp) {
      @sf.panel_row_node(
        gp,
        fn() { @sf.t("web-pages.screen.gamepad") },
        fn() {
          done()
          gamepad_panel_open(s, from)
        },
        icon=fn() { "devices" },
        note=fn() {
          state() |> ignore
          match s.gamepad() {
            Some((native, driver, _)) => gamepad_status_words(native, driver, gamepad_mouse_now(s, src))
            None => ""
          }
        },
        end="chevron-right",
      )
    })
    // how the view goes: live, its round trip and how long it has been seen; pressed, its figures a step further in;
    // who else is on it, as the core says it, its note
    g.show(fn() { state() |> ignore; s.phase() == "live" }, fn(l) {
      @sf.panel_row_node(
        l,
        fn() { @sf.t("web-pages.screen.stats") },
        fn() {
          done()
          net_panel_open(s, u, from, stepped=true)
        },
        icon=fn() { "chart" },
        note=fn() {
          state() |> ignore
          let rtt = text(field(screen_net(s), "rtt"), "text")
          if rtt == "" { seen_for(u) } else { rtt + " · " + seen_for(u) }
        },
        end="chevron-right",
      )
    })
    g.show(fn() { items(state(), "others").length() > 0 && text(state(), "line") != "" }, fn(p) {
      @sf.panel_note_node(p, fn() { text(state(), "line") })
    })
  })
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    // its other views, this person's on other devices and others' alike
    let others = fn() { items(state(), "otherViews") }
    g.show(fn() { others().length() > 0 }, fn(e) {
      @sf.panel_row_node(e, fn() { @sf.t("web-pages.screen.endOthers", args=[("count", others().length().to_string())]) }, fn() {
        if !s.is_active_principal() {
          done()
          return
        }
        for o in @signals.untracked(others) {
          let params = Map([("station", Json::string(s.station)), ("screen", Json::string(s.screen)), ("view", Json::string(text(Some(o), "id")))])
          (src.call)("screen.endView", Json::object(params), @sfbase.answer_unread)
        }
        done()
      }, icon=fn() { "eye-off" })
    })
    // (断开 a group of its own, the last, a line over it)
    @sf.panel_rule_node(g)
    @sf.panel_row_node(g, fn() { @sf.t("web-pages.screen.leave") }, fn() {
      done()
      close()
    }, icon=fn() { "close" }, danger=true)
  })
}

///|
/// 受控端显示 sub-panel body: note explaining that these modify the remote system display and restore on disconnect,
/// followed by remote resolution and remote scale choices.
fn host_display_node(v : @view.View, s : ScreenSess, u : ScreenUi) -> Unit {
  let src = s.src
  let state = fn() {
    s.said.get() |> ignore
    s.state
  }
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    @sf.panel_note_node(g, fn() { @sf.t("web-pages.screen.hostDisplayNote") })
    let resolution = fn() {
      state() |> ignore
      match s.resolution() {
        Some((size, all)) => {
          let fitting = resolution_fitting(all, u.box_w.get(), u.box_h.get())
          Some((size, all, fitting, resolution_shown(all, size, fitting)))
        }
        None => None
      }
    }
    g.show(fn() { resolution() is Some(_) }, fn(r) {
      center_choice_node(
        r,
        "web-pages.screen.resolution",
        fn() {
          match resolution() {
            Some(((w, h), _, _, _)) => "\{w}×\{h}"
            None => ""
          }
        },
        fn() {
          match resolution() {
            Some((_, all, fitting, modes)) =>
              modes.map(fn(m) {
                let size = "\{m.0}×\{m.1}"
                let words = if fitting >= 0 && m == all[fitting] {
                  @sf.t("web-pages.screen.resolutionMark", args=[("size", size)])
                } else {
                  size
                }
                @sf.choice("\{m.0}x\{m.1}", words)
              })
            None => []
          }
        },
        fn() {
          match resolution() {
            Some(((w, h), _, _, _)) => "\{w}x\{h}"
            None => ""
          }
        },
        fn(k) {
          match @signals.untracked(resolution) {
            Some((_, _, _, modes)) =>
              match modes.search_by(fn(m) { "\{m.0}x\{m.1}" == k }) {
                Some(i) => {
                  let (w, h) = modes[i]
                  s.input(src, { "t": Json::string("resolution"), "width": Json::number(w.to_double()), "height": Json::number(h.to_double()) })
                }
                None => ()
              }
            None => ()
          }
        },
      )
    })
    let scale = fn() {
      state() |> ignore
      s.scale()
    }
    g.show(fn() { scale() is Some(_) }, fn(sc) {
      center_choice_node(
        sc,
        "web-pages.screen.scale",
        fn() {
          match scale() {
            Some((percent, _, _)) => "\{percent}%"
            None => ""
          }
        },
        fn() {
          match scale() {
            Some((_, recommended, steps)) =>
              steps.map(fn(p) {
                @sf.choice("\{p}", if p == recommended { @sf.t("web-pages.screen.scaleRecommended", args=[("percent", "\{p}")]) } else { "\{p}%" })
              })
            None => []
          }
        },
        fn() {
          match scale() {
            Some((percent, _, _)) => "\{percent}"
            None => ""
          }
        },
        fn(k) {
          match @signals.untracked(scale) {
            Some((_, _, steps)) =>
              match steps.search_by(fn(p) { "\{p}" == k }) {
                Some(i) => s.input(src, Json::object({ "t": Json::string("scale"), "percent": Json::number(steps[i].to_double()) }))
                None => ()
              }
            None => ()
          }
        },
      )
    })
  })
}

///|
/// 手柄 sub-panel body: host virtual controller driver status note and opt-in mouse/keyboard emulation switch.
fn gamepad_node(v : @view.View, s : ScreenSess) -> Unit {
  let src = s.src
  let state = fn() {
    s.said.get() |> ignore
    s.state
  }
  @sf.panel_group_node(v, fn() { "" }, fn(g) {
    @sf.panel_note_node(g, fn() {
      state() |> ignore
      let driver = match s.gamepad() {
        Some((_, d, _)) => d
        None => ""
      }
      gamepad_driver_note(driver, screen_os(src, s.station))
    })
    @sf.panel_switch_row_node(
      g,
      fn() { @sf.t("web-pages.screen.gamepadMouse") },
      fn() {
        state() |> ignore
        gamepad_mouse_now(s, src)
      },
      fn(on) {
        s.gamepad_mouse_set.set(Some(on))
        prefs_set(s, "screenGamepadMouse", if on { "true" } else { "" }, if on { Json::boolean(true) } else { Json::null() })
        s.input(src, Json::object({ "t": Json::string("gamepadMode"), "mouse": Json::boolean(on) }))
      },
      note=fn() { @sf.t("web-pages.screen.gamepadMouseNote") },
    )
  })
}

///|
/// A choice of 控制中心's in `parent` (串流分辨率, 码率, 帧率, 缩放, 分辨率): a panel's row, its name (`name`, a key of the words) at its
/// start, what is chosen now (`value`) at its end before a chevron; pressed, its `choices` through the presenters
/// (@sf.pick) beside it (a sheet on 小屏), the one `chosen` checked, each with what it means under it; `choose` given the
/// key of the one chosen.
fn center_choice_node(
  parent : @view.View,
  name : String,
  value : () -> String,
  choices : () -> Array[@sf.Choice],
  chosen : () -> String,
  choose : (String) -> Unit,
) -> Unit {
  @sf.panel_row_opens_node(parent, fn() { @sf.t(name) }, fn(from) {
    let beside : @sf.Beside = match from {
      Node(r) => Node(r)
      At(x, y, w, h) => At(x, y, w, h)
      Unanchored => return
    }
    @sf.pick(@sf.t(name), @signals.untracked(choices), @signals.untracked(chosen), choose, from=beside, search=false)
  }, note=value)
}

///|
/// A tile of 快捷操作 in `row` (the combos' look: its icon over its name), named and drawn as `label` and `icon` are now;
/// lit (the ink's ground, its words and icon on it) while `lit`, read out pressed then; `press` as it is pressed.
fn quick_tile_node(
  row : @view.View,
  label : () -> String,
  icon : () -> String,
  lit : () -> Bool,
  press : () -> Unit,
) -> Unit {
  @sf.action_box_node(row, label, on=lit, fn(_) { press() }, fn(t) {
    @sf.style_node(t, fn() {
      let look = if lit() { tile_box.then(tile_lit) } else { tile_box }
      if t.pressed() { look.then(tile_pressed) } else { look }
    }, in_row=true)
    let ink = fn() { @ui.tree_theme().color(if lit() { Bg } else { Fg }) }
    @sf.icon_node(t, "", round_icon, By(ink), name_now=icon) |> ignore
    // (cut short where a tile has not the room for its name, at the system's larger words)
    @sf.words_node(t, label, fn() { if lit() { tile_lit_words } else { tile_words } }).allow_ellipsis(Is(true)) |> ignore
  })
  |> ignore
}

///|
/// What 按键 holds in `v`: 组合键 (the screen's system's) as tiles, then F1–F12 and the keys the keys row has not; it
/// stays open as each is pressed (F5, Page Down… are pressed again and again). `combos_only`: 组合键 alone, its title
/// the panel's (with keyboard and mouse: the keyboard has the rest).
fn keys_node(v : @view.View, s : ScreenSess, u : ScreenUi, combos_only : Bool) -> Unit {
  @sf.panel_group_node(v, fn() { if combos_only { "" } else { @sf.t("web-pages.screen.combos") } }, fn(g) {
    g.pick(fn() { screen_os(s.src, s.station) }, fn(b, os) { combo_tiles_node(b, s, u, combos_for(os)) })
  })
  if !combos_only {
    @sf.panel_group_node(v, fn() { @sf.t("web-pages.screen.commonKeys") }, fn(g) { key_tiles_node(g, s, u) })
  }
  v.box(fn(f) { @sf.style_node(f, fn() { keys_foot }) }) |> ignore
}

///|
/// The combos as tiles in `parent`, three to a row: an icon over its name (what it does, not its keys: a phone has no
/// keys to press for it), a tap sending its keys down and up with the modifiers the keys row holds too.
fn combo_tiles_node(parent : @view.View, s : ScreenSess, u : ScreenUi, combos : Array[Combo]) -> Unit {
  tiles_node(parent, combos.length(), 3, tile_gap, fn(row, i) {
    let k = combos[i]
    center_tile_node(row, tile_box, k.name, fn() {
      stroke(fn(j) { s.input(s.src, j) }, k.key, k.code, k.mods | u.held.take())
    }, fn(t) {
      @sf.icon_node(t, k.icon, round_icon, By(fn() { @ui.tree_theme().color(Fg) })) |> ignore
      @sf.words_node(t, fn() { k.name }, fn() { tile_words }).allow_ellipsis(Is(true)) |> ignore
    })
  })
}

///|
/// The keys of `screen_panel_keys` as small tiles in `parent`, six to a row, a tap sending the key down and up with the
/// modifiers the keys row holds.
fn key_tiles_node(parent : @view.View, s : ScreenSess, u : ScreenUi) -> Unit {
  let keys = screen_panel_keys
  tiles_node(parent, keys.length(), 6, key_tile_gap, fn(row, i) {
    let (label, key) = keys[i]
    center_tile_node(row, key_tile_box, label, fn() {
      let mods = u.held.take()
      stroke(fn(j) { s.input(s.src, j) }, key, key, mods)
    }, fn(t) {
      @sf.words_node(t, fn() { label }, fn() { key_tile_words }) |> ignore
    })
  })
}

///|
/// `count` tiles in `parent`, `per` to a row, 8 apart, in by a panel row's padding, each made by `tile` in its row; the
/// last row's left as wide as the others (`gap`).
fn tiles_node(parent : @view.View, count : Int, per : Int, gap : @ui.Style, tile : (@view.View, Int) -> Unit) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { tiles_box })
    for r in 0..<((count + per - 1) / per) {
      b.box(fn(row) {
        @sf.style_node(row, fn() { tiles_row })
        for i in (r * per)..<(r * per + per) {
          if i >= count {
            row.box(fn(g) { @sf.style_node(g, fn() { gap }, in_row=true) }) |> ignore
          } else {
            tile(row, i)
          }
        }
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// A tile in `row` (`look`: tile_box's, key_tile_box's), its ground the hover's while pressed, read out a button named
/// `label`, `press` as it is pressed; what is on it made by `face`.
fn center_tile_node(row : @view.View, look : @ui.Style, label : String, press : () -> Unit, face : (@view.View) -> Unit) -> Unit {
  @sf.action_box_node(row, fn() { label }, fn(_) { press() }, fn(t) {
    @sf.style_node(t, fn() { if t.pressed() { look.then(tile_pressed) } else { look } }, in_row=true)
    face(t)
  })
  |> ignore
}
