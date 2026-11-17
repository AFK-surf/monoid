// The app's terminals on a device whose build has libghostty-vt (scripts/core.sh puts its headers and library in
// out/core/ghostty-vt; mbui's src/host/term.h is what a host answers without it, its calls weak or /alternatename,
// these taking their place). Built without libghostty-vt's headers this file is only its mark.
//
// The mark: the Mac's link asks for it (src/stillfail/moon.pkg's `-Wl,-u,_sf_terminal_linked`), and Windows's
// win_engine.c reads it, so this file's object is taken out of the package's archive even though term.h defines
// fallback symbols.
int sf_terminal_linked = 1;

#ifndef _WIN32
#define GHOSTTY_STATIC 1
#endif
#if __has_include(<ghostty/vt.h>)
#ifdef _WIN32
#pragma comment(lib, "ghostty-vt.lib")
#endif

#include <ghostty/vt.h>
#include <moonbit.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  GhosttyTerminal term;
  GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows;
  GhosttyRenderStateRowCells cells;
  GhosttyMouseEncoder mouse;
  GhosttyMouseEvent mouse_ev;
  GhosttyTrackedGridRef drag_anchor;
  int32_t drag_x0, drag_y0;
  uint32_t drag_screen_x0, drag_screen_y0;
  bool drag_active;
  bool mouse_synced;
  uint32_t mouse_buttons;
  uint8_t *frame_buf;
  size_t frame_cap;
} sf_term;

#define SF_TERMS 64
static sf_term *sf_terms[SF_TERMS];

static sf_term *sf_term_of(int32_t id) {
  return id >= 1 && id <= SF_TERMS ? sf_terms[id - 1] : NULL;
}

typedef struct {
  uint8_t *p;
  size_t len, cap;
} sf_buf;

static bool sf_reserve(sf_buf *b, size_t add) {
  if (b->len + add <= b->cap) return true;
  size_t cap = b->cap ? b->cap * 2 : 8192;
  while (cap < b->len + add) cap *= 2;
  uint8_t *p = realloc(b->p, cap);
  if (!p) return false;
  b->p = p;
  b->cap = cap;
  return true;
}

static void sf_u8(sf_buf *b, uint8_t v) {
  if (sf_reserve(b, 1)) b->p[b->len++] = v;
}

static void sf_u16(sf_buf *b, uint16_t v) {
  if (sf_reserve(b, 2)) {
    b->p[b->len++] = (uint8_t)(v & 0xff);
    b->p[b->len++] = (uint8_t)((v >> 8) & 0xff);
  }
}

static void sf_u32(sf_buf *b, uint32_t v) {
  if (sf_reserve(b, 4)) {
    b->p[b->len++] = (uint8_t)(v & 0xff);
    b->p[b->len++] = (uint8_t)((v >> 8) & 0xff);
    b->p[b->len++] = (uint8_t)((v >> 16) & 0xff);
    b->p[b->len++] = (uint8_t)((v >> 24) & 0xff);
  }
}

static void sf_bytes(sf_buf *b, const uint8_t *s, size_t n) {
  if (n && sf_reserve(b, n)) {
    memcpy(b->p + b->len, s, n);
    b->len += n;
  }
}

static void sf_patch_u16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
}

static moonbit_bytes_t sf_make_bytes(const uint8_t *p, size_t n) {
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  if (n) memcpy(out, p, n);
  return out;
}

static moonbit_string_t sf_string(const uint8_t *b, size_t len) {
  if (!len || !b) return moonbit_make_string(0, 0);
  uint16_t *tmp = malloc(len * sizeof(uint16_t));
  if (!tmp) return moonbit_make_string(0, 0);
  size_t n = 0;
  for (size_t i = 0; i < len;) {
    uint32_t c = b[i], cp = 0xfffd;
    size_t k = 1;
    if (c < 0x80) cp = c;
    else if (c >= 0xc2 && c < 0xe0 && i + 1 < len) cp = ((c & 31u) << 6) | (b[i + 1] & 63u), k = 2;
    else if (c >= 0xe0 && c < 0xf0 && i + 2 < len) cp = ((c & 15u) << 12) | ((b[i + 1] & 63u) << 6) | (b[i + 2] & 63u), k = 3;
    else if (c >= 0xf0 && c < 0xf5 && i + 3 < len)
      cp = ((c & 7u) << 18) | ((b[i + 1] & 63u) << 12) | ((b[i + 2] & 63u) << 6) | (b[i + 3] & 63u), k = 4;
    if (cp >= 0x10000u) {
      cp -= 0x10000u;
      tmp[n++] = (uint16_t)(0xd800u + (cp >> 10));
      tmp[n++] = (uint16_t)(0xdc00u + (cp & 0x3ffu));
    } else {
      tmp[n++] = (uint16_t)cp;
    }
    i += k;
  }
  moonbit_string_t s = moonbit_make_string((int32_t)n, 0);
  memcpy(s, tmp, n * sizeof(uint16_t));
  free(tmp);
  return s;
}

int32_t mb_host_term_open(int32_t cols, int32_t rows) {
  int slot = -1;
  for (int i = 0; i < SF_TERMS; i++) {
    if (!sf_terms[i]) {
      slot = i;
      break;
    }
  }
  if (slot < 0) return 0;
  sf_term *t = calloc(1, sizeof *t);
  if (!t) return 0;
  uint16_t c = (uint16_t)(cols > 0 ? cols : 1);
  uint16_t r = (uint16_t)(rows > 0 ? rows : 1);
  if (ghostty_terminal_new(NULL, &t->term, c, r) != GHOSTTY_SUCCESS ||
      ghostty_render_state_new(NULL, &t->render) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_iterator_new(NULL, &t->rows) != GHOSTTY_SUCCESS ||
      ghostty_render_state_row_cells_new(NULL, &t->cells) != GHOSTTY_SUCCESS) {
    ghostty_render_state_row_cells_free(t->cells);
    ghostty_render_state_row_iterator_free(t->rows);
    ghostty_render_state_free(t->render);
    ghostty_terminal_free(t->term);
    free(t);
    return 0;
  }
  size_t sb_bytes = 16u * 1024u * 1024u;
  ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &sb_bytes);
  if (ghostty_mouse_encoder_new(NULL, &t->mouse) == GHOSTTY_SUCCESS) {
    bool track_cell = true;
    ghostty_mouse_encoder_set(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_cell);
  }
  ghostty_mouse_event_new(NULL, &t->mouse_ev);
  sf_terms[slot] = t;
  return slot + 1;
}

void mb_host_term_write(int32_t id, moonbit_bytes_t data) {
  sf_term *t = sf_term_of(id);
  if (!t) return;
  ghostty_terminal_vt_write(t->term, data, (size_t)Moonbit_array_length(data));
  t->mouse_synced = false;
}

void mb_host_term_resize(int32_t id, int32_t cols, int32_t rows, int32_t cw, int32_t ch) {
  sf_term *t = sf_term_of(id);
  if (!t) return;
  uint16_t c = (uint16_t)(cols > 0 ? cols : 1);
  uint16_t r = (uint16_t)(rows > 0 ? rows : 1);
  uint32_t pw = (uint32_t)(cw > 0 ? cw : 8);
  uint32_t ph = (uint32_t)(ch > 0 ? ch : 16);
  ghostty_terminal_resize(t->term, c, r, pw, ph);
  t->mouse_synced = false;
}

static uint16_t sf_term_modes(sf_term *t) {
  uint16_t m = 0;
  GhosttyTerminalModeConfig keys = {.mode = GHOSTTY_MODE_CURSOR_KEYS, .value = false};
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &keys) == GHOSTTY_SUCCESS && keys.value) m |= 1u;
  GhosttyTerminalModeConfig paste = {.mode = GHOSTTY_MODE_BRACKETED_PASTE, .value = false};
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &paste) == GHOSTTY_SUCCESS && paste.value) m |= 2u;
  bool mouse = false;
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mouse) == GHOSTTY_SUCCESS && mouse) m |= 4u;
  GhosttyTerminalScreen scr = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &scr) == GHOSTTY_SUCCESS &&
      scr == GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
    m |= 8u;
  GhosttyTerminalModeConfig alt_scroll = {.mode = GHOSTTY_MODE_MOUSE_ALTERNATE_SCROLL, .value = false};
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &alt_scroll) == GHOSTTY_SUCCESS && alt_scroll.value)
    m |= 16u;
  GhosttyTerminalModeConfig focus_ev = {.mode = GHOSTTY_MODE_FOCUS_EVENT, .value = false};
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &focus_ev) == GHOSTTY_SUCCESS && focus_ev.value)
    m |= 32u;
  GhosttySelection sel = {0};
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS) m |= 64u;
  bool vp_active = true;
  if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &vp_active) != GHOSTTY_SUCCESS || vp_active)
    m |= 128u;
  return m;
}

int32_t mb_host_term_modes(int32_t id) {
  sf_term *t = sf_term_of(id);
  return t ? (int32_t)sf_term_modes(t) : 0;
}

moonbit_bytes_t mb_host_term_frame(int32_t id, int32_t flags) {
  sf_term *t = sf_term_of(id);
  if (!t || ghostty_render_state_update(t->render, t->term) != GHOSTTY_SUCCESS) return sf_make_bytes(NULL, 0);

  if (flags & 1) {
    GhosttyRenderStateDirty force_full = GHOSTTY_RENDER_STATE_DIRTY_FULL;
    ghostty_render_state_set(t->render, GHOSTTY_RENDER_STATE_OPT_DIRTY, &force_full);
  }

  uint16_t cols = 0, rows = 0;
  GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);

  bool cur_vis = false, cur_at = false, cur_blink = false, cur_wide_tail = false;
  uint16_t cx = 0, cy = 0;
  GhosttyCursorStyle cur_style = GHOSTTY_CURSOR_STYLE_BLOCK;
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cur_vis);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cur_at);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &cur_blink);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cur_style);
  if (cur_at) {
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL, &cur_wide_tail);
  }

  GhosttyColorRgb def_fg = {0}, def_bg = {0}, cur_rgb = {0};
  bool has_fg = ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &def_fg) == GHOSTTY_SUCCESS;
  bool has_bg = ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &def_bg) == GHOSTTY_SUCCESS;
  bool has_cur = ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_COLOR_CURSOR, &cur_rgb) == GHOSTTY_SUCCESS;

  uint8_t cur_flags = 0;
  if (cur_vis && cur_at) cur_flags |= 1u;
  if (cur_blink) cur_flags |= 2u;
  if (cur_wide_tail) cur_flags |= 4u;
  if (has_cur) cur_flags |= 8u;
  if (has_fg) cur_flags |= 16u;
  if (has_bg) cur_flags |= 32u;

  uint16_t modes = sf_term_modes(t);
  GhosttyTerminalScrollbar sb = {0};
  ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
  uint32_t sb_total = sb.total > 0xffffffffULL ? 0xffffffffu : (uint32_t)sb.total;
  uint32_t sb_offset = sb.offset > 0xffffffffULL ? 0xffffffffu : (uint32_t)sb.offset;
  uint32_t sb_len = sb.len > 0xffffffffULL ? 0xffffffffu : (uint32_t)sb.len;

  sf_buf b = {.p = t->frame_buf, .len = 0, .cap = t->frame_cap};
  if (!sf_reserve(&b, 42)) return sf_make_bytes(NULL, 0);

  // 42-byte header (hostapi/terminal.mbt)
  sf_u8(&b, 1);
  sf_u8(&b, (uint8_t)(dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL ? 2 : dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL ? 1 : 0));
  sf_u16(&b, cols);
  sf_u16(&b, rows);
  sf_u16(&b, cx);
  sf_u16(&b, cy);
  sf_u8(&b, (uint8_t)(cur_style <= 3 ? cur_style : 1));
  sf_u8(&b, cur_flags);
  sf_u16(&b, modes);
  sf_u8(&b, def_fg.r);
  sf_u8(&b, def_fg.g);
  sf_u8(&b, def_fg.b);
  sf_u8(&b, def_bg.r);
  sf_u8(&b, def_bg.g);
  sf_u8(&b, def_bg.b);
  sf_u8(&b, cur_rgb.r);
  sf_u8(&b, cur_rgb.g);
  sf_u8(&b, cur_rgb.b);
  sf_u8(&b, 0);
  sf_u32(&b, sb_total);
  sf_u32(&b, sb_offset);
  sf_u32(&b, sb_len);
  size_t row_count_at = b.len;
  sf_u16(&b, 0);
  sf_u32(&b, 0);

  uint16_t row_count = 0;
  bool have_palette = false;
  GhosttyColorRgb palette[256];

  if (dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE &&
      ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &t->rows) == GHOSTTY_SUCCESS) {
    uint16_t y = 0;
    while (ghostty_render_state_row_iterator_next_dirty(t->rows, &y)) {
      GhosttyRenderStateRowSelection rsel = GHOSTTY_INIT_SIZED(GhosttyRenderStateRowSelection);
      uint16_t sel_start = 0xffffu, sel_end = 0xffffu;
      if (ghostty_render_state_row_get(t->rows, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &rsel) == GHOSTTY_SUCCESS) {
        sel_start = rsel.start_x;
        sel_end = rsel.end_x;
      }
      sf_u16(&b, y);
      sf_u16(&b, sel_start);
      sf_u16(&b, sel_end);
      size_t cell_count_at = b.len;
      sf_u16(&b, 0);
      uint16_t cell_count = 0;

      if (ghostty_render_state_row_get(t->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &t->cells) == GHOSTTY_SUCCESS) {
        uint16_t col = 0;
        while (ghostty_render_state_row_cells_next(t->cells)) {
          uint16_t cell_x = col++;
          GhosttyCell raw = 0;
          GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
          if (ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
          if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;

          uint8_t utf8[64];
          GhosttyBuffer gbuf = {.ptr = utf8, .cap = sizeof utf8, .len = 0};
          if (ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &gbuf) !=
              GHOSTTY_SUCCESS)
            gbuf.len = 0;
          if (gbuf.len == 1 && utf8[0] == ' ') gbuf.len = 0;
          if (gbuf.len > 64) gbuf.len = 64;

          GhosttyStyle style;
          ghostty_style_default(&style);
          ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);

          GhosttyColorRgb fg = {0}, bg = {0}, ul = {0};
          bool cell_fg = ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) ==
                         GHOSTTY_SUCCESS;
          bool cell_bg = ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) ==
                         GHOSTTY_SUCCESS;
          bool cell_ul = false;
          if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB) {
            ul = style.underline_color.value.rgb;
            cell_ul = true;
          } else if (style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE) {
            if (!have_palette) {
              have_palette = ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE, palette) ==
                             GHOSTTY_SUCCESS;
            }
            if (have_palette) {
              ul = palette[style.underline_color.value.palette];
              cell_ul = true;
            }
          }

          uint16_t sflags = (uint16_t)(style.flags & 0x07ffu);
          // Skip blank default cells that draw neither background nor line decorations.
          if (gbuf.len == 0 && !cell_bg && (sflags & (16u | 64u | 128u | 0x0700u)) == 0) continue;

          if (cell_fg) sflags |= 2048u;
          if (cell_bg) sflags |= 4096u;
          if (cell_ul) sflags |= 8192u;

          sf_u16(&b, cell_x);
          sf_u8(&b, wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1);
          sf_u8(&b, (uint8_t)gbuf.len);
          sf_u16(&b, sflags);
          if (cell_fg) {
            sf_u8(&b, fg.r);
            sf_u8(&b, fg.g);
            sf_u8(&b, fg.b);
          }
          if (cell_bg) {
            sf_u8(&b, bg.r);
            sf_u8(&b, bg.g);
            sf_u8(&b, bg.b);
          }
          if (cell_ul) {
            sf_u8(&b, ul.r);
            sf_u8(&b, ul.g);
            sf_u8(&b, ul.b);
          }
          sf_bytes(&b, utf8, gbuf.len);
          cell_count++;
        }
      }
      if (b.p && cell_count_at + 2 <= b.len) sf_patch_u16(b.p + cell_count_at, cell_count);
      row_count++;
    }
  }

  ghostty_render_state_clean(t->render);
  if (b.p && row_count_at + 2 <= b.len) sf_patch_u16(b.p + row_count_at, row_count);
  t->frame_buf = b.p;
  t->frame_cap = b.cap;
  return sf_make_bytes(b.p, b.len);
}

void mb_host_term_scroll(int32_t id, int32_t kind, int32_t value) {
  sf_term *t = sf_term_of(id);
  if (!t) return;
  GhosttyTerminalScrollViewport sv;
  memset(&sv, 0, sizeof sv);
  switch (kind) {
    case 0:
      sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
      sv.value.delta = (intptr_t)value;
      break;
    case 1:
      sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP;
      break;
    case 2:
      sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
      break;
    case 3:
      sv.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW;
      sv.value.row = value > 0 ? (size_t)value : 0;
      break;
    default:
      return;
  }
  ghostty_terminal_scroll_viewport(t->term, sv);
}

static uint16_t sf_clamp_coord(int32_t v, uint16_t limit) {
  if (limit == 0 || v <= 0) return 0;
  if (v >= (int32_t)limit) return (uint16_t)(limit - 1);
  return (uint16_t)v;
}

int32_t mb_host_term_select(int32_t id, int32_t kind, int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
  sf_term *t = sf_term_of(id);
  if (!t) return 0;

  if (kind == 0) {
    if (t->drag_anchor) {
      ghostty_tracked_grid_ref_free(t->drag_anchor);
      t->drag_anchor = NULL;
    }
    t->drag_active = false;
    ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SELECTION, NULL);
    return 0;
  }

  if (kind == 4) {
    t->drag_active = false;
    GhosttySelection sel = {0};
    if (ghostty_terminal_select_all(t->term, &sel) == GHOSTTY_SUCCESS &&
        ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS)
      return 1;
    return 0;
  }

  uint16_t cols = 1, rows = 1;
  ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
  ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
  uint16_t cx0 = sf_clamp_coord(x0, cols), cy0 = sf_clamp_coord(y0, rows);
  uint16_t cx1 = sf_clamp_coord(x1, cols), cy1 = sf_clamp_coord(y1, rows);

  GhosttyPoint p0 = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value = {.coordinate = {.x = cx0, .y = cy0}}};

  if (kind == 2) {
    t->drag_active = false;
    GhosttyGridRef ref = {0};
    if (ghostty_terminal_grid_ref(t->term, p0, &ref) != GHOSTTY_SUCCESS) return 0;
    GhosttyTerminalSelectWordOptions opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
    opt.ref = ref;
    GhosttySelection sel = {0};
    if (ghostty_terminal_select_word(t->term, &opt, &sel) == GHOSTTY_SUCCESS &&
        ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS)
      return 1;
    return 0;
  }

  if (kind == 3) {
    t->drag_active = false;
    GhosttyGridRef ref = {0};
    if (ghostty_terminal_grid_ref(t->term, p0, &ref) != GHOSTTY_SUCCESS) return 0;
    GhosttyTerminalSelectLineOptions opt = GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
    opt.ref = ref;
    GhosttySelection sel = {0};
    if (ghostty_terminal_select_line(t->term, &opt, &sel) == GHOSTTY_SUCCESS &&
        ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS)
      return 1;
    return 0;
  }

  if (kind == 1) {
    if (!t->drag_active || t->drag_x0 != x0 || t->drag_y0 != y0) {
      if (t->drag_anchor) {
        ghostty_tracked_grid_ref_free(t->drag_anchor);
        t->drag_anchor = NULL;
      }
      GhosttyTerminalScrollbar sb = {0};
      ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
      t->drag_x0 = x0;
      t->drag_y0 = y0;
      t->drag_screen_x0 = cx0;
      t->drag_screen_y0 = (uint32_t)sb.offset + cy0;
      ghostty_terminal_grid_ref_track(t->term, p0, &t->drag_anchor);
      t->drag_active = true;
    }

    GhosttyPoint start_pt = {
        .tag = GHOSTTY_POINT_TAG_SCREEN,
        .value = {.coordinate = {.x = t->drag_screen_x0, .y = t->drag_screen_y0}},
    };
    GhosttyPointCoordinate tracked = {0};
    if (t->drag_anchor && ghostty_tracked_grid_ref_point(t->drag_anchor, GHOSTTY_POINT_TAG_SCREEN, &tracked) == GHOSTTY_SUCCESS) {
      start_pt.value.coordinate = tracked;
    }

    GhosttyPoint end_pt = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value = {.coordinate = {.x = cx1, .y = cy1}}};
    GhosttySelection sel = {0};
    if (ghostty_terminal_grid_ref(t->term, start_pt, &sel.start) != GHOSTTY_SUCCESS ||
        ghostty_terminal_grid_ref(t->term, end_pt, &sel.end) != GHOSTTY_SUCCESS)
      return 0;
    return ghostty_terminal_set(t->term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel) == GHOSTTY_SUCCESS ? 1 : 0;
  }

  return 0;
}

moonbit_string_t mb_host_term_text(int32_t id, int32_t sel) {
  sf_term *t = sf_term_of(id);
  if (!t) return moonbit_make_string(0, 0);
  GhosttySelection cur = {0};
  if (sel != 0) {
    if (ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_SELECTION, &cur) != GHOSTTY_SUCCESS)
      return moonbit_make_string(0, 0);
  } else {
    uint16_t cols = 1, rows = 1;
    ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_COLS, &cols);
    ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    GhosttyPoint p0 = {.tag = GHOSTTY_POINT_TAG_VIEWPORT, .value = {.coordinate = {.x = 0, .y = 0}}};
    GhosttyPoint p1 = {
        .tag = GHOSTTY_POINT_TAG_VIEWPORT,
        .value = {
            .coordinate = {
                .x = (uint16_t)(cols > 0 ? cols - 1 : 0),
                .y = (uint32_t)(rows > 0 ? rows - 1 : 0),
            },
        },
    };
    if (ghostty_terminal_grid_ref(t->term, p0, &cur.start) != GHOSTTY_SUCCESS ||
        ghostty_terminal_grid_ref(t->term, p1, &cur.end) != GHOSTTY_SUCCESS)
      return moonbit_make_string(0, 0);
  }

  GhosttyFormatter fmt = NULL;
  if (ghostty_formatter_terminal_new(NULL, &fmt, t->term) != GHOSTTY_SUCCESS) return moonbit_make_string(0, 0);
  bool trim = true;
  bool unwrap = sel != 0;
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap);
  ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_SELECTION, &cur);

  uint8_t *ptr = NULL;
  size_t len = 0;
  moonbit_string_t out = moonbit_make_string(0, 0);
  if (ghostty_formatter_format_alloc(fmt, NULL, &ptr, &len) == GHOSTTY_SUCCESS) {
    out = sf_string(ptr, len);
    ghostty_free(NULL, ptr, len);
  }
  ghostty_formatter_free(fmt);
  return out;
}

moonbit_bytes_t mb_host_term_mouse(
    int32_t id,
    int32_t action,
    int32_t button,
    int32_t mods,
    int32_t x,
    int32_t y,
    int32_t w,
    int32_t h,
    int32_t cw,
    int32_t ch) {
  sf_term *t = sf_term_of(id);
  if (!t || !t->mouse || !t->mouse_ev) return sf_make_bytes(NULL, 0);

  if (action != 2 || !t->mouse_synced) {
    ghostty_mouse_encoder_set_from_terminal(t->mouse, t->term);
    t->mouse_synced = true;
  }

  if (button >= 1 && button <= 3) {
    if (action == 0) t->mouse_buttons |= (1u << button);
    else if (action == 1) t->mouse_buttons &= ~(1u << button);
  }
  bool any_pressed = t->mouse_buttons != 0;
  ghostty_mouse_encoder_set(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_pressed);

  GhosttyMouseEncoderSize sz = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
  sz.screen_width = (uint32_t)(w > 0 ? w : 1);
  sz.screen_height = (uint32_t)(h > 0 ? h : 1);
  sz.cell_width = (uint32_t)(cw > 0 ? cw : 1);
  sz.cell_height = (uint32_t)(ch > 0 ? ch : 1);
  ghostty_mouse_encoder_set(t->mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);

  GhosttyMouseAction ma = action == 1   ? GHOSTTY_MOUSE_ACTION_RELEASE
                          : action == 2 ? GHOSTTY_MOUSE_ACTION_MOTION
                                        : GHOSTTY_MOUSE_ACTION_PRESS;
  ghostty_mouse_event_set_action(t->mouse_ev, ma);
  if (button >= 1 && button <= 11) ghostty_mouse_event_set_button(t->mouse_ev, (GhosttyMouseButton)button);
  else ghostty_mouse_event_clear_button(t->mouse_ev);
  ghostty_mouse_event_set_mods(t->mouse_ev, (GhosttyMods)(mods & 0x0fu));
  GhosttyMousePosition pos = {.x = (float)(x < 0 ? 0 : x), .y = (float)(y < 0 ? 0 : y)};
  ghostty_mouse_event_set_position(t->mouse_ev, pos);

  uint8_t buf[128];
  size_t written = 0;
  if (ghostty_mouse_encoder_encode(t->mouse, t->mouse_ev, buf, sizeof buf, &written) != GHOSTTY_SUCCESS || written == 0)
    return sf_make_bytes(NULL, 0);
  return sf_make_bytes(buf, written);
}

void mb_host_term_close(int32_t id) {
  sf_term *t = sf_term_of(id);
  if (!t) return;
  if (t->drag_anchor) ghostty_tracked_grid_ref_free(t->drag_anchor);
  ghostty_mouse_event_free(t->mouse_ev);
  ghostty_mouse_encoder_free(t->mouse);
  ghostty_render_state_row_cells_free(t->cells);
  ghostty_render_state_row_iterator_free(t->rows);
  ghostty_render_state_free(t->render);
  ghostty_terminal_free(t->term);
  free(t->frame_buf);
  free(t);
  sf_terms[id - 1] = NULL;
}
#endif
