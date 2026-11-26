// V8 single-screen, direct-manipulation native still.fail font settings page built on `@sf.page_node`:
// - Zero `look_node` / `page-look` branching (pure flex-wrap responsive layout)
// - Fits cleanly on one 1280x800 screen without sticky-bar slicing, accordions, or multi-row pill stacking
// - Live chat preview at top (height-locked during hover/drag; clicking a zone opens its font picker directly)
// - Compact 4-card curated style strip (zero middle-dot concatenation; right-aligned download size)
// - Direct 3x2 font pairing card (`界面 / 正文 / 代码` x `西文|等宽 / 中文`): each slot opens an anchored
//   native Popover (Bottom Sheet on Small) via `@sf.panel_nodes` with unified search + script-filtered curated
//   & local fonts + live hover preview
// - Compact 1-row 2-column Reading Comfort card (正文阅读字号 + 正文行距)
// - Quiet collapsible 2-column advanced typography card (代码相对字号, global 中文相对大小/字重, 自动留白, 代码连字).

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
fn font_script_short_key(role_key : String, is_cjk : Bool) -> String {
  if is_cjk {
    "web-pages.appearance.fonts.scriptShort.cjk"
  } else if role_key == "code" {
    "web-pages.appearance.fonts.scriptShort.mono"
  } else {
    "web-pages.appearance.fonts.scriptShort.latin"
  }
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
  if fx_local_up.val {
    fx_local_up.val = false
    @settings.fonts_at.set(0)
    @settings.fonts_script_at.set(1)
    font_picker_open.set(1)
    local_open.set(true)
  } else if fx_code_up.val {
    fx_code_up.val = false
    @settings.fonts_at.set(2)
    @settings.fonts_script_at.set(0)
    font_picker_open.set(4)
    local_open.set(true)
  }
  v.owns(fn() {
    fonts_undo_snap.set(None)
    font_picker_open.set(-1)
    local_open.set(false)
  }) |> ignore
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.fonts.title") },
    fn() { ["preview", "presets", "fonts", "reading", "advanced"] },
    fn(col, key) {
      match key {
        "preview" => font_preview_block_node(col, ctx)
        "presets" => font_presets_strip_node(col, ctx)
        "fonts" => font_roles_card_node(col, ctx)
        "reading" => font_reading_bar_node(col, ctx)
        _ => font_advanced_v8_node(col, ctx)
      }
    },
    on_back~,
    frame~,
    lead=fn() { @sf.t("web-pages.appearance.fonts.description") },
    said?,
    width?,
    scroll~,
  )
}

///|
fn fonts_header_actions_node(row : @view.View, ctx : FontPageCtx) -> Unit {
  row.box(fn(g) {
    g.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
    g.box(fn(anchor) { anchor.width(Is(Some(0.0))).height(Is(Some(0.0))) |> ignore }) |> ignore
    g.show(along_row=true, fn() { fonts_undo_snap.get() is Some(_) }, fn(uw) {
      @sf.action_box_node(uw, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn(_) { ctx.undo_reset() }, fn(btn) {
        @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v8_reset_hot } else { fp_v8_reset } })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn() { fp_v8_undo_words }) |> ignore
      })
      |> ignore
    })
    g.show(along_row=true, fn() { ctx.any_customized() }, fn(rw) {
      @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn(_) { ctx.reset_all() }, fn(btn) {
        @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v8_reset_hot } else { fp_v8_reset } })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn() { fp_v8_reset_words }) |> ignore
      })
      |> ignore
    })
  }) |> ignore
}

///|
/// Height-locked live chat preview block (no sticky separator bar; entire page fits on one desktop screen).
fn font_preview_block_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v8_block_pad })
    sec.by_room(fn(held, r) {
      held.box(fn(cell) {
        let chat : Ref[@view.View?] = Ref(None)
        let tallest = Ref(0.0)
        cell.box(fn(card_host) {
          chat.val = Some(card_host)
          font_preview_v8_node(card_host, ctx)
        })
        |> ignore
        cell.min_height(By(fn() {
          match chat.val {
            Some(card_host) => {
              let tall = r.tall(card_host)
              let lock = font_picker_open.get() >= 0 || preset_trying.get() >= 0 || cjk_scale_drag.get() is Some(_) ||
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
  })
  |> ignore
}

///|
/// Calm, realistic live chat preview (`p=S2` + inner `radius=10.0` exact concentric with `Xl2=18`).
fn font_preview_v8_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
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
    let lat_slot = idx * 2
    let cjk_slot = idx * 2 + 1
    let target = if font_picker_open.untracked() == lat_slot { cjk_slot } else { lat_slot }
    @settings.fonts_at.set(idx)
    @settings.fonts_script_at.set(target % 2)
    font_picker_open.set(target)
    local_open.set(true)
  }
  let zone = fn(col : @view.View, role_idx : Int, role_key : String, body : (@view.View) -> Unit) {
    let active = fn() {
      let cur = font_picker_open.get()
      cur >= 0 && cur / 2 == role_idx
    }
    @sf.action_box_node(col, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn(_) { open_role(role_idx) }, fn(z) {
      @sf.style_node(z, fn() { fp_v8_zone })
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
    @sf.style_node(card, fn() { fp_v8_preview_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    card.box(fn(top) {
      @sf.style_node(top, fn() { fp_v8_top_row })
      top.box(fn(bubble) {
        @sf.style_node(bubble, fn() { fp_v8_bubble })
        bubble.radius(Is(@sf.small_corner)) |> ignore
        face_in_node(
          bubble,
          fn() { @sf.t("web-pages.appearance.fonts.sampleMine") },
          fn() { text_face().unwrap_or(0) },
          fp_v8_mine_words,
          person=fn() { text_face() is None },
          cjk=text_cjk,
          size_scale=prose_scale,
          line_scale~,
        ) |> ignore
      }) |> ignore
    }) |> ignore
    zone(card, 0, "ui", fn(c) {
      c.box(fn(who) {
        @sf.style_node(who, fn() { fp_v8_who_line })
        face_in_node(who, fn() { "Claude" }, ui_face, fp_v8_who_words, cjk=ui_cjk) |> ignore
        face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_v8_time_words, cjk=ui_cjk) |> ignore
      }) |> ignore
    })
    zone(card, 1, "text", fn(c) {
      @sf.markdown_node(
        c,
        fn() { @sf.t("web-pages.appearance.fonts.sampleText") },
        size=fn() { body_size },
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
        @sf.style_node(cb, fn() { fp_v8_code_box })
        cb.radius(Is(@sf.small_corner)) |> ignore
        face_in_node(
          cb,
          fn() { fp_sample_code },
          fn() { code_face().unwrap_or(0) },
          fp_v8_code_words,
          cjk=code_cjk,
          size_scale=fn() { prose_scale() * code_scale() },
          mono=true,
        ) |> ignore
      }) |> ignore
    })
  }) |> ignore
}

///|
/// Compact 4-option curated style strip (4-col wide, auto 2x2 narrow; right-aligned size, zero `·` dots).
fn font_presets_strip_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v8_section })
    sec.box(fn(hdr) {
      @sf.style_node(hdr, fn() { fp_v8_adv_hdr })
      @sf.words_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.presets") }, fn() { fp_v8_sec_heading }) |> ignore
      fonts_header_actions_node(hdr, ctx)
    }) |> ignore
    sec.box(fn(row) {
      @sf.style_node(row, fn() { fp_v8_preset_row })
      row.wraps(Is(Some(8.0))) |> ignore
      for i, preset in font_presets {
        let on = fn() { font_preset_matches(preset, fn(s) { ctx.chosen_of(s) }) }
        let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key) }
        let sub = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key + "Sub") }
        let need_size = fn() {
          let bytes = preset_needed_bytes(preset, ctx.all(), items(ctx.files_state(), "kept"), ctx.core.face_here)
          if bytes > 0.0 { face_size(bytes) } else { "" }
        }
        row.box(fn(slot) {
          slot.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(148.0))).min_width(Is(Some(142.0))) |> ignore
          slot.reacts(fn() { @sf.lit_in_node(slot) }, fn(lit) {
            if lit { preset_trying.set(i) } else if preset_trying.untracked() == i { preset_trying.set(-1) }
          })
          slot.owns(fn() { if preset_trying.untracked() == i { preset_trying.set(-1) } }) |> ignore
          @sf.action_box_node(slot, title, fn(_) {
            clear_fonts_undo()
            for id in [preset.ui, preset.ui_cjk, preset.text, preset.text_cjk, preset.code, preset.code_cjk] {
              if id is Some(s) && s != "" {
                @sfbase.face_retry(s)
              }
            }
            @settings.set_fonts_preset(ctx.core, preset_patch(preset), reset_cjk_optics=true)
          }, fn(card) {
            @sf.style_node(card, fn() {
              if on() { fp_v8_preset_on } else if @sf.lit_node(card) { fp_v8_preset_hot } else { fp_v8_preset }
            })
            card.grow(Is(1.0)).edge(By(fn() {
              if on() { (1.0, @sf.theme().p.accent_text) } else { (0.5, @sf.theme().p.line) }
            })) |> ignore
            card.box(fn(top) {
              @sf.style_node(top, fn() { fp_v8_preset_top })
              top.wraps(Is(Some(2.0))) |> ignore
              @sf.words_node(top, title, fn() { if on() { fp_v8_preset_title_on } else { fp_v8_preset_title } }) |> ignore
              top.pick(fn() { if on() { 1 } else if need_size() != "" { 2 } else { 0 } }, fn(end, st) {
                if st == 1 {
                  @sf.icon_node(end, "check", 14.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
                } else if st == 2 {
                  @sf.words_node(end, need_size, fn() { fp_v8_preset_size }) |> ignore
                }
              })
            }) |> ignore
            @sf.words_node(card, sub, fn() { fp_v8_preset_sub }) |> ignore
          }) |> ignore
        }) |> ignore
      }
    }) |> ignore
  }) |> ignore
}

///|
/// One clickable font dropdown trigger for a single `(role_idx, is_cjk)` slot; opens anchored Popover / Sheet.
fn font_slot_trigger_node(
  parent : @view.View,
  ctx : FontPageCtx,
  role_idx : Int,
  role_key : String,
  is_cjk : Bool,
) -> Unit {
  let slot_idx = role_idx * 2 + (if is_cjk { 1 } else { 0 })
  let script_label = fn() { @sf.t(font_script_short_key(role_key, is_cjk)) }
  let a11y_label = fn() {
    let role = @sf.t("web-pages.appearance.fonts." + role_key)
    let script = script_label()
    if @sf.language() == "en" { role + " " + script } else { role + script }
  }
  let is_open = fn() { font_picker_open.get() == slot_idx }
  parent.box(fn(wrap) {
    wrap.grow(Is(1.0)).shrink(Is(1.0)).width(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
    let anchor : Ref[@view.View?] = Ref(None)
    let mine = Ref(0)
    @sf.action_box_node(
      wrap,
      a11y_label,
      fn(_) {
        fonts_trying.set("")
        if font_picker_open.untracked() == slot_idx {
          font_picker_open.set(-1)
          local_open.set(false)
        } else {
          @settings.fonts_at.set(role_idx)
          @settings.fonts_script_at.set(if is_cjk { 1 } else { 0 })
          font_picker_open.set(slot_idx)
          local_open.set(true)
        }
      },
      fn(btn) {
        anchor.val = Some(btn)
        @sf.style_node(btn, fn() {
          if is_open() { fp_v8_slot_on } else if @sf.lit_node(btn) { fp_v8_slot_hot } else { fp_v8_slot }
        })
        btn.min_height(Is(Some(44.0))).radius(Is(@sf.small_corner)).edge(By(fn() {
          if is_open() { (1.0, @sf.theme().p.accent_text) } else { (0.5, @sf.theme().p.line) }
        })) |> ignore
        btn.box(fn(col) {
          col.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(1.0)) |> ignore
          @sf.words_node(col, script_label, fn() { fp_v8_slot_tag }) |> ignore
          @sf.words_node(col, fn() { ctx.slot_button_label(role_key, is_cjk).0 }, fn() {
            if ctx.slot_button_label(role_key, is_cjk).1 { fp_v8_slot_val_busy } else { fp_v8_slot_val }
          }) |> ignore
        }) |> ignore
        btn.box(fn(ic) {
          ic.shrink(Is(0.0)) |> ignore
          @sf.icon_node(ic, "chevron-down", 13.0, By(fn() {
            if is_open() { @sf.theme().p.accent_text } else { @sf.theme().p.subtle }
          })) |> ignore
        }) |> ignore
      },
    ) |> ignore
    wrap.reacts(is_open, fn(on) {
      if !on {
        if mine.val != 0 && @sf.presented_open_of(mine.val) {
          @sf.close_presented_of(mine.val)
        }
        return
      }
      guard mine.val == 0 || !@sf.presented_open_of(mine.val) else { return }
      let (panel_side, panel_along) : (@view.Side, @view.Along) = match role_idx {
        0 => (Bottom, End)
        1 => (Left, Start)
        _ => (Left, End)
      }
      @sf.panel_nodes(
        "",
        fn(panel_v, close) { font_slot_picker_panel_node(panel_v, ctx, role_key, is_cjk, close) },
        from=Node(anchor.val.unwrap_or(wrap)),
        w=310.0,
        side=panel_side,
        along=panel_along,
        gone=fn() {
          fonts_trying.set("")
          if font_picker_open.untracked() == slot_idx {
            font_picker_open.set(-1)
            local_open.set(false)
          }
        },
      )
      mine.val = @sf.last_presented()
    })
    wrap.owns(fn() {
      if mine.val != 0 && @sf.presented_open_of(mine.val) {
        @sf.close_presented_of(mine.val)
      }
    }) |> ignore
  }) |> ignore
}

///|
/// Direct 3x2 font pairing table (`界面 / 正文 / 代码` x `西文|等宽 / 中文`); zero accordions or nested tabs.
fn font_roles_card_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  let roles = ["ui", "text", "code"]
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v8_section })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.matrix.title") }, fn() { fp_v8_sec_heading }) |> ignore
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v8_card })
      card.clip().edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      for idx, role_key in roles {
        if idx > 0 {
          fp_divider_node(card)
        }
        card.box(fn(row) {
          @sf.style_node(row, fn() { fp_v8_role_row })
          row.wraps(Is(Some(8.0))) |> ignore
          row.box(fn(left) {
            @sf.style_node(left, fn() { fp_v8_role_left })
            left.shrink(Is(0.0)).min_width(Is(Some(112.0))) |> ignore
            @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn() { fp_v8_role_title }) |> ignore
            @sf.words_node(left, fn() { @sf.t(font_role_sub_key(role_key)) }, fn() { fp_v8_role_sub }) |> ignore
          }) |> ignore
          row.box(fn(pair) {
            @sf.style_node(pair, fn() { fp_v8_slot_pair })
            pair.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(240.0))).max_width(Is(Some(450.0))) |> ignore
            font_slot_trigger_node(pair, ctx, idx, role_key, false)
            font_slot_trigger_node(pair, ctx, idx, role_key, true)
          }) |> ignore
        }) |> ignore
      }
    }) |> ignore
  }) |> ignore
}

///|
fn fp_divider_node(parent : @view.View) -> Unit {
  parent.box(fn(d) {
    @sf.style_node(d, fn() { fp_v8_divider })
    d.height(Is(Some(1.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore
  }) |> ignore
}

///|
/// Compact 1-row 2-column Reading Comfort card: 正文阅读字号 (left) + 正文行距 (right), zero wasted white voids.
fn font_reading_bar_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  let set_typo = fn(m : Map[String, Json]) { clear_fonts_undo(); @settings.set_typography(ctx.core, Json::object(m)) }
  let lh_keys = ["compact", "normal", "relaxed"]
  let text_v = fn() { text_size_drag.get().unwrap_or(font_typo_num(ctx.typo(), "textSize", 100.0)) }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v8_block_pad })
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v8_grid_card })
      card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      card.box(fn(row) {
        @sf.style_node(row, fn() { fp_v8_two_col })
        row.wraps(Is(Some(14.0))) |> ignore
        // Left: Prose text size slider
        row.box(fn(left) {
          left.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(210.0))).gap(Is(6.0)) |> ignore
          left.box(fn(hdr) {
            @sf.style_node(hdr, fn() { fp_v8_cell_hdr })
            @sf.words_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") }, fn() { fp_v8_ctrl_title }) |> ignore
            @sf.words_node(hdr, fn() { "\{text_v().round().to_int()}%" }, fn() { fp_v8_ctrl_val }) |> ignore
          }) |> ignore
          left.box(fn(ctrl) {
            @sf.style_node(ctrl, fn() { fp_v8_slider_wrap })
            ctrl.min_height(Is(Some(34.0))) |> ignore
            @sf.words_node(ctrl, fn() { "A" }, fn() { fp_v8_glyph_sm }) |> ignore
            @sf.value_slider_node(
              ctrl,
              fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
              text_v,
              fn(x) { text_size_drag.set(Some(x)) },
              min=85.0,
              max=130.0,
              step=5.0,
              format=fn(n) { "\{n}%" },
              bubble=false,
              on_commit=fn(x) {
                let m : Map[String, Json] = Map([])
                m["textSize"] = ToJson::to_json(x.round().to_int())
                set_typo(m)
                text_size_drag.set(None)
              },
            ).grow(Is(1.0)) |> ignore
            @sf.words_node(ctrl, fn() { "A" }, fn() { fp_v8_glyph_lg }) |> ignore
          }) |> ignore
        }) |> ignore
        // Right: Prose line height segmented control
        row.box(fn(right) {
          right.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(200.0))).min_width(Is(Some(190.0))).gap(Is(6.0)) |> ignore
          @sf.words_node(right, fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") }, fn() { fp_v8_ctrl_title }) |> ignore
          right.box(fn(line) {
            line.row(Is(true)) |> ignore
            line.box(fn(slot) {
              @sf.segmented_node(
                slot,
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
            }) |> ignore
          }) |> ignore
        }) |> ignore
      }) |> ignore
    }) |> ignore
  }) |> ignore
}

///|
/// Compact 2-column advanced typography card (global CJK scale/weight — zero role sub-switcher!).
fn font_advanced_card_node(slot : @view.View, ctx : FontPageCtx) -> Unit {
  let set_typo = fn(m : Map[String, Json]) { clear_fonts_undo(); @settings.set_typography(ctx.core, Json::object(m)) }
  let w_vals = [-100, 0, 100]
  let code_v = fn() { code_scale_drag.get().unwrap_or(font_typo_num(ctx.typo(), "codeScale", 100.0)) }
  let cjk_v = fn() {
    match cjk_scale_drag.get() {
      Some(("*", v)) => v
      _ => font_typo_num(ctx.typo(), "uiCjkScale", 100.0)
    }
  }
  let auto_on = fn() { font_typo_bool(ctx.typo(), "cjkAutoSpace", true) }
  let lig_on = fn() { font_typo_bool(ctx.typo(), "codeLigatures", true) }
  slot.box(fn(card) {
    @sf.style_node(card, fn() { fp_v8_grid_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    // Row 1: Code relative scale + Global CJK relative size
    card.box(fn(r1) {
      @sf.style_node(r1, fn() { fp_v8_two_col })
      r1.wraps(Is(Some(14.0))) |> ignore
      r1.box(fn(left) {
        left.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(210.0))).gap(Is(6.0)) |> ignore
        left.box(fn(hdr) {
          @sf.style_node(hdr, fn() { fp_v8_cell_hdr })
          @sf.words_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") }, fn() { fp_v8_ctrl_title }) |> ignore
          @sf.words_node(hdr, fn() { "\{code_v().round().to_int()}%" }, fn() { fp_v8_ctrl_val }) |> ignore
        }) |> ignore
        @sf.value_slider_node(
          left,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
          code_v,
          fn(x) { code_scale_drag.set(Some(x)) },
          min=85.0,
          max=110.0,
          step=5.0,
          format=fn(n) { "\{n}%" },
          bubble=false,
          on_commit=fn(x) {
            let m : Map[String, Json] = Map([])
            m["codeScale"] = ToJson::to_json(x.round().to_int())
            set_typo(m)
            code_scale_drag.set(None)
          },
        ) |> ignore
      }) |> ignore
      r1.box(fn(right) {
        right.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(210.0))).gap(Is(6.0)) |> ignore
        right.box(fn(hdr) {
          @sf.style_node(hdr, fn() { fp_v8_cell_hdr })
          @sf.words_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") }, fn() { fp_v8_ctrl_title }) |> ignore
          @sf.words_node(hdr, fn() { "\{cjk_v().round().to_int()}%" }, fn() { fp_v8_ctrl_val }) |> ignore
        }) |> ignore
        @sf.value_slider_node(
          right,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
          cjk_v,
          fn(v) { cjk_scale_drag.set(Some(("*", v))) },
          min=85.0,
          max=115.0,
          step=5.0,
          format=fn(n) { "\{n}%" },
          bubble=false,
          on_commit=fn(v) {
            let pct = v.round().to_int()
            let m : Map[String, Json] = Map([])
            m["uiCjkScale"] = ToJson::to_json(pct)
            m["codeCjkScale"] = ToJson::to_json(pct)
            let inherits = ctx.chosen_of("textCjk") == "" && ctx.chosen_of("uiCjk") != ""
            m["textCjkScale"] = if inherits { Json::null() } else { ToJson::to_json(pct) }
            set_typo(m)
            cjk_scale_drag.set(None)
          },
        ) |> ignore
      }) |> ignore
    }) |> ignore
    fp_divider_node(card)
    // Row 2: Global CJK relative weight + Typography toggles
    card.box(fn(r2) {
      @sf.style_node(r2, fn() { fp_v8_two_col })
      r2.wraps(Is(Some(14.0))) |> ignore
      r2.box(fn(left) {
        left.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(220.0))).min_width(Is(Some(200.0))).gap(Is(6.0)) |> ignore
        @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") }, fn() { fp_v8_ctrl_title }) |> ignore
        left.box(fn(line) {
          line.row(Is(true)) |> ignore
          line.box(fn(slot) {
            @sf.segmented_node(
              slot,
              fn() {
                [
                  @sf.t("web-pages.appearance.fonts.advanced.weightLight"),
                  @sf.t("web-pages.appearance.fonts.advanced.weightAuto"),
                  @sf.t("web-pages.appearance.fonts.advanced.weightBold"),
                ]
              },
              fn() {
                let cur = ctx.live_cjk_weight("ui")
                if cur < 0 { 0 } else if cur > 0 { 2 } else { 1 }
              },
              fn(i) {
                let w = w_vals[i]
                let m : Map[String, Json] = Map([])
                m["uiCjkWeight"] = ToJson::to_json(w)
                m["codeCjkWeight"] = ToJson::to_json(w)
                let inherits = ctx.chosen_of("textCjk") == "" && ctx.chosen_of("uiCjk") != ""
                m["textCjkWeight"] = if inherits { Json::null() } else { ToJson::to_json(w) }
                set_typo(m)
              },
            )
          }) |> ignore
        }) |> ignore
      }) |> ignore
      r2.box(fn(right) {
        right.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(210.0))).gap(Is(8.0)) |> ignore
        right.box(fn(sw1) {
          @sf.style_node(sw1, fn() { fp_v8_toggle_row })
          sw1.box(fn(lbl) {
            @sf.style_node(lbl, fn() { fp_v8_toggle_lbl })
            lbl.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(lbl, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") }, fn() { fp_v8_ctrl_title }) |> ignore
            @sf.words_node(lbl, fn() {
              @sf.t(if auto_on() { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOn" } else { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOff" })
            }, fn() { fp_v8_toggle_sample }) |> ignore
          }) |> ignore
          @sf.switch_node(sw1, auto_on, fn(v) {
            let m : Map[String, Json] = Map([])
            m["cjkAutoSpace"] = ToJson::to_json(v)
            set_typo(m)
          }, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") })
        }) |> ignore
        right.box(fn(sw2) {
          @sf.style_node(sw2, fn() { fp_v8_toggle_row })
          sw2.box(fn(lbl) {
            @sf.style_node(lbl, fn() { fp_v8_toggle_lbl })
            lbl.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(lbl, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") }, fn() { fp_v8_ctrl_title }) |> ignore
            @sf.words_node(lbl, fn() { "=> !==" }, fn() { fp_v8_toggle_sample }) |> ignore
          }) |> ignore
          @sf.switch_node(sw2, lig_on, fn(v) {
            let m : Map[String, Json] = Map([])
            m["codeLigatures"] = ToJson::to_json(v)
            set_typo(m)
          }, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") })
        }) |> ignore
      }) |> ignore
    }) |> ignore
  }) |> ignore
}

///|
/// Quiet collapsible advanced typography section (collapsed by default).
fn font_advanced_v8_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
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
    @sf.style_node(sec, fn() { fp_v8_adv_sec })
    sec.box(fn(hdr) {
      @sf.style_node(hdr, fn() { fp_v8_adv_hdr })
      @sf.action_box_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn(_) {
        advanced_open.set(!advanced_open.untracked())
      }, fn(btn) {
        @sf.style_node(btn, fn() { fp_v8_adv_toggle })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn() { fp_v8_sec_heading }) |> ignore
        @sf.words_node(btn, summary, fn() { fp_v8_adv_summary }) |> ignore
        btn.pick(fn() { advanced_open.get() }, fn(ic, open) {
          @sf.icon_node(ic, if open { "chevron-down" } else { "chevron-right" }, 13.0, By(fn() { @sf.theme().p.subtle })) |> ignore
        })
      }) |> ignore
      hdr.show(at_once=true, fn() { font_advanced_custom_count(ctx.typo()) > 0 }, fn(rw) {
        @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn(_) {
          clear_fonts_undo()
          let m : Map[String, Json] = Map([])
          for k in ["codeScale", "uiCjkScale", "textCjkScale", "codeCjkScale", "uiCjkWeight", "textCjkWeight", "codeCjkWeight", "codeLigatures", "cjkAutoSpace"] {
            m[k] = Json::null()
          }
          @settings.set_typography(ctx.core, Json::object(m))
        }, fn(btn) {
          @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v8_reset_hot } else { fp_v8_reset } })
          @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn() { fp_v8_reset_words }) |> ignore
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
let fp_v8_reset : @ui.Style = @ui.css("px=S2_5 py=S1 radius=Full align=ACenter justify=JCenter")
// kept across runs: a value
let fp_v8_reset_hot : @ui.Style = fp_v8_reset.then(@ui.css("bg=Hover"))
// kept across runs: a value
let fp_v8_reset_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
// kept across runs: a value
let fp_v8_undo_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value
let fp_v8_preview_card : @ui.Style = @ui.css("w=Full p=S2 gap=S1_5 radius=Xl2 bg=Card")
// kept across runs: a value
let fp_v8_top_row : @ui.Style = @ui.css("row w=Full justify=JEnd align=ACenter")
// kept across runs: a value
let fp_v8_bubble : @ui.Style = @ui.css("px=S2_5 py=S1 bg=Bg")
// kept across runs: a value
let fp_v8_mine_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L5, color=Fg)
// kept across runs: a value
let fp_v8_zone : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
// kept across runs: a value
let fp_v8_who_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")
// kept across runs: a value
let fp_v8_who_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)
// kept across runs: a value
let fp_v8_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let fp_v8_code_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S1_5 bg=Bg")
// kept across runs: a value
let fp_v8_code_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, w=Full)
// kept across runs: a value
let fp_v8_block_pad : @ui.Style = @ui.css("w=Full pb=S3")
// kept across runs: a value
let fp_v8_section : @ui.Style = @ui.css("w=Full gap=S1_5 pb=S3")
// kept across runs: a value
let fp_v8_sec_heading : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, wrap=false)
// kept across runs: a value
let fp_v8_preset_row : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
// kept across runs: a value
let fp_v8_preset : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=Card")
// kept across runs: a value
let fp_v8_preset_hot : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=Hover")
// kept across runs: a value
let fp_v8_preset_on : @ui.Style = @ui.css("w=Full px=S3 py=S2 gap=S0_5 radius=Xl2 bg=AccentBg")
// kept across runs: a value
let fp_v8_preset_top : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S1")
// kept across runs: a value
let fp_v8_preset_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)
// kept across runs: a value
let fp_v8_preset_title_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=AccentText)
// kept across runs: a value
let fp_v8_preset_size : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let fp_v8_preset_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)
// kept across runs: a value
let fp_v8_card : @ui.Style = @ui.css("w=Full radius=Xl2 bg=Card")
// kept across runs: a value
let fp_v8_role_row : @ui.Style = @ui.css("row w=Full p=S2 gap=S3 justify=JBetween align=ACenter")
// kept across runs: a value
let fp_v8_role_left : @ui.Style = @ui.css("pl=S1_5 gap=S0_5")
// kept across runs: a value
let fp_v8_role_title : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value
let fp_v8_role_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, max_lines=1)
// kept across runs: a value
let fp_v8_slot_pair : @ui.Style = @ui.css("row gap=S2 align=ACenter")
// kept across runs: a value
let fp_v8_slot : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S1_5 justify=JBetween align=AFirstLine bg=Bg")
// kept across runs: a value
let fp_v8_slot_hot : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S1_5 justify=JBetween align=AFirstLine bg=Hover")
// kept across runs: a value
let fp_v8_slot_on : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S1_5 justify=JBetween align=AFirstLine bg=AccentBg")
// kept across runs: a value
let fp_v8_slot_tag : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let fp_v8_slot_val : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=1)
// kept across runs: a value
let fp_v8_slot_val_busy : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, w=Full, max_lines=1)
// kept across runs: a value
let fp_v8_divider : @ui.Style = @ui.css("w=Full")
// kept across runs: a value
let fp_v8_grid_card : @ui.Style = @ui.css("w=Full px=S4 py=S5 gap=S3_5 radius=Xl2 bg=Card")
// kept across runs: a value
let fp_v8_two_col : @ui.Style = @ui.css("row w=Full gap=S5 align=AStart")
// kept across runs: a value
let fp_v8_cell_hdr : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
// kept across runs: a value
let fp_v8_ctrl_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value
let fp_v8_ctrl_val : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)
// kept across runs: a value
let fp_v8_slider_wrap : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")
// kept across runs: a value
let fp_v8_glyph_sm : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let fp_v8_glyph_lg : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value
let fp_v8_toggle_row : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
// kept across runs: a value
let fp_v8_toggle_lbl : @ui.Style = @ui.css("row gap=S2 align=ACenter")
// kept across runs: a value
let fp_v8_toggle_sample : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value
let fp_v8_adv_sec : @ui.Style = @ui.css("w=Full gap=S1_5 pt=S0_5 pb=S2")
// kept across runs: a value
let fp_v8_adv_hdr : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
// kept across runs: a value
let fp_v8_adv_toggle : @ui.Style = @ui.css("row gap=S1_5 align=ACenter py=S0_5")
// kept across runs: a value
let fp_v8_adv_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
