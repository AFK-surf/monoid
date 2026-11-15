// The app's terminals on a device whose build has libghostty-vt (scripts/core.sh puts its headers and library in
// out/core/ghostty-vt; mbui's src/host/term.h is what a host answers without it, its calls weak, these taking their
// place). A terminal: libghostty-vt's, read through its render state as mbui's hostapi/terminal.mbt says the lines
// come: {"cols","rows","cursor":[x,y,shown],"keys","lines":[[["text","#rrggbb"|"","#rrggbb"|"",flags],…],…]}, a run a
// stretch of cells of one look, the cursor's cell inverse where it shows. Built without libghostty-vt's headers this
// file is only its mark.
//
// The mark: the Mac's link asks for it (src/stillfail/moon.pkg's `-Wl,-u,_sf_terminal_linked`), so this file's object
// is taken out of the package's archive. A linker takes an archive's object only for a symbol still undefined, and
// term.h's weak calls define them already: without it the Mac's apps had none of these, so no terminal
// (0.1.9323-0.1.9417).
int sf_terminal_linked = 1;

#if __has_include(<ghostty/vt.h>)
#include <ghostty/vt.h>
#include <moonbit.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  GhosttyTerminal term;
  GhosttyRenderState render;
  GhosttyRenderStateRowIterator rows;
  GhosttyRenderStateRowCells cells;
} sf_term;

// (an app holds a few: one a terminal's page open)
#define SF_TERMS 64
static sf_term *sf_terms[SF_TERMS];

static sf_term *sf_term_of(int32_t id) {
  return id >= 1 && id <= SF_TERMS ? sf_terms[id - 1] : NULL;
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
  if (ghostty_terminal_new(NULL, &t->term, (uint16_t)(cols > 0 ? cols : 1), (uint16_t)(rows > 0 ? rows : 1)) != GHOSTTY_SUCCESS ||
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
  sf_terms[slot] = t;
  return slot + 1;
}

void mb_host_term_write(int32_t id, moonbit_bytes_t data) {
  sf_term *t = sf_term_of(id);
  if (t) ghostty_terminal_vt_write(t->term, data, Moonbit_array_length(data));
}

void mb_host_term_resize(int32_t id, int32_t cols, int32_t rows) {
  sf_term *t = sf_term_of(id);
  // (a cell's pixels are no one's here: only a program asking for them sees it)
  if (t) ghostty_terminal_resize(t->term, (uint16_t)(cols > 0 ? cols : 1), (uint16_t)(rows > 0 ? rows : 1), 8, 16);
}

void mb_host_term_close(int32_t id) {
  sf_term *t = sf_term_of(id);
  if (!t) return;
  ghostty_render_state_row_cells_free(t->cells);
  ghostty_render_state_row_iterator_free(t->rows);
  ghostty_render_state_free(t->render);
  ghostty_terminal_free(t->term);
  free(t);
  sf_terms[id - 1] = NULL;
}

// What the lines are written into: UTF-8, grown as it needs.
typedef struct {
  char *p;
  size_t len, cap;
} sf_out;

static void sf_put(sf_out *o, const char *s, size_t n) {
  if (o->len + n > o->cap) {
    size_t cap = o->cap ? o->cap * 2 : 4096;
    while (cap < o->len + n) cap *= 2;
    char *p = realloc(o->p, cap);
    if (!p) return;
    o->p = p, o->cap = cap;
  }
  memcpy(o->p + o->len, s, n);
  o->len += n;
}

static void sf_puts(sf_out *o, const char *s) { sf_put(o, s, strlen(s)); }

// A JSON string's text: what is not to be written bare escaped.
static void sf_text(sf_out *o, const uint8_t *s, size_t n) {
  for (size_t i = 0; i < n; i++) {
    uint8_t c = s[i];
    if (c == '"' || c == '\\') {
      char e[2] = {'\\', (char)c};
      sf_put(o, e, 2);
    } else if (c < 0x20) {
      char e[8];
      snprintf(e, sizeof e, "\\u%04x", c);
      sf_puts(o, e);
    } else {
      sf_put(o, (const char *)&c, 1);
    }
  }
}

static void sf_colour(sf_out *o, bool has, GhosttyColorRgb c) {
  char e[12];
  if (has) {
    snprintf(e, sizeof e, "\"#%02x%02x%02x\"", c.r, c.g, c.b);
    sf_puts(o, e);
  } else {
    sf_puts(o, "\"\"");
  }
}

// A cell's look: its colours (none: the terminal's own) and its flags (bold 1, italic 2, underline 4, inverse 8,
// faint 16).
typedef struct {
  bool has_fg, has_bg;
  GhosttyColorRgb fg, bg;
  int flags;
} sf_look;

static bool sf_same(const sf_look *a, const sf_look *b) {
  return a->has_fg == b->has_fg && a->has_bg == b->has_bg && a->flags == b->flags &&
         (!a->has_fg || (a->fg.r == b->fg.r && a->fg.g == b->fg.g && a->fg.b == b->fg.b)) &&
         (!a->has_bg || (a->bg.r == b->bg.r && a->bg.g == b->bg.g && a->bg.b == b->bg.b));
}

static void sf_run_end(sf_out *o, const sf_look *l, bool *first) {
  sf_puts(o, "\",");
  sf_colour(o, l->has_fg, l->fg);
  sf_puts(o, ",");
  sf_colour(o, l->has_bg, l->bg);
  char e[16];
  snprintf(e, sizeof e, ",%d]", l->flags);
  sf_puts(o, e);
  *first = false;
}

// The UTF-8 bytes as the app's string (UTF-16).
static moonbit_string_t sf_string(const char *p, size_t len) {
  const uint8_t *b = (const uint8_t *)p;
  uint16_t *tmp = malloc((len ? len : 1) * sizeof(uint16_t));
  size_t n = 0;
  for (size_t i = 0; i < len;) {
    uint32_t c = b[i], cp = 0xfffd;
    size_t k = 1;
    if (c < 0x80) cp = c;
    else if (c >= 0xc2 && c < 0xe0 && i + 1 < len) cp = ((c & 31) << 6) | (b[i + 1] & 63), k = 2;
    else if (c >= 0xe0 && c < 0xf0 && i + 2 < len) cp = ((c & 15) << 12) | ((b[i + 1] & 63) << 6) | (b[i + 2] & 63), k = 3;
    else if (c >= 0xf0 && c < 0xf5 && i + 3 < len)
      cp = ((c & 7) << 18) | ((b[i + 1] & 63) << 12) | ((b[i + 2] & 63) << 6) | (b[i + 3] & 63), k = 4;
    if (cp >= 0x10000) {
      cp -= 0x10000;
      tmp[n++] = (uint16_t)(0xd800 + (cp >> 10));
      tmp[n++] = (uint16_t)(0xdc00 + (cp & 0x3ff));
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

moonbit_string_t mb_host_term_lines(int32_t id) {
  sf_term *t = sf_term_of(id);
  if (!t || ghostty_render_state_update(t->render, t->term) != GHOSTTY_SUCCESS) return moonbit_make_string(0, 0);
  uint16_t cols = 0, rows = 0;
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows);
  bool shown = false, at = false;
  uint16_t cx = 0, cy = 0;
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &shown);
  ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &at);
  if (at) {
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx);
    ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy);
  }
  // (the arrows as ESC O A where the program asked for the cursor keys' application mode: DECCKM; pasted words wrapped
  // in ESC [ 200 ~ … ESC [ 201 ~ where it asked for bracketed paste: ?2004h)
  GhosttyTerminalModeConfig keys = {.mode = GHOSTTY_MODE_CURSOR_KEYS, .value = false};
  ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &keys);
  GhosttyTerminalModeConfig paste = {.mode = GHOSTTY_MODE_BRACKETED_PASTE, .value = false};
  ghostty_terminal_get(t->term, GHOSTTY_TERMINAL_DATA_MODE, &paste);
  sf_out o = {0};
  char head[192];
  snprintf(head, sizeof head, "{\"cols\":%u,\"rows\":%u,\"cursor\":[%u,%u,%s],\"keys\":%d,\"paste\":%d,\"lines\":[", cols, rows, cx, cy,
           shown && at ? "true" : "false", keys.value ? 1 : 0, paste.value ? 1 : 0);
  sf_puts(&o, head);
  if (ghostty_render_state_get(t->render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &t->rows) == GHOSTTY_SUCCESS) {
    bool first_row = true;
    uint16_t y = 0;
    while (ghostty_render_state_row_iterator_next(t->rows)) {
      sf_puts(&o, first_row ? "[" : ",[");
      first_row = false;
      if (ghostty_render_state_row_get(t->rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &t->cells) == GHOSTTY_SUCCESS) {
        bool first = true, open = false;
        sf_look run = {0};
        uint16_t x = 0;
        while (ghostty_render_state_row_cells_next(t->cells)) {
          uint16_t cell_x = x++;
          // (a wide letter's second cell: nothing of its own, the letter before it its width)
          GhosttyCell raw = 0;
          GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
          if (ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
          if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;
          uint8_t text[64];
          GhosttyBuffer buf = {.ptr = text, .cap = sizeof text, .len = 0};
          if (ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buf) != GHOSTTY_SUCCESS)
            buf.len = 0;
          GhosttyStyle style;
          ghostty_style_default(&style);
          ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
          sf_look l = {0};
          l.has_fg = ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &l.fg) == GHOSTTY_SUCCESS;
          l.has_bg = ghostty_render_state_row_cells_get(t->cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &l.bg) == GHOSTTY_SUCCESS;
          l.flags = ((style.flags & GHOSTTY_STYLE_FLAG_BOLD) ? 1 : 0) | ((style.flags & GHOSTTY_STYLE_FLAG_ITALIC) ? 2 : 0) |
                    (GHOSTTY_STYLE_UNDERLINE(style) ? 4 : 0) | ((style.flags & GHOSTTY_STYLE_FLAG_INVERSE) ? 8 : 0) |
                    ((style.flags & GHOSTTY_STYLE_FLAG_FAINT) ? 16 : 0);
          // (the cursor's cell drawn the other way round, a block, where it shows)
          bool cursor = shown && at && y == cy && cell_x == cx;
          if (cursor) l.flags ^= 8;
          // (an empty cell is a space in its look, so the runs keep their columns; one with a ground of its own (the
          // cursor's, a status line's) a no-break space, which a line's end does not let go of as it does the spaces
          // trailing there, so its ground shows to the line's end)
          if (buf.len == 0) {
            if (cursor || l.has_bg || (l.flags & 8)) {
              text[0] = 0xC2, text[1] = 0xA0;
              buf.len = 2;
            } else {
              text[0] = ' ';
              buf.len = 1;
            }
          }
          if (!open || !sf_same(&run, &l)) {
            if (open) sf_run_end(&o, &run, &first);
            sf_puts(&o, first ? "[\"" : ",[\"");
            run = l;
            open = true;
          }
          sf_text(&o, text, buf.len);
        }
        if (open) sf_run_end(&o, &run, &first);
      }
      sf_puts(&o, "]");
      y++;
    }
  }
  sf_puts(&o, "]}");
  moonbit_string_t s = sf_string(o.p ? o.p : "", o.len);
  free(o.p);
  return s;
}
#endif
