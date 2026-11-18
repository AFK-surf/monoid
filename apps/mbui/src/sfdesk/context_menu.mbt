// What a right click in the desktop's window offers, as the desktop app's own (still.fail apps/desktop/src/context-menu.mts:
// Electron shows none of its own): a link's (在浏览器中打开链接 and 复制链接), an image's (复制图片), then the words: a
// field's editing (剪切, 复制, 粘贴, 全选, each as it can be done now), elsewhere the words picked (复制); a line between
// them; nothing where there is none of these (the page's ground). A message of a chat's list right clicked offers its
// words, link and turn's picture at the end (sfbase's share_offered, the same actions its ⋯ offers).
// The library's menu (@sf.menu_node) at the pointer, a node of the window's tree over the wide frame
// (context_menu_node). An old view's field right clicked is told it by the old frame, whose fields they are, and its
// editing chosen is done there (context_fields): what of it is left the old frame's while its fields are.

///|
/// The menu while it is open: where (the pointer: the right click's place, which says the right click it is open for:
/// context_opened_at), the link right clicked ("" none), the image (its source, "" none), the field (its id, 0 none)
/// and what can be done to it then (field_can), the words picked then ("" none), and what shares the turn of the
/// message right clicked (None: none).
pub struct ContextMenu {
  mut open : Bool
  mut x : Double
  mut y : Double
  mut link : String
  mut image : String
  mut field : Int
  mut field_can : Int
  mut words : String
  mut share : (() -> Unit)?
  mut share_link : String
  mut share_words : String
  mut share_key : String
}

///|
pub let context : ContextMenu = {
  open: false,
  x: 0.0,
  y: 0.0,
  link: "",
  image: "",
  field: 0,
  field_can: 0,
  words: "",
  share: None,
  share_link: "",
  share_words: "",
  share_key: "",
}

///|
/// Whether the menu is open for the right click made at (x, y): opened there by what else that right click asked (the
/// page's right click under an image's, a message's turn offered with the words picked in it), whichever part said it
/// first. One right click, one place, as each that reads it has it; another made there while the menu shows is the
/// same menu's, what is under it the same.
fn context_opened_at(x : Double, y : Double) -> Bool {
  context.open && context.x == x && context.y == y
}

///|
/// Each opening of the menu (a right click at another place, or after it closed): the menus drawn (shown, or going),
/// by their number, and the one open now (0 none); and what the open one holds told as it changes (context_told).
// kept across runs: put back by context_reset
let context_menus : @signals.Signal[Array[Int]] = @signals.signal([])

///|
// kept across runs: put back by context_reset
let context_now : @signals.Signal[Int] = @signals.signal(0)

///|
// kept across runs: put back by context_reset
let context_said : @signals.Signal[Int] = @signals.signal(0)

///|
/// The menus gone their way out (by their number), let go of as the next opens.
// kept across runs: put back by context_reset
let context_menus_gone : Map[Int, Bool] = Map([])

///|
// kept across runs: counted on, put back by context_reset
let context_count : Ref[Int] = Ref(0)

///|
/// An old view's field's editing chosen in the menu (the field, what: text_menu_*), done by the old frame whose field it
/// is (context_fields); None once done.
// kept across runs: put back by context_reset
let context_edit : @signals.Signal[(Int, Int)?] = @signals.signal(None)

///|
/// The image whose pixels are read for 复制图片 ("" none), put on the clipboard once read (context_menu_node).
// kept across runs: put back by context_reset
let context_copying : @signals.Signal[String] = @signals.signal("")

///|
/// What the menu holds changed: what shows it told, the message it is open for lit.
fn context_told() -> Unit {
  context_said.set(context_said.untracked() + 1)
  context_lit()
}

///|
/// The menu at (x, y): another opening of it where it is not open for a right click there, else the same told anew.
fn context_open_at(x : Double, y : Double) -> Unit {
  let again = context_opened_at(x, y)
  context.open = true
  context.x = x
  context.y = y
  if !again {
    context_count.val += 1
    let n = context_count.val
    // (those gone their way out let go of as another opens: never as one goes, what it is let go in)
    let left = context_menus.untracked().filter(fn(m) { !context_menus_gone.contains(m) })
    context_menus_gone.clear()
    context_menus.set(left + [n])
    context_now.set(n)
  }
  context_told()
}

///|
/// The menu opened at (x, y) by what is right clicked in a page (a link, an image, the words picked: `words`).
fn context_asked(x : Double, y : Double, words : String, link? : String = "", image? : String = "") -> Unit {
  context.link = link
  context.image = image
  context.field = 0
  context.field_can = 0
  context.words = words
  context.share = None
  context.share_link = ""
  context.share_words = ""
  context.share_key = ""
  // (a message's turn offered by another right click, elsewhere, is not this one's)
  match @signals.untracked(fn() { @sfbase.share_offered.get() }) {
    Some((ox, oy, _, _, _, _)) if ox != x || oy != y => @sfbase.share_offered.set(None)
    _ => ()
  }
  context_open_at(x, y)
}

///|
/// An old view's field `id` right clicked at (x, y), what can be done to it then `can`: its editing.
fn context_field_at(id : Int, x : Double, y : Double, can : Int) -> Unit {
  context.link = ""
  context.image = ""
  context.field = id
  context.field_can = can
  context.words = ""
  context.share = None
  context.share_link = ""
  context.share_words = ""
  context.share_key = ""
  // (a message's turn offered elsewhere is not this one's)
  match @signals.untracked(fn() { @sfbase.share_offered.get() }) {
    Some((ox, oy, _, _, _, _)) if ox != x || oy != y => @sfbase.share_offered.set(None)
    _ => ()
  }
  context_open_at(x, y)
}

///|
/// A message right clicked at (x, y): its turn offered (`go`, its link and words; `key` its row's) with what else that
/// right click opened the menu for (its link, its picture, the words picked: context_opened_at), or alone; not over a
/// field right clicked there, nor again for the same message.
fn context_share_at(x : Double, y : Double, go : () -> Unit, link : String, words : String, key : String) -> Unit {
  let here = context_opened_at(x, y)
  if (here && context.field != 0) || (here && context.share is Some(_) && context.share_key == key) {
    return
  }
  if !here {
    context.link = ""
    context.image = ""
    context.field = 0
    context.field_can = 0
    context.words = @ui.picked_words()
  }
  context.share = Some(go)
  context.share_link = link
  context.share_words = words
  context.share_key = key
  context_open_at(x, y)
}

///|
/// The menu closed: what it was open for, and the turn a message offered it, let go.
fn context_closed() -> Unit {
  context.open = false
  context_now.set(0)
  @sfbase.share_offered.set(None)
  context_lit()
}

///|
fn context_reset() -> Unit {
  context_closed()
  context.share = None
  context.share_link = ""
  context.share_words = ""
  context.share_key = ""
  context_menus.set([])
  context_menus_gone.clear()
  context_count.val = 0
  context_edit.set(None)
  context_copying.set("")
}

///|
/// A right click in the page (box `page`): the words picked's menu, where words are picked and nothing in the page
/// that has a menu of its own was right clicked (Ctx::menu_asked: a message's image is its own menu's alone).
pub fn context_page(c : @ui.Ctx, page : Int) -> Unit {
  match c.menu_asked(page) {
    Some((x, y)) if !context_opened_at(x, y) && c.selected_text().trim(chars=" \n\t") != "" =>
      context_asked(x, y, c.selected_text())
    _ => ()
  }
}

///|
/// A page made once (node `v`, the tree's), as an old view's page is in its frame (page_one's c.selectable and
/// context_page): its words in pieces picked with the mouse (@ui.words_picked), and a right click in it the words
/// picked's menu, where nothing in it that takes a press of its own was right clicked (Tree::menu_at: the topmost that
/// does is asked), as the click's event, at its moment.
pub fn context_node(v : @view.View) -> Unit {
  @ui.words_picked(v)
  v.on_menu(fn(m) {
    let words = @ui.picked_words()
    if !context_opened_at(m.wx, m.wy) && words.trim(chars=" \n\t") != "" {
      context_asked(m.wx, m.wy, words)
    }
  })
  |> ignore
}

///|
/// What the old frame does of the menu (over the wide frame, its island's): an old view's field right clicked anywhere
/// opens its editing (Ctx::field_right_clicked: the focus given it, what can be done to it then, field_can), and the
/// editing chosen in the menu is done to it (Ctx::field_edit; 粘贴 as ⌘V: a picture on the clipboard put in as a file,
/// else its words, Ctx::field_paste), the focus its again.
pub fn context_fields(c : @ui.Ctx) -> Unit {
  match c.field_right_clicked() {
    Some((id, x, y)) => context_field_at(id, x, y, c.field_can(id))
    None => ()
  }
  match context_edit.get() {
    Some((field, what)) => {
      context_edit.set(None)
      if what == @hostapi.text_menu_paste {
        c.field_paste(field)
      } else {
        c.field_edit(field, what)
      }
    }
    None => ()
  }
}

///|
/// The menu, in node `v` (a shell's): each opening of it a menu of the library's at the pointer (@sf.menu_node: Escape,
/// back and a press beside it close it, a right click beside it closing it and going on to what is under it), what it
/// holds as context says now (a link's items, an image's, the words', a message's), kept as it was as it closes, while
/// it goes; chosen, it closes, then what was chosen is done. A message's turn offered by a right click (sfbase's
/// share_offered, wherever that was) is told to it as it is offered. 复制图片's image read, its pixels put on the
/// clipboard as a picture (Electron's copyImage: the picture decoded, as PNG).
pub fn context_menu_node(v : @view.View) -> Unit {
  // (told as it is offered, another at another place too, the one before not let go)
  v.reacts(
    fn() {
      match @sfbase.share_offered.get() {
        Some((x, y, _, link, words, key)) => Some((x, y, link, words, key))
        None => None
      }
    },
    fn(now) {
      match (now, @sfbase.share_offered.untracked()) {
        (Some(_), Some((x, y, go, link, words, key))) => context_share_at(x, y, go, link, words, key)
        _ => ()
      }
    },
  )
  v.each(fn() { context_menus.get() }, fn(n) { n }, fn(cell, k) {
    // (over the window, as what it holds is)
    cell.over(Is(true)) |> ignore
    let n = k.untracked()
    let (x, y) = (context.x, context.y)
    let open = fn() { context_now.get() == n }
    let kept : Ref[Array[@sf.MenuItem?]?] = Ref(None)
    let live = fn() {
      context_said.get() |> ignore
      context_items()
    }
    let content = fn() {
      match kept.val {
        Some(items) => items
        None => live()
      }
    }
    let hold = fn() {
      if kept.val is None {
        kept.val = Some(@signals.untracked(live))
      }
    }
    cell.reacts(open, at_start=false, fn(on) {
      if !on {
        hold()
      }
    })
    @sf.menu_node(
      cell,
      open,
      fn(layer) { @sf.fixed_anchor(layer, (x, y, 0.0, 0.0)) },
      content,
      "",
      Start,
      0.0,
      false,
      false,
      fn(item) {
        hold()
        context_closed()
        (item.select)()
      },
      fn() {
        hold()
        if @signals.untracked(open) {
          context_closed()
        }
      },
      gone=fn() { context_menus_gone[n] = true },
      min_w=context_menu_w,
    )
  })
  // (复制图片: the image's pixels read, then onto the clipboard as a picture)
  v.pick(fn() { context_copying.get() }, fn(p, image) {
    if image != "" {
      let pixels = @ui.tree_image_pixels(p, image, image_copy_px)
      let state = fn() {
        match pixels() {
          None => 0
          Some(@ui.PixelsRead(_, _, _)) => 1
          Some(_) => 2
        }
      }
      p.reacts(state, fn(s) {
        if s == 0 {
          return
        }
        match @signals.untracked(pixels) {
          Some(@ui.PixelsRead(w, h, rgba)) => @ui.clipboard_set_png(@pixels.png(w, h, unpremultiplied(rgba)))
          _ => ()
        }
        context_copying.set("")
      })
    }
  })
}

///|
/// What the menu holds as context says it now: a link's items, an image's, a field's editing (each as it can be done
/// then) or the words picked's, a message's; a line between them. Each item, chosen, does its own as the menu has
/// closed.
fn context_items() -> Array[@sf.MenuItem?] {
  let items : Array[@sf.MenuItem?] = []
  let group = fn() {
    if items.length() > 0 {
      items.push(None)
    }
  }
  let item = fn(label : String, icon : String, f : () -> Unit, disabled : Bool) {
    items.push(Some(@sf.menu_item_of(@sf.t(label), f, icon~, disabled~)))
  }
  if !context.open {
    return items
  }
  let link = context.link
  if link.has_prefix("https://") || link.has_prefix("http://") {
    item("desktop.contextMenu.openLink", "external", fn() { @ui.open_url(link) |> ignore }, false)
  }
  if link != "" {
    item("desktop.contextMenu.copyLink", "link", fn() { @sfbase.copy_out(link) }, false)
  }
  if context.image != "" {
    group()
    let image = context.image
    item("desktop.contextMenu.copyImage", "copy", fn() { context_copying.set(image) }, false)
  }
  if context.field != 0 {
    let (field, can) = (context.field, context.field_can)
    group()
    // (a field's editing alone: none has a mark of its own, 剪切 and 全选 having none)
    for x in [
      (@hostapi.text_menu_cut, "desktop.contextMenu.cut"),
      (@hostapi.text_menu_copy, "desktop.contextMenu.copy"),
      (@hostapi.text_menu_paste, "desktop.contextMenu.paste"),
      (@hostapi.text_menu_select_all, "desktop.contextMenu.selectAll"),
    ] {
      let what = x.0
      item(x.1, "", fn() { context_edit.set(Some((field, what))) }, (can & what) == 0)
    }
  } else if context.words.trim(chars=" \n\t") != "" {
    group()
    let words = context.words
    item("desktop.contextMenu.copy", "copy", fn() { @sfbase.copy_out(words) }, false)
  }
  match context.share {
    Some(go) => {
      group()
      let (words, link) = (context.share_words, context.share_link)
      if words.trim(chars=" \n\t") != "" {
        item("web-main.chat.copyMessage", "copy", fn() { @sfbase.copy_out(words, said=@sf.t("common.copied")) }, false)
      }
      if link != "" {
        item("web-main.chat.copyMessageLink", "link", fn() { @sfbase.copy_out(link, said=@sf.t("common.link.copied")) }, false)
      }
      item("web-main.chat.selectMessages", "check-circle", go, false)
    }
    None => ()
  }
  items
}

///|
/// The message the menu is open for told (sfbase's message_menu): its row lit while it is, none once it is gone.
fn context_lit() -> Unit {
  @sfbase.message_menu.set(if context.open && context.share is Some(_) { context.share_key } else { "" })
}

///|
/// The menu's least width (the system's menus' are about as wide).
let context_menu_w : Double = 180.0
