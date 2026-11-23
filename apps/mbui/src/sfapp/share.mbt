// Sharing.
//
// In: what another app shares into still.fail (Android's share sheet: ACTION_SEND of a link, some text or files,
// ACTION_SEND_MULTIPLE of files, iOS's share extension's as the app next comes to the front, @ui.shared_in;
// MBUI_SHARE_TEXT and MBUI_SHARE_TITLE for scripted runs, the host's MBUI_SHARE_FILES on macOS and iOS) opens one
// sheet: what is shared at its top (its title, the app's subject or its first line; a link's mark or text's), 发到
// the chats it can go to (the core's `shareIn` view: the one a thing from the same site went to last first, saying so;
// 搜索 from six chats), 新 chat last (then which station,
// when there are more). A tap puts what is shared in that chat's composer (`shareIn.open`: a link as a card among its
// files, the words after what is written) and opens the chat there (or a new chat on that station), where it is added
// to and sent. Files (which the Android app does not take in) head the sheet as the composer shows them (pictures as
// tiles, a file's mark, name and size; n 个文件) and go into the chat's composer as attachments, up to the station at once
// as ＋'s files do (composer.mbt add_file); words shared with them go in through `shareIn.open` as before. The sheet
// shows over the app it came from (Android's OverActivity, as the Android app's ShareActivity: the host says so,
// @hostapi.system_channel `over`), on the page's paper: nothing of the app's own under it. Closed, the app goes and the
// person is back where they were; gone into a chat, the app opens at it (@ui.over_done). Signed out, it says to sign in
// in the app first, with 打开 still.fail.
//
// Out: a file of a drive handed to another app: read whole through the core
// (`drive.read`), then the system's share sheet (@hostapi.share: Android's chooser, a file of the app's own provider;
// macOS's sharing picker); 本机没有可打开此文件的应用 when nothing takes it. A chat's picture or file the same from its
// preview on a phone (sfbase viewer.mbt's Viewer::ask_share: its bar, a picture's held menu, a file told of).

///|
fn sh(key : String, args? : Array[(String, String)] = []) -> String {
  fill(key, args)
}

///|
/// A file shared in: its name and bytes; a picture's key once added (`mem:share-in/…`), else "".
#derive(Eq)
priv struct SharedFile {
  name : String
  bytes : Bytes
  image : String
}

///|
/// What is being shared in, and how its sheet stands.
priv struct ShareIn {
  /// its words and the subject the app gave with them
  shared : @signals.Signal[(String, String?)?]
  /// its files
  files : @signals.Signal[Array[SharedFile]]
  /// its sheet raised (it closes by itself: then what is shared is let go)
  raised : @signals.Signal[Bool]
  env_taken : @signals.Signal[Bool]
  searching : @signals.Signal[Bool]
  choosing : @signals.Signal[Bool]
  /// the row being opened (its station, its id; "" a new chat)
  opening : @signals.Signal[(String, String)?]
  error : @signals.Signal[String]
  /// what is typed to find a chat (its field's words, last frame)
  query : @signals.Signal[String]
  /// the words searched for (its field shows them)
  find : @ui.Field
}

///|
let share_in : ShareIn = {
  shared: @signals.signal(None),
  files: @signals.signal([]),
  raised: @signals.signal(false, same=fn(a, b) { a == b }),
  env_taken: @signals.signal(false, same=fn(a, b) { a == b }),
  searching: @signals.signal(false, same=fn(a, b) { a == b }),
  choosing: @signals.signal(false, same=fn(a, b) { a == b }),
  opening: @signals.signal(None),
  error: @signals.signal("", same=fn(a, b) { a == b }),
  query: @signals.signal("", same=fn(a, b) { a == b }),
  find: @ui.Field::new(),
}

///|
/// Whether what is shared fills the window rather than a sheet: over another app in a browser, its window the browser
/// extension's own (web/src/mbui/share.ts), with nothing of another app under it.
fn share_inline() -> Bool {
  share_over.get() && @ui.platform() == 4
}

///|
/// That window: what a sheet holds, a sheet's 20 in, room over it as a sheet has under its grip.
// kept across runs: a value (no field of it changes)
let share_window : @ui.Style = @ui.css("w=Full h=Full px=S5 pt=S6 bg=Bg")

///|
/// Over another app, its sheet closed by hand: the app goes once it has sunk away (ShareScreen: onClose after its spring).
let share_closing : Ref[Bool] = Ref(false)

///|
/// Its sheet closed (by hand, or a chat picked): what it shows kept as it was while it sinks away, let go of once it has
/// gone (share_in_frame).
let share_sinking : Ref[Bool] = Ref(false)

///|
/// 打开 still.fail, as a link's words (semibold, the link's ink).
// kept across runs: a value (no field of it changes)
let open_app_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Semibold, color=Link)

///|
// kept across runs: a value (no field of it changes)
let open_app_box : @ui.Style = @ui.css("px=S5 py=S2 pb=S6")

///|
/// Over another app (ShareActivity), after the old frame's old views (view_in, which took what is shared before them:
/// share_in_frame): its sheet over that app and nothing else (the window's tree draws it: share_sheet_node); the toasts.
fn over_view(c : @ui.Ctx, src : Source) -> Unit {
  ignore(src)
  // a browser's window of its own (the extension's): nothing under the sheet to show, so what it holds is the window's
  // (over_tree's share_window)
  if share_inline() {
    return
  }
  // (nothing of the app's under it: on the page's paper)
  @sf.presented(c, alone=true)
}

///|
// kept across runs: a value (no field of it changes)
let share_reading_box : @ui.Style = @ui.css("w=Full px=S5 pt=S2")

///|
/// From six chats the list can be searched.
let searched_from : Int = 6

///|
/// Each frame once signed in: what another app shared since, its sheet raised; let go once its sheet closed.
fn share_in_frame(c : @ui.Ctx) -> Unit {
  // (what the host says was shared, taken once: the same whichever build takes it)
  if share_in.shared.get() is None {
    let said = @ui.shared_in()
    let mut got : (String, String?)? = None
    let files : Array[SharedFile] = []
    if said != "" {
      let v = try Some(@json.parse(said)) catch { _ => None }
      let title = text(v, "title")
      got = Some((text(v, "text"), if title == "" { None } else { Some(title) }))
      for i, f in items(v, "files") {
        let bytes = @ui.shared_in_file(i)
        if bytes.length() == 0 {
          continue
        }
        let name = text(Some(f), "name")
        let image = match @pixels.image_size(bytes) {
          Some(_) => {
            share_files_made.val += 1
            let key = "mem:share-in/\{share_files_made.val}"
            @ui.add_image(key, bytes)
            key
          }
          None => ""
        }
        files.push({ name, bytes, image })
      }
      // (the host's words are these: the scripted run's are not taken again)
      share_in.env_taken.set(true)
    } else if !share_in.env_taken.get() {
      share_in.env_taken.set(true)
      let words = @ui.env("MBUI_SHARE_TEXT")
      if words != "" {
        let title = @ui.env("MBUI_SHARE_TITLE")

        got = Some((words, if title == "" { None } else { Some(title) }))
      }
    }
    match got {
      Some((words, title)) if words.trim() != "" || files.length() > 0 => {
        @hostapi.log("share in: \{words.length()} characters, \{files.length()} files")
        share_in.shared.set(Some((words, title)))
        share_in.files.set(files)
        share_in.raised.set(false)
        share_in.searching.set(false)
        share_in.choosing.set(false)
        share_in.opening.set(None)
        share_in.error.set("")
        c.blur()
      }
      _ => ()
    }
  } else if share_in.raised.get() && sheet_host.kind != ShareSheet && !share_inline() {
    // closed (the scrim, back, dragged down): what it shows kept as it was while it sinks away, let go of once it has
    // (below); over another app, the app goes then
    share_in.raised.set(false)
    share_sinking.val = true
    if share_over.get() {
      share_closing.val = true
    }
  }
  // put up once shared: the library's panel (a sheet on 小屏, a dialog in the middle of the window on 中屏 and 大屏, as
  // the presenters have it, the window going from one to the other); filling the window the browser extension opened
  // (up before its nodes are made: what they read, the core's shareIn, read as they are made, waited for as it opens:
  // OpenGate)
  if share_in.shared.get() is Some(_) && !share_in.raised.get() && !share_sinking.val {
    share_in.raised.set(true)
    if !share_inline() {
      raise_sheet(ShareSheet)
    }
  }
  if share_sinking.val && !@sf.presented_drawn() {
    share_sinking.val = false
    share_in.shared.set(None)
    share_in.files.set([])
  }
  if share_closing.val && share_over.get() && !@sf.presented_drawn() {
    share_closing.val = false
    @ui.over_done(open_app=false)
  }
}

///|
/// How the body is laid out: a phone's sheet (its PickRows) or the wide frame's panel
/// .
priv struct ShareLook {
  wide : Bool
  /// how far its words stand in from the body's sides
  side : Double
  /// the mark column's width, and the marks in it (what is shared, a row's picture)
  col : Double
  icon : Double
  /// between a mark and its words
  gap : Double
  /// what is shared: room over and under it, its words' room over them, its title's and its words' lines
  head_pt : Double
  head_pb : Double
  head_words_pt : Double
  title_line : Double
  source_line : Double
  /// 发到 (and 新 chat 开在): room over and under it
  label_pt : Double
  label_pb : Double
  /// under the list
  list_pb : Double
  /// a row: its least height, how far in its words stand, its corner, its title's line, between its title and line
  row_h : Double
  row_padx : Double
  row_pady : Double
  row_corner : Double
  row_line : Double
  row_gap : Double
  /// a chat's model mark
  model : Double
  /// the whole width, its words `side` in
  inset : @ui.Style
  /// files shared: how far in their tiles and words stand (a tile's corner concentric in the panel's at the wide one)
  files_in : Double
  /// room over the pictures shared, and a picture's tile's corner: concentric in what holds it (the wide panel's, 20
  /// in: one of the ladder's)
  files_top : Double
  tile_corner : Double
}

///|
// kept across runs: a value (no field of it changes)
let share_whole : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let share_cut : @ui.Style = @ui.css("w=Full clip")

///|
/// 找 chat under 发到; 正在读取 where the rows will be; what went wrong.
// kept across runs: a value (no field of it changes)
let share_find_room : @ui.Style = @ui.css("pt=S1_5 pb=S1")

///|
let share_wait_spin : Double = 14.0

///|
// kept across runs: a value (no field of it changes)
let share_wait_room : @ui.Style = @ui.css("pt=S2")

///|
// kept across runs: a value (no field of it changes)
let share_error_room : @ui.Style = @ui.css("pb=S4")

///|
/// (the sheet's own 20 in is where its words and its rows' marks stand: the web's 20, its PickRows 12 + 8)
// kept across runs: a value (no field of it changes)
let share_narrow : ShareLook = {
  wide: false,
  side: 0.0,
  col: 36.0,
  icon: 20.0,
  gap: 12.0,
  head_pt: 2.0,
  head_pb: 10.0,
  head_words_pt: 1.0,
  title_line: 22.0,
  source_line: 17.0,
  label_pt: 6.0,
  label_pb: 2.0,
  list_pb: 16.0,
  row_h: 46.0,
  row_padx: 0.0,
  row_pady: 12.0,
  row_corner: 0.0,
  row_line: 21.0,
  row_gap: 0.0,
  model: 36.0,
  inset: @ui.css("w=Full"),
  files_in: 0.0,
  // (in the sheet's top left corner, as far from its top as from its side (the sheet's words' 24, the grabber's room
  // over it a point more), concentric with it there: the ladder's row corner)
  files_top: @sf.panel_words - @sf.sheet_grab_h,
  tile_corner: @sf.row_corner,
}

///|
/// (the panel's own 12 in, then a row's 12 more: a dialog's 24)
// kept across runs: a value (no field of it changes)
let share_wide_look : ShareLook = {
  wide: true,
  side: 12.0,
  col: 20.0,
  icon: 16.0,
  gap: 10.0,
  head_pt: 12.0,
  head_pb: 6.0,
  head_words_pt: 0.0,
  title_line: 20.0,
  source_line: 18.0,
  label_pt: 10.0,
  label_pb: 4.0,
  list_pb: 0.0,
  row_h: 38.0,
  row_padx: 12.0,
  row_pady: 8.0,
  row_corner: share_row_corner,
  row_line: 20.0,
  row_gap: 2.0,
  model: 18.0,
  inset: @ui.css("w=Full px=S3"),
  // (in the panel's top left corner on its words' line, as far from its top, concentric with it there: the ladder's
  // row corner)
  files_in: @sf.panel_words - 12.0,
  files_top: @sf.panel_words - 12.0,
  tile_corner: @sf.row_corner,
}

///|
/// What is shared put in the chat's composer (`shareIn.open`, of workspace `scope`; a new chat's on `station` with no
/// `id`), then that chat
/// opened (or a new chat rising), its draft read anew.
fn share_open(
  src : Source,
  scope : String,
  station : String,
  id : String?,
  session? : String = "",
) -> Unit {
  let (source, title) = match share_in.shared.get() {
    Some(s) => s
    None => return
  }
  if share_in.opening.get() is Some(_) {
    return
  }
  let files = share_in.files.get()
  // files alone: nothing for the core to put in the composer; the chat (or a new chat on that station) opened with
  // them going up from its composer
  if source.trim() == "" {
    share_opened(station, match id {
      Some(x) => if session != "" { session } else { x }
      None => ""
    }, "", files, fn() {
      match id {
        // (the station by its own id, the address's last part, as the core's shareIn.open picks it)
        None => {
          let parts = station.split("/").to_array()
          pick_new(src, scope, { "station": Json::string(parts[parts.length() - 1].to_owned()) })
        }
        Some(_) => ()
      }
    })
    return
  }
  share_in.opening.set(Some((station, id.unwrap_or(""))))
  share_in.error.set("")
  let params : Map[String, Json] = {
    "scope": Json::string(scope),
    "source": Json::string(source),
    "station": Json::string(station),
  }
  match id {
    Some(x) => params["id"] = Json::string(x)
    None => ()
  }
  match title {
    Some(x) => params["title"] = Json::string(x)
    None => ()
  }
  (src.call)("shareIn.open", Json::object(params), fn(r) {
    share_in.opening.set(None)
    match r {
      Ok(a) => {
        let key = text(Some(a), "key")
        share_opened(station, text(Some(a), "session"), text(Some(a), "title"), files, fn() {  }, key~)
      }
      Err(e) => share_in.error.set(sh("android-misc.shareIn.failed", args=[("error", text(Some(e), "message"))]))
    }
  })
}

///|
/// What is shared gone into a chat's composer (`session`; "" the workspace's new chat, `station` made the one it starts
/// on by `pick`): the sheet let go, the chat opened (a new chat rising), the files handed to its composer, which puts
/// them up.
fn share_opened(
  station : String,
  session : String,
  title : String,
  files : Array[SharedFile],
  pick : () -> Unit,
  key? : String,
) -> Unit {
  let key = match key {
    Some(k) => k
    None => if session == "" { "new:" + @sfbase.workspace_of(station) } else { station + ":" + session }
  }
  if files.length() > 0 {
    @sfbase.draft_give(key, Shared(files.map(fn(f) { { name: f.name, bytes: f.bytes, held: 0, size: f.bytes.length().to_double(), src: "" } })))
  }
  // (what the sheet shows kept as it was while it sinks away, let go of once it has: share_in_frame)
  share_in.raised.set(false)
  share_sinking.val = true
  lower_sheet()
  @hostapi.log("share in: into \{key}, \{files.length()} files")
  @sfbase.history_push()
  // over another app: the app opens at the chat (ShareActivity openApp: MainActivity's openItem, over Home); a
  // browser's window the extension shares from has the chat open in the browser's still.fail tab, and goes
  // (web/src/mbui/share.ts)
  if share_over.get() {
    if @ui.platform() == 4 {
      let link = if session == "" { "" } else { chat_link(station, session) }
      @ui.open_url(if link == "" { @sfbase.link_origin() } else { link }) |> ignore
      return
    }
    home()
    @ui.over_done(open_app=true)
  }
  if session == "" {
    pick()
    while app.nav.depth() > 1 {
      if !app.nav.pop() {
        break
      }
    }
    open_page(NewChat)
  } else {
    // (as any chat is opened: the one page of it, its composer once)
    open_chat({ station, session, title, station_name: "" })
  }
}

///|
/// How many pictures shared in have been added as images (their keys' numbers).
let share_files_made : Ref[Int] = { val: 0 }

///|
/// A wide row's corner, and what lies in the panel's corners: concentric 12 in, the panel's own then a pane's (34, one of
/// the ladder's).
let share_row_corner : Double = @ui.concentric(@sf.pane_corner, 12.0)

///|
/// The sheet of what is shared (ShareSheet's body, as nodes of the window's tree made once in `v`), as `src` says it now:
/// over another app (share_over), the chats once the core says them, of the workspace the app was last in (else the
/// first), reading meanwhile, signed out to sign in first (SignInFirst); in the app, the workspace in view's. A sheet's
/// look on 小屏, the wide panel's on 中屏 and 大屏 (share_look_of).
fn share_sheet_node(v : @view.View, src : Source) -> Unit {
  let look = share_look_of(v)
  // (which workspace's chats it offers: None while that is read; "" signed out)
  let scope = fn() -> String? {
    if !share_over.get() {
      return workspace_in_view(src).0.map(fn(w) { w.id })
    }
    match src.topic("accounts", {}).get().value {
      Some(Array(list)) if list.length() == 0 => Some("")
      Some(Array(_)) => {
        let (all, answered, _) = workspaces_of(src.topic("workspaces", {}).get().value)
        let kept = text(src.topic("prefs", {}).get().value, "workspace")
        match all.iter().find_first(fn(w) { w.id == kept }) {
          Some(w) => Some(w.id)
          None if all.length() > 0 && (kept == "" || answered) => Some(all[0].id)
          _ => None
        }
      }
      _ => None
    }
  }
  v.box(fn(col) {
    // (a sheet's on its words' line, as the old sheet's body stood: its words and its rows' marks 20 in)
    @sf.style_node(col, fn() { if look.wide { share_whole } else { share_whole.then(@sf.panel_words_in_node(col)) } })
    col.pick(fn() { (share_in.shared.get() is Some(_), scope()) }, fn(p, said) {
      guard said.0 else { return }
      match said.1 {
        Some("") => {
          shared_head_node(p, None, look)
          share_note_node(p, fn() { sh("android-misc.shareIn.signIn") }, look)
          p.box(fn(b) {
            @sf.style_node(b, fn() { open_app_box })
            @sf.presses_node(b, fn() { @ui.over_done(open_app=true) })
            b.says(Is(Some(@view.said(Link, label=sh("android-misc.shareIn.openApp"))))) |> ignore
            @sf.words_node(b, fn() { sh("android-misc.shareIn.openApp") }, fn() { open_app_words }) |> ignore
          })
          |> ignore
        }
        Some(scope) => share_parts_node(p, src, scope, look)
        None => {
          shared_head_node(p, None, look)
          p.box(fn(b) {
            @sf.style_node(b, fn() { share_reading_box })
            @sf.wait_line_node(b, fn() { sh("common.reading") }) |> ignore
          })
          |> ignore
        }
      }
    })
  })
  |> ignore
}

///|
/// One of the rows of what is shared's list (share_parts_node's): words in the rows' place (what to do first, none
/// found), a chat it can go to (its station and id), 新建对话 on a station.
#derive(Eq, Hash)
priv enum ShareRow {
  ShareNote(String)
  ShareChat(String, String)
  ShareNew(String)
}

///|
/// What is shared, 发到 (搜索 from six), the chats it can go to, 新 chat (then the stations, with several), in `look`,
/// as the core's `shareIn` for workspace `scope` says them now (in `v`).
fn share_parts_node(v : @view.View, src : Source, scope : String, look : ShareLook) -> Unit {
  let topic = fn() {
    let query = share_in.query.get()
    let (source, _) = share_in.shared.get().unwrap_or(("", None))
    src.topic("shareIn", {
      "scope": Json::string(scope),
      "source": Json::string(source),
      "query": Json::string(if share_in.searching.get() { query.trim().to_owned() } else { "" }),
    }).get()
  }
  // (once a chat is picked, what it shows kept as it was while it sinks away: what the core says of it after, the chat
  // it went to now its last, not followed; once said, never back to reading)
  let last : Ref[Json?] = Ref(None)
  let value_cell = @signals.computed(fn(_) {
    if share_in.opening.get() is Some(_) || !share_in.raised.get() {
      return last.val
    }
    // (and once said, kept while it is asked anew: a search's words, what is shared another time)
    match topic().value {
      Some(_) as v => {
        last.val = v
        v
      }
      None => last.val
    }
  })
  let value = fn() { value_cell.get() }
  let rows = fn() { items(value(), "items") }
  shared_head_node(v, Some(fn() { text(value(), "site") }), look)
  // 发到, and at its end 搜索 (取消 while searching)
  v.box(fn(line) {
    @sf.style_node(line, fn() {
      share_label_line.then(@ui.style(px=@sf.room_of(look.side), pt=@sf.room_of(look.label_pt), pb=@sf.room_of(look.label_pb)))
    })
    line.box(fn(w) {
      @sf.style_node(w, fn() { share_whole }, in_row=true)
      @sf.words_node(w, fn() { sh("android-misc.shareIn.to") }, fn() { share_label_words }) |> ignore
    })
    |> ignore
    line.show(at_once=true, fn() { share_in.searching.get() || rows().length() >= searched_from }, fn(k) {
      let words = fn() { if share_in.searching.get() { sh("common.cancel") } else { sh("android-misc.shareIn.search") } }
      @sf.action_box_node(k, words, fn(_) {
        let on = !share_in.searching.untracked()
        share_in.searching.set(on)
        if !on {
          share_in.query.set("")
          share_in.find.set("")
        }
      }, fn(b) {
        @sf.words_node(b, words, fn() { if @sf.lit_node(b) { share_search_lit } else { share_search_words } }) |> ignore
      })
      |> ignore
    })
  })
  |> ignore
  v.show(at_once=true, fn() { share_in.searching.get() }, fn(f) {
    @sf.style_node(f, fn() { look.inset.then(share_find_room) })
    @sf.input_node(f, share_in.find, placeholder=sh("android-misc.shareIn.find"), edited=fn(words) { share_in.query.set(words) })
    |> ignore
  })
  let searching = fn() { share_in.searching.get() && share_in.query.get().trim() != "" }
  // (its rows by what each is: the list made again only as they come or go, what each shows read by its key)
  let keys = @signals.computed(
    fn(_) {
      let v = value()
      let out : Array[ShareRow] = []
      guard v is Some(_) else { return out }
      match text(v, "note") {
        "" => ()
        n => out.push(ShareNote(n))
      }
      for item in items(v, "items") {
        out.push(ShareChat(text(Some(item), "station"), text(Some(item), "id")))
      }
      if items(v, "items").length() == 0 && searching() {
        out.push(ShareNote(sh("android-chat.ref.none.match")))
      }
      // 新建对话: on the station new chats start on, which its page lets be changed as any new chat's does
      let stations = items(v, "stations")
      let new_on = text(v, "newOn")
      let on = match stations.iter().find_first(fn(s) { text(Some(s), "station") == new_on }) {
        Some(s) => Some(s)
        None => stations.get(0)
      }
      match on {
        Some(s) if !searching() => out.push(ShareNew(text(Some(s), "station")))
        _ => ()
      }
      out
    },
  )
  // (its rows one under another, each made by what it is: a few, the panel scrolling them where it is short of room,
  // as the old sheet's column did)
  // (read meanwhile, its line in the rows' place till the core says them; the rows then coming to their height from
  // its, one way, the sheet going with them: never a step while it still rises)
  swap_part_node(v, fn() { value() is Some(_) }, fn(w) {
    @sf.style_node(w, fn() { look.inset.then(share_wait_room) })
    // (what failed said; read meanwhile, a spinner alone, its words said only to a screen reader: what is shared comes
    // in a moment, nothing of it a line of words that goes again at once)
    w.pick(fn() { topic().error is Some(_) }, fn(p, failed) {
      if failed {
        @sf.wait_line_node(p, fn() { sh("android-misc.shareIn.update") }) |> ignore
      } else {
        @sf.spinner_node(p, size=share_wait_spin).says(Is(Some(@view.said(Status, label=sh("common.reading"))))) |> ignore
      }
    })
  }, fn(list) {
    @sf.style_node(list, fn() { share_whole })
    // (its chats by station and id once: each row reads its own, told only as that one changes)
    let by_chat = list.keyed_by(rows, fn(i) { (text(Some(i), "station"), text(Some(i), "id")) })
    list.each(fn() { keys.get() }, fn(k) { k }, fn(b, k) {
      let row = @signals.untracked(fn() { k.get() })
      match row {
        ShareNote(words) => share_note_node(b, fn() { words }, look)
        ShareChat(station, id) => {
          let it = fn() { by_chat.get((station, id)) }
          // (its session as it is now, kept for its press by what reads it: never read outside a reader)
          let session = Ref("")
          b.reacts(fn() { text(it(), "session") }, fn(x) { session.val = x })
          let sub = fn() {
            let kept = field(value(), "kept")
            let (source, _) = share_in.shared.get().unwrap_or(("", None))
            // (where things of a site went last: files have no site)
            if text(kept, "station") == station && text(kept, "id") == id && source.trim() != "" {
              text(kept, "text")
            } else {
              text(field(it(), "last"), "preview")
            }
          }
          share_row_node(
            b,
            look,
            fn() { text(it(), "title") },
            sub,
            fn() { if look.wide { text(field(field(it(), "time"), "lastActiveAt"), "ago") } else { "" } },
            fn() { share_in.opening.get() == Some((station, id)) },
            fn(m) {
              let agent = fn() { items(it(), "agents").get(0) }
              m.pick(fn() { agent().map(fn(a) { (text(field(Some(a), "maker"), "id"), text(Some(a), "runtime")) }) }, fn(k, made) {
                match made {
                  Some((maker, runtime)) =>
                    if look.wide {
                      @sf.maker_mark_node(k, maker, runtime, look.model) |> ignore
                    } else {
                      model_mark_big_node(k, fn() { maker }, fn() { runtime }, look.model, fn() { "" })
                    }
                  // (no agent yet: still.fail's mark wide, the phone's 新建对话 mark)
                  None if look.wide => share_app_mark_node(k)
                  None => @sf.icon_node(k, "compose", look.icon, By(fn() { @sf.theme().p.muted })) |> ignore
                }
              })
            },
            fn() { share_open(src, scope, station, Some(id), session=session.val) },
          )
        }
        ShareNew(station) =>
          share_row_node(
            b,
            look,
            fn() { sh("web-main.sidebar.newChat") },
            fn() { "" },
            fn() { "" },
            fn() { share_in.opening.get() == Some((station, "")) },
            fn(m) { @sf.icon_node(m, "compose", look.icon, By(fn() { @sf.theme().p.muted })) |> ignore },
            fn() { share_open(src, scope, station, None) },
          )
      }
    })
  })
  v.box(fn(f) { f.height(Is(Some(look.list_pb))) |> ignore }) |> ignore
  v.show(at_once=true, fn() { share_in.error.get() != "" }, fn(e) {
    @sf.style_node(e, fn() { look.inset.then(share_error_room) })
    @sf.words_node(e, fn() { share_in.error.get() }, fn() { share_error_words }) |> ignore
  })
}

///|
/// still.fail's mark (a row with no agent yet, in the wide panel), in the theme's light or dark.
fn share_app_mark_node(k : @view.View) -> Unit {
  k.pick(fn() { @sf.theme().dark }, fn(m, dark) {
    @sf.drawable_node(m, if dark { "stillfail_mark_dark" } else { "stillfail_mark" }, share_app_mark) |> ignore
  })
}

///|
let share_app_mark : Double = 16.0

///|
/// 发到 and 搜索 on a line, on their middle; 13, muted, 搜索 in the ink under the hand.
// kept across runs: a value (no field of it changes)
let share_label_line : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let share_label_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let share_search_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let share_search_lit : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let share_error_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger)

///|
/// What is shared at the sheet's top (shared_head's and shared_files_head's, as nodes) in `v`, as `share_in` has it
/// now: its files where there are any, else a mark of what it is (a link, some text), its title (the app's subject,
/// else `site`, the link's site the core says) over what it is.
fn shared_head_node(v : @view.View, site : (() -> String)?, look : ShareLook) -> Unit {
  v.pick(
    fn() {
      let (source, title) = share_in.shared.get().unwrap_or(("", None))
      let files = share_in.files.get().map(fn(f) { (f.name, f.image, f.bytes.length()) })
      let head = match (title, site) {
        (Some(_), _) | (_, None) => title
        (None, Some(s)) => if s() == "" { None } else { Some(s()) }
      }
      (source, title, head, files)
    },
    fn(h, said) {
      let (source, title, head, files) = said
      // (files: the app's subject alone over them, the link's site none of theirs)
      if files.length() > 0 {
        shared_files_head_node(h, @signals.untracked(fn() { share_in.files.get() }), source, title, look)
      } else {
        shared_words_head_node(h, source, head, look)
      }
    },
  )
}

///|
/// What is shared when it is words (shared_head's, as nodes) in `h`: a mark of what it is (a link, some text), its
/// title over what it is, two lines of it cut short (three, in the text's ink, when it is all there is).
fn shared_words_head_node(h : @view.View, source : String, head : String?, look : ShareLook) -> Unit {
  let link = source.to_lower().contains("http://") || source.to_lower().contains("https://")
  let alone = head is None
  // (the title said once: what follows it in the words shared under it, a phone's app having put it first)
  let source = match head {
    Some(t) if source.trim().has_prefix(t) && source.trim().length() > t.length() =>
      source.trim().exact_view(start=t.length()).to_owned().trim().to_owned()
    _ => source
  }
  h.box(fn(row) {
    @sf.style_node(row, fn() {
      share_head_row.then(
        @ui.style(
          pl=@sf.room_of(look.side),
          pr=@sf.room_of(look.side),
          pt=@sf.room_of(look.head_pt),
          pb=@sf.room_of(look.head_pb),
          gap=@sf.room_of(look.gap),
        ),
      )
    })
    // (its mark on the first line of its words, whichever it is: its title's, what is shared alone's, its link's; as far
    // down as that line, as tall as it at the system's size of words, never on the middle of all its lines)
    let (first_top, first_line) = match head {
      Some(_) => (look.head_words_pt, look.title_line)
      None if alone =>
        (
          look.head_words_pt + (if look.wide { 0.0 } else { share_alone_over }),
          @ui.tree_theme().leading(L5).unwrap_or(look.title_line),
        )
      None => (look.head_words_pt, look.source_line)
    }
    row.box(fn(m) {
      m
      .width(Is(Some(look.col)))
      .margin(Is((0.0, first_top, 0.0, 0.0)))
      .height(By(fn() { Some(first_line * m.words_scale()) }))
      .shrink(Is(0.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      @sf.icon_node(m, if link { "web" } else { "text" }, look.icon, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
    row.box(fn(w) {
      @sf.style_node(w, fn() { share_whole.then(@ui.style(gap=@sf.room_of(share_wide_look.row_gap), pt=@sf.room_of(look.head_words_pt))) }, in_row=true)
      match head {
        Some(t) =>
          job_runs_node(w, fn() { [@ui.span(t)] }, fn() {
            job_words(if look.wide { @sf.theme().t.ui } else { @sf.theme().t.body }, weight=600, wrap=false, line=look.title_line)
          }, fn() { @sf.theme().p.text })
        None => ()
      }
      if alone {
        w.box(fn(b) {
          @sf.style_node(b, fn() { if look.wide { share_whole } else { share_alone_box } })
          @sf.words_node(b, fn() { source }, fn() { share_alone_words }) |> ignore
        })
        |> ignore
      } else {
        // (a link one line, cut short: it breaks nowhere)
        job_runs_node(w, fn() { [@ui.span(source)] }, fn() {
          job_words(if look.wide { @sf.theme().t.meta } else { @sf.theme().t.caption }, wrap=false, line=look.source_line)
        }, fn() { @sf.theme().p.muted })
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// What is shared at the top: its mark and words in a row on their tops; words alone 7 under, 15 on lines of 20, three
/// at most.
// kept across runs: a value (no field of it changes)
let share_head_row : @ui.Style = @ui.css("row w=Full align=AStart")

///|
let share_alone_over : Double = 7.0

///|
// kept across runs: a value (no field of it changes)
let share_alone_box : @ui.Style = share_whole.then(@ui.style(pt=@sf.room_of(share_alone_over)))

///|
// kept across runs: a value (no field of it changes)
let share_alone_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, leading=L5, max_lines=3)

///|
/// What is shared when it is files (shared_files_head's, as nodes) in `h`: their pictures as 56 tiles, then a file's
/// mark with its name bold (n 个文件 for several) and under it its size (their names), the words shared with them, when
/// any, under that.
fn shared_files_head_node(h : @view.View, files : Array[SharedFile], words : String, title : String?, look : ShareLook) -> Unit {
  let pictures = files.filter(fn(f) { f.image != "" })
  if pictures.length() > 0 {
    h.box(fn(row) {
      @sf.style_node(row, fn() {
        share_tiles.then(@ui.style(pl=@sf.room_of(look.files_in), pr=@sf.room_of(look.files_in), mt=@sf.room_of(look.files_top)))
      })
      for f in pictures {
        row.box(fn(t) {
          t
          .width(Is(Some(share_tile)))
          .height(Is(Some(share_tile)))
          .shrink(Is(0.0))
          .radius(Is(look.tile_corner))
          .clips(Is(true))
          .ground(By(fn() { @sf.theme().p.chip }))
          .image(Is(Some((f.image, "", share_tile_px))))
          |> ignore
        })
        |> ignore
      }
    })
    |> ignore
  }
  let one = files.length() == 1
  let mut size = 0
  for f in files {
    size += f.bytes.length()
  }
  let head = if one { files[0].name } else { sh("android-settings.files.count", args=[("n", "\{files.length()}")]) }
  let under = if one { @sf.file_size(size.to_double()) } else { files.map(fn(f) { f.name }).join(tr("web-main.list.separator")) }
  let said = match title {
    Some(x) => x
    None => words.trim().to_owned()
  }
  h.box(fn(row) {
    @sf.style_node(row, fn() { share_files_row.then(@ui.style(pl=@sf.room_of(look.side), pr=@sf.room_of(look.side))) })
    row.box(fn(m) {
      @sf.style_node(m, fn() { share_files_mark })
      @sf.icon_node(m, if pictures.length() == files.length() { "photo" } else { "file" }, share_files_icon, By(fn() {
        @sf.theme().p.muted
      }))
      |> ignore
    })
    |> ignore
    row.box(fn(w) {
      @sf.style_node(w, fn() { share_whole }, in_row=true)
      job_runs_node(w, fn() { [@ui.span(head)] }, fn() { job_words(@sf.theme().t.title, weight=700, wrap=false, line=share_files_title_line) }, fn() {
        @sf.theme().p.text
      })
      job_runs_node(w, fn() { [@ui.span(under)] }, fn() { job_words(@sf.theme().t.meta, wrap=false) }, fn() { @sf.theme().p.muted })
      if said != "" {
        job_runs_node(w, fn() { [@ui.span(said)] }, fn() { job_words(@sf.theme().t.meta, wrap=false) }, fn() { @sf.theme().p.muted })
      }
    })
    |> ignore
  })
  |> ignore
}

///|
/// The pictures shared: 56 tiles 8 apart, 8 under them, cut where the line ends; their name's row: 4 over, 2 under, the
/// mark (16, 3 down) and words 12 apart; its title on a line of 24.
// kept across runs: a value (no field of it changes)
let share_tiles : @ui.Style = @ui.css("row w=Full pb=S2 gap=S2 clip")

///|
let share_tile : Double = 56.0

///|
let share_tile_px : Int = 512

///|
// kept across runs: a value (no field of it changes)
let share_files_row : @ui.Style = @ui.css("row w=Full pt=S1 pb=S0_5 gap=S3")

///|
let share_files_mark_top : Double = 3.0

///|
// kept across runs: a value (no field of it changes)
let share_files_mark : @ui.Style = @ui.css("w=S4 align=ACenter").then(@ui.style(pt=@sf.room_of(share_files_mark_top)))

///|
let share_files_icon : Double = 16.0

///|
let share_files_title_line : Double = 24.0

///|
/// A line in the rows' place (share_note's, as a node) in `v`: why there are none, or what to do first.
fn share_note_node(v : @view.View, words : () -> String, look : ShareLook) -> Unit {
  v.box(fn(b) {
    @sf.style_node(b, fn() { share_note_box.then(@ui.style(px=@sf.room_of(look.side))) })
    @sf.words_node(b, words, fn() { if look.wide { share_note_wide } else { share_note_narrow } }) |> ignore
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let share_note_box : @ui.Style = @ui.css("w=Full py=S2")

///|
// kept across runs: a value (no field of it changes)
let share_note_wide : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let share_note_narrow : @ui.TextStyle = @ui.text_style(size=Meta, color=Subtle)

///|
/// A row (share_row's, as a node) in `b`: on a phone a PickRow (its mark a model's tile, rippling under a finger), in the
/// wide panel ⌘K's (lit under the pointer, `meta` at its end); `lead` its mark in its column, its title, a line under
/// it, a spinner while it opens (`busy`); faint and taking no press while another opens. Pressed, `press`.
fn share_row_node(
  b : @view.View,
  look : ShareLook,
  title : () -> String,
  sub : () -> String,
  meta : () -> String,
  busy : () -> Bool,
  lead : (@view.View) -> Unit,
  press : () -> Unit,
) -> Unit {
  let enabled = fn() { share_in.opening.get() is None }
  @sf.action_box_node(b, title, fn(_) { if enabled() { press() } }, disabled=fn() { !enabled() }, fn(r) {
    @sf.style_node(r, fn() {
      (if look.wide { share_row_look_wide } else { share_row_look }).then(
        @ui.style(
          min_h=Fixed(look.row_h),
          px=@sf.room_of(look.row_padx),
          py=@sf.room_of(look.row_pady),
          gap=@sf.room_of(look.gap),
        ),
      )
    })
    r
    .radius(Is(look.row_corner))
    .alpha(By(fn() { if enabled() || busy() { 1.0 } else { share_row_faint } }))
    |> ignore
    // (wide, lit under the pointer; narrow, a finger's press rippling over it: what it is to the hand, the keyboard and
    // a screen reader the button's, said after this look)
    if look.wide {
      @sf.hover_ground_node(r, on=enabled)
    } else {
      @sf.rippled_node(r, fn() { if enabled() { press() } }, look.row_corner, title)
    }
    r.box(fn(m) {
      m.width(Is(Some(look.col))).shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
      // (wide, its mark on its title's line, not on the middle of its two: the rows' tops lined up)
      if look.wide {
        m.height(By(fn() { Some(look.row_line * m.words_scale()) })) |> ignore
      }
      lead(m)
    })
    |> ignore
    r.box(fn(w) {
      @sf.style_node(w, fn() { share_cut.then(@ui.style(gap=@sf.room_of(look.row_gap))) }, in_row=true)
      job_runs_node(w, fn() { [@ui.span(title())] }, fn() { job_words(@sf.theme().t.ui, wrap=false, line=look.row_line) }, fn() {
        @sf.theme().p.text
      })
      w.show(at_once=true, fn() { sub() != "" }, fn(s) {
        job_runs_node(s, fn() { [@ui.span(sub())] }, fn() { job_words(@sf.theme().t.meta, wrap=false, line=share_sub_line) }, fn() {
          @sf.theme().p.muted
        })
      })
    })
    |> ignore
    r.pick(fn() { if busy() { 1 } else if meta() != "" { 2 } else { 0 } }, fn(e, what) {
      if look.wide {
        e.min_height(By(fn() { Some(look.row_line * e.words_scale()) })).lies_along(Is(Middle)) |> ignore
      }
      match what {
        1 => @sf.spinner_node(e, size=share_row_spin) |> ignore
        2 => @sf.words_node(e, meta, fn() { share_label_words }) |> ignore
        _ => ()
      }
    })
  })
  |> ignore
}

///|
/// A row: across, on its middle; faint (50%) while another opens; a spinner 14 while it opens; what is under its title
/// on a line of 18.
// kept across runs: a value (no field of it changes)
let share_row_look : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// The wide panel's row (⌘K's): its mark, words and what is at its end on their tops, each on its title's line.
// kept across runs: a value (no field of it changes)
let share_row_look_wide : @ui.Style = @ui.css("row w=Full align=AStart")

///|
let share_row_faint : Double = 0.5

///|
let share_row_spin : Double = 14.0

///|
let share_sub_line : Double = 18.0
