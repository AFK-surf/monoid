// V4 visual font settings page built directly on `@sf.page_node`:
// - Sticky 3-zone interactive live preview card on tall Wide (`h >= 560`), natural scroll on Narrow & short viewports
// - 4 equal-width visual style cards, 3x2 pairing matrix, contextual face picker, and 2-col advanced typography section.

///|
fn font_script_short_key(place : String, is_cjk : Bool) -> String {
  if is_cjk {
    "web-pages.appearance.fonts.scriptShort.cjk"
  } else if place == "code" {
    "web-pages.appearance.fonts.scriptShort.mono"
  } else {
    "web-pages.appearance.fonts.scriptShort.latin"
  }
}

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
fn font_slot_glyph(place : String, is_cjk : Bool) -> String {
  if is_cjk { "字" } else if place == "code" { "</>" } else { "Aa" }
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
  v.owns(fn() { fonts_undo_snap.set(None) }) |> ignore
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.fonts.title") },
    fn() { ["cards", "matrix", "picker", "advanced"] },
    fn(col, key) { fonts_block_v4_node(col, key, ctx, over_faces) },
    on_back~,
    frame~,
    lead=fn() { @sf.t("web-pages.appearance.fonts.lead") },
    actions=fn(row) { fonts_header_actions_node(row, ctx) },
    sticky_head=fn(room) {
      let is_wide = @sf.look_node(room) is Wide // det-ok(page-look): V4 font preview adapts to Narrow/Wide
      if is_wide {
        room.by_room(fn(held, r) {
          held.box(fn(cell) {
            let chat : Ref[@view.View?] = Ref(None)
            let tallest = Ref(0.0)
            cell.box(fn(card_host) {
              chat.val = Some(card_host)
              font_preview_v4_node(card_host, ctx, true)
            })
            |> ignore
            cell.min_height(By(fn() {
              match chat.val {
                Some(card_host) => {
                  let tall = r.tall(card_host)
                  let lock_tall = over_faces.get() ||
                    preset_trying.get() >= 0 ||
                    cjk_scale_drag.get() is Some(_) ||
                    text_size_drag.get() is Some(_) ||
                    code_scale_drag.get() is Some(_)
                  if lock_tall {
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
      } else {
        font_preview_v4_node(room, ctx, false)
      }
    },
    said?,
    width?,
    scroll~,
  )
}

///|
fn fonts_header_actions_node(row : @view.View, ctx : FontPageCtx) -> Unit {
  row.show(at_once=true, fn() { fonts_undo_snap.get() is Some(_) }, fn(uw) {
    @sf.action_box_node(
      uw,
      fn() { @sf.t("web-pages.appearance.fonts.undoReset") },
      fn(_) { ctx.undo_reset() },
      fn(btn) {
        @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v4_reset_hot } else { fp_v4_reset } })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn() { fp_v4_undo_words }) |> ignore
      },
    )
    |> ignore
  })
  row.show(at_once=true, fn() { ctx.any_customized() }, fn(rw) {
    @sf.action_box_node(
      rw,
      fn() { @sf.t("web-pages.appearance.fonts.resetAll") },
      fn(_) { ctx.reset_all() },
      fn(btn) {
        @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v4_reset_hot } else { fp_v4_reset } })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn() { fp_v4_reset_words }) |> ignore
      },
    )
    |> ignore
  })
}

///|
fn fonts_block_v4_node(col : @view.View, key : String, ctx : FontPageCtx, over_faces : @signals.Signal[Bool]) -> Unit {
  let is_wide = @sf.look_node(col) is Wide // det-ok(page-look): V4 style cards, matrix & 2-col advanced grid adapt to Narrow/Wide
  col.box(fn(sec) {
    if key != "advanced" {
      sec.padding(Is((0.0, 0.0, 0.0, 16.0))) |> ignore
    }
    match key {
      "cards" => font_style_cards_node(sec, ctx, is_wide)
      "matrix" => font_pairing_matrix_node(sec, ctx, is_wide)
      "picker" =>
        sec.box(fn(picker_sec) {
          @sf.style_node(picker_sec, fn() { fp_v4_section })
          @sf.words_node(
            picker_sec,
            fn() {
              @sf.t(
                "web-pages.appearance.fonts.picker.forSlot",
                args=[
                  ("place", @sf.t("web-pages.appearance.fonts." + ctx.place())),
                  ("script", @sf.t(font_script_short_key(ctx.place(), ctx.script() == 1))),
                ],
              )
            },
            fn() { fp_v4_sec_heading },
          )
          |> ignore
          picker_sec.box(fn(faces) {
            faces.points(Is(true)) |> ignore
            faces.reacts(fn() { faces.pointed_in() }, fn(on) { over_faces.set(on) })
            faces.owns(fn() { over_faces.set(false) }) |> ignore
            @sf.group_node(faces, fn(g) {
              g.pick(fn() { ctx.active_slot() }, fn(held, slot) {
                @sf.group_rows_node(held, fn(rows) {
                  face_rows_node(rows, ctx, slot, ctx.place(), ctx.script() == 1)
                })
              })
            })
          })
          |> ignore
        })
        |> ignore
      _ => font_advanced_node(sec, ctx, is_wide)
    }
  })
  |> ignore
}

///|
/// Interactive 3-zone live preview card in natural conversation order:
/// 1) User bubble (text) -> 2) Agent header (ui) -> 3) Agent prose lead (text) -> 4) Code block (code) -> 5) Tail (text).
fn font_preview_v4_node(parent : @view.View, ctx : FontPageCtx, is_wide : Bool) -> Unit {
  let ui_face = fn() { ctx.ui_face(is_wide) }
  let text_face = fn() { ctx.text_face(is_wide) }
  let code_face = fn() { ctx.code_face(is_wide) }
  let ui_cjk = fn() { ctx.cjk_override_for("ui") }
  let text_cjk = fn() { ctx.cjk_override_for("text") }
  let code_cjk = fn() { ctx.cjk_override_for("code") }
  let prose_scale = fn() { ctx.preview_prose_scale() }
  let code_scale = fn() { ctx.preview_code_scale() }
  let line_scale = fn() { ctx.preview_line_scale() }
  let select_role = fn(idx : Int) {
    if @signals.untracked(fn() { @settings.fonts_at.get() }) != idx {
      fonts_trying.set("")
      @settings.fonts_at.set(idx)
    }
  }
  let editing_badge = fn() {
    @sf.t(
      "web-pages.appearance.fonts.previewEditing",
      args=[
        ("place", @sf.t("web-pages.appearance.fonts." + ctx.place())),
        ("script", @sf.t(font_script_short_key(ctx.place(), ctx.script() == 1))),
      ],
    )
  }
  let zone_box = fn(col : @view.View, role_idx : Int, role_key : String, body : (@view.View) -> Unit) {
    let active = fn() { @settings.fonts_at.get() == role_idx }
    @sf.action_box_node(
      col,
      fn() { @sf.t("web-pages.appearance.fonts." + role_key) },
      fn(_) { select_role(role_idx) },
      fn(z) {
        @sf.style_node(z, fn() { fp_v4_zone })
        z.min_width(Is(Some(0.0))) |> ignore
        z.box(fn(bar) {
          bar
          .width(Is(Some(2.5)))
          .shrink(Is(0.0))
          .radius(Is(2.0))
          .ground(By(fn() { if active() { @sf.theme().p.accent_text } else { 0L } }))
          |> ignore
        })
        |> ignore
        z.box(fn(content) {
          content.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(4.0)) |> ignore
          body(content)
        })
        |> ignore
      },
    )
    |> ignore
  }
  parent.box(fn(card) {
    @sf.style_node(card, fn() { fp_v4_preview_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    // 1. User bubble (正文)
    zone_box(card, 1, "text", fn(c) {
      c.box(fn(mine_row) {
        @sf.style_node(mine_row, fn() { fp_mine_room })
        mine_row.box(fn(bubble) {
          @sf.style_node(bubble, fn() { fp_v4_bubble })
          face_in_node(
            bubble,
            fn() { @sf.t("web-pages.appearance.fonts.sampleMine") },
            fn() { text_face().unwrap_or(0) },
            fp_v4_mine_words,
            person=fn() { text_face() is None },
            cjk=text_cjk,
            size_scale=prose_scale,
            line_scale~,
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    // 2. Agent header (界面)
    zone_box(card, 0, "ui", fn(c) {
      if is_wide {
        c.box(fn(top_row) {
          @sf.style_node(top_row, fn() { fp_v4_who_row })
          top_row.box(fn(who) {
            @sf.style_node(who, fn() { fp_who_line })
            who.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            face_in_node(who, fn() { "Claude" }, ui_face, fp_who_words, cjk=ui_cjk) |> ignore
            face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_time_words, cjk=ui_cjk)
            |> ignore
          })
          |> ignore
          top_row.box(fn(badge) {
            @sf.style_node(badge, fn() { fp_v4_edit_badge })
            badge.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(badge, editing_badge, fn() { fp_v4_edit_badge_words }) |> ignore
          })
          |> ignore
        })
        |> ignore
      } else {
        c.box(fn(who) {
          @sf.style_node(who, fn() { fp_who_line })
          face_in_node(who, fn() { "Claude" }, ui_face, fp_who_words, cjk=ui_cjk) |> ignore
          face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_time_words, cjk=ui_cjk)
          |> ignore
        })
        |> ignore
        @sf.words_node(c, editing_badge, fn() { fp_v4_edit_badge_words }) |> ignore
      }
    })
    // 3. Agent prose lead (正文, with inline code `preventDefault` / `onSubmit` rendered in code_face)
    zone_box(card, 1, "text", fn(c) {
      @sf.markdown_node(
        c,
        fn() { @sf.t("web-pages.appearance.fonts.sampleText") },
        copy=false,
        typography=fn() {
          {
            prose_scale: prose_scale(),
            code_scale: code_scale(),
            line_scale: line_scale(),
            text_cjk: text_cjk(),
            code_cjk: code_cjk(),
          }
        },
        text_face~,
        code_face~,
      )
      |> ignore
    })
    // 4. Code block (代码, immediately following the colon)
    zone_box(card, 2, "code", fn(c) {
      @sf.markdown_node(
        c,
        fn() { fp_sample_code },
        copy=false,
        typography=fn() {
          {
            prose_scale: prose_scale(),
            code_scale: code_scale(),
            line_scale: line_scale(),
            text_cjk: text_cjk(),
            code_cjk: code_cjk(),
          }
        },
        text_face~,
        code_face~,
      )
      |> ignore
    })
    // 5. Agent prose tail (正文)
    zone_box(card, 1, "text", fn(c) {
      face_in_node(
        c,
        fn() { @sf.t("web-pages.appearance.fonts.sampleAfter") },
        fn() { text_face().unwrap_or(0) },
        fp_v4_prose_words,
        person=fn() { text_face() is None },
        cjk=text_cjk,
        size_scale=prose_scale,
        line_scale~,
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// 4 curated style cards: 4-col on Wide, equal-width 2x2 grid on Narrow (strict 50%/50% center seam alignment).
fn font_style_cards_node(parent : @view.View, ctx : FontPageCtx, is_wide : Bool) -> Unit {
  let card_at = fn(row : @view.View, idx : Int) {
    let preset = font_presets[idx]
    let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key) }
    let sub = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key + "Sub") }
    let on = fn() { font_preset_matches(preset, fn(s) { ctx.chosen_of(s) }) }
    let bytes = fn() {
      preset_needed_bytes(preset, ctx.all(), items(ctx.files_state(), "kept"), ctx.core.face_here)
    }
    let latin_face = fn() {
      match preset.ui {
        Some(id) => ctx.shown_in(id)
        None => 0
      }
    }
    let cjk_face = fn() {
      match preset.text_cjk {
        Some(id) => ctx.shown_in(id)
        None =>
          match preset.ui_cjk {
            Some(id) => ctx.shown_in(id)
            None => 0
          }
      }
    }
    row.box(fn(slot) {
      slot.width(Is(Some(0.0))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      slot.reacts(fn() { @sf.lit_in_node(slot) }, fn(lit) {
        if lit {
          preset_trying.set(idx)
        } else if preset_trying.untracked() == idx {
          preset_trying.set(-1)
        }
      })
      slot.owns(fn() {
        if preset_trying.untracked() == idx {
          preset_trying.set(-1)
        }
      })
      |> ignore
      @sf.action_box_node(
        slot,
        title,
        fn(_) {
          clear_fonts_undo()
          @settings.set_fonts_preset(ctx.core, preset_patch(preset), reset_cjk_optics=true)
        },
        fn(card) {
          let lit = fn() { @sf.lit_node(card) }
          @sf.style_node(card, fn() {
            if on() { fp_v4_style_card_on } else if lit() { fp_v4_style_card_hot } else { fp_v4_style_card }
          })
          card.grow(Is(1.0)).edge(By(fn() {
            if on() {
              (1.0, @sf.theme().p.accent)
            } else if lit() {
              (0.5, @sf.theme().p.line_strong)
            } else {
              (0.5, @sf.theme().p.line)
            }
          }))
          |> ignore
          card.box(fn(top) {
            @sf.style_node(top, fn() { fp_v4_style_top })
            top.box(fn(spec) {
              @sf.style_node(spec, fn() { fp_v4_spec_row })
              face_in_node(spec, fn() { "Aa" }, latin_face, fp_v4_spec_words) |> ignore
              face_in_node(spec, fn() { "字" }, cjk_face, fp_v4_spec_words) |> ignore
            })
            |> ignore
            top.show(at_once=true, on, fn(ck) {
              @sf.icon_node(ck, "check", 14.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
            })
            top.show(at_once=true, fn() { !on() && bytes() > 0.0 }, fn(sz) {
              @sf.words_node(sz, fn() { face_size(bytes()) }, fn() { fp_preset_size }) |> ignore
            })
          })
          |> ignore
          @sf.words_node(card, title, fn() { if on() { fp_preset_title_on } else { fp_preset_title } }) |> ignore
          @sf.words_node(card, sub, fn() { fp_v4_style_sub }) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v4_section })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.presets") }, fn() { fp_v4_sec_heading }) |> ignore
    if is_wide {
      sec.box(fn(row) {
        @sf.style_node(row, fn() { fp_v4_cards_row_wide })
        for i in 0..<4 {
          card_at(row, i)
        }
      })
      |> ignore
    } else {
      sec.box(fn(grid) {
        @sf.style_node(grid, fn() { fp_v4_cards_grid_narrow })
        grid.box(fn(r1) {
          @sf.style_node(r1, fn() { fp_v4_cards_row_narrow })
          card_at(r1, 0)
          card_at(r1, 1)
        })
        |> ignore
        grid.box(fn(r2) {
          @sf.style_node(r2, fn() { fp_v4_cards_row_narrow })
          card_at(r2, 2)
          card_at(r2, 3)
        })
        |> ignore
      })
      |> ignore
    }
  })
  |> ignore
}

///|
/// 3-role x 2-script pairing matrix: clicking any role label or script slot selects it for the contextual picker.
fn font_pairing_matrix_node(parent : @view.View, ctx : FontPageCtx, is_wide : Bool) -> Unit {
  let roles : Array[(Int, String, String)] = [(0, "ui", "uiSub"), (1, "text", "textSub"), (2, "code", "codeSub")]
  let slot_btn = fn(row : @view.View, role_idx : Int, role_key : String, is_cjk : Bool) {
    let slot_name = if is_cjk { font_cjk_slot_of(role_key) } else { role_key }
    let active = fn() { @settings.fonts_at.get() == role_idx && @settings.fonts_script_at.get() == (if is_cjk { 1 } else { 0 }) }
    let prefix = fn() { @sf.t(font_script_short_key(role_key, is_cjk)) }
    let val = fn() {
      let id = ctx.chosen_of(slot_name)
      if id == "" {
        if role_key == "text" { @sf.t("web-pages.appearance.fonts.followUi") } else { @sf.t("web-pages.appearance.fonts.default") }
      } else if id == "none" {
        @sf.t("web-pages.appearance.fonts.cjkNone")
      } else {
        ctx.name_of_id(id)
      }
    }
    let btn_label = fn() {
      @sf.t("web-pages.appearance.fonts.matrix.slotLabel", args=[("script", prefix()), ("name", val())])
    }
    row.box(fn(wrap) {
      wrap.width(Is(Some(0.0))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.action_box_node(
        wrap,
        btn_label,
        fn(_) {
          fonts_trying.set("")
          @settings.fonts_at.set(role_idx)
          @settings.fonts_script_at.set(if is_cjk { 1 } else { 0 })
        },
        fn(btn) {
          let lit = fn() { @sf.lit_node(btn) }
          @sf.style_node(btn, fn() {
            if active() { fp_v4_slot_btn_on } else if lit() { fp_v4_slot_btn_hot } else { fp_v4_slot_btn }
          })
          btn
          .grow(Is(1.0))
          .radius(Is(10.0))
          .edge(By(fn() {
            if active() {
              (1.0, @sf.theme().p.accent)
            } else if lit() {
              (0.5, @sf.theme().p.line_strong)
            } else {
              (0.5, @sf.theme().p.line)
            }
          }))
          |> ignore
          @sf.words_node(btn, prefix, fn() { if active() { fp_v4_slot_tag_on } else { fp_v4_slot_tag } }) |> ignore
          btn.box(fn(vw) {
            vw.row(Is(true)).lies_along(Is(End)).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(vw, val, fn() { if active() { fp_v4_slot_val_on } else { fp_v4_slot_val } }) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v4_section })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.matrix.title") }, fn() { fp_v4_sec_heading }) |> ignore
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v4_matrix_card })
      card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      for item in roles {
        let (idx, role_key, sub_key) = item
        card.box(fn(r) {
          @sf.style_node(r, fn() { if is_wide { fp_v4_matrix_row_wide } else { fp_v4_matrix_row_narrow } })
          @sf.action_box_node(
            r,
            fn() { @sf.t("web-pages.appearance.fonts." + role_key) },
            fn(_) {
              fonts_trying.set("")
              @settings.fonts_at.set(idx)
              @settings.fonts_script_at.set(0)
            },
            fn(meta) {
              @sf.style_node(meta, fn() { if is_wide { fp_v4_matrix_meta_wide } else { fp_v4_matrix_meta_narrow } })
              if is_wide {
                meta.width(Is(Some(148.0))).shrink(Is(0.0)) |> ignore
              }
              @sf.words_node(meta, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn() { fp_v4_matrix_role })
              |> ignore
              @sf.words_node(meta, fn() { @sf.t("web-pages.appearance.fonts.matrix." + sub_key) }, fn() { fp_v4_matrix_sub })
              |> ignore
            },
          )
          |> ignore
          r.box(fn(slots) {
            @sf.style_node(slots, fn() { fp_v4_matrix_slots })
            slots.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
            slot_btn(slots, idx, role_key, false)
            slot_btn(slots, idx, role_key, true)
          })
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
fn face_glyph_badge_node(
  parent : @view.View,
  glyph : () -> String,
  face : () -> Int,
  on : () -> Bool,
) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { if on() { fp_v4_glyph_badge_on } else { fp_v4_glyph_badge } })
    b.min_width(Is(Some(36.0))).height(Is(Some(28.0))).shrink(Is(0.0)) |> ignore
    b.edge(By(fn() { if on() { (1.0, @sf.theme().p.accent) } else { (0.5, @sf.theme().p.line) } })) |> ignore
    face_in_node(b, glyph, face, if on() { fp_v4_glyph_words_on } else { fp_v4_glyph_words }) |> ignore
  })
  |> ignore
}

///|
fn font_glyph_slider_node(
  parent : @view.View,
  label : () -> String,
  value_text : () -> String,
  glyph_small : String,
  glyph_large : String,
  value : () -> Double,
  min : Double,
  max : Double,
  step : Double,
  on_change : (Double) -> Unit,
  on_commit : (Double) -> Unit,
) -> Unit {
  parent.box(fn(col) {
    @sf.style_node(col, fn() { fp_slider_col })
    col.box(fn(head) {
      @sf.style_node(head, fn() { fp_slider_head })
      head.box(fn(l) {
        l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(l, label, fn() { fp_adv_row_label }) |> ignore
      })
      |> ignore
      @sf.words_node(head, value_text, fn() { fp_adv_row_value }) |> ignore
    })
    |> ignore
    col.box(fn(row) {
      @sf.style_node(row, fn() { fp_v4_slider_track_row })
      @sf.words_node(row, fn() { glyph_small }, fn() { fp_v4_glyph_sm }) |> ignore
      row.box(fn(sw) {
        sw.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.value_slider_node(sw, label, value, on_change, min~, max~, step~, format=fn(n) { "\{n}%" }, on_commit~)
        |> ignore
      })
      |> ignore
      @sf.words_node(row, fn() { glyph_large }, fn() { fp_v4_glyph_lg }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn font_line_height_cards_node(
  parent : @view.View,
  is_wide : Bool,
  chosen : () -> String,
  choose : (String) -> Unit,
) -> Unit {
  let opts : Array[(String, String, Double)] = [
    ("compact", "web-pages.appearance.fonts.advanced.lineCompact", 1.5),
    ("normal", "web-pages.appearance.fonts.advanced.lineNormal", 3.0),
    ("relaxed", "web-pages.appearance.fonts.advanced.lineRelaxed", 4.5),
  ]
  parent.box(fn(wrap) {
    @sf.style_node(wrap, fn() { if is_wide { fp_v4_lh_inline_wide } else { fp_v4_lh_col } })
    wrap.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    @sf.words_node(
      wrap,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") },
      fn() { if is_wide { fp_adv_row_label_inline } else { fp_adv_row_label } },
    )
    |> ignore
    wrap.box(fn(tray) {
      @sf.style_node(tray, fn() { if is_wide { fp_v4_lh_tray_wide } else { fp_v4_lh_tray } })
      tray.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      if is_wide {
        tray.width(Is(Some(288.0))).shrink(Is(0.0)) |> ignore
      }
      for opt in opts {
        let (key, label_key, gap) = opt
        let on = fn() { chosen() == key }
        tray.box(fn(slot) {
          slot.width(Is(Some(0.0))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.action_box_node(slot, fn() { @sf.t(label_key) }, fn(_) { choose(key) }, fn(btn) {
            let lit = fn() { @sf.lit_node(btn) }
            @sf.style_node(btn, fn() {
              if on() { fp_v4_lh_btn_on } else if lit() { fp_v4_lh_btn_hot } else { fp_v4_lh_btn }
            })
            btn.box(fn(ico) {
              ico.width(Is(Some(14.0))).gap(Is(gap)).shrink(Is(0.0)) |> ignore
              for w in [14.0, 11.0, 13.0] {
                ico.box(fn(bar) {
                  bar
                  .width(Is(Some(w)))
                  .height(Is(Some(1.5)))
                  .radius(Is(1.0))
                  .ground(By(fn() { if on() { @sf.theme().p.accent_text } else { @sf.theme().p.muted } }))
                  |> ignore
                })
                |> ignore
              }
            })
            |> ignore
            @sf.words_node(btn, fn() { @sf.t(label_key) }, fn() { if on() { fp_v4_lh_label_on } else { fp_v4_lh_label } })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// Collapsible V4 "排版与字号细节" section: high-density 2-col on Wide, 1-col on Narrow.
fn font_advanced_node(parent : @view.View, ctx : FontPageCtx, is_wide : Bool) -> Unit {
  open_advanced_if_fixture(parent)
  let adv_card = fn(host : @view.View, make : (@view.View) -> Unit) {
    host.box(fn(card) {
      @sf.style_node(card, fn() { fp_v4_adv_card })
      card.grow(Is(1.0)).edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      make(card)
    })
    |> ignore
  }
  let adv_row_card = fn(host : @view.View, make : (@view.View) -> Unit) {
    host.box(fn(card) {
      @sf.style_node(card, fn() { fp_v4_adv_row_card })
      card.grow(Is(1.0)).edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
      make(card)
    })
    |> ignore
  }
  let two_col = fn(host : @view.View, left : (@view.View) -> Unit, right : (@view.View) -> Unit) {
    host.box(fn(grid) {
      @sf.style_node(grid, fn() { if is_wide { fp_v4_two_col_wide } else { fp_v4_two_col_narrow } })
      grid.box(fn(a) {
        if is_wide { a.width(Is(Some(0.0))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }
        left(a)
      })
      |> ignore
      grid.box(fn(b) {
        if is_wide { b.width(Is(Some(0.0))).grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore }
        right(b)
      })
      |> ignore
    })
    |> ignore
  }
  let summary = fn() -> String {
    let n = font_typo_custom_count(ctx.typo())
    if n > 0 {
      @sf.t("web-pages.appearance.fonts.advanced.summaryCustom", args=[("n", n.to_string())])
    } else {
      @sf.t("web-pages.appearance.fonts.default")
    }
  }
  let set_typo = fn(m : Map[String, Json]) {
    clear_fonts_undo()
    @settings.set_typography(ctx.core, Json::object(m))
  }
  @sf.group_node(parent, fn(g) {
    @sf.action_box_node(
      g,
      fn() { @sf.t("web-pages.appearance.fonts.advanced.title") },
      fn(_) { advanced_open.set(!advanced_open.untracked()) },
      fn(head) {
        @sf.style_node(head, fn() { if @sf.lit_node(head) { fp_adv_head_hot } else { fp_adv_head } })
        head.box(fn(l) {
          l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(l, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn() { fp_adv_title }) |> ignore
        })
        |> ignore
        head.box(fn(r) {
          @sf.style_node(r, fn() { fp_adv_right })
          @sf.words_node(r, summary, fn() { fp_adv_summary }) |> ignore
          @sf.icon_node(r, "chevron-right", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
    g.show(at_once=true, fn() { advanced_open.get() }, fn(body) {
      @sf.style_node(body, fn() { fp_adv_body })
      // Group 1: Reading & code layout
      body.box(fn(g1) {
        @sf.style_node(g1, fn() { fp_adv_group })
        @sf.words_node(g1, fn() { @sf.t("web-pages.appearance.fonts.advanced.readingGroup") }, fn() { fp_adv_group_title })
        |> ignore
        two_col(
          g1,
          fn(c1) {
            adv_card(c1, fn(card) {
              let text_size_val = fn() {
                match text_size_drag.get() {
                  Some(v) => v
                  None => font_typo_num(ctx.typo(), "textSize", 100.0)
                }
              }
              font_glyph_slider_node(
                card,
                fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
                fn() { "\{text_size_val().round().to_int()}%" },
                "A",
                "A",
                text_size_val,
                85.0,
                130.0,
                5.0,
                fn(v) { text_size_drag.set(Some(v)) },
                fn(v) {
                  text_size_drag.set(None)
                  let m : Map[String, Json] = Map([])
                  m["textSize"] = ToJson::to_json(v.round().to_int())
                  set_typo(m)
                },
              )
            })
          },
          fn(c2) {
            adv_card(c2, fn(card) {
              let code_scale_val = fn() {
                match code_scale_drag.get() {
                  Some(v) => v
                  None => font_typo_num(ctx.typo(), "codeScale", 100.0)
                }
              }
              font_glyph_slider_node(
                card,
                fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
                fn() { "\{code_scale_val().round().to_int()}%" },
                "</>",
                "</>",
                code_scale_val,
                85.0,
                115.0,
                5.0,
                fn(v) { code_scale_drag.set(Some(v)) },
                fn(v) {
                  code_scale_drag.set(None)
                  let m : Map[String, Json] = Map([])
                  m["codeScale"] = ToJson::to_json(v.round().to_int())
                  set_typo(m)
                },
              )
            })
          },
        )
        let autospace_col = fn(c1 : @view.View) {
          let on = fn() { font_typo_bool(ctx.typo(), "cjkAutoSpace", true) }
          adv_row_card(c1, fn(row) {
            row.box(fn(left) {
              @sf.style_node(left, fn() { fp_v4_compact_sw_left })
              left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") }, fn() { fp_adv_row_label_inline })
              |> ignore
              left.box(fn(cmp) {
                @sf.style_node(cmp, fn() { fp_v4_cmp_row })
                cmp.box(fn(p0) {
                  @sf.style_node(p0, fn() { if !on() { fp_v4_cmp_pill_on } else { fp_v4_cmp_pill } })
                  @sf.words_node(p0, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceOff") }, fn() {
                    if !on() { fp_v4_cmp_words_on } else { fp_v4_cmp_words }
                  })
                  |> ignore
                })
                |> ignore
                cmp.box(fn(p1) {
                  @sf.style_node(p1, fn() { if on() { fp_v4_cmp_pill_on } else { fp_v4_cmp_pill } })
                  @sf.words_node(p1, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpaceOn") }, fn() {
                    if on() { fp_v4_cmp_words_on } else { fp_v4_cmp_words }
                  })
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            @sf.switch_node(row, on, fn(v) {
              let m : Map[String, Json] = Map([])
              m["cjkAutoSpace"] = ToJson::to_json(v)
              set_typo(m)
            }, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") })
            |> ignore
          })
        }
        let lig_col = fn(c2 : @view.View) {
          c2.show(at_once=true, fn() { @ui.platform() != 4 }, fn(lig_wrap) {
            let on = fn() { font_typo_bool(ctx.typo(), "codeLigatures", true) }
            adv_row_card(lig_wrap, fn(row) {
              row.box(fn(left) {
                @sf.style_node(left, fn() { fp_v4_compact_sw_left })
                left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.words_node(left, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") }, fn() { fp_adv_row_label_inline })
                |> ignore
                left.box(fn(sample) {
                  @sf.style_node(sample, fn() { if on() { fp_v4_cmp_pill_on } else { fp_v4_cmp_pill } })
                  face_in_node(sample, fn() { "=> !== ===" }, fn() { ctx.code_face(is_wide).unwrap_or(0) }, fp_v4_lig_words) |> ignore
                })
                |> ignore
              })
              |> ignore
              @sf.switch_node(row, on, fn(v) {
                let m : Map[String, Json] = Map([])
                m["codeLigatures"] = ToJson::to_json(v)
                set_typo(m)
              }, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") })
              |> ignore
            })
          })
        }
        if @ui.platform() == 4 {
          autospace_col(g1)
        } else {
          two_col(g1, autospace_col, lig_col)
        }
        let lh_val = fn() {
          match text(ctx.typo(), "lineHeight") {
            "compact" => "compact"
            "relaxed" => "relaxed"
            _ => "normal"
          }
        }
        font_line_height_cards_node(g1, is_wide, lh_val, fn(v) {
          let m : Map[String, Json] = Map([])
          m["lineHeight"] = ToJson::to_json(v)
          set_typo(m)
        })
      })
      |> ignore
      // Group 2: CJK-Latin optical balance
      body.box(fn(g2) {
        @sf.style_node(g2, fn() { fp_adv_group })
        let active_cjk_id = fn() { text(ctx.faces_view(), font_cjk_slot_of(ctx.place())) }
        let has_cjk = fn() { active_cjk_id() != "" }
        let scale_key = fn() { font_cjk_scale_key(ctx.place()) }
        let weight_key = fn() { font_cjk_weight_key(ctx.place()) }
        let scale_val = fn() {
          match cjk_scale_drag.get() {
            Some((k, v)) if k == scale_key() => v
            _ => font_typo_num(ctx.typo(), scale_key(), 100.0)
          }
        }
        let weight_idx = fn() {
          let w = font_typo_num(ctx.typo(), weight_key(), 0.0).round().to_int()
          if w <= -50 { 0 } else if w >= 50 { 2 } else { 1 }
        }
        let can_reset_follow = fn() {
          ctx.place() == "text" &&
          ctx.chosen_of("textCjk") == "" &&
          (font_typo_bool(ctx.typo(), "textCjkScaleOwn", false) || font_typo_bool(ctx.typo(), "textCjkWeightOwn", false))
        }
        g2.box(fn(head) {
          @sf.style_node(head, fn() { fp_v4_ratio_head })
          @sf.words_node(
            head,
            fn() {
              @sf.t("web-pages.appearance.fonts.advanced.cjkRatioTitle", args=[("place", @sf.t("web-pages.appearance.fonts." + ctx.place()))])
            },
            fn() { fp_adv_group_title },
          )
          |> ignore
          head.box(fn(right) {
            @sf.style_node(right, fn() { fp_v4_ratio_right })
            right.show(at_once=true, has_cjk, fn(pill) {
              @sf.style_node(pill, fn() { fp_v4_ratio_pill })
              pill.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
              let primary_f = fn() {
                match ctx.place() {
                  "ui" => ctx.ui_face(is_wide)
                  "text" => ctx.text_face(is_wide).unwrap_or(0)
                  _ => ctx.code_face(is_wide).unwrap_or(0)
                }
              }
              let cjk_ov = fn() -> @view.CjkOverride? {
                let f = ctx.cjk_host_face(active_cjk_id())
                if f > 0 { Some({ face: f, scale: scale_val() / 100.0, weight_off: (weight_idx() - 1) * 100 }) } else { None }
              }
              face_in_node(pill, fn() { "Aa 字体" }, primary_f, fp_v4_ratio_words, cjk=cjk_ov) |> ignore
            })
            right.show(at_once=true, can_reset_follow, fn(rf) {
              @sf.button_node(
                rf,
                fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") },
                fn() {
                  let m : Map[String, Json] = Map([])
                  m["textCjkScale"] = Json::null()
                  m["textCjkWeight"] = Json::null()
                  set_typo(m)
                },
              )
              |> ignore
            })
          })
          |> ignore
        })
        |> ignore
        g2.show(at_once=true, fn() { !has_cjk() }, fn(h) {
          @sf.words_node(h, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkHint") }, fn() { fp_adv_hint }) |> ignore
        })
        g2.show(at_once=true, has_cjk, fn(controls) {
          two_col(
            controls,
            fn(c1) {
              adv_card(c1, fn(card) {
                font_glyph_slider_node(
                  card,
                  fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
                  fn() { "\{scale_val().round().to_int()}%" },
                  "字",
                  "字",
                  scale_val,
                  85.0,
                  115.0,
                  1.0,
                  fn(v) { cjk_scale_drag.set(Some((scale_key(), v))) },
                  fn(v) {
                    cjk_scale_drag.set(None)
                    let m : Map[String, Json] = Map([])
                    m[scale_key()] = ToJson::to_json(v.round().to_int())
                    set_typo(m)
                  },
                )
              })
            },
            fn(c2) {
              adv_card(c2, fn(card) {
                @sf.words_node(card, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") }, fn() { fp_adv_row_label })
                |> ignore
                @sf.seg_node(
                  card,
                  fn() {
                    [
                      @sf.t("web-pages.appearance.fonts.advanced.weightLight"),
                      @sf.t("web-pages.appearance.fonts.advanced.weightAuto"),
                      @sf.t("web-pages.appearance.fonts.advanced.weightBold"),
                    ]
                  },
                  weight_idx,
                  fn(i) {
                    let m : Map[String, Json] = Map([])
                    m[weight_key()] = ToJson::to_json(if i == 0 { -100 } else if i == 2 { 100 } else { 0 })
                    set_typo(m)
                  },
                  said=@signals.untracked(fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") }),
                )
                |> ignore
              })
            },
          )
        })
      })
      |> ignore
      body.box(fn(actions) {
        @sf.style_node(actions, fn() { fp_adv_action_row })
        @sf.button_node(
          actions,
          fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") },
          fn() {
            clear_fonts_undo()
            @settings.set_typography(ctx.core, Json::null())
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
}

///|
// kept across runs: static style constants
let font_check : Double = 14.0
let local_panel_w : Double = 300.0
let local_list_most : Double = 320.0
let local_most : Int = 400
// kept across runs: a value (no field of it changes)
let fp_preset_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_preset_title_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_preset_size : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_adv_head : @ui.Style = @ui.css("row w=Full px=S4 py=S3 gap=S2 radius=Xl2 align=AStart")
// kept across runs: a value (no field of it changes)
let fp_adv_head_hot : @ui.Style = fp_adv_head.then(@ui.css("bg=Hover"))
// kept across runs: a value (no field of it changes)
let fp_adv_title : @ui.TextStyle = @ui.text_style(size=Title, weight=Medium, color=Fg, w=Full)
// kept across runs: a value (no field of it changes)
let fp_adv_right : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_adv_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_adv_body : @ui.Style = @ui.css("w=Full px=S4 pb=S4 gap=S4")
// kept across runs: a value (no field of it changes)
let fp_adv_group : @ui.Style = @ui.css("w=Full gap=S3")
// kept across runs: a value (no field of it changes)
let fp_adv_group_title : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, w=Full)
// kept across runs: a value (no field of it changes)
let fp_adv_hint : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full)
// kept across runs: a value (no field of it changes)
let fp_adv_row_label : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, w=Full)
// kept across runs: a value (no field of it changes)
let fp_adv_row_label_inline : @ui.TextStyle = @ui.text_style(size=Body, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_adv_row_value : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_slider_col : @ui.Style = @ui.css("w=Full gap=S1")
// kept across runs: a value (no field of it changes)
let fp_slider_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")
// kept across runs: a value (no field of it changes)
let fp_adv_action_row : @ui.Style = @ui.css("row w=Full justify=JEnd pt=S1 pb=S1 pr=S1")
// kept across runs: a value (no field of it changes)
let fp_mine_room : @ui.Style = @ui.css("row w=Full justify=JEnd")
// kept across runs: a value (no field of it changes)
let fp_who_line : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_who_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=AccentText)
// kept across runs: a value (no field of it changes)
let fp_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle)
// kept across runs: a value (no field of it changes)
let face_name_words : @ui.TextStyle = @ui.text_style(size=Title, color=Fg, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let face_sample_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let face_status_room : @ui.Style = @ui.style(max_w=@sf.face_status_most)
// kept across runs: a value (no field of it changes)
let face_status_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value (no field of it changes)
let local_search : @ui.Style = @ui.css("w=Full pb=S1_5")
// kept across runs: a value (no field of it changes)
let local_filter_row : @ui.Style = @ui.css("row w=Full pb=S1_5 gap=S1_5")
// kept across runs: a value (no field of it changes)
let local_row : @ui.Style = @ui.css("row w=Full px=S2_5 gap=S2 align=ACenter")
// kept across runs: a value (no field of it changes)
let local_row_hot : @ui.Style = local_row.then(@ui.css("bg=Hover"))
// kept across runs: a value (no field of it changes)
let local_name : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, color=Fg, wrap=false, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let local_sub_name : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let local_note_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S2")
// kept across runs: a value (no field of it changes)
let local_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)
// kept across runs: a value (no field of it changes)
let fp_v4_reset : @ui.Style = @ui.css("px=S2_5 py=S1 radius=Md align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_reset_hot : @ui.Style = fp_v4_reset.then(@ui.css("bg=Hover"))
// kept across runs: a value (no field of it changes)
let fp_v4_reset_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_undo_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_preview_card : @ui.Style = @ui.css("w=Full p=S3 gap=S2 radius=Xl2 bg=Card")
// kept across runs: a value (no field of it changes)
let fp_v4_bubble : @ui.Style = @ui.css("px=S3 py=S1_5 radius=Lg bg=Surface")
// kept across runs: a value (no field of it changes)
let fp_v4_zone : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_who_row : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
// kept across runs: a value (no field of it changes)
let fp_v4_edit_badge : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Sm bg=Surface align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_edit_badge_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_v4_mine_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L5, color=Fg)
// kept across runs: a value (no field of it changes)
let fp_v4_prose_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L6, color=Fg, w=Full)
// kept across runs: a value (no field of it changes)
let fp_v4_section : @ui.Style = @ui.css("w=Full gap=S2")
// kept across runs: a value (no field of it changes)
let fp_v4_sec_heading : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, w=Full)
// kept across runs: a value (no field of it changes)
let fp_v4_cards_row_wide : @ui.Style = @ui.css("row w=Full gap=S2_5 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_cards_grid_narrow : @ui.Style = @ui.css("w=Full gap=S2")
// kept across runs: a value (no field of it changes)
let fp_v4_cards_row_narrow : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_style_card : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=Card")
// kept across runs: a value (no field of it changes)
let fp_v4_style_card_hot : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=Hover")
// kept across runs: a value (no field of it changes)
let fp_v4_style_card_on : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1 radius=Xl2 bg=AccentBg")
// kept across runs: a value (no field of it changes)
let fp_v4_style_top : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_spec_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_spec_words : @ui.TextStyle = @ui.text_style(size=Heading, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_style_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_card : @ui.Style = @ui.css("w=Full p=S2 gap=S2 radius=Xl2 bg=Card")
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_row_wide : @ui.Style = @ui.css("row w=Full gap=S3 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_row_narrow : @ui.Style = @ui.css("w=Full gap=S1_5")
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_meta_wide : @ui.Style = @ui.css("gap=S0_5 justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_meta_narrow : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_role : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_v4_matrix_slots : @ui.Style = @ui.css("row gap=S2 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=Surface align=ACenter justify=JBetween")
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn_hot : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=Hover align=ACenter justify=JBetween")
// kept across runs: a value (no field of it changes)
let fp_v4_slot_btn_on : @ui.Style = @ui.css("row px=S2_5 py=S1_5 gap=S1_5 bg=AccentBg align=ACenter justify=JBetween")
// kept across runs: a value (no field of it changes)
let fp_v4_slot_tag : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_slot_tag_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_slot_val : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Cut, wrap=false, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_v4_slot_val_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, w=Cut, wrap=false, max_lines=1)
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_badge : @ui.Style = @ui.css("mt=S2 px=S1_5 radius=Full bg=Surface align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_badge_on : @ui.Style = @ui.css("mt=S2 px=S1_5 radius=Full bg=AccentBg align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_words_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_slider_track_row : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_sm : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_glyph_lg : @ui.TextStyle = @ui.text_style(size=Title, weight=Medium, color=Muted, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_lh_col : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S2 radius=Lg bg=Surface")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_inline_wide : @ui.Style = @ui.css("row w=Full px=S3 py=S2 gap=S3 radius=Lg bg=Surface align=ACenter justify=JBetween")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_tray : @ui.Style = @ui.css("row w=Full p=S0_5 gap=S1 radius=Md bg=Card")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_tray_wide : @ui.Style = @ui.css("row p=S0_5 gap=S1 radius=Md bg=Card align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_btn : @ui.Style = @ui.css("row px=S2 py=S1 gap=S1_5 radius=Sm align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_btn_hot : @ui.Style = @ui.css("row px=S2 py=S1 gap=S1_5 radius=Sm bg=Hover align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_btn_on : @ui.Style = @ui.css("row px=S2 py=S1 gap=S1_5 radius=Sm bg=AccentBg align=ACenter justify=JCenter")
// kept across runs: a value (no field of it changes)
let fp_v4_lh_label : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_lh_label_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_adv_card : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S1_5 radius=Lg bg=Surface")
// kept across runs: a value (no field of it changes)
let fp_v4_adv_row_card : @ui.Style = @ui.css("row w=Full px=S3 py=S2_5 gap=S2 radius=Lg bg=Surface align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_two_col_wide : @ui.Style = @ui.css("row w=Full gap=S3 align=AStretch")
// kept across runs: a value (no field of it changes)
let fp_v4_two_col_narrow : @ui.Style = @ui.css("w=Full gap=S2_5")
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_right : @ui.Style = @ui.css("row gap=S2 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_compact_sw_left : @ui.Style = @ui.css("row gap=S2 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_head : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_pill : @ui.Style = @ui.css("px=S2_5 py=S1 radius=Md bg=Surface")
// kept across runs: a value (no field of it changes)
let fp_v4_ratio_words : @ui.TextStyle = @ui.text_style(size=Body, weight=Medium, color=Fg, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_pill : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Sm bg=Surface")
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_pill_on : @ui.Style = @ui.css("px=S2 py=S0_5 radius=Sm bg=AccentBg")
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_cmp_words_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
// kept across runs: a value (no field of it changes)
let fp_v4_lig_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false)
