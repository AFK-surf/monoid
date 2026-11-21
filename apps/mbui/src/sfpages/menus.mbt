// What a message's link and file offer, held with a finger or right clicked with a mouse (c.menu_asked, the rich
// text's held link): one menu for both, the presenters' (@sf.menu: a sheet with a finger short of Large, else a small
// panel at the pointer). A link: open it, copy it; a file: quote or download it, a picture also copied (read whole, onto the
// clipboard as a PNG).
// What a choice does is done in the frame after it, by the list that offered it (menus_frame); a picture's copy on a
// chat's page made as nodes by that page (menus_image_node).

///|
/// What a menu's choice left to do: a link to open, words to copy, a picture to copy.
priv struct MenuDoing {
  /// (told: the list that offered it built again to do it)
  open : @signals.Signal[String]
  copy : @signals.Signal[String]
  image : @signals.Signal[String]
  mut offered : String
  /// the file whose menu a finger held opened (its box's id, 0 none), and that menu (the presenters' serial)
  mut held_for : Int
  mut held_serial : Int
}

///|
let menu_doing : MenuDoing = {
  open: @signals.signal("", same=fn(a, b) { a == b }),
  copy: @signals.signal("", same=fn(a, b) { a == b }),
  image: @signals.signal("", same=fn(a, b) { a == b }),
  offered: "",
  held_for: 0,
  held_serial: -1,
}

///|
/// The picture whose menu was last opened ("" none).
pub fn offered_image() -> String {
  menu_doing.offered
}

///|
fn menus_reset() -> Unit {
  menu_doing.open.set("")
  menu_doing.copy.set("")
  menu_doing.image.set("")
  menu_doing.offered = ""
  menu_doing.held_for = 0
  menu_doing.held_serial = -1
}

///|
/// Whether a finger held file `id` (its box's id) for its menu and that menu is up (lifted meanwhile: @sf.lift_over).
fn file_held_open(id : Int) -> Bool {
  menu_doing.held_for == id && @sf.presented_drawn_of(menu_doing.held_serial)
}

///|
/// A link in a message held or right clicked: its menu at the pointer.
fn link_held(c : @ui.Ctx, href : String) -> Unit {
  // (the press is the link's menu's, not a passage's pick)
  pk.taken_at = c.press().frame
  let (x, y, _) = c.pointer()
  // held by a finger, felt as it opens
  @sf.menu_held(c, "link") |> ignore
  @sf.link_menu(
    href,
    from=@sf.at_point(x, y),
    fn() { menu_doing.open.set(href) },
    fn() { menu_doing.copy.set(href) },
  )
}

///|
/// A file a message names by its path (`path`, its agent `agent`'s on `station`) held or right clicked: 在侧边打开
/// where it is offered (beside_offered: a side panel for the chat, a file, a kind that opens there); else nothing.
fn path_held(c : @ui.Ctx, src : Source, station : String, agent : String, path : String) -> Unit {
  if path.has_suffix("/") || !@sfbase.beside_offered(path, stored_name(path)) {
    return
  }
  pk.taken_at = c.press().frame
  let (x, y, _) = c.pointer()
  @sf.menu_held(c, "link") |> ignore
  @sf.menu(
    [Some(@sf.menu_item_of(@sf.t("web-main.preview.openBeside"), fn() { open_named(src, station, agent, path, beside=true) }, icon="panel-open"))],
    from=@sf.at_point(x, y),
  )
}

///|
/// A file in a message (box `id`; a picture's image `src`, else "") held or right clicked: its menu there, as a
/// passage's (pick.mbt): 引用 into the chat's draft (`quote`, where it is a message's), then what else it offers
/// (`more`: 下载 and a video's 加载), then a picture's copy; after them, a line between, what its message offers of
/// itself (`after`, read as the menu opens: its link copied and 多选, as the page made as nodes has them).
fn file_menu(
  c : @ui.Ctx,
  id : Int,
  src : String,
  quote? : (() -> Unit)? = None,
  more? : Array[@sf.MenuItem?] = [],
  reveal? : ((@sf.MenuItem?) -> Unit) -> Unit,
  after? : () -> Array[@sf.MenuItem?] = fn() { [] },
) -> Unit {
  match c.menu_asked(id) {
    Some((x, y)) => {
      menu_doing.offered = src
      // held with a finger: the press is the menu's (lifting it opens nothing), felt
      let held = @sf.menu_held(c, "file")
      if held {
        // (the press is the file's menu's, not a passage's pick)
        pk.taken_at = c.press().frame
      }
      let tail = after()
      let open = fn(shown : @sf.MenuItem?) {
        let items : Array[@sf.MenuItem?] = []
        match quote {
          Some(q) => items.push(Some(@sf.menu_item_of(@sf.t("web-main.chat.quote"), q, icon="quote")))
          None => ()
        }
        items.append(more)
        if shown is Some(_) {
          items.push(shown)
        }
        if src != "" && src != "!" {
          items.push(Some(@sf.menu_item_of(@sf.t("desktop.contextMenu.copyImage"), fn() { menu_doing.image.set(src) }, icon="copy")))
        }
        if !tail.is_empty() {
          if !items.is_empty() {
            items.push(None)
          }
          items.append(tail)
        }
        if items.length() > 0 {
          @sf.menu(items, from=@sf.at_point(x, y))
          menu_doing.held_for = if held { id } else { 0 }
          menu_doing.held_serial = @sf.last_presented()
        }
      }
      // (its 在访达中显示 where this device shows files in their folders: asked once the frame's builds are over, as a
      // press waiting for the core is, message_files.mbt with_reveal)
      match reveal {
        Some(r) if @hostapi.reveals_files() => c.after_build("file-menu-reveal", fn() { r(open) })
        _ => open(None)
      }
    }
    _ => ()
  }
}

///|
/// What a menu's 复制图片 left (`image`), done on a page made as nodes, in `v`: the picture read whole while it is
/// read (tree_image_pixels, as menus_frame reads it for an old view's list), then put on the clipboard as a PNG, or let
/// go where it cannot be read.
fn menus_image_node(v : @view.View) -> Unit {
  v.pick(fn() { menu_doing.image.get() }, fn(r, src) {
    guard src != "" else { return }
    let read = @ui.tree_image_pixels(r, src, image_copy_px)
    let state = fn() {
      match read() {
        None => 0
        Some(@ui.PixelsRead(_, _, _)) => 1
        Some(_) => 2
      }
    }
    r.reacts(state, fn(s) {
      guard s != 0 else { return }
      let png = match @signals.untracked(read) {
        Some(@ui.PixelsRead(w, h, rgba)) => Some(@pixels.png(w, h, unpremultiplied(rgba)))
        _ => None
      }
      menu_doing.image.set("")
      match png {
        Some(p) => @ui.clipboard_set_png(p)
        None => ()
      }
    })
  })
}

///|
/// Pixels with their colours as they are (the host's are premultiplied by their alpha, a PNG's not).
pub fn unpremultiplied(rgba : FixedArray[Byte]) -> FixedArray[Byte] {
  let out = FixedArray::make(rgba.length(), b'\x00')
  let n = rgba.length() / 4
  for i in 0..<n {
    let k = i * 4
    let a = rgba[k + 3].to_int()
    for j in 0..<3 {
      let v = rgba[k + j].to_int()
      let u = if a == 0 { 0 } else { (v * 255 + a / 2) / a }
      out[k + j] = (if u > 255 { 255 } else { u }).to_byte()
    }
    out[k + 3] = rgba[k + 3]
  }
  out
}

///|
/// The picture copied at most this many pixels on its long side.
pub let image_copy_px : Int = 4096
