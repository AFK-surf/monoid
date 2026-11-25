// Chat classification UI (PR 3 Track B):
// - Wide chat bar inline project & tag attributes (`chat_bar_project_attrs_node`, View::fits optional block)
// - Unified chat info "项目与标签" section (`chat_info_projects_section_node`, wide panel & narrow sheet)
// - Linear-style single-responsibility project picker (`open_chat_project_picker`) & tag picker (`open_chat_tag_picker`)
//   using park-safe `ProjectListChain` / `TagListChain` bound to `@sf.panel_nodes`
// - Message inline silent proposal confirmation bar (`agent_proposal_node`) with 2-button footer (`创建` + `编辑`)
//   and top-level edit panel (rename & create, reassign to existing, dismiss without assigning)

///|
/// Translate a chat-projects catalog key via `@sf.t`.
fn proj_t(key : String, args? : Array[(String, String)] = []) -> String {
  @sf.t(key, args~)
}

///|
/// Whether a chat's classification can be edited: gated strictly on the host station's `cv.projects_writable`
/// (online + advertises `projects` + non-viewer), `!src.read_only`, and an existing thread.
pub fn chat_project_can_edit(src : Source, cv : ChatView) -> Bool {
  cv.projects_writable && !src.read_only && !cv.offline && cv.thread is Some(_)
}

///|
/// Human-readable label for a chat's `project` field (`None` or `Some("")` = 未归类, `Some(name)` = name).
pub fn chat_project_label(project : String?) -> String {
  match project {
    Some(name) if name != "" => name
    _ => proj_t("web-main.projects.project_none")
  }
}

///|
// kept across runs: a value (no field of it changes)
let proj_bar_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_bar_words_hot : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_tag_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_tag_words_hot : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_picker_row_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_picker_muted : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_picker_err : @ui.TextStyle = @ui.text_style(size=Caption, color=Danger, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_picker_section : @ui.TextStyle = @ui.text_style(size=Caption, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let proj_info_title : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let proj_proposal_title_style : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_proposal_note_style : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_proposal_ref_style : @ui.TextStyle = @ui.text_style(size=Caption, color=Subtle, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_proposal_done_style : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=true)

///|
// kept across runs: a value (no field of it changes)
let proj_rule_style : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let proj_picker_pad : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let proj_picker_list : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let proj_picker_row_style : @ui.Style = @ui.css("row w=Full px=S2_5 py=S1_5 gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let proj_info_sheet_pad : @ui.Style = @ui.css("w=Full px=S4 py=S3 gap=S2")

///|
// kept across runs: a value (no field of it changes)
let proj_info_panel_pad : @ui.Style = @ui.css("w=Full px=S3 py=S2_5 gap=S2")

///|
// kept across runs: a value (no field of it changes)
let proj_info_tags_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let proj_proposal_done_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=AStart py=S1")

///|
/// Hairline rule inside a picker or section.
fn proj_rule_node(parent : @view.View) -> Unit {
  parent.box(fn(r) {
    @sf.style_node(r, fn() { proj_rule_style })
    r.height(Is(Some(@sf.rule_w))).ground(By(fn() { @sf.rule_color() })) |> ignore
  })
  |> ignore
}

// ── Wide Chat Bar Inline Attributes (`View::fits` optional block) ────────

///|
/// Low-noise Linear-style optional project + tag attribute block for the wide chat bar (`sfdesk/chat_bar_wide_node.mbt`).
/// Strictly gated on `cv.projects == true`: zero nodes and zero bindings when `false`.
/// Uses `View::drops(Is(1))` inside the bar's `View::fits` row (after `people`), so on tight widths (e.g. 768px)
/// it hides BEFORE people or shrinking the chat title.
/// No shield icon on project; no colored dots on tags.
pub fn chat_bar_project_attrs_node(
  row : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  tips : @sf.TipLayer,
) -> Unit {
  let on = fn() {
    match view() {
      Some(cv) => cv.projects
      None => false
    }
  }
  row.show(on, along_row=true, fn(attrs) {
    // Dropped first (k=1, after people in the fits row) before squeezing the chat title.
    attrs
    .row(Is(true))
    .drops(Is(1))
    .shrink(Is(0.0))
    .gap(Is(proj_s1_5))
    .lines_up(Is(Some(Middle)))
    |> ignore
    let project_now = fn() {
      match view() {
        Some(cv) => cv.project
        None => None
      }
    }
    let tags_now = fn() {
      match view() {
        Some(cv) => cv.tags
        None => []
      }
    }
    let can_edit = fn() {
      match view() {
        Some(cv) => chat_project_can_edit(src, cv)
        None => false
      }
    }
    attrs.reacts(
      fn() { (view().bind(fn(cv) { cv.thread }), tags_now()) },
      fn(st) {
        match st.0 {
          Some(th) => @sfbase.classify_reconcile_tags(r.station, th, st.1)
          None => ()
        }
      },
    )
    // 1. Project trigger: quiet flat `[folder {project or 未归类}]` (no shield icon)
    @sf.action_box_node(
      attrs,
      fn() { chat_project_label(project_now()) },
      fn(at) {
        if @signals.untracked(can_edit) {
          open_chat_project_picker(src, r, view, from=Node(at))
        }
      },
      fn(b) {
        b
        .row(Is(true))
        .min_height(Is(Some(@sf.bar_key_side)))
        .padding(Is((proj_s2, 0.0, proj_s2, 0.0)))
        .gap(Is(proj_s1))
        .lines_up(Is(Some(Middle)))
        .radius(Is(@sf.small_corner))
        .max_width(By(fn() { Some(@sf.node_sp(b, 148.0)) }))
        .edge(By(fn() { @sf.control_edge(hot=@sf.lit_node(b)) }))
        |> ignore
        @sf.hover_ground_node(b)
        @sf.focus_ring_node(b)
        @sf.icon_node(b, "folder", 13.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.muted } }))
        |> ignore
        @sf.words_node(b, fn() { chat_project_label(project_now()) }, fn() {
          if @sf.lit_node(b) { proj_bar_words_hot } else { proj_bar_words }
        })
        .allow_ellipsis(Is(true))
        .min_width(Is(Some(0.0)))
        |> ignore
        @sf.tip_node(tips, b, fn() { chat_project_label(project_now()) }) |> ignore
      },
    )
    |> ignore
    // 2. Neutral `#tag` chips (zero colored dots!)
    attrs.each(tags_now, fn(tag) { tag }, fn(slot, tag_sig) {
      let tag_text = fn() { "#" + tag_sig.get() }
      @sf.action_box_node(
        slot,
        tag_text,
        fn(at) {
          if @signals.untracked(can_edit) {
            open_chat_tag_picker(src, r, view, from=Node(at))
          }
        },
        fn(b) {
          b
          .row(Is(true))
          .min_height(Is(Some(@sf.bar_key_side)))
          .padding(Is((proj_s2, 0.0, proj_s2, 0.0)))
          .lines_up(Is(Some(Middle)))
          .radius(Is(@sf.small_corner))
          .max_width(By(fn() { Some(@sf.node_sp(b, 104.0)) }))
          .ground(By(fn() { @sf.theme().p.neutral_bg }))
          |> ignore
          @sf.hover_ground_node(b)
          @sf.focus_ring_node(b)
          @sf.words_node(b, tag_text, fn() {
            if @sf.lit_node(b) { proj_tag_words_hot } else { proj_tag_words }
          })
          .allow_ellipsis(Is(true))
          .min_width(Is(Some(0.0)))
          |> ignore
          @sf.tip_node(tips, b, tag_text) |> ignore
        },
      )
      |> ignore
    })
    // 3. Lightweight `+` tag trigger when editable and fewer than 3 tags
    attrs.show(fn() { can_edit() && tags_now().length() < @sfbase.tags_max }, along_row=true, fn(add_wrap) {
      @sf.action_box_node(
        add_wrap,
        fn() { proj_t("web-main.projects.tags_add") },
        fn(at) { open_chat_tag_picker(src, r, view, from=Node(at)) },
        fn(b) {
          b
          .row(Is(true))
          .min_width(Is(Some(@sf.bar_key_side)))
          .min_height(Is(Some(@sf.bar_key_side)))
          .padding(Is((proj_s1, 0.0, proj_s1, 0.0)))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .radius(Is(@sf.small_corner))
          |> ignore
          @sf.hover_ground_node(b)
          @sf.focus_ring_node(b)
          @sf.icon_node(b, "plus", 12.0, By(fn() { if @sf.lit_node(b) { @sf.theme().p.text } else { @sf.theme().p.muted } }))
          |> ignore
          @sf.tip_node(tips, b, fn() { proj_t("web-main.projects.tags_add") }) |> ignore
        },
      )
      |> ignore
    })
  })
}

// ── Linear-Style Project Picker Panel ───────────────────────────────────

///|
/// Open the Linear-style single-responsibility project picker (`@sf.panel_nodes`, ~256px on wide, bottom sheet on small).
/// Releases its `ProjectListChain` leases automatically on close or park via `chain.bind`.
pub fn open_chat_project_picker(
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  from~ : @sf.Anchor,
) -> Unit {
  let scope = @sfbase.workspace_of(r.station)
  let query : @signals.Signal[String] = @signals.signal("")
  let err : @signals.Signal[String] = @signals.signal("")
  let field = @ui.Field::new()
  @sf.panel_nodes(
    proj_t("web-pages.projects.tab_projects"),
    w=256.0,
    from~,
    heads_itself=true,
    fn(body, close) {
      let cur_project = fn() {
        match view() {
          Some(cv) => cv.project
          None => None
        }
      }
      let can_edit = fn() {
        match view() {
          Some(cv) => chat_project_can_edit(src, cv)
          None => false
        }
      }
      let apply_project = fn(target : String) {
        guard @signals.untracked(can_edit) else {
          err.set(proj_t("web-main.projects.read_only_hint"))
          return
        }
        guard @signals.untracked(view) is Some({ thread: Some(th), .. }) else { return }
        if target != "" {
          match @sfbase.validate_project_name(target) {
            Err(msg) => {
              err.set(msg)
              return
            }
            Ok(valid) => {
              close()
              @sfbase.chat_classify(src, r.station, th, project=Some(Some(valid)), on_done=fn(res) {
                if !res.ok {
                  @sfbase.toast_later(res.error)
                }
              })
            }
          }
        } else {
          close()
          @sfbase.chat_classify(src, r.station, th, project=Some(Some("")), on_done=fn(res) {
            if !res.ok {
              @sfbase.toast_later(res.error)
            }
          })
        }
      }
      body.box(fn(col) {
        @sf.style_node(col, fn() { proj_picker_pad })
        // Search / create input
        @sf.input_node(
          col,
          field,
          placeholder_by=fn() { proj_t("web-main.projects.search_project") },
          small=true,
          edited=fn(s) {
            query.set(s)
            err.set("")
          },
          submitted=fn(s) {
            let trimmed = s.trim().to_owned()
            if trimmed != "" {
              apply_project(trimmed)
            }
          },
        )
        |> ignore
        col.show(fn() { err.get() != "" }, at_once=true, fn(e) {
          @sf.words_node(e, fn() { err.get() }, fn() { proj_picker_err }) |> ignore
        })
        // Unified Unclassified (no project) row
        proj_picker_item_row(
          col,
          fn() { proj_t("web-main.projects.unclassified") },
          fn() { cur_project() is None || cur_project() == Some("") },
          fn() { apply_project("") },
        )
        // Reactive paginated project list (bound to view for park/unmount lease cleanup)
        col.pick(at_once=true, fn() { query.get().trim().to_owned() }, fn(list_host, q) {
          let chain = @sfbase.ProjectListChain::new(scope, q~)
          chain.bind(list_host, src)
          let snap = fn() { chain.read(src) }
          list_host.box(fn(list_col) {
            @sf.style_node(list_col, fn() { proj_picker_list })
            let has_create = fn() {
              q != "" && !snap().items.iter().any(fn(it) { it.name == q })
            }
            let has_below = fn() { !snap().items.is_empty() || has_create() }
            list_col.show(has_below, at_once=true, fn(d) { proj_rule_node(d) })
            list_col.each(fn() { snap().items }, fn(it) { it.name }, fn(row_slot, it_sig) {
              let pname = fn() { it_sig.get().name }
              proj_picker_item_row(
                row_slot,
                pname,
                fn() { cur_project() == Some(pname()) },
                fn() { apply_project(@signals.untracked(pname)) },
              )
            })
            list_col.show(fn() { snap().has_more }, at_once=true, fn(more_slot) {
              proj_picker_action_row(more_slot, "", fn() { proj_t("web-pages.projects.load_more") }, fn() {
                chain.load_more(src)
              })
            })
            list_col.show(has_create, at_once=true, fn(create_slot) {
              proj_picker_action_row(
                create_slot,
                "plus",
                fn() { proj_t("web-main.projects.create_named", args=[("name", q)]) },
                fn() { apply_project(q) },
              )
            })
          })
          |> ignore
        })
        // Quiet lock hint at bottom (no unlock button)
        proj_rule_node(col)
        col.box(fn(hw) {
          hw.padding(Is((6.0, 2.0, 6.0, 4.0))) |> ignore
          @sf.words_node(hw, fn() { proj_t("web-main.projects.locked_hint") }, fn() { proj_picker_muted })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    },
  )
}

///|
/// Single-line selectable row in project/tag combobox: right-side checkmark ONLY (no background + checkmark double emphasis).
fn proj_picker_item_row(
  parent : @view.View,
  label : () -> String,
  selected : () -> Bool,
  on_pick : () -> Unit,
) -> Unit {
  @sf.panel_content_row_node(parent, label, fn(_) { on_pick() }, highlighted=@sf.lit_node, fn(b) {
    @sf.style_node(b, fn() { proj_picker_row_style })
    b.radius(Is(@sf.small_panel_inner(@sf.r_menu))).min_height(Is(Some(36.0))) |> ignore
    @sf.focus_ring_node(b)
    b.box(fn(w) {
      w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(w, label, fn() { proj_picker_row_words })
      .allow_ellipsis(Is(true))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
    |> ignore
    b.show(selected, at_once=true, fn(chk) {
      @sf.icon_node(chk, "check", 14.0, By(fn() { @sf.theme().p.text })) |> ignore
    })
  })
}

///|
/// Action row inside a picker (e.g. `+ 新建项目「…」`, `加载更多`, `不归入项目`).
fn proj_picker_action_row(
  parent : @view.View,
  icon : String,
  label : () -> String,
  on_press : () -> Unit,
) -> Unit {
  @sf.panel_content_row_node(parent, label, fn(_) { on_press() }, highlighted=@sf.lit_node, fn(b) {
    @sf.style_node(b, fn() { proj_picker_row_style })
    b.radius(Is(@sf.small_panel_inner(@sf.r_menu))).min_height(Is(Some(36.0))) |> ignore
    @sf.focus_ring_node(b)
    if icon != "" {
      @sf.icon_node(b, icon, 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
    }
    b.box(fn(w) {
      w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      @sf.words_node(w, label, fn() { proj_picker_row_words })
      .allow_ellipsis(Is(true))
      .min_width(Is(Some(0.0)))
      |> ignore
    })
    |> ignore
  })
}

// ── Independent Lightweight Tag Picker Panel ────────────────────────────

///|
/// Open the lightweight tag combobox (`@sf.panel_nodes`, ~256px on wide, bottom sheet on small).
/// Releases its `TagListChain` leases automatically on close or park via `chain.bind`.
pub fn open_chat_tag_picker(
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  from~ : @sf.Anchor,
) -> Unit {
  let scope = @sfbase.workspace_of(r.station)
  let query : @signals.Signal[String] = @signals.signal("")
  let err : @signals.Signal[String] = @signals.signal("")
  let field = @ui.Field::new()
  @sf.panel_nodes(
    proj_t("web-main.projects.tags_label"),
    w=256.0,
    from~,
    heads_itself=true,
    fn(body, _close) {
      let cur_tags = fn() {
        match view() {
          Some(cv) => cv.tags
          None => []
        }
      }
      let can_edit = fn() {
        match view() {
          Some(cv) => chat_project_can_edit(src, cv)
          None => false
        }
      }
      let toggle_tag = fn(raw : String) {
        guard @signals.untracked(can_edit) else {
          err.set(proj_t("web-main.projects.read_only_hint"))
          return
        }
        guard @signals.untracked(view) is Some({ thread: Some(th), .. }) else { return }
        match @sfbase.validate_tag_name(raw) {
          Err(msg) => {
            err.set(msg)
            return
          }
          Ok(tag) => {
            err.set("")
            @sfbase.chat_toggle_tag(src, r.station, th, @signals.untracked(cur_tags), tag, on_done=fn(res) {
              if !res.ok {
                err.set(res.error)
                @sfbase.toast_later(res.error)
              }
            })
          }
        }
      }
      body.box(fn(col) {
        @sf.style_node(col, fn() { proj_picker_pad })
        @sf.input_node(
          col,
          field,
          placeholder_by=fn() { proj_t("web-main.projects.tags_placeholder") },
          small=true,
          edited=fn(s) {
            query.set(s)
            err.set("")
          },
          submitted=fn(s) {
            let trimmed = s.trim().to_owned()
            if trimmed != "" {
              toggle_tag(trimmed)
              field.set("")
              query.set("")
            }
          },
        )
        |> ignore
        col.show(fn() { err.get() != "" }, at_once=true, fn(e) {
          @sf.words_node(e, fn() { err.get() }, fn() { proj_picker_err }) |> ignore
        })
        col.show(fn() { err.get() == "" && cur_tags().length() >= @sfbase.tags_max }, at_once=true, fn(e) {
          @sf.words_node(e, fn() { proj_t("web-main.projects.err_tags_max") }, fn() { proj_picker_muted }) |> ignore
        })
        col.pick(at_once=true, fn() { query.get().trim().to_owned() }, fn(list_host, q) {
          let chain = @sfbase.TagListChain::new(scope, q~)
          chain.bind(list_host, src)
          let snap = fn() { chain.read(src) }
          let merged_tags = fn() -> Array[String] {
            let out : Array[String] = []
            let seen : Map[String, Bool] = Map([])
            for t in cur_tags() {
              if q == "" || t.to_lower().contains(q.to_lower()) {
                seen[t] = true
                out.push(t)
              }
            }
            for row in snap().items {
              if !seen.contains(row.tag) {
                seen[row.tag] = true
                out.push(row.tag)
              }
            }
            out
          }
          list_host.box(fn(list_col) {
            @sf.style_node(list_col, fn() { proj_picker_list })
            list_col.each(merged_tags, fn(t) { t }, fn(row_slot, tag_sig) {
              let tname = fn() { tag_sig.get() }
              proj_picker_item_row(
                row_slot,
                fn() { "#" + tname() },
                fn() { cur_tags().contains(tname()) },
                fn() { toggle_tag(@signals.untracked(tname)) },
              )
            })
            list_col.show(fn() { snap().has_more }, at_once=true, fn(more_slot) {
              proj_picker_action_row(more_slot, "", fn() { proj_t("web-pages.projects.load_more") }, fn() {
                chain.load_more(src)
              })
            })
            let can_add_new = fn() {
              q != "" && !merged_tags().contains(q) && cur_tags().length() < @sfbase.tags_max
            }
            list_col.show(can_add_new, at_once=true, fn(add_slot) {
              proj_picker_action_row(
                add_slot,
                "plus",
                fn() { proj_t("web-main.projects.tags_add") + " #" + q },
                fn() {
                  toggle_tag(q)
                  field.set("")
                  query.set("")
                },
              )
            })
          })
          |> ignore
        })
      })
      |> ignore
    },
  )
}

// ── Unified Chat Info Classification Section (Wide Panel & Narrow Sheet) ──

///|
/// Unified "项目与标签" section for chat info on both wide panels (`sfdesk/chat_info_node.mbt`)
/// and narrow bottom sheets (`sfapp/sheets.mbt`).
/// Strictly gated on `cv.projects == true` (renders zero nodes when `false`).
pub fn chat_info_projects_section_node(
  parent : @view.View,
  src : Source,
  r : ChatRef,
  view : () -> ChatView?,
  in_sheet? : Bool = false,
) -> Unit {
  let on = fn() {
    match view() {
      Some(cv) => cv.projects
      None => false
    }
  }
  parent.show(on, at_once=true, fn(sec) {
    let project_now = fn() {
      match view() {
        Some(cv) => cv.project
        None => None
      }
    }
    let locked_now = fn() {
      match view() {
        Some(cv) => cv.project_locked
        None => false
      }
    }
    let tags_now = fn() {
      match view() {
        Some(cv) => cv.tags
        None => []
      }
    }
    let can_edit = fn() {
      match view() {
        Some(cv) => chat_project_can_edit(src, cv)
        None => false
      }
    }
    sec.reacts(
      fn() { (view().bind(fn(cv) { cv.thread }), tags_now()) },
      fn(st) {
        match st.0 {
          Some(th) => @sfbase.classify_reconcile_tags(r.station, th, st.1)
          None => ()
        }
      },
    )
    let remove_tag = fn(target : String) {
      guard @signals.untracked(can_edit) else { return }
      guard @signals.untracked(view) is Some({ thread: Some(th), .. }) else { return }
      @sfbase.chat_remove_tag(src, r.station, th, @signals.untracked(tags_now), target, on_done=fn(res) {
        if !res.ok {
          @sfbase.toast_later(res.error)
        }
      })
    }
    sec.box(fn(box) {
      @sf.style_node(box, fn() {
        if in_sheet { proj_info_sheet_pad } else { proj_info_panel_pad }
      })
      if !in_sheet {
        proj_rule_node(box)
      }
      // Section header
      @sf.words_node(box, fn() { proj_t("web-pages.projects.title") }, fn() { proj_picker_section })
      |> ignore
      // Project selector row (clickable when editable; no shield, no unlock button)
      @sf.panel_content_row_node(
        box,
        fn() { chat_project_label(project_now()) },
        fn(at) {
          if @signals.untracked(can_edit) {
            open_chat_project_picker(src, r, view, from=Node(at))
          }
        },
        highlighted=@sf.lit_node,
        fn(row) {
          row
          .row(Is(true))
          .min_height(Is(Some(if in_sheet { 44.0 } else { 32.0 })))
          .padding(Is((8.0, 4.0, 8.0, 4.0)))
          .gap(Is(8.0))
          .lines_up(Is(Some(Middle)))
          .radius(Is(8.0))
          |> ignore
          @sf.focus_ring_node(row)
          @sf.icon_node(row, "folder", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
          row.box(fn(w) {
            w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(w, fn() { chat_project_label(project_now()) }, fn() { proj_info_title })
            .allow_ellipsis(Is(true))
            .min_width(Is(Some(0.0)))
            |> ignore
          })
          |> ignore
          row.show(can_edit, at_once=true, fn(ch) {
            @sf.icon_node(ch, "chevron-right", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          })
        },
      )
      // Tags wrapping row: neutral `#tag` removable chips + `+ 添加标签` button (max 3)
      box.box(fn(trow) {
        @sf.style_node(trow, fn() { proj_info_tags_row })
        trow.wraps(Is(Some(6.0))) |> ignore
        trow.each(tags_now, fn(tag) { tag }, fn(slot, tag_sig) {
          let tname = fn() { tag_sig.get() }
          let chip_label = fn() { "#" + tname() }
          slot.box(fn(chip) {
            chip
            .row(Is(true))
            .min_height(Is(Some(26.0)))
            .padding(Is((8.0, 2.0, 8.0, 2.0)))
            .gap(Is(4.0))
            .lines_up(Is(Some(Middle)))
            .radius(Is(6.0))
            .ground(By(fn() { @sf.theme().p.neutral_bg }))
            |> ignore
            @sf.words_node(chip, chip_label, fn() { proj_tag_words })
            .allow_ellipsis(Is(true))
            .max_width(Is(Some(140.0)))
            .min_width(Is(Some(0.0)))
            |> ignore
            chip.show(can_edit, at_once=true, fn(rm) {
              @sf.action_box_node(
                rm,
                fn() { @sf.t("common.remove") + " " + chip_label() },
                fn(_) { remove_tag(@signals.untracked(tname)) },
                fn(xb) {
                  xb
                  .row(Is(true))
                  .min_width(Is(Some(18.0)))
                  .min_height(Is(Some(18.0)))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  .radius(Is(4.0))
                  |> ignore
                  @sf.hover_ground_node(xb)
                  @sf.icon_node(xb, "close", 11.0, By(fn() { @sf.theme().p.muted })) |> ignore
                },
              )
              |> ignore
            })
          })
          |> ignore
        })
        trow.show(fn() { can_edit() && tags_now().length() < @sfbase.tags_max }, at_once=true, fn(add_slot) {
          @sf.action_box_node(
            add_slot,
            fn() { proj_t("web-main.projects.tags_add") },
            fn(at) { open_chat_tag_picker(src, r, view, from=Node(at)) },
            fn(b) {
              b
              .row(Is(true))
              .min_height(Is(Some(26.0)))
              .padding(Is((7.0, 2.0, 8.0, 2.0)))
              .gap(Is(4.0))
              .lines_up(Is(Some(Middle)))
              .radius(Is(6.0))
              .edge(By(fn() { @sf.control_edge(hot=@sf.lit_node(b)) }))
              |> ignore
              @sf.hover_ground_node(b)
              @sf.focus_ring_node(b)
              @sf.icon_node(b, "plus", 12.0, By(fn() { @sf.theme().p.muted })) |> ignore
              @sf.words_node(b, fn() { proj_t("web-main.projects.tags_add") }, fn() { proj_tag_words }) |> ignore
            },
          )
          |> ignore
        })
      })
      |> ignore
      // Quiet lock explanation (no unlock button — backend has no unlock API)
      box.show(locked_now, at_once=true, fn(hint) {
        @sf.words_node(hint, fn() { proj_t("web-main.projects.locked_hint") }, fn() { proj_picker_muted }) |> ignore
      })
      // Quiet read-only hint when host station is offline or read-only
      box.show(fn() { !can_edit() }, at_once=true, fn(ro) {
        @sf.words_node(ro, fn() { proj_t("web-main.projects.read_only_hint") }, fn() { proj_picker_muted }) |> ignore
      })
    })
    |> ignore
  })
}

// ── Message Inline Silent Proposal Confirmation Bar ─────────────────────

///|
/// Effective `(status, resolved_project)` for a message's proposal:
/// prefers non-pending server state; while server still reports `"pending"`, overlays any local optimistic convergence
/// from `proposal_optimistic_state` (including 200 `{ alreadyResolved: true }` with no follow-up chat push).
fn proposal_effective_state(
  station : String,
  thread : Double,
  seq : Double,
  p : @sfbase.MessageProposal,
) -> (String, String?) {
  if p.status != "pending" {
    @sfbase.proposal_clear_optimistic(station, thread, seq)
    return (p.status, p.resolved_project)
  }
  match @sfbase.proposal_optimistic_state(station, thread, seq) {
    Some(opt) => opt
    None => (p.status, p.resolved_project)
  }
}

///|
/// Converged single-line copy for a resolved proposal.
fn proposal_converged_words(status : String, resolved : String?, proposed_name : String) -> String {
  match status {
    "accepted" => {
      let name = match resolved {
        Some(n) if n != "" => n
        _ => proposed_name
      }
      proj_t("web-main.projects.proposal_approved", args=[("name", name)])
    }
    "reassigned" => {
      let name = resolved.unwrap_or("")
      proj_t("web-main.projects.proposal_reassigned", args=[("name", name)])
    }
    "dismissed" => proj_t("web-main.projects.proposal_dismissed")
    _ => proj_t("web-main.projects.proposal_dismissed")
  }
}

///|
/// Open the 「编辑」 panel for a pending proposal (`@sf.panel_nodes`):
/// all 3 actions directly visible at top level (zero hidden sub-steps):
/// 1. Pre-filled project name input + `创建项目` (`action="accept", name=...`)
/// 2. `改归已有项目` via park-safe `ProjectListChain` (`action="reassign", target=...`)
/// 3. Top-level `不归入项目` (`action="dismiss", mark_cross=true`)
fn open_proposal_edit_panel(
  src : Source,
  station : String,
  thread : Double,
  seq : Double,
  proposed : @sfbase.MessageProposal,
  can_edit : () -> Bool,
  from~ : @sf.Anchor,
) -> Unit {
  let scope = @sfbase.workspace_of(station)
  let field = @ui.Field::new(text=proposed.name)
  let name_sig : @signals.Signal[String] = @signals.signal(proposed.name)
  let err : @signals.Signal[String] = @signals.signal("")
  @sf.panel_nodes(
    proj_t("web-main.projects.proposal_edit"),
    w=288.0,
    from~,
    heads_itself=true,
    fn(body, close) {
      let busy = fn() { @sfbase.proposal_is_pending(station, thread, seq) }
      let submit_accept = fn() {
        if !@signals.untracked(can_edit) {
          err.set(proj_t("web-main.projects.read_only_hint"))
          return
        }
        let raw = @signals.untracked(fn() { name_sig.get() })
        match @sfbase.validate_project_name(raw) {
          Err(msg) => err.set(msg)
          Ok(valid) => {
            err.set("")
            close()
            @sfbase.proposal_resolve(
              src,
              station,
              thread,
              seq,
              "accept",
              name=Some(valid),
              on_done=fn(res) {
                if !res.ok {
                  @sfbase.toast_later(res.error)
                }
              },
            )
          }
        }
      }
      let submit_reassign = fn(target : String) {
        if !@signals.untracked(can_edit) {
          err.set(proj_t("web-main.projects.read_only_hint"))
          return
        }
        err.set("")
        close()
        @sfbase.proposal_resolve(
          src,
          station,
          thread,
          seq,
          "reassign",
          target=Some(target),
          on_done=fn(res) {
            if !res.ok {
              @sfbase.toast_later(res.error)
            }
          },
        )
      }
      let submit_cross = fn() {
        if !@signals.untracked(can_edit) {
          err.set(proj_t("web-main.projects.read_only_hint"))
          return
        }
        err.set("")
        close()
        @sfbase.proposal_resolve(
          src,
          station,
          thread,
          seq,
          "dismiss",
          mark_cross=true,
          on_done=fn(res) {
            if !res.ok {
              @sfbase.toast_later(res.error)
            }
          },
        )
      }
      body.box(fn(col) {
        @sf.style_node(col, fn() { proj_picker_pad })
        // 1. Pre-filled project name + 创建并归入
        @sf.input_node(
          col,
          field,
          placeholder_by=fn() { proj_t("web-main.projects.proposal_name_placeholder") },
          small=true,
          edited=fn(s) {
            name_sig.set(s)
            err.set("")
          },
          submitted=fn(_) { submit_accept() },
        )
        |> ignore
        col.show(fn() { err.get() != "" }, at_once=true, fn(e) {
          @sf.words_node(e, fn() { err.get() }, fn() { proj_picker_err }) |> ignore
        })
        @sf.button_node(
          col,
          fn() { proj_t("web-main.projects.proposal_rename_create") },
          submit_accept,
          tone=Primary,
          busy~,
          disabled=fn() { !can_edit() },
          across=true,
        )
        |> ignore
        // 2. 改归已有项目 (park-safe ProjectListChain)
        proj_rule_node(col)
        @sf.words_node(col, fn() { proj_t("web-main.projects.proposal_reassign") }, fn() { proj_picker_section })
        |> ignore
        col.box(fn(list_host) {
          let chain = @sfbase.ProjectListChain::new(scope)
          chain.bind(list_host, src)
          let snap = fn() { chain.read(src) }
          @sf.style_node(list_host, fn() { proj_picker_list })
          list_host.each(fn() { snap().items }, fn(it) { it.name }, fn(row_slot, it_sig) {
            let pname = fn() { it_sig.get().name }
            proj_picker_action_row(row_slot, "folder", pname, fn() {
              submit_reassign(@signals.untracked(pname))
            })
          })
          list_host.show(fn() { snap().has_more }, at_once=true, fn(more_slot) {
            proj_picker_action_row(more_slot, "", fn() { proj_t("web-pages.projects.load_more") }, fn() {
              chain.load_more(src)
            })
          })
        })
        |> ignore
        // 3. Top-level directly visible 不归入项目
        proj_rule_node(col)
        proj_picker_action_row(
          col,
          "other",
          fn() { proj_t("web-main.projects.proposal_mark_cross") },
          submit_cross,
        )
      })
      |> ignore
    },
  )
}

///|
/// Message inline silent proposal confirmation bar (`message_agent_node.mbt`).
/// Strictly gated on `only_while() && (here.view)().projects && m().proposal is Some(_)`:
/// zero nodes and zero bindings when `projects == false` or `proposal == None`.
/// Reuses `ask_in_place_node` (`under_post_room` width constraint + `msg_part_leave_ms` smooth cross-fade + `held` snapshot)
/// so the card never overflows narrow 320px viewports and converges smoothly in place.
pub fn agent_proposal_node(
  b : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  only_while? : () -> Bool = fn() { true },
) -> Unit {
  let shown = fn() {
    only_while() && (here.view)().projects && m().proposal is Some(_)
  }
  b.show(shown, at_once=true, fn(wrap) {
    @sf.style_node(wrap, fn() { under_post_room })
    wrap.padding(Is((0.0, 8.0, 0.0, 0.0))) |> ignore
    let thread_now = fn() { (here.view)().thread.unwrap_or(0.0) }
    let eff = fn() -> (String, String?) {
      let msg = m()
      match msg.proposal {
        Some(p) => proposal_effective_state(here.station, thread_now(), msg.seq, p)
        None => ("", None)
      }
    }
    let decided = fn() { eff().0 != "pending" }
    ask_in_place_node(
      wrap,
      decided,
      m,
      ask_room_under,
      fn(room, open_m) {
        @sf.ask_card_node(
          room,
          fn(card) {
            // Head row: icon aligned to first line of title (natural width, matching signin_ask_node / rig_ask_node)
            card.box(fn(head) {
              head.row(Is(true)).gap(Is(proj_s2)).lines_up(Is(Some(Start))) |> ignore
              head.box(fn(ic) {
                ic
                .height(By(fn() { Some(@sf.node_sp(ic, @sf.theme().t.ui_line)) }))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .shrink(Is(0.0))
                |> ignore
                @sf.icon_node(ic, "folder-plus", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
              })
              |> ignore
              head.box(fn(tw) {
                tw.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                @sf.words_node(
                  tw,
                  fn() {
                    let pname = open_m().proposal.map_or("", fn(p) { p.name })
                    proj_t("web-main.projects.proposal_title", args=[("name", pname)])
                  },
                  fn() { proj_proposal_title_style },
                )
                |> ignore
              })
              |> ignore
            })
            |> ignore
            // Optional wrapping note (never single-line truncated)
            card.show(
              fn() { open_m().proposal.map_or(false, fn(p) { p.note != "" }) },
              at_once=true,
              fn(nw) {
                @sf.words_node(
                  nw,
                  fn() { open_m().proposal.map_or("", fn(p) { p.note }) },
                  fn() { proj_proposal_note_style },
                )
                |> ignore
              },
            )
            // Optional wrapping refs (never single-line truncated, never middle-dot joined)
            card.show(
              fn() { open_m().proposal.map_or(false, fn(p) { !p.refs.is_empty() }) },
              at_once=true,
              fn(rw) {
                @sf.words_node(
                  rw,
                  fn() {
                    open_m().proposal.map_or("", fn(p) {
                      p.refs.map(fn(u) { u.replace_all(old="/", new="/\u{200B}") }).join("\n")
                    })
                  },
                  fn() { proj_proposal_ref_style },
                )
                |> ignore
              },
            )
            // Footer: strictly 2 buttons (`创建` Primary + `编辑` Default), staying on one line even at 320x568 @ 1.3x
            @sf.ask_buttons_node(card, fn(foot) {
              let is_busy = fn() {
                @sfbase.proposal_is_pending(here.station, thread_now(), open_m().seq)
              }
              let can_edit = fn() {
                chat_project_can_edit(src, (here.view)())
              }
              @sf.button_node(
                foot,
                fn() { proj_t("web-main.projects.proposal_create") },
                fn() {
                  guard @signals.untracked(can_edit) else { return }
                  let msg = @signals.untracked(open_m)
                  guard @signals.untracked(here.view).thread is Some(th) else { return }
                  let displayed_name = msg.proposal.map(fn(p) { p.name })
                  @sfbase.proposal_resolve(
                    src,
                    here.station,
                    th,
                    msg.seq,
                    "accept",
                    name=displayed_name,
                    on_done=fn(res) {
                      if !res.ok {
                        @sfbase.toast_later(res.error)
                      }
                    },
                  )
                },
                tone=Primary,
                busy=is_busy,
                disabled=fn() { !can_edit() },
                card_words=true,
              )
              |> ignore
              @sf.button_opens_node(
                foot,
                fn() { proj_t("web-main.projects.proposal_edit") },
                fn(btn) {
                  guard @signals.untracked(can_edit) && !@signals.untracked(is_busy) else { return }
                  let msg = @signals.untracked(open_m)
                  guard @signals.untracked(here.view).thread is Some(th) else { return }
                  match msg.proposal {
                    Some(p) => open_proposal_edit_panel(src, here.station, th, msg.seq, p, can_edit, from=Node(btn))
                    None => ()
                  }
                },
                tone=Plain,
              )
              |> ignore
            })
            |> ignore
          },
        )
        |> ignore
      },
      fn(slot) {
        // Converged quiet single-line state: muted icon + muted ink (no bright green checkmark), first-line aligned
        slot.box(fn(done_row) {
          @sf.style_node(done_row, fn() { proj_proposal_done_row })
          done_row.box(fn(ic) {
            ic
            .height(By(fn() { Some(@sf.node_sp(ic, @sf.theme().t.meta_line)) }))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .shrink(Is(0.0))
            |> ignore
            let icon_name = fn() {
              if eff().0 == "dismissed" && eff().1 is None { "minus" } else { "check" }
            }
            ic.pick(at_once=true, icon_name, fn(is_slot, name) {
              @sf.icon_node(is_slot, name, 13.0, By(fn() { @sf.theme().p.muted })) |> ignore
            })
          })
          |> ignore
          done_row.box(fn(tw) {
            tw.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
            @sf.words_node(
              tw,
              fn() {
                let (st, rp) = eff()
                let pname = m().proposal.map_or("", fn(p) { p.name })
                proposal_converged_words(st, rp, pname)
              },
              fn() { proj_proposal_done_style },
            )
            |> ignore
          })
          |> ignore
        })
        |> ignore
      },
    )
  })
}
