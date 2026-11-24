// V7 clean, effortless native still.fail font settings page built on `@sf.page_node`:
// - Zero `look_node` / `page-look` branching (pure flex-wrap responsive layout)
// - Calm sticky live chat preview (zero debug banners; clicking 界面/正文/代码 opens that role directly)
// - Compact 4-option style strip (title rendered in real preview font when loaded + download size in subtitle;
//   zero fake identical `Aa 字` banners)
// - Front-and-center native Reading Comfort card (`@sf.group_node`: 正文行距 + full-width flexible 正文阅读字号)
// - Native 3-row 字体搭配 settings card (`界面 / 正文 / 代码`) with clean ellipsized summaries (safe at 390pt × 1.3×);
//   tapping a row expands in-place with AT MOST ONE segmented bar visible at a time (`[西文 | 中文]` + `本机字体 ›` in
//   curated mode; `‹ 精选字体` + search + `[全部 | 仅中文 | 仅等宽]` in local mode)
// - Quiet collapsible advanced typography drawer (`@sf.group_node` with explicit `[界面 | 正文 | 代码]` scope picker
//   for CJK ratio, exact core-ts slider caps 110%/115%, and non-Web codeLigatures).

///|
fn font_slot_sample_key(place : String, is_cjk : Bool) -> String {
  if is_cjk {
    "web-pages.appearance.fonts.sampleCjk"
  } else if place == "code" {
    "web-pages.appearance.fonts.sampleCode"
  } else {
    "web-pages.appearance.fonts.sampleLatin"
  }
}

///|
fn font_role_sub_key(role_key : String) -> String {
  match role_key {
    "ui" => "web-pages.appearance.fonts.matrix.uiSub"
    "text" => "web-pages.appearance.fonts.matrix.textSub"
    _ => "web-pages.appearance.fonts.matrix.codeSub"
  }
}

///|
/// Capability check for local font browsing: short-circuits on hosts without local fonts (e.g. Web) so
/// `local_font_info_signal()` is never armed on Web.
fn can_show_local_fonts() -> Bool {
  let _ = local_open.get()
  let _ = @settings.fonts_at.get()
  let _ = @settings.fonts_script_at.get()
  if !@ui.can_list_local_fonts() {
    return false
  }
  let _ = @ui.local_font_info_signal()
  true
}

///|
fn fonts_page_v4_node(
  v : @view.View,
  core : Core,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let ctx : FontPageCtx = { core, }
  let scroll = @view.Scroll::list()
  let over_faces : @signals.Signal[Bool] = @signals.signal(false)
  if fx_local_up.val {
    fx_local_up.val = false
    @settings.fonts_at.set(0)
    font_picker_open.set(0)
    local_open.set(true)
  }
  v.owns(fn() { fonts_undo_snap.set(None) }) |> ignore
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.fonts.title") },
    fn() { ["presets", "reading", "fonts", "advanced"] },
    fn(col, key) {
      match key {
        "presets" => font_presets_strip_node(col, ctx)
        "reading" => font_reading_bar_node(col, ctx)
        "fonts" => font_roles_card_node(col, ctx, over_faces)
        _ => font_advanced_v6_node(col, ctx)
      }
    },
    on_back~,
    frame~,
    lead=fn() { @sf.t("web-pages.appearance.fonts.description") },
    actions=fn(row) { fonts_header_actions_node(row, ctx) },
    sticky_head=fn(room) {
      room.by_room(fn(held, r) {
        held.box(fn(cell) {
          let chat : Ref[@view.View?] = Ref(None)
          let tallest = Ref(0.0)
          cell.box(fn(card_host) {
            chat.val = Some(card_host)
            font_preview_v6_node(card_host, ctx)
          })
          |> ignore
          cell.min_height(By(fn() {
            match chat.val {
              Some(card_host) => {
                let tall = r.tall(card_host)
                let lock = over_faces.get() || preset_trying.get() >= 0 || cjk_scale_drag.get() is Some(_) ||
                  text_size_drag.get() is Some(_) || code_scale_drag.get() is Some(_)
                if lock {
                  tallest.val = dmax(tallest.val, tall)
                  Some(tallest.val)
                } else {
                  tallest.val = tall
                  None
                }
              }
              None => None
            }
          }))
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    said?,
    width?,
    scroll~,
  )
}

///|
fn fonts_header_actions_node(row : @view.View, ctx : FontPageCtx) -> Unit {
  row.show(at_once=true, fn() { fonts_undo_snap.get() is Some(_) }, fn(uw) {
    @sf.action_box_node(uw, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn(_) { ctx.undo_reset() }, fn(btn) {
      @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v6_reset_hot } else { fp_v6_reset } })
      @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn() { fp_v6_undo_words }) |> ignore
    })
    |> ignore
  })
  row.show(at_once=true, fn() { ctx.any_customized() }, fn(rw) {
    @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn(_) { ctx.reset_all() }, fn(btn) {
      @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v6_reset_hot } else { fp_v6_reset } })
      @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn() { fp_v6_reset_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// Calm, realistic sticky live chat preview (`p=S2` + `radius=10.0` exact concentric with `Xl2=18`).
fn font_preview_v6_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  let ui_face = fn() { ctx.ui_face() }
  let text_face = fn() { ctx.text_face() }
  let code_face = fn() { ctx.code_face() }
  let ui_cjk = fn() { ctx.cjk_override_for("ui") }
  let text_cjk = fn() { ctx.cjk_override_for("text") }
  let code_cjk = fn() { ctx.cjk_override_for("code") }
  let prose_scale = fn() { ctx.preview_prose_scale() }
  let code_scale = fn() { ctx.preview_code_scale() }
  let line_scale = fn() { ctx.preview_line_scale() }
  let open_role = fn(idx : Int) {
    fonts_trying.set("")
    @settings.fonts_at.set(idx)
    font_picker_open.set(idx)
  }
  let zone = fn(col : @view.View, role_idx : Int, role_key : String, body : (@view.View) -> Unit) {
    let active = fn() { font_picker_open.get() == role_idx }
    @sf.action_box_node(col, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn(_) { open_role(role_idx) }, fn(z) {
      @sf.style_node(z, fn() { fp_v6_zone })
      z.min_width(Is(Some(0.0))) |> ignore
      z.box(fn(bar) {
        bar.width(Is(Some(2.5))).shrink(Is(0.0)).radius(Is(2.0)).ground(By(fn() {
          if active() { @sf.theme().p.accent_text } else { 0L }
        })) |> ignore
      }) |> ignore
      z.box(fn(content) {
        content.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(3.0)) |> ignore
        body(content)
      }) |> ignore
    }) |> ignore
  }
  parent.box(fn(card) {
    @sf.style_node(card, fn() { fp_v6_preview_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    card.box(fn(top) {
      @sf.style_node(top, fn() { fp_v6_top_row })
      top.box(fn(bubble) {
        @sf.style_node(bubble, fn() { fp_v6_bubble })
        bubble.radius(Is(10.0)) |> ignore
        face_in_node(
          bubble,
          fn() { @sf.t("web-pages.appearance.fonts.sampleMine") },
          fn() { text_face().unwrap_or(0) },
          fp_v6_mine_words,
          person=fn() { text_face() is None },
          cjk=text_cjk,
          size_scale=prose_scale,
          line_scale~,
        ) |> ignore
      }) |> ignore
    }) |> ignore
    zone(card, 0, "ui", fn(c) {
      c.box(fn(who) {
        @sf.style_node(who, fn() { fp_v6_who_line })
        face_in_node(who, fn() { "Claude" }, ui_face, fp_v6_who_words, cjk=ui_cjk) |> ignore
        face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_v6_time_words, cjk=ui_cjk) |> ignore
      }) |> ignore
    })
    zone(card, 1, "text", fn(c) {
      @sf.markdown_node(
        c,
        fn() { @sf.t("web-pages.appearance.fonts.sampleText") },
        size=fn() { body_size * prose_scale() },
        copy=false,
        typography=fn() {
          { prose_scale: prose_scale(), code_scale: code_scale(), line_scale: line_scale(), text_cjk: text_cjk(), code_cjk: code_cjk() }
        },
        text_face~,
        code_face~,
      ) |> ignore
    })
    zone(card, 2, "code", fn(c) {
      c.box(fn(cb) {
        @sf.style_node(cb, fn() { fp_v6_code_box })
        cb.radius(Is(10.0)) |> ignore
        face_in_node(
          cb,
          fn() { fp_sample_code },
          fn() { code_face().unwrap_or(0) },
          fp_v6_code_words,
          cjk=code_cjk,
          size_scale=fn() { prose_scale() * code_scale() },
          line_scale~,
          mono=true,
        ) |> ignore
      }) |> ignore
    })
  }) |> ignore
}

///|
/// Compact 4-option curated style strip (4-col wide, auto 2x2 narrow; shows needed download size in subtitle).
fn font_presets_strip_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v6_presets_sec })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.presets") }, fn() { fp_v6_sec_heading }) |> ignore
    sec.box(fn(row) {
      @sf.style_node(row, fn() { fp_v6_preset_row })
      row.wraps(Is(Some(8.0))) |> ignore
      for i, preset in font_presets {
        let on = fn() { font_preset_matches(preset, fn(s) { ctx.chosen_of(s) }) }
        let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key) }
        let sub_with_size = fn() {
          let base = @sf.t("web-pages.appearance.fonts.preset." + preset.key + "Sub")
          let bytes = preset_needed_bytes(preset, ctx.all(), items(ctx.files_state(), "kept"), ctx.core.face_here)
          if bytes > 0.0 { base + " · " + face_size(bytes) } else { base }
        }
        row.box(fn(slot) {
          slot.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(148.0))).min_width(Is(Some(142.0))) |> ignore
          slot.reacts(fn() { @sf.lit_in_node(slot) }, fn(lit) {
            if lit { preset_trying.set(i) } else if preset_trying.untracked() == i { preset_trying.set(-1) }
          })
          slot.owns(fn() { if preset_trying.untracked() == i { preset_trying.set(-1) } }) |> ignore
          @sf.action_box_node(slot, title, fn(_) {
            clear_fonts_undo()
            @settings.set_fonts_preset(ctx.core, preset_patch(preset), reset_cjk_optics=true)
          }, fn(card) {
            @sf.style_node(card, fn() {
              if on() { fp_v6_preset_on } else if @sf.lit_node(card) { fp_v6_preset_hot } else { fp_v6_preset }
            })
            card.grow(Is(1.0)).edge(By(fn() {
              if on() { (1.0, @sf.theme().p.accent_text) } else { (0.5, @sf.theme().p.line) }
            })) |> ignore
            card.box(fn(top) {
              @sf.style_node(top, fn() { fp_v6_preset_top })
              @sf.words_node(top, title, fn() { if on() { fp_v6_preset_title_on } else { fp_v6_preset_title } }) |> ignore
              top.show(at_once=true, on, fn(chk) {
                @sf.icon_node(chk, "check", 14.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
              })
            }) |> ignore
            @sf.words_node(card, sub_with_size, fn() { fp_v6_preset_sub }) |> ignore
          }) |> ignore
        }) |> ignore
      }
    }) |> ignore
  }) |> ignore
}

///|
/// Native flexible slider control for `@sf.setting_node` rows (full width on narrow phones, compact 240pt cap wide).
fn fp_setting_slider_ctrl(
  r : @view.View,
  label : () -> String,
  value : () -> Double,
  min : Double,
  max : Double,
  step : Double,
  on_change : (Double) -> Unit,
  on_commit : (Double) -> Unit,
) -> Unit {
  r.box(fn(row) {
    @sf.style_node(row, fn() { fp_v6_slider_row })
    row.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(200.0))).max_width(Is(Some(280.0))) |> ignore
    @sf.value_slider_node(
      row,
      label,
      value,
      on_change,
      min~,
      max~,
      step~,
      format=fn(n) { "\{n}%" },
      on_commit~,
    ).grow(Is(1.0)) |> ignore
    row.box(fn(val_box) {
      @sf.style_node(val_box, fn() { fp_v6_val_box })
      val_box.shrink(Is(0.0)).width(Is(Some(48.0))) |> ignore
      @sf.words_node(val_box, fn() { "\{value().round().to_int()}%" }, fn() { fp_v6_row_val }) |> ignore
    }) |> ignore
  }) |> ignore
}

///|
/// Front-and-center native Reading Comfort card (`@sf.group_node`): 正文行距 + 正文阅读字号.
fn font_reading_bar_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  let set_typo = fn(m : Map[String, Json]) { clear_fonts_undo(); @settings.set_typography(ctx.core, Json::object(m)) }
  let lh_keys = ["compact", "normal", "relaxed"]
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v6_block_pad })
    @sf.group_node(sec, fn(g) {
      @sf.setting_choice_node(
        g,
        fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") },
        fn() {
          [
            @sf.t("web-pages.appearance.fonts.advanced.lineCompact"),
            @sf.t("web-pages.appearance.fonts.advanced.lineNormal"),
            @sf.t("web-pages.appearance.fonts.advanced.lineRelaxed"),
          ]
        },
        fn() {
          match text(ctx.typo(), "lineHeight") {
            "compact" => 0
            "relaxed" => 2
            _ => 1
          }
        },
        fn(i) {
          let m : Map[String, Json] = Map([])
          m["lineHeight"] = ToJson::to_json(lh_keys[i])
          set_typo(m)
        },
      )
      let text_v = fn() { text_size_drag.get().unwrap_or(font_typo_num(ctx.typo(), "textSize", 100.0)) }
      @sf.setting_node(
        g,
        fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
        fn(r) {
          fp_setting_slider_ctrl(
            r,
            fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
            text_v,
            85.0,
            130.0,
            5.0,
            fn(x) { text_size_drag.set(Some(x)) },
            fn(x) {
              let m : Map[String, Json] = Map([])
              m["textSize"] = ToJson::to_json(x.round().to_int())
              set_typo(m)
              text_size_drag.set(None)
            },
          )
        },
      )
    })
  }) |> ignore
}

///|
/// Subtle right-side action link to enter local machine fonts from curated view (zero competing second pill bar).
fn font_local_entry_btn(slot : @view.View) -> Unit {
  slot.shrink(Is(0.0)) |> ignore
  @sf.action_box_node(slot, fn() { @sf.t("web-pages.appearance.fonts.local") }, fn(_) {
    fonts_trying.set("")
    local_open.set(true)
  }, fn(btn) {
    @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v6_link_hot } else { fp_v6_link } })
    @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.local") }, fn() { fp_v6_link_words }) |> ignore
    @sf.icon_node(btn, "chevron-right", 13.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
  }) |> ignore
}

///|
/// Single-row toolbar for an expanded role drawer:
/// - Curated mode: `[ 西文 | 中文 ]` segmented pill on left + clean `本机字体 ›` link on right
/// - Local mode: `‹ 精选字体` back link on left + `本机字体` label on right (never stacks 2+ segmented bars!)
fn font_drawer_toolbar_node(bar : @view.View, role_key : String) -> Unit {
  @sf.style_node(bar, fn() { fp_v6_drawer_bar })
  bar.pick(fn() { local_open.get() && can_show_local_fonts() }, fn(slot, is_local) {
    @sf.style_node(slot, fn() { fp_v6_drawer_bar_inner })
    slot.wraps(Is(Some(6.0))) |> ignore
    if is_local {
      @sf.action_box_node(slot, fn() { @sf.t("web-pages.appearance.fonts.curated") }, fn(_) {
        fonts_trying.set("")
        local_open.set(false)
      }, fn(btn) {
        @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v6_link_hot } else { fp_v6_link } })
        @sf.icon_node(btn, "chevron-left", 13.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.curated") }, fn() { fp_v6_link_words }) |> ignore
      }) |> ignore
      @sf.words_node(slot, fn() { @sf.t("web-pages.appearance.fonts.local") }, fn() { fp_v6_sec_heading }) |> ignore
    } else {
      slot.box(fn(left) {
        left.shrink(Is(0.0)) |> ignore
        @sf.segmented_node(
          left,
          fn() {
            [
              @sf.t(if role_key == "code" { "web-pages.appearance.fonts.scriptShort.mono" } else { "web-pages.appearance.fonts.scriptShort.latin" }),
              @sf.t("web-pages.appearance.fonts.scriptShort.cjk"),
            ]
          },
          fn() { @settings.fonts_script_at.get() },
          fn(i) {
            fonts_trying.set("")
            @settings.fonts_script_at.set(i)
          },
        )
      }) |> ignore
      slot.show(at_once=true, can_show_local_fonts, fn(src) { font_local_entry_btn(src) })
    }
  })
}

///|
/// In-place expanded drawer for one role inside the 字体搭配 card (styles `panel` directly, zero structure-box).
fn font_role_drawer_node(
  panel : @view.View,
  ctx : FontPageCtx,
  role_key : String,
  over_faces : @signals.Signal[Bool],
) -> Unit {
  @sf.style_node(panel, fn() { fp_v6_drawer })
  panel.points(Is(true)) |> ignore
  panel.reacts(fn() { panel.pointed_in() }, fn(on) { over_faces.set(on) })
  panel.owns(fn() { over_faces.set(false) }) |> ignore
  fp_divider_node(panel)
  panel.box(fn(bar) { font_drawer_toolbar_node(bar, role_key) }) |> ignore
  fp_divider_node(panel)
  panel.box(fn(list_host) {
    @sf.style_node(list_host, fn() { fp_v6_drawer_list })
    list_host.pick(fn() { (ctx.active_slot(), local_open.get() && can_show_local_fonts()) }, fn(held, st) {
      let (slot, is_local) = st
      if is_local {
        local_faces_inline_node(held, ctx, slot, role_key, ctx.script() == 1)
      } else {
        @sf.group_rows_node(held, fn(rows) { face_rows_node(rows, ctx, slot, role_key, ctx.script() == 1) })
      }
    })
  }) |> ignore
}

///|
/// Clean 3-row native settings card (`界面 / 正文 / 代码`); long summaries ellipsize safely at 390pt × 1.3×.
fn font_roles_card_node(parent : @view.View, ctx : FontPageCtx, over_faces : @signals.Signal[Bool]) -> Unit {
  let roles = ["ui", "text", "code"]
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v6_presets_sec })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.matrix.title") }, fn() { fp_v6_sec_heading }) |> ignore
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v6_card })
      card.clip().edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      for idx, role_key in roles {
        if idx > 0 {
          fp_divider_node(card)
        }
        let open = fn() { font_picker_open.get() == idx }
        card.box(fn(row_wrap) {
          @sf.style_node(row_wrap, fn() { fp_v6_role_wrap })
          @sf.action_box_node(
            row_wrap,
            fn() { @sf.t("web-pages.appearance.fonts." + role_key) + " · " + @sf.t(font_role_sub_key(role_key)) },
            fn(_) {
              fonts_trying.set("")
              if font_picker_open.untracked() == idx {
                font_picker_open.set(-1)
              } else {
                @settings.fonts_at.set(idx)
                font_picker_open.set(idx)
              }
            },
            fn(hdr) {
              @sf.style_node(hdr, fn() {
                if @sf.lit_node(hdr) { fp_v6_role_row_hot } else { fp_v6_role_row }
              })
              hdr.min_height(Is(Some(52.0))) |> ignore
              hdr.box(fn(left) {
                @sf.style_node(left, fn() { fp_v6_role_left })
                left.shrink(Is(0.0)) |> ignore
                @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn() { fp_v6_role_title }) |> ignore
                @sf.words_node(left, fn() { @sf.t(font_role_sub_key(role_key)) }, fn() { fp_v6_role_sub }) |> ignore
              }) |> ignore
              hdr.box(fn(right) {
                @sf.style_node(right, fn() { fp_v6_role_right })
                right.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                right.box(fn(val_wrap) {
                  val_wrap.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  @sf.words_node(val_wrap, fn() { ctx.role_summary(role_key).0 }, fn() {
                    if ctx.role_summary(role_key).1 { fp_v6_role_val_busy } else { fp_v6_role_val }
                  }) |> ignore
                }) |> ignore
                right.box(fn(ic_wrap) {
                  ic_wrap.shrink(Is(0.0)) |> ignore
                  ic_wrap.pick(open, fn(ic, is_open) {
                    @sf.icon_node(ic, if is_open { "chevron-down" } else { "chevron-right" }, 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
                  })
                }) |> ignore
              }) |> ignore
            },
          ) |> ignore
          row_wrap.show(at_once=true, open, fn(panel) {
            font_role_drawer_node(panel, ctx, role_key, over_faces)
          })
        }) |> ignore
      }
    }) |> ignore
  }) |> ignore
}

///|
fn fp_divider_node(parent : @view.View) -> Unit {
  parent.box(fn(d) {
    @sf.style_node(d, fn() { fp_v6_divider })
    d.height(Is(Some(1.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore
  }) |> ignore
}

///|
/// Native `@sf.group_node` card for collapsible advanced typography (explicit `[界面 | 正文 | 代码]` CJK scope).
fn font_advanced_card_node(slot : @view.View, ctx : FontPageCtx) -> Unit {
  let set_typo = fn(m : Map[String, Json]) { clear_fonts_undo(); @settings.set_typography(ctx.core, Json::object(m)) }
  let w_vals = [-100, 0, 100]
  @sf.group_node(slot, fn(g) {
    // 1. Code relative scale (exact core-ts cap 85..110%)
    let code_v = fn() { code_scale_drag.get().unwrap_or(font_typo_num(ctx.typo(), "codeScale", 100.0)) }
    @sf.setting_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
      fn(r) {
        fp_setting_slider_ctrl(
          r,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
          code_v,
          85.0,
          110.0,
          5.0,
          fn(x) { code_scale_drag.set(Some(x)) },
          fn(x) {
            let m : Map[String, Json] = Map([])
            m["codeScale"] = ToJson::to_json(x.round().to_int())
            set_typo(m)
            code_scale_drag.set(None)
          },
        )
      },
    )
    // 2. CJK AutoSpace
    let auto_on = fn() { font_typo_bool(ctx.typo(), "cjkAutoSpace", true) }
    @sf.setting_switch_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") },
      auto_on,
      fn(v) {
        let m : Map[String, Json] = Map([])
        m["cjkAutoSpace"] = ToJson::to_json(v)
        set_typo(m)
      },
      note=fn() {
        @sf.t(if auto_on() { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOn" } else { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOff" })
      },
    )
    // 3. Code Ligatures (hidden on Web platform == 4)
    if @ui.platform() != 4 {
      @sf.setting_switch_node(
        g,
        fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") },
        fn() { font_typo_bool(ctx.typo(), "codeLigatures", true) },
        fn(v) {
          let m : Map[String, Json] = Map([])
          m["codeLigatures"] = ToJson::to_json(v)
          set_typo(m)
        },
        note=fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigaturesNote") },
      )
    }
    // 4. Explicit role scope selector for CJK optical tuning (no hidden coupling!)
    let p = fn() { ctx.place() }
    @sf.setting_choice_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkGroup", args=[("place", @sf.t("web-pages.appearance.fonts." + p()))]) },
      fn() {
        [
          @sf.t("web-pages.appearance.fonts.ui"),
          @sf.t("web-pages.appearance.fonts.text"),
          @sf.t("web-pages.appearance.fonts.code"),
        ]
      },
      fn() { @settings.fonts_at.get() },
      fn(i) {
        fonts_trying.set("")
        @settings.fonts_at.set(i)
      },
    )
    // 5. CJK relative weight (placed before CJK slider so segmented pill never sits in the group's bottom corners)
    @sf.setting_choice_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") },
      fn() {
        [
          @sf.t("web-pages.appearance.fonts.advanced.weightLight"),
          @sf.t("web-pages.appearance.fonts.advanced.weightAuto"),
          @sf.t("web-pages.appearance.fonts.advanced.weightBold"),
        ]
      },
      fn() {
        let cur = ctx.live_cjk_weight(p())
        if cur < 0 { 0 } else if cur > 0 { 2 } else { 1 }
      },
      fn(i) {
        let m : Map[String, Json] = Map([])
        m[font_cjk_weight_key(p())] = ToJson::to_json(w_vals[i])
        set_typo(m)
      },
    )
    // 6. CJK relative size (exact core-ts cap 85..115%)
    let cjk_v = fn() {
      let key = font_cjk_scale_key(p())
      match cjk_scale_drag.get() {
        Some((k, v)) if k == key => v
        _ => font_typo_num(ctx.typo(), key, 100.0)
      }
    }
    @sf.setting_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
      fn(r) {
        fp_setting_slider_ctrl(
          r,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
          cjk_v,
          85.0,
          115.0,
          5.0,
          fn(v) { cjk_scale_drag.set(Some((font_cjk_scale_key(p()), v))) },
          fn(v) {
            let m : Map[String, Json] = Map([])
            m[font_cjk_scale_key(p())] = ToJson::to_json(v.round().to_int())
            set_typo(m)
            cjk_scale_drag.set(None)
          },
        )
      },
    )
    // 7. Optional reset-follow-UI row when textCjk inherits uiCjk with custom optics override
    g.show(at_once=true, fn() {
      p() == "text" && ctx.chosen_of("textCjk") == "" &&
      (font_typo_bool(ctx.typo(), "textCjkScaleOwn", false) || font_typo_bool(ctx.typo(), "textCjkWeightOwn", false))
    }, fn(rf) {
      @sf.setting_node(rf, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") }, fn(r) {
        @sf.button_node(r, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") }, fn() {
          let m : Map[String, Json] = Map([])
          m["textCjkScale"] = Json::null()
          m["textCjkWeight"] = Json::null()
          set_typo(m)
        }) |> ignore
      })
    })
  })
}

///|
/// Quiet collapsible advanced typography section (collapsed by default).
fn font_advanced_v6_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  open_advanced_if_fixture(parent)
  let summary = fn() -> String {
    let n = font_advanced_custom_count(ctx.typo())
    if n > 0 {
      @sf.t("web-pages.appearance.fonts.advanced.summaryCustom", args=[("n", n.to_string())])
    } else {
      @sf.t("web-pages.appearance.fonts.default")
    }
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v6_adv_sec })
    sec.box(fn(hdr) {
      @sf.style_node(hdr, fn() { fp_v6_adv_hdr })
      @sf.action_box_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn(_) {
        advanced_open.set(!advanced_open.untracked())
      }, fn(btn) {
        @sf.style_node(btn, fn() { fp_v6_adv_toggle })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn() { fp_v6_sec_heading }) |> ignore
        @sf.words_node(btn, summary, fn() { fp_v6_adv_summary }) |> ignore
        btn.pick(fn() { advanced_open.get() }, fn(ic, open) {
          @sf.icon_node(ic, if open { "chevron-down" } else { "chevron-right" }, 13.0, By(fn() { @sf.theme().p.subtle })) |> ignore
        })
      }) |> ignore
      hdr.show(at_once=true, fn() { font_typo_custom_count(ctx.typo()) > 0 }, fn(rw) {
        @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn(_) {
          clear_fonts_undo()
          @settings.set_typography(ctx.core, Json::null())
        }, fn(btn) {
          @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v6_reset_hot } else { fp_v6_reset } })
          @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn() { fp_v6_reset_words }) |> ignore
        }) |> ignore
      })
    }) |> ignore
    sec.show(at_once=true, fn() { advanced_open.get() }, fn(card) {
      font_advanced_card_node(card, ctx)
    })
  }) |> ignore
}

///|
// kept across runs: a value
let fp_v6_reset : @ui.Style = @ui.css("px=S2 py=S1 radius=Md align=ACenter justify=JCenter")

///|
// kept across runs: a value
let fp_v6_reset_hot : @ui.Style = fp_v6_reset.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value
let fp_v6_reset_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value
let fp_v6_undo_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value
let fp_v6_link : @ui.Style = @ui.css("row px=S2 py=S1 gap=S0_5 radius=Md align=ACenter justify=JCenter")

///|
// kept across runs: a value
let fp_v6_link_hot : @ui.Style = fp_v6_link.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value
let fp_v6_link_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, wrap=false)

///|
// kept across runs: a value
let fp_v6_preview_card : @ui.Style = @ui.css("w=Full p=S2 gap=S1_5 radius=Xl2 bg=Card")

///|
// kept across runs: a value
let fp_v6_top_row : @ui.Style = @ui.css("row w=Full justify=JEnd align=ACenter")

///|
// kept across runs: a value
let fp_v6_bubble : @ui.Style = @ui.css("px=S2_5 py=S1 bg=Bg")

///|
// kept across runs: a value
let fp_v6_mine_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L5, color=Fg)

///|
// kept across runs: a value
let fp_v6_zone : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")

///|
// kept across runs: a value
let fp_v6_who_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
// kept across runs: a value
let fp_v6_who_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)

///|
// kept across runs: a value
let fp_v6_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)

///|
// kept across runs: a value
let fp_v6_code_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S1_5 bg=Bg")

///|
// kept across runs: a value
let fp_v6_code_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, w=Full)

///|
// kept across runs: a value
let fp_v6_block_pad : @ui.Style = @ui.css("w=Full pb=S3")

///|
// kept across runs: a value
let fp_v6_presets_sec : @ui.Style = @ui.css("w=Full gap=S1_5 pb=S3")

///|
// kept across runs: a value
let fp_v6_adv_sec : @ui.Style = @ui.css("w=Full gap=S1_5 pt=S0_5 pb=S2")

///|
// kept across runs: a value
let fp_v6_sec_heading : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, wrap=false)

///|
// kept across runs: a value
let fp_v6_preset_row : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")

///|
// kept across runs: a value
let fp_v6_preset : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=Card")

///|
// kept across runs: a value
let fp_v6_preset_hot : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=Hover")

///|
// kept across runs: a value
let fp_v6_preset_on : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=AccentBg")

///|
// kept across runs: a value
let fp_v6_preset_top : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S1")

///|
// kept across runs: a value
let fp_v6_preset_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)

///|
// kept across runs: a value
let fp_v6_preset_title_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=AccentText)

///|
// kept across runs: a value
let fp_v6_preset_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)

///|
// kept across runs: a value
let fp_v6_slider_row : @ui.Style = @ui.css("row gap=S3 align=ACenter")

///|
// kept across runs: a value
let fp_v6_val_box : @ui.Style = @ui.css("row justify=JEnd align=ACenter")

///|
// kept across runs: a value
let fp_v6_row_val : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)

///|
// kept across runs: a value
let fp_v6_card : @ui.Style = @ui.css("w=Full radius=Xl2 bg=Card")

///|
// kept across runs: a value
let fp_v6_role_wrap : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value
let fp_v6_role_row : @ui.Style = @ui.css("row w=Full px=S4 py=S2_5 gap=S3 justify=JBetween align=ACenter")

///|
// kept across runs: a value
let fp_v6_role_row_hot : @ui.Style = fp_v6_role_row.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value
let fp_v6_role_left : @ui.Style = @ui.css("gap=S0_5")

///|
// kept across runs: a value
let fp_v6_role_title : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value
let fp_v6_role_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, max_lines=1)

///|
// kept across runs: a value
let fp_v6_role_right : @ui.Style = @ui.css("row gap=S1_5 justify=JEnd align=ACenter")

///|
// kept across runs: a value
let fp_v6_role_val : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, max_lines=1)

///|
// kept across runs: a value
let fp_v6_role_val_busy : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, max_lines=1)

///|
// kept across runs: a value
let fp_v6_drawer : @ui.Style = @ui.css("w=Full bg=Surface")

///|
// kept across runs: a value
let fp_v6_drawer_bar : @ui.Style = @ui.css("w=Full px=S3 py=S2")

///|
// kept across runs: a value
let fp_v6_drawer_bar_inner : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")

///|
// kept across runs: a value
let fp_v6_drawer_list : @ui.Style = @ui.css("w=Full bg=Card")

///|
// kept across runs: a value
let fp_v6_divider : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value
let fp_v6_adv_hdr : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")

///|
// kept across runs: a value
let fp_v6_adv_toggle : @ui.Style = @ui.css("row gap=S1_5 align=ACenter py=S0_5")

///|
// kept across runs: a value
let fp_v6_adv_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
