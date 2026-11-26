// 设置 › 项目与标签 (`Route::Projects`) 与项目详情 (`Route::Project(String)`):
// 严格遵循原生设置页排版规范（参考 `memory.mbt` / `automatic_decisions.mbt` / `profiles_list.mbt`）：
// - 列表页：park-safe `ProjectListChain`（`read()` 纯读无副作用、`bind(v, src)` 驱动租约与重置），顶部独立节点汇总（零 `·`），
//   使用 `@sf.card_piece_node(..., wide_group=true)` 与连续 `card_piece_of(i, total)`（含「加载更多」作为末块 `CardFoot`），错误态带「重试」按钮。
// - 详情页：park-safe `ProjectDetailChain`（缓存态 `complete` 只读展示，仅全部页面收到 live 答案 `editable == true` 才解锁编辑与保存），
//   全页使用画布级 `@sf.section_node`（标题在白卡外）：
//   1. 「项目说明」：`@sf.textarea_node(..., solid=true)` 直接落在页面底色上（绝不套白卡）；
//   2. 「关联路径与链接」：添加行（`solid=true` 输入框 + 按钮）直接落在画布上，已有路径放入原生 `@sf.group_node`，紧跟画布级「保存」按钮；
//   3. 「管理操作」：`@sf.section_node` + `@sf.group_node` 内放 `@sf.link_row_node`（「重命名」、「合并项目」，自带原生同心圆 hover）。
//   冲突条拦截普通「保存」，且普通保存与「覆盖保存」均仅提交相对编辑基线 `(base_note, base_refs)` 真正改动的字段。

///|
// kept across runs: immutable styles
let proj_summary_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted)

///|
// kept across runs: immutable styles
let proj_row_name : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, max_lines=1)

///|
// kept across runs: immutable styles
let proj_row_count : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, tabular=true)

///|
// kept across runs: immutable styles
let proj_note_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, leading=L6)

///|
// kept across runs: immutable styles
let proj_warn_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, leading=L6)

///|
// kept across runs: immutable styles
let proj_ref_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg)

///|
let proj_pad_x : Double = @ui.Space::S4.px()

///|
let proj_s1 : Double = @ui.Space::S1.px()

///|
let proj_s1_5 : Double = @ui.Space::S1_5.px()

///|
let proj_s2 : Double = @ui.Space::S2.px()

///|
let proj_s2_5 : Double = @ui.Space::S2_5.px()

///|
let proj_s3 : Double = @ui.Space::S3.px()

///|
let proj_s4 : Double = @ui.Space::S4.px()

///|
/// 设置 › 项目与标签 列表页 (`Route::Projects`).
pub fn projects_page_node(
  v : @view.View,
  src : Source,
  core : Core,
  here : @settings.Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let chain = @sfbase.ProjectListChain::new(here.workspace)
  chain.bind(v, src)
  let snap = fn() { chain.read(src) }
  let row_keys = fn() {
    let s = snap()
    let out : Array[String] = ["summary"]
    if s.items.is_empty() {
      out.push("empty")
    } else {
      for r in s.items {
        out.push("p/" + r.name)
      }
      if s.has_more {
        out.push("more")
      }
    }
    out
  }
  let card_total = fn() -> Int {
    let s = snap()
    s.items.length() + (if s.has_more { 1 } else { 0 })
  }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.projects.title") },
    on_back~,
    frame~,
    said?,
    width?,
    row_keys,
    fn(b, key) {
      if key == "summary" {
        b.box(fn(box) {
          box
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(proj_s4))
          .padding(Is((proj_pad_x, proj_s1, proj_pad_x, proj_s2_5)))
          |> ignore
          @sf.words_node(
            box,
            fn() { @sf.t("web-pages.projects.tab_projects") + " " + snap().total.to_string() },
            fn() { proj_summary_words },
          )
          |> ignore
          let unassigned = fn() { snap().unclassified_count + snap().cross_count }
          box.show(fn() { unassigned() > 0 }, along_row=true, fn(u) {
            @sf.words_node(
              u,
              fn() { @sf.t("web-main.projects.unclassified") + " " + unassigned().to_string() },
              fn() { proj_summary_words },
            )
            |> ignore
          })
        })
        |> ignore
      } else if key == "empty" {
        b.box(fn(box) {
          box.padding(Is((proj_pad_x, proj_s3, proj_pad_x, proj_s3))).gap(Is(proj_s2_5)) |> ignore
          @sf.words_node(
            box,
            fn() {
              let s = snap()
              match s.error {
                Some(e) if e != "" => e
                _ =>
                  if s.loading {
                    @sf.t("web-pages.projects.loading_detail")
                  } else {
                    @sf.t("web-pages.projects.empty_projects")
                  }
              }
            },
            fn() {
              match snap().error {
                Some(e) if e != "" => proj_warn_words
                _ => proj_note_words
              }
            },
          )
          |> ignore
          box.show(
            fn() {
              match snap().error {
                Some(e) if e != "" => true
                _ => false
              }
            },
            fn(rbox) {
              rbox.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
              @sf.button_node(
                rbox,
                fn() { @sf.t("common.retry") },
                fn() { chain.retry(src) },
                tone=@sf.Tone::Plain,
              )
              |> ignore
            },
          )
        })
        |> ignore
      } else if key == "more" {
        let piece = fn() -> @sf.CardPiece {
          let total = card_total()
          @sf.card_piece_of(total - 1, total)
        }
        @sf.card_piece_node(b, piece, wide_group=true, fn(c) {
          @sf.action_box_node(c, fn() { @sf.t("web-pages.projects.load_more") }, fn(_) { chain.load_more(src) }, fn(r) {
            r
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .padding(Is((proj_pad_x, proj_s2_5, proj_pad_x, proj_s2_5)))
            .min_height(Is(Some(@sf.theme().items.least)))
            |> ignore
            @sf.words_node(r, fn() { @sf.t("web-pages.projects.load_more") }, fn() { proj_summary_words }) |> ignore
          })
          |> ignore
        })
      } else if key.has_prefix("p/") {
        let pname = key.exact_view(start=2).to_owned()
        let piece = fn() -> @sf.CardPiece {
          let s = snap()
          let idx = s.items.search_by(fn(r) { r.name == pname }).unwrap_or(0)
          @sf.card_piece_of(idx, card_total())
        }
        @sf.card_piece_node(b, piece, wide_group=true, fn(c) {
          @sf.action_box_node(c, fn() { pname }, fn(_) { (core.push)(Project(pname)) }, fn(row) {
            row
            .row(Is(true))
            .lines_up(Is(Some(Middle)))
            .gap(Is(proj_s2))
            .padding(Is((proj_pad_x, proj_s2_5, proj_pad_x, proj_s2_5)))
            .min_height(Is(Some(@sf.theme().items.least)))
            |> ignore
            @sf.icon_node(row, "folder", 15.0, By(fn() { @sf.theme().p.muted })) |> ignore
            @sf.words_node(row, fn() { pname }, fn() { proj_row_name })
            .grow(Is(1.0))
            .basis(Is(Some(0.0)))
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .cuts(Is(true))
            .allow_ellipsis(Is(true))
            |> ignore
            // Status marks matching chat_mark_node & collapsed sidebar headers: busy = yellow spokes, alert = red dot, wait/unread = blue dot.
            row.show(
              fn() {
                snap().items.iter().find_first(fn(r) { r.name == pname }).map_or(false, fn(r) { r.running_count > 0 })
              },
              along_row=true,
              fn(dot) {
                dot.shrink(Is(0.0)) |> ignore
                @sf.spokes_node(dot, 10.0, @sf.mark_yellow) |> ignore
              },
            )
            row.show(
              fn() {
                snap().items.iter().find_first(fn(r) { r.name == pname }).map_or(false, fn(r) { r.alert_count > 0 })
              },
              along_row=true,
              fn(dot) {
                dot.width(Is(Some(6.0))).height(Is(Some(6.0))).radius(Is(3.0)).ground(By(fn() { @ui.tree_theme().color(@sf.mark_red) })).shrink(Is(0.0)) |> ignore
              },
            )
            row.show(
              fn() {
                snap().items.iter().find_first(fn(r) { r.name == pname }).map_or(false, fn(r) { r.asking_count > 0 || r.unread_count > 0 })
              },
              along_row=true,
              fn(dot) {
                dot.width(Is(Some(6.0))).height(Is(Some(6.0))).radius(Is(3.0)).ground(By(fn() { @ui.tree_theme().color(@sf.mark_blue) })).shrink(Is(0.0)) |> ignore
              },
            )
            @sf.words_node(
              row,
              fn() {
                snap().items.iter().find_first(fn(r) { r.name == pname }).map_or("0", fn(r) { r.chat_count.to_string() })
              },
              fn() { proj_row_count },
            )
            .shrink(Is(0.0))
            |> ignore
            @sf.icon_node(row, "chevron-right", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
          })
          |> ignore
        })
      }
    },
  )
}

///|
/// 设置 › 项目详情页 (`Route::Project(name)`).
pub fn project_detail_page_node(
  v : @view.View,
  src : Source,
  core : Core,
  here : @settings.Here,
  name : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let chain = @sfbase.ProjectDetailChain::new(here.workspace, name)
  chain.bind(v, src)
  let detail = fn() { chain.read(src) }
  let writable = fn() { @sfbase.workspace_projects_writable(src, here.workspace) }

  let note_field = @ui.Field::new()
  let ref_input = @ui.Field::new()

  let note_len : @signals.Signal[Int] = @signals.signal(0)
  let refs_draft : @signals.Signal[Array[String]] = @signals.signal([])
  let base_rev : Ref[String] = Ref("")
  let base_note : Ref[String] = Ref("")
  let base_refs : Ref[Array[String]] = Ref([])
  let dirty : @signals.Signal[Bool] = @signals.signal(false)
  let conflict : @signals.Signal[Bool] = @signals.signal(false)
  let saving : @signals.Signal[Bool] = @signals.signal(false)
  let managing : @signals.Signal[Bool] = @signals.signal(false)
  let banner : @signals.Signal[String] = @signals.signal("")

  // Sync draft when complete snapshot arrives (cached or live); preserve unsaved draft and flag conflict on revision mismatch.
  v.reacts(
    fn() {
      let d = detail()
      (d.complete, d.editable, d.info_revision, d.note, d.refs)
    },
    fn(st) {
      let (complete, _editable, rev, note, refs) = st
      guard complete else { return }
      if base_rev.val == "" {
        base_rev.val = rev
        base_note.val = note
        base_refs.val = refs.copy()
        note_field.set(note)
        note_len.set(note.length())
        refs_draft.set(refs.copy())
        dirty.set(false)
        conflict.set(false)
      } else if rev != base_rev.val {
        if dirty.untracked() {
          conflict.set(true)
        } else if _editable {
          base_rev.val = rev
          base_note.val = note
          base_refs.val = refs.copy()
          note_field.set(note)
          note_len.set(note.length())
          refs_draft.set(refs.copy())
          conflict.set(false)
        }
      }
    },
  )

  let reload_from_server = fn() {
    let d = @signals.untracked(detail)
    guard d.complete else { return }
    base_rev.val = d.info_revision
    base_note.val = d.note
    base_refs.val = d.refs.copy()
    note_field.set(d.note)
    note_len.set(d.note.length())
    refs_draft.set(d.refs.copy())
    dirty.set(false)
    conflict.set(false)
  }

  // Only changed fields relative to `(base_note, base_refs)` are sent — both on normal save AND overwrite save,
  // so overwriting a note conflict never clobbers remotely added refs (and vice versa).
  let save_info = fn(force : Bool) {
    let d = @signals.untracked(detail)
    guard d.editable && @signals.untracked(writable) && !saving.untracked() && !managing.untracked() else { return }
    if !force && conflict.untracked() {
      return
    }
    let cur_note = note_field.text()
    let cur_refs = refs_draft.untracked()
    let note_arg : String? = if cur_note != base_note.val { Some(cur_note) } else { None }
    let refs_arg : Array[String]? = if cur_refs != base_refs.val { Some(cur_refs) } else { None }
    if note_arg is None && refs_arg is None {
      if force || conflict.untracked() {
        reload_from_server()
      } else {
        dirty.set(false)
        conflict.set(false)
      }
      return
    }
    saving.set(true)
    banner.set("")
    @sfbase.project_update_info(src, here.workspace, name, note=note_arg, refs=refs_arg, on_done=fn(res) {
      saving.set(false)
      match res {
        Ok(_) => {
          let latest = @signals.untracked(detail)
          if note_arg is Some(_) {
            base_note.val = cur_note
          }
          if refs_arg is Some(_) {
            base_refs.val = cur_refs.copy()
          }
          // Only advance `base_rev` and sync unedited fields when `latest` is a single complete live snapshot.
          // If the new revision's tail page has not arrived yet, leave `base_rev` unchanged so `v.reacts`
          // atomically syncs `base_rev` and all unedited fields once the complete live snapshot lands.
          if latest.complete && latest.editable {
            base_rev.val = latest.info_revision
            if note_arg is None {
              base_note.val = latest.note
              note_field.set(latest.note)
              note_len.set(latest.note.length())
            }
            if refs_arg is None {
              base_refs.val = latest.refs.copy()
              refs_draft.set(latest.refs.copy())
            }
          }
          dirty.set(false)
          conflict.set(false)
          (core.say)(@sf.t("web-pages.projects.saved"))
        }
        Err(e) => banner.set(e)
      }
    })
  }

  let add_ref_value = fn(raw : String) {
    let trimmed = raw.trim().to_owned()
    if trimmed != "" {
      let cur = refs_draft.untracked().copy()
      if !cur.contains(trimmed) {
        cur.push(trimmed)
        refs_draft.set(cur)
        dirty.set(true)
      }
      ref_input.set("")
    }
  }

  let format_partial = fn(res : @sfbase.ProjectMutationResult) -> String {
    let parts : Array[String] = []
    if res.info_error != "" { parts.push(res.info_error) }
    if res.roster_error != "" { parts.push(res.roster_error) }
    for p in res.peers {
      if !p.ok && p.status != "rig" {
        let who = if p.name != "" { p.name } else { p.station }
        let why = if p.error != "" { p.error } else if p.status != "" { p.status } else { "error" }
        parts.push(who + " (" + why + ")")
      }
    }
    if parts.is_empty() {
      ""
    } else {
      @sf.t("web-pages.projects.partial_warning", args=[("detail", parts.join("; "))])
    }
  }

  let run_rename = fn(raw : String) {
    let to_name = raw.trim().to_owned()
    if to_name == "" || to_name == name || !@signals.untracked(writable) || saving.untracked() || managing.untracked() {
      return
    }
    if dirty.untracked() {
      (core.say)(@sf.t("web-pages.projects.save_first_before_manage"))
      return
    }
    managing.set(true)
    banner.set("")
    @sfbase.project_rename(src, here.workspace, name, to_name, on_done=fn(res) {
      managing.set(false)
      if res.ok {
        let warn = format_partial(res)
        if warn != "" {
          (core.say)(warn)
        } else {
          (core.say)(@sf.t("android-settings.renamed"))
        }
        (core.in_place)(Project(to_name))
      } else if res.status == 409 {
        let msg = @sf.t("web-pages.projects.conflict_409")
        banner.set(msg)
        (core.say)(msg)
      } else {
        banner.set(res.error)
        (core.say)(res.error)
      }
    })
  }

  let open_rename_dialog = fn() {
    if !@signals.untracked(writable) || saving.untracked() || managing.untracked() {
      return
    }
    if dirty.untracked() {
      (core.say)(@sf.t("web-pages.projects.save_first_before_manage"))
      return
    }
    ask(
      @sf.t("web-pages.projects.rename_title"),
      name,
      @sf.t("web-pages.projects.rename_placeholder"),
      @sf.t("web-pages.projects.rename"),
      run_rename,
    )
  }

  let run_merge = fn(to_name : String) {
    if to_name == name || !@signals.untracked(writable) || saving.untracked() || managing.untracked() {
      return
    }
    if dirty.untracked() {
      (core.say)(@sf.t("web-pages.projects.save_first_before_manage"))
      return
    }
    managing.set(true)
    banner.set("")
    @sfbase.project_merge(src, here.workspace, name, to_name, on_done=fn(res) {
      managing.set(false)
      if res.ok {
        let warn = format_partial(res)
        if warn != "" {
          (core.say)(warn)
        }
        if to_name == "" {
          (core.in_place)(Projects)
        } else {
          (core.in_place)(Project(to_name))
        }
      } else {
        banner.set(res.error)
        (core.say)(res.error)
      }
    })
  }

  let open_merge_picker = fn(from : @sf.Anchor) {
    if !@signals.untracked(writable) || saving.untracked() || managing.untracked() {
      return
    }
    if dirty.untracked() {
      (core.say)(@sf.t("web-pages.projects.save_first_before_manage"))
      return
    }
    @sf.panel_nodes(
      @sf.t("web-pages.projects.merge_title"),
      from~,
      fn(pv, pclose) {
        let pchain = @sfbase.ProjectListChain::new(here.workspace)
        pchain.bind(pv, src)
        let psnap = fn() { pchain.read(src) }
        let pkeys = fn() {
          let out : Array[String] = ["cross", "sep"]
          for r in psnap().items {
            if r.name != name {
              out.push("p/" + r.name)
            }
          }
          if psnap().has_more {
            out.push("more")
          }
          out
        }
        @sf.panel_list_node(pv, pkeys, est=44.0, fills=true, fn(r, k) {
          if k == "cross" {
            @sf.action_box_node(r, fn() { @sf.t("web-pages.projects.merge_into_cross") }, fn(_) {
              pclose()
              @sf.confirm(
                @sf.t("web-pages.projects.merge_title"),
                @sf.t("web-pages.projects.merge_cross_confirm_body", args=[("from", name)]),
                @sf.t("web-pages.projects.merge_confirm"),
                fn() { run_merge("") },
                danger=true,
              )
            }, fn(row) {
              row.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
              @sf.words_node(row, fn() { @sf.t("web-pages.projects.merge_into_cross") }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            })
            |> ignore
          } else if k == "sep" {
            r.box(fn(sep) {
              @sf.style_node(sep, fn() { @sf.rule_line })
              sep.margin(Is((proj_pad_x, proj_s1, proj_pad_x, proj_s1))) |> ignore
            })
            |> ignore
          } else if k == "more" {
            @sf.action_box_node(r, fn() { @sf.t("web-pages.projects.load_more") }, fn(_) { pchain.load_more(src) }, fn(row) {
              row.row(Is(true)).lines_up(Is(Some(Middle))).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
              @sf.words_node(row, fn() { @sf.t("web-pages.projects.load_more") }, fn() { proj_summary_words }) |> ignore
            })
            |> ignore
          } else if k.has_prefix("p/") {
            let target = k.exact_view(start=2).to_owned()
            @sf.action_box_node(r, fn() { target }, fn(_) {
              pclose()
              @sf.confirm(
                @sf.t("web-pages.projects.merge_title"),
                @sf.t("web-pages.projects.merge_confirm_body", args=[("from", name), ("to", target)]),
                @sf.t("web-pages.projects.merge_confirm"),
                fn() { run_merge(target) },
                danger=true,
              )
            }, fn(row) {
              row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s2)).padding(Is((proj_pad_x, proj_s2, proj_pad_x, proj_s2))) |> ignore
              @sf.icon_node(row, "folder", 14.0, By(fn() { @sf.theme().p.muted })) |> ignore
              @sf.words_node(row, fn() { target }, fn() { proj_row_name }).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).cuts(Is(true)).allow_ellipsis(Is(true)) |> ignore
            })
            |> ignore
          }
        })
        |> ignore
      },
    )
  }

  let blocks = fn() { ["meta", "banner", "name", "note", "refs", "save", "manage"] }

  @sf.page_node(
    v,
    fn() { name },
    on_back~,
    frame~,
    said?,
    width?,
    blocks,
    fn(b, key) {
      if key == "meta" {
        b.box(fn(row) {
          row
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(proj_s3))
          .padding(Is((0.0, proj_s1, 0.0, proj_s1_5)))
          |> ignore
          @sf.words_node(
            row,
            fn() {
              let d = detail()
              @sf.t("web-pages.projects.chat_count", args=[("n", d.chat_count.to_string())])
            },
            fn() { proj_summary_words },
          )
          |> ignore
          row.show(fn() { detail().running_count > 0 }, along_row=true, fn(run_box) {
            run_box.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s1_5)) |> ignore
            @sf.spokes_node(run_box, 10.0, @sf.mark_yellow) |> ignore
            @sf.words_node(
              run_box,
              fn() { @sf.t("web-pages.projects.running_count", args=[("n", detail().running_count.to_string())]) },
              fn() { proj_summary_words },
            )
            |> ignore
          })
          @sf.words_node(
            row,
            fn() {
              if !detail().editable && detail().error is None {
                @sf.t("web-pages.projects.loading_detail")
              } else {
                ""
              }
            },
            fn() { proj_summary_words },
          )
          |> ignore
        })
        |> ignore
      } else if key == "name" {
        b.box(fn(nb) {
          nb.padding(Is((0.0, proj_s1, 0.0, proj_s1))) |> ignore
          let can_manage = fn() { writable() && !saving.get() && !managing.get() }
          nb.switch_by(can_manage, fn(nb2, can_edit) {
            @sf.group_node(nb2, fn(g) {
              @sf.link_row_node(
                g,
                fn() { @sf.t("web-pages.projects.name_label") },
                open_rename_dialog,
                value=fn() { name },
                chevron=can_edit,
                goes=can_edit,
              )
            })
          })
        })
        |> ignore
      } else if key == "banner" {
        let has_detail_err = fn() {
          match detail().error {
            Some(e) if e != "" => true
            _ => false
          }
        }
        b.show(
          fn() { !writable() || conflict.get() || banner.get() != "" || has_detail_err() },
          fn(box) {
            box.padding(Is((0.0, proj_s1, 0.0, proj_s2))).gap(Is(proj_s2)) |> ignore
            box.show(has_detail_err, fn(derr) {
              derr.gap(Is(proj_s2)) |> ignore
              @sf.words_node(derr, fn() { detail().error.unwrap_or("") }, fn() { proj_warn_words }) |> ignore
              derr.box(fn(btns) {
                btns.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
                @sf.button_node(
                  btns,
                  fn() { @sf.t("common.retry") },
                  fn() { chain.retry(src) },
                  tone=@sf.Tone::Plain,
                )
                |> ignore
              })
              |> ignore
            })
            box.show(fn() { !writable() }, fn(ro) {
              @sf.words_node(ro, fn() { @sf.t("web-main.projects.read_only_hint") }, fn() { proj_note_words }) |> ignore
            })
            box.show(fn() { conflict.get() }, fn(cf) {
              cf.gap(Is(proj_s2)) |> ignore
              @sf.words_node(cf, fn() { @sf.t("web-pages.projects.draft_conflict") }, fn() { proj_warn_words }) |> ignore
              cf.box(fn(btns) {
                btns.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s2)) |> ignore
                @sf.button_node(
                  btns,
                  fn() { @sf.t("web-pages.projects.draft_reload") },
                  reload_from_server,
                  tone=@sf.Tone::Plain,
                  disabled=fn() { !detail().complete || saving.get() },
                )
                |> ignore
                @sf.button_node(
                  btns,
                  fn() { @sf.t("web-pages.projects.draft_overwrite") },
                  fn() { save_info(true) },
                  tone=@sf.Tone::Primary,
                  disabled=fn() { !detail().editable || !writable() || saving.get() || managing.get() },
                )
                |> ignore
              })
              |> ignore
            })
            box.show(fn() { banner.get() != "" }, fn(err) {
              @sf.words_node(err, fn() { banner.get() }, fn() { proj_warn_words }) |> ignore
            })
          },
        )
      } else if key == "note" {
        @sf.section_node(
          b,
          fn() { @sf.t("web-pages.projects.note_label") },
          title_after=fn(l) {
            @sf.words_node(l, fn() { note_len.get().to_string() + " / 2000" }, fn() { proj_row_count }) |> ignore
          },
          fn(sec) {
            @sf.textarea_node(
              sec,
              note_field,
              rows=4,
              most=8,
              placeholder=@sf.t("web-pages.projects.note_placeholder"),
              disabled=fn() { !detail().editable || !writable() || saving.get() || managing.get() },
              edited=fn(s) {
                note_len.set(s.length())
                dirty.set(true)
              },
            )
            |> ignore
          },
        )
      } else if key == "refs" {
        @sf.section_node(
          b,
          fn() { @sf.t("web-pages.projects.refs_label") },
          fn(sec) {
            sec.gap(Is(proj_s2_5)) |> ignore
            // Add input + button directly on canvas (never nested inside a white card).
            sec.show(fn() { writable() }, fn(add_row) {
              add_row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(proj_s2)) |> ignore
              add_row.box(fn(ib) {
                ib.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
                @sf.input_node(
                  ib,
                  ref_input,
                  placeholder=@sf.t("web-pages.projects.refs_placeholder"),
                  disabled=fn() { !detail().editable || saving.get() || managing.get() },
                  submitted=fn(s) { add_ref_value(s) },
                )
                |> ignore
              })
              |> ignore
              @sf.button_node(
                add_row,
                fn() { @sf.t("web-pages.projects.refs_add") },
                fn() { add_ref_value(ref_input.text()) },
                tone=@sf.Tone::Plain,
                disabled=fn() { !detail().editable || saving.get() || managing.get() },
              )
              .shrink(Is(0.0))
              |> ignore
            })
            // Existing refs + native `+ 添加目录 >` row inside a native settings group card (100% concentric corners).
            sec.show(
              fn() { !refs_draft.get().is_empty() || writable() },
              fn(gbox) {
                @sf.group_node(gbox, fn(g) {
                  g.each(
                    fn() { refs_draft.get() },
                    fn(r) { r },
                    fn(slot, r_sig) {
                      let r_val = r_sig.untracked()
                      slot.show(
                        fn() { refs_draft.get().get(0) != Some(r_val) },
                        at_once=true,
                        fn(sep) {
                          @sf.style_node(sep, fn() { @sf.rule_line })
                          sep.margin(Is((proj_pad_x, 0.0, proj_pad_x, 0.0))) |> ignore
                        },
                      )
                      slot.box(fn(row) {
                        row
                        .row(Is(true))
                        .lines_up(Is(Some(Middle)))
                        .gap(Is(proj_s2))
                        .padding(Is((proj_pad_x, 2.0, 2.0, 2.0)))
                        .min_height(Is(Some(36.0)))
                        |> ignore
                        @sf.words_node(row, fn() { r_sig.get() }, fn() { proj_ref_words })
                        .grow(Is(1.0))
                        .basis(Is(Some(0.0)))
                        .min_width(Is(Some(0.0)))
                        .cuts(Is(true))
                        .allow_ellipsis(Is(true))
                        |> ignore
                        row.show(fn() { detail().editable && writable() && !saving.get() && !managing.get() }, along_row=true, fn(rm) {
                          @sf.icon_button_node(rm, "close", fn() { @sf.t("web-pages.projects.refs_remove") }, fn() {
                            refs_draft.set(refs_draft.untracked().filter(fn(x) { x != r_val }))
                            dirty.set(true)
                          })
                          |> ignore
                        })
                      })
                      |> ignore
                    },
                  )
                  g.show(fn() { writable() }, fn(add_dir_slot) {
                    add_dir_slot.show(fn() { !refs_draft.get().is_empty() }, at_once=true, fn(sep) {
                      @sf.style_node(sep, fn() { @sf.rule_line })
                      sep.margin(Is((proj_pad_x, 0.0, proj_pad_x, 0.0))) |> ignore
                    })
                    @sf.link_row_node(
                      add_dir_slot,
                      fn() { @sf.t("web-main.preset.add") },
                      fn() {
                        if !@signals.untracked(detail).editable || !@signals.untracked(writable) || saving.untracked() || managing.untracked() {
                          return
                        }
                        open_station_dir_picker(src, here.workspace, fn(st_name, path) {
                          let entry = if st_name != "" { st_name + ":" + path } else { path }
                          add_ref_value(entry)
                        })
                      },
                    )
                  })
                })
              },
            )
          },
        )
      } else if key == "save" {
        b.box(fn(row) {
          row
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .padding(Is((0.0, proj_s1, 0.0, proj_s4 + proj_s2)))
          |> ignore
          @sf.button_node(
            row,
            fn() { @sf.t("web-pages.projects.save") },
            fn() { save_info(false) },
            tone=@sf.Tone::Primary,
            busy=fn() { saving.get() },
            disabled=fn() { !detail().editable || !writable() || !dirty.get() || conflict.get() || managing.get() },
          )
          |> ignore
        })
        |> ignore
      } else if key == "manage" {
        @sf.section_node(
          b,
          fn() { @sf.t("web-pages.projects.manage_section") },
          fn(sec) {
            sec.gap(Is(proj_s2_5)) |> ignore
            let can_manage = fn() { writable() && !saving.get() && !managing.get() }
            sec.switch_by(can_manage, fn(s2, can_edit) {
              @sf.group_node(s2, fn(g) {
                @sf.link_row_node(
                  g,
                  fn() { @sf.t("web-pages.projects.merge") },
                  fn() { open_merge_picker(Unanchored) },
                  chevron=can_edit,
                  goes=can_edit,
                )
              })
            })
          },
        )
      }
    },
  )
}
