// A terminal's screen, kept by the host (libghostty-vt on native and Wasm: src/host/term.h, web/host.js): what a
// program wrote to a terminal (VT sequences, colours, cursor, scrollback, selection and modes) made a grid of `cols` ×
// `rows` cells, read as compact dirty-row binary frames (`Terminal::frame`) for `@ui` to draw on its monospace grid.
//
// Binary frame header (42 bytes, little-endian):
//   [0]      version = 1
//   [1]      dirty (0 clean, 1 partial, 2 full)
//   [2..4]   cols : u16
//   [4..6]   rows : u16
//   [6..8]   cursor_x : u16
//   [8..10]  cursor_y : u16
//   [10]     cursor_style : u8 (0 bar, 1 block, 2 underline, 3 hollow)
//   [11]     cursor_flags : u8 (1 visible_in_viewport, 2 blinking, 4 wide_tail, 8 has_cur_rgb, 16 has_fg_rgb, 32 has_bg_rgb)
//   [12..14] modes : u16 (1 DECCKM, 2 bracketed_paste, 4 mouse_tracking, 8 alt_screen, 16 alt_scroll, 32 focus_event, 64 has_selection, 128 viewport_active)
//   [14..17] default fg rgb (3 × u8)
//   [17..20] default bg rgb (3 × u8)
//   [20..23] cursor rgb (3 × u8)
//   [23]     reserved = 0
//   [24..28] sb_total : u32
//   [28..32] sb_offset : u32
//   [32..36] sb_len : u32
//   [36..38] row_count : u16
//   [38..42] reserved = 0
// Followed by `row_count` dirty rows:
//   y : u16, sel_start : u16 (0xFFFF = none), sel_end : u16, cell_count : u16
//   and `cell_count` non-default cells:
//     col : u16, width : u8 (1 or 2), utf8_len : u8, style_flags : u16
//     (bits 0..10 = GhosttyStyleFlags: 1 bold, 2 italic, 4 faint, 8 blink, 16 inverse, 32 invisible, 64 strike, 128 overline,
//      bits 8..10 underline style; 2048 has_fg, 4096 has_bg, 8192 has_ul),
//     optional fg_rgb (3B), optional bg_rgb (3B), optional ul_rgb (3B), utf8[utf8_len].

///|
/// A terminal the host keeps.
pub struct Terminal {
  id : Int
}

///|
/// Mode bit flags returned by `Terminal::modes` and in the frame header.
pub let term_mode_decckm : Int = 1

///|
pub let term_mode_bracketed_paste : Int = 2

///|
pub let term_mode_mouse_tracking : Int = 4

///|
pub let term_mode_alt_screen : Int = 8

///|
pub let term_mode_alt_scroll : Int = 16

///|
pub let term_mode_focus_event : Int = 32

///|
pub let term_mode_has_selection : Int = 64

///|
pub let term_mode_viewport_active : Int = 128

///|
/// A new one of `cols` × `rows` cells; None where the host keeps none.
pub fn Terminal::open(cols : Int, rows : Int) -> Terminal? {
  match tm_open(cols, rows) {
    0 => None
    id => Some({ id, })
  }
}

///|
/// What its program wrote, as it came.
pub fn Terminal::write(self : Terminal, data : Bytes) -> Unit {
  tm_write(self.id, data)
}

///|
/// Its new size in cells and pixels per cell (preserving scrollback and reflowing wrapped lines).
pub fn Terminal::resize(
  self : Terminal,
  cols : Int,
  rows : Int,
  cell_w? : Int = 8,
  cell_h? : Int = 16,
) -> Unit {
  tm_resize(self.id, cols, rows, cell_w, cell_h)
}

///|
/// Binary render-state frame (`full = true` exports every viewport row; `false` exports only rows changed since last frame).
pub fn Terminal::frame(self : Terminal, full? : Bool = false) -> Bytes {
  tm_frame(self.id, if full { 1 } else { 0 })
}

///|
/// Fast scalar bitmask of active terminal modes (`term_mode_*`), with zero allocation.
pub fn Terminal::modes(self : Terminal) -> Int {
  tm_modes(self.id)
}

///|
/// Scroll the viewport (`kind`: 0 delta rows, 1 top, 2 bottom, 3 row offset).
pub fn Terminal::scroll(self : Terminal, kind : Int, value : Int) -> Unit {
  tm_scroll(self.id, kind, value)
}

///|
/// Selection control (`kind`: 0 clear, 1 drag `(x0,y0)->(x1,y1)`, 2 word at `(x0,y0)`, 3 line at `(x0,y0)`, 4 select all).
/// Returns `true` when a selection is active after the call.
pub fn Terminal::select(
  self : Terminal,
  kind : Int,
  x0 : Int,
  y0 : Int,
  x1 : Int,
  y1 : Int,
) -> Bool {
  tm_select(self.id, kind, x0, y0, x1, y1) != 0
}

///|
/// Formatted plain text (`selection_only = true`: selected text unwrapped & trimmed; `false`: active screen trimmed).
pub fn Terminal::text(self : Terminal, selection_only? : Bool = false) -> String {
  tm_text(self.id, if selection_only { 1 } else { 0 })
}

///|
/// Encode a mouse event (`action`: 0 press, 1 release, 2 motion; `button`: 0 none, 1 left, 2 right, 3 middle, 4 wheel-up, 5 wheel-down, 6 wheel-left, 7 wheel-right; `mods`: 1 shift, 2 ctrl, 4 alt, 8 super) in surface pixels.
pub fn Terminal::mouse(
  self : Terminal,
  action : Int,
  button : Int,
  mods : Int,
  x : Int,
  y : Int,
  w : Int,
  h : Int,
  cw : Int,
  ch : Int,
) -> Bytes {
  tm_mouse(self.id, action, button, mods, x, y, w, h, cw, ch)
}

///|
/// Let go of.
pub fn Terminal::close(self : Terminal) -> Unit {
  tm_close(self.id)
}
