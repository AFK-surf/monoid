// Liquid glass's reflection of what is outside it (the overlay ambient pull and the 1-point rim of the colour beyond
// its edge: the renderers' extRimEnv / wideAmb), the same scenes and gates on every renderer's test
// (scripts/apple_render_test.m, scripts/gles_render_test.c, scripts/win_gpu_test.cpp). The test including it first
// defines CHECK, MB_INST, glass_forget() and gr_pixels(inst, count, r, g, b, w, h): the scene drawn as a shot is
// (mb_render_pixels_of, 2 pixels a point) into w × h RGBA pixels from the top left, freed by gr_free; GR_KEYS_CHECKED
// defined checks its key pixels against Metal's (gr_keys).
//   GLASS_REFLECT_DUMP=<dir> writes each scene's pixels there (<name>.rgba), to compare renderers or commits;
//   GLASS_REFLECT_BENCH=1 times a full-window sheet and a menu (printed, not checked).
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define GR_S 2

static double gr_tid = -700;

// A plain rect at x, y, w × h of colour (r, g, b) in a scene cw × ch points.
static void gr_rect(double *d, double x, double y, double w, double h, double r, double g, double b, double cw,
                    double ch) {
  memset(d, 0, MB_INST * sizeof(double));
  d[0] = x, d[1] = y, d[2] = w, d[3] = h;
  d[8] = r, d[9] = g, d[10] = b, d[11] = 1;
  d[18] = cw, d[19] = ch;
}

// Regular liquid glass (kind 6) as src/ui/glass.mbt makes it: corners `rad`, light or dark, density `alpha`, blur and
// refraction in points, its chroma; its capture told by gr_capture.
static void gr_glass(double *d, double x, double y, double w, double h, double rad, int dark, double alpha,
                     double blur, double refr, double chroma, double cw, double ch) {
  gr_rect(d, x, y, w, h, dark ? 32.0 / 255.0 : 253.0 / 255.0, dark ? 32.0 / 255.0 : 252.0 / 255.0,
          dark ? 32.0 / 255.0 : 253.0 / 255.0, cw, ch);
  d[4] = rad;
  d[5] = 6;
  d[6] = 1.0;
  d[7] = blur;
  d[11] = alpha;
  d[12] = 0.6;
  d[13] = 20.0;
  d[15] = 1.0;
  d[21] = refr;
  d[22] = chroma;
  d[36] = d[37] = d[38] = d[39] = rad;
}

// A capture of its own for the glass at `d` (and those after it given the same).
static double gr_capture(void) { return gr_tid -= 1; }

static int gr_dump_n;
static uint8_t *gr_draw(const char *name, const double *inst, int n, const double bg[3], int wpt, int hpt) {
  glass_forget();
  uint8_t *px = gr_pixels(inst, n, bg[0], bg[1], bg[2], wpt * GR_S, hpt * GR_S);
  CHECK(px != NULL);
  const char *dir = getenv("GLASS_REFLECT_DUMP");
  if (px && dir && *dir) {
    char path[512];
    snprintf(path, sizeof path, "%s/%02d_%s_%dx%d.rgba", dir, gr_dump_n++, name, wpt * GR_S, hpt * GR_S);
    FILE *fp = fopen(path, "wb");
    if (fp) {
      fwrite(px, 1, (size_t)wpt * GR_S * hpt * GR_S * 4, fp);
      fclose(fp);
    }
  }
  return px;
}

// The pixel at px, py (pixels from the top left) of a reading w pixels wide.
static const uint8_t *gr_at(const uint8_t *px, int w, int x, int y) { return px + ((size_t)y * w + x) * 4; }

static double gr_wcag(const uint8_t *p) {
  double c[3];
  for (int i = 0; i < 3; i++) {
    double v = p[i] / 255.0;
    c[i] = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
  }
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

// The hue (degrees) of a pixel, and its chroma (max - min of its channels).
static double gr_hue(const uint8_t *p) {
  double r = p[0], g = p[1], b = p[2];
  double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b)), c = mx - mn;
  if (c <= 0) return -1;
  double h = mx == r ? fmod((g - b) / c, 6.0) : mx == g ? (b - r) / c + 2.0 : (r - g) / c + 4.0;
  h *= 60.0;
  return h < 0 ? h + 360.0 : h;
}
static int gr_chroma(const uint8_t *p) {
  int mx = p[0] > p[1] ? p[0] : p[1], mn = p[0] < p[1] ? p[0] : p[1];
  if (p[2] > mx) mx = p[2];
  if (p[2] < mn) mn = p[2];
  return mx - mn;
}

// The largest step of any channel between neighbouring samples (xs[i], ys[i]) of a reading.
static int gr_steps(const uint8_t *px, int w, const int *xs, const int *ys, int n, int *at) {
  int most = 0;
  for (int i = 1; i < n; i++) {
    const uint8_t *a = gr_at(px, w, xs[i - 1], ys[i - 1]), *b = gr_at(px, w, xs[i], ys[i]);
    for (int c = 0; c < 3; c++) {
      int d = abs((int)a[c] - (int)b[c]);
      if (d > most) most = d, *at = i;
    }
  }
  return most;
}

// The largest difference of any channel between two readings within x0..x1 × y0..y1 (pixels, end excluded).
static int gr_diff(const uint8_t *a, const uint8_t *b, int w, int x0, int y0, int x1, int y1) {
  int most = 0;
  for (int y = y0; y < y1; y++)
    for (int x = x0; x < x1; x++)
      for (int c = 0; c < 3; c++) {
        int d = abs((int)gr_at(a, w, x, y)[c] - (int)gr_at(b, w, x, y)[c]);
        if (d > most) most = d;
      }
  return most;
}

// Key pixels as Metal draws them (apple_render_test.m on Apple silicon): where the test says GR_KEYS_CHECKED (the GLES
// one, Mesa's llvmpipe), its own within 2 of each, so the renderers draw the reflection alike.
static const struct {
  const char *name;
  int r, g, b;
} gr_keys[] = {
    {"gate15_centre", 210, 209, 211},
    {"gate7_ground_foot_inset12", 91, 91, 92},
    {"gate7_ground_foot_inset16", 87, 87, 89},
    {"gate7_orange_foot_inset12", 157, 90, 0},
    {"gate7_orange_foot_inset16", 159, 90, 0},
    {"gate8_diag_in25", 202, 215, 205},
    {"gate9_mid", 210, 210, 210},
    {"menu_dark_blue", 26, 90, 161},
    {"menu_dark_foot6_green", 57, 67, 61},
    {"menu_dark_foot6_plain", 58, 58, 60},
    {"menu_dark_foot6_purple", 67, 60, 71},
    {"menu_dark_orange", 139, 85, 11},
    {"menu_dark_rim_green", 59, 147, 84},
    {"menu_dark_rim_plain", 103, 103, 105},
    {"menu_dark_rim_purple", 143, 96, 165},
    {"menu_light_blue", 177, 224, 255},
    {"menu_light_foot6_green", 247, 251, 251},
    {"menu_light_foot6_plain", 248, 248, 253},
    {"menu_light_foot6_purple", 251, 249, 254},
    {"menu_light_orange", 255, 224, 164},
    {"menu_light_rim_green", 197, 255, 217},
    {"menu_light_rim_plain", 254, 254, 255},
    {"menu_light_rim_purple", 254, 227, 255},
    {"zero_clear_left_in4", 49, 207, 89},
    {"zero_clear_mid", 188, 88, 239},
    {"zero_droplet_left_in4", 49, 207, 89},
    {"zero_droplet_mid", 177, 97, 227},
    {"zero_flat_left_in4", 126, 249, 157},
    {"zero_flat_mid", 244, 189, 255},
    {"zero_tinted_left_in4", 215, 160, 70},
    {"zero_tinted_mid", 231, 154, 87},
};

static void gr_key(const char *name, const uint8_t *p) {
  printf("glass_reflect: key %s %d %d %d\n", name, p[0], p[1], p[2]);
#ifdef GR_KEYS_CHECKED
  int known = 0;
  for (size_t i = 0; i < sizeof gr_keys / sizeof gr_keys[0]; i++) {
    if (strcmp(gr_keys[i].name, name) != 0) continue;
    known = 1;
    CHECK(abs(p[0] - gr_keys[i].r) <= 2 && abs(p[1] - gr_keys[i].g) <= 2 && abs(p[2] - gr_keys[i].b) <= 2);
  }
  CHECK(known);
#endif
}

// A menu 240 × 200 at 40, 20 (corners 22, 0x80, blur 14, refraction 16) in a scene 320 × 300: a green and a purple
// button 33 points under it (or not), saturated orange and blue under its foot 24 points in (or not).
static uint8_t *gr_menu(int dark, int buttons, int inner, const char *name) {
  const double cw = 320, ch = 300;
  double s[5 * MB_INST];
  double bg[3] = {dark ? 28 / 255.0 : 242 / 255.0, dark ? 28 / 255.0 : 242 / 255.0, dark ? 30 / 255.0 : 247 / 255.0};
  int n = 0;
  if (inner) {
    gr_rect(s + n++ * MB_INST, 60, 150, 80, 50, 1.0, 149 / 255.0, 0.0, cw, ch);
    gr_rect(s + n++ * MB_INST, 180, 150, 80, 50, 0.0, 122 / 255.0, 1.0, cw, ch);
  }
  if (buttons) {
    gr_rect(s + n++ * MB_INST, 60, 253, 90, 36, 52 / 255.0, 199 / 255.0, 89 / 255.0, cw, ch);
    gr_rect(s + n++ * MB_INST, 170, 253, 90, 36, 175 / 255.0, 82 / 255.0, 222 / 255.0, cw, ch);
  }
  gr_glass(s + n * MB_INST, 40, 20, 240, 200, 22, dark, 0x80 / 255.0, 14, 16, 0, cw, ch);
  s[n++ * MB_INST + 20] = gr_capture();
  return gr_draw(name, s, n, bg, (int)cw, (int)ch);
}

static void glass_reflect_cases(void) {
  // --- Menu foot: the green and purple buttons under it seen in its foot (6 points in) and its 1-point rim; with
  // saturated orange and blue under its foot, those kept as vivid as without the buttons; light and dark.
  for (int dark = 0; dark < 2; dark++) {
    const int w = 320 * GR_S;
    const char *m = dark ? "dark" : "light";
    char nm[64];
    snprintf(nm, sizeof nm, "menu_%s_buttons", m);
    uint8_t *with = gr_menu(dark, 1, 0, nm);
    snprintf(nm, sizeof nm, "menu_%s_plain", m);
    uint8_t *without = gr_menu(dark, 0, 0, nm);
    snprintf(nm, sizeof nm, "menu_%s_vivid_buttons", m);
    uint8_t *vwith = gr_menu(dark, 1, 1, nm);
    snprintf(nm, sizeof nm, "menu_%s_vivid_plain", m);
    uint8_t *vwithout = gr_menu(dark, 0, 1, nm);
    if (!with || !without || !vwith || !vwithout) {
      gr_free(with), gr_free(without), gr_free(vwith), gr_free(vwithout);
      continue;
    }
    // (6 points in from the foot over each button's middle, and the rim's outer pixel row, 0.25 points in)
    const uint8_t *gin = gr_at(with, w, 105 * GR_S, 214 * GR_S), *pin = gr_at(with, w, 215 * GR_S, 214 * GR_S);
    const uint8_t *grim = gr_at(with, w, 105 * GR_S, 219 * GR_S + 1), *prim = gr_at(with, w, 215 * GR_S, 219 * GR_S + 1);
    const uint8_t *gin0 = gr_at(without, w, 105 * GR_S, 214 * GR_S), *grim0 = gr_at(without, w, 105 * GR_S, 219 * GR_S + 1);
    // (the orange and blue 24 points in from the foot)
    const uint8_t *or1 = gr_at(vwith, w, 100 * GR_S, 196 * GR_S), *or0 = gr_at(vwithout, w, 100 * GR_S, 196 * GR_S);
    const uint8_t *bl1 = gr_at(vwith, w, 220 * GR_S, 196 * GR_S), *bl0 = gr_at(vwithout, w, 220 * GR_S, 196 * GR_S);
    snprintf(nm, sizeof nm, "menu_%s_foot6_green", m), gr_key(nm, gin);
    snprintf(nm, sizeof nm, "menu_%s_foot6_purple", m), gr_key(nm, pin);
    snprintf(nm, sizeof nm, "menu_%s_rim_green", m), gr_key(nm, grim);
    snprintf(nm, sizeof nm, "menu_%s_rim_purple", m), gr_key(nm, prim);
    snprintf(nm, sizeof nm, "menu_%s_foot6_plain", m), gr_key(nm, gin0);
    snprintf(nm, sizeof nm, "menu_%s_rim_plain", m), gr_key(nm, grim0);
    snprintf(nm, sizeof nm, "menu_%s_orange", m), gr_key(nm, or1);
    snprintf(nm, sizeof nm, "menu_%s_blue", m), gr_key(nm, bl1);
    printf("glass_reflect: menu_%s hue foot6 green=%.1f purple=%.1f rim green=%.1f purple=%.1f chroma orange %d->%d blue %d->%d\n",
           m, gr_hue(gin), gr_hue(pin), gr_hue(grim), gr_hue(prim), gr_chroma(or0), gr_chroma(or1), gr_chroma(bl0),
           gr_chroma(bl1));
    // What the buttons add, channel by channel, over the menu without them: on the green side green over red and
    // blue (blue never rising with it: no cyan), on the purple side red and blue over green. At the rim (0.25 and 0.75
    // points in) light and dark; 6 points in, dark. (6 points in on light, the colour is near white's ceiling: green
    // shows a little, purple only lighter, never toward green.)
    const int rows[3] = {219 * GR_S + 1, 219 * GR_S, 214 * GR_S};
    for (int r = 0; r < 3; r++) {
      const uint8_t *g1 = gr_at(with, w, 105 * GR_S, rows[r]), *g0 = gr_at(without, w, 105 * GR_S, rows[r]);
      const uint8_t *p1 = gr_at(with, w, 215 * GR_S, rows[r]), *p0 = gr_at(without, w, 215 * GR_S, rows[r]);
      int ge[3], pe[3];
      for (int c = 0; c < 3; c++) ge[c] = g1[c] - g0[c], pe[c] = p1[c] - p0[c];
      int gs = ge[1] - (ge[0] > ge[2] ? ge[0] : ge[2]), ps = (pe[0] < pe[2] ? pe[0] : pe[2]) - pe[1];
      printf("glass_reflect: menu_%s row%d green+=(%d,%d,%d) score=%d purple+=(%d,%d,%d) score=%d\n", m, rows[r], ge[0],
             ge[1], ge[2], gs, pe[0], pe[1], pe[2], ps);
      if (r < 2) {
        CHECK(gs >= (r == 0 ? 30 : 12) && ps >= (r == 0 ? 20 : 8));
      } else if (dark) {
        CHECK(gs >= 5 && ps >= 4);
      } else {
        CHECK(gs >= 2 && pe[0] >= pe[1]);
      }
      CHECK(ge[1] >= ge[2] + 2);
    }
    // the buttons' colour only where they are: what is under the menu's foot no less vivid for them
    CHECK(gr_chroma(or1) + 2 >= gr_chroma(or0) && gr_chroma(bl1) + 2 >= gr_chroma(bl0));
    gr_free(with), gr_free(without), gr_free(vwith), gr_free(vwithout);
  }

  // --- GATE7: dark 0x80 with white round it, 12 and 16 points in from each edge, #E9E9EA words keep a contrast of
  // 4.5:1 over the menu's own dark ground; over saturated orange (its colour drawing no reflection) the contrast the
  // reflection leaves is the one the white's blur leaves without it, printed.
  for (int orange = 0; orange < 2; orange++) {
    const double cw = 320, ch = 240;
    double s[2 * MB_INST], bg[3] = {1, 1, 1};
    if (orange) gr_rect(s, 40, 20, 240, 200, 1.0, 149 / 255.0, 0.0, cw, ch);
    else gr_rect(s, 40, 20, 240, 200, 28 / 255.0, 28 / 255.0, 30 / 255.0, cw, ch);
    gr_glass(s + MB_INST, 40, 20, 240, 200, 22, 1, 0x80 / 255.0, 14, 16, 0, cw, ch);
    s[MB_INST + 20] = gr_capture();
    uint8_t *px = gr_draw(orange ? "gate7_dark_orange_white" : "gate7_dark_ground_white", s, 2, bg, (int)cw, (int)ch);
    if (px) {
      const uint8_t words[3] = {0xE9, 0xE9, 0xEA};
      double lw = gr_wcag(words), worst = 99;
      int insets[2] = {12, 16};
      for (int k = 0; k < 2; k++) {
        int in = insets[k];
        int pts[4][2] = {{160, 20 + in}, {160, 220 - in}, {40 + in, 120}, {280 - in, 120}};
        for (int e = 0; e < 4; e++) {
          const uint8_t *p = gr_at(px, (int)cw * GR_S, pts[e][0] * GR_S, pts[e][1] * GR_S - (e == 1 ? 1 : 0));
          double cr = (lw + 0.05) / (gr_wcag(p) + 0.05);
          if (cr < worst) worst = cr;
          if (e == 1) {
            char nm[48];
            snprintf(nm, sizeof nm, "gate7_%s_foot_inset%d", orange ? "orange" : "ground", in), gr_key(nm, p);
          }
        }
      }
      printf("glass_reflect: gate7 %s worst_cr=%.3f\n", orange ? "orange" : "ground", worst);
      if (!orange) CHECK(worst >= 4.50);
      gr_free(px);
    }
  }

  // --- GATE8: a corner (22, blur 14) white to its right and green under it: along its 45° diagonal 16..34 points in,
  // no step over 2.
  {
    const double cw = 240, ch = 240;
    double s[4 * MB_INST], bg[3] = {0.5, 0.5, 0.5};
    gr_rect(s, 200, 0, 40, 240, 1, 1, 1, cw, ch);
    gr_rect(s + MB_INST, 0, 200, 200, 40, 52 / 255.0, 199 / 255.0, 89 / 255.0, cw, ch);
    gr_glass(s + 2 * MB_INST, 40, 40, 160, 160, 22, 0, 0x80 / 255.0, 14, 16, 0, cw, ch);
    s[2 * MB_INST + 20] = gr_capture();
    uint8_t *px = gr_draw("gate8_corner", s, 3, bg, (int)cw, (int)ch);
    if (px) {
      // the corner's middle at 178, 178: 16..34 points in along the diagonal are 169.5..182.2 points
      int xs[64], ys[64], n = 0, at = 0;
      for (int k = (int)floor(169.5 * GR_S); k <= (int)ceil(182.25 * GR_S); k++) xs[n] = k, ys[n] = k, n++;
      int most = gr_steps(px, (int)cw * GR_S, xs, ys, n, &at);
      printf("glass_reflect: gate8 diag max_step=%d at=%d\n", most, xs[at]);
      gr_key("gate8_diag_in25", gr_at(px, (int)cw * GR_S, (int)(176.0 * GR_S), (int)(176.0 * GR_S)));
      CHECK(most <= 2);
      gr_free(px);
    }
  }

  // --- GATE9: a 44-point capsule (blur 12) black above its middle and white under: along its middle, no step over 3.
  {
    const double cw = 320, ch = 120;
    double s[2 * MB_INST], bg[3] = {0, 0, 0};
    gr_rect(s, 0, 60, 320, 60, 1, 1, 1, cw, ch);
    gr_glass(s + MB_INST, 60, 38, 200, 44, 22, 0, 0x80 / 255.0, 12, 16, 0, cw, ch);
    s[MB_INST + 20] = gr_capture();
    uint8_t *px = gr_draw("gate9_capsule", s, 2, bg, (int)cw, (int)ch);
    if (px) {
      int xs[512], ys[512], n = 0, at = 0;
      for (int x = 62 * GR_S; x < 258 * GR_S; x++) xs[n] = x, ys[n] = 60 * GR_S, n++;
      int most = gr_steps(px, (int)cw * GR_S, xs, ys, n, &at);
      printf("glass_reflect: gate9 midline max_step=%d at=%d\n", most, xs[at]);
      gr_key("gate9_mid", gr_at(px, (int)cw * GR_S, 160 * GR_S, 60 * GR_S));
      CHECK(most <= 3);
      gr_free(px);
    }
  }

  // --- GATE15: neutral glass 72 × 72 (blur 14, refraction 16) over grey, red beside its left edge and blue beside its
  // right: along its middle, no step over 3 (nothing turns over at its centre, where the two sides meet).
  {
    const double cw = 200, ch = 152;
    double s[3 * MB_INST], bg[3] = {0.5, 0.5, 0.5};
    gr_rect(s, 0, 0, 64, 152, 1, 59 / 255.0, 48 / 255.0, cw, ch);
    gr_rect(s + MB_INST, 136, 0, 64, 152, 0, 122 / 255.0, 1, cw, ch);
    gr_glass(s + 2 * MB_INST, 64, 40, 72, 72, 22, 0, 0x80 / 255.0, 14, 16, 0, cw, ch);
    s[2 * MB_INST + 20] = gr_capture();
    uint8_t *px = gr_draw("gate15_square", s, 3, bg, (int)cw, (int)ch);
    if (px) {
      int xs[256], ys[256], n = 0, at = 0;
      for (int x = 66 * GR_S; x < 134 * GR_S; x++) xs[n] = x, ys[n] = 76 * GR_S, n++;
      int most = gr_steps(px, (int)cw * GR_S, xs, ys, n, &at);
      printf("glass_reflect: gate15 centre_line max_step=%d at=%d\n", most, xs[at]);
      gr_key("gate15_centre", gr_at(px, (int)cw * GR_S, 100 * GR_S, 76 * GR_S));
      CHECK(most <= 3);
      gr_free(px);
    }
  }

  // --- GATE13 / GATE14: what the glass shows the same from its capture alone and from one shared with glass far off
  // (which takes in what is past the first's margin): positive refraction with black 61 points off (1 at most), and
  // negative refraction (passed straight) with green 26..38 points off (0).
  for (int neg = 0; neg < 2; neg++) {
    const double cw = 480, ch = 300;
    double s[3 * MB_INST], bg[3] = {242 / 255.0, 242 / 255.0, 247 / 255.0};
    if (neg) gr_rect(s, 306, 60, 12, 120, 52 / 255.0, 199 / 255.0, 89 / 255.0, cw, ch);
    else gr_rect(s, 341, 60, 40, 120, 0, 0, 0, cw, ch);
    gr_glass(s + MB_INST, 40, 20, 240, 200, 22, 0, 0x80 / 255.0, neg ? 1.2 : 14, neg ? -20 : 16, 0, cw, ch);
    s[MB_INST + 20] = gr_capture();
    uint8_t *alone = gr_draw(neg ? "gate14_alone" : "gate13_alone", s, 2, bg, (int)cw, (int)ch);
    gr_glass(s + 2 * MB_INST, 420, 240, 40, 40, 12, 0, 0x80 / 255.0, neg ? 1.2 : 14, neg ? -20 : 16, 0, cw, ch);
    s[MB_INST + 20] = s[2 * MB_INST + 20] = gr_capture();
    uint8_t *shared = gr_draw(neg ? "gate14_shared" : "gate13_shared", s, 3, bg, (int)cw, (int)ch);
    if (alone && shared) {
      int most = gr_diff(alone, shared, (int)cw * GR_S, 40 * GR_S, 20 * GR_S, 280 * GR_S, 220 * GR_S);
      printf("glass_reflect: gate%d alone_vs_shared max_diff=%d\n", neg ? 14 : 13, most);
      CHECK(most <= (neg ? 0 : 1));
    }
    gr_free(alone), gr_free(shared);
  }

  // --- No reflection where there is none to make: clear glass, tinted glass (chroma >= 0.16), glass of no blur and no
  // refraction, and a zoomed droplet: green beside each, nothing on them NaN (black) and each its own look.
  {
    const double cw = 320, ch = 120;
    struct { const char *name; double alpha, blur, refr, r, g, b, pw; } cs[4] = {
      {"zero_clear", 0.0, 0, 16, 1, 1, 1, 0},
      {"zero_tinted", 0x80 / 255.0, 14, 16, 0.95, 0.55, 0.20, 0},
      {"zero_flat", 0x80 / 255.0, 0, 0, 253 / 255.0, 252 / 255.0, 253 / 255.0, 0},
      {"zero_droplet", 0.0, 0, 16, 1, 1, 1, -0.18},
    };
    for (int c = 0; c < 4; c++) {
      double s[3 * MB_INST], bg[3] = {242 / 255.0, 242 / 255.0, 247 / 255.0};
      gr_rect(s, 0, 0, 160, 120, 52 / 255.0, 199 / 255.0, 89 / 255.0, cw, ch);
      gr_rect(s + MB_INST, 160, 0, 160, 120, 175 / 255.0, 82 / 255.0, 222 / 255.0, cw, ch);
      gr_glass(s + 2 * MB_INST, 100, 30, 120, 60, 30, 0, cs[c].alpha, cs[c].blur, cs[c].refr, 0, cw, ch);
      s[2 * MB_INST + 8] = cs[c].r, s[2 * MB_INST + 9] = cs[c].g, s[2 * MB_INST + 10] = cs[c].b;
      if (cs[c].pw < 0) s[2 * MB_INST + 7] = cs[c].pw;
      s[2 * MB_INST + 20] = gr_capture();
      uint8_t *px = gr_draw(cs[c].name, s, 3, bg, (int)cw, (int)ch);
      if (!px) continue;
      int black = 0;
      for (int y = 30 * GR_S; y < 90 * GR_S; y++)
        for (int x = 100 * GR_S; x < 220 * GR_S; x++) {
          const uint8_t *p = gr_at(px, (int)cw * GR_S, x, y);
          if (p[0] + p[1] + p[2] == 0) black++;
        }
      char nm[48];
      snprintf(nm, sizeof nm, "%s_left_in4", cs[c].name), gr_key(nm, gr_at(px, (int)cw * GR_S, 104 * GR_S, 60 * GR_S));
      snprintf(nm, sizeof nm, "%s_mid", cs[c].name), gr_key(nm, gr_at(px, (int)cw * GR_S, 160 * GR_S, 60 * GR_S));
      CHECK(black == 0);
      gr_free(px);
    }
  }

  // --- Speed (printed only): a full-window 0x80 sheet (its inside past 56 points takes no samples more) and a menu.
  if (getenv("GLASS_REFLECT_BENCH")) {
    const double cw = 400, ch = 800;
    double s[3 * MB_INST], bg[3] = {242 / 255.0, 242 / 255.0, 247 / 255.0};
    gr_rect(s, 40, 300, 320, 200, 0.0, 122 / 255.0, 1.0, cw, ch);
    gr_rect(s + MB_INST, 60, 600, 120, 60, 52 / 255.0, 199 / 255.0, 89 / 255.0, cw, ch);
    for (int menu = 0; menu < 2; menu++) {
      if (menu) gr_glass(s + 2 * MB_INST, 80, 200, 240, 200, 22, 0, 0x80 / 255.0, 14, 16, 0, cw, ch);
      else gr_glass(s + 2 * MB_INST, 0, 0, cw, ch, 0, 0, 0x80 / 255.0, 14, 16, 0, cw, ch);
      double best = 1e9, sum = 0;
      const int runs = 7;
      for (int i = 0; i < runs; i++) {
        s[2 * MB_INST + 20] = gr_capture();
        glass_forget();
        struct timespec t0, t1;
        timespec_get(&t0, TIME_UTC);
        uint8_t *px = gr_pixels(s, 3, bg[0], bg[1], bg[2], (int)cw * GR_S, (int)ch * GR_S);
        timespec_get(&t1, TIME_UTC);
        gr_free(px);
        double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
        if (i > 0) sum += ms;  // (the first builds the programs)
        if (i > 0 && ms < best) best = ms;
      }
      printf("glass_reflect: bench %s best_ms=%.2f mean_ms=%.2f\n", menu ? "menu" : "sheet", best, sum / (runs - 1));
    }
  }
}
