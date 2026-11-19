// What a person does with a Farview tab's page here besides reading and pressing it (farview_tab.mbt holds the tab):
// words found on it (⌘F: its bar under the tab's, the stage finding them on the page as it is laid out here, never
// asking the host), the page shown bigger or smaller (⌘= ⌘- ⌘0: the stage's zoom, laid out again in the room the bigger
// page has; how big it is said in the tab's bar while it is not as laid out), the page's menu (a right click, a finger
// held: what is there, the stage's MenuHit, offered as the presenters' menu at that point), the files a page's file
// input asks for (the device's picker) and what it downloads (kept in the device's downloads).

///|
/// ⌘F on a tab's page: whether its bar is open, its field and the words looked for now ("" none).
priv struct FarviewFind {
  open : @signals.Signal[Bool]
  field : @ui.Field
  query : @signals.Signal[String]
}

///|
fn FarviewFind::new() -> FarviewFind {
  { open: @signals.signal(false), field: @ui.Field::new(), query: @signals.signal("") }
}

///|
/// The bar opened (or brought to again): its words picked whole, to type over, and looked for again on the page as it
/// is now.
fn FarviewFind::show(self : FarviewFind, stage : @stage.Stage) -> Unit {
  @view.transition(fn() {
    self.open.set(true)
    let q = self.field.text()
    self.field.pick(0, q.length())
    self.field.focus()
    self.query.set(q)
    stage.find(q)
  })
}

///|
/// The bar closed: nothing looked for any more, the matches no longer drawn, the keyboard let go of. Its words kept
/// for the next ⌘F (picked whole then).
fn FarviewFind::close(self : FarviewFind, stage : @stage.Stage) -> Unit {
  @view.transition(fn() {
    self.open.set(false)
    self.field.let_go()
    stage.find_clear()
  })
}

///|
/// ⌘G, ⇧⌘G: the match after (or before) the one at; the bar opened where it is not.
fn FarviewFind::step(self : FarviewFind, stage : @stage.Stage, delta : Int) -> Unit {
  if !self.open.untracked() {
    self.show(stage)
  } else {
    stage.find_step(delta)
  }
}

///|
/// Which of how many matches is the one at (m/n), that there is none, or nothing while nothing is looked for.
fn farview_find_said(stage : @stage.Stage, query : String) -> String {
  if query == "" {
    return ""
  }
  let (at, n) = stage.find_place()
  if n == 0 {
    @sf.t("web-main.find.none")
  } else {
    "\{at}/\{n}"
  }
}

///|
/// ⌘F's bar in `c` (the tab's chrome, under its bar): a capsule inset 8 from the tab's sides as the agent's line is,
/// on the same faint ground, its keys concentric with it; fading in as it opens and out as it closes (find_bar_node's
/// fade), taking no press from the moment it closes.
fn farview_find_node(c : @view.View, stage : @stage.Stage, find : FarviewFind, tips? : @sf.TipLayer) -> Unit {
  c.show(fn() { find.open.get() }, leave=find_in_ms, fn(fb) {
    fb.padding(Is((8.0, 0.0, 8.0, 8.0))).presses(By(fn() { find.open.get() })) |> ignore
    fb.alpha(By(@motion.presence_in(fb, @motion.tween(find_in_ms, ease=Out)))) |> ignore
    @sf.page_find_node(
      fb,
      fn() { farview_find_said(stage, find.query.get()) },
      fn(d) { stage.find_step(d) },
      fn(_) { stage.find_place().1 > 0 },
      fn() { find.close(stage) },
      field=find.field,
      placeholder_by=fn() { @sf.t("web-pages.farview.findPlaceholder") },
      edited=fn(words) {
        let q = words.replace_all(old="\n", new="")
        find.query.set(q)
        stage.find(q)
      },
      frame=fn(f) {
        f
        .padding(Is((farview_find_in, farview_find_in, farview_find_in, farview_find_in)))
        .ground(By(fn() { @sf.theme().p.neutral_bg }))
        .radius(Is(farview_find_round))
        |> ignore
      },
      said_look=fn() { farview_find_said_words },
      tips?,
      field_in=farview_words_in - farview_find_in,
    )
    |> ignore
  })
}

///|
/// How far in ⌘F's keys stand from its capsule's ends, and its round: its keys' round (@sf.page_find_key_side's half)
/// as far in again, concentric.
let farview_find_in : Double = 4.0

///|
let farview_find_round : Double = @sf.page_find_key_side / 2.0 + farview_find_in

///|
/// Which match is the one at: the meta's, muted, its digits all one width (m/n changing where it stands).
// kept across runs: a value (no field of it changes)
let farview_find_said_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, tabular=true)

///|
/// How big the page is shown, as a percentage (150%).
fn farview_zoom_said(z : Double) -> String {
  "\{(z * 100.0 + 0.5).floor().to_int()}%"
}

///|
/// Whether the page is shown at another size than it is laid out at.
fn farview_zoomed(stage : @stage.Stage) -> Bool {
  (stage.zoom() - 1.0).abs() > 0.001
}

///|
/// How big the page is shown, in the tab's bar (`bar`) beside its address while it is not as laid out: a capsule as
/// high as the address's, its digits all one width, pressed: back to as laid out.
fn farview_zoom_node(bar : @view.View, stage : @stage.Stage, tips? : @sf.TipLayer) -> Unit {
  bar.show(along_row=true, fn() { farview_zoomed(stage) }, fn(z) {
    let label = fn() { @sf.t("web-pages.farview.zoomReset", args=[("zoom", "100%")]) }
    @sf.capsule_words_button_node(
      z,
      fn() { farview_zoom_said(stage.zoom()) },
      label,
      fn() { stage.zoom_reset() },
      fn() { farview_zoom_words },
      room=farview_words_in,
      tips?,
    )
    |> ignore
  })
}

///|
/// How big the page is shown: the body's, its digits all one width.
// kept across runs: a value (no field of it changes)
let farview_zoom_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, wrap=false, tabular=true)

///|
/// The page's menu at what `hit` says is there: the presenters' menu at the point it was asked for (beside it on a
/// wide screen, a sheet from the foot on a small one).
fn farview_menu(stage : @stage.Stage, hit : @stage.MenuHit, find : () -> Unit) -> Unit {
  @sf.menu(farview_menu_items(stage, hit, find), from=@sf.at_point(hit.x, hit.y))
}

///|
/// What the page's menu holds for `hit`: a link's (in a new tab, its address copied), a picture's (copied where its
/// bytes are a PNG's, its address copied), the words picked's (copied), going back and forth and again, then the
/// page's own (words found on it, its address copied); a line between each part there is, none at either end.
fn farview_menu_items(stage : @stage.Stage, hit : @stage.MenuHit, find : () -> Unit) -> Array[@sf.MenuItem?] {
  let items : Array[@sf.MenuItem?] = []
  let group = fn() {
    if items.last() is Some(Some(_)) {
      items.push(None)
    }
  }
  let item = fn(label : String, icon : String, f : () -> Unit, disabled : Bool) {
    items.push(Some(@sf.menu_item_of(label, f, icon~, disabled~)))
  }
  let link = hit.link
  if link != "" {
    if link.has_prefix("https://") || link.has_prefix("http://") {
      item(@sf.t("web-pages.farview.openInNewTab"), "external", fn() { stage.open_link_new_tab(link) }, false)
    }
    item(@sf.t("desktop.contextMenu.copyLink"), "link", fn() {
      @sfbase.copy_out(link, said=@sf.t("common.link.copied"))
    }, false)
  }
  if hit.image != "" {
    group()
    match hit.image_bytes {
      Some(b) if farview_png(b) =>
        item(@sf.t("desktop.contextMenu.copyImage"), "photo", fn() {
          @ui.clipboard_set_png(b)
          @sfbase.toast_later(@sf.t("common.copied"))
        }, false)
      _ => ()
    }
    let image = hit.image
    item(@sf.t("web-pages.farview.copyImageLink"), "link", fn() {
      @sfbase.copy_out(image, said=@sf.t("common.link.copied"))
    }, false)
  }
  if hit.selection.trim(chars=" \n\t") != "" {
    group()
    item(@sf.t("desktop.contextMenu.copy"), "copy", fn() {
      if stage.copy_selection() {
        @sfbase.toast_later(@sf.t("common.copied"))
      }
    }, false)
  }
  group()
  item(@sf.t("web-pages.screen.back"), "arrow-left", fn() { stage.back() }, !hit.can_back)
  item(@sf.t("web-pages.screen.forward"), "arrow-right", fn() { stage.forward() }, !hit.can_forward)
  item(@sf.t("web-pages.screen.reloadShort"), "refresh", fn() { stage.reload() }, false)
  group()
  item(@sf.t("web-pages.farview.find"), "search", find, false)
  let page = @signals.untracked(fn() { stage.url() })
  if page != "" {
    item(@sf.t("web-pages.remote.copyUrl"), "link", fn() { @sfbase.copy_out(page, said=@sf.t("common.link.copied")) }, false)
  }
  items
}

///|
/// Whether `b` is a PNG's bytes (its signature), which the clipboard takes as a picture.
fn farview_png(b : Bytes) -> Bool {
  b.length() > 4 && b[0] == b'\x89' && b[1] == b'P' && b[2] == b'N' && b[3] == b'G'
}

///|
/// The device's picker for a file input's ask (`accept`: its accept attribute; `multiple`: whether it takes several):
/// the gallery's where all it accepts are pictures, else files; what was chosen given to the page (one alone where
/// it takes one), nothing chosen (or no picker here) its cancel.
fn farview_pick(stage : @stage.Stage, wire_id : Int, accept : String, multiple : Bool) -> Unit {
  let kinds = []
  for part in accept.split(",") {
    let k = part.trim(chars=" \t").to_lower()
    if k != "" {
      kinds.push(k)
    }
  }
  let photos = !kinds.is_empty() && kinds.iter().all(fn(k) { k.has_prefix("image/") })
  let kind : @hostapi.PickKind = if photos { Photos } else { Files }
  let asked = @ui.pick(kind, on_got=fn(files) {
    if files.is_empty() {
      stage.cancel_file_pick(wire_id)
    } else {
      let taken = if multiple { files } else { [files[0]] }
      stage.give_files(wire_id, taken.map(fn(f) { (f.name, @sfbase.preview_kind(f.name).1, f.bytes) }))
    }
  })
  if asked is None {
    stage.cancel_file_pick(wire_id)
  }
}

///|
/// What the page downloaded and not yet kept: each kept in the device's downloads, said in the toast; one too big to
/// be sent (no bytes) said kept in the tab's downloads on the station alone.
fn farview_keep_downloads(stage : @stage.Stage) -> Unit {
  for d in stage.take_downloads() {
    let (name, _, mime, bytes) = d
    if bytes.is_empty() {
      @sfbase.toast_later(@sf.t("web-pages.farview.downloadedOnHost", args=[("name", name)]))
      continue
    }
    let kind = if mime == "" { "application/octet-stream" } else { mime }
    if @ui.keep(name, kind, bytes, way=Downloads) is Some(_) {
      @sfbase.toast_later(@sf.t("web-pages.farview.downloaded", args=[("name", name)]))
    }
  }
}

///|
/// A tab's screen and those of its chat's other tabs share what is before its number (`browser:fv_<chat>`, then
/// `_<n>` for all but its first).
fn farview_tabs_of(screen : String) -> String {
  let head = "browser:fv_"
  guard screen.has_prefix(head) else { return screen }
  let rest = screen.to_array()[head.length():]
  let out = StringBuilder()
  out.write_string(head)
  for c in rest {
    if c == '_' {
      break
    }
    out.write_char(c)
  }
  out.to_string()
}

///|
/// How long a tab the page asked for is waited for to be among the station's screens, to be shown as it comes.
let farview_opened_wait_ms : Double = 5000.0
