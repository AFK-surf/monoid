// Text with DirectWrite: shaping into clusters with their advances, and
// rasterizing each cluster with Direct2D into the RGBA atlas: drawn ahead by
// threads of their own where the app says which it will draw, else when it is
// first drawn. Segoe UI, with Han, kana and CJK punctuation mapped to Microsoft
// YaHei UI ahead of the system fallback (which supplies Segoe UI Emoji).
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <dwrite_3.h>
#include <d2d1.h>
#include <wincodec.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "win.h"

#pragma comment(lib, "dwrite.lib")
#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "user32.lib")

static const WCHAR *FAMILY = L"Segoe UI";
static const WCHAR *MONO = L"Consolas";  // the code face (style & 2)
static const WCHAR *SERIF = L"SimSun";   // the serif face (style & 4): 宋体, its Latin too
static const int RT_SIZE = 512;  // largest cluster bitmap, in pixels

struct ClusterBounds {
  double x0, y0, x1, y1, base;
  int color;
  bool valid;
};

typedef struct {
  int off, len;  // the cluster's text in pool
  double size;
  int weight;
  int style;  // 1 italic, 2 the code face
  double w, h, ox, oy;
  int color;
  // its ink across, from where it starts (punct_ink); known: worked out
  double ink_l, ink_r;
  bool ink_known;
  ClusterBounds bounds;
  uint8_t subs_queued;
} glyph_entry;

static IDWriteFactory2 *dw;
static IDWriteFontFallback *fallback;
static IDWriteRenderingParams *params, *params_gray, *params_ct;
static ID2D1Factory *d2d;
static IWICImagingFactory *wic;
// Where a glyph is drawn: a bitmap of RT_SIZE pixels, Direct2D's target over it at the scale it was made for, white
// and black brushes. The frames' thread has its own (the factories made in init); each thread drawing ahead its own, of
// its own factories (Direct2D's single-threaded one, WIC's).
struct Target {
  ID2D1Factory *d2d;
  IWICImagingFactory *wic;
  IWICBitmap *bitmap;
  ID2D1RenderTarget *rt;
  ID2D1SolidColorBrush *white;
  ID2D1SolidColorBrush *black;
  double scale;
};
static Target main_target;
static double text_scale = 1;
static glyph_entry *entries;
static int n_entries, cap_entries;
static WCHAR *pool;
static size_t pool_len, pool_cap;
static int *table;  // open addressing: entry index + 1, 0 is empty
static size_t table_cap;
static int generation;
// the glyph drawn last (mb_host_glyph), its picture until it is put in the atlas (mb_host_glyph_put)
static int held_key = -1, held_w, held_h;
static uint8_t *held_px;
static struct { double size; int weight; int style; IDWriteTextFormat *f; } formats[32];
static int n_formats;

// Whether a monitor's EDID friendly name names an OLED panel (or a known QD-OLED / WOLED model whose EDID omits
// "OLED"), whose triangular or RWBG subpixels do not match ClearType's horizontal RGB stripes.
static bool is_oled_name(const WCHAR *name) {
  static const WCHAR *const tags[] = {
      L"OLED",     L"AW3225",   L"AW2725",   L"AW3423",   L"PG32UCD",  L"PG27AQD",  L"PG27UCD",  L"PG34WCD",
      L"XG27AQD",  L"MPG 321",  L"MPG 271",  L"MAG 321",  L"MAG 271",  L"MPG 341",  L"FO32U",    L"FO27Q",
      L"MO34WQC",  L"G80SD",    L"G60SD",    L"32GS95",   L"27GS95",   L"27GR95",   L"34GS95",   L"39GS95",
      L"45GS95",   L"LG TV",
  };
  for (size_t k = 0; k < sizeof tags / sizeof tags[0]; k++) {
    const WCHAR *t = tags[k];
    size_t tlen = wcslen(t);
    for (const WCHAR *p = name; *p; p++) {
      if (_wcsnicmp(p, t, tlen) == 0) return true;
    }
  }
  return false;
}

// Subpixel geometry of the machine's active display: FLAT when an active physical monitor is an OLED panel or when a
// physical monitor is attached and the user turned ClearType off in Windows; BGR when configured so; else RGB.
static DWRITE_PIXEL_GEOMETRY detect_pixel_geometry(void) {
  bool has_edid_monitor = false;
  bool has_oled = false;
  UINT32 np = 0, nm = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) == ERROR_SUCCESS && np > 0) {
    DISPLAYCONFIG_PATH_INFO *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(np, sizeof *paths);
    DISPLAYCONFIG_MODE_INFO *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(nm, sizeof *modes);
    if (paths && modes && QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) == ERROR_SUCCESS) {
      for (UINT32 i = 0; i < np; i++) {
        DISPLAYCONFIG_TARGET_DEVICE_NAME tn = {};
        tn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tn.header.size = sizeof tn;
        tn.header.adapterId = paths[i].targetInfo.adapterId;
        tn.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tn.header) == ERROR_SUCCESS && tn.flags.edidIdsValid) {
          has_edid_monitor = true;
          if (is_oled_name(tn.monitorFriendlyDeviceName)) has_oled = true;
        }
      }
    }
    free(paths);
    free(modes);
  }
  if (has_oled) return DWRITE_PIXEL_GEOMETRY_FLAT;
  if (has_edid_monitor) {
    BOOL smoothing = TRUE;
    UINT type = FE_FONTSMOOTHINGCLEARTYPE;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHING, 0, &smoothing, 0) && !smoothing) return DWRITE_PIXEL_GEOMETRY_FLAT;
    if (SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE, 0, &type, 0) && type != FE_FONTSMOOTHINGCLEARTYPE)
      return DWRITE_PIXEL_GEOMETRY_FLAT;
    IDWriteRenderingParams *sys = NULL;
    if (SUCCEEDED(dw->CreateRenderingParams(&sys)) && sys) {
      DWRITE_PIXEL_GEOMETRY g = sys->GetPixelGeometry();
      FLOAT ct = sys->GetClearTypeLevel();
      sys->Release();
      if (g == DWRITE_PIXEL_GEOMETRY_FLAT || ct <= 0.0f) return DWRITE_PIXEL_GEOMETRY_FLAT;
      if (g == DWRITE_PIXEL_GEOMETRY_BGR) return DWRITE_PIXEL_GEOMETRY_BGR;
    }
  }
  return DWRITE_PIXEL_GEOMETRY_RGB;
}

static bool use_cleartype(double sc) { return params_ct != NULL && sc < 1.25; }

static void init(void) {
  if (dw) return;
  DWriteCreateFactory(DWRITE_FACTORY_TYPE_ISOLATED, __uuidof(IDWriteFactory2), (IUnknown **)&dw);
  IDWriteFontFallbackBuilder *b = NULL;
  IDWriteFontFallback *sys = NULL;
  dw->CreateFontFallbackBuilder(&b);
  DWRITE_UNICODE_RANGE cjk[] = {
      {0x2E80, 0x2FDF}, {0x3000, 0x31FF}, {0x3200, 0x4DBF},   {0x4E00, 0x9FFF},
      {0xF900, 0xFAFF}, {0xFE30, 0xFE4F}, {0xFF00, 0xFFEF}, {0x20000, 0x3FFFF},
  };
  const WCHAR *cjk_fonts[] = {L"Microsoft YaHei UI", L"Microsoft YaHei", L"SimSun"};
  b->AddMapping(cjk, sizeof cjk / sizeof cjk[0], cjk_fonts, 3, NULL, NULL, NULL, 1.0f);
  dw->GetSystemFontFallback(&sys);
  b->AddMappings(sys);
  b->CreateFontFallback(&fallback);
  sys->Release();
  b->Release();
  // the font's own features, ligatures with them, as DirectWrite draws any app's text: a ligature is one
  // cluster of its letters (GetClusterMetrics), drawn whole
  // plain coverage without contrast boost for colour glyphs (emojis)
  IDWriteRenderingParams2 *p2 = NULL;
  dw->CreateCustomRenderingParams(1.0f, 0.0f, 0.0f, 0.0f, DWRITE_PIXEL_GEOMETRY_FLAT,
                                  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
                                  DWRITE_GRID_FIT_MODE_DISABLED, &p2);
  params = p2;
  // Monochrome text in grayscale (used at 125%+ high-DPI scaling, on OLED panels, or when ClearType is off in Windows):
  // unhinted geometric outlines as in macOS CoreText (DWRITE_GRID_FIT_MODE_DISABLED, so legacy CJK TrueType hinting
  // bytecode does not pinch or distort stroke weights across rows) with symmetric 6x5 antialiasing
  // (DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC) and optical stem darkening (contrast 0.45 at linear gamma 1.0).
  IDWriteRenderingParams2 *g2 = NULL;
  dw->CreateCustomRenderingParams(1.0f, 0.45f, 0.45f, 0.0f, DWRITE_PIXEL_GEOMETRY_FLAT,
                                  DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_GRID_FIT_MODE_DISABLED, &g2);
  params_gray = g2;
  // A glyph in one colour drawn with ClearType at < 150% on an RGB/BGR LCD: each of a pixel's three stripes covered on
  // its own, with unhinted geometric outlines, symmetric 6x5 antialiasing, and optical stem darkening (contrast 0.35)
  // at linear gamma (1.0).
  DWRITE_PIXEL_GEOMETRY geom = detect_pixel_geometry();
  if (geom != DWRITE_PIXEL_GEOMETRY_FLAT) {
    IDWriteRenderingParams2 *c2 = NULL;
    dw->CreateCustomRenderingParams(1.0f, 0.35f, 0.35f, 1.0f, geom,
                                    DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_GRID_FIT_MODE_DISABLED, &c2);
    params_ct = c2;
  }
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), NULL, (void **)&d2d);
  CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory),
                   (void **)&wic);
  main_target.d2d = d2d;
  main_target.wic = wic;
}

// The faces given (mb_host_face_add, style.mbt): each its files, made into a collection of their own (DirectWrite's
// font set from the files: a variable file's named weights in it), and the family the files make.
#define MB_FACES 16
static struct {
  WCHAR **paths;  // a file's path, or NULL: its bytes (data, sizes)
  void **data;
  UINT32 *sizes;
  int n;
  IDWriteFontCollection1 *fc;
  WCHAR family[128];
  bool system;  // a family installed here (mb_host_face_add_family): the system's collection, no files of its own
} faces[MB_FACES];
// fonts given as bytes: DirectWrite's in-memory loader (it keeps a copy of each)
static IDWriteInMemoryFontFileLoader *mem_loader;

// The face a style is set in: the one it names; else code's (style & 2), what people wrote's (style & 16), the app's
// words' (not the serif face's); 0 none given.
static bool face_has(int f) { return faces[f].fc || faces[f].system; }

static int face_id(int style) {
  int f = (style >> 8) & 15;
  if (f > 0) return face_has(f) ? f : 0;
  if (style & 2) return face_has(3) ? 3 : 0;
  if ((style & 16) && face_has(2)) return 2;
  if (style & 4) return 0;
  return face_has(1) ? 1 : 0;
}

// Face `f`'s files as a collection, its family's name from it (false: not fonts DirectWrite reads).
static bool face_build(int f) {
  IDWriteFactory5 *dw5 = NULL;
  if (FAILED(dw->QueryInterface(__uuidof(IDWriteFactory5), (void **)&dw5))) return false;
  IDWriteFontSetBuilder1 *b = NULL;
  IDWriteFontSet *set = NULL;
  IDWriteFontCollection1 *fc = NULL;
  IDWriteFontFamily1 *fam = NULL;
  IDWriteLocalizedStrings *names = NULL;
  bool ok = SUCCEEDED(dw5->CreateFontSetBuilder(&b));
  for (int i = 0; ok && i < faces[f].n; i++) {
    IDWriteFontFile *file = NULL;
    if (faces[f].paths[i]) {
      ok = SUCCEEDED(dw5->CreateFontFileReference(faces[f].paths[i], NULL, &file));
    } else {
      if (!mem_loader && SUCCEEDED(dw5->CreateInMemoryFontFileLoader(&mem_loader))) dw5->RegisterFontFileLoader(mem_loader);
      ok = mem_loader && SUCCEEDED(mem_loader->CreateInMemoryFontFileReference(dw5, faces[f].data[i], faces[f].sizes[i], NULL, &file));
    }
    ok = ok && SUCCEEDED(b->AddFontFile(file));
    if (file) file->Release();
  }
  ok = ok && SUCCEEDED(b->CreateFontSet(&set)) && SUCCEEDED(dw5->CreateFontCollectionFromFontSet(set, &fc)) &&
       fc->GetFontFamilyCount() > 0 && SUCCEEDED(fc->GetFontFamily(0, &fam)) && SUCCEEDED(fam->GetFamilyNames(&names)) &&
       SUCCEEDED(names->GetString(0, faces[f].family, 128));
  if (ok) {
    if (faces[f].fc) faces[f].fc->Release();
    faces[f].fc = fc;
    faces[f].system = false;
    fc = NULL;
  }
  if (names) names->Release();
  if (fam) fam->Release();
  if (fc) fc->Release();
  if (set) set->Release();
  if (b) b->Release();
  dw5->Release();
  return ok;
}

static void faces_changed(void);

// A file of face `f`: its path, or its bytes (path NULL); made part of it if DirectWrite reads them as a font.
static int32_t face_take(int32_t f, WCHAR *path, void *data, UINT32 size) {
  init();
  if (f <= 0 || f >= MB_FACES) {
    free(path);
    free(data);
    return 0;
  }
  int n = faces[f].n;
  faces[f].paths = (WCHAR **)realloc(faces[f].paths, sizeof(WCHAR *) * (n + 1));
  faces[f].data = (void **)realloc(faces[f].data, sizeof(void *) * (n + 1));
  faces[f].sizes = (UINT32 *)realloc(faces[f].sizes, sizeof(UINT32) * (n + 1));
  faces[f].paths[n] = path;
  faces[f].data[n] = data;
  faces[f].sizes[n] = size;
  faces[f].n = n + 1;
  if (!face_build(f)) {
    faces[f].n = n;
    free(path);
    free(data);
    return 0;
  }
  faces_changed();
  return 1;
}

extern "C" int32_t mb_host_face_add(int32_t f, moonbit_string_t path, int32_t weight) {
  (void)weight;  // the files' own weights say which is which (a variable file: its named instances)
  int len = Moonbit_array_length(path);
  WCHAR *p = (WCHAR *)malloc(sizeof(WCHAR) * (len + 1));
  memcpy(p, path, sizeof(WCHAR) * len);
  p[len] = 0;
  return face_take(f, p, NULL, 0);
}

extern "C" int32_t mb_host_face_add_bytes(int32_t f, moonbit_bytes_t data, int32_t weight) {
  (void)weight;
  UINT32 size = (UINT32)Moonbit_array_length(data);
  void *copy = malloc(size);
  memcpy(copy, data, size);
  return face_take(f, NULL, copy, size);
}

extern "C" void mb_host_face_clear(int32_t f) {
  if (f <= 0 || f >= MB_FACES || !face_has(f)) return;
  for (int i = 0; i < faces[f].n; i++) {
    free(faces[f].paths[i]);
    free(faces[f].data[i]);
  }
  faces[f].n = 0;
  if (faces[f].fc) faces[f].fc->Release();
  faces[f].fc = NULL;
  faces[f].system = false;
  faces_changed();
}

// The system's font collection's family named `name` (its index), if there is one.
static bool system_family(const WCHAR *name) {
  IDWriteFontCollection *fc = NULL;
  if (FAILED(dw->GetSystemFontCollection(&fc, FALSE))) return false;
  UINT32 at = 0;
  BOOL there = FALSE;
  fc->FindFamilyName(name, &at, &there);
  fc->Release();
  return there;
}

// Face `f` set in the family installed here named `family`: the system's collection, by its name.
extern "C" int32_t mb_host_face_add_family(int32_t f, moonbit_string_t family) {
  init();
  int len = Moonbit_array_length(family);
  if (f <= 0 || f >= MB_FACES || len <= 0 || len >= 128) return 0;
  WCHAR name[128];
  memcpy(name, family, sizeof(WCHAR) * len);
  name[len] = 0;
  if (!system_family(name)) return 0;
  for (int i = 0; i < faces[f].n; i++) {
    free(faces[f].paths[i]);
    free(faces[f].data[i]);
  }
  faces[f].n = 0;
  if (faces[f].fc) faces[f].fc->Release();
  faces[f].fc = NULL;
  memcpy(faces[f].family, name, sizeof(name));
  faces[f].system = true;
  faces_changed();
  return 1;
}

// The font families installed here, as a JSON array of their names (each its name in the user's language, else its
// first), sorted as the collection has them.
// the user's locale, the families' names are shown and sorted in
static WCHAR names_locale[LOCALE_NAME_MAX_LENGTH];

static int name_order(const void *a, const void *b) {
  return CompareStringEx(names_locale[0] ? names_locale : NULL, LINGUISTIC_IGNORECASE, *(const WCHAR *const *)a, -1,
                         *(const WCHAR *const *)b, -1, NULL, NULL, 0) - CSTR_EQUAL;
}

extern "C" moonbit_string_t mb_host_local_font_families(void) {
  init();
  IDWriteFontCollection *fc = NULL;
  if (FAILED(dw->GetSystemFontCollection(&fc, FALSE))) return moonbit_make_string_raw(0);
  if (!GetUserDefaultLocaleName(names_locale, LOCALE_NAME_MAX_LENGTH)) names_locale[0] = 0;
  UINT32 count = fc->GetFontFamilyCount();
  WCHAR **all = (WCHAR **)calloc(count ? count : 1, sizeof(WCHAR *));
  UINT32 had = 0;
  for (UINT32 i = 0; i < count; i++) {
    IDWriteFontFamily *fam = NULL;
    IDWriteLocalizedStrings *names = NULL;
    WCHAR name[256];
    name[0] = 0;
    if (SUCCEEDED(fc->GetFontFamily(i, &fam)) && SUCCEEDED(fam->GetFamilyNames(&names))) {
      UINT32 at = 0;
      BOOL there = FALSE;
      if (names_locale[0]) names->FindLocaleName(names_locale, &at, &there);
      if (!there) at = 0;
      UINT32 len = 0;
      if (SUCCEEDED(names->GetStringLength(at, &len)) && len < 255) names->GetString(at, name, 256);
    }
    if (names) names->Release();
    if (fam) fam->Release();
    if (name[0]) all[had++] = _wcsdup(name);
  }
  fc->Release();
  // in the order of the user's language, as the web's localeCompare
  qsort(all, had, sizeof(WCHAR *), name_order);
  size_t cap = 4096, n = 0;
  WCHAR *out = (WCHAR *)malloc(sizeof(WCHAR) * cap);
  out[n++] = L'[';
  for (UINT32 i = 0; i < had; i++) {
    const WCHAR *name = all[i];
    size_t len = wcslen(name);
    // its name as a JSON string: a quote and a backslash escaped, the rest as it is
    if (n + 2 * len + 4 >= cap) {
      cap = (n + 2 * len + 4) * 2;
      out = (WCHAR *)realloc(out, sizeof(WCHAR) * cap);
    }
    if (n > 1) out[n++] = L',';
    out[n++] = L'"';
    for (size_t k = 0; k < len; k++) {
      if (name[k] == L'"' || name[k] == L'\\') out[n++] = L'\\';
      out[n++] = name[k] < 0x20 ? L' ' : name[k];
    }
    out[n++] = L'"';
    free(all[i]);
  }
  free(all);
  out[n++] = L']';
  moonbit_string_t s = moonbit_make_string_raw((int32_t)n);
  memcpy(s, out, sizeof(WCHAR) * n);
  free(out);
  return s;
}

static IDWriteTextFormat *format_for(double size, int weight, int style) {
  for (int i = 0; i < n_formats; i++)
    if (formats[i].size == size && formats[i].weight == weight && formats[i].style == style) return formats[i].f;
  IDWriteTextFormat *f = NULL;
  int face = face_id(style);
  dw->CreateTextFormat(face ? faces[face].family : (style & 2) ? MONO : (style & 4) ? SERIF : FAMILY,
                       face && faces[face].fc ? faces[face].fc : NULL, (DWRITE_FONT_WEIGHT)weight,
                       (style & 1) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
                       DWRITE_FONT_STRETCH_NORMAL, (FLOAT)size, L"zh-cn", &f);
  f->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  if (n_formats == 32) {
    formats[0].f->Release();
    formats[0] = formats[--n_formats];
  }
  formats[n_formats].size = size;
  formats[n_formats].weight = weight;
  formats[n_formats].style = style;
  formats[n_formats++].f = f;
  return f;
}

// style & 8: no ligatures (words with letter spacing, each cluster spaced on its own): liga and clig off; style & 32:
// digits all one width (style.mbt style_tabular): tnum; style & 64: a CJK face's marks narrow among Latin letters
// (style.mbt style_proportional): pwid. One typography for each of the ways they go together.
static IDWriteTypography *typographies[8];

// the typography of a style's features (NULL: none, the font's own)
static IDWriteTypography *typography_for(int style) {
  int k = ((style & 8) ? 1 : 0) | ((style & 32) ? 2 : 0) | ((style & 64) ? 4 : 0);
  if (!k) return NULL;
  if (!typographies[k]) {
    IDWriteTypography *t = NULL;
    dw->CreateTypography(&t);
    if (k & 1) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_STANDARD_LIGATURES, 0});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_CONTEXTUAL_LIGATURES, 0});
    }
    if (k & 2) t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, 1});
    // (kern said again: DirectWrite sets a range with pwid unkerned otherwise, quotes round "Wo" 3 pt wider at 20)
    if (k & 4) {
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_PROPORTIONAL_WIDTHS, 1});
      t->AddFontFeature({DWRITE_FONT_FEATURE_TAG_KERNING, 1});
    }
    typographies[k] = t;
  }
  return typographies[k];
}

static void set_style_features(IDWriteTextLayout *l, int len, int style) {
  IDWriteTypography *t = typography_for(style);
  if (t) l->SetTypography(t, {0, (UINT32)len});
}

static IDWriteTextLayout *make_layout(const WCHAR *s, int len, double size, int weight, int style) {
  IDWriteTextLayout *l = NULL;
  dw->CreateTextLayout(s, (UINT32)len, format_for(size, weight, style), 1e6f, 1e6f, &l);
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  set_style_features(l, len, style);
  return l;
}

#define LAYOUT_CACHE_CAP 256
static struct {
  int key;
  IDWriteTextLayout *l;
} layout_cache[LAYOUT_CACHE_CAP];
static bool layout_cache_inited;

static void layout_cache_clear(void) {
  for (int i = 0; i < LAYOUT_CACHE_CAP; i++) {
    if (layout_cache[i].l) layout_cache[i].l->Release();
    layout_cache[i].l = NULL;
    layout_cache[i].key = -1;
  }
  layout_cache_inited = true;
}

static IDWriteTextLayout *main_layout_for(int key) {
  if (!layout_cache_inited) layout_cache_clear();
  int slot = key & (LAYOUT_CACHE_CAP - 1);
  if (layout_cache[slot].key == key && layout_cache[slot].l) return layout_cache[slot].l;
  if (layout_cache[slot].l) layout_cache[slot].l->Release();
  glyph_entry *e = &entries[key];
  IDWriteTextLayout *l = make_layout(pool + e->off, e->len, e->size, e->weight, e->style);
  layout_cache[slot].key = key;
  layout_cache[slot].l = l;
  return l;
}

// A family's metrics at this weight and style (false: not on this system, `m` as it was); in a face's collection
// where one is given.
static bool family_metrics(const WCHAR *name, int weight, int style, DWRITE_FONT_METRICS *m, IDWriteFontCollection *in = NULL) {
  IDWriteFontCollection *fc = NULL;
  IDWriteFontFamily *fam = NULL;
  IDWriteFont *font = NULL;
  UINT32 i = 0;
  BOOL found = FALSE;
  bool ok = false;
  if (in) {
    fc = in;
    fc->AddRef();
  } else {
    dw->GetSystemFontCollection(&fc, FALSE);
  }
  if (SUCCEEDED(fc->FindFamilyName(name, &i, &found)) && found && SUCCEEDED(fc->GetFontFamily(i, &fam)) &&
      SUCCEEDED(fam->GetFirstMatchingFont((DWRITE_FONT_WEIGHT)weight, DWRITE_FONT_STRETCH_NORMAL,
                                          (style & 1) ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, &font))) {
    font->GetMetrics(m);
    ok = true;
  }
  if (font) font->Release();
  if (fam) fam->Release();
  fc->Release();
  return ok;
}

extern "C" void mb_host_font_metrics(double size, int32_t weight, int32_t style, double *out) {
  init();
  DWRITE_FONT_METRICS m = {};
  m.designUnitsPerEm = 2048;
  m.ascent = 2210;
  m.descent = 514;
  int face = face_id(style);
  if (face) family_metrics(faces[face].family, weight, style, &m, faces[face].fc);
  else family_metrics((style & 2) ? MONO : (style & 4) ? SERIF : FAMILY, weight, style, &m);
  out[0] = size * m.ascent / m.designUnitsPerEm;
  out[1] = size * m.descent / m.designUnitsPerEm;
  out[2] = round(size * 1.42);
  // the face Han falls back to (Chinese Windows' UI font): a line with Chinese in it is measured by the taller
  DWRITE_FONT_METRICS h = m;
  family_metrics(L"Microsoft YaHei UI", weight, style, &h);
  out[3] = size * h.ascent / h.designUnitsPerEm;
  out[4] = size * h.descent / h.designUnitsPerEm;
  out[5] = 0;  // lines as asked, not on whole pixels
}

static uint32_t hash(const WCHAR *s, int len, double size, int weight, int style) {
  uint32_t h = 2166136261u;
  for (int i = 0; i < len; i++) h = (h ^ s[i]) * 16777619u;
  h = (h ^ (uint32_t)(size * 64)) * 16777619u;
  h = (h ^ (uint32_t)style) * 16777619u;
  return (h ^ (uint32_t)weight) * 16777619u;
}

static int same(const glyph_entry *e, const WCHAR *s, int len, double size, int weight, int style) {
  return e->len == len && e->size == size && e->weight == weight && e->style == style &&
         memcmp(pool + e->off, s, (size_t)len * sizeof(WCHAR)) == 0;
}

static void table_put(int id) {
  glyph_entry *e = &entries[id];
  size_t i = hash(pool + e->off, e->len, e->size, e->weight, e->style) & (table_cap - 1);
  while (table[i]) i = (i + 1) & (table_cap - 1);
  table[i] = id + 1;
}

static int intern(const WCHAR *s, int len, double size, int weight, int style) {
  if (table_cap) {
    size_t i = hash(s, len, size, weight, style) & (table_cap - 1);
    for (; table[i]; i = (i + 1) & (table_cap - 1))
      if (same(&entries[table[i] - 1], s, len, size, weight, style)) return table[i] - 1;
  }
  if (n_entries == cap_entries) {
    cap_entries = cap_entries ? cap_entries * 2 : 1024;
    entries = (glyph_entry *)realloc(entries, sizeof(glyph_entry) * cap_entries);
  }
  if (pool_len + len > pool_cap) {
    pool_cap = (pool_len + len) * 2 + 4096;
    pool = (WCHAR *)realloc(pool, pool_cap * sizeof(WCHAR));
  }
  memcpy(pool + pool_len, s, (size_t)len * sizeof(WCHAR));
  int id = n_entries++;
  glyph_entry ge = {};
  ge.off = (int)pool_len;
  ge.len = len;
  ge.size = size;
  ge.weight = weight;
  ge.style = style;
  entries[id] = ge;
  pool_len += len;
  if ((size_t)n_entries * 2 > table_cap) {
    free(table);
    table_cap = table_cap ? table_cap * 2 : 4096;
    table = (int *)calloc(table_cap, sizeof(int));
    for (int j = 0; j < n_entries; j++) table_put(j);
  } else {
    table_put(id);
  }
  return id;
}

// CJK punctuation two in a row set solid, as Core Text sets it on the Apple hosts (and DirectWrite would, for a font
// with chws: Microsoft YaHei, the fallback Han is drawn in, has neither chws nor halt, so "），" stood a whole empty
// half em apart). 1: a closing mark or a pause (，。、：；and the closing brackets), its ink in its first half in a
// Simplified Chinese font; 2: an opening bracket, its ink in its second half. ！？ and the quotes (narrow in YaHei)
// are left as they are.
static int punct_kind(WCHAR c) {
  switch (c) {
    case 0xFF0C: case 0x3002: case 0x3001: case 0xFF1A: case 0xFF1B: case 0xFF0E:
    case 0xFF09: case 0x300D: case 0x300F: case 0x3011: case 0x300B: case 0x3009: case 0x3015: case 0xFF3D:
    case 0xFF5D:
      return 1;
    case 0xFF08: case 0x300C: case 0x300E: case 0x3010: case 0x300A: case 0x3008: case 0x3014: case 0xFF3B:
    case 0xFF5B:
      return 2;
  }
  return 0;
}

// Where glyph `key`'s ink is across, from where it starts: worked out once, from the face it is drawn in.
static void punct_ink(int key) {
  glyph_entry *e = &entries[key];
  if (e->ink_known) return;
  IDWriteTextLayout *l = main_layout_for(key);
  DWRITE_TEXT_METRICS tm;
  DWRITE_OVERHANG_METRICS om;
  l->GetMetrics(&tm);
  l->SetMaxWidth(tm.widthIncludingTrailingWhitespace);
  l->SetMaxHeight(tm.height);
  l->GetOverhangMetrics(&om);
  e->ink_l = -om.left;
  e->ink_r = tm.widthIncludingTrailingWhitespace + om.right;
  e->ink_known = true;
}

// Each pair of full-width marks in a line's clusters (out, as mb_host_shape gives them): the first's advance a half
// em less where its ink still ends before the second's begins (a closing mark's empty second half; before an opening
// bracket, that bracket's empty first half), as chws sets them. An opening bracket then a closing one ("（）") is
// left.
static void punct_solid(const WCHAR *s, double size, double *out, int32_t k) {
  double half = size / 2, tol = size * 0.05;
  for (int32_t i = 0; i + 1 < k; i++) {
    int a = (int)out[i * 4 + 3], b = (int)out[(i + 1) * 4 + 3];
    if (a < 0 || b < 0 || out[i * 4 + 1] != 1 || out[(i + 1) * 4 + 1] != 1) continue;
    int ka = punct_kind(s[(int)out[i * 4]]), kb = punct_kind(s[(int)out[(i + 1) * 4]]);
    if (!ka || !kb || (ka == 2 && kb == 1)) continue;
    double adv = out[i * 4 + 2];
    if (fabs(adv - size) > tol || fabs(out[(i + 1) * 4 + 2] - size) > tol) continue;
    punct_ink(a);
    punct_ink(b);
    if (entries[a].ink_r <= adv - half + entries[b].ink_l + tol) out[i * 4 + 2] = adv - half;
  }
}

extern "C" int32_t mb_host_shape(moonbit_string_t text, double size, int32_t weight, int32_t style, double *out) {
  init();
  int32_t len = Moonbit_array_length(text);
  int32_t cap = Moonbit_array_length(out) / 4;
  const WCHAR *s = (const WCHAR *)text;
  IDWriteTextLayout *l = make_layout(s, len, size, weight, style);
  static DWRITE_CLUSTER_METRICS *cm;
  static UINT32 cm_cap;
  UINT32 n = 0;
  if (l->GetClusterMetrics(cm, cm_cap, &n) == E_NOT_SUFFICIENT_BUFFER) {
    cm_cap = n * 2;
    cm = (DWRITE_CLUSTER_METRICS *)realloc(cm, cm_cap * sizeof *cm);
    l->GetClusterMetrics(cm, cm_cap, &n);
  }
  int32_t k = 0, pos = 0;
  for (UINT32 i = 0; i < n && k < cap; i++) {
    int clen = cm[i].length;
    WCHAR c = s[pos];
    double adv = cm[i].width;
    int key;
    if (c == '\n' || cm[i].isNewline) {
      adv = 0;
      key = -1;
    } else if (c == ' ' || c == '\t') {
      key = -1;
    } else {
      key = intern(s + pos, clen, size, weight, style);
    }
    out[k * 4] = pos;
    out[k * 4 + 1] = clen;
    out[k * 4 + 2] = adv < 0 ? 0 : adv;
    out[k * 4 + 3] = key;
    k++;
    pos += clen;
  }
  l->Release();
  punct_solid(s, size, out, k);
  return k;
}

// The key of a piece of text drawn whole (a word of a joining script): host_native.mbt's text_key.
extern "C" int32_t mb_host_text_key(moonbit_string_t text, double size, int32_t weight, int32_t style) {
  init();
  return intern((const WCHAR *)text, Moonbit_array_length(text), size, weight, style);
}

extern "C" int32_t mb_host_atlas_generation(void) { return generation; }

// (one atlas: colour glyphs in it with the others)
extern "C" int32_t mb_host_atlas_size(int32_t colour) { return colour ? 0 : mb_atlas_size; }

// What was drawn before is drawn again: MoonBit drops its glyphs as the generation moves on.
static void reset_atlas(void) {
  generation++;
}

// What was measured and drawn before a face changed: its formats made again, its glyphs drawn again.
static void ahead_forget(void);

static void faces_changed(void) {
  layout_cache_clear();
  for (int i = 0; i < n_formats; i++) formats[i].f->Release();
  n_formats = 0;
  for (int i = 0; i < n_entries; i++) {
    entries[i].ink_known = false;
    entries[i].bounds = {};
    entries[i].subs_queued = 0;
  }
  ahead_forget();
  reset_atlas();
}

extern "C" void mb_text_set_scale(double scale) {
  if (scale == text_scale) return;
  text_scale = scale;
  ahead_forget();
  reset_atlas();
}

// Draws nothing; tells whether any run of a layout comes from a color font
// (emoji), the way the Core Text host checks kCTFontTraitColorGlyphs.
struct ColorProbe : public IDWriteTextRenderer {
  int color = 0;
  STDMETHOD(QueryInterface)(REFIID iid, void **o) override {
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IDWritePixelSnapping) ||
        iid == __uuidof(IDWriteTextRenderer)) {
      *o = this;
      return S_OK;
    }
    *o = NULL;
    return E_NOINTERFACE;
  }
  STDMETHOD_(ULONG, AddRef)() override { return 1; }
  STDMETHOD_(ULONG, Release)() override { return 1; }
  STDMETHOD(IsPixelSnappingDisabled)(void *, BOOL *d) override {
    *d = TRUE;
    return S_OK;
  }
  STDMETHOD(GetCurrentTransform)(void *, DWRITE_MATRIX *m) override {
    *m = {1, 0, 0, 1, 0, 0};
    return S_OK;
  }
  STDMETHOD(GetPixelsPerDip)(void *, FLOAT *p) override {
    *p = 1;
    return S_OK;
  }
  STDMETHOD(DrawGlyphRun)(void *, FLOAT x, FLOAT y, DWRITE_MEASURING_MODE mode, DWRITE_GLYPH_RUN const *run,
                          DWRITE_GLYPH_RUN_DESCRIPTION const *desc, IUnknown *) override {
    IDWriteColorGlyphRunEnumerator *runs = NULL;
    if (SUCCEEDED(dw->TranslateColorGlyphRun(x, y, run, desc, mode, NULL, 0, &runs))) {
      color = 1;
      runs->Release();
    }
    return S_OK;
  }
  STDMETHOD(DrawUnderline)(void *, FLOAT, FLOAT, DWRITE_UNDERLINE const *, IUnknown *) override {
    return S_OK;
  }
  STDMETHOD(DrawStrikethrough)(void *, FLOAT, FLOAT, DWRITE_STRIKETHROUGH const *, IUnknown *) override {
    return S_OK;
  }
  STDMETHOD(DrawInlineObject)(void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL, IUnknown *) override {
    return S_OK;
  }
};

static void target_ensure(Target *t, double scale) {
  if (t->rt && t->scale == scale) return;
  if (t->white) t->white->Release();
  if (t->black) t->black->Release();
  if (t->rt) t->rt->Release();
  t->white = NULL;
  t->black = NULL;
  t->rt = NULL;
  if (!t->bitmap && FAILED(t->wic->CreateBitmap(RT_SIZE, RT_SIZE, GUID_WICPixelFormat32bppPBGRA,
                                                  WICBitmapCacheOnDemand, &t->bitmap)))
    return;
  float dpi = (float)(96.0 * scale);
  D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
  if (FAILED(t->d2d->CreateWicBitmapRenderTarget(t->bitmap, &p, &t->rt))) return;
  t->rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  t->rt->SetTextRenderingParams(params);
  t->rt->CreateSolidColorBrush(D2D1::ColorF(1, 1, 1, 1), &t->white);
  t->rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &t->black);
  t->scale = scale;
}

// A cluster drawn: its picture (pw × ph pixels, RGBA, NULL none), its box in points as its entry has it, whether it is
// in its own colours (an emoji)
struct Drawn {
  int pw, ph;
  uint8_t *px;
  double w, h, ox, oy;
  int color;
};

static inline float px_at(const float *buf, int pw, int ph, int x, int y) {
  if (x < 0 || x >= pw || y < 0 || y >= ph) return 0.0f;
  return buf[y * pw + x];
}

// Optical stem darkening and cross-row/cross-column stem convergence for grayscale unhinted glyphs (as in macOS
// CoreGraphics font smoothing + CFF hstem/vstem alignment): when an unhinted horizontal or vertical stem at 1.25x/1.5x
// straddles two adjacent pixel rows or columns (flanked by open counter space), concentrates coverage into the dominant
// row/column so stems keep a solid black core without blurring or distorting diagonals.
static void enhance_gray_stems(uint8_t *px, int pw, int ph) {
  if (pw <= 1 || ph <= 1) return;
  size_t n = (size_t)pw * ph;
  float *f = (float *)malloc(sizeof(float) * n);
  float *tmp = (float *)malloc(sizeof(float) * n);
  if (!f || !tmp) {
    free(f);
    free(tmp);
    return;
  }
  for (size_t i = 0; i < n; i++) f[i] = px[i * 4 + 3] / 255.0f;

  // Step 1: subtle isotropic edge dilation (~0.06px radius, matching CoreGraphics font smoothing)
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      float c = f[y * pw + x];
      if (c > 0.01f && c < 0.99f) {
        float m = c;
        float l = px_at(f, pw, ph, x - 1, y), r = px_at(f, pw, ph, x + 1, y);
        float u = px_at(f, pw, ph, x, y - 1), d = px_at(f, pw, ph, x, y + 1);
        if (l > m) m = l;
        if (r > m) m = r;
        if (u > m) m = u;
        if (d > m) m = d;
        c = fminf(1.0f, c * 1.06f + 0.06f * m);
      }
      tmp[y * pw + x] = c;
    }
  }
  memcpy(f, tmp, sizeof(float) * n);

  // Step 2: vertical pass (horizontal stems straddling rows y and y+1)
  for (int y = 0; y < ph - 1; y++) {
    for (int x = 0; x < pw; x++) {
      float u = px_at(f, pw, ph, x, y - 1);
      float p0 = f[y * pw + x];
      float p1 = f[(y + 1) * pw + x];
      float d = px_at(f, pw, ph, x, y + 2);
      if (p0 > 0.25f && p1 > 0.25f && u < 0.22f && d < 0.22f) {
        float l_in = px_at(f, pw, ph, x - 1, y) + px_at(f, pw, ph, x - 1, y + 1);
        float r_in = px_at(f, pw, ph, x + 1, y) + px_at(f, pw, ph, x + 1, y + 1);
        if (l_in > 0.50f || r_in > 0.50f) {
          float shift = 0.42f * fminf(p0, p1);
          if (p0 >= p1) {
            tmp[y * pw + x] = fminf(1.0f, p0 + shift);
            tmp[(y + 1) * pw + x] = p1 - shift * 0.60f;
          } else {
            tmp[(y + 1) * pw + x] = fminf(1.0f, p1 + shift);
            tmp[y * pw + x] = p0 - shift * 0.60f;
          }
        }
      }
    }
  }

  // Step 3: horizontal pass (vertical stems straddling columns x and x+1)
  memcpy(f, tmp, sizeof(float) * n);
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw - 1; x++) {
      float l = px_at(tmp, pw, ph, x - 1, y);
      float p0 = tmp[y * pw + x];
      float p1 = tmp[y * pw + x + 1];
      float r = px_at(tmp, pw, ph, x + 2, y);
      if (p0 > 0.25f && p1 > 0.25f && l < 0.22f && r < 0.22f) {
        float u_in = px_at(tmp, pw, ph, x, y - 1) + px_at(tmp, pw, ph, x + 1, y - 1);
        float d_in = px_at(tmp, pw, ph, x, y + 1) + px_at(tmp, pw, ph, x + 1, y + 1);
        if (u_in > 0.50f || d_in > 0.50f) {
          float shift = 0.42f * fminf(p0, p1);
          if (p0 >= p1) {
            f[y * pw + x] = fminf(1.0f, p0 + shift);
            f[y * pw + x + 1] = p1 - shift * 0.60f;
          } else {
            f[y * pw + x + 1] = fminf(1.0f, p1 + shift);
            f[y * pw + x] = p0 - shift * 0.60f;
          }
        }
      }
    }
  }

  for (size_t i = 0; i < n; i++) {
    uint8_t v = (uint8_t)(fminf(1.0f, fmaxf(0.0f, f[i])) * 255.0f + 0.5f);
    px[i * 4 + 0] = px[i * 4 + 1] = px[i * 4 + 2] = px[i * 4 + 3] = v;
  }
  free(tmp);
  free(f);
}

static void measure_bounds(IDWriteTextLayout *l, ClusterBounds *cb) {
  if (cb->valid) return;
  ColorProbe probe;
  l->Draw(NULL, &probe, 0, 0);
  DWRITE_TEXT_METRICS tm;
  DWRITE_LINE_METRICS lm;
  UINT32 nl = 0;
  l->GetMetrics(&tm);
  l->GetLineMetrics(&lm, 1, &nl);
  l->SetMaxWidth(tm.widthIncludingTrailingWhitespace);
  l->SetMaxHeight(tm.height);
  DWRITE_OVERHANG_METRICS om;
  l->GetOverhangMetrics(&om);
  // the ink box in layout coordinates (y down, the baseline at lm.baseline);
  // color glyphs and blanks use the typographic box
  double x0 = -om.left, y0 = -om.top;
  double x1 = tm.widthIncludingTrailingWhitespace + om.right, y1 = tm.height + om.bottom;
  if (probe.color || x1 - x0 <= 0 || y1 - y0 <= 0) {
    x0 = 0;
    y0 = 0;
    x1 = tm.widthIncludingTrailingWhitespace;
    y1 = tm.height;
  }
  cb->x0 = x0;
  cb->y0 = y0;
  cb->x1 = x1;
  cb->y1 = y1;
  cb->base = nl ? lm.baseline : 0;
  cb->color = probe.color;
  cb->valid = true;
}

// A cluster's layout drawn in white at `sc` pixels a point (shifted horizontally by `dx` points for its
// quarter-pixel subpixel phase), a pixel round its cached bounds `cb`, on `t`.
static void draw_cluster(IDWriteTextLayout *l, const ClusterBounds *cb, double sc, double dx, Target *t, Drawn *d) {
  *d = {};
  int color = cb->color;
  // The bitmap's edges on whole pixels from the baseline, a pixel of room
  // around: the baseline then falls on a pixel row of every glyph's bitmap,
  // so glyphs placed on the same rounded baseline line up.
  double base = cb->base;
  int px0 = (int)floor(cb->x0 * sc) - 1, px1 = (int)ceil(cb->x1 * sc) + 1;
  int py0 = (int)floor((cb->y0 - base) * sc) - 1, py1 = (int)ceil((cb->y1 - base) * sc) + 1;
  double x0 = px0 / sc;
  double y0 = base + py0 / sc;
  int pw = px1 - px0, ph = py1 - py0;
  if (pw <= 0 || ph <= 0 || pw > RT_SIZE || ph > RT_SIZE) return;
  target_ensure(t, sc);
  if (!t->rt) return;
  // One colour: drawn black on opaque white so Direct2D's contrast (0.5) at linear gamma (1.0) shapes coverage (with
  // ClearType at < 150% on RGB/BGR LCDs, or contrast-boosted grayscale at 150%+ / on OLED / when ClearType is off),
  // each stripe's coverage (255 - s) in its channel (the shader blends a mask stripe by stripe: win_render.cpp fmain),
  // its alpha their mean. Straight on the target: in a layer made for ClearType
  // (D2D1_LAYER_OPTIONS_INITIALIZE_FOR_CLEARTYPE) Direct2D drew it gray after all.
  // Clip to the glyph's own bounds so Clear() does not wipe the entire 512x512 (1 MiB) WIC bitmap per glyph.
  bool mono = !color && (params_ct || params_gray);
  bool ct = mono && use_cleartype(sc);
  FLOAT clip_w = (FLOAT)((pw < RT_SIZE ? pw + 1 : pw) / sc);
  FLOAT clip_h = (FLOAT)((ph < RT_SIZE ? ph + 1 : ph) / sc);
  t->rt->BeginDraw();
  t->rt->PushAxisAlignedClip(D2D1::RectF(0.0f, 0.0f, clip_w, clip_h), D2D1_ANTIALIAS_MODE_ALIASED);
  t->rt->Clear(mono ? D2D1::ColorF(1, 1, 1, 1) : D2D1::ColorF(0, 0, 0, 0));
  if (mono) {
    t->rt->SetTextAntialiasMode(ct ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    t->rt->SetTextRenderingParams(ct ? params_ct : params_gray);
  }
  t->rt->DrawTextLayout(D2D1::Point2F((FLOAT)(-x0 + dx), (FLOAT)-y0), l, mono ? t->black : t->white,
                        D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT | D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
  t->rt->PopAxisAlignedClip();
  t->rt->EndDraw();
  if (mono) {
    t->rt->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
    t->rt->SetTextRenderingParams(params);
  }
  WICRect r = {0, 0, pw, ph};
  IWICBitmapLock *lock = NULL;
  if (SUCCEEDED(t->bitmap->Lock(&r, WICBitmapLockRead, &lock))) {
    UINT stride = 0, bytes = 0;
    BYTE *src = NULL;
    lock->GetStride(&stride);
    lock->GetDataPointer(&bytes, &src);
    uint8_t *px = (uint8_t *)malloc((size_t)pw * ph * 4);
    for (int y = 0; y < ph; y++) {
      const BYTE *s = src + (size_t)y * stride;
      uint8_t *o = px + (size_t)y * pw * 4;
      for (int x = 0; x < pw; x++, s += 4, o += 4) {
        o[0] = mono ? (uint8_t)(255 - s[2]) : s[2];
        o[1] = mono ? (uint8_t)(255 - s[1]) : s[1];
        o[2] = mono ? (uint8_t)(255 - s[0]) : s[0];
        o[3] = mono ? (uint8_t)((o[0] + o[1] + o[2] + 1) / 3) : s[3];
        // premultiplied: drawn in white, a mask's pixel has its colour equal to its alpha; an emoji's does not
        if (color == 1 && o[3] > 64 && (o[0] + 32 < o[3] || o[1] + 32 < o[3] || o[2] + 32 < o[3])) color = 2;
      }
    }
    lock->Release();
    if (mono && !ct && color != 2) enhance_gray_stems(px, pw, ph);
    d->pw = pw;
    d->ph = ph;
    d->px = px;
  }
  // a color font's glyph drawn in the text's colour (Segoe UI Emoji's flags are letters): a mask after all
  d->color = color == 2;
  d->w = pw / sc;
  d->h = ph / sc;
  d->ox = x0;
  d->oy = y0 - base;
}

// ---- drawing ahead: the glyphs a frame shaped (text.mbt glyphs_ahead) and the remaining subpixel phases of any
// glyph first drawn on the main thread, drawn by threads of their own across all 5 horizontal quarter-pixel phases ----

#define SUB_COUNT 5
#define SUB_ALL 0x1F

// Horizontal quarter-pixel shift (in device pixels) encoded in bits 26..28 of a glyph key:
// 0 -> 0.0, 1 -> +0.25, 2 -> +0.50, 3 -> -0.25, 4 -> -0.50.
static double sub_dx(int sub) {
  switch (sub) {
    case 1: return 0.25;
    case 2: return 0.50;
    case 3: return -0.25;
    case 4: return -0.50;
    default: return 0.0;
  }
}

enum { AHEAD_ASKED, AHEAD_DRAWING, AHEAD_DRAWN };
struct Ahead {
  int key;
  WCHAR *text;
  int len;
  IDWriteTextFormat *format;
  IDWriteTypography *typography;
  double scale;
  int state;
  uint8_t want_mask;
  uint8_t have_mask;
  bool dropped;
  Drawn drawn[SUB_COUNT];
};

// The most glyph clusters asked for or drawn ahead and not all placed yet (the oldest drawn let go past it).
#define AHEAD_MOST 2048
static CRITICAL_SECTION ahead_lock;
static CONDITION_VARIABLE ahead_more, ahead_done;
static int ahead_started;
// (under ahead_lock) what the threads are to draw, in the order asked
static Ahead **ahead_queue;
static int ahead_head, ahead_n, ahead_cap;
// (the frames' thread's) what was asked for and not placed yet, by key, and in the order asked
static Ahead **ahead_of;  // by key, n_entries' room
static int ahead_of_cap;
static Ahead **ahead_order;
static int order_head, order_n, order_cap;

static void ahead_free(Ahead *a) {
  if (a->format) a->format->Release();
  if (a->typography) a->typography->Release();
  free(a->text);
  for (int s = 0; s < SUB_COUNT; s++) free(a->drawn[s].px);
  free(a);
}

static IDWriteTextLayout *layout_with(const WCHAR *s, int len, IDWriteTextFormat *f, IDWriteTypography *typo) {
  IDWriteTextLayout *l = NULL;
  if (FAILED(dw->CreateTextLayout(s, (UINT32)len, f, 1e6f, 1e6f, &l))) return NULL;
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  if (typo) l->SetTypography(typo, {0, (UINT32)len});
  return l;
}

// A thread drawing ahead: what is asked, oldest first, with a target of its own (on COM's multithreaded apartment)
static DWORD WINAPI ahead_thread(void *) {
  CoInitializeEx(NULL, COINIT_MULTITHREADED);
  Target t = {};
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory), NULL, (void **)&t.d2d);
  CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, __uuidof(IWICImagingFactory), (void **)&t.wic);
  for (;;) {
    EnterCriticalSection(&ahead_lock);
    while (ahead_n == 0) SleepConditionVariableCS(&ahead_more, &ahead_lock, INFINITE);
    Ahead *a = ahead_queue[ahead_head];
    ahead_head = (ahead_head + 1) % ahead_cap;
    ahead_n--;
    uint8_t mask = a->want_mask;
    bool gone = a->dropped || mask == 0;
    if (!gone) a->state = AHEAD_DRAWING;
    LeaveCriticalSection(&ahead_lock);
    if (gone) {
      ahead_free(a);
      continue;
    }
    Drawn local_d[SUB_COUNT] = {};
    uint8_t built_mask = 0;
    IDWriteTextLayout *l = t.d2d && t.wic ? layout_with(a->text, a->len, a->format, a->typography) : NULL;
    if (l) {
      ClusterBounds cb = {};
      measure_bounds(l, &cb);
      for (int s = 0; s < SUB_COUNT; s++) {
        if (!(mask & (1 << s))) continue;
        EnterCriticalSection(&ahead_lock);
        bool drop_now = a->dropped;
        LeaveCriticalSection(&ahead_lock);
        if (drop_now) break;
        draw_cluster(l, &cb, a->scale, sub_dx(s) / a->scale, &t, &local_d[s]);
        built_mask |= (uint8_t)(1 << s);
      }
      l->Release();
    }
    EnterCriticalSection(&ahead_lock);
    for (int s = 0; s < SUB_COUNT; s++) {
      if (built_mask & (1 << s)) a->drawn[s] = local_d[s];
    }
    a->have_mask = built_mask;
    a->state = AHEAD_DRAWN;
    bool free_it = a->dropped;
    WakeAllConditionVariable(&ahead_done);
    LeaveCriticalSection(&ahead_lock);
    if (free_it) ahead_free(a);
  }
}

// (the frames' thread) its hold on `a` let go: freed here when no thread has it, else by the one that does
static void ahead_drop(Ahead *a) {
  EnterCriticalSection(&ahead_lock);
  bool mine = a->state == AHEAD_DRAWN;
  a->dropped = true;
  LeaveCriticalSection(&ahead_lock);
  if (mine) ahead_free(a);
}

static void order_remove_front(void) {
  order_head = (order_head + 1) % order_cap;
  order_n--;
}

static void order_clear_ptr(Ahead *a) {
  for (int i = 0; i < order_n; i++) {
    Ahead **at = &ahead_order[(order_head + i) % order_cap];
    if (*at == a) {
      *at = NULL;
      break;
    }
  }
}

// Everything asked for let go: the faces or the scale changed, and what is drawn with them with it.
static void ahead_forget(void) {
  for (int i = 0; i < n_entries; i++) entries[i].subs_queued = 0;
  for (int i = 0; i < order_n; i++) {
    Ahead *a = ahead_order[(order_head + i) % order_cap];
    if (!a) continue;
    if (a->key < ahead_of_cap) ahead_of[a->key] = NULL;
    ahead_drop(a);
  }
  order_n = order_head = 0;
}

// The oldest asked, let go if it is drawn (the threads draw about in the order asked: hardly any is when it is not);
// false when not.
static bool drop_oldest_drawn(void) {
  while (order_n > 0 && !ahead_order[order_head]) order_remove_front();
  if (order_n == 0) return false;
  Ahead *a = ahead_order[order_head];
  EnterCriticalSection(&ahead_lock);
  bool drawn = a->state == AHEAD_DRAWN;
  uint8_t left_mask = a->have_mask;
  LeaveCriticalSection(&ahead_lock);
  if (!drawn) return false;
  if (a->key >= 0 && a->key < n_entries) entries[a->key].subs_queued &= (uint8_t)~left_mask;
  ahead_of[a->key] = NULL;
  order_remove_front();
  ahead_free(a);
  return true;
}

// What was drawn ahead of `key` at subpixel phase `sub` and the scale of now, taken (true, its picture in *d);
// false when it was not (asked and not begun: removed from want_mask and drawn here).
static bool drawn_ahead(int key, int sub, Drawn *d) {
  if (sub < 0 || sub >= SUB_COUNT) return false;
  Ahead *a = key < ahead_of_cap ? ahead_of[key] : NULL;
  if (!a) return false;
  uint8_t bit = (uint8_t)(1 << sub);
  EnterCriticalSection(&ahead_lock);
  if (a->state == AHEAD_ASKED) {
    a->want_mask &= (uint8_t)~bit;
    bool empty = a->want_mask == 0;
    if (empty) a->dropped = true;
    LeaveCriticalSection(&ahead_lock);
    if (empty) {
      ahead_of[key] = NULL;
      order_clear_ptr(a);
    }
    return false;
  }
  if (a->state == AHEAD_DRAWING) {
    if (!(a->want_mask & bit)) {
      LeaveCriticalSection(&ahead_lock);
      return false;
    }
    while (a->state == AHEAD_DRAWING) SleepConditionVariableCS(&ahead_done, &ahead_lock, INFINITE);
  }
  bool ok = a->scale == text_scale && (a->have_mask & bit) != 0;
  if (ok) {
    *d = a->drawn[sub];
    a->drawn[sub] = {};
    a->have_mask &= (uint8_t)~bit;
  }
  bool done = a->have_mask == 0 || a->scale != text_scale;
  LeaveCriticalSection(&ahead_lock);
  if (done) {
    ahead_of[key] = NULL;
    order_clear_ptr(a);
    ahead_free(a);
  }
  return ok;
}

static void ahead_ensure_started(void) {
  if (ahead_started) return;
  ahead_started = 1;
  InitializeCriticalSection(&ahead_lock);
  InitializeConditionVariable(&ahead_more);
  InitializeConditionVariable(&ahead_done);
  // (a page's few hundred glyphs drawn in the time a frame or two takes, over the cores there are, the frames'
  // thread's left to it)
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  int threads = (int)si.dwNumberOfProcessors - 1;
  threads = threads < 1 ? 1 : threads > 4 ? 4 : threads;
  for (int i = 0; i < threads; i++) {
    HANDLE h = CreateThread(NULL, 0, ahead_thread, NULL, 0, NULL);
    if (h) SetThreadPriority(h, THREAD_PRIORITY_BELOW_NORMAL), CloseHandle(h);
  }
}

static bool ahead_enqueue_one(int k, uint8_t mask) {
  if (k < 0 || k >= n_entries || mask == 0) return false;
  ahead_ensure_started();
  if (ahead_of_cap <= k) {
    int cap = n_entries * 2;
    if (cap <= k) cap = (k + 1) * 2;
    ahead_of = (Ahead **)realloc(ahead_of, (size_t)cap * sizeof *ahead_of);
    memset(ahead_of + ahead_of_cap, 0, (size_t)(cap - ahead_of_cap) * sizeof *ahead_of);
    ahead_of_cap = cap;
  }
  if (ahead_of[k]) return false;
  if (order_n >= AHEAD_MOST && !drop_oldest_drawn()) return false;
  glyph_entry *e = &entries[k];
  e->subs_queued |= mask;
  Ahead *a = (Ahead *)calloc(1, sizeof(Ahead));
  a->key = k;
  a->len = e->len;
  a->text = (WCHAR *)malloc(sizeof(WCHAR) * (e->len ? e->len : 1));
  memcpy(a->text, pool + e->off, sizeof(WCHAR) * e->len);
  a->format = format_for(e->size, e->weight, e->style);
  a->format->AddRef();
  a->typography = typography_for(e->style);
  if (a->typography) a->typography->AddRef();
  a->scale = text_scale;
  a->state = AHEAD_ASKED;
  a->want_mask = mask;
  ahead_of[k] = a;
  if (order_n + 1 > order_cap) {
    int cap = order_cap ? order_cap * 2 : 256;
    Ahead **next = (Ahead **)malloc((size_t)cap * sizeof *next);
    for (int j = 0; j < order_n; j++) next[j] = ahead_order[(order_head + j) % order_cap];
    free(ahead_order);
    ahead_order = next;
    order_head = 0;
    order_cap = cap;
  }
  ahead_order[(order_head + order_n++) % order_cap] = a;
  EnterCriticalSection(&ahead_lock);
  if (ahead_n + 1 > ahead_cap) {
    int cap = ahead_cap ? ahead_cap * 2 : 256;
    Ahead **next = (Ahead **)malloc((size_t)cap * sizeof *next);
    for (int j = 0; j < ahead_n; j++) next[j] = ahead_queue[(ahead_head + j) % ahead_cap];
    free(ahead_queue);
    ahead_queue = next;
    ahead_head = 0;
    ahead_cap = cap;
  }
  ahead_queue[(ahead_head + ahead_n++) % ahead_cap] = a;
  LeaveCriticalSection(&ahead_lock);
  return true;
}

extern "C" void mb_host_glyphs_ahead(int32_t *keys, int32_t n) {
  if (n <= 0 || !dw) return;
  int asked = 0;
  for (int32_t i = 0; i < n; i++) {
    int k = keys[i];
    if (k < 0 || k >= n_entries) continue;
    uint8_t rem = (uint8_t)(SUB_ALL & ~entries[k].subs_queued);
    if (ahead_enqueue_one(k, rem)) asked++;
  }
  if (asked) WakeAllConditionVariable(&ahead_more);
}

// Glyph `full_key` drawn in white, a pixel round its bounds: its box (in its entry) and its picture, held for
// mb_host_glyph_put (where it goes in the atlas is MoonBit's: hostapi's atlas.mbt). From what was drawn ahead of it
// when ready, else drawn here using cached cluster bounds and layout while its remaining subpixel phases are queued
// ahead in the background.
static void rasterize(int full_key) {
  int key = full_key & 0x03FFFFFF;
  int sub = (full_key >> 26) & 7;
  if (sub >= SUB_COUNT) sub = 0;
  free(held_px);
  held_px = NULL;
  held_key = -1;
  entries[key].w = entries[key].h = 0;
  Drawn d = {};
  if (!drawn_ahead(key, sub, &d)) {
    IDWriteTextLayout *l = main_layout_for(key);
    glyph_entry *e = &entries[key];
    measure_bounds(l, &e->bounds);
    draw_cluster(l, &e->bounds, text_scale, sub_dx(sub) / text_scale, &main_target, &d);
    e->subs_queued |= (uint8_t)(1 << sub);
    uint8_t rem = (uint8_t)(SUB_ALL & ~e->subs_queued);
    if (rem && ahead_enqueue_one(key, rem)) WakeAllConditionVariable(&ahead_more);
  } else {
    entries[key].subs_queued |= (uint8_t)(1 << sub);
  }
  glyph_entry *e = &entries[key];
  if (d.px) {
    held_key = full_key;
    held_w = d.pw;
    held_h = d.ph;
    held_px = d.px;
  }
  e->w = d.w;
  e->h = d.h;
  e->ox = d.ox;
  e->oy = d.oy;
  e->color = d.color;
}

extern "C" void mb_host_glyph(int32_t key, double *out) {
  int base_key = key >= 0 ? (key & 0x03FFFFFF) : key;
  if (base_key < 0 || base_key >= n_entries) {
    for (int i = 0; i < 7; i++) out[i] = 0;
    return;
  }
  rasterize(key);
  glyph_entry *e = &entries[base_key];
  out[0] = 0;
  out[1] = 0;
  out[2] = e->w;
  out[3] = e->h;
  out[4] = e->ox;
  out[5] = e->oy;
  out[6] = e->color;
}

// The glyph drawn last put in the atlas, its top left at x, y.
extern "C" void mb_host_glyph_put(int32_t key, int32_t x, int32_t y) {
  if (key != held_key || !held_px) return;
  mb_atlas_upload(x, y, held_w, held_h, held_px);
  free(held_px);
  held_px = NULL;
  held_key = -1;
}

// The picture of the glyph drawn last, as mb_host_glyph_put would put it, copied out (RGBA, a mask's colour its
// cover): what words' halo is blurred from (src/ui/halo.mbt). 1 when given.
extern "C" int32_t mb_host_glyph_picture(int32_t key, moonbit_bytes_t out) {
  if (key != held_key || !held_px) return 0;
  size_t n = (size_t)held_w * held_h * 4;
  if ((size_t)Moonbit_array_length(out) < n) return 0;
  memcpy(out, held_px, n);
  return 1;
}

// Pixels made by MoonBit (a halo, RGBA) put in the atlas, their top left at x, y, as a glyph's are. 1 when put.
extern "C" int32_t mb_host_atlas_put(int32_t x, int32_t y, int32_t w, int32_t h, moonbit_bytes_t px) {
  if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > mb_atlas_size || y + h > mb_atlas_size) return 0;
  if ((size_t)Moonbit_array_length(px) < (size_t)w * h * 4) return 0;
  mb_atlas_upload(x, y, w, h, px);
  return 1;
}

// ---------------------------------------------------------------------------
// The platform's own drawing of a line (textref_native.mbt, for src/textdiff): DirectWrite's text layout with its
// default features (ligatures as any app has them) and the fonts above, drawn by Direct2D into a WIC bitmap with the
// rasterizer settings above, at the places mbui draws the same words.

static IWICBitmap *ref_bmp;
static ID2D1RenderTarget *ref_rt;
static ID2D1SolidColorBrush *ref_brush;
static int ref_w, ref_h;

static void ref_path(moonbit_string_t name, WCHAR *out, size_t cap) {
  const WCHAR *dir = _wgetenv(L"MBUI_SHOT_DIR");
  int n = Moonbit_array_length(name);
  _snwprintf(out, cap, L"%ls\\%.*ls.png", dir ? dir : L".", n, (const WCHAR *)name);
}

static void ref_release(void) {
  if (ref_brush) ref_brush->Release();
  if (ref_rt) ref_rt->Release();
  if (ref_bmp) ref_bmp->Release();
  ref_brush = NULL;
  ref_rt = NULL;
  ref_bmp = NULL;
}

static D2D1_COLOR_F rgb(int c) {
  return D2D1::ColorF(((c >> 16) & 255) / 255.0f, ((c >> 8) & 255) / 255.0f, (c & 255) / 255.0f, 1);
}

extern "C" void mb_host_ref_begin(double w, double h, double scale, int32_t bg) {
  init();
  ref_release();
  ref_w = (int)floor(w * scale + 0.5);
  ref_h = (int)floor(h * scale + 0.5);
  wic->CreateBitmap(ref_w, ref_h, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnDemand, &ref_bmp);
  float dpi = (float)(96.0 * scale);
  D2D1_RENDER_TARGET_PROPERTIES p = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_SOFTWARE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), dpi, dpi);
  d2d->CreateWicBitmapRenderTarget(ref_bmp, &p, &ref_rt);
  bool ct = use_cleartype(scale);
  ref_rt->SetTextAntialiasMode(ct ? D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE : D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  ref_rt->SetTextRenderingParams(ct ? params_ct : params_gray);
  ref_rt->CreateSolidColorBrush(D2D1::ColorF(0, 0, 0, 1), &ref_brush);
  ref_rt->BeginDraw();
  ref_rt->Clear(rgb(bg));
}

extern "C" void mb_host_ref_text(moonbit_string_t text, double size, int32_t weight, int32_t style, double x,
                                 double base, int32_t color, double *out) {
  for (int i = 0; i < 5; i++) out[i] = 0;
  if (!ref_rt) return;
  int len = Moonbit_array_length(text);
  IDWriteTextLayout *l = NULL;
  dw->CreateTextLayout((const WCHAR *)text, (UINT32)len, format_for(size, weight, style), 1e6f, 1e6f, &l);
  IDWriteTextLayout2 *l2 = NULL;
  if (SUCCEEDED(l->QueryInterface(__uuidof(IDWriteTextLayout2), (void **)&l2))) {
    l2->SetFontFallback(fallback);
    l2->Release();
  }
  set_style_features(l, len, style);
  DWRITE_LINE_METRICS lm;
  UINT32 nl = 0;
  l->GetLineMetrics(&lm, 1, &nl);
  DWRITE_TEXT_METRICS tm;
  l->GetMetrics(&tm);
  ref_brush->SetColor(rgb(color));
  ref_rt->DrawTextLayout(D2D1::Point2F((FLOAT)x, (FLOAT)(base - (nl ? lm.baseline : 0))), l, ref_brush,
                         D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT | D2D1_DRAW_TEXT_OPTIONS_NO_SNAP);
  out[0] = tm.widthIncludingTrailingWhitespace;
  l->Release();
}

extern "C" int32_t mb_host_ref_end(moonbit_string_t name) {
  if (!ref_rt) return 0;
  ref_rt->EndDraw();
  WCHAR path[1024];
  ref_path(name, path, 1024);
  int ok = 0;
  WICRect r = {0, 0, ref_w, ref_h};
  IWICBitmapLock *lock = NULL;
  IWICStream *stream = NULL;
  IWICBitmapEncoder *enc = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  if (SUCCEEDED(ref_bmp->Lock(&r, WICBitmapLockRead, &lock))) {
    UINT stride = 0, bytes = 0;
    BYTE *px = NULL;
    lock->GetStride(&stride);
    lock->GetDataPointer(&bytes, &px);
    // the ground is opaque: premultiplied or not, the same bytes
    WICPixelFormatGUID fmt = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(wic->CreateStream(&stream)) && SUCCEEDED(stream->InitializeFromFilename(path, GENERIC_WRITE)) &&
        SUCCEEDED(wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &enc)) &&
        SUCCEEDED(enc->Initialize(stream, WICBitmapEncoderNoCache)) && SUCCEEDED(enc->CreateNewFrame(&frame, NULL)) &&
        SUCCEEDED(frame->Initialize(NULL)) && SUCCEEDED(frame->SetSize((UINT)ref_w, (UINT)ref_h)) &&
        SUCCEEDED(frame->SetPixelFormat(&fmt)))
      ok = SUCCEEDED(frame->WritePixels((UINT)ref_h, stride, stride * ref_h, px)) && SUCCEEDED(frame->Commit()) &&
           SUCCEEDED(enc->Commit());
    lock->Release();
  }
  if (frame) frame->Release();
  if (enc) enc->Release();
  if (stream) stream->Release();
  ref_release();
  return ok;
}

extern "C" int32_t mb_host_ref_frame(moonbit_string_t name) {
  WCHAR path[1024];
  ref_path(name, path, 1024);
  return mb_render_snapshot(path);
}
