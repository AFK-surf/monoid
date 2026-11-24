// V5 native still.fail-style font settings page built on `@sf.page_node`:
// - Zero `look_node` / `page-look` branching (pure flex-wrap responsive layout)
// - Ultra-compact sticky live preview card (~150px)
// - Compact 4-option preset strip (no fake Aa specimen cards)
// - Unified native font picker card (role overview segmented bar + script/source tabs + inline local fonts, zero popovers)
// - Single clean white card for Reading & Typography with 1px dividers (zero nested sub-cards).

///|
fn font_script_short_key(place : String, is_cjk : Bool) -> String {
  if is_cjk { "web-pages.appearance.fonts.scriptShort.cjk" } else if place == "code" { "web-pages.appearance.fonts.scriptShort.mono" } else { "web-pages.appearance.fonts.scriptShort.latin" }
}

///|
fn font_slot_sample_key(place : String, is_cjk : Bool) -> String {
  if is_cjk { "web-pages.appearance.fonts.sampleCjk" } else if place == "code" { "web-pages.appearance.fonts.sampleCode" } else { "web-pages.appearance.fonts.sampleLatin" }
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
    local_open.set(true)
  }
  v.owns(fn() { fonts_undo_snap.set(None) }) |> ignore
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.appearance.fonts.title") },
    fn() { ["presets", "picker", "advanced"] },
    fn(col, key) {
      match key {
        "presets" => font_presets_strip_node(col, ctx)
        "picker" => font_picker_unified_node(col, ctx, over_faces)
        _ => font_advanced_v5_node(col, ctx)
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
            font_preview_v5_node(card_host, ctx)
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
      @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v5_reset_hot } else { fp_v5_reset } })
      @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.undoReset") }, fn() { fp_v5_undo_words }) |> ignore
    })
    |> ignore
  })
  row.show(at_once=true, fn() { ctx.any_customized() }, fn(rw) {
    @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn(_) { ctx.reset_all() }, fn(btn) {
      @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v5_reset_hot } else { fp_v5_reset } })
      @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.resetAll") }, fn() { fp_v5_reset_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// Ultra-compact (~150px) 3-row sticky live preview card:
/// 1) Editing indicator + user bubble -> 2) Claude header + 1-line prose with inline code -> 3) 1-line code block.
fn font_preview_v5_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  let ui_face = fn() { ctx.ui_face() }
  let text_face = fn() { ctx.text_face() }
  let code_face = fn() { ctx.code_face() }
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
  let editing_label = fn() {
    @sf.t("web-pages.appearance.fonts.previewEditing", args=[
      ("place", @sf.t("web-pages.appearance.fonts." + ctx.place())),
      ("script", @sf.t(font_script_short_key(ctx.place(), ctx.script() == 1))),
    ])
  }
  let zone = fn(col : @view.View, role_idx : Int, role_key : String, body : (@view.View) -> Unit) {
    let active = fn() { @settings.fonts_at.get() == role_idx }
    @sf.action_box_node(col, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn(_) { select_role(role_idx) }, fn(z) {
      @sf.style_node(z, fn() { fp_v5_zone })
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
    @sf.style_node(card, fn() { fp_v5_preview_card })
    card.edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
    card.box(fn(top) {
      @sf.style_node(top, fn() { fp_v5_top_row })
      top.wraps(Is(Some(6.0))) |> ignore
      @sf.words_node(top, editing_label, fn() { fp_v5_editing_words }) |> ignore
      top.box(fn(bubble) {
        @sf.style_node(bubble, fn() { fp_v5_bubble })
        bubble.radius(Is(10.0)) |> ignore
        face_in_node(bubble, fn() { @sf.t("web-pages.appearance.fonts.sampleMine") }, fn() { text_face().unwrap_or(0) },
          fp_v5_mine_words, person=fn() { text_face() is None }, cjk=text_cjk, size_scale=prose_scale, line_scale~) |> ignore
      }) |> ignore
    }) |> ignore
    zone(card, 0, "ui", fn(c) {
      c.box(fn(who) {
        @sf.style_node(who, fn() { fp_v5_who_line })
        face_in_node(who, fn() { "Claude" }, ui_face, fp_v5_who_words, cjk=ui_cjk) |> ignore
        face_in_node(who, fn() { @sf.t("web-pages.appearance.fonts.sampleTime") }, ui_face, fp_v5_time_words, cjk=ui_cjk) |> ignore
      }) |> ignore
    })
    zone(card, 1, "text", fn(c) {
      @sf.markdown_node(
        c, fn() { @sf.t("web-pages.appearance.fonts.sampleText") },
        size=fn() { body_size * prose_scale() }, copy=false,
        typography=fn() { { prose_scale: prose_scale(), code_scale: code_scale(), line_scale: line_scale(), text_cjk: text_cjk(), code_cjk: code_cjk() } },
        text_face~, code_face~,
      ) |> ignore
    })
    zone(card, 2, "code", fn(c) {
      c.box(fn(cb) {
        @sf.style_node(cb, fn() { fp_v5_code_box })
        cb.radius(Is(10.0)) |> ignore
        face_in_node(cb, fn() { fp_sample_code }, fn() { code_face().unwrap_or(0) }, fp_v5_code_words,
          cjk=code_cjk, size_scale=code_scale, line_scale~, mono=true) |> ignore
      }) |> ignore
    })
  }) |> ignore
}

///|
/// Compact 4-option preset strip (4-col wide, auto 2x2 narrow via flex-wrap; zero fake Aa specimen headers).
fn font_presets_strip_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v5_presets_sec })
    @sf.words_node(sec, fn() { @sf.t("web-pages.appearance.fonts.presets") }, fn() { fp_v5_sec_heading }) |> ignore
    sec.box(fn(row) {
      @sf.style_node(row, fn() { fp_v5_preset_row })
      row.wraps(Is(Some(8.0))) |> ignore
      for i, preset in font_presets {
        let on = fn() { font_preset_matches(preset, fn(s) { ctx.chosen_of(s) }) }
        let title = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key) }
        let sub = fn() { @sf.t("web-pages.appearance.fonts.preset." + preset.key + "Sub") }
        let needed = fn() {
          let bytes = preset_needed_bytes(preset, ctx.all(), items(ctx.files_state(), "kept"), ctx.core.face_here)
          if bytes > 0.0 { face_size(bytes) } else { "" }
        }
        row.box(fn(slot) {
          slot.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(155.0))).min_width(Is(Some(155.0))) |> ignore
          slot.reacts(fn() { @sf.lit_in_node(slot) }, fn(lit) {
            if lit { preset_trying.set(i) } else if preset_trying.untracked() == i { preset_trying.set(-1) }
          })
          slot.owns(fn() { if preset_trying.untracked() == i { preset_trying.set(-1) } }) |> ignore
          @sf.action_box_node(slot, title, fn(_) {
            clear_fonts_undo()
            @settings.set_fonts_preset(ctx.core, preset_patch(preset), reset_cjk_optics=true)
          }, fn(card) {
            @sf.style_node(card, fn() {
              if on() { fp_v5_preset_on } else if @sf.lit_node(card) { fp_v5_preset_hot } else { fp_v5_preset }
            })
            card.grow(Is(1.0)).edge(By(fn() {
              if on() { (1.0, @sf.theme().p.accent_text) } else { (0.5, @sf.theme().p.line) }
            })) |> ignore
            card.box(fn(head) {
              @sf.style_node(head, fn() { fp_v5_preset_head })
              head.wraps(Is(Some(4.0))) |> ignore
              @sf.words_node(head, title, fn() { if on() { fp_v5_preset_title_on } else { fp_v5_preset_title } }) |> ignore
              head.show(at_once=true, on, fn(chk) {
                @sf.icon_node(chk, "check", 13.0, By(fn() { @sf.theme().p.accent_text })) |> ignore
              })
              head.show(at_once=true, fn() { !on() && needed() != "" }, fn(sz) {
                @sf.words_node(sz, needed, fn() { fp_v5_preset_size }) |> ignore
              })
            }) |> ignore
            @sf.words_node(card, sub, fn() { fp_v5_preset_sub }) |> ignore
          }) |> ignore
        }) |> ignore
      }
    }) |> ignore
  }) |> ignore
}

///|
/// Unified native still.fail font picker: 3-role overview segmented bar + single clean white card with script/source tabs.
fn font_picker_unified_node(parent : @view.View, ctx : FontPageCtx, over_faces : @signals.Signal[Bool]) -> Unit {
  let roles = ["ui", "text", "code"]
  let slot_short = fn(role_key : String, is_cjk : Bool) -> String {
    let id = ctx.chosen_of(if is_cjk { font_cjk_slot_of(role_key) } else { role_key })
    if id == "" {
      if role_key == "text" { @sf.t("web-pages.appearance.fonts.followUi") } else { @sf.t("web-pages.appearance.fonts.default") }
    } else if id == "none" {
      @sf.t("web-pages.appearance.fonts.cjkNone")
    } else {
      ctx.name_of_id(id)
    }
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v5_section })
    sec.box(fn(bar) {
      @sf.style_node(bar, fn() { fp_v5_role_bar })
      bar.wraps(Is(Some(4.0))) |> ignore
      for idx, role_key in roles {
        let active = fn() { @settings.fonts_at.get() == idx }
        bar.box(fn(cell) {
          cell.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(100.0))).min_width(Is(Some(96.0))) |> ignore
          @sf.action_box_node(cell, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn(_) {
            fonts_trying.set("")
            @settings.fonts_at.set(idx)
          }, fn(btn) {
            @sf.style_node(btn, fn() {
              if active() { fp_v5_role_on } else if @sf.lit_node(btn) { fp_v5_role_hot } else { fp_v5_role }
            })
            btn.radius(Is(10.0)).edge(By(fn() { if active() { (0.5, @sf.theme().p.line) } else { (0.0, 0L) } })) |> ignore
            @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts." + role_key) }, fn() {
              if active() { fp_v5_role_name_on } else { fp_v5_role_name }
            }) |> ignore
            @sf.words_node(btn, fn() { slot_short(role_key, false) + " / " + slot_short(role_key, true) }, fn() { fp_v5_role_pair }) |> ignore
          }) |> ignore
        }) |> ignore
      }
    }) |> ignore
    sec.box(fn(card) {
      @sf.style_node(card, fn() { fp_v5_card })
      card.clip().edge(By(fn() { (0.5, @sf.theme().p.line) })).points(Is(true)) |> ignore
      card.reacts(fn() { card.pointed_in() }, fn(on) { over_faces.set(on) })
      card.owns(fn() { over_faces.set(false) }) |> ignore
      card.box(fn(top) {
        @sf.style_node(top, fn() { fp_v5_picker_top })
        top.wraps(Is(Some(6.0))) |> ignore
        let tab_btn = fn(host : @view.View, label : () -> String, active : () -> Bool, press : () -> Unit) {
          @sf.action_box_node(host, label, fn(_) { press() }, fn(b) {
            @sf.style_node(b, fn() { if active() { fp_v5_tab_on } else if @sf.lit_node(b) { fp_v5_tab_hot } else { fp_v5_tab } })
            b.radius(Is(10.0)) |> ignore
            @sf.words_node(b, label, fn() { if active() { fp_v5_tab_words_on } else { fp_v5_tab_words } }) |> ignore
          }) |> ignore
        }
        top.box(fn(scripts) {
          @sf.style_node(scripts, fn() { fp_v5_tab_row })
          tab_btn(scripts, fn() { @sf.t(if ctx.place() == "code" { "web-pages.appearance.fonts.scriptShort.mono" } else { "web-pages.appearance.fonts.scriptShort.latin" }) },
            fn() { @settings.fonts_script_at.get() == 0 }, fn() { fonts_trying.set(""); @settings.fonts_script_at.set(0) })
          tab_btn(scripts, fn() { @sf.t("web-pages.appearance.fonts.scriptShort.cjk") },
            fn() { @settings.fonts_script_at.get() == 1 }, fn() { fonts_trying.set(""); @settings.fonts_script_at.set(1) })
        }) |> ignore
        top.show(at_once=true, fn() { @ui.can_list_local_fonts() }, fn(src_box) {
          src_box.box(fn(row) {
            @sf.style_node(row, fn() { fp_v5_tab_row })
            tab_btn(row, fn() { @sf.t("web-pages.appearance.fonts.curated") }, fn() { !local_open.get() }, fn() { fonts_trying.set(""); local_open.set(false) })
            tab_btn(row, fn() { @sf.t("web-pages.appearance.fonts.local") }, fn() { local_open.get() }, fn() { fonts_trying.set(""); local_open.set(true) })
          }) |> ignore
        })
      }) |> ignore
      fp_divider_node(card)
      card.pick(fn() { (ctx.active_slot(), local_open.get() && @ui.can_list_local_fonts()) }, fn(held, st) {
        let (slot, is_local) = st
        if is_local {
          local_faces_inline_node(held, ctx, slot, ctx.place(), ctx.script() == 1)
        } else {
          @sf.group_rows_node(held, fn(rows) { face_rows_node(rows, ctx, slot, ctx.place(), ctx.script() == 1) })
        }
      })
    }) |> ignore
  }) |> ignore
}

///|
fn fp_divider_node(parent : @view.View) -> Unit {
  parent.box(fn(d) {
    @sf.style_node(d, fn() { fp_v5_divider })
    d.height(Is(Some(1.0))).ground(By(fn() { @sf.theme().p.line })) |> ignore
  }) |> ignore
}

///|
fn fp_slider_col_node(
  parent : @view.View,
  label : () -> String,
  value_text : () -> String,
  glyph_sm : String,
  glyph_lg : String,
  value : () -> Double,
  min : Double,
  max : Double,
  step : Double,
  on_change : (Double) -> Unit,
  on_commit : (Double) -> Unit,
  extra_head? : (@view.View) -> Unit,
) -> Unit {
  parent.box(fn(col) {
    @sf.style_node(col, fn() { fp_v5_slider_col })
    col.box(fn(head) {
      @sf.style_node(head, fn() { fp_v5_slider_head })
      head.box(fn(left) {
        @sf.style_node(left, fn() { fp_v5_inline_row })
        left.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.words_node(left, label, fn() { fp_v5_row_label }) |> ignore
        match extra_head { Some(f) => f(left); None => () }
      }) |> ignore
      @sf.words_node(head, value_text, fn() { fp_v5_row_val }) |> ignore
    }) |> ignore
    col.box(fn(track) {
      @sf.style_node(track, fn() { fp_v5_slider_track })
      @sf.words_node(track, fn() { glyph_sm }, fn() { fp_v5_glyph_sm }) |> ignore
      track.box(fn(sw) {
        sw.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.value_slider_node(sw, label, value, on_change, min~, max~, step~, format=fn(n) { "\{n}%" }, on_commit~) |> ignore
      }) |> ignore
      @sf.words_node(track, fn() { glyph_lg }, fn() { fp_v5_glyph_lg }) |> ignore
    }) |> ignore
  }) |> ignore
}

///|
/// Single clean white card for Reading & Typography with 1px dividers (zero nested sub-cards).
fn font_advanced_v5_node(parent : @view.View, ctx : FontPageCtx) -> Unit {
  open_advanced_if_fixture(parent)
  let set_typo = fn(m : Map[String, Json]) { clear_fonts_undo(); @settings.set_typography(ctx.core, Json::object(m)) }
  let two_col = fn(host : @view.View, left : (@view.View) -> Unit, right : (@view.View) -> Unit) {
    host.box(fn(row) {
      @sf.style_node(row, fn() { fp_v5_adv_two_col })
      row.wraps(Is(Some(12.0))) |> ignore
      row.box(fn(a) { a.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(220.0))) |> ignore; left(a) }) |> ignore
      row.box(fn(b) { b.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(240.0))).min_width(Is(Some(220.0))) |> ignore; right(b) }) |> ignore
    }) |> ignore
  }
  let summary = fn() -> String {
    let n = font_typo_custom_count(ctx.typo())
    if n > 0 { @sf.t("web-pages.appearance.fonts.advanced.summaryCustom", args=[("n", n.to_string())]) } else { @sf.t("web-pages.appearance.fonts.default") }
  }
  parent.box(fn(sec) {
    @sf.style_node(sec, fn() { fp_v5_adv_sec })
    sec.box(fn(hdr) {
      @sf.style_node(hdr, fn() { fp_v5_adv_hdr })
      @sf.action_box_node(hdr, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn(_) {
        advanced_open.set(!advanced_open.untracked())
      }, fn(btn) {
        @sf.style_node(btn, fn() { fp_v5_adv_toggle })
        @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.title") }, fn() { fp_v5_sec_heading }) |> ignore
        @sf.words_node(btn, summary, fn() { fp_v5_adv_summary }) |> ignore
        btn.pick(fn() { advanced_open.get() }, fn(ic, open) {
          @sf.icon_node(ic, if open { "chevron-down" } else { "chevron-right" }, 13.0, By(fn() { @sf.theme().p.subtle })) |> ignore
        })
      }) |> ignore
      hdr.show(at_once=true, fn() { font_typo_custom_count(ctx.typo()) > 0 }, fn(rw) {
        @sf.action_box_node(rw, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn(_) {
          clear_fonts_undo()
          @settings.set_typography(ctx.core, Json::null())
        }, fn(btn) {
          @sf.style_node(btn, fn() { if @sf.lit_node(btn) { fp_v5_reset_hot } else { fp_v5_reset } })
          @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.reset") }, fn() { fp_v5_reset_words }) |> ignore
        }) |> ignore
      })
    }) |> ignore
    sec.show(at_once=true, fn() { advanced_open.get() }, fn(body) {
      body.box(fn(card) {
        @sf.style_node(card, fn() { fp_v5_card })
        card.clip().edge(By(fn() { (0.5, @sf.theme().p.line) })) |> ignore
        // Row 1: Message font size | Code relative size
        two_col(card, fn(c1) {
          let v = fn() { text_size_drag.get().unwrap_or(font_typo_num(ctx.typo(), "textSize", 100.0)) }
          fp_slider_col_node(c1, fn() { @sf.t("web-pages.appearance.fonts.advanced.textSize") },
            fn() { "\{v().round().to_int()}%" }, "A", "A", v, 85.0, 130.0, 5.0,
            fn(x) { text_size_drag.set(Some(x)) },
            fn(x) { text_size_drag.set(None); let m : Map[String, Json] = Map([]); m["textSize"] = ToJson::to_json(x.round().to_int()); set_typo(m) })
        }, fn(c2) {
          let v = fn() { code_scale_drag.get().unwrap_or(font_typo_num(ctx.typo(), "codeScale", 100.0)) }
          fp_slider_col_node(c2, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeScale") },
            fn() { "\{v().round().to_int()}%" }, "</>", "</>", v, 85.0, 115.0, 5.0,
            fn(x) { code_scale_drag.set(Some(x)) },
            fn(x) { code_scale_drag.set(None); let m : Map[String, Json] = Map([]); m["codeScale"] = ToJson::to_json(x.round().to_int()); set_typo(m) })
        })
        fp_divider_node(card)
        // Row 2: Line height segmented control
        card.box(fn(r2) {
          @sf.style_node(r2, fn() { fp_v5_adv_row })
          r2.wraps(Is(Some(8.0))) |> ignore
          @sf.words_node(r2, fn() { @sf.t("web-pages.appearance.fonts.advanced.lineHeight") }, fn() { fp_v5_row_label }) |> ignore
          let lh_keys = ["compact", "normal", "relaxed"]
          @sf.segmented_node(r2, fn() {
            [@sf.t("web-pages.appearance.fonts.advanced.lineCompact"), @sf.t("web-pages.appearance.fonts.advanced.lineNormal"), @sf.t("web-pages.appearance.fonts.advanced.lineRelaxed")]
          }, fn() {
            match text(ctx.typo(), "lineHeight") { "compact" => 0; "relaxed" => 2; _ => 1 }
          }, fn(i) { let m : Map[String, Json] = Map([]); m["lineHeight"] = ToJson::to_json(lh_keys[i]); set_typo(m) })
        }) |> ignore
        fp_divider_node(card)
        // Row 3: CJK AutoSpace | Code Ligatures
        two_col(card, fn(c1) {
          let on = fn() { font_typo_bool(ctx.typo(), "cjkAutoSpace", true) }
          c1.box(fn(row) {
            @sf.style_node(row, fn() { fp_v5_switch_row })
            row.box(fn(l) {
              @sf.style_node(l, fn() { fp_v5_inline_row })
              l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(l, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") }, fn() { fp_v5_row_label }) |> ignore
              @sf.words_node(l, fn() {
                @sf.t(if on() { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOn" } else { "web-pages.appearance.fonts.advanced.cjkAutoSpaceOff" })
              }, fn() { fp_v5_sample_hint }) |> ignore
            }) |> ignore
            @sf.switch_node(row, on, fn(v) {
              let m : Map[String, Json] = Map([]); m["cjkAutoSpace"] = ToJson::to_json(v); set_typo(m)
            }, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkAutoSpace") }) |> ignore
          }) |> ignore
        }, fn(c2) {
          let on = fn() { font_typo_bool(ctx.typo(), "codeLigatures", true) }
          c2.box(fn(row) {
            @sf.style_node(row, fn() { fp_v5_switch_row })
            row.box(fn(l) {
              @sf.style_node(l, fn() { fp_v5_inline_row })
              l.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
              @sf.words_node(l, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") }, fn() { fp_v5_row_label }) |> ignore
              face_in_node(l, fn() { "=> !==" }, fn() { ctx.code_face().unwrap_or(0) }, fp_v5_sample_hint, mono=true) |> ignore
            }) |> ignore
            @sf.switch_node(row, on, fn(v) {
              let m : Map[String, Json] = Map([]); m["codeLigatures"] = ToJson::to_json(v); set_typo(m)
            }, fn() { @sf.t("web-pages.appearance.fonts.advanced.codeLigatures") }) |> ignore
          }) |> ignore
        })
        fp_divider_node(card)
        // Row 4: CJK relative size | CJK relative weight (full-width 3-col segmented bar, top-aligned)
        two_col(card, fn(c1) {
          let p = fn() { ctx.place() }
          let scale_val = fn() {
            let key = font_cjk_scale_key(p())
            match cjk_scale_drag.get() { Some((k, v)) if k == key => v; _ => font_typo_num(ctx.typo(), key, 100.0) }
          }
          fp_slider_col_node(c1, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkScale") },
            fn() { "\{scale_val().round().to_int()}%" }, "字", "字", scale_val, 85.0, 120.0, 5.0,
            fn(v) { cjk_scale_drag.set(Some((font_cjk_scale_key(p()), v))) },
            fn(v) { cjk_scale_drag.set(None); let m : Map[String, Json] = Map([]); m[font_cjk_scale_key(p())] = ToJson::to_json(v.round().to_int()); set_typo(m) },
            extra_head=fn(h) {
              face_in_node(h, fn() { "Aa 字体" }, fn() { ctx.ui_face() }, fp_v5_sample_hint, cjk=fn() { ctx.cjk_override_for(p()) }) |> ignore
            })
        }, fn(c2) {
          let p = fn() { ctx.place() }
          let w_vals = [-100, 0, 100]
          c2.box(fn(col) {
            @sf.style_node(col, fn() { fp_v5_slider_col })
            col.box(fn(head) {
              @sf.style_node(head, fn() { fp_v5_slider_head })
              @sf.words_node(head, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkWeight") }, fn() { fp_v5_row_label }) |> ignore
              head.show(at_once=true, fn() {
                p() == "text" && ctx.chosen_of("textCjk") == "" &&
                (font_typo_bool(ctx.typo(), "textCjkScaleOwn", false) || font_typo_bool(ctx.typo(), "textCjkWeightOwn", false))
              }, fn(rf) {
                @sf.action_box_node(rf, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") }, fn(_) {
                  let m : Map[String, Json] = Map([]); m["textCjkScale"] = Json::null(); m["textCjkWeight"] = Json::null(); set_typo(m)
                }, fn(btn) { @sf.words_node(btn, fn() { @sf.t("web-pages.appearance.fonts.advanced.cjkResetFollow") }, fn() { fp_v5_undo_words }) |> ignore }) |> ignore
              })
            }) |> ignore
            @sf.segmented_node(col, fn() {
              [@sf.t("web-pages.appearance.fonts.advanced.weightLight"), @sf.t("web-pages.appearance.fonts.advanced.weightAuto"), @sf.t("web-pages.appearance.fonts.advanced.weightBold")]
            }, fn() {
              let cur = ctx.live_cjk_weight(p())
              if cur < 0 { 0 } else if cur > 0 { 2 } else { 1 }
            }, fn(i) { let m : Map[String, Json] = Map([]); m[font_cjk_weight_key(p())] = ToJson::to_json(w_vals[i]); set_typo(m) })
          }) |> ignore
        })
      }) |> ignore
    })
  }) |> ignore
}

///|
// kept across runs: static styles for V5 page
let fp_v5_reset : @ui.Style = @ui.css("px=S2 py=S1 radius=Md align=ACenter justify=JCenter")
let fp_v5_reset_hot : @ui.Style = fp_v5_reset.then(@ui.css("bg=Hover"))
let fp_v5_reset_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
let fp_v5_undo_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false)
let fp_v5_preview_card : @ui.Style = @ui.css("w=Full p=S2 gap=S1_5 radius=Xl2 bg=Card")
let fp_v5_top_row : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
let fp_v5_editing_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)
let fp_v5_bubble : @ui.Style = @ui.css("px=S2_5 py=S1 bg=Bg")
let fp_v5_mine_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L5, color=Fg)
let fp_v5_zone : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
let fp_v5_who_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")
let fp_v5_who_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg, wrap=false)
let fp_v5_time_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
let fp_v5_code_box : @ui.Style = @ui.css("w=Full px=S2_5 py=S1_5 bg=Bg")
let fp_v5_code_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, w=Full)
let fp_v5_section : @ui.Style = @ui.css("w=Full gap=S1_5")
let fp_v5_presets_sec : @ui.Style = @ui.css("w=Full gap=S1_5 pb=S3")
let fp_v5_adv_sec : @ui.Style = @ui.css("w=Full gap=S1_5 pt=S1")
let fp_v5_sec_heading : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, color=Muted, wrap=false)
let fp_v5_preset_row : @ui.Style = @ui.css("row w=Full gap=S2 align=AStretch")
let fp_v5_preset : @ui.Style = @ui.css("w=Full px=S3 py=S1_5 gap=S0_5 radius=Xl2 bg=Card")
let fp_v5_preset_hot : @ui.Style = @ui.css("w=Full px=S3 py=S1_5 gap=S0_5 radius=Xl2 bg=Hover")
let fp_v5_preset_on : @ui.Style = @ui.css("w=Full px=S3 py=S1_5 gap=S0_5 radius=Xl2 bg=AccentBg")
let fp_v5_preset_head : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S1")
let fp_v5_preset_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)
let fp_v5_preset_title_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=AccentText)
let fp_v5_preset_size : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
let fp_v5_preset_sub : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)
let fp_v5_role_bar : @ui.Style = @ui.css("row w=Full p=S2 gap=S1 radius=Xl2 bg=Surface")
let fp_v5_role : @ui.Style = @ui.css("w=Full px=S1_5 py=S1_5 gap=S0_5")
let fp_v5_role_hot : @ui.Style = @ui.css("w=Full px=S1_5 py=S1_5 gap=S0_5 bg=Hover")
let fp_v5_role_on : @ui.Style = @ui.css("w=Full px=S1_5 py=S1_5 gap=S0_5 bg=Card")
let fp_v5_role_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted)
let fp_v5_role_name_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Fg)
let fp_v5_role_pair : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, w=Full, max_lines=1)
let fp_v5_card : @ui.Style = @ui.css("w=Full radius=Xl2 bg=Card")
let fp_v5_picker_top : @ui.Style = @ui.css("row w=Full p=S2 justify=JBetween align=ACenter gap=S2")
let fp_v5_tab_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")
let fp_v5_tab : @ui.Style = @ui.css("px=S2_5 py=S1 align=ACenter justify=JCenter")
let fp_v5_tab_hot : @ui.Style = fp_v5_tab.then(@ui.css("bg=Hover"))
let fp_v5_tab_on : @ui.Style = fp_v5_tab.then(@ui.css("bg=AccentBg"))
let fp_v5_tab_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Muted, wrap=false)
let fp_v5_tab_words_on : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=AccentText, wrap=false)
let fp_v5_divider : @ui.Style = @ui.css("w=Full")
let fp_v5_adv_hdr : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
let fp_v5_adv_toggle : @ui.Style = @ui.css("row gap=S1_5 align=ACenter py=S0_5")
let fp_v5_adv_summary : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
let fp_v5_adv_two_col : @ui.Style = @ui.css("row w=Full px=S4 py=S3 gap=S6 align=AStretch")
let fp_v5_adv_row : @ui.Style = @ui.css("row w=Full px=S4 py=S2_5 justify=JBetween align=ACenter gap=S3")
let fp_v5_switch_row : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
let fp_v5_inline_row : @ui.Style = @ui.css("row gap=S2 align=ACenter")
let fp_v5_slider_col : @ui.Style = @ui.css("w=Full gap=S1_5")
let fp_v5_slider_head : @ui.Style = @ui.css("row w=Full justify=JBetween align=ACenter gap=S2")
let fp_v5_slider_track : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")
let fp_v5_row_label : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)
let fp_v5_row_val : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
let fp_v5_sample_hint : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle, wrap=false)
let fp_v5_glyph_sm : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Muted, wrap=false)
let fp_v5_glyph_lg : @ui.TextStyle = @ui.text_style(size=Title, weight=Medium, color=Muted, wrap=false)
