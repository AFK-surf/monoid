// A folder of a station's drive: one page on every screen (the same on every screen, and what differs), as nodes of the
// window's tree. What it is for: a person comes to find a file and open it (read, played, previewed, saved), and to put
// files in and keep them in order (up, a new folder, a name changed, deleted, dragged into a folder, 收藏). So, top to
// bottom: its way down from its root (the station's switch first), what it holds in a line (why it could not be read,
// 重试), the files going up into it, its entries in the way it is shown (columns, a tree, a list: drive_views_node.mbt),
// the preview beside them where the room has it (drive_pane_node.mbt). What can be done to it (its ways, put up, a new
// folder, read again, 收藏, its ⋯) is `folder_actions_node`, put in the bar it is shown under. What differs is not the
// page's: the sizes are the theme's (Theme.items), the rows on a card or on the page the page's arrangement's, whether a
// press opens or chooses and whether the ⋯ is there the hand's (drive_row_node), the menus the presenters', how many of
// the bar's actions are out the bar's room (View::fits), which ways it can be shown and how many columns the list's room
// (views_for), tabs and halves or a stack the frame's (files_page_node.mbt).

///|
/// A folder as its page gives it (FolderView's props, and what the files' page around it does): the place's key (its
/// side), the workspace, the station (as it is now), the folder (its root said), whether it is the side in front (where
/// the keys go); another folder of the station shown (`replace`: as the keys go), a folder opened in a tab or beside
/// (None: no files' page around it), 前往文件夹 (⌘⇧G).
pub(all) struct FolderOf {
  key : String
  ws : String
  st : () -> DvStation
  at : DriveAt
  front : () -> Bool
  room : () -> Double
  go : (DriveAt, Bool) -> Unit
  open_in : ((DriveAt, Bool) -> Unit)?
  go_to : (() -> Unit)?
}

///|
/// The rights the viewer has at the folder's station, as they are now.
fn FolderOf::rights(self : FolderOf, src : Source) -> DvRights {
  dv_rights(src, self.ws, Some((self.st)()))
}

///|
/// The folder's browsing, as the files' page shows it (`page`'s), `view` its way as it is now.
pub fn FolderOf::browse(self : FolderOf, src : Source, view : () -> String) -> Browse {
  let at = self.at
  let open_row = fn(in_ : DriveAt, e : DvEntry) {
    let near = if in_.path == at.path {
      @signals.untracked(fn() { self.browse_of(src, view).arranged(src, in_.path) }).unwrap_or([e])
    } else {
      [e]
    }
    open_entry(src, "page", in_, e, near, fn(to) { (self.go)(to, false) })
  }
  {
    key: self.key,
    owner: "page",
    view,
    at: fn() { at },
    write: fn() { self.rights(src).write },
    does: {
      open: open_row,
      preview: open_row,
      go: fn(p, replace) { (self.go)({ ..at, path: p }, replace) },
      remove: fn(items) { remove_entries(src, @signals.untracked(self.st), items) },
    },
  }
}

///|
/// The browsing alone (what it does with what the core answers left out): for what reads the order of a folder.
fn FolderOf::browse_of(self : FolderOf, src : Source, view : () -> String) -> Browse {
  let at = self.at
  {
    key: self.key,
    owner: "page",
    view,
    at: fn() { at },
    // (the same place as browse's, so read as the same topic: never another subscription for it)
    write: fn() { self.rights(src).write },
    does: { open: fn(_, _) {  }, preview: fn(_, _) {  }, go: fn(_, _) {  }, remove: fn(_) {  } },
  }
}

///|
/// A row's menu (FolderView itemsIn): about what is chosen when it is among it and more than it, else about it alone.
fn row_items(src : Source, f : FolderOf, b : Browse, in_ : DriveAt, e : DvEntry) -> Array[@sf.MenuItem?] {
  let all = b.chosen_with(src, in_.path, e)
  let root = in_.root.unwrap_or("")
  let st = (f.st)()
  let rights = f.rights(src)
  let write = rights.write
  // (each with its icon: the words of every item on one line)
  let out : Array[@sf.MenuItem?] = []
  let item = fn(label : String, icon : String, act : () -> Unit) { out.push(Some(@sf.menu_item_of(label, icon~, act))) }
  if all.length() > 1 {
    // what is chosen, several at once
    let files = all.filter(fn(x) { !x.1.dir })
    if files.length() > 0 {
      item(@sf.t("web-pages.drive.downloadMany", args=[("n", files.length().to_string())]), "download", fn() {
        for x in files {
          save_entry(src, x.0, x.1)
        }
      })
    }
    item(@sf.t("web-pages.drive.copyPaths"), "copy", fn() {
      copy_path(all.map(fn(x) { dv_absolute(root, dv_join(x.0.path, x.1.name)) }).join("\n"))
    })
    if write {
      out.push(
        Some(
          @sf.menu_item_of(
            @sf.t(if st.trash { "web-pages.drive.toTrashMany" } else { "web-pages.drive.deleteMany" }, args=[("n", all.length().to_string())]),
            icon="trash",
            danger=true,
            fn() { remove_entries(src, st, all) },
          ),
        ),
      )
    }
    return out
  }
  let full = dv_join(in_.path, e.name)
  let abs = dv_absolute(root, full)
  item(@sf.t("web-pages.drive.open"), "eye", fn() { open_entry(src, "page", in_, e, [e], fn(to) { (f.go)(to, false) }) })
  match entry_beside(in_, e) {
    Some(open) => item(@sf.t("web-main.preview.openBeside"), "panel-open", open)
    None => ()
  }
  if !e.dir {
    item(@sf.t("web-pages.drive.download"), "download", fn() { save_entry(src, in_, e) })
    item(@sf.t("android-misc.drive.share"), "external", fn() { share_entry(src, in_, e) })
  } else if rights.zip {
    item(@sf.t("web-pages.drive.downloadZip"), "download", fn() { save_entry(src, in_, e) })
  }
  item(@sf.t("web-pages.drive.copyPath"), "copy", fn() { copy_path(abs) })
  match f.open_in {
    Some(open) if e.dir => {
      item(@sf.t("web-pages.files.openInTab"), "plus", fn() { open({ ..in_, path: full }, false) })
      item(@sf.t("web-pages.files.openBeside"), "view-columns", fn() { open({ ..in_, path: full }, true) })
    }
    _ => ()
  }
  if e.dir {
    if terminals_here() && (src.asks_terminals)() && abs != "" {
      item(@sf.t("web-pages.remote.openHereTerminal"), "terminal", fn() { @sfbase.open_terminal(in_.station, "new", abs, "") })
    }
    let kept = favorite_has(favorites_in(src, f.ws, [st]), in_.station, root, full)
    item(@sf.t(if kept { "web-pages.files.unfavorite" } else { "web-pages.files.favorite" }, args=[("name", e.name)]), "star", fn() {
      if kept {
        favorite_remove(src, f.ws, in_.station, root, full)
      } else {
        favorite_add(src, f.ws, { station: in_.station, root, path: full, name: e.name })
      }
    })
  }
  if write {
    // (changed in place, wherever: the row kept in view over the soft keyboard)
    item(@sf.t("web-pages.drive.rename"), "edit", fn() { b.start_rename(src, in_.path, e) })
    out.push(
      Some(
        @sf.menu_item_of(
          @sf.t(if st.trash { "web-pages.drive.toTrash" } else { "web-pages.drive.delete" }),
          icon="trash",
          danger=true,
          fn() { remove_entries(src, st, [(in_, e)]) },
        ),
      ),
    )
  }
  out
}

///|
/// The folder's own (FolderView) in node `parent` (filling it): a folder of a station in the way its room has it shown
/// (views_for), `head` over its rows (in their list, scrolled with them; over the columns, which scroll each their
/// own), the files going up into it, its preview beside it (⌘⇧P) where the room has it; `foot` the frame's room under
/// the last row. What is dropped where no folder of it takes it goes into it. Its keys while it is in front: the rows'
/// (the core's), ⌘U puts files up, ⌘⇧N a new folder, ⌘⇧P the preview.
pub fn folder_view_node(
  parent : @view.View,
  src : Source,
  f : FolderOf,
  head : (@view.View, Browse) -> Unit,
  foot? : () -> Double = fn() { 0.0 },
) -> Unit {
  let at = f.at
  let root = at.root.unwrap_or("")
  parent.box(fn(whole) {
    // (shorter than what it holds where the room is (a keyboard come up under it): what it holds scrolls in it)
    whole.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    @sf.style_node(whole, fn() { with_pane })
    let held = whole
    {
      // (the preview beside the list where its room has both, as its frame gives it: the list keeping what is left)
      let previewing = fn() { preview_shown(src, "page") && pane_fits((f.room)()) }
      let list_room = fn() { if previewing() { (f.room)() - pane_w - 1.0 } else { (f.room)() } }
      let view = fn() { view_in(src, "page", list_room()) }
      let b = f.browse(src, view)
      b.follow(held, src)
      // (what is under way, which its rows say of themselves (entry_busy), held from the first: what the shell asked of
      // it as it opened taken over, never let go of till its rows come)
      held.reacts(fn() { src.topic("doing", {}).get().value is Some(_) }, fn(_) {  })
      let write = fn() { f.rights(src).write }
      // (kept as the folder the files' page last showed, while it is the side in front)
      held.reacts(f.front, fn(front) { if front { keep_files_page(f.ws, at) } })
      let entries = fn() { dv_entries(src, at.station, root, at.path).unwrap_or([]) }
      let into = fn(folder : DriveAt) -> DriveAt? { if @signals.untracked(write) { Some(folder) } else { None } }
      let s : Shown = {
        src,
        b,
        row_of: fn(in_, e) {
          let name = @signals.untracked(e).name
          {
            items: fn() { row_items(src, f, b, in_, @signals.untracked(e)) },
            open: fn() { (b.does.open)(in_, @signals.untracked(e)) },
            press: fn() { b.press(src, in_.path, @signals.untracked(e).name) },
            menu: fn() { b.choose(src, in_.path, @signals.untracked(e).name) },
            chosen: fn() { b.is_chosen(src, in_.path, name) },
            renaming: fn() { b.renaming() == Some(row_key(in_.path, name)) },
            rename: fn(to) { b.rename(src, in_.path, @signals.untracked(e), to) },
            drop: if @signals.untracked(e).dir { into({ ..in_, path: dv_join(in_.path, name) }) } else { None },
          }
        },
        drop_on: into,
        clear: fn() { b.clear(src) },
        write,
        transfers: fn() { (f.st)().transfers },
        stacked: fn() { list_room() < row_stack_below },
        carries: drag_source_node,
      }
      // its keys while it is in front (the rows', the core's; ⌘U, ⌘⇧N), anywhere on it but a field
      held.on_key(fn(k) {
        guard @signals.untracked(f.front) else { return false }
        let cmd = (k.mods & (@ui.mod_cmd | @ui.mod_ctrl)) != 0
        let shift = (k.mods & @ui.mod_shift_key) != 0
        if cmd && !shift && k.code == @ui.key_of_char('u') && @signals.untracked(write) {
          upload_into(src, at)
          return true
        }
        if cmd && shift && k.code == @ui.key_of_char('n') && @signals.untracked(write) {
          b.new_folder(src, at.path)
          return true
        }
        b.key(src, k.code, k.mods)
      })
      |> ignore
      // (the keymap's files.preview: ⌘⇧P, as Finder's preview pane, or as changed)
      held.key_context("Files").on_action("files.preview", fn(_) {
        set_preview_shown(src, "page", !@signals.untracked(previewing))
        true
      }, can=f.front)
      |> ignore
      // (one up stays till its folder's own row of it comes: the one row in the other's place, dv_up_done)
      let ups_here = fn() {
        @sfbase.ups.uploads.filter(fn(u) {
          u.station == at.station &&
          u.root == root &&
          u.dir == at.path &&
          !(u.state.get() == "done" && entries().iter().any(fn(e) { e.name == u.name.get() }))
        })
      }
      let empty = fn(v : @view.View) { folder_empty_node(v, fn() { if write() { Some(fn() { upload_into(src, at) }) } else { None } }) }
      // a press where there is no row: what can be done to the folder, its menu
      let folder_menu = fn() -> Array[@sf.MenuItem?] {
        let a = b.arrangement(src)
        let menu : Array[@sf.MenuItem?] = []
        if write() {
          menu.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.mkdir"), icon="folder-plus", fn() { b.new_folder(src, at.path) })))
          menu.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.upload"), icon="upload", fn() { upload_into(src, at) })))
        }
        for by in ["name", "time", "size", "kind"] {
          menu.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.sortBy." + by), chosen=a.by == by, fn() { b.arrange_as(src, by~, down=false) })))
        }
        menu.push(Some(@sf.menu_item_of(@sf.t(if a.hidden { "web-pages.drive.hideHidden" } else { "web-pages.drive.showHidden" }), fn() {
          b.arrange_as(src, hidden=!a.hidden)
        })))
        menu.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.refresh"), icon="refresh", fn() { refresh_folder(src, at) })))
        let folder_dir = dv_absolute(root, at.path)
        if terminals_here() && (src.asks_terminals)() && folder_dir != "" {
          menu.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openHereTerminal"), icon="terminal", fn() {
            @sfbase.open_terminal(at.station, "new", folder_dir, "")
          })))
        }
        menu
      }
      let name = fn() { folder_name((f.st)(), at) }
      held.box(fn(list) {
        @sf.style_node(list, fn() { list_box }, in_row=true)
        let lit = drop_target_node(list, src, "pane/" + f.key + "/" + at.station + "/" + root + "/" + at.path, Some(at), @signals.untracked(name), write, fn() {
          (f.st)().transfers
        }, 0)
        // (a ground round its rows: a press there chooses none; a right click there, the folder's menu)
        list.presses(Is(true)).on_press(s.clear).on_menu(fn(m) { @sf.menu(folder_menu(), from=@sf.at_point(m.wx, m.wy)) }) |> ignore
        let stale_node = fn(h : @view.View) {
          h.show(fn() {
            let (value, error) = drive_folder(src, at.station, root, at.path)
            value is Some(_) && error is Some(_)
          }, at_once=true, fn(s) {
            folder_error_slot_node(
              s,
              fn() {
                match drive_folder(src, at.station, root, at.path).1 {
                  Some(e) => @sf.t("android-misc.drive.stale", args=[("error", e)])
                  None => ""
                }
              },
              fn() { refresh_folder(src, at) },
              title=fn() { "" },
              busy=fn() { refreshing(at) },
              tone=Plain,
              stale=true,
              inset=f.open_in is Some(_),
            )
          })
        }
        let head_all = fn(h : @view.View) {
          head(h, b)
          stale_node(h)
          uploads_node(h, src, ups_here)
          // (its columns' heads where its rows have their columns: not where they say it under the name)
          h.show(fn() { view() == "list" && !(b.arranged(src, at.path).unwrap_or([]).is_empty()) && list_room() >= row_stack_below }, fn(lh) {
            list_head_node(lh, fn() { b.arrangement(src) }, fn(by) {
              let a = @signals.untracked(fn() { b.arrangement(src) })
              if by == a.by {
                b.arrange_as(src, down=!a.down)
              } else {
                b.arrange_as(src, by~, down=false)
              }
            })
          })
        }
        list.pick(fn() {
          if view() == "columns" {
            "columns"
          } else {
            let (value, error) = b.folder(src, at)
            match (value, error) {
              (None, Some(_)) => "failed"
              (None, None) => "reading"
              (Some(_), _) => if b.arranged(src, at.path) is None { "reading" } else { view() }
            }
          }
        }, fn(v, shows) {
          v.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          // (in its own frame, in from its sides as a page's blocks are; on the files' page, its side's own room)
          if f.open_in is None {
            v.padding(Is((@ui.Space::px(S3), 0.0, @ui.Space::px(S3), 0.0))) |> ignore
          }
          match shows {
            "columns" => {
              // (columns stay while the folder opened is read: each column owns its own reading, stale, or error card)
              head(v, b)
              uploads_node(v, src, ups_here)
              columns_view_node(v, s, { ..at, path: "" }, fn() { at.path }, empty=fn(e) {
                e.show(fn() { ups_here().is_empty() }, fn(x) { empty(x) })
              })
            }
            // (why it could not be read: a card under the head, with its Retry button)
            "failed" => {
              head(v, b)
              folder_error_slot_node(
                v,
                fn() { b.folder(src, at).1.unwrap_or("") },
                fn() { refresh_folder(src, at) },
                busy=fn() { refreshing(at) },
                inset=f.open_in is Some(_),
              )
            }
            "reading" => {
              head(v, b)
              rows_sample_node(v, s, at, 8)
            }
            way =>
              rows_view_node(v, s, at, way == "tree", head=head_all, empty=fn(e) { e.show(fn() { ups_here().is_empty() }, fn(x) { empty(x) }) }, foot~)
          }
        })
        drop_over_node(list, lit, name)
      })
      |> ignore
      held.show(previewing, fn(slot) {
        @sf.style_node(slot, fn() { pane_slot_row }, in_row=true)
        let shown = fn() {
          let ch = b.chosen(src)
          if ch.names.length() > 1 {
            Many(ch.names.length())
          } else {
            match ch.names.get(0) {
              Some(n) =>
                match dv_entries(src, at.station, root, ch.folder).unwrap_or([]).iter().find_first(fn(e) { e.name == n }) {
                  Some(e) => One({ ..at, path: ch.folder }, e)
                  None => Nothing
                }
              None => Nothing
            }
          }
        }
        drive_pane_node(
          slot,
          src,
          shown,
          fn() { (f.st)().name },
          fn() {
            match @signals.untracked(shown) {
              One(pat, e) => open_entry(src, "page", pat, e, [e], fn(to) { (f.go)(to, false) })
              _ => ()
            }
          },
          fn() {
            match @signals.untracked(shown) {
              One(pat, e) => save_entry(src, pat, e)
              _ => ()
            }
          },
        )
      })
    }
  })
  |> ignore
}

///|
/// The folder's head (the phone's Crumbs and mCount), in `parent`: its way (its station's button, then the way down
/// from its root to it, each a way back to it), its name where the frame's bar has not said it (`titled`: h1), and what
/// it holds in a line (hidden while a folder-error or stale card is shown below). In as far as the rows' words are,
/// wherever it is shown.
pub fn folder_head_node(parent : @view.View, src : Source, f : FolderOf, b : Browse, front_it : () -> Unit, titled : Bool) -> Unit {
  let at = f.at
  let root = at.root.unwrap_or("")
  @sf.rows_head_node(parent, first=true, fn(h) {
    h.box(fn(trail) {
      @sf.style_node(trail, fn() { head_trail })
      station_switch_node(trail, src, f.ws, at, f.st, fn(to) { (f.go)(to, false) }, f.open_in, front_it)
      // the way down from the root to it (the root alone at the root), each but the last a way back to it; the folder
      // itself is already named by the page or its bar: the trail holds only places one can go back to
      let ancestors = fn() -> Array[(String, String)] {
        let parts = at.path.split("/").filter(fn(p) { p != "" }).map(fn(p) { p.to_owned() }).to_array()
        let levels : Array[(String, String)] = [(folder_name((f.st)(), { ..at, path: "" }), "")]
        let mut so_far = ""
        for p in parts {
          so_far = dv_join(so_far, p)
          levels.push((p, so_far))
        }
        levels[:levels.length() - 1].to_owned()
      }
      if at.path != "" {
        trail.box(fn(w) {
          @sf.style_node(w, fn() { head_way }, in_row=true)
          @sf.way_line_node(w, fn() { ancestors().map(fn(l) { l.0 }) }, folder_crumb_way, fn(i) {
            front_it()
            match @signals.untracked(ancestors).get(i) {
              Some((_, path)) => (f.go)({ ..at, path, }, false)
              None => ()
            }
          }, last_link=true)
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
    if titled {
      @sf.words_node(h, fn() { pane_parts(at, dv_stations(src, f.ws).0.unwrap_or([])).0 }, fn() { head_title }) |> ignore
    }
    let line = fn() -> (Int, String) {
      let (value, error) = drive_folder(src, at.station, root, at.path)
      match (value, error) {
        (_, Some(_)) => (4, "")
        (Some(v), None) =>
          match b.count_text(src) {
            Some(shown) => (3, shown + (if flag(Some(v), "truncated") { " · " + @sf.t("web-pages.drive.truncated") } else { "" }))
            None => (0, "")
          }
        (None, None) => (0, "")
      }
    }
    h.show(fn() { line().0 != 4 }, at_once=true, fn(row) {
      row.pick(fn() { line().0 }, at_once=true, fn(l, k) {
        match k {
          3 => @sf.words_node(l, fn() { line().1 }, fn() { @sf.theme().rows.note }).shown_nowhere() |> ignore
          // what it holds while it is read, in its bones: the line's room kept, as the columns under it stay
          _ =>
            @sf.waiting_node(l, fn(w) {
              @sf.words_node(w, fn() { @sf.sample_words(8) }, fn() { @sf.theme().rows.note }) |> ignore
            })
        }
      })
    })
  })
}

///|
/// Placement wrapper for `drive_error_card_node` on the files page: aligns horizontally with the folder heading (when
/// `inset`, where the outer files shell has no `px=S3`) and caps card width at `540pt` so wide layouts stay scannable
/// while narrow viewports naturally span full width.
fn folder_error_slot_node(
  parent : @view.View,
  words : () -> String,
  retry : () -> Unit,
  title? : () -> String = fn() { @sf.t("web-pages.drive.cantOpen") },
  busy? : () -> Bool = fn() { false },
  tone? : @sf.Tone = Primary,
  stale? : Bool = false,
  inset? : Bool = false,
) -> Unit {
  parent.box(fn(outer) {
    @sf.style_node(outer, fn() {
      match (inset, stale) {
        (true, false) => folder_err_slot_inset
        (true, true) => folder_err_stale_inset
        (false, false) => folder_err_slot_flush
        (false, true) => folder_err_stale_flush
      }
    })
    outer.box(fn(card_room) {
      @sf.style_node(card_room, fn() { folder_err_card_room })
      drive_error_card_node(card_room, words, retry, title~, busy~, tone~)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The way's look (the crumbs): a step 4 round, the way's words the row's note's (muted), where it is in the words'
/// colour, the chevrons subtle.
fn folder_crumb_way() -> @sf.WayLook {
  let note = @sf.theme().rows.note
  {
    line: folder_crumb_line,
    step: folder_crumb_step,
    words: note.then(folder_crumb_words),
    here: note.then(folder_crumb_here),
    chevron: folder_crumb_chevron,
    chevron_ink: @sf.theme().p.subtle,
  }
}

///|
/// What can be done to the folder (FolderView's actions), in `parent` (the bar it is shown under: the files' page's
/// while it is in front, or its own): its ways, the preview, putting files up and a new folder; its ⋯ holds what is
/// needed less (read again, 收藏, the order and hidden files, the path and a folder by its path) and what the bar has
/// not the room for, the preview first, putting files up last. `others`: the files' page's other sides, as they are
/// shown (another way pressed is theirs too). `room`: the list's room across, as it is now.
pub fn folder_actions_node(
  parent : @view.View,
  src : Source,
  f : FolderOf,
  room : () -> Double,
  others? : () -> Array[FolderOf] = fn() { [] },
  tips? : @sf.TipLayer,
) -> Unit {
  let at = f.at
  let root = at.root.unwrap_or("")
  let previewing = fn() { preview_shown(src, "page") }
  let list_room = fn() { if previewing() && pane_fits(room()) { room() - pane_w - 1.0 } else { room() } }
  let view = fn() { view_in(src, "page", list_room()) }
  let b = f.browse(src, view)
  let write = fn() { f.rights(src).write }
  let lit = fn(on : Bool) { if on { @sf.theme().p.accent } else { @sf.theme().p.muted } }
  let press_view = fn(v : String) {
    let sides = @signals.untracked(others).map(fn(o) { o.browse(src, view) })
    view_press(src, b, v, others=sides)
  }
  let mkdir = fn() { b.new_folder(src, at.path) }
  let upload = fn() { upload_into(src, at) }
  // what leaves the bar short of room goes into its ⋯ (each by its part, read as the ⋯ is pressed)
  let parts : Array[(@view.View, () -> Array[@sf.MenuItem?])] = []
  parent.box(fn(row) {
    @sf.style_node(row, fn() { actions_row() })
    row.fits(Is(true)) |> ignore
    // (short of room, the preview leaves first, then the view, a new folder and uploading)
    let part = row.box(fn(p) {
      p.drops(Is(folder_drop_view)) |> ignore
      view_switch_node(p, fn() { views_for(list_room()) }, fn() { view_pressed("page", view()) }, press_view, tips?)
    })
    parts.push((part, fn() {
      view_icons
      .filter(fn(w) { w.0 != view_pressed("page", view()) && views_for(list_room()).contains(w.0) })
      .map(fn(w) { Some(@sf.menu_item_of(@sf.t("web-pages.drive.view." + w.0), fn() { press_view(w.0) }, icon=w.1)) })
    }))
    let preview = row.box(fn(p) {
      p.drops(Is(folder_drop_preview)).laid_nowhere(By(fn() { !pane_fits(room()) })) |> ignore
      @sf.icon_button_node(
        p,
        "panel-open",
        fn() { @sf.t(if previewing() { "web-pages.files.hidePreview" } else { "web-pages.files.showPreview" }) },
        fn() { set_preview_shown(src, "page", !@signals.untracked(previewing)) },
        tips?,
        icon_now=fn() { if previewing() { "panel-close" } else { "panel-open" } },
        shortcut="files.preview",
        ink=fn() { lit(previewing()) },
        on=previewing,
      )
      |> ignore
    })
    parts.push((preview, fn() {
      if pane_fits(room()) {
        [
          Some(@sf.menu_item_of(@sf.t(if previewing() { "web-pages.files.hidePreview" } else { "web-pages.files.showPreview" }), fn() {
            set_preview_shown(src, "page", !previewing())
          }, icon=if previewing() { "panel-close" } else { "panel-open" })),
        ]
      } else {
        []
      }
    }))
    let up = row.box(fn(p) {
      p.drops(Is(folder_drop_upload)).laid_nowhere(By(fn() { !write() })) |> ignore
      @sf.icon_button_node(p, "upload", fn() { @sf.t("web-pages.drive.upload") }, upload, tips?) |> ignore
    })
    parts.push((up, fn() { [Some(@sf.menu_item_of(@sf.t("web-pages.drive.upload"), upload, icon="upload"))] }))
    let mk = row.box(fn(p) {
      p.drops(Is(folder_drop_mkdir)).laid_nowhere(By(fn() { !write() })) |> ignore
      @sf.icon_button_node(p, "folder-plus", fn() { @sf.t("web-pages.drive.mkdir") }, mkdir, tips?) |> ignore
    })
    parts.push((mk, fn() { [Some(@sf.menu_item_of(@sf.t("web-pages.drive.mkdir"), mkdir, icon="folder-plus"))] }))
    // its ⋯: what left the bar, then read again, 收藏, the order, hidden files, the path and a folder by its path
    @sf.icon_button_opens_node(row, "more", fn() { @sf.t("web-main.menu.more") }, fn(m) {
      let st = @signals.untracked(f.st)
      let name = folder_name(st, at)
      let kept = favorite_has(favorites_in(src, f.ws, [st]), at.station, root, at.path)
      let items : Array[@sf.MenuItem?] = []
      for x in parts {
        if x.0.left_out() {
          items.push_iter((x.1)().iter())
        }
      }
      if !items.is_empty() {
        items.push(None)
      }
      items.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.refresh"), icon="refresh", disabled=refreshing(at), fn() {
        refresh_folder(src, at)
      })))
      items.push(Some(@sf.menu_item_of(
        @sf.t(if kept { "web-pages.files.unfavorite" } else { "web-pages.files.favorite" }, args=[("name", name)]),
        icon="star",
        fn() {
          if kept {
            favorite_remove(src, f.ws, at.station, root, at.path)
          } else {
            favorite_add(src, f.ws, { station: at.station, root, path: at.path, name })
          }
        },
      )))
      let a = b.arrangement(src)
      items.push(None)
      for by in ["name", "time", "size", "kind"] {
        items.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.sortBy." + by), chosen=a.by == by, fn() { b.arrange_as(src, by~, down=false) })))
      }
      items.push(Some(@sf.menu_item_of(@sf.t(if a.hidden { "web-pages.drive.hideHidden" } else { "web-pages.drive.showHidden" }), fn() {
        b.arrange_as(src, hidden=!a.hidden)
      })))
      items.push(None)
      items.push(Some(@sf.menu_item_of(@sf.t("web-pages.drive.copyPath"), icon="copy", fn() { copy_path(dv_absolute(root, at.path)) })))
      let here = dv_absolute(root, at.path)
      if terminals_here() && (src.asks_terminals)() && here != "" {
        items.push(Some(@sf.menu_item_of(@sf.t("web-pages.remote.openHereTerminal"), icon="terminal", fn() {
          @sfbase.open_terminal(at.station, "new", here, "")
        })))
      }
      match f.go_to {
        Some(g) => items.push(Some(@sf.menu_item_of(@sf.t("web-pages.files.goTo"), icon="search", further=true, g)))
        None => ()
      }
      @sf.menu(items, from=Node(m), along=End)
    })
    |> ignore
  })
  |> ignore
}

///|
/// The order a folder's actions go into its ⋯ in, short of room (the preview first, putting files up last).
let folder_drop_preview : Int = 1

///|
let folder_drop_view : Int = 2

///|
let folder_drop_mkdir : Int = 3

///|
let folder_drop_upload : Int = 4

///|
/// The files going up into the folder shown, together as its rows are, in `parent`: a row each by its serial.
fn uploads_node(parent : @view.View, src : Source, ups_here : () -> Array[DvUpload]) -> Unit {
  parent.box(fn(g) {
    // (each by its serial, read by it: its place among them the piece of their card it is)
    let by_serial = g.keyed_by(fn() {
      let all = ups_here()
      all.mapi(fn(i, u) { (u.serial, @sf.card_piece_of(i, all.length())) })
    }, fn(x) { x.0 })
    g.each(fn() { by_serial.keys() }, fn(n) { n }, fn(row, n) {
      let serial = n.untracked()
      // (its upload's own, as the row is made: its signals what it binds)
      guard @signals.untracked(ups_here).filter(fn(u) { u.serial == serial }).get(0) is Some(u) else { return }
      let piece = fn() { by_serial.get(serial).map(fn(x) { x.1 }).unwrap_or(CardWhole) }
      @sf.card_piece_node(row, piece, fn(r) { upload_row_node(r, src, u) })
    })
  })
  |> ignore
}

///|
/// A file going up into the folder shown (UploadRow), in `parent`: its mark, its name, how far (a thin bar, sent of its
/// size); its name taken there (替换, 保留两者), or why it failed (重试); × lets it go. Wide, how far beside its name;
/// narrower than its columns need (row_stack_below), under it, as a list's row says what it is.
fn upload_row_node(parent : @view.View, src : Source, u : DvUpload) -> Unit {
  let size = u.bytes.length()
  let part = fn() { if size > 0 { dmin(u.sent.get().to_double() / size.to_double(), 1.0) } else { 0.0 } }
  let how_far = fn() {
    @sf.t("web-pages.drive.uploading", args=[("sent", @sf.file_size(u.sent.get().to_double())), ("size", @sf.file_size(size.to_double()))])
  }
  let replace = fn() {
    u.replace = true
    u.state.set("waiting")
    dv_pump(src)
  }
  parent.box(fn(room) {
    @sf.row_apart_node(room)
    room.box(fn(g) {
      @sf.style_node(g, fn() { entry_plain })
      g.by_room(fn(held, given) {
        let stacked = fn() { given.width() < row_stack_below }
        // its mark, its name and its keys on its first line; under it (stacked) or beside its name, how far, what is
        // asked (its answers after it) or why it failed
        let failed = fn() { u.state.get() == "failed" }
        // (its keys over its first line's end, each in the middle of a square as tall as that line: the last 8 in
        // from the row's end and top, concentric with the card's corner where the row is its first)
        let key_in = fn(parent : @view.View, made : (@view.View) -> Unit) {
          parent.box(fn(sq) {
            @sf.style_node(sq, fn() { upload_key_square }, in_row=true)
            made(sq)
          })
          |> ignore
        }
        g.box(fn(o) {
          o.over(Is(true)) |> ignore
          @sf.style_node(o, fn() { upload_keys })
          o.show(failed, at_once=true, fn(r) {
            key_in(r, fn(sq) {
              @sf.icon_button_node(sq, "retry", fn() { @sf.t("web-pages.drive.retry") }, fn() {
                u.state.set("waiting")
                u.error.set("")
                u.sent.set(0)
                dv_pump(src)
              })
              |> ignore
            })
          })
          key_in(o, fn(sq) {
            @sf.icon_button_node(sq, "close", fn() { @sf.t("common.cancel") }, fn() {
              @sfbase.ups.uploads.retain(fn(x) { x.serial != u.serial })
              if u.state.untracked() == "going" {
                @sfbase.ups.pumping.set(false)
                dv_pump(src)
              }
            })
            |> ignore
          })
        })
        |> ignore
        held.box(fn(first) {
          @sf.style_node(first, fn() { upload_first })
          @sf.icon_node(first, "upload", @signals.untracked(fn() { @sf.theme().items.mark }), By(fn() { @sf.theme().p.muted })) |> ignore
          first.box(fn(n) {
            @sf.style_node(n, fn() { upload_name }, in_row=true)
            @sf.words_node(n, fn() { u.name.get() }, fn() { @sf.theme().items.name.then(file_name_cut) }) |> ignore
          })
          |> ignore
          first.box(fn(beside) {
            @sf.style_node(beside, fn() { upload_beside }, in_row=true)
            beside.laid_nowhere(By(stacked)) |> ignore
            upload_state_node(beside, src, u, part, how_far, replace, false)
          })
          |> ignore
          // (the room its keys take over its end)
          first.box(fn(k) {
            k.shrink(Is(0.0)).width(By(fn() { Some(if failed() { 2.0 * upload_key_side } else { upload_key_side }) })) |> ignore
          })
          |> ignore
        })
        |> ignore
        held.box(fn(under) {
          @sf.style_node(under, fn() { upload_under.then(@ui.style(pl=@sf.room_of(upload_under_in + @sf.theme().items.mark))) })
          under.laid_nowhere(By(fn() { !stacked() })).row(Is(true)).lines_up(Is(Some(Start))) |> ignore
          upload_state_node(under, src, u, part, how_far, replace, true)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// How an upload stands, in `parent` (beside its name, or under it where `under`): how far (its bar and its words),
/// its name taken there (已有同名文件, 替换, 保留两者), or why it failed.
fn upload_state_node(
  parent : @view.View,
  src : Source,
  u : DvUpload,
  part : () -> Double,
  how_far : () -> String,
  replace : () -> Unit,
  under : Bool,
) -> Unit {
  parent.pick(fn() { u.state.get() }, at_once=true, fn(s, state) {
    // (beside its name, no wider than the row leaves it: why it failed cut short there)
    s.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    match state {
      "taken" =>
        s.box(fn(ask) {
          @sf.style_node(ask, fn() { upload_ask_line }, in_row=!under)
          // (under its name, on lines of its own as they come; beside it, on its one line, 已有同名文件 left out
          // before its answers where that line has not the room)
          if under {
            ask.wraps(Is(Some(0.0))) |> ignore
          } else {
            ask.fits(Is(true)) |> ignore
          }
          @sf.words_node(ask, fn() { @sf.t("web-pages.drive.taken") }, fn() {
            if under {
              @sf.theme().items.meta.then(@ui.text_style(wrap=true))
            } else {
              @sf.theme().items.meta
            }
          })
          .shrink(Is(if under { 1.0 } else { 0.0 }))
          .min_width(Is(if under { Some(0.0) } else { None }))
          .drops(Is(upload_drop_note))
          |> ignore
          ask.box(fn(a) {
            @sf.style_node(a, fn() { upload_answers }, in_row=true)
            @sf.button_node(a, fn() { @sf.t("web-pages.drive.replace") }, replace, tone=Ghost) |> ignore
            @sf.button_node(a, fn() { @sf.t("web-pages.drive.keepBoth") }, fn() { @sfbase.dv_keep_both(src, u) }, tone=Ghost) |> ignore
          })
          |> ignore
        })
        |> ignore
      "failed" =>
        @sf.words_node(s, fn() { @sf.t("web-pages.drive.uploadFailed", args=[("error", u.error.get())]) }, fn() {
          @sf.theme().items.meta.then(if under { upload_failed_under } else { upload_failed })
        })
        .cuts(Is(true))
        .min_width(Is(Some(0.0)))
        |> ignore
      _ =>
        s.box(fn(p) {
          @sf.style_node(p, fn() { if under { upload_progress_under } else { progress_cell } }, in_row=!under)
          if under {
            @sf.words_node(p, how_far, fn() { @sf.theme().items.meta }) |> ignore
            @sf.progress_node(p, fn() { if upload_size(u) > 0 { Some(part()) } else { None } }, fn() { @sf.theme().p.line }, fn() {
              @sf.theme().p.accent
            })
            |> ignore
          } else {
            p.box(fn(bar) {
              @sf.style_node(bar, fn() { progress_bar_cell }, in_row=true)
              @sf.progress_node(bar, fn() { Some(part()) }, fn() { @sf.theme().p.line }, fn() { @sf.theme().p.accent }, h=2.0) |> ignore
            })
            |> ignore
            @sf.words_node(p, how_far, fn() { @sf.theme().items.meta }).drops(Is(upload_drop_sent)) |> ignore
          }
        })
        |> ignore
    }
  })
}

///|
fn upload_size(u : DvUpload) -> Int {
  u.bytes.length()
}

///|
/// Nothing in the folder, in `parent`: the head already says it is empty; here is its mark and what can be done
/// (`upload`, where the viewer may put files there).
fn folder_empty_node(parent : @view.View, upload : () -> (() -> Unit)?) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() { folder_empty_box })
    @sf.icon_node(b, "folder", empty_icon, By(fn() { @sf.theme().p.muted })) |> ignore
    b.show(fn() { upload() is Some(_) }, at_once=true, fn(u) {
      @sf.button_node(u, fn() { @sf.t("web-pages.drive.upload") }, fn() {
        match @signals.untracked(upload) {
          Some(up) => up()
          None => ()
        }
      }, icon="upload")
      |> ignore
    })
  })
  |> ignore
}

///|
/// What is held over the folder shown (drop), over all of `parent` while it is: where it goes, in words (`lit`: what a
/// drop there does), round it, square.
fn drop_over_node(parent : @view.View, lit : () -> String?, name : () -> String) -> Unit {
  parent.show(fn() { lit() is Some(_) }, at_once=true, fn(o) {
    o.over(Is(true)).presses(Is(false)) |> ignore
    @sf.style_node(o, fn() { drop_room })
    o.box(fn(b) {
      @sf.style_node(b, fn() { drop_box })
      @sf.icon_node(b, "", folder_drop_icon, By(fn() { @sf.theme().p.text }), name_now=fn() {
        if lit() == Some("upload") { "upload" } else { "move" }
      })
      |> ignore
      @sf.words_node(
        b,
        fn() {
          let key = match lit() {
            Some("copy") => "web-pages.files.copyHere"
            Some("move") => "web-pages.files.moveHere"
            _ => "web-pages.drive.dropHere"
          }
          @sf.t(key, args=[("name", name())])
        },
        fn() { folder_drop_words },
      )
      |> ignore
    })
    |> ignore
  })
}

///|
/// Whether a folder's room `room` across has the preview beside its list: where the page is laid out wide, the list
/// keeping what is left (a narrow page's whole width is its list's).
pub fn pane_fits(room : Double) -> Bool {
  room >= @sf.page_narrow_most
}

///|
/// The empty folder's mark (36), what is dropped's (22).
let empty_icon : Double = 36.0

///|
let folder_drop_icon : Double = 22.0

///|
/// The list and the preview beside it (withPane).
// kept across runs: a value (no field of it changes)
let with_pane : @ui.Style = @ui.css("row w=Full h=Full")

///|
/// The entries (list): rows 2 apart, on the page's ground (no corner of its own: its head's station button and its rows
/// stand in none; what is held over it is rounded itself).
// kept across runs: a value (no field of it changes)
let list_box : @ui.Style = @ui.style(w=@sf.grow, min_w=S56, h=Full, clip=true)

///|
/// The preview and its rule, as tall as the list.
// kept across runs: a value (no field of it changes)
let pane_slot_row : @ui.Style = @ui.css("row h=Full")

///|
/// Its way: the station's button, 8 to the crumbs, which take what is left of the line.
// kept across runs: a value (no field of it changes)
let head_trail : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let head_way : @ui.Style = @ui.style(w=@sf.grow, min_w=S0)

///|
/// Its name (h1): 22, 600.
// kept across runs: a value (no field of it changes)
let head_title : @ui.TextStyle = @ui.text_style(size=Heading, weight=Semibold, color=Fg)

///|
/// Folder error card slots: inset by `px=S3` when inside the wide files shell (matching `rows_head_wide`), flush when
/// inside a framed narrow folder (which already pads `px=S3`).
// kept across runs: a value (no field of it changes)
let folder_err_slot_inset : @ui.Style = @ui.css("w=Full px=S3 pt=S1")

///|
// kept across runs: a value (no field of it changes)
let folder_err_stale_inset : @ui.Style = @ui.css("w=Full px=S3 pb=S2_5")

///|
// kept across runs: a value (no field of it changes)
let folder_err_slot_flush : @ui.Style = @ui.css("w=Full pt=S1")

///|
// kept across runs: a value (no field of it changes)
let folder_err_stale_flush : @ui.Style = @ui.css("w=Full pb=S2_5")

///|
/// Maximum width of a folder error card so prose stays comfortable to scan on wide viewports while filling narrow ones.
let folder_err_max_w : Double = 540.0

///|
// kept across runs: a value (no field of it changes)
let folder_err_card_room : @ui.Style = @ui.style(w=Full, max_w=Fixed(folder_err_max_w))

///|
/// The crumbs: a step 4 round, its ground under the pointer.
// kept across runs: a value (no field of it changes)
let folder_crumb_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let folder_crumb_step : @ui.Style = @ui.css("px=S1 py=S0_5 radius=Lg hovered{bg=Hover}")

///|
// kept across runs: a value (no field of it changes)
let folder_crumb_words : @ui.TextStyle = @ui.text_style(wrap=false)

///|
// kept across runs: a value (no field of it changes)
let folder_crumb_here : @ui.TextStyle = @ui.text_style(weight=Medium, color=Fg, wrap=false)

///|
let folder_crumb_chevron : Double = 12.0

///|
/// What is done to the folder (actions): 6 apart, more where a press's room needs it (@sf.keys_gap).
fn actions_row() -> @ui.Style {
  actions_row_look.then(@ui.style(gap=@sf.keys_gap(least=@sf.tools_apart)))
}

///|
// kept across runs: a value (no field of it changes)
let actions_row_look : @ui.Style = @ui.css("row align=ACenter justify=JEnd")

///|
/// Its first line (its mark, its name cut short, how far beside it where it is not stacked, the room its keys take at
/// its end: 36 high, the row's ground 6 round it), the lines under it (stacked) in from the row's start as far as its name (its mark and the
/// 12 after it), to the row's end (12 in), 8 under the last.
// kept across runs: a value (no field of it changes)
let upload_first : @ui.Style = @ui.css("row w=Full min_h=S9 pl=S3 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let upload_under : @ui.Style = @ui.css("w=Full pr=S3 pb=S2 gap=S1_25")

///|
/// How far in from a row's start its name is past its mark (row_style's 12 in, 12 after the mark).
let upload_under_in : Double = 24.0

///|
/// Its name, never less than a few words (16: 64).
// kept across runs: a value (no field of it changes)
let upload_name : @ui.Style = @ui.style(w=@sf.grow, min_w=S16)

///|
/// What is beside its name, wide: how far, what is asked or why it failed, at its end.
// kept across runs: a value (no field of it changes)
let upload_beside : @ui.Style = @ui.style(row=true, w=@sf.grow, min_w=S0, align=ACenter, justify=JEnd)

///|
// kept across runs: a value (no field of it changes)
let upload_keys : @ui.Style = @ui.css("row w=Full justify=JEnd align=AStart")

///|
/// A key's square over the first line's end (36, in the row's ground's 6: its 32 key 8 in from the row's end and top,
/// concentric with a card's 24 corner).
// kept across runs: a value (no field of it changes)
let upload_key_square : @ui.Style = @ui.css("w=S9 h=S9 align=ACenter justify=JCenter")

///|
let upload_key_side : Double = 36.0

///|
/// What is asked: its words, its answers after it (under it where the line has not the room), 12 apart.
// kept across runs: a value (no field of it changes)
let upload_ask_line : @ui.Style = @ui.css("row gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let upload_answers : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let upload_failed_under : @ui.TextStyle = @ui.text_style(color=Danger, wrap=true, w=Full)

///|
// kept across runs: a value (no field of it changes)
let upload_failed : @ui.TextStyle = @ui.text_style(color=Danger, wrap=false, w=Cut)

///|
/// Going up, under its name: how far, the bar 5 under the words.
// kept across runs: a value (no field of it changes)
let upload_progress_under : @ui.Style = @ui.css("w=Full gap=S1_25")

///|
/// Going up, beside its name: how far it has got (a 2 high bar), its size, as wide as the size and time columns.
// kept across runs: a value (no field of it changes)
let progress_cell : @ui.Style = @ui.style(row=true, w=@sf.grow, max_w=Fixed(progress_w), gap=S2_5, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let progress_bar_cell : @ui.Style = @ui.style(w=@sf.grow, min_w=S12)

///|
/// The size and time columns' (96 and 104 and their gap).
let progress_w : Double = 212.0

///|
/// What leaves an upload's row first, short of room: what its answers are about (已有同名文件).
let upload_drop_note : Int = 1

///|
/// What leaves an upload's bar, short of room: how much has gone up of its size, the bar kept.
let upload_drop_sent : Int = 1

///|
/// Nothing in it (empty): in the middle, 56 by 24 in, 12 apart, muted.
// kept across runs: a value (no field of it changes)
let folder_empty_box : @ui.Style = @ui.css("w=Full pt=S14 pb=S14 px=S6 gap=S3 align=ACenter")

///|
/// What is held over the list (drop): over all of it, its words and mark in the middle, the page's ground at 80% under
/// them, ringed in the accent, 10 in from the list's edges (the ladder's inset).
// kept across runs: a value (no field of it changes)
let drop_box : @ui.Style = @ui.css((
  #|w=Full h=Full gap=S2 align=ACenter justify=JCenter radius=Xl2 bg=A(Bg,O80) border=B2 border_color=A(Accent,O60)
))

///|
// kept across runs: a value (no field of it changes)
let drop_room : @ui.Style = @ui.style(w=Full, h=Full, p=@sf.inset_room)

///|
// kept across runs: a value (no field of it changes)
let folder_drop_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false)
