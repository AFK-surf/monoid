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
}

///|
let menu_doing : MenuDoing = {
  open: @signals.signal("", same=fn(a, b) { a == b }),
  copy: @signals.signal("", same=fn(a, b) { a == b }),
  image: @signals.signal("", same=fn(a, b) { a == b }),
  offered: "",
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
