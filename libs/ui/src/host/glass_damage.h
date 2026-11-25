// Close host-added dirty rectangles over every glass capture they meet. The app's @damage does the same for its own
// rectangles, but adaptive settle frames are added by the hosts after that calculation.
#ifndef MB_GLASS_DAMAGE_H
#define MB_GLASS_DAMAGE_H

#include <math.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
  float id;
  double x0, y0, x1, y1, blur, refract, rim;
} MBGlassDamage;

// Rectangles are x, y, width, height in points. Updates *pn after clipping empty rectangles and merging overlapping
// dirty rectangles. Returns 0 on allocation failure so the caller can redraw the whole frame. Bounds conservatively
// contain grab_of's captures, with padding for host rounding.
static int mb_glass_damage_expand(const float *f, int32_t count, double rects[][4], int *pn,
                                  double width, double height, double scale, const int *donor_of) {
  int n = pn ? *pn : 0;
  if (n <= 0) {
    if (pn) *pn = 0;
    return 1;
  }
  int kept = 0;
  for (int i = 0; i < n; i++) {
    double x0 = fmax(0.0, rects[i][0]), y0 = fmax(0.0, rects[i][1]);
    double x1 = fmin(width, rects[i][0] + rects[i][2]);
    double y1 = fmin(height, rects[i][1] + rects[i][3]);
    if (x1 <= x0 || y1 <= y0) continue;
    rects[kept][0] = x0; rects[kept][1] = y0;
    rects[kept][2] = x1 - x0; rects[kept][3] = y1 - y0;
    kept++;
  }
  n = kept;
  *pn = n;
  if (!n) return 1;
  int total = 0;
  for (int32_t i = 0; i < count; i++) if (f[(size_t)i * MB_INST + 20] < 0.0f) total++;
  if (!total) return 1;
  MBGlassDamage *groups = (MBGlassDamage *)malloc((size_t)total * sizeof(*groups));
  if (!groups) return 0;
  int ng = 0;
  int cur_g = -1;
  for (int32_t i = 0; i < count; ) {
    const float *a = f + (size_t)i * MB_INST;
    int kind = (int)(a[5] + 0.5f);
    if (kind == 8) {
      int32_t child_n = (int32_t)(a[12] + 0.5f);
      if (child_n < 0) child_n = 0;
      if (i + 1 + child_n > count) child_n = count - i - 1;
      i += 1 + child_n;
      continue;
    }
    if (a[20] < 0.0f) {
      double x0 = kind == 6 ? a[0] : fmax(a[0], a[16]);
      double y0 = kind == 6 ? a[1] : fmax(a[1], a[17]);
      double x1 = kind == 6 ? a[0] + a[2] : fmin(a[0] + a[2], a[18]);
      double y1 = kind == 6 ? a[1] + a[3] : fmin(a[1] + a[3], a[19]);
      if (kind != 6 && (x1 <= x0 || y1 <= y0)) {
        if (kind == 5) cur_g = -1;
        i++;
        continue;
      }
      double blur = kind == 6 && a[7] < 0.0f ? 0.0 : fabs(a[7]);
      double refract = kind == 6 ? fmax(0.0, a[21] * (1.0 + fabs(a[22]))) : 0.0;
      double rim = kind == 6 ? fmax(a[23], 0.0) : 0.0;
      int k = 0;
      while (k < ng && groups[k].id != a[20]) k++;
      if (k == ng) {
        MBGlassDamage g = {a[20], x0, y0, x1, y1, blur, refract, rim};
        groups[ng++] = g;
      } else {
        MBGlassDamage *g = &groups[k];
        g->x0 = fmin(g->x0, x0); g->y0 = fmin(g->y0, y0);
        g->x1 = fmax(g->x1, x1); g->y1 = fmax(g->y1, y1);
        g->blur = fmax(g->blur, blur); g->refract = fmax(g->refract, refract); g->rim = fmax(g->rim, rim);
      }
      if (kind == 5 || kind == 6) cur_g = k;
    } else if (cur_g >= 0 && (kind == 7 || kind == 10 || kind == 11) && a[23] < 0.0f &&
               (!donor_of || donor_of[i] == 0)) {
      double cx, cy, hx, hy;
      if (kind == 7) {
        cx = a[0] + a[2] * 0.5; cy = a[1] + a[3] * 0.5;
        hx = fmax(-a[23], a[2]); hy = fmax(fmax(-a[23] * 0.5, a[3]), 1.0);
      } else if (kind == 10) {
        cx = a[0] + a[2] * 0.5; cy = a[1] + a[3] * 0.5;
        hx = hy = fmax(-a[23] * 0.5, 1.0);
      } else {
        cx = a[0] + a[2] * 0.5 + a[6]; cy = a[1] + a[3] * 0.5 + a[7];
        hx = hy = fmax(-a[23] * 0.5, 1.0);
      }
      MBGlassDamage *g = &groups[cur_g];
      g->x0 = fmin(g->x0, cx - hx); g->y0 = fmin(g->y0, cy - hy);
      g->x1 = fmax(g->x1, cx + hx); g->y1 = fmax(g->y1, cy + hy);
    }
    i++;
  }
  if (!ng) {
    free(groups);
    return 1;
  }
  for (int j = 0; j < ng; j++) {
    MBGlassDamage *g = &groups[j];
    // A merged group's first rim and blur can apply to its other shapes; bound all of them conservatively.
    double m = 3.0 * g->blur + g->refract + 2.0 * g->rim + 2.0 + 2.0 / (scale > 0.0 ? scale : 1.0);
    g->x0 = fmax(0.0, g->x0 - m); g->y0 = fmax(0.0, g->y0 - m);
    g->x1 = fmin(width, g->x1 + m); g->y1 = fmin(height, g->y1 + m);
  }
  for (int i = 0; i < n; i++) {
    rects[i][2] += rects[i][0];
    rects[i][3] += rects[i][1];
  }
  int changed;
  do {
    changed = 0;
    for (int i = 0; i < n; i++) {
      double x0 = rects[i][0], y0 = rects[i][1], x1 = rects[i][2], y1 = rects[i][3];
      for (int j = 0; j < ng; j++) {
        MBGlassDamage *g = &groups[j];
        if (g->x1 <= g->x0 || g->y1 <= g->y0 || x0 >= g->x1 || x1 <= g->x0 ||
            y0 >= g->y1 || y1 <= g->y0) continue;
        if (x0 > g->x0 || y0 > g->y0 || x1 < g->x1 || y1 < g->y1) {
          x0 = fmin(x0, g->x0); y0 = fmin(y0, g->y0);
          x1 = fmax(x1, g->x1); y1 = fmax(y1, g->y1);
          changed = 1;
        }
      }
      rects[i][0] = x0; rects[i][1] = y0; rects[i][2] = x1; rects[i][3] = y1;
    }
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n;) {
        if (rects[i][0] <= rects[j][2] && rects[j][0] <= rects[i][2] &&
            rects[i][1] <= rects[j][3] && rects[j][1] <= rects[i][3]) {
          rects[i][0] = fmin(rects[i][0], rects[j][0]);
          rects[i][1] = fmin(rects[i][1], rects[j][1]);
          rects[i][2] = fmax(rects[i][2], rects[j][2]);
          rects[i][3] = fmax(rects[i][3], rects[j][3]);
          for (int k = j + 1; k < n; k++) {
            rects[k - 1][0] = rects[k][0]; rects[k - 1][1] = rects[k][1];
            rects[k - 1][2] = rects[k][2]; rects[k - 1][3] = rects[k][3];
          }
          n--;
          changed = 1;
        } else {
          j++;
        }
      }
    }
  } while (changed);
  for (int i = 0; i < n; i++) {
    rects[i][2] -= rects[i][0];
    rects[i][3] -= rects[i][1];
  }
  *pn = n;
  free(groups);
  return 1;
}
#endif
