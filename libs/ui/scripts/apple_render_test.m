// src/host/apple_render.m's tests: after mb_render_trim shrinks the layer's drawableSize to 1x1 (the window hidden,
// covered, minimized or the Mac asleep) and mb_render_set_size restores the window's size, the next frame is drawn
// whole into a new canvas and presented, never skipped by same_as_shown as equal to the frame before the trim; the
// blur under glass kept while what is under it is the same, never while a picture under it had no texture yet; three
// groups of glass on one screen each keeping its own blur, made again only for the one something moved under; frames
// handed to the presenting queue while it is busy drawn as the newest alone, what each said to differ joined, the
// glyphs put meanwhile kept, the canvas then the same to the byte as the frame drawn whole; and many frames in a row
// with sizes, trims and read-backs between them:
//   cc -Wall -fobjc-arc -I src/host -I "$MOON_HOME/include" scripts/apple_render_test.m -framework Foundation -framework QuartzCore -framework Metal -framework CoreGraphics -framework ImageIO -o out/apple_render_test && out/apple_render_test
#include <stdio.h>
#import "apple_render.m"

// picture 1's texture: none (not decoded yet) till a test makes one
static id<MTLTexture> picture_one;
id<MTLTexture> mb_image_texture(int iid) { return iid == 1 ? picture_one : nil; }
id<MTLTexture> mb_stream_texture(int sid) { (void)sid; return nil; }
int mb_views_take_moved(void) { return 0; }
static int test_frost_can;
static int test_frost_n;
static double test_frost_last[MB_FROST_N];
int mb_views_frost(int n, const double *frosts) {
  test_frost_n = n;
  if (n > 0 && frosts) memcpy(test_frost_last, frosts, sizeof test_frost_last);
  return test_frost_can;
}
int mb_views_count(void) { return 0; }
void mb_views_draw_under(CGContextRef ctx, double scale) { (void)ctx, (void)scale; }
void mb_text_set_scale(double scale) { (void)scale; }

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

// An instance: a rect at x, y, w × h of colour (r, g, b), kind `kind`, image `tid`, its clip the window's.
static double wcag_luma_u8(int r, int g, int b) {
  double c[3] = {r / 255.0, g / 255.0, b / 255.0};
  for (int i = 0; i < 3; i++) c[i] = c[i] <= 0.04045 ? (c[i] / 12.92) : pow((c[i] + 0.055) / 1.055, 2.4);
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

static void rect_at(double *d, double x, double y, double w, double h, int kind, double r, double g, double b,
                    double tid) {
  memset(d, 0, MB_INST * sizeof(double));
  d[0] = x;
  d[1] = y;
  d[2] = w;
  d[3] = h;
  d[5] = kind;
  d[8] = r;
  d[9] = g;
  d[10] = b;
  d[11] = 1;
  d[16] = 0;
  d[17] = 0;
  d[18] = 400;
  d[19] = 300;
  d[20] = tid;
}

// A shot's pixels (mb_render_pixels_of) in bytes of MoonBit's (their length in the header before them), for
// glass_reflect_cases.h.
static uint8_t *gr_pixels(const double *inst, int n, double r, double g, double b, int w, int h) {
  size_t bytes = (size_t)w * h * 4;
  struct moonbit_object *o = calloc(1, sizeof *o + bytes);
  o->meta = (uint32_t)bytes;
  uint8_t *px = (uint8_t *)(o + 1);
  if (!mb_render_pixels_of(inst, n, r, g, b, 2.0, w, h, px)) {
    free(o);
    return NULL;
  }
  return px;
}
static void gr_free(uint8_t *px) {
  if (px) free((struct moonbit_object *)px - 1);
}
#define GR_KEYS_CHECKED 1
#define GR_HOT_FRAMES 1
#include "glass_reflect_cases.h"

// A frame of glass_reflect_cases.h's hot-frame case drawn as the window draws it (its canvas read back, RGBA).
static uint8_t *gr_window_frame(const double *inst, int n_inst, const double bg[3], const double (*rects)[4], int n) {
  // (all of it anew: no capture kept, no canvas held, nothing taken as already shown)
  if (!n) glass_forget(), canvas_ok = 0, shown_ok = 0, mb_host_render_dirty(0, 0, 320, 300);
  for (int i = 0; i < n; i++) mb_host_render_dirty(rects[i][0], rects[i][1], rects[i][2], rects[i][3]);
  mb_render_present(inst, n_inst, bg[0], bg[1], bg[2]);
  present_drain();
  int aw = 0, ah = 0;
  uint8_t *px = read_texture(canvas, &aw, &ah);
  if (!px || aw != 320 * GR_S || ah != 300 * GR_S) {
    free(px);
    return NULL;
  }
  size_t bytes = (size_t)aw * ah * 4;
  struct moonbit_object *o = calloc(1, sizeof *o + bytes);
  uint8_t *out = (uint8_t *)(o + 1);
  for (size_t i = 0; i < bytes; i += 4) out[i] = px[i + 2], out[i + 1] = px[i + 1], out[i + 2] = px[i], out[i + 3] = px[i + 3];
  free(px);
  return out;
}

// The canvas the window's frames were drawn into the same to the byte as its last frame drawn whole again.
static int canvas_as_whole(void) {
  int cw, ch, ww, wh;
  uint8_t *drawn = read_texture(canvas, &cw, &ch);
  uint8_t *whole = read_last(&ww, &wh);
  int same = cw == ww && ch == wh && memcmp(drawn, whole, (size_t)cw * ch * 4) == 0;
  free(drawn);
  free(whole);
  return same;
}

int main(void) {
  @autoreleasepool {
    CAMetalLayer *layer = [CAMetalLayer layer];
    mb_render_init(layer);
    CHECK(mlayer == layer);
    CHECK(mlayer.framebufferOnly == YES);
    CHECK(mlayer.opaque == YES);
    mb_render_set_size(400, 300, 2);
    CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(800, 600)));

    double inst[MB_INST] = {0};
    inst[0] = 10;
    inst[1] = 20;
    inst[2] = 100;
    inst[3] = 50;
    inst[16] = 0;
    inst[17] = 0;
    inst[18] = 400;
    inst[19] = 300;
    float f[MB_INST] = {0};
    for (int i = 0; i < MB_INST; i++) f[i] = (float)inst[i];
    last_inst = f;
    last_count = 1;
    last_bg[0] = 0.1;
    last_bg[1] = 0.2;
    last_bg[2] = 0.3;
    shown_w = 400;
    shown_h = 300;
    shown_scale = 2;
    shown_ok = 1;
    canvas_ok = 1;

    // An identical frame while shown is skipped.
    CHECK(same_as_shown(f, 1, 0.1, 0.2, 0.3) == 1);
    CHECK(glass_through(f, 1) == 0);

    // A frame with a visible hole (kind 9) turns mlayer.opaque off; once the hole leaves, mlayer.opaque is YES again.
    double hole[MB_INST] = {0};
    hole[0] = 10;
    hole[1] = 20;
    hole[2] = 100;
    hole[3] = 50;
    hole[5] = 9;
    hole[16] = 0;
    hole[17] = 0;
    hole[18] = 400;
    hole[19] = 300;
    float hole_f[MB_INST];
    for (int i = 0; i < MB_INST; i++) hole_f[i] = (float)hole[i];
    CHECK(glass_through(hole_f, 1) == 1);
    last_inst = NULL;
    mb_render_present(hole, 1, 0.1, 0.2, 0.3);
    CHECK(mlayer.opaque == NO);
    CHECK(shown_ok == 1);
    mb_render_present(inst, 1, 0.1, 0.2, 0.3);
    CHECK(mlayer.opaque == YES);
    CHECK(shown_ok == 1);
    present_drain();
    // A frame drawn whole with no glass goes straight into the drawable: the canvas holds no frame after it.
    CHECK(canvas_ok == 0);
    // One said to differ in a part is drawn into the canvas (whole, as it held none) and copied.
    double moved[MB_INST];
    memcpy(moved, inst, sizeof moved);
    moved[0] = 12;
    mb_host_render_dirty(0, 0, 200, 100);
    mb_render_present(moved, 1, 0.1, 0.2, 0.3);
    CHECK(shown_ok == 1);
    present_drain();
    CHECK(canvas_ok == 1);
    // One with glass (slot 20 negative) goes through the canvas, whose copy its blur reads, though drawn whole.
    double glass[2 * MB_INST];
    memcpy(glass, inst, sizeof inst);
    memcpy(glass + MB_INST, inst, sizeof inst);
    glass[MB_INST + 5] = 5;
    glass[MB_INST + 7] = 10;
    glass[MB_INST + 11] = 0.5;
    glass[MB_INST + 20] = -1;
    canvas_ok = 0;
    mb_render_present(glass, 2, 0.1, 0.2, 0.3);
    CHECK(shown_ok == 1);
    present_drain();
    CHECK(canvas_ok == 1);

    // The blur under glass is kept while what is drawn under it is the same: what is over it changing draws none
    // again; what is under it changing does.
    {
      double g3[3 * MB_INST];
      rect_at(g3, 20, 20, 200, 100, 0, 0.9, 0.1, 0.1, 0);
      rect_at(g3 + MB_INST, 40, 40, 120, 60, 5, 1, 1, 1, -2);
      g3[MB_INST + 7] = 10;
      g3[MB_INST + 11] = 0.5;
      rect_at(g3 + 2 * MB_INST, 300, 200, 20, 20, 0, 0.1, 0.1, 0.9, 0);
      mb_render_present(g3, 3, 0.1, 0.2, 0.3);
      present_drain();
      int made = blurs_made;
      CHECK(kept_ok == 1);
      g3[2 * MB_INST + 0] = 320;  // over the glass: moved
      mb_render_present(g3, 3, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made);
      CHECK(kept_ok == 1);
      g3[0] = 24;  // under it: moved
      mb_render_present(g3, 3, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 1);
      CHECK(kept_ok == 1);

      // A picture under it with no texture yet (drawn without it): that blur is not kept as what is under it, and
      // once the picture has its texture, it is drawn and kept.
      double p3[3 * MB_INST];
      memcpy(p3, g3, sizeof p3);
      rect_at(p3, 20, 20, 200, 100, 4, 1, 1, 1, 1);
      p3[12] = 0;
      p3[13] = 0;
      p3[14] = 1;
      p3[15] = 1;
      picture_one = nil;
      mb_render_present(p3, 3, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(kept_ok == 0);
      MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                    width:2
                                                                                   height:2
                                                                                mipmapped:NO];
      picture_one = [dev newTextureWithDescriptor:td];
      uint8_t px[16] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
      [picture_one replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:px bytesPerRow:8];
      p3[2 * MB_INST + 0] = 330;  // (a frame of its own: the same numbers would be the one shown)
      made = blurs_made;
      mb_render_present(p3, 3, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 1);
      CHECK(kept_ok == 1);
      picture_one = nil;
    }

    // Three groups of glass on one screen (frosted at the top, liquid in the middle, frosted at the foot, each with
    // something of its own under it, a caret over all): each keeps its own blur. A frame where only what is over them
    // moves makes none; one where something moves under the middle one alone makes that one's again, the others kept.
    // The canvas each time the same to the byte as the frame drawn whole with every blur made anew.
    {
      double s3[8 * MB_INST];
      rect_at(s3, 0, 0, 400, 300, 0, 0.95, 0.95, 0.9, 0);
      rect_at(s3 + 1 * MB_INST, 32, 16, 104, 32, 0, 0.9, 0.1, 0.1, 0);
      rect_at(s3 + 2 * MB_INST, 20, 8, 144, 40, 5, 1, 1, 1, -2);
      s3[2 * MB_INST + 7] = 8;
      s3[2 * MB_INST + 11] = 0.5;
      rect_at(s3 + 3 * MB_INST, 248, 128, 80, 32, 0, 0.1, 0.7, 0.2, 0);
      rect_at(s3 + 4 * MB_INST, 240, 120, 120, 48, 6, 1, 1, 1, -3);
      s3[4 * MB_INST + 4] = 24;
      s3[4 * MB_INST + 7] = 8;
      s3[4 * MB_INST + 11] = 0.3;
      s3[4 * MB_INST + 21] = 8;
      s3[4 * MB_INST + 23] = 4;
      rect_at(s3 + 5 * MB_INST, 40, 240, 100, 24, 0, 0.2, 0.2, 0.9, 0);
      rect_at(s3 + 6 * MB_INST, 20, 228, 160, 48, 5, 1, 1, 1, -4);
      s3[6 * MB_INST + 7] = 8;
      s3[6 * MB_INST + 11] = 0.5;
      rect_at(s3 + 7 * MB_INST, 360, 260, 8, 24, 0, 0, 0, 0, 0);
      int made = blurs_made;
      mb_render_present(s3, 8, 0.1, 0.2, 0.3);
      present_drain();
      printf("apple_render_test: three groups, first frame: %d blurs\n", blurs_made - made);
      CHECK(blurs_made == made + 3);
      glass_forget();
      CHECK(canvas_as_whole());
      for (int i = 0; i < 3; i++) {
        s3[7 * MB_INST + 1] = 250 + 4 * i;  // the caret: moved
        made = blurs_made;
        mb_render_present(s3, 8, 0.1, 0.2, 0.3);
        present_drain();
        printf("apple_render_test: three groups, the caret moved: %d blurs\n", blurs_made - made);
        CHECK(blurs_made == made);
        CHECK(kept_ok == 1);
        CHECK(canvas_as_whole());
        glass_forget();
        CHECK(canvas_as_whole());
      }
      s3[3 * MB_INST + 0] = 256;  // under the liquid glass alone: moved
      made = blurs_made;
      mb_render_present(s3, 8, 0.1, 0.2, 0.3);
      present_drain();
      printf("apple_render_test: three groups, what is under the middle one moved: %d blurs\n", blurs_made - made);
      CHECK(blurs_made == made + 1);
      glass_forget();
      CHECK(canvas_as_whole());
      s3[1 * MB_INST + 0] = 36;  // under the top one: moved, that one's alone made again
      made = blurs_made;
      mb_render_present(s3, 8, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 1);
      glass_forget();
      CHECK(canvas_as_whole());
    }

    // Fourteen independent glass groups of mixed sizes and blur radii on one screen: all 14 stay cached when only the
    // top-level caret moves (blurs_made delta == 0) and match a fresh render byte-for-byte.
    {
      double g14[16 * MB_INST];
      static const double blurs[4] = {1.0, 3.0, 7.0, 16.0};
      rect_at(g14, 0, 0, 400, 300, 0, 0.92, 0.90, 0.88, 0);
      for (int i = 0; i < 14; i++) {
        int col = i % 7, row = i / 7;
        double gx = 8 + col * 52;
        double gy = 8 + row * 128;
        double gw = 32 + i * 4;
        double gh = 24 + i * 4;
        double *d = g14 + (i + 1) * MB_INST;
        rect_at(d, gx, gy, gw, gh, 5, 1, 1, 1, -(101 + i));
        d[7] = blurs[i % 4];
        d[11] = 0.4;
      }
      rect_at(g14 + 15 * MB_INST, 368, 264, 8, 24, 0, 0, 0, 0, 0);
      glass_free();
      int made = blurs_made;
      mb_render_present(g14, 16, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 14);
      CHECK(canvas_as_whole());
      g14[15 * MB_INST + 0] = 376;  // only top-level caret moves
      made = blurs_made;
      mb_render_present(g14, 16, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made);
      CHECK(kept_ok == 1);
      CHECK(canvas_as_whole());
      glass_forget();
      CHECK(canvas_as_whole());
    }

    // Frames handed over while the queue is busy (here held by a block of the test's): drawn once, the newest, in
    // part, what both said to differ joined; the glyph put between them kept; the canvas then the same to the byte as
    // that frame drawn whole.
    {
      double two[2 * MB_INST];
      rect_at(two, 20, 20, 40, 40, 0, 0.9, 0.2, 0.1, 0);
      rect_at(two + MB_INST, 200, 150, 40, 40, 0, 0.1, 0.8, 0.3, 0);
      // (a frame drawn in part first: the canvas then holds it)
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      present_drain();
      mb_host_render_dirty(18, 18, 46, 44);
      two[0] = 22;
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(canvas_ok == 1);
      CHECK(canvas_as_whole());
      dispatch_semaphore_t gate = dispatch_semaphore_create(0);
      dispatch_async(present_q, ^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
      });
      int drawn = present_drawn;
      two[0] = 60;  // the first moved, said
      mb_host_render_dirty(18, 18, 84, 44);
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      uint8_t glyph[4] = {11, 22, 33, 44};
      mb_atlas_upload(0, 8, 4, 2, 2, glyph);
      two[MB_INST + 1] = 100;  // then the second, said: the first's part not said again
      mb_host_render_dirty(198, 98, 44, 94);
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      CHECK(shown_ok == 1);
      CHECK(present_drawn == drawn);
      dispatch_semaphore_signal(gate);
      present_drain();
      CHECK(present_drawn == drawn + 1);
      // (put in by the queue for the frame drawn, before anything here reads back)
      uint8_t back[4] = {0};
      [atlas getBytes:back bytesPerRow:2 fromRegion:MTLRegionMake2D(8, 4, 2, 2) mipmapLevel:0];
      CHECK(memcmp(back, glyph, 4) == 0);
      CHECK(canvas_ok == 1);
      CHECK(canvas_as_whole());

      // Many frames in a row, the queue never waited for but by what reads back, resizes or trims: each frame's
      // canvas, when read, the frame drawn whole.
      for (int i = 0; i < 400; i++) {
        two[0] = 20 + (i * 7) % 300;
        two[MB_INST + 1] = 10 + (i * 13) % 200;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(two, 2, 0.1, 0.2, 0.3);
        if (i % 97 == 50) {
          mb_render_trim();
          CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(1, 1)));
        }
        if (i % 41 == 20) mb_render_set_size(i % 2 ? 380 : 400, 300, 2);
        if (i % 41 == 30) mb_render_set_size(400, 300, 2);
        if (i % 53 == 0) {
          int fw, fh;
          free(read_last(&fw, &fh));
          CHECK(fw == (int)round(vw * 2) && fh == 600);
        }
      }
      mb_render_set_size(400, 300, 2);
      two[0] = 33;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      two[0] = 35;
      mb_host_render_dirty(30, 18, 50, 44);
      mb_render_present(two, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(canvas_ok == 1);
      CHECK(canvas_as_whole());
      mb_render_trim();
      CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(1, 1)));
      CHECK(canvas_ok == 0);
      mb_render_set_size(400, 300, 2);
    }

    // What drawing holds beyond its frames given back: the trim lets go of the read back's texture and glass's (made
    // again by the next read and the next glass, the canvas then the same to the byte as the frame drawn whole); and
    // glass's textures go once MB_GLASS_IDLE frames in a row drew none, the glass after them blurred anew, as the frame
    // drawn whole.
    {
      double g1[2 * MB_INST];
      rect_at(g1, 30, 30, 160, 80, 0, 0.9, 0.1, 0.1, 0);
      rect_at(g1 + MB_INST, 20, 20, 200, 100, 6, 1, 1, 1, -5);
      g1[MB_INST + 4] = 24;
      g1[MB_INST + 7] = 8;
      g1[MB_INST + 11] = 0.3;
      g1[MB_INST + 21] = 8;
      g1[MB_INST + 23] = 4;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(lv[0] != nil && lv_w > 0);
      CHECK(slot_bt[0] != nil);
      // the same capture frosted (kind 5), kept in the same slot
      g1[MB_INST + 5] = 5;
      g1[0] = 32;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(slot_bt[0] != nil);
      CHECK(canvas_as_whole());

      int fw, fh;
      free(read_last(&fw, &fh));
      CHECK(read_tex != nil);
      mb_render_trim();
      CHECK(read_tex == nil);
      CHECK(lv[0] == nil && ltmp == nil && lv_w == 0 && lv_h == 0);
      CHECK(slot_bt[0] == nil);
      mb_render_set_size(400, 300, 2);
      g1[0] = 34;
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(lv[0] != nil);
      CHECK(canvas_as_whole());

      // frames with no glass: the glass's textures kept till the MB_GLASS_IDLE-th, then let go
      double plain[MB_INST];
      rect_at(plain, 30, 30, 160, 80, 0, 0.9, 0.1, 0.1, 0);
      for (int i = 1; i <= MB_GLASS_IDLE; i++) {
        plain[0] = 30 + i % 50;  // (each a frame of its own: the same numbers would be the one shown)
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(plain, 1, 0.1, 0.2, 0.3);
        present_drain();
        if (i == MB_GLASS_IDLE - 1) CHECK(lv[0] != nil && slot_bt[0] != nil);
      }
      CHECK(lv[0] == nil && ltmp == nil && lv_w == 0);
      for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slot_bt[i] == nil);
      // a frame with glass after: its blur made anew, as the frame drawn whole
      int made = blurs_made;
      g1[0] = 36;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 1);
      CHECK(lv[0] != nil);
      CHECK(canvas_as_whole());
      // a frame with glass among those without keeps them: the count starts again
      for (int i = 1; i < MB_GLASS_IDLE; i++) {
        plain[0] = 30 + i % 50;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(plain, 1, 0.1, 0.2, 0.3);
        present_drain();
      }
      g1[0] = 38;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      for (int i = 1; i < MB_GLASS_IDLE; i++) {
        plain[0] = 30 + i % 50;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(plain, 1, 0.1, 0.2, 0.3);
        present_drain();
      }
      CHECK(lv[0] != nil);
    }

    // Unmerged liquid glass (kind 6, a[23] <= 0):
    // (1) single shape with merge=0 (tight quad + direct sd_rr) matches merge=1e-7 (merged_liquid + sd_group, same float32 quad bounds) byte-for-byte;
    // (2) two unmerged liquid shapes separated by a shadow (kind 2) sharing one capture make only 1 blur and preserve
    //     each instance's own spot, matching separate captures byte-for-byte at k == 0.
    {
      double eq[2 * MB_INST];
      rect_at(eq, 0, 0, 400, 300, 0, 0.85, 0.30, 0.20, 0);
      rect_at(eq + MB_INST, 70, 90, 220, 96, 6, 1, 1, 1, -9);
      eq[MB_INST + 4] = 48;
      eq[MB_INST + 6] = 1;
      eq[MB_INST + 7] = 2;
      eq[MB_INST + 11] = 0.25;
      eq[MB_INST + 12] = 0.8;
      eq[MB_INST + 13] = 10;
      eq[MB_INST + 14] = 0;
      eq[MB_INST + 15] = 1;
      eq[MB_INST + 21] = 8;
      eq[MB_INST + 22] = 0.2;
      eq[MB_INST + 23] = 0;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(eq, 2, 0.1, 0.2, 0.3);
      present_drain();
      int sw, sh;
      uint8_t *px_single = read_texture(canvas, &sw, &sh);

      eq[MB_INST + 23] = 1e-7;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(eq, 2, 0.1, 0.2, 0.3);
      present_drain();
      int mw, mh;
      uint8_t *px_merged = read_texture(canvas, &mw, &mh);
      CHECK(sw == mw && sh == mh && memcmp(px_single, px_merged, (size_t)sw * sh * 4) == 0);
      free(px_single);
      free(px_merged);

      double lq[5 * MB_INST];
      rect_at(lq, 0, 0, 400, 300, 0, 0.92, 0.90, 0.85, 0);
      rect_at(lq + 1 * MB_INST, 20, 180, 340, 72, 0, 0.85, 0.25, 0.20, 0);
      // left capsule (no spot, merge=0)
      rect_at(lq + 2 * MB_INST, 24, 192, 160, 56, 6, 1, 1, 1, -9);
      lq[2 * MB_INST + 4] = 28;
      lq[2 * MB_INST + 6] = 1;
      lq[2 * MB_INST + 7] = 1.0;  // sp = 2.0 -> k == 0
      lq[2 * MB_INST + 11] = 0.25;
      lq[2 * MB_INST + 12] = 0.8;
      lq[2 * MB_INST + 13] = 10;
      lq[2 * MB_INST + 14] = 0;
      lq[2 * MB_INST + 15] = 1;
      lq[2 * MB_INST + 21] = 4;
      lq[2 * MB_INST + 22] = 0;
      lq[2 * MB_INST + 23] = 0;
      // shadow between the two shapes (outside the right disc's capture box)
      rect_at(lq + 3 * MB_INST, 24, 192, 40, 20, 2, 0, 0, 0, 0);
      lq[3 * MB_INST + 7] = 2;
      lq[3 * MB_INST + 11] = 0.2;
      // right disc (with its own spot, merge=0, sharing capture -9)
      rect_at(lq + 4 * MB_INST, 280, 192, 56, 56, 6, 1, 1, 1, -9);
      lq[4 * MB_INST + 4] = 28;
      lq[4 * MB_INST + 6] = 1;
      lq[4 * MB_INST + 7] = 1.0;
      lq[4 * MB_INST + 11] = 0.25;
      lq[4 * MB_INST + 12] = 0.8;
      lq[4 * MB_INST + 13] = 10;
      lq[4 * MB_INST + 14] = 537.0 * 4096.0 + 528.0 + 1.0;
      lq[4 * MB_INST + 15] = 1;
      lq[4 * MB_INST + 21] = 4;
      lq[4 * MB_INST + 22] = 0;
      lq[4 * MB_INST + 23] = 0;

      glass_forget();
      int made = blurs_made;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lq, 5, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 1);
      uint8_t *px_lq_shared = read_texture(canvas, &sw, &sh);

      lq[2 * MB_INST + 20] = -10;
      lq[4 * MB_INST + 20] = -11;
      glass_forget();
      made = blurs_made;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lq, 5, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(blurs_made == made + 2);
      int sep_w, sep_h;
      uint8_t *px_lq_sep = read_texture(canvas, &sep_w, &sep_h);
      CHECK(sw == sep_w && sh == sep_h && memcmp(px_lq_shared, px_lq_sep, (size_t)sw * sh * 4) == 0);
      free(px_lq_shared);
      free(px_lq_sep);
    }

    // Asymmetric 4-corner merged_liquid (rr = 24,24,0,0 sheet merged with pill) + Glass::clear() micro-veil vs pure lens:
    {
      double as[3 * MB_INST];
      rect_at(as, 0, 0, 400, 300, 0, 0.10, 0.12, 0.16, 0);
      // Sheet with top-rounded, bottom-square corners (24, 24, 0, 0)
      rect_at(as + 1 * MB_INST, 60, 100, 160, 120, 6, 1, 1, 1, -12);
      as[1 * MB_INST + 4] = 24;
      as[1 * MB_INST + 6] = 1;
      as[1 * MB_INST + 7] = 1;
      as[1 * MB_INST + 11] = 0.25;
      as[1 * MB_INST + 12] = 0.55;
      as[1 * MB_INST + 13] = 14;
      as[1 * MB_INST + 15] = 1;
      as[1 * MB_INST + 21] = 9;
      as[1 * MB_INST + 22] = 0.18;
      as[1 * MB_INST + 23] = 16;
      as[1 * MB_INST + 36] = 24;
      as[1 * MB_INST + 37] = 24;
      as[1 * MB_INST + 38] = 0;
      as[1 * MB_INST + 39] = 0;
      // Adjacent circular button merged with the sheet
      rect_at(as + 2 * MB_INST, 226, 128, 56, 56, 6, 1, 1, 1, -12);
      as[2 * MB_INST + 4] = 28;
      as[2 * MB_INST + 6] = 1;
      as[2 * MB_INST + 7] = 1;
      as[2 * MB_INST + 11] = 0.25;
      as[2 * MB_INST + 12] = 0.55;
      as[2 * MB_INST + 13] = 14;
      as[2 * MB_INST + 15] = 1;
      as[2 * MB_INST + 21] = 9;
      as[2 * MB_INST + 22] = 0.18;
      as[2 * MB_INST + 23] = 16;
      as[2 * MB_INST + 36] = 28;
      as[2 * MB_INST + 37] = 28;
      as[2 * MB_INST + 38] = 28;
      as[2 * MB_INST + 39] = 28;

      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(as, 3, 0.1, 0.12, 0.16);
      present_drain();
      int aw, ah;
      uint8_t *px_as = read_texture(canvas, &aw, &ah);
      // BGRA8Unorm top-down at scale 2
      uint8_t *bg_p = px_as + (10 * aw + 10) * 4;
      uint8_t *tl_p = px_as + (206 * aw + 126) * 4;  // (63, 103) outside top-left rounded corner (r=24)
      uint8_t *bl_p = px_as + (434 * aw + 126) * 4;  // (63, 217) inside bottom-left square corner (r=0)
      CHECK(abs((int)tl_p[1] - (int)bg_p[1]) <= 2 && abs((int)tl_p[2] - (int)bg_p[2]) <= 2);
      CHECK((int)bl_p[2] > (int)bg_p[2] + 40 && (int)bl_p[1] > (int)bg_p[1] + 40);
      free(px_as);

      // Glass::clear() (col.a = 26/255 ~ 0.102, blur = 0) yields +0.126 veil vs pure lens (col.a = 0, blur = 0) zero veil
      double cl[3 * MB_INST];
      rect_at(cl, 0, 0, 400, 300, 0, 0.08, 0.08, 0.10, 0);
      rect_at(cl + 1 * MB_INST, 40, 80, 120, 100, 6, 1, 1, 1, -13);
      cl[1 * MB_INST + 4] = 24;
      cl[1 * MB_INST + 6] = 1;
      cl[1 * MB_INST + 7] = 0;
      cl[1 * MB_INST + 11] = 26.0 / 255.0;
      cl[1 * MB_INST + 12] = 0.6;
      cl[1 * MB_INST + 13] = 14;
      cl[1 * MB_INST + 15] = 1;
      cl[1 * MB_INST + 21] = 16;
      cl[1 * MB_INST + 22] = 0;
      cl[1 * MB_INST + 23] = 0;
      rect_at(cl + 2 * MB_INST, 220, 80, 120, 100, 6, 1, 1, 1, -14);
      cl[2 * MB_INST + 4] = 24;
      cl[2 * MB_INST + 6] = 1;
      cl[2 * MB_INST + 7] = 0;
      cl[2 * MB_INST + 11] = 0.0;
      cl[2 * MB_INST + 12] = 0.6;
      cl[2 * MB_INST + 13] = 14;
      cl[2 * MB_INST + 15] = 1;
      cl[2 * MB_INST + 21] = 16;
      cl[2 * MB_INST + 22] = 0;
      cl[2 * MB_INST + 23] = 0;

      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(cl, 3, 0.08, 0.08, 0.10);
      present_drain();
      uint8_t *px_cl = read_texture(canvas, &aw, &ah);
      uint8_t *cl_bg = px_cl + (10 * aw + 10) * 4;
      uint8_t *cl_veil = px_cl + (260 * aw + 200) * 4;  // center of Glass::clear()
      uint8_t *cl_lens = px_cl + (260 * aw + 560) * 4;  // center of pure clear optical lens
      CHECK((int)cl_veil[1] >= 44 && (int)cl_veil[1] <= 62);
      // Native iOS 27 ClearGlassView applies subtle dark-backdrop volumetric lift (~+12/255 at rim=0.6)
      // while staying clearly more transparent than Glass::clear() (cl_veil ~52/255).
      CHECK((int)cl_lens[1] >= (int)cl_bg[1] && (int)cl_lens[1] <= (int)cl_bg[1] + 18 && (int)cl_lens[1] + 10 < (int)cl_veil[1]);
      free(px_cl);

      // Wave 3A (1): clear-lens optical zoom (slot 7 = -(zoom - 1.0)) magnifies centered backdrop
      double zm[3 * MB_INST];
      rect_at(zm, 0, 0, 400, 300, 0, 0.05, 0.05, 0.08, 0);
      // Red square centered at (100, 130), half-width 14pt -> x in [86, 114]
      rect_at(zm + 1 * MB_INST, 86, 116, 28, 28, 0, 0.95, 0.10, 0.10, 0);
      // Clear liquid lens (40, 80, 120, 100), center (100, 130), refraction = 0 so only zoom shifts sample
      rect_at(zm + 2 * MB_INST, 40, 80, 120, 100, 6, 1, 1, 1, -15);
      zm[2 * MB_INST + 4] = 24;
      zm[2 * MB_INST + 6] = 1;
      zm[2 * MB_INST + 7] = 0.0;  // zoom = 1.0
      zm[2 * MB_INST + 11] = 0.0;
      zm[2 * MB_INST + 12] = 0.0;
      zm[2 * MB_INST + 13] = 8;
      zm[2 * MB_INST + 15] = 1;
      zm[2 * MB_INST + 21] = 0;
      zm[2 * MB_INST + 22] = 0;
      zm[2 * MB_INST + 23] = 0;

      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(zm, 3, 0.05, 0.05, 0.08);
      present_drain();
      uint8_t *px_z1 = read_texture(canvas, &aw, &ah);
      // Probe (116, 130) -> (232, 260) at 2x: outside [86, 114] at zoom=1.0 -> dark background
      uint8_t *z1_p = px_z1 + (260 * aw + 232) * 4;
      CHECK((int)z1_p[2] < 40);
      free(px_z1);

      zm[2 * MB_INST + 7] = -0.25;  // zoom = 1.25 -> sampleBase.x = 100 + 16/1.25 = 112.8 (inside red square!)
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(zm, 3, 0.05, 0.05, 0.08);
      present_drain();
      uint8_t *px_z2 = read_texture(canvas, &aw, &ah);
      uint8_t *z2_p = px_z2 + (260 * aw + 232) * 4;
      CHECK((int)z2_p[2] > 200);
      free(px_z2);

      // Wave 3A (2): global ambient light_angle rotates specular glint by 90 deg and restores bit-exact at 0.0
      double la_inst[2 * MB_INST];
      rect_at(la_inst, 0, 0, 400, 300, 0, 0.10, 0.10, 0.12, 0);
      rect_at(la_inst + 1 * MB_INST, 100, 80, 120, 120, 6, 0.12, 0.12, 0.12, -16);
      la_inst[1 * MB_INST + 4] = 28;
      la_inst[1 * MB_INST + 6] = 1;
      la_inst[1 * MB_INST + 7] = 1.0;
      la_inst[1 * MB_INST + 11] = 0.5;
      la_inst[1 * MB_INST + 12] = 1.0;
      la_inst[1 * MB_INST + 13] = 12;
      la_inst[1 * MB_INST + 15] = 1;
      la_inst[1 * MB_INST + 21] = 0;
      la_inst[1 * MB_INST + 22] = 0;
      la_inst[1 * MB_INST + 23] = 0;

      mb_host_glass_light_angle(0.0);
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(la_inst, 2, 0.10, 0.10, 0.12);
      present_drain();
      uint8_t *px_la0 = read_texture(canvas, &aw, &ah);
      // Top edge (160, 80.5) -> (320, 161); Left edge (100.5, 140) -> (201, 280)
      int top0 = (int)px_la0[(161 * aw + 320) * 4 + 1];
      int left0 = (int)px_la0[(280 * aw + 201) * 4 + 1];
      CHECK(top0 > left0 + 20);

      mb_host_glass_light_angle(1.5707963267948966);  // PI / 2
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(la_inst, 2, 0.10, 0.10, 0.12);
      present_drain();
      uint8_t *px_la90 = read_texture(canvas, &aw, &ah);
      int top90 = (int)px_la90[(161 * aw + 320) * 4 + 1];
      int left90 = (int)px_la90[(280 * aw + 201) * 4 + 1];
      int right90 = (int)px_la90[(280 * aw + 439) * 4 + 1];
      CHECK(left90 > top90 + 20);
      CHECK(right90 > top90 + 20);
      free(px_la90);

      mb_host_glass_light_angle(0.0);
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(la_inst, 2, 0.10, 0.10, 0.12);
      present_drain();
      uint8_t *px_la0_again = read_texture(canvas, &aw, &ah);
      CHECK(memcmp(px_la0, px_la0_again, (size_t)aw * (size_t)ah * 4) == 0);
      free(px_la0);
      free(px_la0_again);

      // Neutral light liquid glass density (kind 6, !is_clear && !is_dark): alpha <= 0.41 keeps the 0.4032 baseline to
      // the byte (0xFDFCFD50 and 0xFDFCFD67 draw the same), while a dense veil (0xFDFCFDD9 ~ 0.851) emits its own alpha
      // and fades transmittance, lift and chroma to 0, so over black it is far brighter and over saturated blue it
      // stays neutral.
      double ld[2 * MB_INST];
      uint8_t *px_ld[5];
      // (alpha byte, backdrop r, g, b)
      static const double ld_case[5][4] = {
          {0x50, 0, 0, 0}, {0x67, 0, 0, 0}, {0xD9, 0, 0, 0}, {0xD9, 0.0, 0.4, 1.0}, {0xFF, 0.0, 0.4, 1.0}};
      for (int i = 0; i < 5; i++) {
        rect_at(ld, 0, 0, 400, 300, 0, ld_case[i][1], ld_case[i][2], ld_case[i][3], 0);
        rect_at(ld + MB_INST, 100, 80, 200, 140, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -17);
        ld[MB_INST + 4] = 28;
        ld[MB_INST + 6] = 1;
        ld[MB_INST + 7] = 1.0;
        ld[MB_INST + 11] = ld_case[i][0] / 255.0;
        ld[MB_INST + 12] = 0.0;
        ld[MB_INST + 13] = 12;
        ld[MB_INST + 15] = 1;
        ld[MB_INST + 21] = 0;
        ld[MB_INST + 22] = 0;
        ld[MB_INST + 23] = 0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(ld, 2, ld_case[i][1], ld_case[i][2], ld_case[i][3]);
        present_drain();
        px_ld[i] = read_texture(canvas, &aw, &ah);
      }
      // centre (200, 150) -> (400, 300) at 2x; the canvas is BGRA
      double ld_lum[5];
      for (int i = 0; i < 5; i++) {
        uint8_t *c = px_ld[i] + (300 * aw + 400) * 4;
        ld_lum[i] = (0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0]) / 255.0;
        printf("apple_render: light glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n",
               (int)ld_case[i][0], ld_case[i][1], ld_case[i][2], ld_case[i][3], c[2], c[1], c[0], ld_lum[i]);
      }
      CHECK(memcmp(px_ld[0], px_ld[1], (size_t)aw * (size_t)ah * 4) == 0);
      CHECK(ld_lum[1] >= 0.49 && ld_lum[1] <= 0.56);
      CHECK(ld_lum[2] >= 0.80 && ld_lum[2] > ld_lum[1] + 0.30);
      CHECK(px_ld[3][(300 * aw + 400) * 4 + 2] >= (int)(0.72 * 255.0 + 0.5));
      uint8_t *c_ff = px_ld[4] + (300 * aw + 400) * 4;
      CHECK(abs((int)c_ff[2] - 253) <= 4 && abs((int)c_ff[1] - 252) <= 4 && abs((int)c_ff[0] - 253) <= 4);
      for (int i = 0; i < 5; i++) free(px_ld[i]);

      // Neutral dark liquid glass density (kind 6, is_dark): alpha <= 0.41 keeps the regular baseline to the byte
      // (0x20202050 and 0x20202067 draw the same), while dense veils (0x202020BF 75%, 0x202020D9 85%) fade
      // transmittance, lift and chroma toward 0, so over white they stay dark for white ink and over saturated blue
      // chroma is cleanly attenuated.
      double dd[2 * MB_INST];
      uint8_t *px_dd[5];
      // (alpha byte, backdrop r, g, b)
      static const double dd_case[5][4] = {
          {0x50, 1, 1, 1}, {0x67, 1, 1, 1}, {0xBF, 1, 1, 1}, {0xD9, 1, 1, 1}, {0xD9, 0.0, 0.4, 1.0}};
      for (int i = 0; i < 5; i++) {
        rect_at(dd, 0, 0, 400, 300, 0, dd_case[i][1], dd_case[i][2], dd_case[i][3], 0);
        rect_at(dd + MB_INST, 100, 80, 200, 140, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -17);
        dd[MB_INST + 4] = 28;
        dd[MB_INST + 6] = 1;
        dd[MB_INST + 7] = 1.0;
        dd[MB_INST + 11] = dd_case[i][0] / 255.0;
        dd[MB_INST + 12] = 0.0;
        dd[MB_INST + 13] = 12;
        dd[MB_INST + 15] = 1;
        dd[MB_INST + 21] = 0;
        dd[MB_INST + 22] = 0;
        dd[MB_INST + 23] = 0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(dd, 2, dd_case[i][1], dd_case[i][2], dd_case[i][3]);
        present_drain();
        px_dd[i] = read_texture(canvas, &aw, &ah);
      }
      double dd_lum[5];
      for (int i = 0; i < 5; i++) {
        uint8_t *c = px_dd[i] + (300 * aw + 400) * 4;
        dd_lum[i] = (0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0]) / 255.0;
        printf("apple_render: dark glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n",
               (int)dd_case[i][0], dd_case[i][1], dd_case[i][2], dd_case[i][3], c[2], c[1], c[0], dd_lum[i]);
      }
      CHECK(memcmp(px_dd[0], px_dd[1], (size_t)aw * (size_t)ah * 4) == 0);
      CHECK(dd_lum[1] >= 0.55 && dd_lum[1] <= 0.74);
      CHECK(dd_lum[2] <= 0.36 && dd_lum[2] <= dd_lum[1] - 0.25);
      CHECK(dd_lum[3] <= 0.30 && dd_lum[3] < dd_lum[2]);
      uint8_t *dd_blue = px_dd[4] + (300 * aw + 400) * 4;
      CHECK(((double)dd_blue[0] - (double)dd_blue[2]) / 255.0 <= 0.28);
      for (int i = 0; i < 5; i++) free(px_dd[i]);

      // Dedicated ONE_KIND=13 (unmerged liquid, merge=0) vs ONE_KIND=6 (merged liquid, merge=1e-7) with large flat
      // interior (inward >= 23), non-zero bevel/refraction/chroma/rim: must be byte-for-byte identical; and zero-copy
      // slot swap across frames + glass_free() must preserve identical pixels without aliasing/double-free.
      dispatch_group_wait(kinds_made, DISPATCH_TIME_FOREVER);
      CHECK(kpipe[5] != nil && kpipe[6] != nil && kpipe[MB_KIND_LIQUID_SINGLE] != nil);
      double lp[3 * MB_INST];
      rect_at(lp, 0, 0, 400, 300, 0, 0.12, 0.24, 0.48, 0);
      rect_at(lp + MB_INST, 120, 90, 160, 120, 0, 0.92, 0.35, 0.18, 0);
      rect_at(lp + 2 * MB_INST, 80, 60, 240, 180, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -18);
      lp[2 * MB_INST + 4] = 28;
      lp[2 * MB_INST + 6] = 1.0;
      lp[2 * MB_INST + 7] = 2.5;
      lp[2 * MB_INST + 11] = 0x67 / 255.0;
      lp[2 * MB_INST + 12] = 0.6;
      lp[2 * MB_INST + 13] = 14.0;
      lp[2 * MB_INST + 15] = 1.0;
      lp[2 * MB_INST + 21] = 18.0;
      lp[2 * MB_INST + 22] = 0.4;
      lp[2 * MB_INST + 23] = 0.0;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lp, 3, 0.12, 0.24, 0.48);
      present_drain();
      uint8_t *px_single = read_texture(canvas, &aw, &ah);

      lp[2 * MB_INST + 23] = 1e-7;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lp, 3, 0.12, 0.24, 0.48);
      present_drain();
      uint8_t *px_merged = read_texture(canvas, &aw, &ah);
      CHECK(memcmp(px_single, px_merged, (size_t)aw * (size_t)ah * 4) == 0);
      free(px_merged);

      // Zero-copy slot swap across moving backdrop frames + glass_free() + re-render parity.
      lp[2 * MB_INST + 23] = 0.0;
      for (int step = 1; step <= 4; step++) {
        lp[MB_INST + 0] = 120 + step * 5;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(lp, 3, 0.12, 0.24, 0.48);
        present_drain();
      }
      dispatch_sync(present_q, ^{ glass_free(); });
      lp[MB_INST + 0] = 120;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lp, 3, 0.12, 0.24, 0.48);
      present_drain();
      uint8_t *px_after_free = read_texture(canvas, &aw, &ah);
      CHECK(memcmp(px_single, px_after_free, (size_t)aw * (size_t)ah * 4) == 0);
      free(px_single);
      free(px_after_free);

      // Wave 7: adaptive liquid glass (slot 14 = -1.0) + adaptive kind 10 neutral/chromatic ink:
      // 0: light glass over white (bg=1.0) -> light glass + dark ink
      // 1: light glass over black (bg=0.0) -> dark glass + light ink
      // 2: light glass over a linear ~50% mid-tone (bg=0.72, 0.72^2 = 0.52) -> stays light glass + dark ink
      // 3: dark glass (0x20202067) over white (bg=1.0) -> smoked glass surface stays dark-tinted, while light ink
      //    flips dark when composited backdrop luma >= 0.55 so contrast stays >= 3:1 (measured ~8.44:1)
      double ad[4 * MB_INST];
      // 4: light glass over Apple blue #007AFF -> dark ink flips white (sRGB luma 0.414 sat on the dark edge;
      //    the ink decision reads linear-ish luma c*c, 0.236, well inside the dark side)
      // 5: light glass over light gray #F5F5F7 -> stays light glass + dark ink
      struct { double bg, bg_g, bg_b; int dark_glass; double ink; } w7_cases[6] = {
        {1.0, 1.0, 1.0, 0, 0.11},
        {0.0, 0.0, 0.0, 0, 0.11},
        {0.72, 0.72, 0.72, 0, 0.11},
        {1.0, 1.0, 1.0, 1, 0.93},
        {0.0, 122.0 / 255.0, 1.0, 0, 0.11},
        {245.0 / 255.0, 245.0 / 255.0, 247.0 / 255.0, 0, 0.11},
      };
      for (int ci = 0; ci < 6; ci++) {
        double bg = w7_cases[ci].bg, bg_g = w7_cases[ci].bg_g, bg_b = w7_cases[ci].bg_b;
        int dg = w7_cases[ci].dark_glass;
        double ink = w7_cases[ci].ink;
        rect_at(ad, 0, 0, 400, 300, 0, bg, bg_g, bg_b, 0);
        rect_at(ad + MB_INST, 100, 80, 200, 140, 6,
                dg ? 32.0 / 255.0 : 253.0 / 255.0,
                dg ? 32.0 / 255.0 : 252.0 / 255.0,
                dg ? 32.0 / 255.0 : 253.0 / 255.0, -19);
        ad[MB_INST + 4] = 28;
        ad[MB_INST + 6] = 1.0;
        ad[MB_INST + 7] = 2.0;
        ad[MB_INST + 11] = 0x67 / 255.0;
        ad[MB_INST + 12] = 0.0;
        ad[MB_INST + 13] = 14.0;
        ad[MB_INST + 14] = -1.0;  // adaptive=true, no spot
        ad[MB_INST + 15] = 1.0;
        ad[MB_INST + 21] = 0.0;
        ad[MB_INST + 22] = 0.0;
        ad[MB_INST + 23] = 0.0;
        // Neutral line inside glass at y=120 (x=140..180)
        rect_at(ad + 2 * MB_INST, 130, 110, 60, 20, 10, ink, ink, ink, 0);
        ad[2 * MB_INST + 4] = 4.0;
        ad[2 * MB_INST + 12] = 0.1;
        ad[2 * MB_INST + 13] = 0.5;
        ad[2 * MB_INST + 14] = 0.9;
        ad[2 * MB_INST + 15] = 0.5;
        ad[2 * MB_INST + 21] = 200.0;
        ad[2 * MB_INST + 22] = 150.0;
        ad[2 * MB_INST + 23] = 70.0;
        // Chromatic accent line inside glass at y=180 (x=140..180): must preserve color on dark backdrop
        rect_at(ad + 3 * MB_INST, 130, 170, 60, 20, 10, 0.90, 0.30, 0.15, 0);
        ad[3 * MB_INST + 4] = 4.0;
        ad[3 * MB_INST + 12] = 0.1;
        ad[3 * MB_INST + 13] = 0.5;
        ad[3 * MB_INST + 14] = 0.9;
        ad[3 * MB_INST + 15] = 0.5;
        ad[3 * MB_INST + 21] = 200.0;
        ad[3 * MB_INST + 22] = 150.0;
        ad[3 * MB_INST + 23] = 70.0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(ad, 4, bg, bg_g, bg_b);
        present_drain();
        uint8_t *px_ad = read_texture(canvas, &aw, &ah);
        // Glass interior at (240, 150) -> (480, 300) at 2x (BGRA)
        uint8_t *gp = px_ad + (300 * aw + 480) * 4;
        double g_lum = (0.2126 * gp[2] + 0.7152 * gp[1] + 0.0722 * gp[0]) / 255.0;
        // Neutral line center at (160, 120) -> (320, 240)
        uint8_t *np = px_ad + (240 * aw + 320) * 4;
        double n_lum = (0.2126 * np[2] + 0.7152 * np[1] + 0.0722 * np[0]) / 255.0;
        // Chromatic line center at (160, 180) -> (320, 360)
        uint8_t *cp = px_ad + (360 * aw + 320) * 4;
        printf("apple_render: wave7 case=%d bg=%.2f dg=%d glass=%.3f neutral_ink=%.3f chroma_rgb=%d,%d,%d\n",
               ci, bg, dg, g_lum, n_lum, cp[2], cp[1], cp[0]);
        if (ci == 0) {
          CHECK(g_lum > 0.75);
          CHECK(n_lum < 0.25);
        } else if (ci == 1) {
          CHECK(g_lum < 0.20);
          CHECK(n_lum > 0.80);
        } else if (ci == 2) {
          CHECK(g_lum > 0.55);
          CHECK(n_lum < 0.25);
        } else if (ci == 3) {
          CHECK(g_lum >= 0.55 && g_lum <= 0.78);
          CHECK(n_lum < 0.25);
        } else if (ci == 4) {
          CHECK(g_lum > 0.55);
          CHECK(n_lum < 0.25);
        } else {
          CHECK(g_lum > 0.75);
          CHECK(n_lum < 0.25);
        }
        CHECK((int)cp[2] > (int)cp[0] + 120);
        free(px_ad);
      }

      // Wave 7b: adaptive kind 0 translucent hover wash (pad.w < 0, 0x0000001C) inside adaptive=true light glass:
      // 0: white (bg=1.0) -> stays darkened; 1: black (bg=0.0) -> flips luminous white; 2: Apple blue #007AFF -> flips luminous white.
      {
        double ahov[3 * MB_INST];
        struct { double r, g, b; } hov_cases[3] = {
          {1.0, 1.0, 1.0},
          {0.0, 0.0, 0.0},
          {0.0, 122.0 / 255.0, 1.0},
        };
        for (int ci = 0; ci < 3; ci++) {
          double bg = hov_cases[ci].r, bg_g = hov_cases[ci].g, bg_b = hov_cases[ci].b;
          rect_at(ahov, 0, 0, 400, 300, 0, bg, bg_g, bg_b, 0);
          rect_at(ahov + MB_INST, 100, 80, 200, 140, 6,
                  253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
          ahov[MB_INST + 4] = 28;
          ahov[MB_INST + 6] = 1.0;
          ahov[MB_INST + 7] = 2.0;
          ahov[MB_INST + 11] = 0x67 / 255.0;
          ahov[MB_INST + 12] = 0.0;
          ahov[MB_INST + 13] = 14.0;
          ahov[MB_INST + 14] = -1.0;
          ahov[MB_INST + 15] = 1.0;
          ahov[MB_INST + 21] = 0.0;
          ahov[MB_INST + 22] = 0.0;
          ahov[MB_INST + 23] = 0.0;
          // Adaptive kind 0 translucent dark hover disc (0x0000001C) on left half of glass
          rect_at(ahov + 2 * MB_INST, 120, 120, 60, 60, 0, 0.0, 0.0, 0.0, 0);
          ahov[2 * MB_INST + 4] = 30.0;
          ahov[2 * MB_INST + 11] = 0x1C / 255.0;
          ahov[2 * MB_INST + 21] = 200.0;
          ahov[2 * MB_INST + 22] = 150.0;
          ahov[2 * MB_INST + 23] = -70.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ahov, 3, bg, bg_g, bg_b);
          present_drain();
          uint8_t *px_h = read_texture(canvas, &aw, &ah);
          uint8_t *gp = px_h + (300 * aw + 480) * 4;
          double g_lum = (0.2126 * gp[2] + 0.7152 * gp[1] + 0.0722 * gp[0]) / 255.0;
          uint8_t *hp = px_h + (300 * aw + 300) * 4;
          double h_lum = (0.2126 * hp[2] + 0.7152 * hp[1] + 0.0722 * hp[0]) / 255.0;
          printf("apple_render: wave7b_hover case=%d glass=%.3f hover=%.3f delta=%+.3f\n",
                 ci, g_lum, h_lum, h_lum - g_lum);
          if (ci == 0 || ci == 2) {
            CHECK(h_lum < g_lum - 0.03);
          } else {
            CHECK(h_lum > g_lum + 0.08);
          }
          free(px_h);
        }
      }

      // Smooth fogging on adaptive flip: thin bright stripe over black is softened by dual-ring fog blur + higher darkDens
      double fg[3 * MB_INST];
      double fog_peaks[2] = {0.0, 0.0};
      for (int adaptive_on = 0; adaptive_on <= 1; adaptive_on++) {
        rect_at(fg, 0, 0, 400, 300, 0, 0.0, 0.0, 0.0, 0);
        // Place the thin 2pt white stripe at y=165 (off the 5-point luma sample cross at y=150 and y=150+/-35)
        rect_at(fg + MB_INST, 80, 164, 240, 2, 0, 1.0, 1.0, 1.0, 0);
        rect_at(fg + 2 * MB_INST, 100, 80, 200, 140, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -20);
        fg[2 * MB_INST + 4] = 28;
        fg[2 * MB_INST + 6] = 1.0;
        fg[2 * MB_INST + 7] = 1.0;
        fg[2 * MB_INST + 11] = 0x67 / 255.0;
        fg[2 * MB_INST + 12] = 0.0;
        fg[2 * MB_INST + 13] = 14.0;
        fg[2 * MB_INST + 14] = adaptive_on ? -1.0 : 0.0;
        fg[2 * MB_INST + 15] = 1.0;
        fg[2 * MB_INST + 21] = 0.0;
        fg[2 * MB_INST + 22] = 0.0;
        fg[2 * MB_INST + 23] = 0.0;
        // Over black, light tint with adaptive_on triggers fogT=1.0; compare against non-adaptive dark tint
        if (adaptive_on) {
          fg[2 * MB_INST + 8] = 253.0 / 255.0;
          fg[2 * MB_INST + 9] = 252.0 / 255.0;
          fg[2 * MB_INST + 10] = 253.0 / 255.0;
        }
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(fg, 3, 0.0, 0.0, 0.0);
        present_drain();
        uint8_t *px_fg = read_texture(canvas, &aw, &ah);
        uint8_t *sp = px_fg + (330 * aw + 400) * 4;  // (200, 165) on the bright 2pt stripe
        fog_peaks[adaptive_on] = (0.2126 * sp[2] + 0.7152 * sp[1] + 0.0722 * sp[0]) / 255.0;
        free(px_fg);
      }
      printf("apple_render: wave7 fog stripe peak plain_dark=%.3f adaptive_fog=%.3f\n",
             fog_peaks[0], fog_peaks[1]);
      CHECK(fog_peaks[1] < fog_peaks[0] - 0.08);
      CHECK(fog_peaks[1] <= 0.30);

      // Test A: wide 320x36pt adaptive capsule over deep navy #173255 with centered 60x24pt pure white "{less}" block
      // must resist ping-pong flipping (trimmed mean stays dark -> dark glass + white ink).
      double ta[4 * MB_INST];
      rect_at(ta, 0, 0, 400, 300, 0, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0, 0);
      rect_at(ta + MB_INST, 170, 138, 60, 24, 0, 1.0, 1.0, 1.0, 0);
      rect_at(ta + 2 * MB_INST, 40, 132, 320, 36, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -21);
      ta[2 * MB_INST + 4] = 18.0;
      ta[2 * MB_INST + 6] = 1.0;
      ta[2 * MB_INST + 7] = 2.0;
      ta[2 * MB_INST + 11] = 0x67 / 255.0;
      ta[2 * MB_INST + 12] = 0.0;
      ta[2 * MB_INST + 13] = 14.0;
      ta[2 * MB_INST + 14] = -1.0;
      ta[2 * MB_INST + 15] = 1.0;
      ta[2 * MB_INST + 21] = 0.0;
      ta[2 * MB_INST + 22] = 0.0;
      ta[2 * MB_INST + 23] = 0.0;
      rect_at(ta + 3 * MB_INST, 70, 140, 60, 20, 10, 0.11, 0.11, 0.11, 0);
      ta[3 * MB_INST + 4] = 4.0;
      ta[3 * MB_INST + 12] = 0.1;
      ta[3 * MB_INST + 13] = 0.5;
      ta[3 * MB_INST + 14] = 0.9;
      ta[3 * MB_INST + 15] = 0.5;
      ta[3 * MB_INST + 21] = 200.0;
      ta[3 * MB_INST + 22] = 150.0;
      ta[3 * MB_INST + 23] = 36.0;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(ta, 4, 23.0 / 255.0, 50.0 / 255.0, 85.0 / 255.0);
      present_drain();
      uint8_t *px_ta = read_texture(canvas, &aw, &ah);
      uint8_t *ta_gp = px_ta + (300 * aw + 560) * 4;  // (280, 150) glass over navy
      uint8_t *ta_np = px_ta + (300 * aw + 200) * 4;  // (100, 150) neutral ink inside capsule
      double ta_g = (0.2126 * ta_gp[2] + 0.7152 * ta_gp[1] + 0.0722 * ta_gp[0]) / 255.0;
      double ta_n = (0.2126 * ta_np[2] + 0.7152 * ta_np[1] + 0.0722 * ta_np[0]) / 255.0;
      printf("apple_render: wave7 testA wide_less glass=%.3f ink=%.3f\n", ta_g, ta_n);
      CHECK(ta_g < 0.28);
      CHECK(ta_n > 0.80);
      free(px_ta);

      // Test B: cross-frame temporal smoothing + synchronized glass/ink + Schmitt hysteresis + auto-settle stop
      mb_render_set_fixed_dt(1.0 / 60.0);
      double tb[3 * MB_INST];
      rect_at(tb, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
      rect_at(tb + MB_INST, 40, 132, 320, 36, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -22);
      tb[MB_INST + 4] = 18.0;
      tb[MB_INST + 6] = 1.0;
      tb[MB_INST + 7] = 2.0;
      tb[MB_INST + 11] = 0x67 / 255.0;
      tb[MB_INST + 12] = 0.0;
      tb[MB_INST + 13] = 14.0;
      tb[MB_INST + 14] = -1.0;
      tb[MB_INST + 15] = 1.0;
      tb[MB_INST + 21] = 0.0;
      tb[MB_INST + 22] = 0.0;
      tb[MB_INST + 23] = 0.0;
      rect_at(tb + 2 * MB_INST, 70, 140, 60, 20, 10, 0.11, 0.11, 0.11, 0);
      tb[2 * MB_INST + 4] = 4.0;
      tb[2 * MB_INST + 12] = 0.1;
      tb[2 * MB_INST + 13] = 0.5;
      tb[2 * MB_INST + 14] = 0.9;
      tb[2 * MB_INST + 15] = 0.5;
      tb[2 * MB_INST + 21] = 200.0;
      tb[2 * MB_INST + 22] = 150.0;
      tb[2 * MB_INST + 23] = 36.0;

      // Frame 0: pure white -> instant light state
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(tb, 3, 1.0, 1.0, 1.0);
      present_drain();
      uint8_t *px_tb = read_texture(canvas, &aw, &ah);
      double f0_g = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
      double f0_n = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
      free(px_tb);
      printf("apple_render: wave7 testB f0_white glass=%.3f ink=%.3f\n", f0_g, f0_n);
      CHECK(f0_g > 0.75);
      CHECK(f0_n < 0.25);

      // Frame 1: switch to deep navy #173255 -> intermediate state (no 1-frame hard jump)
      tb[8] = 23.0 / 255.0; tb[9] = 50.0 / 255.0; tb[10] = 85.0 / 255.0;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(tb, 3, tb[8], tb[9], tb[10]);
      present_drain();
      px_tb = read_texture(canvas, &aw, &ah);
      double f1_g = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
      double f1_n = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
      free(px_tb);
      printf("apple_render: wave7 testB f1_navy glass=%.3f ink=%.3f settling=%d\n", f1_g, f1_n, mb_render_adaptive_settling());
      CHECK(f1_g > 0.28 && f1_g < 0.72);
      CHECK(f1_n > 0.15 && f1_n < 0.75);
      CHECK(mb_render_adaptive_settling() == 1);

      // Step 25 more frames (~420ms): monotonic convergence to dark state
      double prev_g = f1_g, prev_n = f1_n;
      for (int s = 0; s < 25; s++) {
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(tb, 3, tb[8], tb[9], tb[10]);
        present_drain();
        px_tb = read_texture(canvas, &aw, &ah);
        double cg = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
        double cn = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
        free(px_tb);
        CHECK(cg <= prev_g + 0.015);
        CHECK(cn >= prev_n - 0.015);
        prev_g = cg;
        prev_n = cn;
      }
      printf("apple_render: wave7 testB f26_dark glass=%.3f ink=%.3f settling=%d\n", prev_g, prev_n, mb_render_adaptive_settling());
      CHECK(prev_g < 0.28);
      CHECK(prev_n > 0.85);

      // Schmitt hysteresis: bg=0.40 (in [0.36, 0.46]) for 25 frames stays dark
      tb[8] = 0.40; tb[9] = 0.40; tb[10] = 0.40;
      for (int s = 0; s < 25; s++) {
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(tb, 3, 0.40, 0.40, 0.40);
        present_drain();
      }
      px_tb = read_texture(canvas, &aw, &ah);
      double hyst_g = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
      double hyst_n = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
      free(px_tb);
      printf("apple_render: wave7 testB hyst_0.40 glass=%.3f ink=%.3f\n", hyst_g, hyst_n);
      CHECK(hyst_g < 0.40);
      CHECK(hyst_n > 0.80);

      // Return to bright bg=0.95: frame 1 intermediate, +26 frames settles back to light and stops settling
      tb[8] = 0.95; tb[9] = 0.95; tb[10] = 0.95;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(tb, 3, 0.95, 0.95, 0.95);
      present_drain();
      px_tb = read_texture(canvas, &aw, &ah);
      double r1_g = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
      double r1_n = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
      free(px_tb);
      printf("apple_render: wave7 testB return_f1 glass=%.3f ink=%.3f\n", r1_g, r1_n);
      CHECK(r1_g > 0.30 && r1_g < 0.82);
      CHECK(r1_n > 0.20 && r1_n < 0.88);
      for (int s = 0; s < 26; s++) {
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(tb, 3, 0.95, 0.95, 0.95);
        present_drain();
      }
      px_tb = read_texture(canvas, &aw, &ah);
      double r_end_g = (0.2126 * px_tb[(300 * aw + 560) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 560) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 560) * 4 + 0]) / 255.0;
      double r_end_n = (0.2126 * px_tb[(300 * aw + 200) * 4 + 2] + 0.7152 * px_tb[(300 * aw + 200) * 4 + 1] + 0.0722 * px_tb[(300 * aw + 200) * 4 + 0]) / 255.0;
      free(px_tb);
      printf("apple_render: wave7 testB return_end glass=%.3f ink=%.3f settling=%d\n", r_end_g, r_end_n, mb_render_adaptive_settling());
      CHECK(r_end_g > 0.75);
      CHECK(r_end_n < 0.25);
      CHECK(mb_render_adaptive_settling() == 0);
      // Caret / instance drawn ABOVE the glass changing must NOT re-trigger adaptive settling.
      double tb4[4 * MB_INST];
      memcpy(tb4, tb, 3 * MB_INST * sizeof(double));
      rect_at(tb4 + 3 * MB_INST, 10, 10, 2, 16, 0, 0.1, 0.1, 0.1, 0);
      mb_host_render_dirty(0, 0, 40, 40);
      mb_render_present(tb4, 4, 0.95, 0.95, 0.95);
      present_drain();
      CHECK(mb_render_adaptive_settling() == 0);
      tb4[3 * MB_INST + 0] = 20;
      mb_host_render_dirty(0, 0, 40, 40);
      mb_render_present(tb4, 4, 0.95, 0.95, 0.95);
      present_drain();
      CHECK(mb_render_adaptive_settling() == 0);
      // Kind 7 (adaptive glyph) has its own specialized pipeline.
      CHECK(has_own_pipe(7) == 1);
      // Same-side backdrop change (0.95 -> 0.93, both light) converges early via async readback instead of spinning
      // for the full 420ms settle window.
      tb[8] = 0.93; tb[9] = 0.93; tb[10] = 0.93;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(tb, 3, 0.93, 0.93, 0.93);
      present_drain();
      for (int s = 0; s < 4 && mb_render_adaptive_settling(); s++) {
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(tb, 3, 0.93, 0.93, 0.93);
        present_drain();
      }
      CHECK(mb_render_adaptive_settling() == 0);
      mb_render_set_fixed_dt(0.0);
      glass_forget();

      // Test C: wide 320x44pt adaptive light capsule spanning left 45% dark (#141418) + right 55% white (#FFFFFF).
      // Verifies: whole capsule stays light, left-half neutral ink (kind 10 & kind 7) inverts bright locally,
      // right-half neutral ink stays dark, left chromatic accent preserves hue, out-of-bd elements stay dark,
      // and expanding to full dark converges the whole capsule and all ink to dark glass with light ink.
      {
        uint8_t solid_glyph[16 * 16];
        memset(solid_glyph, 255, sizeof(solid_glyph));
        mb_atlas_upload(0, 16, 16, 16, 16, solid_glyph);
        double tc[9 * MB_INST];
        rect_at(tc, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(tc + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
        rect_at(tc + 2 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -23);
        tc[2 * MB_INST + 4] = 22.0;
        tc[2 * MB_INST + 6] = 1.0;
        tc[2 * MB_INST + 7] = 2.0;
        tc[2 * MB_INST + 11] = 0x67 / 255.0;
        tc[2 * MB_INST + 12] = 0.0;
        tc[2 * MB_INST + 13] = 14.0;
        tc[2 * MB_INST + 14] = -1.0;
        tc[2 * MB_INST + 15] = 1.0;
        tc[2 * MB_INST + 21] = 0.0;
        tc[2 * MB_INST + 22] = 0.0;
        tc[2 * MB_INST + 23] = 0.0;
        // 3: Left subtle ink (kind 10) at center (72, 150)
        rect_at(tc + 3 * MB_INST, 60, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[3 * MB_INST + 4] = 4.0;
        tc[3 * MB_INST + 12] = 0.1; tc[3 * MB_INST + 13] = 0.5;
        tc[3 * MB_INST + 14] = 0.9; tc[3 * MB_INST + 15] = 0.5;
        tc[3 * MB_INST + 21] = 200.0; tc[3 * MB_INST + 22] = 150.0; tc[3 * MB_INST + 23] = 44.0;
        // 4: Left text glyph (kind 7) at center (104, 150)
        rect_at(tc + 4 * MB_INST, 96, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[4 * MB_INST + 12] = 16.0; tc[4 * MB_INST + 13] = 16.0;
        tc[4 * MB_INST + 14] = 16.0; tc[4 * MB_INST + 15] = 16.0;
        tc[4 * MB_INST + 21] = 200.0; tc[4 * MB_INST + 22] = 150.0; tc[4 * MB_INST + 23] = 44.0;
        // 5: Left chromatic accent (kind 10) at center (136, 150)
        rect_at(tc + 5 * MB_INST, 124, 140, 24, 20, 10, 0.90, 0.30, 0.15, 0);
        tc[5 * MB_INST + 4] = 4.0;
        tc[5 * MB_INST + 12] = 0.1; tc[5 * MB_INST + 13] = 0.5;
        tc[5 * MB_INST + 14] = 0.9; tc[5 * MB_INST + 15] = 0.5;
        tc[5 * MB_INST + 21] = 200.0; tc[5 * MB_INST + 22] = 150.0; tc[5 * MB_INST + 23] = 44.0;
        // 6: Right subtle ink (kind 10) at center (232, 150)
        rect_at(tc + 6 * MB_INST, 220, 140, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[6 * MB_INST + 4] = 4.0;
        tc[6 * MB_INST + 12] = 0.1; tc[6 * MB_INST + 13] = 0.5;
        tc[6 * MB_INST + 14] = 0.9; tc[6 * MB_INST + 15] = 0.5;
        tc[6 * MB_INST + 21] = 200.0; tc[6 * MB_INST + 22] = 150.0; tc[6 * MB_INST + 23] = 44.0;
        // 7: Right text glyph (kind 7) at center (268, 150)
        rect_at(tc + 7 * MB_INST, 260, 142, 16, 16, 7, 0.14, 0.15, 0.17, 0);
        tc[7 * MB_INST + 12] = 16.0; tc[7 * MB_INST + 13] = 16.0;
        tc[7 * MB_INST + 14] = 16.0; tc[7 * MB_INST + 15] = 16.0;
        tc[7 * MB_INST + 21] = 200.0; tc[7 * MB_INST + 22] = 150.0; tc[7 * MB_INST + 23] = 44.0;
        // 8: Out-of-bd guard (kind 10) at (16, 16), outside capsule bd capture rect: must NOT sample clamped dark edge
        rect_at(tc + 8 * MB_INST, 4, 6, 24, 20, 10, 0.34, 0.36, 0.38, 0);
        tc[8 * MB_INST + 4] = 4.0;
        tc[8 * MB_INST + 12] = 0.1; tc[8 * MB_INST + 13] = 0.5;
        tc[8 * MB_INST + 14] = 0.9; tc[8 * MB_INST + 15] = 0.5;
        tc[8 * MB_INST + 21] = 200.0; tc[8 * MB_INST + 22] = 150.0; tc[8 * MB_INST + 23] = 44.0;

        mb_render_set_fixed_dt(1.0 / 60.0);
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(tc, 9, 1.0, 1.0, 1.0);
        present_drain();
        uint8_t *px_tc = read_texture(canvas, &aw, &ah);
        uint8_t *p_ls = px_tc + (300 * aw + 144) * 4;
        uint8_t *p_lt = px_tc + (300 * aw + 208) * 4;
        uint8_t *p_lc = px_tc + (300 * aw + 272) * 4;
        uint8_t *p_rs = px_tc + (300 * aw + 464) * 4;
        uint8_t *p_rt = px_tc + (300 * aw + 536) * 4;
        uint8_t *p_rg = px_tc + (300 * aw + 620) * 4;
        uint8_t *p_ob = px_tc + (32 * aw + 32) * 4;
        double l_sub = (0.2126 * p_ls[2] + 0.7152 * p_ls[1] + 0.0722 * p_ls[0]) / 255.0;
        double l_txt = (0.2126 * p_lt[2] + 0.7152 * p_lt[1] + 0.0722 * p_lt[0]) / 255.0;
        double r_sub = (0.2126 * p_rs[2] + 0.7152 * p_rs[1] + 0.0722 * p_rs[0]) / 255.0;
        double r_txt = (0.2126 * p_rt[2] + 0.7152 * p_rt[1] + 0.0722 * p_rt[0]) / 255.0;
        double g_right = (0.2126 * p_rg[2] + 0.7152 * p_rg[1] + 0.0722 * p_rg[0]) / 255.0;
        double oob_sub = (0.2126 * p_ob[2] + 0.7152 * p_ob[1] + 0.0722 * p_ob[0]) / 255.0;
        printf("apple_render: wave7 testC half_dark l_sub=%.3f l_txt=%.3f r_sub=%.3f r_txt=%.3f g_right=%.3f oob=%.3f chroma=%d,%d,%d\n",
               l_sub, l_txt, r_sub, r_txt, g_right, oob_sub, p_lc[2], p_lc[1], p_lc[0]);
        CHECK(l_sub > 0.82);
        CHECK(l_txt > 0.82);
        CHECK(r_sub < 0.45);
        CHECK(r_txt < 0.45);
        CHECK(g_right > 0.75);
        CHECK(oob_sub < 0.45);
        CHECK((int)p_lc[2] > (int)p_lc[0] + 120);
        free(px_tc);

        // Expand dark backdrop from 45% to 100% across 20 frames + 10 settle frames:
        // whole capsule and all ink converge to dark glass with light ink.
        double min_l_sub = 1.0, min_l_txt = 1.0, end_r_sub = 0.0, end_g_right = 1.0;
        for (int s = 0; s < 30; s++) {
          double t = s < 20 ? (double)(s + 1) / 20.0 : 1.0;
          tc[MB_INST + 2] = 184.0 + (400.0 - 184.0) * t;
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tc, 9, 1.0, 1.0, 1.0);
          present_drain();
          px_tc = read_texture(canvas, &aw, &ah);
          p_ls = px_tc + (300 * aw + 144) * 4;
          p_lt = px_tc + (300 * aw + 208) * 4;
          p_rs = px_tc + (300 * aw + 464) * 4;
          p_rg = px_tc + (300 * aw + 620) * 4;
          double cs = (0.2126 * p_ls[2] + 0.7152 * p_ls[1] + 0.0722 * p_ls[0]) / 255.0;
          double ct = (0.2126 * p_lt[2] + 0.7152 * p_lt[1] + 0.0722 * p_lt[0]) / 255.0;
          end_r_sub = (0.2126 * p_rs[2] + 0.7152 * p_rs[1] + 0.0722 * p_rs[0]) / 255.0;
          end_g_right = (0.2126 * p_rg[2] + 0.7152 * p_rg[1] + 0.0722 * p_rg[0]) / 255.0;
          if (cs < min_l_sub) min_l_sub = cs;
          if (ct < min_l_txt) min_l_txt = ct;
          free(px_tc);
        }
        printf("apple_render: wave7 testC scroll_to_full min_l_sub=%.3f min_l_txt=%.3f end_r_sub=%.3f end_g_right=%.3f\n",
               min_l_sub, min_l_txt, end_r_sub, end_g_right);
        CHECK(end_r_sub > 0.68);
        CHECK(end_g_right < 0.35);

        // Test D: small 240x30pt adaptive capsule (half_w=120, half_h=15) straddling a horizontal white/dark edge
        // (top white #FFFFFF, bottom dark #141418 starting at y=152; capsule average luma > 0.45 stays light).
        // Two adjacent kind-7 glyphs simulating uppercase 'H' (upper box) and lowercase 'o' (lower box):
        // small capsules disable local ink override, so both glyphs stay dark (< 0.35) with matching luma.
        {
          double td[5 * MB_INST];
          rect_at(td, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(td + MB_INST, 0, 152, 400, 148, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
          rect_at(td + 2 * MB_INST, 80, 135, 240, 30, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -24);
          td[2 * MB_INST + 4] = 15.0;
          td[2 * MB_INST + 6] = 1.0;
          td[2 * MB_INST + 7] = 2.0;
          td[2 * MB_INST + 11] = 0x67 / 255.0;
          td[2 * MB_INST + 12] = 0.0;
          td[2 * MB_INST + 13] = 12.0;
          td[2 * MB_INST + 14] = -1.0;
          td[2 * MB_INST + 15] = 1.0;
          // 3: uppercase 'H' glyph (upper box, center y=144 in white)
          rect_at(td + 3 * MB_INST, 180, 138, 12, 12, 7, 0.14, 0.15, 0.17, 0);
          td[3 * MB_INST + 12] = 16.0; td[3 * MB_INST + 13] = 16.0;
          td[3 * MB_INST + 14] = 16.0; td[3 * MB_INST + 15] = 16.0;
          td[3 * MB_INST + 21] = 200.0; td[3 * MB_INST + 22] = 150.0; td[3 * MB_INST + 23] = 30.0;
          // 4: lowercase 'o' glyph (lower box, center y=158 in dark)
          rect_at(td + 4 * MB_INST, 196, 153, 12, 10, 7, 0.14, 0.15, 0.17, 0);
          td[4 * MB_INST + 12] = 16.0; td[4 * MB_INST + 13] = 16.0;
          td[4 * MB_INST + 14] = 16.0; td[4 * MB_INST + 15] = 16.0;
          td[4 * MB_INST + 21] = 200.0; td[4 * MB_INST + 22] = 150.0; td[4 * MB_INST + 23] = 30.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(td, 5, 1.0, 1.0, 1.0);
          present_drain();
          uint8_t *px_td = read_texture(canvas, &aw, &ah);
          uint8_t *p_H = px_td + (288 * aw + 372) * 4;
          uint8_t *p_o = px_td + (316 * aw + 404) * 4;
          double l_H = (0.2126 * p_H[2] + 0.7152 * p_H[1] + 0.0722 * p_H[0]) / 255.0;
          double l_o = (0.2126 * p_o[2] + 0.7152 * p_o[1] + 0.0722 * p_o[0]) / 255.0;
          printf("apple_render: wave7 testD small_pill_no_local l_H=%.3f l_o=%.3f\n", l_H, l_o);
          CHECK(l_H < 0.35);
          CHECK(l_o < 0.35);
          CHECK(fabs(l_H - l_o) < 0.05);
          free(px_td);
        }

        // Test E1: expanded 320x80pt large capsule (capHalf.y=40 > 28) with dark quadrant 0..184 x 0..152.
        // Center-relative offsets in slots 6-7: tall 'H' (y=138..148) and short 'o' (y=154..164) share line_cy=142,
        // and trailing 'i' (x=180..192 straddling x=184) shifts slot 6 to word center x=160: all 3 invert bright (> 0.82).
        {
          double te1[6 * MB_INST];
          rect_at(te1, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(te1 + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
          rect_at(te1 + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -25);
          te1[2 * MB_INST + 4] = 22.0;
          te1[2 * MB_INST + 6] = 1.0;
          te1[2 * MB_INST + 7] = 2.0;
          te1[2 * MB_INST + 11] = 0x67 / 255.0;
          te1[2 * MB_INST + 12] = 0.0;
          te1[2 * MB_INST + 13] = 14.0;
          te1[2 * MB_INST + 14] = -1.0;
          te1[2 * MB_INST + 15] = 1.0;
          // 3: uppercase 'H' (96, 138, 12, 10), center (102, 143), target (102, 142)
          rect_at(te1 + 3 * MB_INST, 96, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
          te1[3 * MB_INST + 6] = 0.0; te1[3 * MB_INST + 7] = 142.0 - 143.0;
          te1[3 * MB_INST + 12] = 16.0; te1[3 * MB_INST + 13] = 16.0;
          te1[3 * MB_INST + 14] = 16.0; te1[3 * MB_INST + 15] = 16.0;
          te1[3 * MB_INST + 21] = 200.0; te1[3 * MB_INST + 22] = 150.0; te1[3 * MB_INST + 23] = 80.0;
          // 4: lowercase 'o' (112, 154, 12, 10), center (118, 159), target (118, 142)
          rect_at(te1 + 4 * MB_INST, 112, 154, 12, 10, 7, 0.14, 0.15, 0.17, 0);
          te1[4 * MB_INST + 6] = 0.0; te1[4 * MB_INST + 7] = 142.0 - 159.0;
          te1[4 * MB_INST + 12] = 16.0; te1[4 * MB_INST + 13] = 16.0;
          te1[4 * MB_INST + 14] = 16.0; te1[4 * MB_INST + 15] = 16.0;
          te1[4 * MB_INST + 21] = 200.0; te1[4 * MB_INST + 22] = 150.0; te1[4 * MB_INST + 23] = 80.0;
          // 5: trailing 'i' (180, 138, 12, 10), center (186, 143) straddling x=184, target word center (160, 142)
          rect_at(te1 + 5 * MB_INST, 180, 138, 12, 10, 7, 0.14, 0.15, 0.17, 0);
          te1[5 * MB_INST + 6] = 160.0 - 186.0; te1[5 * MB_INST + 7] = 142.0 - 143.0;
          te1[5 * MB_INST + 12] = 16.0; te1[5 * MB_INST + 13] = 16.0;
          te1[5 * MB_INST + 14] = 16.0; te1[5 * MB_INST + 15] = 16.0;
          te1[5 * MB_INST + 21] = 200.0; te1[5 * MB_INST + 22] = 150.0; te1[5 * MB_INST + 23] = 80.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(te1, 6, 1.0, 1.0, 1.0);
          present_drain();
          uint8_t *px_e1 = read_texture(canvas, &aw, &ah);
          uint8_t *p_H = px_e1 + (286 * aw + 204) * 4;
          uint8_t *p_o = px_e1 + (318 * aw + 236) * 4;
          uint8_t *p_i = px_e1 + (286 * aw + 372) * 4;
          double l_H = (0.2126 * p_H[2] + 0.7152 * p_H[1] + 0.0722 * p_H[0]) / 255.0;
          double l_o = (0.2126 * p_o[2] + 0.7152 * p_o[1] + 0.0722 * p_o[0]) / 255.0;
          double l_i = (0.2126 * p_i[2] + 0.7152 * p_i[1] + 0.0722 * p_i[0]) / 255.0;
          printf("apple_render: wave7 testE1 line_word_unified l_H=%.3f l_o=%.3f l_i=%.3f\n", l_H, l_o, l_i);
          CHECK(l_H > 0.82 && l_o > 0.82 && l_i > 0.82 && fabs(l_H - l_o) < 0.05 && fabs(l_H - l_i) < 0.05);
          free(px_e1);
        }

        // Test E2: macro spatial low-pass rejects short-range oscillation.
        // 320x44pt large capsule over left dark region (0..184) with an embedded 16x10pt 2D white highlight (100..116, 145..155).
        // Three adjacent glyphs at x=90, x=108 (over highlight), x=126 must all stay bright (> 0.82, diff < 0.05),
        // while the right-side glyph at x=268 over white stays dark (< 0.35).
        {
          double te2[8 * MB_INST];
          rect_at(te2, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(te2 + MB_INST, 0, 0, 184, 300, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
          rect_at(te2 + 2 * MB_INST, 100, 145, 16, 10, 0, 1.0, 1.0, 1.0, 0);
          rect_at(te2 + 3 * MB_INST, 40, 128, 320, 44, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -27);
          te2[3 * MB_INST + 4] = 22.0;
          te2[3 * MB_INST + 6] = 1.0;
          te2[3 * MB_INST + 7] = 2.0;
          te2[3 * MB_INST + 11] = 0x67 / 255.0;
          te2[3 * MB_INST + 12] = 0.0;
          te2[3 * MB_INST + 13] = 14.0;
          te2[3 * MB_INST + 14] = -1.0;
          te2[3 * MB_INST + 15] = 1.0;
          double gx_xs[4] = { 84.0, 102.0, 120.0, 262.0 };
          for (int k = 0; k < 4; k++) {
            double *g = te2 + (4 + k) * MB_INST;
            rect_at(g, gx_xs[k], 142, 12, 16, 7, 0.14, 0.15, 0.17, 0);
            g[6] = 0.0; g[7] = 0.0;
            g[12] = 16.0; g[13] = 16.0; g[14] = 16.0; g[15] = 16.0;
            g[21] = 200.0; g[22] = 150.0; g[23] = 44.0;
          }
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(te2, 8, 1.0, 1.0, 1.0);
          present_drain();
          uint8_t *px_e2 = read_texture(canvas, &aw, &ah);
          uint8_t *p1 = px_e2 + (300 * aw + 180) * 4;
          uint8_t *p2 = px_e2 + (300 * aw + 216) * 4;
          uint8_t *p3 = px_e2 + (300 * aw + 252) * 4;
          uint8_t *p4 = px_e2 + (300 * aw + 536) * 4;
          double l1 = (0.2126 * p1[2] + 0.7152 * p1[1] + 0.0722 * p1[0]) / 255.0;
          double l2 = (0.2126 * p2[2] + 0.7152 * p2[1] + 0.0722 * p2[0]) / 255.0;
          double l3 = (0.2126 * p3[2] + 0.7152 * p3[1] + 0.0722 * p3[0]) / 255.0;
          double l4 = (0.2126 * p4[2] + 0.7152 * p4[1] + 0.0722 * p4[0]) / 255.0;
          printf("apple_render: wave7 testE2 lowpass_anti_osc l1=%.3f l2=%.3f l3=%.3f l4=%.3f\n",
                 l1, l2, l3, l4);
          CHECK(l1 > 0.82 && l2 > 0.82 && l3 > 0.82);
          CHECK(fabs(l1 - l2) < 0.05 && fabs(l2 - l3) < 0.05);
          CHECK(l4 < 0.35);
          free(px_e2);
        }

        // Test F: expanded 320x80pt large capsule (capHalf.y=40 > 28) with horizontal dark/white boundary at y=152
        // (top-left dark quadrant so whole capsule stays light). Two kind-11 vector bands (upper y=138..148 in dark,
        // lower y=154..164 in white) share p.zw pointing to joint icon center (104, 142) in dark:
        // both bands must invert bright (> 0.82) with matching luma (no band-splitting).
        {
          double tf[6 * MB_INST];
          rect_at(tf, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(tf + MB_INST, 0, 0, 184, 152, 0, 20.0 / 255.0, 20.0 / 255.0, 24.0 / 255.0, 0);
          rect_at(tf + 2 * MB_INST, 40, 110, 320, 80, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -26);
          tf[2 * MB_INST + 4] = 22.0;
          tf[2 * MB_INST + 6] = 1.0;
          tf[2 * MB_INST + 7] = 2.0;
          tf[2 * MB_INST + 11] = 0x67 / 255.0;
          tf[2 * MB_INST + 12] = 0.0;
          tf[2 * MB_INST + 13] = 14.0;
          tf[2 * MB_INST + 14] = -1.0;
          tf[2 * MB_INST + 15] = 1.0;
          // 3: upper kind-11 band (96, 138, 16, 10), center (104, 143), p.zw -> (104, 142)
          rect_at(tf + 3 * MB_INST, 96, 138, 16, 10, 11, 0.14, 0.15, 0.17, 0);
          tf[3 * MB_INST + 4] = 4.0;
          tf[3 * MB_INST + 6] = 104.0 - 104.0; tf[3 * MB_INST + 7] = 142.0 - 143.0;
          tf[3 * MB_INST + 12] = 0.0; tf[3 * MB_INST + 13] = 1.0;
          tf[3 * MB_INST + 21] = 200.0; tf[3 * MB_INST + 22] = 150.0; tf[3 * MB_INST + 23] = 80.0;
          // 4: lower kind-11 band (96, 154, 16, 10), center (104, 159), p.zw -> (104, 142)
          rect_at(tf + 4 * MB_INST, 96, 154, 16, 10, 11, 0.14, 0.15, 0.17, 0);
          tf[4 * MB_INST + 4] = 4.0;
          tf[4 * MB_INST + 6] = 104.0 - 104.0; tf[4 * MB_INST + 7] = 142.0 - 159.0;
          tf[4 * MB_INST + 12] = 0.0; tf[4 * MB_INST + 13] = 1.0;
          tf[4 * MB_INST + 21] = 200.0; tf[4 * MB_INST + 22] = 150.0; tf[4 * MB_INST + 23] = 80.0;
          // 5: kind-12 segment data: horizontal segment across center of band
          memset(tf + 5 * MB_INST, 0, MB_INST * sizeof(double));
          tf[5 * MB_INST + 0] = 0.1; tf[5 * MB_INST + 1] = 0.5;
          tf[5 * MB_INST + 2] = 0.9; tf[5 * MB_INST + 3] = 0.5;
          tf[5 * MB_INST + 5] = 12.0;

          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tf, 6, 1.0, 1.0, 1.0);
          present_drain();
          uint8_t *px_tf = read_texture(canvas, &aw, &ah);
          uint8_t *p_top = px_tf + (286 * aw + 208) * 4;
          uint8_t *p_bot = px_tf + (318 * aw + 208) * 4;
          double l_top = (0.2126 * p_top[2] + 0.7152 * p_top[1] + 0.0722 * p_top[0]) / 255.0;
          double l_bot = (0.2126 * p_bot[2] + 0.7152 * p_bot[1] + 0.0722 * p_bot[0]) / 255.0;
          printf("apple_render: wave7 testF icon_bands_unified l_top=%.3f l_bot=%.3f\n", l_top, l_bot);
          CHECK(l_top > 0.82 && l_bot > 0.82 && fabs(l_top - l_bot) < 0.05);
          free(px_tf);
        }

        mb_render_set_fixed_dt(0.0);
        glass_forget();
      }
    }

    // A selection changes shape data while two adaptive glasses share a capture. Settle regions must contain the
    // complete capture so they never blur the preceding frame's glass or foreground.
    {
      double a[6 * MB_INST];
      rect_at(a, 0, 0, 400, 300, 0, 0.95, 0.95, 0.95, 0);
      rect_at(a + MB_INST, 56, 216, 160, 12, 0, 0.1, 0.1, 0.1, 0);
      rect_at(a + 2 * MB_INST, 40, 116, 140, 32, 6, 0.99, 0.99, 0.99, -1);
      rect_at(a + 3 * MB_INST, 32, 180, 336, 92, 6, 0.99, 0.99, 0.99, -1);
      for (int i = 2; i <= 3; i++) {
        a[i * MB_INST + 4] = 16.0;
        a[i * MB_INST + 6] = 1.0;
        a[i * MB_INST + 7] = 4.0;
        a[i * MB_INST + 11] = 0x67 / 255.0;
        a[i * MB_INST + 13] = 8.0;
        a[i * MB_INST + 14] = -1.0;
        a[i * MB_INST + 15] = 1.0;
        a[i * MB_INST + 21] = 6.0;
      }
      rect_at(a + 4 * MB_INST, 40, 8, 120, 12, 0, 0.4, 0.6, 1.0, 0);
      a[4 * MB_INST + 11] = 0.0;
      rect_at(a + 5 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
      mb_render_set_fixed_dt(1.0 / 60.0);
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(a, 6, 0.95, 0.95, 0.95);
      present_drain();
      a[8] = 0.93;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(a, 6, 0.95, 0.95, 0.95);
      present_drain();
      CHECK(mb_render_adaptive_settling());
      a[4 * MB_INST + 11] = 0.5;
      a[5 * MB_INST + 12] = 1.0;
      mb_host_render_dirty(32, 0, 144, 32);
      mb_render_present(a, 6, 0.95, 0.95, 0.95);
      present_drain();
      slots_invalidate();
      CHECK(canvas_as_whole());
      mb_render_set_fixed_dt(0.0);
      glass_forget();
    }

    // Two independent adaptive liquid glasses spaced 8pt apart so their captures overlap, with a high-contrast blue
    // foreground caret drawn after the lower glass. Three consecutive partial frames updating only the top non-glass
    // region while settling must stay pixel-identical to a whole redraw, and overlapping settle damage merges to one.
    {
      double a[7 * MB_INST];
      rect_at(a, 0, 0, 400, 300, 0, 0.95, 0.95, 0.95, 0);
      rect_at(a + MB_INST, 56, 216, 160, 12, 0, 0.1, 0.1, 0.1, 0);
      rect_at(a + 2 * MB_INST, 40, 128, 140, 32, 6, 0.99, 0.99, 0.99, -1);
      a[2 * MB_INST + 4] = 16.0;
      a[2 * MB_INST + 6] = 1.0;
      a[2 * MB_INST + 7] = 2.1;
      a[2 * MB_INST + 11] = 0x67 / 255.0;
      a[2 * MB_INST + 13] = 8.0;
      a[2 * MB_INST + 14] = -1.0;
      a[2 * MB_INST + 15] = 1.0;
      a[2 * MB_INST + 21] = 28.0;
      rect_at(a + 3 * MB_INST, 32, 168, 336, 92, 6, 0.99, 0.99, 0.99, -2);
      a[3 * MB_INST + 4] = 16.0;
      a[3 * MB_INST + 6] = 1.0;
      a[3 * MB_INST + 7] = 4.0;
      a[3 * MB_INST + 11] = 0x67 / 255.0;
      a[3 * MB_INST + 13] = 8.0;
      a[3 * MB_INST + 14] = -1.0;
      a[3 * MB_INST + 15] = 1.0;
      a[3 * MB_INST + 21] = 28.0;
      rect_at(a + 4 * MB_INST, 48, 196, 2, 24, 0, 0.05, 0.35, 1.0, 0);
      rect_at(a + 5 * MB_INST, 40, 8, 120, 12, 0, 0.4, 0.6, 1.0, 0);
      a[5 * MB_INST + 11] = 0.0;
      rect_at(a + 6 * MB_INST, 0, 0, 0, 0, 12, 0, 0, 0, 0);
      mb_render_set_fixed_dt(1.0 / 60.0);
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(a, 7, 0.95, 0.95, 0.95);
      present_drain();
      a[8] = 0.93;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(a, 7, 0.95, 0.95, 0.95);
      present_drain();
      CHECK(mb_render_adaptive_settling());
      for (int step = 0; step < 3; step++) {
        a[5 * MB_INST + 11] = 0.3 * (step + 1);
        a[6 * MB_INST + 12] = (double)(step + 1);
        mb_host_render_dirty(32, 0, 144, 32);
        mb_render_present(a, 7, 0.95, 0.95, 0.95);
        present_drain();
        slots_invalidate();
        CHECK(canvas_as_whole());
      }
      float f[7 * MB_INST];
      for (int i = 0; i < 7 * MB_INST; i++) f[i] = (float)a[i];
      double r[][4] = {{36, 124, 148, 40}, {28, 164, 344, 100}};
      int rn = 2;
      CHECK(mb_glass_damage_expand(f, 7, r, &rn, 400, 300, 2, NULL));
      CHECK(rn == 1);
      CHECK(r[0][1] <= 92 && r[0][1] + r[0][3] >= 298);
      mb_render_set_fixed_dt(0.0);
      glass_forget();
      // Wave 4B v17: foreground optical lens (kind == 8): offscreen Gaussian defocus + spherical bevel refraction + SDF clip
      double k8[3 * MB_INST];
      rect_at(k8, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
      rect_at(k8 + MB_INST, 100, 80, 120, 120, 8, 1.0, 1.0, 1.0, 0);
      k8[MB_INST + 4] = 28;
      k8[MB_INST + 7] = 4.0;   // blur = 4pt
      k8[MB_INST + 11] = 1.0;  // alpha = 1
      k8[MB_INST + 12] = 1.0;  // child_n = 1
      k8[MB_INST + 13] = 24.0; // bezel = 24pt
      k8[MB_INST + 14] = 18.0; // refraction = 18pt
      k8[MB_INST + 15] = 1.0;
      k8[MB_INST + 36] = 28; k8[MB_INST + 37] = 28; k8[MB_INST + 38] = 28; k8[MB_INST + 39] = 28;
      rect_at(k8 + 2 * MB_INST, 140, 120, 40, 40, 0, 1.0, 0.0, 0.0, 0);
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(k8, 3, 1.0, 1.0, 1.0);
      present_drain();
      int k8w = 0, k8h = 0;
      uint8_t *px_k8 = read_texture(canvas, &k8w, &k8h);
      // BGRA at 2x: center (160,140)->(320,280), blur halo (136,140)->(272,280), outside SDF (80,140)->(160,280)
      uint8_t *k8_ctr = px_k8 + (280 * k8w + 320) * 4;
      uint8_t *k8_halo = px_k8 + (280 * k8w + 272) * 4;
      uint8_t *k8_out = px_k8 + (280 * k8w + 160) * 4;
      printf("apple_render: kind8 lens ctr=%d,%d,%d halo=%d,%d,%d out=%d,%d,%d\n",
             k8_ctr[2], k8_ctr[1], k8_ctr[0], k8_halo[2], k8_halo[1], k8_halo[0], k8_out[2], k8_out[1], k8_out[0]);
      CHECK((int)k8_ctr[2] - (int)k8_ctr[0] > 120);
      CHECK((int)k8_halo[2] - (int)k8_halo[0] > 20);
      CHECK(abs((int)k8_out[2] - (int)k8_out[0]) <= 2 && k8_out[2] >= 250);
      free(px_k8);
    }

    // 5K progressive blur + mixed aspect-ratio 40-frame scroll stress:
    // A wide top progressive bar + tall sidebar stretch lv_w/lv_h to near-5K, then 40 frames of moving backdrop
    // under small progressive + regular frosted glass must stay within MB_GLASS_CACHE_MAX_BYTES (64 MiB), keep
    // compact slot textures far smaller than lv_w * lv_h, and match canvas_as_whole() byte-for-byte on every frame.
    {
      glass_free();
      mb_render_set_size(2560, 1440, 2);
      double big[3 * MB_INST];
      rect_at(big, 0, 0, 2560, 1440, 0, 0.12, 0.16, 0.22, 0);
      big[18] = 2560; big[19] = 1440;
      // Wide top bar progressive frosted glass
      rect_at(big + MB_INST, 0, 0, 2500, 60, 5, 1, 1, 1, -30);
      big[MB_INST + 7] = 12.0;
      big[MB_INST + 11] = 0.4;
      big[MB_INST + 18] = 2560; big[MB_INST + 19] = 1440;
      big[MB_INST + 22] = -1.0;  // progressive
      big[MB_INST + 55] = 60.0;
      big[MB_INST + 56] = 1.0;
      // Tall sidebar frosted glass
      rect_at(big + 2 * MB_INST, 0, 80, 120, 1340, 5, 1, 1, 1, -31);
      big[2 * MB_INST + 7] = 12.0;
      big[2 * MB_INST + 11] = 0.4;
      big[2 * MB_INST + 18] = 2560; big[2 * MB_INST + 19] = 1440;
      mb_host_render_dirty(0, 0, 2560, 1440);
      mb_render_present(big, 3, 0.12, 0.16, 0.22);
      present_drain();
      CHECK(lv_w >= 4800 && lv_h >= 2600);
      CHECK(slots_total_bytes() <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(canvas_as_whole());

      double small[4 * MB_INST];
      rect_at(small, 0, 0, 2560, 1440, 0, 0.14, 0.18, 0.24, 0);
      small[18] = 2560; small[19] = 1440;
      // Moving backdrop stripe under both small glasses
      rect_at(small + MB_INST, 20, 30, 420, 60, 0, 0.90, 0.35, 0.20, 0);
      small[MB_INST + 18] = 2560; small[MB_INST + 19] = 1440;
      // Small progressive glass capsule
      rect_at(small + 2 * MB_INST, 40, 40, 160, 44, 5, 1, 1, 1, -32);
      small[2 * MB_INST + 7] = 12.0;
      small[2 * MB_INST + 11] = 0.45;
      small[2 * MB_INST + 18] = 2560; small[2 * MB_INST + 19] = 1440;
      small[2 * MB_INST + 22] = -1.0;  // progressive
      small[2 * MB_INST + 55] = 44.0;
      small[2 * MB_INST + 56] = 1.0;
      // Small regular frosted pill
      rect_at(small + 3 * MB_INST, 300, 40, 120, 40, 5, 1, 1, 1, -33);
      small[3 * MB_INST + 7] = 3.0;
      small[3 * MB_INST + 11] = 0.45;
      small[3 * MB_INST + 18] = 2560; small[3 * MB_INST + 19] = 1440;

      size_t peak_slot_bytes = slots_total_bytes();
      size_t max_small_tex_area = 0;
      for (int step = 0; step < 40; step++) {
        small[MB_INST + 0] = 20 + (step * 7) % 120;
        mb_host_render_dirty(0, 0, 2560, 1440);
        mb_render_present(small, 4, 0.14, 0.18, 0.24);
        present_drain();
        size_t cur_bytes = slots_total_bytes();
        if (cur_bytes > peak_slot_bytes) peak_slot_bytes = cur_bytes;
        CHECK(cur_bytes <= MB_GLASS_CACHE_MAX_BYTES);
        for (int j = 0; j < MB_GLASS_SLOTS; j++) {
          if (slots[j].valid && slot_bt[j] && slots[j].grab.w < 1000) {
            size_t area = (size_t)slot_bt[j].width * (size_t)slot_bt[j].height;
            if (area > max_small_tex_area) max_small_tex_area = area;
          }
        }
        CHECK(canvas_as_whole());
      }
      printf("apple_render: 5K glass stress peak_slot_bytes=%zu (limit=%zu) max_small_area=%zu lv_area=%zu\n",
             peak_slot_bytes, (size_t)MB_GLASS_CACHE_MAX_BYTES, max_small_tex_area, (size_t)lv_w * (size_t)lv_h);
      CHECK(peak_slot_bytes <= MB_GLASS_CACHE_MAX_BYTES);
      CHECK(max_small_tex_area > 0 && max_small_tex_area * 16 < (size_t)lv_w * (size_t)lv_h);
      glass_free();
      mb_render_set_size(400, 300, 2);
    }

    // High-water mark shrink: after a large glass stretches lv_w * lv_h, MB_GLASS_IDLE consecutive frames with only
    // small glass must shrink lv_w * lv_h back down and preserve byte-for-byte parity with canvas_as_whole().
    {
      glass_free();
      mb_render_set_size(400, 300, 2);
      double lg[2 * MB_INST];
      rect_at(lg, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      rect_at(lg + MB_INST, 0, 0, 400, 300, 5, 1, 1, 1, -40);
      lg[MB_INST + 7] = 8.0;
      lg[MB_INST + 11] = 0.45;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(lg, 2, 0.15, 0.25, 0.40);
      present_drain();
      size_t big_lv_area = (size_t)lv_w * (size_t)lv_h;
      CHECK(lv_w == 800 && lv_h == 600);
      CHECK(canvas_as_whole());

      double sm[3 * MB_INST];
      rect_at(sm, 0, 0, 400, 300, 0, 0.15, 0.25, 0.40, 0);
      rect_at(sm + MB_INST, 24, 24, 52, 32, 0, 0.90, 0.20, 0.20, 0);
      rect_at(sm + 2 * MB_INST, 20, 20, 60, 40, 5, 1, 1, 1, -41);
      sm[2 * MB_INST + 7] = 4.0;
      sm[2 * MB_INST + 11] = 0.45;
      for (int i = 0; i < MB_GLASS_IDLE; i++) {
        sm[MB_INST + 0] = 24 + (i % 20);
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(sm, 3, 0.15, 0.25, 0.40);
        present_drain();
      }
      size_t shrunk_lv_area = (size_t)lv_w * (size_t)lv_h;
      printf("apple_render: lv shrink big_area=%zu -> shrunk_area=%zu (%dx%d)\n",
             big_lv_area, shrunk_lv_area, lv_w, lv_h);
      CHECK(shrunk_lv_area * 4 < big_lv_area);
      CHECK(canvas_as_whole());
      glass_forget();
      CHECK(canvas_as_whole());
      glass_free();
    }

    // Perf-29: Stacked glass cache independence (top progressive blur + top liquid glass capsule + changing bottom
    // content must produce 0 blur rebuilds and match a whole redraw to the byte; changing content under top
    // progressive blur rebuilds both and matches a whole redraw).
    {
      double sg[5 * MB_INST];
      rect_at(sg, 0, 0, 400, 300, 0, 0.94, 0.94, 0.92, 0);
      rect_at(sg + 1 * MB_INST, 20, 8, 120, 24, 0, 0.85, 0.20, 0.20, 0);
      rect_at(sg + 2 * MB_INST, 20, 220, 200, 32, 0, 0.20, 0.45, 0.90, 0);
      rect_at(sg + 3 * MB_INST, 0, 0, 400, 64, 5, 0.96, 0.96, 0.96, -30);
      sg[3 * MB_INST + 6] = 1.1;
      sg[3 * MB_INST + 7] = 6.0;
      sg[3 * MB_INST + 11] = 0.35;
      sg[3 * MB_INST + 15] = 1.0;
      sg[3 * MB_INST + 22] = -1.0;
      sg[3 * MB_INST + 54] = 64.0;
      sg[3 * MB_INST + 55] = 24.0;
      rect_at(sg + 4 * MB_INST, 24, 12, 140, 32, 6, 0.99, 0.99, 0.99, -31);
      sg[4 * MB_INST + 4] = 16.0;
      sg[4 * MB_INST + 6] = 1.0;
      sg[4 * MB_INST + 7] = 2.0;
      sg[4 * MB_INST + 11] = 0x67 / 255.0;
      sg[4 * MB_INST + 13] = 8.0;
      sg[4 * MB_INST + 14] = -1.0;
      sg[4 * MB_INST + 15] = 1.0;
      sg[4 * MB_INST + 21] = 6.0;

      mb_render_set_fixed_dt(1.0 / 60.0);
      glass_forget();
      int b0 = blurs_made;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(sg, 5, 0.94, 0.94, 0.92);
      present_drain();
      CHECK(blurs_made == b0 + 2);
      CHECK(canvas_as_whole());

      for (int step = 0; step < 3; step++) {
        sg[2 * MB_INST + 8] = 0.20 + 0.25 * (step + 1);
        b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(sg, 5, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(blurs_made == b0);
        CHECK(canvas_as_whole());
      }

      sg[1 * MB_INST + 9] = 0.80;
      b0 = blurs_made;
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(sg, 5, 0.94, 0.94, 0.92);
      present_drain();
      CHECK(blurs_made == b0 + 2);
      CHECK(canvas_as_whole());
      mb_render_set_fixed_dt(0.0);
      glass_forget();
    }

    // Progressive blur small-radius anti-ghosting regression: 1pt and 1px dark vertical/horizontal strokes over
    // a light background under blur=8.5, fade_h=68 progressive blur at both 2x and 1x scale must produce strictly
    // unimodal profiles (no 9-tap comb ghosting / secondary dark peaks) and monotonically attenuate center contrast.
    {
      static const double scales[2] = {2.0, 1.0};
      static const double v_ramps[6] = {0.06, 0.10, 0.14, 0.18, 0.24, 0.35};
      static const double h_ramps[3] = {0.10, 0.18, 0.24};
      for (int si = 0; si < 2; si++) {
        double sc = scales[si];
        mb_render_set_size(400, 300, sc);
        double widths[2] = {1.0, 1.0 / sc};
        int n_widths = (sc > 1.5) ? 2 : 1;
        for (int wi = 0; wi < n_widths; wi++) {
          double lw = widths[wi];
          // 1) Vertical stroke across the entire fade band (y=0..80)
          double pb[3 * MB_INST];
          rect_at(pb, 0, 0, 400, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(pb + MB_INST, 50.0, 0.0, lw, 80.0, 0, 0.05, 0.05, 0.05, 0);
          rect_at(pb + 2 * MB_INST, 0, 0, 400, 68.0, 5, 0.96, 0.96, 0.96, -40);
          pb[2 * MB_INST + 6] = 1.0;
          pb[2 * MB_INST + 7] = 8.5;
          pb[2 * MB_INST + 11] = 0.15;
          pb[2 * MB_INST + 15] = 1.0;
          pb[2 * MB_INST + 22] = -1.0;
          pb[2 * MB_INST + 54] = 68.0;
          pb[2 * MB_INST + 55] = 68.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(pb, 3, 0.96, 0.96, 0.96);
          present_drain();
          int cw = 0, ch = 0;
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int prev_center = -1;
          int first_center = -1;
          int last_center = -1;
          int mono_ok = 1;
          int max_dip = 0;
          for (int ri = 0; ri < 6; ri++) {
            int py = (int)llround(68.0 * (1.0 - v_ramps[ri]) * sc);
            if (py < 0) py = 0;
            if (py >= ch) py = ch - 1;
            int x0 = (int)floor(50.0 * sc) - 2;
            int x1 = (int)ceil((50.0 + lw) * sc) + 2;
            int xc = x0, min_l = 256;
            for (int x = x0; x <= x1; x++) {
              int l = px[(py * cw + x) * 4 + 1];
              if (l < min_l) { min_l = l; xc = x; }
            }
            if (ri == 0) first_center = min_l;
            last_center = min_l;
            if (prev_center >= 0 && min_l < prev_center - 2) {
              fprintf(stderr, "apple_render: prog-blur v-stroke center non-mono sc=%.0f lw=%.2f ramp=%.2f prev=%d cur=%d\n",
                      sc, lw, v_ramps[ri], prev_center, min_l);
              mono_ok = 0;
            }
            prev_center = min_l;
            for (int dir = -1; dir <= 1; dir += 2) {
              int max_seen = min_l;
              for (int dx = 1; dx <= 12; dx++) {
                int x = xc + dir * dx;
                if (x < 0 || x >= cw) break;
                int l = px[(py * cw + x) * 4 + 1];
                if (max_seen - l > max_dip) max_dip = max_seen - l;
                if (l < max_seen - 2) mono_ok = 0;
                if (l > max_seen) max_seen = l;
              }
            }
          }
          printf("apple_render: prog-blur v-stroke sc=%.0f lw=%.2f first=%d last=%d max_dip=%d\n",
                 sc, lw, first_center, last_center, max_dip);
          CHECK(mono_ok);
          CHECK(last_center > first_center + 15);
          free(px);

          // 2) Horizontal strokes at representative small-radius ramps
          int h_mono_ok = 1;
          int h_max_dip = 0;
          for (int ri = 0; ri < 3; ri++) {
            double y_pt = 68.0 * (1.0 - h_ramps[ri]);
            double hp[3 * MB_INST];
            rect_at(hp, 0, 0, 400, 300, 0, 0.96, 0.96, 0.96, 0);
            rect_at(hp + MB_INST, 20.0, y_pt, 160.0, lw, 0, 0.05, 0.05, 0.05, 0);
            rect_at(hp + 2 * MB_INST, 0, 0, 400, 68.0, 5, 0.96, 0.96, 0.96, -41);
            hp[2 * MB_INST + 6] = 1.0;
            hp[2 * MB_INST + 7] = 8.5;
            hp[2 * MB_INST + 11] = 0.15;
            hp[2 * MB_INST + 15] = 1.0;
            hp[2 * MB_INST + 22] = -1.0;
            hp[2 * MB_INST + 54] = 68.0;
            hp[2 * MB_INST + 55] = 68.0;
            glass_forget();
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(hp, 3, 0.96, 0.96, 0.96);
            present_drain();
            int hcw = 0, hch = 0;
            uint8_t *hpx = read_texture(canvas, &hcw, &hch);
            int px_x = (int)llround(100.0 * sc);
            int y0 = (int)floor(y_pt * sc) - 2;
            int y1 = (int)ceil((y_pt + lw) * sc) + 2;
            int yc = y0, min_l = 256;
            for (int y = y0; y <= y1; y++) {
              int l = hpx[(y * hcw + px_x) * 4 + 1];
              if (l < min_l) { min_l = l; yc = y; }
            }
            for (int dir = -1; dir <= 1; dir += 2) {
              int max_seen = min_l;
              for (int dy = 1; dy <= 10; dy++) {
                int y = yc + dir * dy;
                if (y < 0 || y >= hch) break;
                int l = hpx[(y * hcw + px_x) * 4 + 1];
                if (max_seen - l > h_max_dip) h_max_dip = max_seen - l;
                if (l < max_seen - 2) h_mono_ok = 0;
                if (l > max_seen) max_seen = l;
              }
            }
            free(hpx);
          }
          printf("apple_render: prog-blur h-stroke sc=%.0f lw=%.2f max_dip=%d\n", sc, lw, h_max_dip);
          CHECK(h_mono_ok);
        }
      }
      // Progressive blur zero-tint regression: dark background (0.15, 0.15, 0.16) under kind==5 progressive blur
      // with blur=8.5, saturation=1.0, tint=(1.0, 1.0, 1.0, 0.0) must stay pure dark (~38, 38, 41) at r=1.0
      // without any contrast-boosted white veil.
      {
        mb_render_set_size(400, 300, 2);
        double zt[2 * MB_INST];
        rect_at(zt, 0, 0, 400, 300, 0, 0.15, 0.15, 0.16, 0);
        rect_at(zt + MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -42);
        zt[MB_INST + 6] = 1.0;   // saturation=1.0
        zt[MB_INST + 7] = 8.5;   // blur=8.5
        zt[MB_INST + 11] = 0.0;  // tint alpha=0.0 (clear)
        zt[MB_INST + 15] = 1.0;
        zt[MB_INST + 22] = -1.0; // progressive
        zt[MB_INST + 54] = 68.0;
        zt[MB_INST + 55] = 40.0; // y in [0, 28] has fade_r == 1.0
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(zt, 2, 0.15, 0.15, 0.16);
        present_drain();
        int zcw = 0, zch = 0;
        uint8_t *zpx = read_texture(canvas, &zcw, &zch);
        int zidx = (20 * zcw + 400) * 4; // (200pt, 10pt) at 2x scale, r=1.0
        int zr = zpx[zidx + 2], zg = zpx[zidx + 1], zb = zpx[zidx + 0]; // BGRA
        printf("apple_render: prog-blur zero-tint rgb=(%d,%d,%d)\n", zr, zg, zb);
        CHECK(abs(zr - 38) <= 2 && abs(zg - 38) <= 2 && abs(zb - 41) <= 2);
        free(zpx);
      }
      // Bare-text kind==7 (negative pad.w) bidirectional adaptive ink over kind==5 zero-tint progressive blur
      // with non-uniform left/right backdrop (left kind==6 pill over opposite luminance from right bare text,
      // proving grab_of actually expands to cover bare text instead of UV-clamping the pill):
      // (a) left bright / right dark + bare dark text -> flips light (>= 0.70 luma)
      // (b) left dark / right bright + bare light text -> flips dark (<= 0.30 luma)
      // Plus WCAG >= 4.5:1 contrast on mid-gray sRGB 0.45, 0.60, 0.77 for both dark and light origin bare text,
      // and capsule white text (pad.w > 0) over ad_n == 0 bright backdrop staying white (>= 0.90 luma).
      {
        mb_render_set_size(400, 300, 2);
        struct { double l_bg, r_bg, txt; int expect_light; } bi_cases[2] = {
          { 0.96, 0.12, 0.11, 1 },
          { 0.12, 0.96, 0.95, 0 },
        };
        for (int ci = 0; ci < 2; ci++) {
          double bi[5 * MB_INST];
          rect_at(bi, 0, 0, 140, 300, 0, bi_cases[ci].l_bg, bi_cases[ci].l_bg, bi_cases[ci].l_bg, 0);
          rect_at(bi + MB_INST, 140, 0, 260, 300, 0, bi_cases[ci].r_bg, bi_cases[ci].r_bg, bi_cases[ci].r_bg, 0);
          rect_at(bi + 2 * MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -43);
          bi[2 * MB_INST + 6] = 1.0; bi[2 * MB_INST + 7] = 8.5; bi[2 * MB_INST + 11] = 0.0; bi[2 * MB_INST + 15] = 1.0;
          bi[2 * MB_INST + 22] = -1.0; bi[2 * MB_INST + 54] = 68.0; bi[2 * MB_INST + 55] = 40.0;
          rect_at(bi + 3 * MB_INST, 12, 8, 60, 28, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -44);
          bi[3 * MB_INST + 4] = 14.0; bi[3 * MB_INST + 6] = 1.0; bi[3 * MB_INST + 7] = 2.0;
          bi[3 * MB_INST + 11] = 0x67 / 255.0; bi[3 * MB_INST + 14] = -1.0; bi[3 * MB_INST + 15] = 1.0;
          rect_at(bi + 4 * MB_INST, 252, 12, 16, 16, 7, bi_cases[ci].txt, bi_cases[ci].txt, bi_cases[ci].txt, 0);
          bi[4 * MB_INST + 12] = 16.0; bi[4 * MB_INST + 13] = 16.0;
          bi[4 * MB_INST + 14] = 16.0; bi[4 * MB_INST + 15] = 16.0;
          bi[4 * MB_INST + 21] = 260.0; bi[4 * MB_INST + 22] = 20.0; bi[4 * MB_INST + 23] = -16.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(bi, 5, bi_cases[ci].r_bg, bi_cases[ci].r_bg, bi_cases[ci].r_bg);
          present_drain();
          int bcw = 0, bch = 0;
          uint8_t *bpx = read_texture(canvas, &bcw, &bch);
          int bidx = (40 * bcw + 520) * 4; // (260pt, 20pt) at 2x scale
          double lum = (0.2126 * bpx[bidx + 2] + 0.7152 * bpx[bidx + 1] + 0.0722 * bpx[bidx + 0]) / 255.0;
          printf("apple_render: bare-text adaptive ink non-uniform case %d: rgb=(%d,%d,%d) luma=%.3f\n",
                 ci, bpx[bidx + 2], bpx[bidx + 1], bpx[bidx + 0], lum);
          if (bi_cases[ci].expect_light) {
            CHECK(lum >= 0.70);
          } else {
            CHECK(lum <= 0.30);
          }
          free(bpx);
        }
        // Mid-gray WCAG >= 4.5:1 contrast check on 8 mid-grays x 5 primary/muted inks (40 cases)
        double mid_bgs[8] = { 0.45, 0.47, 0.50, 0.53, 0.60, 0.63, 0.70, 0.77 };
        double mid_txts[5] = { 0.11, 0.40, 0.67, 0.95, 1.00 };
        for (int mi = 0; mi < 8; mi++) {
          double bg = mid_bgs[mi];
          double bg_lin = bg <= 0.04045 ? bg / 12.92 : pow((bg + 0.055) / 1.055, 2.4);
          for (int ti = 0; ti < 5; ti++) {
            double mc[3 * MB_INST];
            rect_at(mc, 0, 0, 400, 300, 0, bg, bg, bg, 0);
            rect_at(mc + MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -45);
            mc[MB_INST + 6] = 1.0; mc[MB_INST + 7] = 8.5; mc[MB_INST + 11] = 0.0; mc[MB_INST + 15] = 1.0;
            mc[MB_INST + 22] = -1.0; mc[MB_INST + 54] = 68.0; mc[MB_INST + 55] = 40.0;
            rect_at(mc + 2 * MB_INST, 192, 12, 16, 16, 7, mid_txts[ti], mid_txts[ti], mid_txts[ti], 0);
            mc[2 * MB_INST + 12] = 16.0; mc[2 * MB_INST + 13] = 16.0;
            mc[2 * MB_INST + 14] = 16.0; mc[2 * MB_INST + 15] = 16.0;
            mc[2 * MB_INST + 21] = 200.0; mc[2 * MB_INST + 22] = 20.0; mc[2 * MB_INST + 23] = -16.0;
            glass_forget();
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(mc, 3, bg, bg, bg);
            present_drain();
            int mcw = 0, mch = 0;
            uint8_t *mpx = read_texture(canvas, &mcw, &mch);
            int midx = (40 * mcw + 400) * 4;
            double tr = mpx[midx + 2] / 255.0, tg = mpx[midx + 1] / 255.0, tb = mpx[midx + 0] / 255.0;
            double rl = 0.2126 * (tr <= 0.04045 ? tr / 12.92 : pow((tr + 0.055) / 1.055, 2.4))
                      + 0.7152 * (tg <= 0.04045 ? tg / 12.92 : pow((tg + 0.055) / 1.055, 2.4))
                      + 0.0722 * (tb <= 0.04045 ? tb / 12.92 : pow((tb + 0.055) / 1.055, 2.4));
            double hi = rl > bg_lin ? rl : bg_lin, lo = rl > bg_lin ? bg_lin : rl;
            double cr = (hi + 0.05) / (lo + 0.05);
            printf("apple_render: bare-text mid-gray bg=%.2f txt=%.2f -> rgb=(%d,%d,%d) cr=%.2f\n",
                   bg, mid_txts[ti], mpx[midx + 2], mpx[midx + 1], mpx[midx + 0], cr);
            CHECK(cr >= 4.5);
            free(mpx);
          }
        }
        // Capsule white text (pad.w > 0) over ad_n == 0 bright backdrop must NOT flip dark
        {
          double cw[3 * MB_INST];
          rect_at(cw, 0, 0, 400, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(cw + MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -46);
          cw[MB_INST + 6] = 1.0; cw[MB_INST + 7] = 8.5; cw[MB_INST + 11] = 0.0; cw[MB_INST + 15] = 1.0;
          cw[MB_INST + 22] = -1.0; cw[MB_INST + 54] = 68.0; cw[MB_INST + 55] = 40.0;
          rect_at(cw + 2 * MB_INST, 192, 12, 16, 16, 7, 0.95, 0.95, 0.95, 0);
          cw[2 * MB_INST + 12] = 16.0; cw[2 * MB_INST + 13] = 16.0;
          cw[2 * MB_INST + 14] = 16.0; cw[2 * MB_INST + 15] = 16.0;
          cw[2 * MB_INST + 21] = 200.0; cw[2 * MB_INST + 22] = 20.0; cw[2 * MB_INST + 23] = 16.0; // positive = capsule
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(cw, 3, 0.96, 0.96, 0.96);
          present_drain();
          int ccw = 0, cch = 0;
          uint8_t *cpx = read_texture(canvas, &ccw, &cch);
          int cidx = (40 * ccw + 400) * 4;
          double lum = (0.2126 * cpx[cidx + 2] + 0.7152 * cpx[cidx + 1] + 0.0722 * cpx[cidx + 0]) / 255.0;
          printf("apple_render: capsule white text ad_n=0 bright bg: rgb=(%d,%d,%d) luma=%.3f\n",
                 cpx[cidx + 2], cpx[cidx + 1], cpx[cidx + 0], lum);
          CHECK(lum >= 0.90);
          free(cpx);
        }
        // Bare kind==10 (line) & kind==11 (shape) + kind==7 on #F00080 exact WCAG luma
        {
          struct { double r, g, b; const char *name; } bg_cases[4] = {
            { 0.96, 0.96, 0.96, "light" },
            { 0.12, 0.12, 0.12, "dark" },
            { 0.50, 0.50, 0.50, "mid50" },
            { 240.0 / 255.0, 0.0, 128.0 / 255.0, "#F00080" },
          };
          double inks[2] = { 0.11, 0.95 };
          for (int bi_i = 0; bi_i < 4; bi_i++) {
            double br = bg_cases[bi_i].r, bgc = bg_cases[bi_i].g, bb = bg_cases[bi_i].b;
            double bg_lin = 0.2126 * (br <= 0.04045 ? br / 12.92 : pow((br + 0.055) / 1.055, 2.4))
                          + 0.7152 * (bgc <= 0.04045 ? bgc / 12.92 : pow((bgc + 0.055) / 1.055, 2.4))
                          + 0.0722 * (bb <= 0.04045 ? bb / 12.92 : pow((bb + 0.055) / 1.055, 2.4));
            for (int ii = 0; ii < 2; ii++) {
              double ink = inks[ii];
              double sc[6 * MB_INST];
              rect_at(sc, 0, 0, 400, 300, 0, br, bgc, bb, 0);
              rect_at(sc + MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -47);
              sc[MB_INST + 6] = 1.0; sc[MB_INST + 7] = 8.5; sc[MB_INST + 11] = 0.0; sc[MB_INST + 15] = 1.0;
              sc[MB_INST + 22] = -1.0; sc[MB_INST + 54] = 68.0; sc[MB_INST + 55] = 40.0;
              rect_at(sc + 2 * MB_INST, 72, 12, 16, 16, 7, ink, ink, ink, 0);
              sc[2 * MB_INST + 12] = 16.0; sc[2 * MB_INST + 13] = 16.0;
              sc[2 * MB_INST + 14] = 16.0; sc[2 * MB_INST + 15] = 16.0;
              sc[2 * MB_INST + 21] = 80.0; sc[2 * MB_INST + 22] = 20.0; sc[2 * MB_INST + 23] = -16.0;
              rect_at(sc + 3 * MB_INST, 192, 14, 16, 12, 10, ink, ink, ink, 0);
              sc[3 * MB_INST + 4] = 4.0;
              sc[3 * MB_INST + 12] = 0.1; sc[3 * MB_INST + 13] = 0.5;
              sc[3 * MB_INST + 14] = 0.9; sc[3 * MB_INST + 15] = 0.5;
              sc[3 * MB_INST + 21] = 200.0; sc[3 * MB_INST + 22] = 20.0; sc[3 * MB_INST + 23] = -16.0;
              rect_at(sc + 4 * MB_INST, 312, 14, 16, 12, 11, ink, ink, ink, 0);
              sc[4 * MB_INST + 4] = 4.0;
              sc[4 * MB_INST + 6] = 0.0; sc[4 * MB_INST + 7] = 0.0;
              sc[4 * MB_INST + 12] = 0.0; sc[4 * MB_INST + 13] = 1.0;
              sc[4 * MB_INST + 21] = 320.0; sc[4 * MB_INST + 22] = 20.0; sc[4 * MB_INST + 23] = -16.0;
              memset(sc + 5 * MB_INST, 0, MB_INST * sizeof(double));
              sc[5 * MB_INST + 0] = 0.1; sc[5 * MB_INST + 1] = 0.5;
              sc[5 * MB_INST + 2] = 0.9; sc[5 * MB_INST + 3] = 0.5;
              sc[5 * MB_INST + 5] = 12.0;
              glass_forget();
              mb_host_render_dirty(0, 0, 400, 300);
              mb_render_present(sc, 6, br, bgc, bb);
              present_drain();
              int scw = 0, sch = 0;
              uint8_t *spx = read_texture(canvas, &scw, &sch);
              int xs[3] = { 80, 200, 320 };
              int kinds[3] = { 7, 10, 11 };
              for (int ki = 0; ki < 3; ki++) {
                int idx = (40 * scw + xs[ki] * 2) * 4;
                double tr = spx[idx + 2] / 255.0, tg = spx[idx + 1] / 255.0, tb = spx[idx + 0] / 255.0;
                double rl = 0.2126 * (tr <= 0.04045 ? tr / 12.92 : pow((tr + 0.055) / 1.055, 2.4))
                          + 0.7152 * (tg <= 0.04045 ? tg / 12.92 : pow((tg + 0.055) / 1.055, 2.4))
                          + 0.0722 * (tb <= 0.04045 ? tb / 12.92 : pow((tb + 0.055) / 1.055, 2.4));
                double hi = rl > bg_lin ? rl : bg_lin, lo = rl > bg_lin ? bg_lin : rl;
                double cr = (hi + 0.05) / (lo + 0.05);
                printf("apple_render: bare k=%d bg=%s ink=%.2f -> rgb=(%d,%d,%d) cr=%.2f\n",
                       kinds[ki], bg_cases[bi_i].name, ink, spx[idx + 2], spx[idx + 1], spx[idx + 0], cr);
                CHECK(cr >= 4.5);
                if (bi_i == 3) { CHECK(rl < 0.05); }
              }
              free(spx);
            }
          }
        }
        // 300pt-wide bare title straddling bright (left) / dark (right) boundary: per-glyph local sampling
        {
          double wt[5 * MB_INST];
          rect_at(wt, 0, 0, 200, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(wt + MB_INST, 200, 0, 200, 300, 0, 0.10, 0.10, 0.10, 0);
          rect_at(wt + 2 * MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -48);
          wt[2 * MB_INST + 6] = 1.0; wt[2 * MB_INST + 7] = 8.5; wt[2 * MB_INST + 11] = 0.0; wt[2 * MB_INST + 15] = 1.0;
          wt[2 * MB_INST + 22] = -1.0; wt[2 * MB_INST + 54] = 68.0; wt[2 * MB_INST + 55] = 40.0;
          rect_at(wt + 3 * MB_INST, 62, 12, 16, 16, 7, 0.11, 0.11, 0.11, 0);
          wt[3 * MB_INST + 12] = 16.0; wt[3 * MB_INST + 13] = 16.0; wt[3 * MB_INST + 14] = 16.0; wt[3 * MB_INST + 15] = 16.0;
          wt[3 * MB_INST + 21] = 200.0; wt[3 * MB_INST + 22] = 20.0; wt[3 * MB_INST + 23] = -16.0;
          rect_at(wt + 4 * MB_INST, 322, 12, 16, 16, 7, 0.11, 0.11, 0.11, 0);
          wt[4 * MB_INST + 12] = 16.0; wt[4 * MB_INST + 13] = 16.0; wt[4 * MB_INST + 14] = 16.0; wt[4 * MB_INST + 15] = 16.0;
          wt[4 * MB_INST + 21] = 200.0; wt[4 * MB_INST + 22] = 20.0; wt[4 * MB_INST + 23] = -16.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(wt, 5, 0.10, 0.10, 0.10);
          present_drain();
          int wcw = 0, wch = 0;
          uint8_t *wpx = read_texture(canvas, &wcw, &wch);
          int il = (40 * wcw + 140) * 4, ir = (40 * wcw + 660) * 4;
          double ll = (0.2126 * wpx[il + 2] + 0.7152 * wpx[il + 1] + 0.0722 * wpx[il + 0]) / 255.0;
          double lr = (0.2126 * wpx[ir + 2] + 0.7152 * wpx[ir + 1] + 0.0722 * wpx[ir + 0]) / 255.0;
          printf("apple_render: bare 300pt title split: left_lum=%.3f right_lum=%.3f\n", ll, lr);
          CHECK(ll <= 0.30);
          CHECK(lr >= 0.70);
          free(wpx);
        }
        // Vertical split multiline bare kind==7: top row y=14..26 over light 0.96, bottom row y=84..96 over dark 0.10,
        // shared ancestor pad.yz=(100, 55) -> both rows must sample their own rect.y + rect.h*0.5 and reach CR >= 4.5
        {
          double ml[5 * MB_INST];
          rect_at(ml, 0, 0, 400, 60, 0, 0.96, 0.96, 0.96, 0);
          rect_at(ml + MB_INST, 0, 60, 400, 240, 0, 0.10, 0.10, 0.10, 0);
          rect_at(ml + 2 * MB_INST, 0, 0, 400, 120.0, 5, 1.0, 1.0, 1.0, -52);
          ml[2 * MB_INST + 6] = 1.0; ml[2 * MB_INST + 7] = 4.0; ml[2 * MB_INST + 11] = 0.0; ml[2 * MB_INST + 15] = 1.0;
          ml[2 * MB_INST + 22] = -1.0; ml[2 * MB_INST + 54] = 120.0; ml[2 * MB_INST + 55] = 20.0;
          rect_at(ml + 3 * MB_INST, 92, 12, 16, 16, 7, 0.11, 0.11, 0.11, 0);
          ml[3 * MB_INST + 12] = 16.0; ml[3 * MB_INST + 13] = 16.0; ml[3 * MB_INST + 14] = 16.0; ml[3 * MB_INST + 15] = 16.0;
          ml[3 * MB_INST + 21] = 100.0; ml[3 * MB_INST + 22] = 55.0; ml[3 * MB_INST + 23] = -16.0;
          rect_at(ml + 4 * MB_INST, 92, 82, 16, 16, 7, 0.11, 0.11, 0.11, 0);
          ml[4 * MB_INST + 12] = 16.0; ml[4 * MB_INST + 13] = 16.0; ml[4 * MB_INST + 14] = 16.0; ml[4 * MB_INST + 15] = 16.0;
          ml[4 * MB_INST + 21] = 100.0; ml[4 * MB_INST + 22] = 55.0; ml[4 * MB_INST + 23] = -16.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ml, 5, 0.10, 0.10, 0.10);
          present_drain();
          int mcw = 0, mch = 0;
          uint8_t *mpx = read_texture(canvas, &mcw, &mch);
          int it = (40 * mcw + 200) * 4, ib = (180 * mcw + 200) * 4;
          double yt = wcag_luma_u8(mpx[it + 2], mpx[it + 1], mpx[it + 0]);
          double yb = wcag_luma_u8(mpx[ib + 2], mpx[ib + 1], mpx[ib + 0]);
          double bg_top = wcag_luma_u8(245, 245, 245), bg_bot = wcag_luma_u8(26, 26, 26);
          double cr_top = ((yt > bg_top ? yt : bg_top) + 0.05) / ((yt > bg_top ? bg_top : yt) + 0.05);
          double cr_bot = ((yb > bg_bot ? yb : bg_bot) + 0.05) / ((yb > bg_bot ? bg_bot : yb) + 0.05);
          printf("apple_render: bare multiline k=7 top_cr=%.2f bot_cr=%.2f\n", cr_top, cr_bot);
          CHECK(cr_top >= 4.5 && cr_bot >= 4.5);
          free(mpx);
        }
        // Single-band bare kind==11 with legal p.zw=(0,0) at x=80 over light 0.96, ancestor pad.yz=(340,20) over dark 0.10
        {
          double s11[5 * MB_INST];
          rect_at(s11, 0, 0, 200, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(s11 + MB_INST, 200, 0, 200, 300, 0, 0.10, 0.10, 0.10, 0);
          rect_at(s11 + 2 * MB_INST, 0, 0, 400, 68.0, 5, 1.0, 1.0, 1.0, -53);
          s11[2 * MB_INST + 6] = 1.0; s11[2 * MB_INST + 7] = 4.0; s11[2 * MB_INST + 11] = 0.0; s11[2 * MB_INST + 15] = 1.0;
          s11[2 * MB_INST + 22] = -1.0; s11[2 * MB_INST + 54] = 68.0; s11[2 * MB_INST + 55] = 20.0;
          rect_at(s11 + 3 * MB_INST, 72, 12, 16, 16, 11, 0.93, 0.93, 0.93, 0);
          s11[3 * MB_INST + 4] = 0.0; s11[3 * MB_INST + 6] = 0.0; s11[3 * MB_INST + 7] = 0.0;
          s11[3 * MB_INST + 12] = 0.0; s11[3 * MB_INST + 13] = 4.0; s11[3 * MB_INST + 14] = 0.0;
          s11[3 * MB_INST + 21] = 340.0; s11[3 * MB_INST + 22] = 20.0; s11[3 * MB_INST + 23] = -12.0;
          memset(s11 + 4 * MB_INST, 0, MB_INST * sizeof(double));
          s11[4 * MB_INST + 5] = 12.0;
          s11[4 * MB_INST + 0] = 0.0; s11[4 * MB_INST + 1] = 0.0; s11[4 * MB_INST + 2] = 1.0; s11[4 * MB_INST + 3] = 0.0;
          s11[4 * MB_INST + 8] = 1.0; s11[4 * MB_INST + 9] = 0.0; s11[4 * MB_INST + 10] = 1.0; s11[4 * MB_INST + 11] = 1.0;
          s11[4 * MB_INST + 12] = 1.0; s11[4 * MB_INST + 13] = 1.0; s11[4 * MB_INST + 14] = 0.0; s11[4 * MB_INST + 15] = 1.0;
          s11[4 * MB_INST + 16] = 0.0; s11[4 * MB_INST + 17] = 1.0; s11[4 * MB_INST + 18] = 0.0; s11[4 * MB_INST + 19] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(s11, 5, 0.10, 0.10, 0.10);
          present_drain();
          int cw11 = 0, ch11 = 0;
          uint8_t *p11 = read_texture(canvas, &cw11, &ch11);
          int idx11 = (40 * cw11 + 160) * 4;
          double y11 = wcag_luma_u8(p11[idx11 + 2], p11[idx11 + 1], p11[idx11 + 0]);
          double bg_l = wcag_luma_u8(245, 245, 245);
          double cr11 = ((bg_l > y11 ? bg_l : y11) + 0.05) / ((bg_l > y11 ? y11 : bg_l) + 0.05);
          printf("apple_render: bare k=11 zero-offset rgb=(%d,%d,%d) cr=%.2f\n", p11[idx11 + 2], p11[idx11 + 1], p11[idx11 + 0], cr11);
          CHECK(y11 < 0.20 && cr11 >= 4.5);
          free(p11);
        }
        // Merged liquid glass (pad.w=8.0) on left light 0.96 + bare kind==10 icon on right dark 0.10: grab_of must expand capture
        {
          double mlq[4 * MB_INST];
          rect_at(mlq, 0, 0, 200, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(mlq + MB_INST, 200, 0, 200, 300, 0, 0.10, 0.10, 0.10, 0);
          rect_at(mlq + 2 * MB_INST, 10, 10, 40, 28, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -54);
          mlq[2 * MB_INST + 4] = 14.0; mlq[2 * MB_INST + 6] = 1.0; mlq[2 * MB_INST + 7] = 2.0;
          mlq[2 * MB_INST + 11] = 0x67 / 255.0; mlq[2 * MB_INST + 14] = -1.0; mlq[2 * MB_INST + 15] = 1.0;
          mlq[2 * MB_INST + 23] = 8.0; // merged_liquid
          rect_at(mlq + 3 * MB_INST, 300, 14, 16, 12, 10, 0.11, 0.11, 0.11, 0);
          mlq[3 * MB_INST + 4] = 4.0;
          mlq[3 * MB_INST + 12] = 0.1; mlq[3 * MB_INST + 13] = 0.5; mlq[3 * MB_INST + 14] = 0.9; mlq[3 * MB_INST + 15] = 0.5;
          mlq[3 * MB_INST + 21] = 308.0; mlq[3 * MB_INST + 22] = 20.0; mlq[3 * MB_INST + 23] = -12.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(mlq, 4, 0.10, 0.10, 0.10);
          present_drain();
          int cwm = 0, chm = 0;
          uint8_t *pm = read_texture(canvas, &cwm, &chm);
          int idxm = (40 * cwm + 616) * 4;
          double ym = wcag_luma_u8(pm[idxm + 2], pm[idxm + 1], pm[idxm + 0]);
          double bg_d = wcag_luma_u8(26, 26, 26);
          double crm = ((ym > bg_d ? ym : bg_d) + 0.05) / ((ym > bg_d ? bg_d : ym) + 0.05);
          printf("apple_render: bare k=10 after merged_liquid rgb=(%d,%d,%d) cr=%.2f\n", pm[idxm + 2], pm[idxm + 1], pm[idxm + 0], crm);
          CHECK(ym > 0.55 && crm >= 4.5);
          free(pm);
        }
        // Warm-cache vs cold-cache parity (fixed clear color; changing patch strictly outside 2nd glass capture box,
        // inside bare kind==10 icon sample rect): verify control frame cache hit, cold_before != cold_after (>=30),
        // and warm_after == cold_after (<=1)
        {
          double hc[6 * MB_INST];
          rect_at(hc, 0, 0, 200, 300, 0, 0.96, 0.96, 0.96, 0);
          rect_at(hc + MB_INST, 200, 0, 200, 300, 0, 0.40, 0.40, 0.40, 0);
          rect_at(hc + 2 * MB_INST, 266, 0, 27, 300, 0, 0.10, 0.10, 0.10, 0);
          rect_at(hc + 3 * MB_INST, 10, 10, 40, 28, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -49);
          hc[3 * MB_INST + 4] = 14.0; hc[3 * MB_INST + 6] = 1.0; hc[3 * MB_INST + 7] = 2.0;
          hc[3 * MB_INST + 11] = 0x67 / 255.0; hc[3 * MB_INST + 14] = -1.0; hc[3 * MB_INST + 15] = 1.0;
          rect_at(hc + 4 * MB_INST, 298, 14, 16, 12, 10, 0.11, 0.11, 0.11, 0);
          hc[4 * MB_INST + 4] = 4.0;
          hc[4 * MB_INST + 12] = 0.1; hc[4 * MB_INST + 13] = 0.5; hc[4 * MB_INST + 14] = 0.9; hc[4 * MB_INST + 15] = 0.5;
          hc[4 * MB_INST + 21] = 306.0; hc[4 * MB_INST + 22] = 20.0; hc[4 * MB_INST + 23] = -40.0;
          rect_at(hc + 5 * MB_INST, 310, 6, 40, 32, 5, 1.0, 1.0, 1.0, -50);
          hc[5 * MB_INST + 6] = 1.0; hc[5 * MB_INST + 7] = 4.0; hc[5 * MB_INST + 11] = 0.10; hc[5 * MB_INST + 15] = 1.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(hc, 6, 0.40, 0.40, 0.40);
          present_drain();
          int cw0 = 0, ch0 = 0, cwc = 0, chc = 0, cw1 = 0, ch1 = 0, cw2 = 0, ch2 = 0;
          uint8_t *cold_before = read_texture(canvas, &cw0, &ch0);
          // Unchanged control frame
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(hc, 6, 0.40, 0.40, 0.40);
          present_drain();
          uint8_t *ctrl_px = read_texture(canvas, &cwc, &chc);
          int ctrl_diff = 0;
          for (int y = 12; y < 76; y++) {
            for (int x = 620; x < 700; x++) {
              int idx = (y * cw0 + x) * 4;
              for (int c = 0; c < 3; c++) {
                int d = abs((int)cold_before[idx + c] - (int)ctrl_px[idx + c]);
                if (d > ctrl_diff) ctrl_diff = d;
              }
            }
          }
          // Flip ONLY the patch outside 2nd glass capture box (clear color fixed 0.40)
          hc[2 * MB_INST + 8] = 1.0; hc[2 * MB_INST + 9] = 1.0; hc[2 * MB_INST + 10] = 1.0;
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(hc, 6, 0.40, 0.40, 0.40);
          present_drain();
          uint8_t *warm_after = read_texture(canvas, &cw1, &ch1);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(hc, 6, 0.40, 0.40, 0.40);
          present_drain();
          uint8_t *cold_after = read_texture(canvas, &cw2, &ch2);
          int delta_cold = 0, max_diff = 0;
          for (int y = 12; y < 76; y++) {
            for (int x = 620; x < 700; x++) {
              int idx = (y * cw1 + x) * 4;
              for (int c = 0; c < 3; c++) {
                int dc = abs((int)cold_before[idx + c] - (int)cold_after[idx + c]);
                if (dc > delta_cold) delta_cold = dc;
                int dw = abs((int)warm_after[idx + c] - (int)cold_after[idx + c]);
                if (dw > max_diff) max_diff = dw;
              }
            }
          }
          printf("apple_render: bare k=10 warm vs cold 2nd-glass ctrl_diff=%d cold_delta=%d warm_vs_cold=%d\n",
                 ctrl_diff, delta_cold, max_diff);
          CHECK(ctrl_diff == 0 && delta_cold >= 30 && max_diff <= 1);
          free(cold_before); free(ctrl_px); free(warm_after); free(cold_after);
        }
        // Dark-mode adaptive=true pill (0x20202067) full grayscale round-trip sweep (ascending & descending):
        // verifies hysteresis latch in b-channel keeps CR >= 3.0 at EVERY gray level including #B8B8B8/#B9B9B9
        {
          const double grays[] = {
            0.0, 0.25, 0x80/255.0, 0x99/255.0, 0xA8/255.0, 0xB8/255.0, 0xB9/255.0, 0xCC/255.0, 1.0,
            0xCC/255.0, 0xB9/255.0, 0xB8/255.0, 0xA8/255.0, 0x99/255.0, 0x80/255.0, 0.25, 0.0
          };
          int ng = (int)(sizeof(grays) / sizeof(grays[0]));
          double dp[3 * MB_INST];
          rect_at(dp, 0, 0, 400, 300, 0, 0.0, 0.0, 0.0, 0);
          rect_at(dp + MB_INST, 150, 20, 100, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -51);
          dp[MB_INST + 4] = 18.0; dp[MB_INST + 6] = 1.0; dp[MB_INST + 7] = 1.2;
          dp[MB_INST + 11] = 0x67 / 255.0; dp[MB_INST + 12] = 0.6; dp[MB_INST + 13] = 14.0;
          dp[MB_INST + 14] = -1.0; dp[MB_INST + 15] = 1.0;
          dp[MB_INST + 21] = 20.0; dp[MB_INST + 22] = 0.06; dp[MB_INST + 23] = 0.0;
          rect_at(dp + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          dp[2 * MB_INST + 4] = 4.0;
          dp[2 * MB_INST + 12] = 0.1; dp[2 * MB_INST + 13] = 0.5; dp[2 * MB_INST + 14] = 0.9; dp[2 * MB_INST + 15] = 0.5;
          dp[2 * MB_INST + 21] = 200.0; dp[2 * MB_INST + 22] = 38.0; dp[2 * MB_INST + 23] = 18.0;
          glass_forget();
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0;
          double min_cr = 999.0;
          for (int gi = 0; gi < ng; gi++) {
            double gv = grays[gi];
            dp[8] = gv; dp[9] = gv; dp[10] = gv;
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(dp, 3, gv, gv, gv);
            present_drain();
            int dcw = 0, dch = 0;
            uint8_t *dpx = read_texture(canvas, &dcw, &dch);
            int gidx = (76 * dcw + 340) * 4, iidx = (76 * dcw + 400) * 4;
            double gl2 = wcag_luma_u8(dpx[gidx+2], dpx[gidx+1], dpx[gidx+0]);
            double il2 = wcag_luma_u8(dpx[iidx+2], dpx[iidx+1], dpx[iidx+0]);
            double dcr = ((il2 > gl2 ? il2 : gl2) + 0.05) / ((il2 > gl2 ? gl2 : il2) + 0.05);
            if (dcr < min_cr) min_cr = dcr;
            if (dcr < 4.5) {
              printf("apple_render: FAIL dark pill step=%d gray=#%02X glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                     gi, (int)(gv * 255.0 + 0.5), dpx[gidx+2], dpx[gidx+1], dpx[gidx+0], dpx[iidx+2], dpx[iidx+1], dpx[iidx+0], dcr);
            }
            CHECK(dcr >= 4.5);
            free(dpx);
          }
          ad_fixed_dt = prev_dt;
          printf("apple_render: dark adaptive pill round-trip grayscale sweep (%d steps) min_cr=%.2f\n", ng, min_cr);
        }
        // Dark-mode adaptive pill straddling left dark (0.08) + right coral (0.95, 0.65, 0.55):
        // same-pixel glass vs icon contrast must be >= 4.5
        {
          double sc_p[4 * MB_INST];
          rect_at(sc_p, 0, 0, 180, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(sc_p + MB_INST, 180, 0, 220, 300, 0, 0.95, 0.65, 0.55, 0);
          rect_at(sc_p + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -55);
          sc_p[2 * MB_INST + 4] = 20.0; sc_p[2 * MB_INST + 6] = 1.0; sc_p[2 * MB_INST + 7] = 1.2;
          sc_p[2 * MB_INST + 11] = 0x67 / 255.0; sc_p[2 * MB_INST + 12] = 0.6; sc_p[2 * MB_INST + 13] = 14.0;
          sc_p[2 * MB_INST + 14] = -1.0; sc_p[2 * MB_INST + 15] = 1.0;
          sc_p[2 * MB_INST + 21] = 20.0; sc_p[2 * MB_INST + 22] = 0.06; sc_p[2 * MB_INST + 23] = 0.0;
          rect_at(sc_p + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          sc_p[3 * MB_INST + 4] = 4.0;
          sc_p[3 * MB_INST + 12] = 0.1; sc_p[3 * MB_INST + 13] = 0.5; sc_p[3 * MB_INST + 14] = 0.9; sc_p[3 * MB_INST + 15] = 0.5;
          sc_p[3 * MB_INST + 21] = 176.0; sc_p[3 * MB_INST + 22] = 38.0; sc_p[3 * MB_INST + 23] = 20.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(sc_p, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, scw = 0, sch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(sc_p, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *spx = read_texture(canvas, &scw, &sch);
          int gidx = (76 * bcw + 380) * 4, iidx = (76 * scw + 380) * 4;
          double gl3 = wcag_luma_u8(bgx[gidx+2], bgx[gidx+1], bgx[gidx+0]);
          double il3 = wcag_luma_u8(spx[iidx+2], spx[iidx+1], spx[iidx+0]);
          double scr = ((il3 > gl3 ? il3 : gl3) + 0.05) / ((il3 > gl3 ? gl3 : il3) + 0.05);
          printf("apple_render: dark adaptive straddle dark+coral: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 bgx[gidx+2], bgx[gidx+1], bgx[gidx+0], spx[iidx+2], spx[iidx+1], spx[iidx+0], scr);
          CHECK(scr >= 4.5);
          free(bgx); free(spx);
        }
        // R3-1A: Dark capsule straddling left white (1.0) + right dark gray (0.08), icon in right dark zone -> stays bright white (CR >= 4.5)
        {
          double wd_p[4 * MB_INST];
          rect_at(wd_p, 0, 0, 172, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(wd_p + MB_INST, 172, 0, 228, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(wd_p + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -56);
          wd_p[2 * MB_INST + 4] = 20.0; wd_p[2 * MB_INST + 6] = 1.0; wd_p[2 * MB_INST + 7] = 1.2;
          wd_p[2 * MB_INST + 11] = 0x67 / 255.0; wd_p[2 * MB_INST + 12] = 0.6; wd_p[2 * MB_INST + 13] = 14.0;
          wd_p[2 * MB_INST + 14] = -1.0; wd_p[2 * MB_INST + 15] = 1.0;
          wd_p[2 * MB_INST + 21] = 20.0; wd_p[2 * MB_INST + 22] = 0.06; wd_p[2 * MB_INST + 23] = 0.0;
          rect_at(wd_p + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          wd_p[3 * MB_INST + 4] = 4.0;
          wd_p[3 * MB_INST + 12] = 0.1; wd_p[3 * MB_INST + 13] = 0.5; wd_p[3 * MB_INST + 14] = 0.9; wd_p[3 * MB_INST + 15] = 0.5;
          wd_p[3 * MB_INST + 21] = 176.0; wd_p[3 * MB_INST + 22] = 38.0; wd_p[3 * MB_INST + 23] = 20.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(wd_p, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(wd_p, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int gidx = (76 * bcw + 380) * 4, iidx = (76 * cw + 380) * 4;
          double gl = wcag_luma_u8(bgx[gidx+2], bgx[gidx+1], bgx[gidx+0]);
          double il = wcag_luma_u8(px[iidx+2], px[iidx+1], px[iidx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive straddle white+dark right-icon: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 bgx[gidx+2], bgx[gidx+1], bgx[gidx+0], px[iidx+2], px[iidx+1], px[iidx+0], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }
        // R3-1B: Light adaptive capsule on uniform dark gray (0.08) + light neutral icon -> stays bright white (no b-channel collision)
        {
          double ld_p[3 * MB_INST];
          rect_at(ld_p, 0, 0, 400, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ld_p + MB_INST, 150, 20, 100, 36, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -57);
          ld_p[MB_INST + 4] = 18.0; ld_p[MB_INST + 6] = 1.0; ld_p[MB_INST + 7] = 1.2;
          ld_p[MB_INST + 11] = 0x67 / 255.0; ld_p[MB_INST + 12] = 0.6; ld_p[MB_INST + 13] = 14.0;
          ld_p[MB_INST + 14] = -1.0; ld_p[MB_INST + 15] = 1.0;
          ld_p[MB_INST + 21] = 20.0; ld_p[MB_INST + 22] = 0.06; ld_p[MB_INST + 23] = 0.0;
          rect_at(ld_p + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          ld_p[2 * MB_INST + 4] = 4.0;
          ld_p[2 * MB_INST + 12] = 0.1; ld_p[2 * MB_INST + 13] = 0.5; ld_p[2 * MB_INST + 14] = 0.9; ld_p[2 * MB_INST + 15] = 0.5;
          ld_p[2 * MB_INST + 21] = 200.0; ld_p[2 * MB_INST + 22] = 38.0; ld_p[2 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ld_p, 3, 0.08, 0.08, 0.08);
          present_drain();
          int cw = 0, ch = 0;
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int gidx = (76 * cw + 340) * 4, iidx = (76 * cw + 400) * 4;
          double gl = wcag_luma_u8(px[gidx+2], px[gidx+1], px[gidx+0]);
          double il = wcag_luma_u8(px[iidx+2], px[iidx+1], px[iidx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: light adaptive on dark + light icon: glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 px[gidx+2], px[gidx+1], px[gidx+0], px[iidx+2], px[iidx+1], px[iidx+0], cr);
          CHECK(il > 0.70 && cr >= 4.5);
          free(px);
        }
        // R3-1C: 4-frame hysteresis jitter test (zero flicker): (1) #9A/#9B straddle, (2) #7A/#7B inside [0.20, 0.26] band
        {
          double jt[4 * MB_INST];
          rect_at(jt, 0, 0, 180, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(jt + MB_INST, 180, 0, 220, 300, 0, 0x9A/255.0, 0x9A/255.0, 0x9A/255.0, 0);
          rect_at(jt + 2 * MB_INST, 152, 18, 48, 40, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -58);
          jt[2 * MB_INST + 4] = 20.0; jt[2 * MB_INST + 6] = 1.0; jt[2 * MB_INST + 7] = 1.2;
          jt[2 * MB_INST + 11] = 0x67 / 255.0; jt[2 * MB_INST + 12] = 0.6; jt[2 * MB_INST + 13] = 14.0;
          jt[2 * MB_INST + 14] = -1.0; jt[2 * MB_INST + 15] = 1.0;
          jt[2 * MB_INST + 21] = 20.0; jt[2 * MB_INST + 22] = 0.06; jt[2 * MB_INST + 23] = 0.0;
          rect_at(jt + 3 * MB_INST, 184, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          jt[3 * MB_INST + 4] = 4.0;
          jt[3 * MB_INST + 12] = 0.1; jt[3 * MB_INST + 13] = 0.5; jt[3 * MB_INST + 14] = 0.9; jt[3 * MB_INST + 15] = 0.5;
          jt[3 * MB_INST + 21] = 176.0; jt[3 * MB_INST + 22] = 38.0; jt[3 * MB_INST + 23] = 20.0;
          const double seq1[4] = { 0x9A/255.0, 0x9B/255.0, 0x9A/255.0, 0x9B/255.0 };
          glass_forget();
          uint8_t ref1[3] = {0, 0, 0};
          int max_j1 = 0;
          for (int f = 0; f < 4; f++) {
            jt[MB_INST + 8] = seq1[f]; jt[MB_INST + 9] = seq1[f]; jt[MB_INST + 10] = seq1[f];
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(jt, 4, 0.08, 0.08, 0.08);
            present_drain();
            int cw = 0, ch = 0;
            uint8_t *px = read_texture(canvas, &cw, &ch);
            int iidx = (76 * cw + 380) * 4;
            if (f == 0) { ref1[0] = px[iidx+2]; ref1[1] = px[iidx+1]; ref1[2] = px[iidx+0]; }
            else {
              int d0 = abs((int)px[iidx+2] - (int)ref1[0]), d1 = abs((int)px[iidx+1] - (int)ref1[1]), d2 = abs((int)px[iidx+0] - (int)ref1[2]);
              if (d0 > max_j1) max_j1 = d0; if (d1 > max_j1) max_j1 = d1; if (d2 > max_j1) max_j1 = d2;
            }
            free(px);
          }
          const double seq2[4] = { 0x7A/255.0, 0x7B/255.0, 0x7A/255.0, 0x7B/255.0 };
          glass_forget();
          jt[MB_INST + 8] = 0.08; jt[MB_INST + 9] = 0.08; jt[MB_INST + 10] = 0.08;
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(jt, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t ref2[3] = {0, 0, 0};
          int max_j2 = 0;
          for (int f = 0; f < 4; f++) {
            jt[MB_INST + 8] = seq2[f]; jt[MB_INST + 9] = seq2[f]; jt[MB_INST + 10] = seq2[f];
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(jt, 4, 0.08, 0.08, 0.08);
            present_drain();
            int cw = 0, ch = 0;
            uint8_t *px = read_texture(canvas, &cw, &ch);
            int iidx = (76 * cw + 380) * 4;
            if (f == 0) { ref2[0] = px[iidx+2]; ref2[1] = px[iidx+1]; ref2[2] = px[iidx+0]; }
            else {
              int d0 = abs((int)px[iidx+2] - (int)ref2[0]), d1 = abs((int)px[iidx+1] - (int)ref2[1]), d2 = abs((int)px[iidx+0] - (int)ref2[2]);
              if (d0 > max_j2) max_j2 = d0; if (d1 > max_j2) max_j2 = d1; if (d2 > max_j2) max_j2 = d2;
            }
            free(px);
          }
          printf("apple_render: dark adaptive 4-frame jitter #9A/#9B diff=%d #7A/#7B diff=%d\n", max_j1, max_j2);
          CHECK(max_j1 == 0 && max_j2 == 0);
        }
        // R3-1D: Text glyphs (kind==7, is_icon==false) inside dark capsule straddling light/dark -> uniform word ink AND CR >= 4.5 on BOTH halves
        {
          double tx_p[5 * MB_INST];
          rect_at(tx_p, 0, 0, 180, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(tx_p + MB_INST, 180, 0, 220, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tx_p + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -59);
          tx_p[2 * MB_INST + 4] = 18.0; tx_p[2 * MB_INST + 6] = 1.0; tx_p[2 * MB_INST + 7] = 1.2;
          tx_p[2 * MB_INST + 11] = 0x67 / 255.0; tx_p[2 * MB_INST + 12] = 0.6; tx_p[2 * MB_INST + 13] = 14.0;
          tx_p[2 * MB_INST + 14] = -1.0; tx_p[2 * MB_INST + 15] = 1.0;
          tx_p[2 * MB_INST + 21] = 20.0; tx_p[2 * MB_INST + 22] = 0.06; tx_p[2 * MB_INST + 23] = 0.0;
          rect_at(tx_p + 3 * MB_INST, 124, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tx_p[3 * MB_INST + 12] = 16.0; tx_p[3 * MB_INST + 13] = 16.0; tx_p[3 * MB_INST + 14] = 16.0; tx_p[3 * MB_INST + 15] = 16.0;
          tx_p[3 * MB_INST + 21] = 180.0; tx_p[3 * MB_INST + 22] = 38.0; tx_p[3 * MB_INST + 23] = 18.0;
          rect_at(tx_p + 4 * MB_INST, 224, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tx_p[4 * MB_INST + 12] = 16.0; tx_p[4 * MB_INST + 13] = 16.0; tx_p[4 * MB_INST + 14] = 16.0; tx_p[4 * MB_INST + 15] = 16.0;
          tx_p[4 * MB_INST + 21] = 180.0; tx_p[4 * MB_INST + 22] = 38.0; tx_p[4 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tx_p, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tx_p, 5, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int li = (76 * cw + 260) * 4, ri = (76 * cw + 460) * 4;
          int word_diff = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)px[li+c] - (int)px[ri+c]); if (d > word_diff) word_diff = d; }
          double ybl = wcag_luma_u8(bgx[li+2], bgx[li+1], bgx[li+0]), yil = wcag_luma_u8(px[li+2], px[li+1], px[li+0]);
          double ybr = wcag_luma_u8(bgx[ri+2], bgx[ri+1], bgx[ri+0]), yir = wcag_luma_u8(px[ri+2], px[ri+1], px[ri+0]);
          double cr_l = ((yil > ybl ? yil : ybl) + 0.05) / ((yil > ybl ? ybl : yil) + 0.05);
          double cr_r = ((yir > ybr ? yir : ybr) + 0.05) / ((yir > ybr ? ybr : yir) + 0.05);
          printf("apple_render: dark adaptive straddle text uniform left_cr=%.2f right_cr=%.2f diff=%d\n", cr_l, cr_r, word_diff);
          CHECK(word_diff <= 1 && cr_l >= 4.5 && cr_r >= 4.5);
          free(bgx); free(px);
        }
        // R4-1E: Wide capsule (x=100..260, split x=216, icon at (238,38)) both directions -> same-pixel CR >= 4.5
        for (int dir = 0; dir < 2; dir++) {
          double lv = dir == 0 ? 1.0 : 0.08;
          double rv = dir == 0 ? 0.08 : 1.0;
          double wc[4 * MB_INST];
          rect_at(wc, 0, 0, 216, 300, 0, lv, lv, lv, 0);
          rect_at(wc + MB_INST, 216, 0, 184, 300, 0, rv, rv, rv, 0);
          rect_at(wc + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -60 - dir);
          wc[2 * MB_INST + 4] = 18.0; wc[2 * MB_INST + 6] = 1.0; wc[2 * MB_INST + 7] = 1.2;
          wc[2 * MB_INST + 11] = 0x67 / 255.0; wc[2 * MB_INST + 12] = 0.6; wc[2 * MB_INST + 13] = 14.0;
          wc[2 * MB_INST + 14] = -1.0; wc[2 * MB_INST + 15] = 1.0;
          wc[2 * MB_INST + 21] = 20.0; wc[2 * MB_INST + 22] = 0.06; wc[2 * MB_INST + 23] = 0.0;
          rect_at(wc + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          wc[3 * MB_INST + 4] = 4.0;
          wc[3 * MB_INST + 12] = 0.1; wc[3 * MB_INST + 13] = 0.5; wc[3 * MB_INST + 14] = 0.9; wc[3 * MB_INST + 15] = 0.5;
          wc[3 * MB_INST + 21] = 180.0; wc[3 * MB_INST + 22] = 38.0; wc[3 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(wc, 3, rv, rv, rv);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(wc, 4, rv, rv, rv);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int idx = (76 * cw + 476) * 4;
          double gl = wcag_luma_u8(bgx[idx+2], bgx[idx+1], bgx[idx+0]);
          double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive wide off-center dir=%d glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 dir, bgx[idx+2], bgx[idx+1], bgx[idx+0], px[idx+2], px[idx+1], px[idx+0], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }
        // R5-1: 60 Hz straddling word transition (right=#141414, left #141414 -> white, dt=1/60, 15 frames)
        {
          double tr[5 * MB_INST];
          rect_at(tr, 0, 0, 180, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tr + MB_INST, 180, 0, 220, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(tr + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -62);
          tr[2 * MB_INST + 4] = 18.0; tr[2 * MB_INST + 6] = 1.0; tr[2 * MB_INST + 7] = 1.2;
          tr[2 * MB_INST + 11] = 0x67 / 255.0; tr[2 * MB_INST + 12] = 0.6; tr[2 * MB_INST + 13] = 14.0;
          tr[2 * MB_INST + 14] = -1.0; tr[2 * MB_INST + 15] = 1.0;
          tr[2 * MB_INST + 21] = 20.0; tr[2 * MB_INST + 22] = 0.06; tr[2 * MB_INST + 23] = 0.0;
          rect_at(tr + 3 * MB_INST, 124, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tr[3 * MB_INST + 12] = 16.0; tr[3 * MB_INST + 13] = 16.0; tr[3 * MB_INST + 14] = 16.0; tr[3 * MB_INST + 15] = 16.0;
          tr[3 * MB_INST + 21] = 180.0; tr[3 * MB_INST + 22] = 38.0; tr[3 * MB_INST + 23] = 18.0;
          rect_at(tr + 4 * MB_INST, 224, 32, 12, 12, 7, 0.93, 0.93, 0.93, 0);
          tr[4 * MB_INST + 12] = 16.0; tr[4 * MB_INST + 13] = 16.0; tr[4 * MB_INST + 14] = 16.0; tr[4 * MB_INST + 15] = 16.0;
          tr[4 * MB_INST + 21] = 180.0; tr[4 * MB_INST + 22] = 38.0; tr[4 * MB_INST + 23] = 18.0;
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0 / 60.0;
          tr[8] = 1.0; tr[9] = 1.0; tr[10] = 1.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tr, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          tr[8] = 0.08; tr[9] = 0.08; tr[10] = 0.08;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(tr, 5, 0.08, 0.08, 0.08);
          present_drain();
          tr[8] = 1.0; tr[9] = 1.0; tr[10] = 1.0;
          double min_l = 999.0, min_r = 999.0;
          int max_wd = 0;
          int li = (76 * bcw + 260) * 4, ri = (76 * bcw + 460) * 4;
          double ybl = wcag_luma_u8(bgx[li+2], bgx[li+1], bgx[li+0]);
          double ybr = wcag_luma_u8(bgx[ri+2], bgx[ri+1], bgx[ri+0]);
          for (int fr = 1; fr <= 15; fr++) {
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(tr, 5, 0.08, 0.08, 0.08);
            present_drain();
            int cw = 0, ch = 0;
            uint8_t *px = read_texture(canvas, &cw, &ch);
            int wd = 0;
            for (int c = 0; c < 3; c++) { int d = abs((int)px[li+c] - (int)px[ri+c]); if (d > wd) wd = d; }
            if (wd > max_wd) max_wd = wd;
            double yil = wcag_luma_u8(px[li+2], px[li+1], px[li+0]);
            double yir = wcag_luma_u8(px[ri+2], px[ri+1], px[ri+0]);
            double cr_l = ((yil > ybl ? yil : ybl) + 0.05) / ((yil > ybl ? ybl : yil) + 0.05);
            double cr_r = ((yir > ybr ? yir : ybr) + 0.05) / ((yir > ybr ? ybr : yir) + 0.05);
            if (cr_l < min_l) min_l = cr_l;
            if (cr_r < min_r) min_r = cr_r;
            CHECK(wd <= 1 && cr_l >= 4.5 && cr_r >= 4.5);
            free(px);
          }
          ad_fixed_dt = prev_dt;
          printf("apple_render: dark adaptive 60Hz transition (15 frames) min_left_cr=%.2f min_right_cr=%.2f max_wd=%d\n",
                 min_l, min_r, max_wd);
          free(bgx);
        }
        // R5-2: p.muted (#A8AAAE) on dark-left/white-right & primary (#EDEDED) on dark-left/pure-red-right
        for (int tc = 0; tc < 2; tc++) {
          double mr[4 * MB_INST];
          rect_at(mr, 0, 0, 216, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(mr + MB_INST, 216, 0, 184, 300, 0, 1.0, tc == 0 ? 1.0 : 0.0, tc == 0 ? 1.0 : 0.0, 0);
          rect_at(mr + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -63 - tc);
          mr[2 * MB_INST + 4] = 18.0; mr[2 * MB_INST + 6] = 1.0; mr[2 * MB_INST + 7] = 1.2;
          mr[2 * MB_INST + 11] = 0x67 / 255.0; mr[2 * MB_INST + 12] = 0.6; mr[2 * MB_INST + 13] = 14.0;
          mr[2 * MB_INST + 14] = -1.0; mr[2 * MB_INST + 15] = 1.0;
          mr[2 * MB_INST + 21] = 20.0; mr[2 * MB_INST + 22] = 0.06; mr[2 * MB_INST + 23] = 0.0;
          rect_at(mr + 3 * MB_INST, 232, 32, 12, 12, 10,
                  tc == 0 ? (0xA8/255.0) : 0.93, tc == 0 ? (0xAA/255.0) : 0.93, tc == 0 ? (0xAE/255.0) : 0.93, 0);
          mr[3 * MB_INST + 4] = 4.0;
          mr[3 * MB_INST + 12] = 0.1; mr[3 * MB_INST + 13] = 0.5; mr[3 * MB_INST + 14] = 0.9; mr[3 * MB_INST + 15] = 0.5;
          mr[3 * MB_INST + 21] = 180.0; mr[3 * MB_INST + 22] = 38.0; mr[3 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(mr, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(mr, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int idx = (76 * cw + 476) * 4;
          double gl = wcag_luma_u8(bgx[idx+2], bgx[idx+1], bgx[idx+0]);
          double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive %s glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 tc == 0 ? "p.muted-white" : "pure-red", bgx[idx+2], bgx[idx+1], bgx[idx+0], px[idx+2], px[idx+1], px[idx+0], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }
        // R5-3: High tint alpha 0xA8 and 0xCC wide capsule (white-left + dark-right) -> stays dark glass + light ink, CR >= 4.5
        for (int ti = 0; ti < 2; ti++) {
          double alpha = ti == 0 ? (0xA8 / 255.0) : (0xCC / 255.0);
          double ht[4 * MB_INST];
          rect_at(ht, 0, 0, 216, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(ht + MB_INST, 216, 0, 184, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ht + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -65 - ti);
          ht[2 * MB_INST + 4] = 18.0; ht[2 * MB_INST + 6] = 1.0; ht[2 * MB_INST + 7] = 1.2;
          ht[2 * MB_INST + 11] = alpha; ht[2 * MB_INST + 12] = 0.6; ht[2 * MB_INST + 13] = 14.0;
          ht[2 * MB_INST + 14] = -1.0; ht[2 * MB_INST + 15] = 1.0;
          ht[2 * MB_INST + 21] = 20.0; ht[2 * MB_INST + 22] = 0.06; ht[2 * MB_INST + 23] = 0.0;
          rect_at(ht + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          ht[3 * MB_INST + 4] = 4.0;
          ht[3 * MB_INST + 12] = 0.1; ht[3 * MB_INST + 13] = 0.5; ht[3 * MB_INST + 14] = 0.9; ht[3 * MB_INST + 15] = 0.5;
          ht[3 * MB_INST + 21] = 180.0; ht[3 * MB_INST + 22] = 38.0; ht[3 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ht, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ht, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int idx = (76 * cw + 476) * 4;
          double gl = wcag_luma_u8(bgx[idx+2], bgx[idx+1], bgx[idx+0]);
          double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive high-alpha=0x%02X glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 ti == 0 ? 0xA8 : 0xCC, bgx[idx+2], bgx[idx+1], bgx[idx+0], px[idx+2], px[idx+1], px[idx+0], cr);
          CHECK(il > 0.70 && cr >= 4.5);
          free(bgx); free(px);
        }
        // R5-4: Dark -> White -> Dark 50-frame round-trip cache hit (fixed clear color)
        {
          double rt[3 * MB_INST];
          rect_at(rt, 0, 0, 400, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(rt + MB_INST, 150, 20, 100, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -67);
          rt[MB_INST + 4] = 18.0; rt[MB_INST + 6] = 1.0; rt[MB_INST + 7] = 1.2;
          rt[MB_INST + 11] = 0x67 / 255.0; rt[MB_INST + 12] = 0.6; rt[MB_INST + 13] = 14.0;
          rt[MB_INST + 14] = -1.0; rt[MB_INST + 15] = 1.0;
          rt[MB_INST + 21] = 20.0; rt[MB_INST + 22] = 0.06; rt[MB_INST + 23] = 0.0;
          rect_at(rt + 2 * MB_INST, 192, 32, 16, 12, 10, 0.93, 0.93, 0.93, 0);
          rt[2 * MB_INST + 4] = 4.0;
          rt[2 * MB_INST + 12] = 0.1; rt[2 * MB_INST + 13] = 0.5; rt[2 * MB_INST + 14] = 0.9; rt[2 * MB_INST + 15] = 0.5;
          rt[2 * MB_INST + 21] = 200.0; rt[2 * MB_INST + 22] = 38.0; rt[2 * MB_INST + 23] = 18.0;
          double prev_dt = ad_fixed_dt;
          ad_fixed_dt = 1.0 / 60.0;
          glass_forget();
          for (int ph = 0; ph < 3; ph++) {
            double v = (ph == 1) ? 1.0 : 0.08;
            rt[8] = v; rt[9] = v; rt[10] = v;
            for (int f = 0; f < 50; f++) {
              mb_host_render_dirty(0, 0, 400, 300);
              mb_render_present(rt, 3, 0.08, 0.08, 0.08);
              present_drain();
            }
          }
          ad_fixed_dt = prev_dt;
          int cw = 0, ch = 0;
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int gidx = (76 * cw + 340) * 4, iidx = (76 * cw + 400) * 4;
          int settling = at_win ? at_win->ad_settling : 0;
          printf("apple_render: dark adaptive 50x3 round-trip cache-hit glass=(%d,%d,%d) icon=(%d,%d,%d) settling=%d\n",
                 px[gidx+2], px[gidx+1], px[gidx+0], px[iidx+2], px[iidx+1], px[iidx+0], settling);
          CHECK(px[gidx+2] < 70 && px[iidx+2] > 200 && settling == 0);
          free(px);
        }
        // R6-1: Same capsule raises tint alpha 0x67 -> 0xA8 under partial dirty (98,16,164,42) across 50 frames
        {
          double pa[4 * MB_INST];
          rect_at(pa, 0, 0, 216, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(pa + MB_INST, 216, 0, 184, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(pa + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -68);
          pa[2 * MB_INST + 4] = 18.0; pa[2 * MB_INST + 6] = 1.0; pa[2 * MB_INST + 7] = 1.2;
          pa[2 * MB_INST + 11] = 0xA8 / 255.0; pa[2 * MB_INST + 12] = 0.6; pa[2 * MB_INST + 13] = 14.0;
          pa[2 * MB_INST + 14] = -1.0; pa[2 * MB_INST + 15] = 1.0;
          pa[2 * MB_INST + 21] = 20.0; pa[2 * MB_INST + 22] = 0.06; pa[2 * MB_INST + 23] = 0.0;
          rect_at(pa + 3 * MB_INST, 232, 32, 12, 12, 10, 0.93, 0.93, 0.93, 0);
          pa[3 * MB_INST + 4] = 4.0;
          pa[3 * MB_INST + 12] = 0.1; pa[3 * MB_INST + 13] = 0.5; pa[3 * MB_INST + 14] = 0.9; pa[3 * MB_INST + 15] = 0.5;
          pa[3 * MB_INST + 21] = 180.0; pa[3 * MB_INST + 22] = 38.0; pa[3 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(pa, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          int bidx = (76 * bcw + 476) * 4;
          double gl = wcag_luma_u8(bgx[bidx+2], bgx[bidx+1], bgx[bidx+0]);
          pa[2 * MB_INST + 11] = 0x67 / 255.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(pa, 4, 0.08, 0.08, 0.08);
          present_drain();
          mb_host_render_dirty(98, 16, 164, 42);
          mb_render_present(pa, 4, 0.08, 0.08, 0.08);
          present_drain();
          pa[2 * MB_INST + 11] = 0xA8 / 255.0;
          double min_cr = 999.0;
          for (int f = 0; f < 50; f++) {
            mb_host_render_dirty(98, 16, 164, 42);
            mb_render_present(pa, 4, 0.08, 0.08, 0.08);
            present_drain();
            int cw = 0, ch = 0;
            uint8_t *px = read_texture(canvas, &cw, &ch);
            int idx = (76 * cw + 476) * 4;
            double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
            double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
            if (cr < min_cr) min_cr = cr;
            CHECK(il > 0.70 && cr >= 4.5);
            free(px);
          }
          printf("apple_render: dark adaptive 0x67->0xA8 partial-dirty 50f min_cr=%.2f\n", min_cr);
          free(bgx);
        }
        // R6-2: Narrow bright edge (split x=242, capsule 100..260) + p.muted (#A8AAAE) icon at (250,38) -> CR >= 4.5
        {
          double nm[4 * MB_INST];
          rect_at(nm, 0, 0, 242, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(nm + MB_INST, 242, 0, 158, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(nm + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -69);
          nm[2 * MB_INST + 4] = 18.0; nm[2 * MB_INST + 6] = 1.0; nm[2 * MB_INST + 7] = 1.2;
          nm[2 * MB_INST + 11] = 0x67 / 255.0; nm[2 * MB_INST + 12] = 0.6; nm[2 * MB_INST + 13] = 14.0;
          nm[2 * MB_INST + 14] = -1.0; nm[2 * MB_INST + 15] = 1.0;
          nm[2 * MB_INST + 21] = 20.0; nm[2 * MB_INST + 22] = 0.06; nm[2 * MB_INST + 23] = 0.0;
          rect_at(nm + 3 * MB_INST, 244, 32, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          nm[3 * MB_INST + 4] = 4.0;
          nm[3 * MB_INST + 12] = 0.1; nm[3 * MB_INST + 13] = 0.5; nm[3 * MB_INST + 14] = 0.9; nm[3 * MB_INST + 15] = 0.5;
          nm[3 * MB_INST + 21] = 180.0; nm[3 * MB_INST + 22] = 38.0; nm[3 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(nm, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(nm, 4, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int idx = (76 * cw + 500) * 4;
          double gl = wcag_luma_u8(bgx[idx+2], bgx[idx+1], bgx[idx+0]);
          double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive narrow-bright p.muted glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 bgx[idx+2], bgx[idx+1], bgx[idx+0], px[idx+2], px[idx+1], px[idx+0], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }
        // R7-1: Narrow bright edge (split x=242, capsule 100..260) + short muted word (p.muted #A8AAAE)
        {
          double mw[5 * MB_INST];
          rect_at(mw, 0, 0, 242, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(mw + MB_INST, 242, 0, 158, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(mw + 2 * MB_INST, 100, 20, 160, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -70);
          mw[2 * MB_INST + 4] = 18.0; mw[2 * MB_INST + 6] = 1.0; mw[2 * MB_INST + 7] = 1.2;
          mw[2 * MB_INST + 11] = 0x67 / 255.0; mw[2 * MB_INST + 12] = 0.6; mw[2 * MB_INST + 13] = 14.0;
          mw[2 * MB_INST + 14] = -1.0; mw[2 * MB_INST + 15] = 1.0;
          mw[2 * MB_INST + 21] = 20.0; mw[2 * MB_INST + 22] = 0.06; mw[2 * MB_INST + 23] = 0.0;
          rect_at(mw + 3 * MB_INST, 194, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          mw[3 * MB_INST + 6] = 22.0; mw[3 * MB_INST + 7] = 0.0;
          mw[3 * MB_INST + 12] = 16.0; mw[3 * MB_INST + 13] = 16.0; mw[3 * MB_INST + 14] = 16.0; mw[3 * MB_INST + 15] = 16.0;
          mw[3 * MB_INST + 21] = 180.0; mw[3 * MB_INST + 22] = 38.0; mw[3 * MB_INST + 23] = 18.0;
          rect_at(mw + 4 * MB_INST, 245, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          mw[4 * MB_INST + 6] = -29.0; mw[4 * MB_INST + 7] = 0.0;
          mw[4 * MB_INST + 12] = 16.0; mw[4 * MB_INST + 13] = 16.0; mw[4 * MB_INST + 14] = 16.0; mw[4 * MB_INST + 15] = 16.0;
          mw[4 * MB_INST + 21] = 180.0; mw[4 * MB_INST + 22] = 38.0; mw[4 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(mw, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(mw, 5, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int ilx = (76 * cw + 400) * 4, irx = (76 * cw + 502) * 4;
          double ll = wcag_luma_u8(bgx[ilx+2], bgx[ilx+1], bgx[ilx+0]), fl = wcag_luma_u8(px[ilx+2], px[ilx+1], px[ilx+0]);
          double lr = wcag_luma_u8(bgx[irx+2], bgx[irx+1], bgx[irx+0]), fr = wcag_luma_u8(px[irx+2], px[irx+1], px[irx+0]);
          double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
          double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
          int wd = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)px[ilx+c] - (int)px[irx+c]); if (d > wd) wd = d; }
          printf("apple_render: dark adaptive narrow-bright muted-word left_cr=%.2f right_cr=%.2f diff=%d\n", crl, crr, wd);
          CHECK(wd <= 1 && crl >= 4.5 && crr >= 4.5);
          free(bgx); free(px);
        }
        // R8-1: Wide 320pt capsule (40..360) with 16pt white stripe sweeping across icon (238,38) and
        // short muted word (center 212, last glyph 239)
        {
          double sw[6 * MB_INST];
          rect_at(sw, 0, 0, 400, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(sw + MB_INST, 224, 0, 16, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(sw + 2 * MB_INST, 40, 20, 320, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -71);
          sw[2 * MB_INST + 4] = 18.0; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = 1.2;
          sw[2 * MB_INST + 11] = 0x67 / 255.0; sw[2 * MB_INST + 12] = 0.6; sw[2 * MB_INST + 13] = 14.0;
          sw[2 * MB_INST + 14] = -1.0; sw[2 * MB_INST + 15] = 1.0;
          sw[2 * MB_INST + 21] = 20.0; sw[2 * MB_INST + 22] = 0.06; sw[2 * MB_INST + 23] = 0.0;
          rect_at(sw + 3 * MB_INST, 232, 32, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[3 * MB_INST + 4] = 4.0;
          sw[3 * MB_INST + 12] = 0.1; sw[3 * MB_INST + 13] = 0.5; sw[3 * MB_INST + 14] = 0.9; sw[3 * MB_INST + 15] = 0.5;
          sw[3 * MB_INST + 21] = 200.0; sw[3 * MB_INST + 22] = 38.0; sw[3 * MB_INST + 23] = 18.0;
          rect_at(sw + 4 * MB_INST, 179, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[4 * MB_INST + 6] = 27.0; sw[4 * MB_INST + 7] = 0.0;
          sw[4 * MB_INST + 12] = 16.0; sw[4 * MB_INST + 13] = 16.0; sw[4 * MB_INST + 14] = 16.0; sw[4 * MB_INST + 15] = 16.0;
          sw[4 * MB_INST + 21] = 200.0; sw[4 * MB_INST + 22] = 38.0; sw[4 * MB_INST + 23] = 18.0;
          rect_at(sw + 5 * MB_INST, 233, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          sw[5 * MB_INST + 6] = -27.0; sw[5 * MB_INST + 7] = 0.0;
          sw[5 * MB_INST + 12] = 16.0; sw[5 * MB_INST + 13] = 16.0; sw[5 * MB_INST + 14] = 16.0; sw[5 * MB_INST + 15] = 16.0;
          sw[5 * MB_INST + 21] = 200.0; sw[5 * MB_INST + 22] = 38.0; sw[5 * MB_INST + 23] = 18.0;
          double min_icr = 999.0, min_wcr = 999.0;
          int max_wd = 0;
          for (int sx = 224; sx <= 240; sx += 4) {
            sw[MB_INST + 0] = (double)sx;
            glass_forget();
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(sw, 3, 0.08, 0.08, 0.08);
            present_drain();
            int bcw = 0, bch = 0, cw = 0, ch = 0;
            uint8_t *bgx = read_texture(canvas, &bcw, &bch);
            glass_forget();
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(sw, 4, 0.08, 0.08, 0.08);
            present_drain();
            uint8_t *ipx = read_texture(canvas, &cw, &ch);
            int iidx = (76 * cw + 476) * 4;
            double li = wcag_luma_u8(bgx[iidx+2], bgx[iidx+1], bgx[iidx+0]);
            double fi = wcag_luma_u8(ipx[iidx+2], ipx[iidx+1], ipx[iidx+0]);
            double icr = ((fi > li ? fi : li) + 0.05) / ((fi > li ? li : fi) + 0.05);
            if (icr < min_icr) min_icr = icr;
            CHECK(icr >= 4.5);
            free(ipx);
            double sww[5 * MB_INST];
            memcpy(sww, sw, 3 * MB_INST * sizeof(double));
            memcpy(sww + 3 * MB_INST, sw + 4 * MB_INST, 2 * MB_INST * sizeof(double));
            glass_forget();
            mb_host_render_dirty(0, 0, 400, 300);
            mb_render_present(sww, 5, 0.08, 0.08, 0.08);
            present_drain();
            uint8_t *wpx = read_texture(canvas, &cw, &ch);
            int ilx = (76 * cw + 370) * 4, irx = (76 * cw + 478) * 4;
            double ll = wcag_luma_u8(bgx[ilx+2], bgx[ilx+1], bgx[ilx+0]), fl = wcag_luma_u8(wpx[ilx+2], wpx[ilx+1], wpx[ilx+0]);
            double lr = wcag_luma_u8(bgx[irx+2], bgx[irx+1], bgx[irx+0]), fr = wcag_luma_u8(wpx[irx+2], wpx[irx+1], wpx[irx+0]);
            double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
            double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
            if (crl < min_wcr) min_wcr = crl;
            if (crr < min_wcr) min_wcr = crr;
            for (int c = 0; c < 3; c++) { int d = abs((int)wpx[ilx+c] - (int)wpx[irx+c]); if (d > max_wd) max_wd = d; }
            CHECK(crl >= 4.5 && crr >= 4.5 && max_wd <= 1);
            free(wpx); free(bgx);
          }
          printf("apple_render: dark adaptive 320pt 16pt-stripe sweep min_icon_cr=%.2f min_word_cr=%.2f max_wd=%d\n",
                 min_icr, min_wcr, max_wd);
        }
        // R9-1: 144pt muted 12-char word & R9-2: off-center icon in 56pt-tall capsule
        {
          double ew[5 * MB_INST];
          rect_at(ew, 0, 0, 400, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(ew + MB_INST, 268, 0, 16, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(ew + 2 * MB_INST, 40, 20, 320, 36, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -72);
          ew[2 * MB_INST + 4] = 18.0; ew[2 * MB_INST + 6] = 1.0; ew[2 * MB_INST + 7] = 1.2;
          ew[2 * MB_INST + 11] = 0x67 / 255.0; ew[2 * MB_INST + 12] = 0.6; ew[2 * MB_INST + 13] = 14.0;
          ew[2 * MB_INST + 14] = -1.0; ew[2 * MB_INST + 15] = 1.0;
          ew[2 * MB_INST + 21] = 20.0; ew[2 * MB_INST + 22] = 0.06; ew[2 * MB_INST + 23] = 0.0;
          rect_at(ew + 3 * MB_INST, 139, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          ew[3 * MB_INST + 6] = 63.0; ew[3 * MB_INST + 7] = 0.0;
          ew[3 * MB_INST + 12] = 16.0; ew[3 * MB_INST + 13] = 16.0; ew[3 * MB_INST + 14] = 16.0; ew[3 * MB_INST + 15] = 16.0;
          ew[3 * MB_INST + 21] = 200.0; ew[3 * MB_INST + 22] = 38.0; ew[3 * MB_INST + 23] = 18.0;
          rect_at(ew + 4 * MB_INST, 265, 32, 12, 12, 7, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          ew[4 * MB_INST + 6] = -63.0; ew[4 * MB_INST + 7] = 0.0;
          ew[4 * MB_INST + 12] = 16.0; ew[4 * MB_INST + 13] = 16.0; ew[4 * MB_INST + 14] = 16.0; ew[4 * MB_INST + 15] = 16.0;
          ew[4 * MB_INST + 21] = 200.0; ew[4 * MB_INST + 22] = 38.0; ew[4 * MB_INST + 23] = 18.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ew, 3, 0.08, 0.08, 0.08);
          present_drain();
          int bcw = 0, bch = 0, cw = 0, ch = 0;
          uint8_t *bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(ew, 5, 0.08, 0.08, 0.08);
          present_drain();
          uint8_t *px = read_texture(canvas, &cw, &ch);
          int ilx = (76 * cw + 290) * 4, irx = (76 * cw + 542) * 4;
          double ll = wcag_luma_u8(bgx[ilx+2], bgx[ilx+1], bgx[ilx+0]), fl = wcag_luma_u8(px[ilx+2], px[ilx+1], px[ilx+0]);
          double lr = wcag_luma_u8(bgx[irx+2], bgx[irx+1], bgx[irx+0]), fr = wcag_luma_u8(px[irx+2], px[irx+1], px[irx+0]);
          double crl = ((fl > ll ? fl : ll) + 0.05) / ((fl > ll ? ll : fl) + 0.05);
          double crr = ((fr > lr ? fr : lr) + 0.05) / ((fr > lr ? lr : fr) + 0.05);
          int wd = 0;
          for (int c = 0; c < 3; c++) { int d = abs((int)px[ilx+c] - (int)px[irx+c]); if (d > wd) wd = d; }
          printf("apple_render: dark adaptive 144pt-word left_cr=%.2f right_cr=%.2f diff=%d\n", crl, crr, wd);
          CHECK(wd <= 1 && crl >= 4.5 && crr >= 4.5);
          free(bgx); free(px);

          double oc[4 * MB_INST];
          rect_at(oc, 0, 0, 400, 300, 0, 0.08, 0.08, 0.08, 0);
          rect_at(oc + MB_INST, 188, 20, 24, 12, 0, 1.0, 1.0, 1.0, 0);
          rect_at(oc + 2 * MB_INST, 120, 20, 160, 56, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -73);
          oc[2 * MB_INST + 4] = 28.0; oc[2 * MB_INST + 6] = 1.0; oc[2 * MB_INST + 7] = 1.2;
          oc[2 * MB_INST + 11] = 0x67 / 255.0; oc[2 * MB_INST + 12] = 0.6; oc[2 * MB_INST + 13] = 14.0;
          oc[2 * MB_INST + 14] = -1.0; oc[2 * MB_INST + 15] = 1.0;
          oc[2 * MB_INST + 21] = 20.0; oc[2 * MB_INST + 22] = 0.06; oc[2 * MB_INST + 23] = 0.0;
          rect_at(oc + 3 * MB_INST, 194, 22, 12, 12, 10, 0xA8/255.0, 0xAA/255.0, 0xAE/255.0, 0);
          oc[3 * MB_INST + 4] = 4.0;
          oc[3 * MB_INST + 12] = 0.1; oc[3 * MB_INST + 13] = 0.5; oc[3 * MB_INST + 14] = 0.9; oc[3 * MB_INST + 15] = 0.5;
          oc[3 * MB_INST + 21] = 200.0; oc[3 * MB_INST + 22] = 48.0; oc[3 * MB_INST + 23] = 28.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(oc, 3, 0.08, 0.08, 0.08);
          present_drain();
          bgx = read_texture(canvas, &bcw, &bch);
          glass_forget();
          mb_host_render_dirty(0, 0, 400, 300);
          mb_render_present(oc, 4, 0.08, 0.08, 0.08);
          present_drain();
          px = read_texture(canvas, &cw, &ch);
          int idx = (56 * cw + 400) * 4;
          double gl = wcag_luma_u8(bgx[idx+2], bgx[idx+1], bgx[idx+0]);
          double il = wcag_luma_u8(px[idx+2], px[idx+1], px[idx+0]);
          double cr = ((il > gl ? il : gl) + 0.05) / ((il > gl ? gl : il) + 0.05);
          printf("apple_render: dark adaptive offcenter-56pt icon glass=(%d,%d,%d) icon=(%d,%d,%d) cr=%.2f\n",
                 bgx[idx+2], bgx[idx+1], bgx[idx+0], px[idx+2], px[idx+1], px[idx+0], cr);
          CHECK(cr >= 4.5);
          free(bgx); free(px);
        }
      }
      mb_render_set_size(400, 300, 2);
      glass_forget();
    }

    // Perf-30: (1) Rotated spinner isolation & 60-frame benchmark, (2) 45-deg grazing & far-pivot rotated overlap,
    // (3) unrelated kind==12 vector path segment isolation.
    {
      mb_render_set_size(400, 600, 2);
      glass_free();
      // (1) Rotated spinner 400pt below top progressive blur + liquid glass
      {
        double sp[5 * MB_INST];
        rect_at(sp, 0, 0, 400, 600, 0, 0.94, 0.94, 0.92, 0);
        sp[18] = 400; sp[19] = 600;
        rect_at(sp + 1 * MB_INST, 20, 8, 120, 24, 0, 0.85, 0.20, 0.20, 0);
        sp[1 * MB_INST + 18] = 400; sp[1 * MB_INST + 19] = 600;
        rect_at(sp + 2 * MB_INST, 180, 460, 20, 20, 0, 0.20, 0.45, 0.90, 0);
        sp[2 * MB_INST + 18] = 400; sp[2 * MB_INST + 19] = 600;
        sp[2 * MB_INST + 32] = 0.1;
        sp[2 * MB_INST + 33] = 190.0;
        sp[2 * MB_INST + 34] = 470.0;
        rect_at(sp + 3 * MB_INST, 0, 0, 400, 64, 5, 0.96, 0.96, 0.96, -50);
        sp[3 * MB_INST + 6] = 1.1;
        sp[3 * MB_INST + 7] = 6.0;
        sp[3 * MB_INST + 11] = 0.35;
        sp[3 * MB_INST + 15] = 1.0;
        sp[3 * MB_INST + 18] = 400; sp[3 * MB_INST + 19] = 600;
        sp[3 * MB_INST + 22] = -1.0;
        sp[3 * MB_INST + 54] = 64.0;
        sp[3 * MB_INST + 55] = 24.0;
        rect_at(sp + 4 * MB_INST, 24, 12, 140, 32, 6, 0.99, 0.99, 0.99, -51);
        sp[4 * MB_INST + 4] = 16.0;
        sp[4 * MB_INST + 6] = 1.0;
        sp[4 * MB_INST + 7] = 2.0;
        sp[4 * MB_INST + 11] = 0x67 / 255.0;
        sp[4 * MB_INST + 13] = 8.0;
        sp[4 * MB_INST + 14] = -1.0;
        sp[4 * MB_INST + 15] = 1.0;
        sp[4 * MB_INST + 18] = 400; sp[4 * MB_INST + 19] = 600;
        sp[4 * MB_INST + 21] = 6.0;

        mb_render_set_fixed_dt(1.0 / 60.0);
        glass_forget();
        int b_start = blurs_made;
        int steady_blurs = 0;
        double t0 = CACurrentMediaTime();
        for (int frame = 0; frame < 60; frame++) {
          sp[2 * MB_INST + 32] = 0.1 + frame * 0.105;
          int b_before = blurs_made;
          mb_host_render_dirty(0, 0, 400, 600);
          mb_render_present(sp, 5, 0.94, 0.94, 0.92);
          present_drain();
          if (frame == 0) {
            CHECK(blurs_made == b_before + 2);
          } else {
            steady_blurs += (blurs_made - b_before);
            CHECK(blurs_made == b_before);
          }
        }
        double elapsed_ms = (CACurrentMediaTime() - t0) * 1000.0;
        printf("apple_render: Perf-30 60-frame spinner blurs=%d (frames 2..60=%d) ms=%.2f\n",
               blurs_made - b_start, steady_blurs, elapsed_ms);
        CHECK(steady_blurs == 0);
        CHECK(canvas_as_whole());
        mb_render_set_fixed_dt(0.0);
      }

      // (2) Rotated instance grazing overlap at 45 deg + far-pivot swing into glass capture region
      {
        double rg[3 * MB_INST];
        rect_at(rg, 0, 0, 400, 600, 0, 0.94, 0.94, 0.92, 0);
        rg[18] = 400; rg[19] = 600;
        rect_at(rg + 1 * MB_INST, 80, 80, 40, 40, 0, 0.90, 0.15, 0.15, 0);
        rg[1 * MB_INST + 18] = 400; rg[1 * MB_INST + 19] = 600;
        rg[1 * MB_INST + 32] = 0.0;
        rg[1 * MB_INST + 33] = 100.0;
        rg[1 * MB_INST + 34] = 100.0;
        rect_at(rg + 2 * MB_INST, 40, 20, 120, 40, 5, 0.98, 0.98, 0.98, -52);
        rg[2 * MB_INST + 7] = 4.0;
        rg[2 * MB_INST + 11] = 0.45;
        rg[2 * MB_INST + 18] = 400; rg[2 * MB_INST + 19] = 600;

        glass_forget();
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(rg, 3, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(canvas_as_whole());
        rg[1 * MB_INST + 32] = 0.7853981633974483;
        int b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(rg, 3, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(blurs_made == b0 + 1);
        CHECK(canvas_as_whole());

        // Far-pivot swing
        rg[1 * MB_INST + 0] = 200.0; rg[1 * MB_INST + 1] = 300.0;
        rg[1 * MB_INST + 2] = 30.0; rg[1 * MB_INST + 3] = 30.0;
        rg[1 * MB_INST + 32] = 0.0;
        rg[1 * MB_INST + 33] = 150.0; rg[1 * MB_INST + 34] = 170.0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(rg, 3, 0.94, 0.94, 0.92);
        present_drain();
        rg[1 * MB_INST + 32] = 3.141592653589793;
        b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(rg, 3, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(blurs_made == b0 + 1);
        CHECK(canvas_as_whole());
      }

      // (3) Unrelated kind==12 vector path segment isolation
      {
        double vg[4 * MB_INST];
        rect_at(vg, 0, 0, 400, 600, 0, 0.94, 0.94, 0.92, 0);
        vg[18] = 400; vg[19] = 600;
        rect_at(vg + 1 * MB_INST, 40, 400, 60, 40, 11, 0.10, 0.30, 0.85, 0);
        vg[1 * MB_INST + 12] = 0.0;
        vg[1 * MB_INST + 13] = 1.0;
        vg[1 * MB_INST + 18] = 400; vg[1 * MB_INST + 19] = 600;
        rect_at(vg + 2 * MB_INST, 20, 20, 140, 40, 5, 0.98, 0.98, 0.98, -53);
        vg[2 * MB_INST + 7] = 4.0;
        vg[2 * MB_INST + 11] = 0.45;
        vg[2 * MB_INST + 18] = 400; vg[2 * MB_INST + 19] = 600;
        memset(vg + 3 * MB_INST, 0, MB_INST * sizeof(double));
        vg[3 * MB_INST + 5] = 12;
        vg[3 * MB_INST + 0] = 40; vg[3 * MB_INST + 1] = 400;
        vg[3 * MB_INST + 2] = 100; vg[3 * MB_INST + 3] = 440;

        glass_forget();
        int b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(vg, 4, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(blurs_made == b0 + 1);
        for (int step = 0; step < 3; step++) {
          vg[3 * MB_INST + 2] = 90 + step * 5;
          b0 = blurs_made;
          mb_host_render_dirty(0, 0, 400, 600);
          mb_render_present(vg, 4, 0.94, 0.94, 0.92);
          present_drain();
          CHECK(blurs_made == b0);
          CHECK(canvas_as_whole());
        }

        vg[1 * MB_INST + 1] = 24.0;
        vg[3 * MB_INST + 1] = 24.0; vg[3 * MB_INST + 3] = 56.0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(vg, 4, 0.94, 0.94, 0.92);
        present_drain();
        vg[3 * MB_INST + 2] = 110.0;
        b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(vg, 4, 0.94, 0.94, 0.92);
        present_drain();
        CHECK(blurs_made == b0 + 1);
        CHECK(canvas_as_whole());
      }

      // (4) Perf-31: iOS/macOS VRAM cap macro, multi-dirty-rect single MTLRenderCommandEncoder reuse,
      //     conservative CPU scissor culling, off-rect glass/lens skipping, and byte-for-byte parity.
      {
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
        CHECK(MB_GLASS_CACHE_MAX_BYTES == (size_t)32 * 1024 * 1024);
#else
        CHECK(MB_GLASS_CACHE_MAX_BYTES == (size_t)64 * 1024 * 1024);
#endif
        const int GRID_N = 400;
        const int TOTAL = GRID_N + 8;
        double *sc = (double *)calloc((size_t)TOTAL * MB_INST, sizeof(double));
        for (int i = 0; i < GRID_N; i++) {
          int col = i % 20, row = i / 20;
          double x = 8.0 + col * 19.0;
          double y = 60.0 + row * 23.0;
          rect_at(sc + (size_t)i * MB_INST, x, y, 14.0, 16.0, 0,
                  0.2 + 0.03 * col, 0.25 + 0.03 * row, 0.55, 0);
          sc[(size_t)i * MB_INST + 18] = 400;
          sc[(size_t)i * MB_INST + 19] = 600;
        }
        int idx = GRID_N;
        // Shadow (kind 2)
        rect_at(sc + (size_t)idx * MB_INST, 26, 100, 24, 20, 2, 0.0, 0.0, 0.0, 0);
        sc[(size_t)idx * MB_INST + 7] = 6.0;
        sc[(size_t)idx * MB_INST + 11] = 0.45;
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        // Clipped + outer-clipped rect
        rect_at(sc + (size_t)idx * MB_INST, 290, 430, 60, 50, 0, 0.85, 0.25, 0.15, 0);
        sc[(size_t)idx * MB_INST + 16] = 295; sc[(size_t)idx * MB_INST + 17] = 435;
        sc[(size_t)idx * MB_INST + 18] = 345; sc[(size_t)idx * MB_INST + 19] = 475;
        sc[(size_t)idx * MB_INST + 40] = 300; sc[(size_t)idx * MB_INST + 41] = 440;
        sc[(size_t)idx * MB_INST + 42] = 340; sc[(size_t)idx * MB_INST + 43] = 470;
        sc[(size_t)idx * MB_INST + 44] = 6.0; sc[(size_t)idx * MB_INST + 45] = 6.0;
        sc[(size_t)idx * MB_INST + 46] = 6.0; sc[(size_t)idx * MB_INST + 47] = 6.0;
        idx++;
        // Rotated rect
        rect_at(sc + (size_t)idx * MB_INST, 180, 140, 26, 26, 0, 0.15, 0.80, 0.35, 0);
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        sc[(size_t)idx * MB_INST + 32] = 0.6;
        sc[(size_t)idx * MB_INST + 33] = 193.0;
        sc[(size_t)idx * MB_INST + 34] = 153.0;
        idx++;
        // Glass group 1 at top
        rect_at(sc + (size_t)idx * MB_INST, 20, 10, 360, 40, 5, 0.96, 0.96, 0.96, -71);
        sc[(size_t)idx * MB_INST + 7] = 6.0;
        sc[(size_t)idx * MB_INST + 11] = 0.45;
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        // Glass group 2 at bottom
        rect_at(sc + (size_t)idx * MB_INST, 20, 540, 360, 40, 5, 0.96, 0.96, 0.96, -72);
        sc[(size_t)idx * MB_INST + 7] = 6.0;
        sc[(size_t)idx * MB_INST + 11] = 0.45;
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        // Foreground lens (kind 8) with 2 children
        rect_at(sc + (size_t)idx * MB_INST, 140, 280, 120, 40, 8, 1.0, 1.0, 1.0, 0);
        sc[(size_t)idx * MB_INST + 4] = 12.0;
        sc[(size_t)idx * MB_INST + 7] = 2.0;
        sc[(size_t)idx * MB_INST + 11] = 1.0;
        sc[(size_t)idx * MB_INST + 12] = 2.0;
        sc[(size_t)idx * MB_INST + 14] = 4.0;
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        rect_at(sc + (size_t)idx * MB_INST, 150, 288, 40, 24, 0, 0.90, 0.30, 0.20, 0);
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        rect_at(sc + (size_t)idx * MB_INST, 200, 288, 45, 24, 0, 0.20, 0.45, 0.90, 0);
        sc[(size_t)idx * MB_INST + 18] = 400; sc[(size_t)idx * MB_INST + 19] = 600;
        idx++;
        CHECK(idx == TOTAL);

        glass_forget();
        mb_host_render_dirty(0, 0, 400, 600);
        mb_render_present(sc, TOTAL, 0.92, 0.93, 0.95);
        present_drain();
        CHECK(canvas_as_whole());

        // Case A: 4 disjoint small dirty rects away from both glass groups and the lens ->
        // must reuse ONE MTLRenderCommandEncoder, trigger 0 blurs, cull off-rect instances, and match whole byte-for-byte.
        slots_invalidate();
        sc[21 * MB_INST + 8] = 0.95;
        sc[88 * MB_INST + 9] = 0.90;
        sc[310 * MB_INST + 10] = 0.10;
        sc[(GRID_N + 1) * MB_INST + 9] = 0.85;
        int p0 = encode_passes_made, b0 = blurs_made, inst0 = encode_inst_submitted;
        mb_host_render_dirty(8, 78, 56, 52);
        mb_host_render_dirty(155, 130, 60, 50);
        mb_host_render_dirty(190, 398, 30, 30);
        mb_host_render_dirty(292, 432, 56, 46);
        mb_render_present(sc, TOTAL, 0.92, 0.93, 0.95);
        present_drain();
        int passes_d = encode_passes_made - p0;
        int blurs_d = blurs_made - b0;
        int inst_d = encode_inst_submitted - inst0;
        printf("apple_render: Perf-31 4-rect partial: encoders=%d blurs=%d inst_submitted=%d (unculled=%d)\n",
               passes_d, blurs_d, inst_d, 4 * TOTAL);
        CHECK(passes_d == 1);
        CHECK(blurs_d == 0);
        CHECK(inst_d < TOTAL);
        CHECK(canvas_as_whole());

        // Case B: 2 dirty rects covering top glass + kind 8 lens; bottom glass skipped.
        slots_invalidate();
        sc[(GRID_N + 6) * MB_INST + 8] = 0.15;
        sc[0 * MB_INST + 8] = 0.95;
        b0 = blurs_made;
        mb_host_render_dirty(0, 0, 400, 80);
        mb_host_render_dirty(120, 260, 160, 80);
        mb_render_present(sc, TOTAL, 0.92, 0.93, 0.95);
        present_drain();
        CHECK(blurs_made - b0 == 1);
        CHECK(canvas_as_whole());

        free(sc);
      }

      mb_render_set_size(400, 300, 2);
      glass_free();
    }

    // A group kept by the host (groups.h) drawn out by a header, straight into the floats: each instance moved in
    // doubles, then made a float, as the app's own instance moved there would be.
    double kept[MB_INST];
    memcpy(kept, inst, sizeof kept);
    kept[0] = 10.1;
    kept[1] = 20.3;
    double kept_moves[1] = {0};
    mb_host_group_set(5, kept, kept_moves, 1);
    double head[MB_INST] = {0};
    head[0] = 0.2;
    head[1] = -7.7;
    head[5] = MB_GROUP_HEAD;
    head[12] = 5;
    head[13] = 0;
    head[14] = 1;
    mb_render_present(head, 1, 0.1, 0.2, 0.3);
    CHECK(shown_ok == 1);
    CHECK(last_count == 1);
    CHECK(last_inst[0] == (float)(10.1 + 0.2));
    CHECK(last_inst[1] == (float)(20.3 + -7.7));
    CHECK(last_inst[2] == 100.0f);
    CHECK(last_inst[5] == 0.0f);
    // the same frame again is the one on the screen: nothing drawn
    float shown_first = last_inst[0];
    CHECK(same_as_shown(last_inst, 1, 0.1, 0.2, 0.3) == 1);
    mb_render_present(head, 1, 0.1, 0.2, 0.3);
    CHECK(last_inst[0] == shown_first);
    mb_host_group_drop(5);
    free(last_inst);
    last_inst = NULL;
    last_cap = 0;

    // P0 optics fix numerical smoke vectors (calibrated to native iOS 27.0 Regular Glass):
    // 0: Dark Regular (0x20202067) over #000000 -> (42,42,42)
    // 1: Dark Regular (0x20202067) over #1B1C1F -> (58,59,62)
    // 2: Dark Adaptive (0x20202067, adaptive=1) over #FFFFFF -> (93,93,93)
    // 3: Light Regular (0xFDFCFD67) over #0088FF -> (53,160,255), HSV S >= 0.75
    // 4: Pure Clear (0xFFFFFF00, regMix=0) over (0,255,64) -> (0,255,64)
    {
      struct {
        const char *name;
        double bg_r, bg_g, bg_b;
        double t_r, t_g, t_b, t_a;
        double blur, adaptive;
        int exp_r, exp_g, exp_b, tol;
      } p0_cases[5] = {
        {"dark_black",    0.0, 0.0, 0.0,                      32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0,  0.0,  34,  34,  34, 3},
        {"dark_1b1c1f",   27.0/255.0, 28.0/255.0, 31.0/255.0, 32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0,  0.0,  58,  59,  62, 3},
        {"dark_ad_white", 1.0, 1.0, 1.0,                      32.0/255.0, 32.0/255.0, 32.0/255.0, 0x67/255.0, 2.0, -1.0, 174, 174, 174, 4},
        {"light_blue",    0.0, 136.0/255.0, 1.0,              253.0/255.0, 252.0/255.0, 253.0/255.0, 0x67/255.0, 2.0, 0.0, 88, 205, 255, 4},
        {"pure_clear",    0.0, 1.0, 64.0/255.0,               1.0, 1.0, 1.0, 0.0,                              0.0,  0.0,  0, 255,  64, 1},
      };
      double p0[2 * MB_INST];
      for (int ci = 0; ci < 5; ci++) {
        rect_at(p0, 0, 0, 400, 300, 0, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b, 0);
        rect_at(p0 + MB_INST, 100, 80, 200, 120, 6, p0_cases[ci].t_r, p0_cases[ci].t_g, p0_cases[ci].t_b, -30 - ci);
        p0[MB_INST + 4] = 20.0;
        p0[MB_INST + 6] = 1.0;
        p0[MB_INST + 7] = p0_cases[ci].blur;
        p0[MB_INST + 11] = p0_cases[ci].t_a;
        p0[MB_INST + 12] = 0.0;
        p0[MB_INST + 13] = 4.0;
        p0[MB_INST + 14] = p0_cases[ci].adaptive;
        p0[MB_INST + 15] = 1.0;
        p0[MB_INST + 21] = 0.0;
        p0[MB_INST + 22] = 0.0;
        p0[MB_INST + 23] = 0.0;
        glass_forget();
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(p0, 2, p0_cases[ci].bg_r, p0_cases[ci].bg_g, p0_cases[ci].bg_b);
        present_drain();
        int aw = 0, ah = 0;
        uint8_t *px = read_texture(canvas, &aw, &ah);
        // BGRA8 at center (200, 140) -> (400, 280) at 2x
        uint8_t *c = px + (280 * aw + 400) * 4;
        int r = c[2], g = c[1], b = c[0];
        printf("apple_render: p0_%s rgb=(%d,%d,%d) exp=(%d,%d,%d)\n",
               p0_cases[ci].name, r, g, b, p0_cases[ci].exp_r, p0_cases[ci].exp_g, p0_cases[ci].exp_b);
        CHECK(abs(r - p0_cases[ci].exp_r) <= p0_cases[ci].tol);
        CHECK(abs(g - p0_cases[ci].exp_g) <= p0_cases[ci].tol);
        CHECK(abs(b - p0_cases[ci].exp_b) <= p0_cases[ci].tol);
        if (ci == 3) {
          double mx = fmax(fmax(r, g), b);
          double mn = fmin(fmin(r, g), b);
          double hsv_s = mx > 0.0 ? (mx - mn) / mx : 0.0;
          printf("apple_render: p0_light_blue hsv_s=%.3f\n", hsv_s);
          CHECK(hsv_s >= 0.62);
        }
        free(px);
      }

      // Commit 2 V8/V9 2D Multi-Pixel ROI Gates (Slider, Switch ON/OFF, 3x TIR rows, 2x phase-shifted TIR, Light Segmented Prism):
      {
        int VW = 160, VH = 80;
        #define A_PX(buf, aw, xpx, ypx) ((buf) + ((ypx) * (aw) + (xpx)) * 4)
        mb_render_set_size(VW, VH, 3);
        // --- V8a: Slider Dark & Light @ 3x ---
        for (int is_light = 0; is_light <= 1; is_light++) {
          double bg = is_light ? 1.0 : 28.0 / 255.0;
          double bg_b = is_light ? 1.0 : 30.0 / 255.0;
          double sl[4 * MB_INST];
          rect_at(sl, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
          rect_at(sl + MB_INST, 10, 37, 70, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
          rect_at(sl + 2 * MB_INST, 80, 37, 70, 6, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
          rect_at(sl + 3 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -50 - is_light);
          sl[3 * MB_INST + 4] = 19.0; sl[3 * MB_INST + 6] = 1.0; sl[3 * MB_INST + 7] = -16.0;
          sl[3 * MB_INST + 11] = 0.0; sl[3 * MB_INST + 12] = 1.0; sl[3 * MB_INST + 13] = 9.0;
          sl[3 * MB_INST + 15] = 1.0; sl[3 * MB_INST + 21] = 9.0; sl[3 * MB_INST + 22] = 0.0; sl[3 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sl, 4, bg, bg, bg_b);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          double max_bh = 0.0, peak_dx = 0.0, h_55 = 0.0;
          double max_gh = 0.0, grey_peak_dx = 0.0, grey_h55 = 0.0;
          for (int i = 0; i <= 18; i++) {
            int x_l = 51 * 3 + i;
            int cnt = 0;
            for (int ypx = 21 * 3; ypx < 59 * 3; ypx++) {
              uint8_t *c = A_PX(px, aw, x_l, ypx);
              if ((int)c[0] - (int)c[2] > 100) cnt++;  // BGRA: B=c[0], R=c[2]
            }
            double hpt = cnt / 3.0;
            double dx_l = (i + 0.5) / 3.0;
            if (hpt > max_bh) { max_bh = hpt; peak_dx = dx_l; }
            if (i == 16) h_55 = hpt;
          }
          uint8_t *bg_ref = A_PX(px, aw, 80 * 3, 25 * 3);
          double ref_y = 0.2126 * bg_ref[2] + 0.7152 * bg_ref[1] + 0.0722 * bg_ref[0];
          for (int i = 0; i <= 18; i++) {
            int x_r = 109 * 3 - 1 - i;
            int cnt = 0;
            for (int ypx = 33 * 3; ypx < 47 * 3; ypx++) {
              uint8_t *c = A_PX(px, aw, x_r, ypx);
              double cy = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
              if (is_light ? (cy < ref_y - 70.0) : (cy > ref_y + 20.0)) cnt++;
            }
            double hpt = cnt / 3.0;
            double dx_r = (i + 0.5) / 3.0;
            if (hpt > max_gh) { max_gh = hpt; grey_peak_dx = dx_r; }
            if (i == 16) grey_h55 = hpt;
          }
          uint8_t *c_l = A_PX(px, aw, (int)(79.3 * 3), 40 * 3);
          uint8_t *c_r = A_PX(px, aw, (int)(80.7 * 3), 40 * 3);
          uint8_t *c_top = A_PX(px, aw, 60 * 3, 25 * 3);
          uint8_t *c_bot = A_PX(px, aw, 60 * 3, 55 * 3);
          // 5-point 3D thickness profile at x = 80 (dy = 0, 0.67, 2.0, 9.0, 24.0pt from y = 21)
          uint8_t *t0 = A_PX(px, aw, 80 * 3, 21 * 3);
          uint8_t *t1 = A_PX(px, aw, 80 * 3, 21 * 3 + 2);
          uint8_t *t2 = A_PX(px, aw, 80 * 3, 23 * 3);
          uint8_t *t9 = A_PX(px, aw, 80 * 3, 30 * 3);
          uint8_t *t24 = A_PX(px, aw, 80 * 3, 45 * 3);
          double y0 = 0.2126 * t0[2] + 0.7152 * t0[1] + 0.0722 * t0[0];
          double y1 = 0.2126 * t1[2] + 0.7152 * t1[1] + 0.0722 * t1[0];
          double y2 = 0.2126 * t2[2] + 0.7152 * t2[1] + 0.0722 * t2[0];
          double y9 = 0.2126 * t9[2] + 0.7152 * t9[1] + 0.0722 * t9[0];
          double y24 = 0.2126 * t24[2] + 0.7152 * t24[1] + 0.0722 * t24[0];
          printf("apple_render: v8_slider(%s) blue_peak=%.2f@dx=%.2f blue_h55=%.2f grey_peak=%.2f@dx=%.2f grey_h55=%.2f prof5=(%.0f,%.0f,%.0f,%.0f,%.0f)\n",
                 is_light ? "light" : "dark", max_bh, peak_dx, h_55, max_gh, grey_peak_dx, grey_h55, y0, y1, y2, y9, y24);
          CHECK(max_bh >= 9.5 && max_bh <= 12.5);
          CHECK(peak_dx >= 0.33 && peak_dx <= 1.50);
          CHECK(h_55 >= 5.6 && h_55 <= 6.4);
          CHECK(max_gh >= 9.5 && max_gh <= 12.5);
          CHECK(grey_peak_dx >= 0.33 && grey_peak_dx <= 1.50);
          CHECK(grey_h55 >= 5.6 && grey_h55 <= 6.4);
          CHECK((int)c_l[0] - (int)c_l[2] > 100 && (int)c_r[0] - (int)c_r[2] < 20);
          CHECK((int)c_top[0] - (int)c_top[2] < 20 && (int)c_bot[0] - (int)c_bot[2] < 20);
          CHECK(y1 > y0 && y2 > y9 && y9 < y24);
          free(px);
        }
        // --- V8a2: Horizontal-stripe vertical monotonicity ---
        {
          double st[42 * MB_INST];
          rect_at(st, 0, 0, VW, VH, 0, 0.0, 0.0, 0.0, 0);
          for (int i = 0; i < 40; i++) {
            double v = fmin(1.0, fmax(0.0, (i - 12.0) / 16.0));
            rect_at(st + (i + 1) * MB_INST, 0, 20 + i, VW, 1, 0, 1.0 - v, 0.0, v, 0);
          }
          rect_at(st + 41 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -52);
          st[41 * MB_INST + 4] = 19.0; st[41 * MB_INST + 6] = 1.0; st[41 * MB_INST + 7] = -16.0;
          st[41 * MB_INST + 11] = 0.0; st[41 * MB_INST + 12] = 1.0; st[41 * MB_INST + 13] = 9.0;
          st[41 * MB_INST + 15] = 1.0; st[41 * MB_INST + 21] = 9.0; st[41 * MB_INST + 22] = 0.0; st[41 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(st, 42, 0.0, 0.0, 0.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          int xpx = (int)(51.85 * 3);
          int prev = -1000;
          int mono_ok = 1;
          for (int ypx = 36 * 3; ypx <= 44 * 3; ypx++) {
            uint8_t *c = A_PX(px, aw, xpx, ypx);
            int cur = (int)c[0] - (int)c[2];  // BGRA B - R: invariant to achromatic specular rim
            if (prev > -999 && cur < prev - 6) mono_ok = 0;
            prev = cur;
          }
          CHECK(mono_ok);
          free(px);
        }
        // --- V8b: 124x48pt dropRole=0 magnifier unaffected + Role 0 real zoom (1.18) contact-edge push ---
        {
          double mg[3 * MB_INST];
          rect_at(mg, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(mg + MB_INST, 0, 37, VW, 6, 0, 0.0, 136.0 / 255.0, 1.0, 0);
          rect_at(mg + 2 * MB_INST, 18, 16, 124, 48, 6, 1.0, 1.0, 1.0, -53);
          mg[2 * MB_INST + 4] = 24.0; mg[2 * MB_INST + 6] = 1.0; mg[2 * MB_INST + 7] = 0.0;
          mg[2 * MB_INST + 11] = 0.0; mg[2 * MB_INST + 12] = 1.0; mg[2 * MB_INST + 13] = 8.0;
          mg[2 * MB_INST + 15] = 1.0; mg[2 * MB_INST + 21] = 3.0; mg[2 * MB_INST + 22] = 0.0; mg[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(mg, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          int cnt = 0;
          for (int ypx = 16 * 3; ypx < 64 * 3; ypx++) {
            uint8_t *c = A_PX(px, aw, 19 * 3, ypx);
            if ((int)c[0] - (int)c[2] > 100) cnt++;
          }
          printf("apple_render: v8_magnifier_role0 h(1.0)=%.2f\n", cnt / 3.0);
          CHECK(cnt / 3.0 < 7.0);
          free(px);
        }
        {
          // Role 0 real zoom (1.18 -> slot 7 = -0.18) contact-edge +0.85pt outward push:
          // at p.x=51.17, zoom maps sampleBase.x to 80+(51.17-80)/1.18=55.57; +0.85pt outward shifts to 54.72 (<55.2 -> green),
          // whereas missing outward push stays >=55.57 (red).
          double zm[3 * MB_INST];
          rect_at(zm, 0, 0, VW, VH, 0, 1.0, 0.0, 0.0, 0);
          rect_at(zm + MB_INST, 0, 0, 55.2, VH, 0, 0.0, 1.0, 0.0, 0);
          rect_at(zm + 2 * MB_INST, 51, 21, 58, 38, 6, 1.0, 1.0, 1.0, -59);
          zm[2 * MB_INST + 4] = 19.0; zm[2 * MB_INST + 6] = 1.0; zm[2 * MB_INST + 7] = -0.18;
          zm[2 * MB_INST + 11] = 0.0; zm[2 * MB_INST + 12] = 1.0; zm[2 * MB_INST + 13] = 8.0;
          zm[2 * MB_INST + 15] = 1.0; zm[2 * MB_INST + 21] = 8.0; zm[2 * MB_INST + 22] = 0.0; zm[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(zm, 3, 1.0, 0.0, 0.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *edge = A_PX(px, aw, 51 * 3, 40 * 3);
          printf("apple_render: v8_role0_zoom118_contact rgb=(%d,%d,%d)\n", edge[2], edge[1], edge[0]);
          CHECK((int)edge[1] > (int)edge[2] + 40);
          free(px);
        }
        // --- V9a: Switch ON @ 3x ---
        {
          double sw[3 * MB_INST];
          rect_at(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(sw + MB_INST, 40, 26, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
          sw[MB_INST + 4] = 14.0;
          rect_at(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -54);
          sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
          sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
          sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *r0 = A_PX(px, aw, 80 * 3, 21 * 3 + 0);
          uint8_t *r1 = A_PX(px, aw, 80 * 3, 21 * 3 + 1);
          uint8_t *r2 = A_PX(px, aw, 80 * 3, 21 * 3 + 2);
          int gr0 = (int)r0[1] - (int)r0[2];
          int gr1 = (int)r1[1] - (int)r1[2];
          int gr2 = (int)r2[1] - (int)r2[2];
          int core_px = 0, first_core_y = -1;
          for (int ypx = 21 * 3 + 2; ypx < 59 * 3; ypx++) {
            uint8_t *c = A_PX(px, aw, 80 * 3, ypx);
            if ((int)c[1] - (int)c[2] > 60) {
              if (first_core_y < 0) first_core_y = ypx;
              core_px++;
            }
          }
          double moat_top_pt = first_core_y >= 0 ? (first_core_y - (21 * 3 + 2)) / 3.0 : 0.0;
          uint8_t *tip = A_PX(px, aw, (int)(111.5 * 3), 40 * 3);
          int tip_gr = (int)tip[1] - (int)tip[2];
          printf("apple_render: v9_switch_on_3x tir=(%d,%d,%d) core=%.2f moat_top=%.2f tip_gr=%d\n",
                 gr0, gr1, gr2, core_px / 3.0, moat_top_pt, tip_gr);
          CHECK(gr0 < 15 && gr1 > 60 && gr2 < 15);
          CHECK(core_px / 3.0 >= 20.0 && core_px / 3.0 <= 22.5);
          CHECK(moat_top_pt >= 6.5);
          CHECK(tip_gr < 15);
          free(px);
        }
        // --- V9b: Switch OFF @ 3x + right-cap inward horizontal profile (distinguishes dropDisp=0 from paraxialDisp) ---
        {
          double sw[4 * MB_INST];
          rect_at(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(sw + MB_INST, 40, 26, 63, 28, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
          sw[MB_INST + 4] = 14.0;
          // Blue vertical probe bar at x=[85, 87] inside track: dropDisp=0 leaves x=89.0 neutral; residual paraxialDisp pulls blue into x=89.0.
          rect_at(sw + 2 * MB_INST, 85.0, 26.0, 2.0, 28.0, 0, 0.0, 136.0 / 255.0, 1.0, 0);
          rect_at(sw + 3 * MB_INST, 30.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -55);
          sw[3 * MB_INST + 4] = 19.2; sw[3 * MB_INST + 6] = 1.0; sw[3 * MB_INST + 7] = -32.0;
          sw[3 * MB_INST + 11] = 0.0; sw[3 * MB_INST + 12] = 1.0; sw[3 * MB_INST + 13] = 9.0;
          sw[3 * MB_INST + 15] = 1.0; sw[3 * MB_INST + 21] = 9.0; sw[3 * MB_INST + 22] = 0.0; sw[3 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sw, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *core_c = A_PX(px, aw, 60 * 3, 40 * 3);
          uint8_t *moat_c = A_PX(px, aw, 60 * 3, 25 * 3);
          uint8_t *h0 = A_PX(px, aw, 60 * 3, 21 * 3);
          uint8_t *rm = A_PX(px, aw, 60 * 3, 21 * 3 + 2);
          uint8_t *rcap = A_PX(px, aw, (int)(88.6 * 3), 40 * 3);
          uint8_t *rtir = A_PX(px, aw, (int)(89.3 * 3), 40 * 3);
          int rcap_br = (int)rcap[0] - (int)rcap[2];
          int rtir_br = (int)rtir[0] - (int)rtir[2];
          printf("apple_render: v9_switch_off_3x core=%d moat=%d rim=%d h0=%d rcap_br=%d rtir_br=%d\n",
                 core_c[2], moat_c[2], rm[2], h0[2], rcap_br, rtir_br);
          CHECK(core_c[2] > moat_c[2] + 15 && rm[2] > h0[2]);
          CHECK(rcap_br < 20 && rtir_br > 80);
          free(px);
        }
        // --- V9b2: Switch half-press p = 0.5 / 0.6 / 1.0 pinch displacement on 2D color grid ---
        {
          double ps[3] = { 0.5, 0.6, 1.0 };
          int red_rows[3] = { 0, 0, 0 };
          for (int pi = 0; pi < 3; pi++) {
            double p = ps[pi];
            double sw[3 * MB_INST];
            rect_at(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
            // Bright red horizontal band at y=[20, 27]: outward pinch at y>=27 pulls red downward into the capsule.
            rect_at(sw + MB_INST, 40, 20, 80, 7, 0, 1.0, 0.0, 0.0, 0);
            rect_at(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -60 - pi);
            sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
            sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0 * p; sw[2 * MB_INST + 13] = 9.0 * p;
            sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0 * p; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
            glass_forget();
            mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
            present_drain();
            int aw = 0, ah = 0;
            uint8_t *px = read_texture(canvas, &aw, &ah);
            for (int ypx = 27 * 3; ypx < 38 * 3; ypx++) {
              uint8_t *c = A_PX(px, aw, 80 * 3, ypx);
              if ((int)c[2] - (int)c[0] > 80) red_rows[pi]++;
            }
            free(px);
          }
          printf("apple_render: v9_switch_half_press red_shift_px=(p0.5:%d, p0.6:%d, p1.0:%d)\n",
                 red_rows[0], red_rows[1], red_rows[2]);
          CHECK(red_rows[0] >= 4 && red_rows[1] >= red_rows[0] && red_rows[2] > red_rows[1]);
        }
        // --- V9c: Light Segmented Prism @ 3x (top/bot cyan, left/right amber, dark-stroke text ROI chroma-0 invariance) ---
        {
          double sg[4 * MB_INST];
          rect_at(sg, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
          rect_at(sg + MB_INST, 60.0, 34.0, 4.0, 12.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
          rect_at(sg + 2 * MB_INST, 78.0, 36.0, 22.0, 3.0, 0, 20.0 / 255.0, 20.0 / 255.0, 20.0 / 255.0, 0);
          rect_at(sg + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -56);
          sg[3 * MB_INST + 4] = 22.5; sg[3 * MB_INST + 6] = 1.0; sg[3 * MB_INST + 7] = -48.0;
          sg[3 * MB_INST + 11] = 0.0; sg[3 * MB_INST + 12] = 1.0; sg[3 * MB_INST + 13] = 9.0;
          sg[3 * MB_INST + 15] = 1.0; sg[3 * MB_INST + 21] = 9.0; sg[3 * MB_INST + 22] = 0.04; sg[3 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sg, 4, 1.0, 1.0, 1.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *top = A_PX(px, aw, 80 * 3, (int)(18.4 * 3));
          uint8_t *bot = A_PX(px, aw, 80 * 3, (int)(61.6 * 3));
          uint8_t *lft = A_PX(px, aw, (int)(25.9 * 3), 40 * 3);
          uint8_t *rgt = A_PX(px, aw, (int)(134.1 * 3), 40 * 3);
          printf("apple_render: v9_seg_light top B-R=%d bot B-R=%d lft R-B=%d rgt R-B=%d\n",
                 (int)top[0] - (int)top[2], (int)bot[0] - (int)bot[2],
                 (int)lft[2] - (int)lft[0], (int)rgt[2] - (int)rgt[0]);
          CHECK((int)top[0] - (int)top[2] >= 10);
          CHECK((int)bot[0] - (int)bot[2] >= 10);
          CHECK((int)lft[2] - (int)lft[0] >= 20);
          CHECK((int)rgt[2] - (int)rgt[0] >= 20);
          sg[3 * MB_INST + 20] = -561;
          sg[3 * MB_INST + 22] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sg, 4, 1.0, 1.0, 1.0);
          present_drain();
          int aw0 = 0, ah0 = 0;
          uint8_t *px0 = read_texture(canvas, &aw0, &ah0);
          int text_max_diff = 0;
          for (int py = 32 * 3; py <= 48 * 3; py++) {
            for (int px_i = 55 * 3; px_i <= 105 * 3; px_i++) {
              uint8_t *a = A_PX(px, aw, px_i, py);
              uint8_t *b = A_PX(px0, aw0, px_i, py);
              for (int ch = 0; ch < 3; ch++) {
                int df = abs((int)a[ch] - (int)b[ch]);
                if (df > text_max_diff) text_max_diff = df;
              }
            }
          }
          printf("apple_render: v9_seg_text_roi_diff=%d\n", text_max_diff);
          CHECK(text_max_diff == 0);
          // Role 3 interior 1.00x vertical text scale (12pt = 36px@3x dark stroke, no ~20% compression)
          int seg_stroke_span = 0;
          for (int py = 30 * 3; py <= 50 * 3; py++) {
            uint8_t *sc = A_PX(px, aw, 62 * 3, py);
            double sl = 0.2126 * sc[2] + 0.7152 * sc[1] + 0.0722 * sc[0];
            if (sl < 160.0) seg_stroke_span++;
          }
          // Role 3 track pinch (+3.0pt outer grey track pulled white at y=25.5pt, grey at y=29.0pt)
          double tp[3 * MB_INST];
          rect_at(tp, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
          rect_at(tp + MB_INST, 10.0, 24.0, 140.0, 32.0, 0, 190.0 / 255.0, 190.0 / 255.0, 190.0 / 255.0, 0);
          rect_at(tp + 2 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -5611);
          tp[2 * MB_INST + 4] = 22.5; tp[2 * MB_INST + 6] = 1.0; tp[2 * MB_INST + 7] = -48.0;
          tp[2 * MB_INST + 11] = 0.0; tp[2 * MB_INST + 12] = 1.0; tp[2 * MB_INST + 13] = 9.0;
          tp[2 * MB_INST + 15] = 1.0; tp[2 * MB_INST + 21] = 9.0; tp[2 * MB_INST + 22] = 0.04; tp[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(tp, 3, 1.0, 1.0, 1.0);
          present_drain();
          int awt = 0, aht = 0;
          uint8_t *pxt = read_texture(canvas, &awt, &aht);
          uint8_t *po = A_PX(pxt, awt, 80 * 3, (int)(25.5 * 3));
          uint8_t *pi = A_PX(pxt, awt, 80 * 3, (int)(29.0 * 3));
          double pinch_out_L = 0.2126 * po[2] + 0.7152 * po[1] + 0.0722 * po[0];
          double pinch_in_L = 0.2126 * pi[2] + 0.7152 * pi[1] + 0.0722 * pi[0];
          printf("apple_render: v9_seg_scale stroke_span=%dpx pinch_out_L=%.1f pinch_in_L=%.1f\n",
                 seg_stroke_span, pinch_out_L, pinch_in_L);
          CHECK(seg_stroke_span >= 35 && seg_stroke_span <= 37);
          CHECK(pinch_out_L > 240.0 && pinch_in_L < 215.0);
          free(pxt);
          free(px);
          free(px0);
        }
        // --- V9e: Switch uniform green center + blue-track swap + OFF r9->r4.5 + 5-level press ---
        {
          double sg[2 * MB_INST];
          rect_at(sg, 0, 0, VW, VH, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
          rect_at(sg + MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -562);
          sg[MB_INST + 4] = 19.2; sg[MB_INST + 6] = 1.0; sg[MB_INST + 7] = -32.0;
          sg[MB_INST + 11] = 0.0; sg[MB_INST + 12] = 1.0; sg[MB_INST + 13] = 9.0;
          sg[MB_INST + 15] = 1.0; sg[MB_INST + 21] = 9.0; sg[MB_INST + 22] = 0.0; sg[MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sg, 2, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *c = A_PX(px, aw, (int)lround(82.5 * 3), (int)lround(40.2 * 3));
          printf("apple_render: v9_switch_green_ctr rgb=(%d,%d,%d) exp=(57,218,97)\n", c[2], c[1], c[0]);
          CHECK(abs((int)c[2] - 57) <= 2 && abs((int)c[1] - 218) <= 2 && abs((int)c[0] - 97) <= 2);
          free(px);

          // Blue track swap
          double sb[3 * MB_INST];
          rect_at(sb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(sb + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 0.0, 122.0 / 255.0, 1.0, 0);
          sb[MB_INST + 4] = 14.0;
          sb[MB_INST + 36] = 14.0; sb[MB_INST + 37] = 14.0; sb[MB_INST + 38] = 14.0; sb[MB_INST + 39] = 14.0;
          rect_at(sb + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5621);
          sb[2 * MB_INST + 4] = 19.2; sb[2 * MB_INST + 6] = 1.0; sb[2 * MB_INST + 7] = -32.0;
          sb[2 * MB_INST + 11] = 0.0; sb[2 * MB_INST + 12] = 1.0; sb[2 * MB_INST + 13] = 9.0;
          sb[2 * MB_INST + 15] = 1.0; sb[2 * MB_INST + 21] = 9.0; sb[2 * MB_INST + 22] = 0.0; sb[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sb, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          uint8_t *pxb = read_texture(canvas, &aw, &ah);
          uint8_t *cb = A_PX(pxb, aw, 80 * 3, 21 * 3 + 1);
          printf("apple_render: v9_switch_blue_caustic rgb=(%d,%d,%d) B-R=%d\n", cb[2], cb[1], cb[0], (int)cb[0] - (int)cb[2]);
          CHECK((int)cb[0] - (int)cb[2] >= 100 && cb[0] > cb[1]);
          free(pxb);

          // OFF fixed press r=9.0 vs r=4.5 narrows neutral moat
          int off_moat[2] = {0, 0};
          double refs[2] = {9.0, 4.5};
          for (int ri = 0; ri < 2; ri++) {
            double so[3 * MB_INST];
            rect_at(so, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
            rect_at(so + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 120.0 / 255.0, 120.0 / 255.0, 128.0 / 255.0, 0);
            so[MB_INST + 4] = 14.0;
            so[MB_INST + 36] = 14.0; so[MB_INST + 37] = 14.0; so[MB_INST + 38] = 14.0; so[MB_INST + 39] = 14.0;
            rect_at(so + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -5622 - ri);
            so[2 * MB_INST + 4] = 19.2; so[2 * MB_INST + 6] = 1.0; so[2 * MB_INST + 7] = -32.0;
            so[2 * MB_INST + 11] = 0.0; so[2 * MB_INST + 12] = 1.0; so[2 * MB_INST + 13] = 9.0;
            so[2 * MB_INST + 15] = 1.0; so[2 * MB_INST + 21] = refs[ri]; so[2 * MB_INST + 22] = 0.0; so[2 * MB_INST + 23] = 0.0;
            glass_forget();
            mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(so, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
            present_drain();
            uint8_t *pxo = read_texture(canvas, &aw, &ah);
            int best = 0, cur = 0;
            for (int py = 21 * 3 + 2; py < 40 * 3; py++) {
              uint8_t *c0 = A_PX(pxo, aw, 80 * 3, py);
              if (c0[2] < 95) { cur++; if (cur > best) best = cur; } else cur = 0;
            }
            off_moat[ri] = best;
            free(pxo);
          }
          printf("apple_render: v9_switch_off_moat r9=%dpx r4.5=%dpx\n", off_moat[0], off_moat[1]);
          CHECK(off_moat[0] > off_moat[1] && off_moat[1] >= 1);

          // 5-level white-cap + glass press monotonic visible delta area vs p=0 rest (synced with liquid_toggle.mbt)
          double ps[5] = {0.0, 0.25, 0.50, 0.75, 1.0};
          int areas[5] = {0, 0, 0, 0, 0};
          uint8_t *px_rest = NULL;
          int aw_r = 0, ah_r = 0;
          for (int pi = 0; pi < 5; pi++) {
            double p = ps[pi];
            double sc5[4 * MB_INST];
            rect_at(sc5, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
            rect_at(sc5 + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
            sc5[MB_INST + 4] = 14.0;
            sc5[MB_INST + 36] = 14.0; sc5[MB_INST + 37] = 14.0; sc5[MB_INST + 38] = 14.0; sc5[MB_INST + 39] = 14.0;
            double cw = 37.0 * (1.0 + 0.60 * p), ch = 24.0 * (1.0 + 0.60 * p);
            double cx0 = 82.5 - cw * 0.5, cy0 = 40.0 - ch * 0.5;
            double cap_a = 1.0 - 1.8 * p;
            if (cap_a < 0.0) cap_a = 0.0;
            if (cap_a > 1.0) cap_a = 1.0;
            rect_at(sc5 + 2 * MB_INST, cx0, cy0, cw, ch, 0, 1.0, 1.0, 1.0, 0);
            sc5[2 * MB_INST + 4] = ch * 0.5; sc5[2 * MB_INST + 11] = cap_a;
            sc5[2 * MB_INST + 36] = ch * 0.5; sc5[2 * MB_INST + 37] = ch * 0.5;
            sc5[2 * MB_INST + 38] = ch * 0.5; sc5[2 * MB_INST + 39] = ch * 0.5;
            int ninst = 3;
            if (p > 0.001) {
              rect_at(sc5 + 3 * MB_INST, cx0, cy0, cw, ch, 6, 1.0, 1.0, 1.0, -5625 - pi);
              sc5[3 * MB_INST + 4] = ch * 0.5; sc5[3 * MB_INST + 6] = 1.0; sc5[3 * MB_INST + 7] = -32.0;
              sc5[3 * MB_INST + 11] = 0.0; sc5[3 * MB_INST + 12] = p; sc5[3 * MB_INST + 13] = 9.0 * p;
              sc5[3 * MB_INST + 15] = p; sc5[3 * MB_INST + 21] = 9.0 * p; sc5[3 * MB_INST + 22] = 0.0; sc5[3 * MB_INST + 23] = 0.0;
              ninst = 4;
            }
            glass_forget();
            mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(sc5, ninst, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
            present_drain();
            uint8_t *px5 = read_texture(canvas, &aw, &ah);
            if (pi == 0) {
              px_rest = px5; aw_r = aw; ah_r = ah; (void)ah_r;
              areas[0] = 0;
            } else {
              int cnt = 0;
              for (int py = 21 * 3; py <= 59 * 3; py += 2) {
                for (int px_i = 53 * 3; px_i <= 112 * 3; px_i += 2) {
                  uint8_t *c0 = A_PX(px5, aw, px_i, py);
                  uint8_t *r0 = A_PX(px_rest, aw_r, px_i, py);
                  int d = abs((int)c0[0] - (int)r0[0]) + abs((int)c0[1] - (int)r0[1]) + abs((int)c0[2] - (int)r0[2]);
                  if (d >= 30) cnt++;
                }
              }
              areas[pi] = cnt;
              free(px5);
            }
          }
          free(px_rest);
          printf("apple_render: v9_switch_5press_delta_area=(%d,%d,%d,%d,%d)\n", areas[0], areas[1], areas[2], areas[3], areas[4]);
          CHECK(areas[0] < areas[1] && areas[1] < areas[2] && areas[2] < areas[3] && areas[3] < areas[4]);
        }
        // --- V9f: Role 4 Tab icon bevel gate (FIXED refract=9.0, Role 4 -64; icon at x_right-6.7pt vs empty; |y-cy|=0.42*h diff==0) ---
        {
          double tb[4 * MB_INST];
          rect_at(tb, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(tb + MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -563);
          tb[MB_INST + 4] = 22.5; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = -64.0;
          tb[MB_INST + 11] = 0.0; tb[MB_INST + 12] = 1.0; tb[MB_INST + 13] = 9.0;
          tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 9.0; tb[MB_INST + 22] = 0.0; tb[MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw0 = 0, ah0 = 0;
          uint8_t *px_empty = read_texture(canvas, &aw0, &ah0);
          rect_at(tb + MB_INST, 127.3, 35.0, 2.0, 10.0, 0, 1.0, 0.55, 0.0, 0);
          rect_at(tb + 2 * MB_INST, 117.0, 56.0, 2.0, 6.0, 0, 1.0, 0.55, 0.0, 0);
          rect_at(tb + 3 * MB_INST, 25, 17.5, 110, 45, 6, 1.0, 1.0, 1.0, -564);
          tb[3 * MB_INST + 4] = 22.5; tb[3 * MB_INST + 6] = 1.0; tb[3 * MB_INST + 7] = -64.0;
          tb[3 * MB_INST + 11] = 0.0; tb[3 * MB_INST + 12] = 1.0; tb[3 * MB_INST + 13] = 9.0;
          tb[3 * MB_INST + 15] = 1.0; tb[3 * MB_INST + 21] = 9.0; tb[3 * MB_INST + 22] = 0.0; tb[3 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(tb, 4, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw1 = 0, ah1 = 0;
          uint8_t *px_icon = read_texture(canvas, &aw1, &ah1);
          uint8_t *a_mid = A_PX(px_empty, aw0, 400, 120);
          uint8_t *b_mid = A_PX(px_icon, aw1, 400, 120);
          int mid_delta = abs((int)b_mid[2] - (int)a_mid[2]) + abs((int)b_mid[1] - (int)a_mid[1]);
          uint8_t *a_out = A_PX(px_empty, aw0, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
          uint8_t *b_out = A_PX(px_icon, aw1, (int)lround(123.2 * 3), (int)lround(58.9 * 3));
          int out_diff = 0;
          for (int ch = 0; ch < 3; ch++) {
            int df = abs((int)b_out[ch] - (int)a_out[ch]);
            if (df > out_diff) out_diff = df;
          }
          printf("apple_render: v9_tab_icon_bevel mid_delta=%d out_diff=%d\n", mid_delta, out_diff);
          CHECK(mid_delta >= 40 && out_diff == 0);
          free(px_empty);
          free(px_icon);
        }
        // --- V9g: Role 4 Tab bevelGate outer falloff regression (no un-refracted ghost at inward=10pt) ---
        {
          double tg[3 * MB_INST];
          rect_at(tg, 0, 0, VW, VH, 0, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0, 0);
          rect_at(tg + MB_INST, 41.5, 8.0, 2.0, 64.0, 0, 90.0 / 255.0, 90.0 / 255.0, 90.0 / 255.0, 0);
          rect_at(tg + 2 * MB_INST, 32.5, 8.25, 95.0, 63.5, 6, 1.0, 1.0, 1.0, -565);
          tg[2 * MB_INST + 4] = 31.75; tg[2 * MB_INST + 6] = 1.0; tg[2 * MB_INST + 7] = -64.0;
          tg[2 * MB_INST + 11] = 0.0; tg[2 * MB_INST + 12] = 1.0; tg[2 * MB_INST + 13] = 9.0;
          tg[2 * MB_INST + 15] = 1.0; tg[2 * MB_INST + 21] = 9.0; tg[2 * MB_INST + 22] = 0.0; tg[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(tg, 3, 246.0 / 255.0, 244.0 / 255.0, 240.0 / 255.0);
          present_drain();
          int awg = 0, ahg = 0;
          uint8_t *pxg = read_texture(canvas, &awg, &ahg);
          uint8_t *co = A_PX(pxg, awg, 127, 120);
          double l_orig = 0.2126 * co[2] + 0.7152 * co[1] + 0.0722 * co[0];
          double min_l = 1e9;
          for (int px_i = 132; px_i <= 136; px_i++) {
            uint8_t *cr = A_PX(pxg, awg, px_i, 120);
            double lr = 0.2126 * cr[2] + 0.7152 * cr[1] + 0.0722 * cr[0];
            if (lr < min_l) min_l = lr;
          }
          printf("apple_render: v9_tab_no_ghost orig_L=%.1f refr_min_L=%.1f\n", l_orig, min_l);
          CHECK(l_orig > 220.0 && min_l < 170.0);
          free(pxg);
        }
        // --- V9a2: Switch ON @ 2x phase-shifted integrated green mass ---
        mb_render_set_size(VW, VH, 2);
        for (int ph = 0; ph < 2; ph++) {
          double yoff = ph * 0.25;
          double sw[3 * MB_INST];
          rect_at(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(sw + MB_INST, 40, 26 + yoff, 63, 28, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
          sw[MB_INST + 4] = 14.0;
          rect_at(sw + 2 * MB_INST, 52.9, 21.0 + yoff, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -57 - ph);
          sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
          sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
          sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          int gsum = 0;
          for (int dy = 0; dy < 3; dy++) {
            uint8_t *c = A_PX(px, aw, 80 * 2, 21 * 2 + dy);
            int d = (int)c[1] - (int)c[2];
            if (d > 0) gsum += d;
          }
          printf("apple_render: v9_switch_on_2x phase=%d green_mass=%d\n", ph, gsum);
          CHECK(gsum > 40);
          free(px);
        }
        // --- V10: Regular Glass Light Parabolic AA (@2x, R=24pt) & Dark Corner Check ---
        {
          mb_render_set_size(160, 80, 2);
          double rg[2 * MB_INST];
          rect_at(rg, 0, 0, 160, 80, 0, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0, 0);
          rect_at(rg + MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -70);
          rg[MB_INST + 4] = 24.0; rg[MB_INST + 6] = 1.0; rg[MB_INST + 7] = 0.0;
          rg[MB_INST + 11] = 0.40; rg[MB_INST + 12] = 0.6; rg[MB_INST + 13] = 14.0;
          rg[MB_INST + 15] = 1.0; rg[MB_INST + 21] = 20.0; rg[MB_INST + 22] = 0.0; rg[MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 160, 80);
          mb_render_present(rg, 2, 242.0 / 255.0, 240.0 / 255.0, 236.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          double masses[64];
          int n = 0;
          const double bg_L = 0.2126 * 242.0 + 0.7152 * 240.0 + 0.0722 * 236.0;
          for (int py = 20 + 4; py <= 20 + 44; py++) {
            double mass = 0.0;
            for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
              uint8_t *c = A_PX(px, aw, xpx, py);
              double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
              if (L < bg_L) mass += (bg_L - L);
            }
            masses[n++] = mass / 2.0;
          }
          double max_d2 = 0.0;
          for (int i = 1; i < n - 1; i++) {
            double d2 = fabs(masses[i - 1] - 2.0 * masses[i] + masses[i + 1]);
            if (d2 > max_d2) max_d2 = d2;
          }
          double side_lmin = 1e9;
          for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 2; xpx++) {
            uint8_t *c = A_PX(px, aw, xpx, 40 * 2);
            double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
            if (L < side_lmin) side_lmin = L;
          }
          uint8_t *lc_outer_top = A_PX(px, aw, 80 * 2, 10 * 2 - 1);
          uint8_t *lc_top = A_PX(px, aw, 80 * 2, 10 * 2);
          uint8_t *lc_mid = A_PX(px, aw, 80 * 2, 40 * 2);
          double light_outer_top_L = 0.2126 * lc_outer_top[2] + 0.7152 * lc_outer_top[1] + 0.0722 * lc_outer_top[0];
          double light_top_L = 0.2126 * lc_top[2] + 0.7152 * lc_top[1] + 0.0722 * lc_top[0];
          double light_mid_L = 0.2126 * lc_mid[2] + 0.7152 * lc_mid[1] + 0.0722 * lc_mid[0];
          printf("apple_render: v10_reg_light_2x max_d2=%.2f side_lmin=%.2f outer_top_L=%.1f top_L=%.1f mid_L=%.1f\n",
                 max_d2, side_lmin, light_outer_top_L, light_top_L, light_mid_L);
          CHECK(max_d2 <= 14.0);
          CHECK(side_lmin >= 150.0 && side_lmin <= 176.0);
          CHECK(light_outer_top_L <= light_mid_L - 15.0);
          CHECK(light_top_L >= light_mid_L);
          free(px);
          // V10-Dark: Dark Regular Glass (@2x, R=24pt, regRim enabled) top rim > interior, obsidian external side contour (never eating inward)
          double rgd[2 * MB_INST];
          rect_at(rgd, 0, 0, 160, 80, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          rect_at(rgd + MB_INST, 20, 10, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -71);
          rgd[MB_INST + 4] = 24.0; rgd[MB_INST + 6] = 1.0; rgd[MB_INST + 7] = 0.0;
          rgd[MB_INST + 11] = 0x67 / 255.0; rgd[MB_INST + 12] = 0.6; rgd[MB_INST + 13] = 14.0;
          rgd[MB_INST + 15] = 1.0; rgd[MB_INST + 21] = 20.0; rgd[MB_INST + 22] = 0.0; rgd[MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 160, 80);
          mb_render_present(rgd, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
          present_drain();
          uint8_t *pxd = read_texture(canvas, &aw, &ah);
          uint8_t *dc_mid = A_PX(pxd, aw, 80 * 2, 40 * 2);
          uint8_t *dc_top = A_PX(pxd, aw, 80 * 2, 10 * 2);
          uint8_t *dc_side_in = A_PX(pxd, aw, 140 * 2 - 1, 40 * 2);
          uint8_t *dc_side_out = A_PX(pxd, aw, 140 * 2, 40 * 2);
          double l_mid = 0.2126 * dc_mid[2] + 0.7152 * dc_mid[1] + 0.0722 * dc_mid[0];
          double l_top = 0.2126 * dc_top[2] + 0.7152 * dc_top[1] + 0.0722 * dc_top[0];
          double l_side_in = 0.2126 * dc_side_in[2] + 0.7152 * dc_side_in[1] + 0.0722 * dc_side_in[0];
          double l_side_out = 0.2126 * dc_side_out[2] + 0.7152 * dc_side_out[1] + 0.0722 * dc_side_out[0];
          uint64_t dh = 14695981039346656037ULL;
          for (int py = 10 * 2; py <= 10 * 2 + 8; py++) {
            uint8_t *c = A_PX(pxd, aw, 80 * 2, py);
            uint8_t rgba[4] = { c[2], c[1], c[0], c[3] };
            for (int ch = 0; ch < 4; ch++) { dh ^= rgba[ch]; dh *= 1099511628211ULL; }
          }
          for (int xpx = 140 * 2 - 8; xpx <= 140 * 2 + 1; xpx++) {
            uint8_t *c = A_PX(pxd, aw, xpx, 40 * 2);
            uint8_t rgba[4] = { c[2], c[1], c[0], c[3] };
            for (int ch = 0; ch < 4; ch++) { dh ^= rgba[ch]; dh *= 1099511628211ULL; }
          }
          for (int py = 10 * 2; py <= 10 * 2 + 48; py++) {
            for (int xpx = 140 * 2 - 48; xpx <= 140 * 2 + 2; xpx++) {
              uint8_t *c = A_PX(pxd, aw, xpx, py);
              uint8_t rgba[4] = { c[2], c[1], c[0], c[3] };
              for (int ch = 0; ch < 4; ch++) { dh ^= rgba[ch]; dh *= 1099511628211ULL; }
            }
          }
          printf("apple_render: v10_reg_dark_2x top=%.1f mid=%.1f side_in=%.1f side_out=%.1f roi_fnv1a=0x%016llx\n", l_top, l_mid, l_side_in, l_side_out, (unsigned long long)dh);
          // (the 1-point rim of what is outside it, glass_reflect_cases.h: 66 pixels of this ROI 1 LSB from before)
          CHECK(dh == 0xe6ce81e8141ce998ULL);
          CHECK(l_top > l_mid + 20.0);
          CHECK(l_side_out <= 14.0 && l_side_out < l_mid - 40.0);
          CHECK(l_side_in >= l_mid - 6.0);
          free(pxd);
          // V12-AntiSmear: Regular Light blur=1.2pt at 3x over 2pt alternating dark/light strokes must keep
          // full-res stroke separation (blocks reintroduction of secondary detailAmt smear or k=1 blur downsample).
          mb_render_set_size(160, 80, 3);
          double sm[7 * MB_INST];
          rect_at(sm, 0, 0, 160, 80, 0, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0, 0);
          for (int si = 0; si < 5; si++) {
            rect_at(sm + (si + 1) * MB_INST, 20, 30 + si * 4, 120, 2, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
          }
          rect_at(sm + 6 * MB_INST, 20, 10, 120, 60, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -711);
          sm[6 * MB_INST + 4] = 24.0; sm[6 * MB_INST + 6] = 1.0; sm[6 * MB_INST + 7] = 1.2;
          sm[6 * MB_INST + 11] = 0x67 / 255.0; sm[6 * MB_INST + 12] = 0.6; sm[6 * MB_INST + 13] = 20.0;
          sm[6 * MB_INST + 15] = 1.0; sm[6 * MB_INST + 21] = 28.0; sm[6 * MB_INST + 22] = 0.06; sm[6 * MB_INST + 23] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, 160, 80);
          mb_render_present(sm, 7, 244.0 / 255.0, 241.0 / 255.0, 234.0 / 255.0);
          present_drain();
          uint8_t *pxs = read_texture(canvas, &aw, &ah);
          double sm_min = 1e9, sm_max = -1.0;
          for (int py = 34 * 3; py <= 42 * 3; py++) {
            uint8_t *c = A_PX(pxs, aw, 80 * 3, py);
            double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
            if (L < sm_min) sm_min = L;
            if (L > sm_max) sm_max = L;
          }
          printf("apple_render: v12_reg_antismear_3x min_L=%.1f max_L=%.1f delta=%.1f\n", sm_min, sm_max, sm_max - sm_min);
          CHECK(sm_max - sm_min >= 4.0 && sm_min >= 170.0);
          free(pxs);
          mb_render_set_size(160, 80, 2);
        }
        // --- V11-AA & V11-Wall: Switch ON (Dark & Light, 3x & 2x, shadow-free) ---
        for (int is_light = 0; is_light <= 1; is_light++) {
          double bg = is_light ? 1.0 : 28.0 / 255.0;
          double bg_b = is_light ? 1.0 : 30.0 / 255.0;
          double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
          double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
          double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
          for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
            int sc = (sc_idx == 0) ? 3 : 2;
            mb_render_set_size(120, 65, sc);
            double sw[3 * MB_INST];
            rect_at(sw, 0, 0, 120, 65, 0, bg, bg, bg_b, 0);
            rect_at(sw + MB_INST, 18.5, 18.0, 63.0, 28.0, 0, tr_r, tr_g, tr_b, 0);
            sw[MB_INST + 4] = 14.0;
            sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
            rect_at(sw + 2 * MB_INST, 31.58, 12.8, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -72 - is_light * 2 - sc_idx);
            sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
            sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
            sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
            glass_forget();
            mb_host_render_dirty(0, 0, 120, 65);
            mb_render_present(sw, 3, bg, bg, bg_b);
            present_drain();
            int aw = 0, ah = 0;
            uint8_t *px = read_texture(canvas, &aw, &ah);
            int y_lo = (int)ceil((32.0 - 0.52 * 19.2) * sc - 0.5);
            int y_hi = (int)floor((32.0 + 0.52 * 19.2) * sc - 0.5);
            int xl0 = (sc == 3) ? 89 : 58, xl1 = (sc == 3) ? 109 : 74;
            int xr0 = (sc == 3) ? 259 : 170, xr1 = (sc == 3) ? 281 : 188;
            double minL[128], minR[128];
            int n = 0;
            for (int py = y_lo; py <= y_hi; py++) {
              double ml = 1e9, mr = 1e9;
              for (int xpx = xl0; xpx <= xl1; xpx++) {
                uint8_t *c = A_PX(px, aw, xpx, py);
                double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
                if (L < ml) ml = L;
              }
              for (int xpx = xr0; xpx <= xr1; xpx++) {
                uint8_t *c = A_PX(px, aw, xpx, py);
                double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
                if (L < mr) mr = L;
              }
              minL[n] = ml; minR[n] = mr; n++;
            }
            double d2L = 0.0, d2R = 0.0;
            for (int i = 1; i < n - 1; i++) {
              double a = fabs(minL[i - 1] - 2.0 * minL[i] + minL[i + 1]);
              double b = fabs(minR[i - 1] - 2.0 * minR[i] + minR[i + 1]);
              if (a > d2L) d2L = a;
              if (b > d2R) d2R = b;
            }
            double lim = (sc == 3) ? (is_light ? 12.0 : 10.0) : (is_light ? 14.0 : 12.0);
            printf("apple_render: v11_aa(%s %dx [%d..%d]) L=%.2f R=%.2f (lim=%.1f)\n",
                   is_light ? "light" : "dark", sc, y_lo, y_hi, d2L, d2R, lim);
            CHECK(d2L <= lim && d2R <= lim);
            if (sc == 3) {
              int cy_px = 32 * 3;
              int rx_min = 271;
              double r_minL = 1e9;
              for (int xpx = 268; xpx <= 272; xpx++) {
                uint8_t *c = A_PX(px, aw, xpx, cy_px);
                double L = 0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0];
                if (L < r_minL) { r_minL = L; rx_min = xpx; }
              }
              uint8_t *rc0 = A_PX(px, aw, rx_min, cy_px);
              int r_gr = (int)rc0[1] - (int)rc0[2];
              double l1, l2, l3, l4;
              {
                uint8_t *c1 = A_PX(px, aw, rx_min - 1, cy_px);
                uint8_t *c2 = A_PX(px, aw, rx_min - 2, cy_px);
                uint8_t *c3 = A_PX(px, aw, rx_min - 3, cy_px);
                uint8_t *c4 = A_PX(px, aw, rx_min - 4, cy_px);
                l1 = 0.2126 * c1[2] + 0.7152 * c1[1] + 0.0722 * c1[0];
                l2 = 0.2126 * c2[2] + 0.7152 * c2[1] + 0.0722 * c2[0];
                l3 = 0.2126 * c3[2] + 0.7152 * c3[1] + 0.0722 * c3[0];
                l4 = 0.2126 * c4[2] + 0.7152 * c4[1] + 0.0722 * c4[0];
              }
              int r_mono = (l1 >= r_minL && l2 >= l1 && l3 >= l2 && l4 >= l3);
              int best_gr = -999, best_g = 0;
              for (int xpx = 94; xpx <= 98; xpx++) {
                uint8_t *c = A_PX(px, aw, xpx, cy_px);
                int gr = (int)c[1] - (int)c[2];
                if (gr > best_gr && c[1] >= 125 && c[1] <= 165) { best_gr = gr; best_g = c[1]; }
              }
              printf("apple_render: v11_wall(%s 3x) r_minL=%.1f@x=%d r_gr=%d wall=(%.1f,%.1f,%.1f,%.1f) r_mono=%d l_emerald=(G=%d,G-R=%d)\n",
                     is_light ? "light" : "dark", r_minL, rx_min, r_gr, l1, l2, l3, l4, r_mono, best_g, best_gr);
              if (!is_light) {
                CHECK(r_minL <= 14.0 && r_gr <= 12 && r_mono);
              } else {
                CHECK(r_minL >= 170.0 && r_minL <= 205.0 && r_mono && l4 >= 230.0);
              }
              CHECK(best_gr >= 90 && best_g >= 125 && best_g <= 165);
              // Switch 3x left-horn sweep dx=6..20pt (both Dark & Light)
              {
                double prev_moat = -1.0;
                printf("apple_render: v9_left_horn_3x(%s)", is_light ? "light" : "dark");
                for (int dx = 6; dx <= 20; dx += 2) {
                  int pc = (int)lround((31.58 + dx) * 3.0);
                  double dyc = sqrt(fmax(19.2 * 19.2 - fmax(19.2 - dx, 0.0) * fmax(19.2 - dx, 0.0), 0.0));
                  int y0 = (int)lround((32.0 - dyc + 1.0) * 3.0);
                  int y1 = (int)lround(32.0 * 3.0);
                  int best = 0, cur = 0;
                  for (int py = y0; py < y1; py++) {
                    uint8_t *c = A_PX(px, aw, pc, py);
                    if ((int)c[1] - (int)c[2] < 26) { cur++; if (cur > best) best = cur; } else cur = 0;
                  }
                  double mpt = best / 3.0;
                  printf(" dx=%d:%.2f", dx, mpt);
                  if (dx == 6 || dx == 8) CHECK(mpt == 0.0);
                  if (dx == 10) CHECK(mpt >= 1.5 && mpt <= 4.5);
                  if (dx >= 12 && prev_moat >= 0.0) {
                    CHECK(mpt >= prev_moat - 0.35 && mpt - prev_moat <= 3.5);
                  }
                  if (dx == 20) CHECK(mpt >= 7.0);
                  prev_moat = mpt;
                }
                printf("\n");
              }
            }
            free(px);
          }
        }
        // --- V11-Top: Registered 3x & 2x top-wall at 5.00pt & 5.20pt (Dark & Light) ---
        {
          double offs[2] = { 5.00, 5.20 };
          for (int is_light = 0; is_light <= 1; is_light++) {
            double bg = is_light ? 1.0 : 28.0 / 255.0;
            double bg_b = is_light ? 1.0 : 30.0 / 255.0;
            double tr_r = is_light ? 52.0 / 255.0 : 48.0 / 255.0;
            double tr_g = is_light ? 199.0 / 255.0 : 209.0 / 255.0;
            double tr_b = is_light ? 89.0 / 255.0 : 88.0 / 255.0;
            for (int oi = 0; oi < 2; oi++) {
              double off = offs[oi], th = 38.4 - 2.0 * off;
              for (int sc_idx = 0; sc_idx < 2; sc_idx++) {
                int sc = (sc_idx == 0) ? 3 : 2;
                mb_render_set_size(VW, VH, sc);
                double sw[3 * MB_INST];
                rect_at(sw, 0, 0, VW, VH, 0, bg, bg, bg_b, 0);
                rect_at(sw + MB_INST, 40.0, 21.0 + off, 63.0, th, 0, tr_r, tr_g, tr_b, 0);
                sw[MB_INST + 4] = th * 0.5;
                sw[MB_INST + 36] = th * 0.5; sw[MB_INST + 37] = th * 0.5; sw[MB_INST + 38] = th * 0.5; sw[MB_INST + 39] = th * 0.5;
                rect_at(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -80 - is_light * 4 - oi * 2 - sc_idx);
                sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = -32.0;
                sw[2 * MB_INST + 11] = 0.0; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
                sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = 9.0; sw[2 * MB_INST + 22] = 0.0; sw[2 * MB_INST + 23] = 0.0;
                glass_forget();
                mb_host_render_dirty(0, 0, VW, VH);
                mb_render_present(sw, 3, bg, bg, bg_b);
                present_drain();
                int aw = 0, ah = 0;
                uint8_t *px = read_texture(canvas, &aw, &ah);
                uint8_t *r0 = A_PX(px, aw, 80 * sc, 21 * sc + 0);
                uint8_t *r1 = A_PX(px, aw, 80 * sc, 21 * sc + 1);
                uint8_t *r2 = A_PX(px, aw, 80 * sc, 21 * sc + 2);
                int gr0 = (int)r0[1] - (int)r0[2], gr1 = (int)r1[1] - (int)r1[2], gr2 = (int)r2[1] - (int)r2[2];
                double l0 = 0.2126 * r0[2] + 0.7152 * r0[1] + 0.0722 * r0[0];
                double l2 = 0.2126 * r2[2] + 0.7152 * r2[1] + 0.0722 * r2[0];
                printf("apple_render: v11_top(%s %dx @%.2fpt) r0=(G-R=%d,L=%.0f) r1=(G-R=%d) r2=(G-R=%d,L=%.0f)\n",
                       is_light ? "light" : "dark", sc, off, gr0, l0, gr1, gr2, l2);
                if (sc == 3) {
                  if (!is_light) {
                    CHECK(gr0 < 15 && l0 <= 35.0 && gr1 >= 100 && gr2 < 15 && l2 >= 75.0);
                  } else {
                    CHECK(gr0 < 15 && l0 >= 180.0 && l0 <= 215.0 && gr1 >= 95 && gr2 < 15 && l2 >= 245.0);
                  }
                } else {
                  CHECK(gr1 >= 70 && gr2 < 15);
                }
                free(px);
              }
            }
          }
        }
        // --- V9h: Switch ON held glassFrost C0 continuity (0 -> eps, 0.108->0.110 veil, 0.127->0.129 blur, 0.60 frosted) ---
        {
          static const double frosts[8] = { 0.0, 0.0001, 0.00011, 0.108, 0.110, 0.127, 0.129, 0.60 };
          mb_render_set_size(VW, VH, 3);
          uint8_t *px0 = NULL, *px_prev = NULL;
          int aw0 = 0, ah0 = 0;
          int max_d_eps = 0, max_d_veil = 0, max_d_blur = 0;
          int c0_r = 0, c0_g = 0, c60_r = 0, c60_g = 0;
          for (int fi = 0; fi < 8; fi++) {
            double fr = frosts[fi];
            double alpha = 0.0, slot7 = -32.0, refr = 9.0;
            if (fr > 0.0001) {
              double a_frac = 0.94 * fr;
              alpha = round(a_frac * 255.0) / 255.0;
              double bl = (a_frac <= 0.12) ? 0.0 : 14.0 * ((a_frac - 0.12) / 0.88) * 0.5;
              slot7 = (bl <= 0.0) ? -32.0 : bl;
              refr = 9.0 * (1.0 - 0.55 * fr);
            }
            double sw[3 * MB_INST];
            rect_at(sw, 0, 0, VW, VH, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
            rect_at(sw + MB_INST, 40.0, 26.0, 63.0, 28.0, 0, 48.0 / 255.0, 209.0 / 255.0, 88.0 / 255.0, 0);
            sw[MB_INST + 4] = 14.0;
            sw[MB_INST + 36] = 14.0; sw[MB_INST + 37] = 14.0; sw[MB_INST + 38] = 14.0; sw[MB_INST + 39] = 14.0;
            rect_at(sw + 2 * MB_INST, 52.9, 21.0, 59.2, 38.4, 6, 1.0, 1.0, 1.0, -90 - fi);
            sw[2 * MB_INST + 4] = 19.2; sw[2 * MB_INST + 6] = 1.0; sw[2 * MB_INST + 7] = slot7;
            sw[2 * MB_INST + 11] = alpha; sw[2 * MB_INST + 12] = 1.0; sw[2 * MB_INST + 13] = 9.0;
            sw[2 * MB_INST + 15] = 1.0; sw[2 * MB_INST + 21] = refr;
            glass_forget();
            mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(sw, 3, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0);
            present_drain();
            int aw = 0, ah = 0;
            uint8_t *px = read_texture(canvas, &aw, &ah);
            if (fi == 0) {
              px0 = px; aw0 = aw; ah0 = ah;
              uint8_t *c = A_PX(px, aw, 82 * 3, 40 * 3);
              c0_r = c[2]; c0_g = c[1];
            } else {
              if (fi == 2) {
                for (int py = 21 * 3; py <= 59 * 3; py++) {
                  for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                    uint8_t *a = A_PX(px0, aw0, xpx, py);
                    uint8_t *b = A_PX(px, aw, xpx, py);
                    for (int ch = 0; ch < 3; ch++) {
                      int d = abs((int)a[ch] - (int)b[ch]);
                      if (d > max_d_eps) max_d_eps = d;
                    }
                  }
                }
              } else if (fi == 3 || fi == 5) {
                free(px_prev);
                px_prev = px;
                px = NULL;
              } else if (fi == 4 || fi == 6) {
                int md = 0;
                for (int py = 21 * 3; py <= 59 * 3; py++) {
                  for (int xpx = 53 * 3; xpx <= 112 * 3; xpx++) {
                    uint8_t *a = A_PX(px_prev, aw0, xpx, py);
                    uint8_t *b = A_PX(px, aw, xpx, py);
                    for (int ch = 0; ch < 3; ch++) {
                      int d = abs((int)a[ch] - (int)b[ch]);
                      if (d > md) md = d;
                    }
                  }
                }
                if (fi == 4) max_d_veil = md; else max_d_blur = md;
              } else if (fi == 7) {
                uint8_t *c = A_PX(px, aw, 82 * 3, 40 * 3);
                c60_r = c[2]; c60_g = c[1];
              }
              free(px);
            }
          }
          free(px0);
          free(px_prev);
          (void)ah0;
          printf("apple_render: v9_switch_frost_continuity max_d_eps=%d max_d_veil=%d max_d_blur=%d ctr0=(%d,%d) ctr60=(%d,%d)\n",
                 max_d_eps, max_d_veil, max_d_blur, c0_r, c0_g, c60_r, c60_g);
          CHECK(max_d_eps <= 2);
          CHECK(max_d_veil <= 10);
          CHECK(max_d_blur <= 10);
          CHECK(c60_r > c0_r + 25 && (c60_g - c60_r) < (c0_g - c0_r) - 20);
        }
        // --- V11-Unified-Panel-Glass: Light/Dark 0x80 overlay chroma, rim, white-backdrop WCAG >= 4.5:1, and 0xFF solid zero leak ---
        {
          mb_render_set_size(VW, VH, 2);
          double pb[2 * MB_INST];
          rect_at(pb, 0, 0, VW, VH, 0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0, 0);
          rect_at(pb + MB_INST, 20.0, 10.0, 120.0, 60.0, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -98);
          pb[MB_INST + 4] = 22.0; pb[MB_INST + 6] = 1.0; pb[MB_INST + 7] = 14.0;
          pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 20.0;
          pb[MB_INST + 14] = 0.0; pb[MB_INST + 15] = 1.0; pb[MB_INST + 21] = 16.0; pb[MB_INST + 22] = 0.0;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0);
          present_drain();
          int aw = 0, ah = 0;
          uint8_t *px = read_texture(canvas, &aw, &ah);
          uint8_t *rim = A_PX(px, aw, 80 * 2, 20);
          uint8_t *mid = A_PX(px, aw, 80 * 2, 68);
          int mid_br = (int)mid[0] - (int)mid[2];
          double rim_L = 0.2126 * rim[2] + 0.7152 * rim[1] + 0.0722 * rim[0];
          double mid_L = 0.2126 * mid[2] + 0.7152 * mid[1] + 0.0722 * mid[0];
          free(px);

          pb[MB_INST + 11] = 1.0;
          pb[MB_INST + 20] = -99;
          glass_forget();
          mb_host_render_dirty(0, 0, VW, VH);
          mb_render_present(pb, 2, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0);
          present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *sr = A_PX(px, aw, 80 * 2, 20);
          uint8_t *sm = A_PX(px, aw, 80 * 2, 68);
          double sr_L = 0.2126 * sr[2] + 0.7152 * sr[1] + 0.0722 * sr[0];
          double sm_L = 0.2126 * sm[2] + 0.7152 * sm[1] + 0.0722 * sm[0];
          free(px);

          // Light density monotonicity: 0x80 and 0xB3 (frost) over 0.72 grey vs 0.60 grey
          rect_at(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 0);
          pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -100; pb[MB_INST + 22] = 0.0;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 0.60, 0.60, 0.60); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *m60 = A_PX(px, aw, 80 * 2, 68);
          double l60 = 0.2126 * m60[2] + 0.7152 * m60[1] + 0.0722 * m60[0];
          free(px);
          rect_at(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 0);
          pb[MB_INST + 20] = -101;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 0.72, 0.72, 0.72); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *m72 = A_PX(px, aw, 80 * 2, 68);
          double l72 = 0.2126 * m72[2] + 0.7152 * m72[1] + 0.0722 * m72[0];
          free(px);
          rect_at(pb, 0, 0, VW, VH, 0, 0.60, 0.60, 0.60, 0);
          pb[MB_INST + 11] = 0xB3 / 255.0; pb[MB_INST + 20] = -105; pb[MB_INST + 22] = 0.0;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 0.60, 0.60, 0.60); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *m60c = A_PX(px, aw, 80 * 2, 68);
          double l60_cd = 0.2126 * m60c[2] + 0.7152 * m60c[1] + 0.0722 * m60c[0];
          free(px);
          rect_at(pb, 0, 0, VW, VH, 0, 0.72, 0.72, 0.72, 0);
          pb[MB_INST + 20] = -106;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 0.72, 0.72, 0.72); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *m72c = A_PX(px, aw, 80 * 2, 68);
          double l72_cd = 0.2126 * m72c[2] + 0.7152 * m72c[1] + 0.0722 * m72c[0];
          free(px);

          // Dark 0x80 vibrant chroma over (60,120,210), Dark 0xCC calmer chroma, and Dark 0x80 over pure white WCAG >= 4.5:1
          rect_at(pb, 0, 0, VW, VH, 0, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0, 0);
          pb[MB_INST + 8] = 32.0 / 255.0; pb[MB_INST + 9] = 32.0 / 255.0; pb[MB_INST + 10] = 32.0 / 255.0;
          pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -102; pb[MB_INST + 22] = 0.0;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *da = A_PX(px, aw, 80 * 2, 68);
          int d80_br = (int)da[0] - (int)da[2];
          free(px);
          pb[MB_INST + 11] = 0xCC / 255.0; pb[MB_INST + 20] = -104; pb[MB_INST + 22] = 0.0;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *dc = A_PX(px, aw, 80 * 2, 68);
          int cc_br = (int)dc[0] - (int)dc[2];
          free(px);
          rect_at(pb, 0, 0, VW, VH, 0, 1.0, 1.0, 1.0, 0);
          pb[MB_INST + 11] = 0x80 / 255.0; pb[MB_INST + 20] = -107; pb[MB_INST + 22] = 0.0;
          glass_forget(); mb_host_render_dirty(0, 0, VW, VH); mb_render_present(pb, 2, 1.0, 1.0, 1.0); present_drain();
          px = read_texture(canvas, &aw, &ah);
          uint8_t *dw = A_PX(px, aw, 80 * 2, 68);
          double dark_white_L = 0.2126 * dw[2] + 0.7152 * dw[1] + 0.0722 * dw[0];
          free(px);

          // Regular controls (chroma=0.06 vs 0.0) bit-exact zero-diff gate under Light 0x85/0xAB & Dark 0xAB
          int ctrl_max_diff = 0;
          int ctrl_hash_eq = 1;
          struct { int dark; double alpha; double br, bg, bb; } ctrl_cases[3] = {
            { 0, 0x85 / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
            { 0, 0xAB / 255.0, 211.0 / 255.0, 232.0 / 255.0, 253.0 / 255.0 },
            { 1, 0xAB / 255.0,  60.0 / 255.0, 120.0 / 255.0, 210.0 / 255.0 },
          };
          pb[MB_INST + 7] = 2.0; pb[MB_INST + 12] = 0.6; pb[MB_INST + 13] = 14.0; pb[MB_INST + 21] = 20.0;
          for (int ci = 0; ci < 3; ci++) {
            rect_at(pb, 0, 0, VW, VH, 0, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb, 0);
            pb[MB_INST + 8] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
            pb[MB_INST + 9] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 252.0 / 255.0;
            pb[MB_INST + 10] = ctrl_cases[ci].dark ? 32.0 / 255.0 : 253.0 / 255.0;
            pb[MB_INST + 11] = ctrl_cases[ci].alpha;
            pb[MB_INST + 20] = -110 - ci * 2; pb[MB_INST + 22] = 0.06;
            glass_forget(); mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb); present_drain();
            uint8_t *p06 = read_texture(canvas, &aw, &ah);
            pb[MB_INST + 20] = -111 - ci * 2; pb[MB_INST + 22] = 0.0;
            glass_forget(); mb_host_render_dirty(0, 0, VW, VH);
            mb_render_present(pb, 2, ctrl_cases[ci].br, ctrl_cases[ci].bg, ctrl_cases[ci].bb); present_drain();
            uint8_t *p00 = read_texture(canvas, &aw, &ah);
            uint64_t h06 = 14695981039346656037ULL, h00 = 14695981039346656037ULL;
            for (int ry = 20; ry < 140; ry++) {
              for (int rx = 40; rx < 280; rx++) {
                uint8_t *q06 = A_PX(p06, aw, rx, ry);
                uint8_t *q00 = A_PX(p00, aw, rx, ry);
                for (int c = 0; c < 3; c++) {
                  int d = abs((int)q06[c] - (int)q00[c]);
                  if (d > ctrl_max_diff) ctrl_max_diff = d;
                  h06 = (h06 ^ q06[c]) * 1099511628211ULL;
                  h00 = (h00 ^ q00[c]) * 1099511628211ULL;
                }
              }
            }
            if (h06 != h00) ctrl_hash_eq = 0;
            free(p06); free(p00);
          }

          printf("apple_render: v11_unified_panel_glass mid_br=%d rim_L=%.1f mid_L=%.1f solid_dL=%.2f l60=%.1f l72=%.1f b3=%.1f->%.1f d80_br=%d cc_br=%d dark_wt_L=%.1f ctrl_diff=%d ctrl_eq=%d\n",
                 mid_br, rim_L, mid_L, fabs(sr_L - sm_L), l60, l72, l60_cd, l72_cd, d80_br, cc_br, dark_white_L, ctrl_max_diff, ctrl_hash_eq);
          CHECK(mid_br >= 24);
          CHECK(rim_L >= mid_L + 4.0);
          CHECK(fabs(sr_L - sm_L) <= 1.0);
          CHECK(l72 >= l60 + 2.0);
          CHECK(l72_cd >= l60_cd + 1.0);
          CHECK(d80_br >= 90 && cc_br < d80_br - 25);
          CHECK(dark_white_L <= 102.0);
          CHECK(ctrl_max_diff == 0 && ctrl_hash_eq == 1);
        }
        // V13-Menu-Morph-DualW: sweep liquid_menu_morph_glass alpha codes (Light 103..147, Dark 103..136, Tinted 180..210)
        // and verify C1-continuous dual_w (adjacent alpha step <= 0.05) + k>=3 guard.
        {
          float mf[MB_INST];
          float max_step_l = 0.0f, max_step_d = 0.0f, max_step_t = 0.0f;
          float prev_w = -1.0f, w_start = 0.0f, w_end = 0.0f;
          for (int ai = 103; ai <= 147; ai++) {
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 44.0f;
            mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = (float)ai / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -120.0f; mf[21] = 20.0f;
            Grab g;
            CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            if (ai == 103) w_start = g.dual_w;
            if (ai == 147) w_end = g.dual_w;
            if (prev_w >= 0.0f) {
              float d = fabsf(g.dual_w - prev_w);
              if (d > max_step_l) max_step_l = d;
            }
            prev_w = g.dual_w;
          }
          prev_w = -1.0f;
          for (int ai = 103; ai <= 136; ai++) {
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * (float)(ai - 103) / 33.0f;
            mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = (float)ai / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -121.0f; mf[21] = 20.0f;
            Grab g;
            CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            if (prev_w >= 0.0f) {
              float d = fabsf(g.dual_w - prev_w);
              if (d > max_step_d) max_step_d = d;
            }
            prev_w = g.dual_w;
          }
          prev_w = -1.0f;
          for (int ai = 180; ai <= 210; ai++) {
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
            mf[8] = 0.0f; mf[9] = 136.0f / 255.0f; mf[10] = 1.0f; mf[11] = (float)ai / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -122.0f; mf[21] = 20.0f;
            Grab g;
            CHECK(grab_of(&g, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            if (prev_w >= 0.0f) {
              float d = fabsf(g.dual_w - prev_w);
              if (d > max_step_t) max_step_t = d;
            }
            prev_w = g.dual_w;
          }
          printf("apple_render: v13_menu_morph_dual_w start=%.3f end=%.3f max_step=(L=%.4f,D=%.4f,T=%.4f)\n",
                 w_start, w_end, max_step_l, max_step_d, max_step_t);
          CHECK(w_start >= 0.80f && w_start <= 0.88f && w_end == 0.0f);
          CHECK(max_step_l <= 0.06f && max_step_d <= 0.06f && max_step_t <= 0.07f);
          // V13b: height-adaptive dual_w (44pt -> ~0.68, 62pt -> ~0.86), zero-frost sharp path (sg==0, k==1 at 2x),
          // and sp >= 2.4 -> k == 1 guard (non-dual blur=1.2pt at 2x -> k=1, sg>0.3).
          {
            Grab g44, g62, gclr;
            memset(mf, 0, sizeof mf);
            mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 132.0f; mf[3] = 44.0f; mf[4] = 22.0f;
            mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
            mf[8] = 32.0f / 255.0f; mf[9] = 32.0f / 255.0f; mf[10] = 32.0f / 255.0f; mf[11] = 0x67 / 255.0f;
            mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -123.0f; mf[21] = 20.0f;
            CHECK(grab_of(&g44, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            CHECK(g44.dual_scale == 1 && fabsf(g44.dual_w - 0.68f) < 0.01f && g44.k == 1 && g44.sg == 0.0f);
            mf[2] = 292.0f; mf[3] = 62.0f; mf[4] = 31.0f;
            CHECK(grab_of(&g62, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            CHECK(g62.dual_scale == 1 && fabsf(g62.dual_w - 0.86f) < 0.01f && g62.k == 1 && g62.sg == 0.0f);
            // Clear liquid glass (non-dual, blur auto-promoted to 1.2pt -> sp=2.4px at 2x -> k=1, sg>0.3)
            mf[2] = 100.0f; mf[3] = 44.0f; mf[4] = 22.0f; mf[7] = 0.0f;
            mf[8] = 1.0f; mf[9] = 1.0f; mf[10] = 1.0f; mf[11] = 0x1A / 255.0f;
            CHECK(grab_of(&gclr, mf, 0, 1, 1, VW * 2, VH * 2) == 1);
            CHECK(gclr.dual_scale == 0 && gclr.k == 1 && gclr.sg > 0.3f);
            printf("apple_render: v13_dual_k1 w44=%.3f w62=%.3f clr_k=%d clr_sg=%.2f\n",
                   g44.dual_w, g62.dual_w, gclr.k, gclr.sg);
            // V13c: effective-sigma continuity (no 1-frame sharpness pop) across menu morph (legacy + v9 3-anchor) & size sweep (14..20pt) at 2x & 3x.
            double max_morph_dsig = 0.0, min_morph_dsig = 0.0, max_sz_dsig = 0.0;
            double max_v9_dsig = 0.0, min_v9_dsig = 0.0;
            for (int sc_i = 2; sc_i <= 3; sc_i++) {
              mb_render_set_size(VW, VH, sc_i);
              at_scale = sc_i;
              double prev_se = -1.0;
              for (int si = 0; si <= 240; si++) {
                float t = (float)si / 240.0f;
                memset(mf, 0, sizeof mf);
                mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = 60.0f; mf[4] = 24.0f;
                mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f + 2.8f * t;
                mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
                mf[11] = (103.0f + 44.0f * t) / 255.0f;
                mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -124.0f; mf[21] = 20.0f;
                Grab gm;
                CHECK(grab_of(&gm, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
                double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
                double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
                double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
                if (prev_se >= 0.0) {
                  double d = se - prev_se;
                  if (fabs(d) > max_morph_dsig) max_morph_dsig = fabs(d);
                  if (d < min_morph_dsig) min_morph_dsig = d;
                }
                prev_se = se;
              }
              prev_se = -1.0;
              for (int si = 0; si <= 240; si++) {
                float t = (float)si / 240.0f;
                float u = t <= 0.5f ? t * 2.0f : (t - 0.5f) * 2.0f;
                float mb = t <= 0.5f ? (1.2f + 4.8f * u) : (6.0f + 8.0f * u);
                float ma = t <= 0.5f ? (103.0f + 13.0f * u) / 255.0f : (116.0f + 12.0f * u) / 255.0f;
                memset(mf, 0, sizeof mf);
                mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 44.0f + 207.0f * t; mf[3] = 44.0f + 214.0f * t; mf[4] = 22.0f + 10.0f * t;
                mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = mb;
                mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f;
                mf[11] = ma;
                mf[12] = 0.6f; mf[13] = 14.0f + 6.0f * t; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -126.0f; mf[21] = 20.0f - 4.0f * t;
                Grab gm;
                CHECK(grab_of(&gm, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
                double pre = gm.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gm.k)) / 3.0 + 1.0 / 6.0 : 0.0;
                double sgu = (gm.dual_scale && gm.k > 0) ? (gm.sg > 0.55f ? (double)gm.sg : 0.526) : (gm.sg > 0.3f ? (double)gm.sg : 0.0);
                double se = (double)(1 << gm.k) * sqrt(sgu * sgu + pre);
                if (prev_se >= 0.0) {
                  double d = se - prev_se;
                  if (fabs(d) > max_v9_dsig) max_v9_dsig = fabs(d);
                  if (d < min_v9_dsig) min_v9_dsig = d;
                }
                prev_se = se;
              }
              prev_se = -1.0;
              for (int si = 0; si <= 60; si++) {
                float dim = 14.0f + 6.0f * (float)si / 60.0f;
                memset(mf, 0, sizeof mf);
                mf[0] = 20.0f; mf[1] = 10.0f; mf[2] = 120.0f; mf[3] = dim; mf[4] = dim * 0.5f;
                mf[5] = 6.0f; mf[6] = 1.0f; mf[7] = 1.2f;
                mf[8] = 253.0f / 255.0f; mf[9] = 252.0f / 255.0f; mf[10] = 253.0f / 255.0f; mf[11] = 103.0f / 255.0f;
                mf[12] = 0.6f; mf[13] = 14.0f; mf[15] = 1.0f; mf[18] = (float)VW; mf[19] = (float)VH; mf[20] = -125.0f; mf[21] = 20.0f;
                Grab gs;
                CHECK(grab_of(&gs, mf, 0, 1, 1, VW * sc_i, VH * sc_i) == 1);
                double pre = gs.k > 0 ? 0.75 * (1.0 - pow(0.25, (double)gs.k)) / 3.0 + 1.0 / 6.0 : 0.0;
                double sgu = (gs.dual_scale && gs.k > 0) ? (gs.sg > 0.55f ? (double)gs.sg : 0.526) : (gs.sg > 0.3f ? (double)gs.sg : 0.0);
                double se = (double)(1 << gs.k) * sqrt(sgu * sgu + pre);
                if (prev_se >= 0.0) {
                  double d = fabs(se - prev_se);
                  if (d > max_sz_dsig) max_sz_dsig = d;
                }
                prev_se = se;
              }
            }
            mb_render_set_size(VW, VH, 2);
            at_scale = 2;
            printf("apple_render: v13c_sigma_cont max_morph_dsig=%.3f min_morph_dsig=%.3f v9_3anchor=(%.3f,%.3f) max_sz_dsig=%.3f\n",
                   max_morph_dsig, min_morph_dsig, max_v9_dsig, min_v9_dsig, max_sz_dsig);
            CHECK(min_morph_dsig >= -1e-4);
            CHECK(max_morph_dsig <= 0.30);
            CHECK(min_v9_dsig >= -1e-4);
            CHECK(max_v9_dsig <= 0.45);
            CHECK(max_sz_dsig <= 0.30);
          }
          // V14-Opus-Gates: (1) Tinted capsule dark outer contour <= 14; (2) Light Regular rim on black/mid-grey/cream;
          // (3) Clear pill on pure white has zero inner grey band (min_L >= 254).
          {
            mb_render_set_size(160, 80, 3);
            // (1) Tinted blue capsule on dark bg: outermost side pixel L <= 14
            double tb[2 * MB_INST];
            rect_at(tb, 0, 0, 160, 80, 0, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0, 0);
            rect_at(tb + MB_INST, 20, 18, 78, 44, 6, 0.0, 122.0 / 255.0, 1.0, -130);
            tb[MB_INST + 4] = 22.0; tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 1.2;
            tb[MB_INST + 11] = 0x99 / 255.0; tb[MB_INST + 12] = 0.6; tb[MB_INST + 13] = 14.0;
            tb[MB_INST + 15] = 1.0; tb[MB_INST + 21] = 20.0; tb[MB_INST + 22] = 0.06;
            glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
            mb_render_present(tb, 2, 28.0 / 255.0, 28.0 / 255.0, 30.0 / 255.0); present_drain();
            int aw = 0, ah = 0;
            uint8_t *pxt = read_texture(canvas, &aw, &ah);
            uint8_t *ts = A_PX(pxt, aw, 98 * 3, 40 * 3);
            double tint_side_L = 0.2126 * ts[2] + 0.7152 * ts[1] + 0.0722 * ts[0];
            free(pxt);
            // (2) Light Regular non-adaptive pill on pure black, mid-grey (0.5), and cream:
            double bg_vals[3][3] = { {0.0, 0.0, 0.0}, {0.5, 0.5, 0.5}, {244.0/255.0, 241.0/255.0, 234.0/255.0} };
            double top_d[3] = {0}, top2_d[3] = {0}, top_abs[3] = {0};
            for (int bi = 0; bi < 3; bi++) {
              double lr[2 * MB_INST];
              rect_at(lr, 0, 0, 160, 80, 0, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2], 0);
              rect_at(lr + MB_INST, 14, 18, 132, 44, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -131 - bi);
              lr[MB_INST + 4] = 22.0; lr[MB_INST + 6] = 1.0; lr[MB_INST + 7] = 1.2;
              lr[MB_INST + 11] = 0x67 / 255.0; lr[MB_INST + 12] = 0.6; lr[MB_INST + 13] = 14.0;
              lr[MB_INST + 15] = 1.0; lr[MB_INST + 21] = 20.0; lr[MB_INST + 22] = 0.06;
              glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
              mb_render_present(lr, 2, bg_vals[bi][0], bg_vals[bi][1], bg_vals[bi][2]); present_drain();
              uint8_t *pxl = read_texture(canvas, &aw, &ah);
              uint8_t *cm = A_PX(pxl, aw, 80 * 3, 40 * 3);
              uint8_t *c0 = A_PX(pxl, aw, 80 * 3, 18 * 3);
              uint8_t *c2 = A_PX(pxl, aw, 80 * 3, 18 * 3 + 2);
              double lm = 0.2126 * cm[2] + 0.7152 * cm[1] + 0.0722 * cm[0];
              double l0 = 0.2126 * c0[2] + 0.7152 * c0[1] + 0.0722 * c0[0];
              double l2 = 0.2126 * c2[2] + 0.7152 * c2[1] + 0.0722 * c2[0];
              top_d[bi] = l0 - lm; top2_d[bi] = l2 - lm; top_abs[bi] = l0;
              free(pxl);
            }
            // (3) Clear pill on pure white: no inner bevel shadow grey band (all interior rows >= 254)
            double cw[2 * MB_INST];
            rect_at(cw, 0, 0, 160, 80, 0, 1.0, 1.0, 1.0, 0);
            rect_at(cw + MB_INST, 20, 18, 100, 44, 6, 1.0, 1.0, 1.0, -135);
            cw[MB_INST + 4] = 22.0; cw[MB_INST + 6] = 1.0; cw[MB_INST + 7] = 0.0;
            cw[MB_INST + 11] = 0x1A / 255.0; cw[MB_INST + 12] = 0.6; cw[MB_INST + 13] = 14.0;
            cw[MB_INST + 15] = 1.0; cw[MB_INST + 21] = 16.0;
            glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
            mb_render_present(cw, 2, 1.0, 1.0, 1.0); present_drain();
            uint8_t *pxc = read_texture(canvas, &aw, &ah);
            double clr_min_L = 999.0;
            for (int py = 18 * 3 + 2; py <= 62 * 3 - 2; py++) {
              uint8_t *cp = A_PX(pxc, aw, 70 * 3, py);
              double L = 0.2126 * cp[2] + 0.7152 * cp[1] + 0.0722 * cp[0];
              if (L < clr_min_L) clr_min_L = L;
            }
            free(pxc);
            printf("apple_render: v14_opus_gates tint_side=%.1f blk_d=(+%.1f,+%.1f) mid_d=(+%.1f,+%.1f) crm=%.1f clr_min=%.1f\n",
                   tint_side_L, top_d[0], top2_d[0], top_d[1], top2_d[1], top_abs[2], clr_min_L);
            CHECK(tint_side_L <= 14.0);
            CHECK(top_d[0] <= 50.0 && top2_d[0] <= 28.0);
            CHECK(top_d[1] <= 38.0 && top2_d[1] <= 18.0);
            CHECK(top_abs[2] >= 252.0);
            CHECK(clr_min_L >= 254.0);
            // V14b-Scroll-Shimmer: measure 1px vertical scroll shift-invariance of 44pt Light Regular pill
            // over crisp dark text-like strokes (1pt, 1.5pt, 2pt bars on white) at 2x and 3x.
            for (int sc_i = 2; sc_i <= 3; sc_i++) {
              mb_render_set_size(160, 80, sc_i);
              uint8_t *fpx[2] = {NULL, NULL};
              int faw = 0, fah = 0;
              for (int fi = 0; fi < 2; fi++) {
                double dy = (double)fi / (double)sc_i;
                double sb[7 * MB_INST];
                rect_at(sb, 0, 0, 160, 80, 0, 1.0, 1.0, 1.0, 0);
                // Crisp dark horizontal strokes simulating text lines (1pt, 1.5pt, 2pt, 1pt, 2pt)
                rect_at(sb + 1 * MB_INST, 0, 24.0 + dy, 160, 1.0, 0, 0.08, 0.08, 0.08, 0);
                rect_at(sb + 2 * MB_INST, 0, 31.0 + dy, 160, 1.5, 0, 0.08, 0.08, 0.08, 0);
                rect_at(sb + 3 * MB_INST, 0, 39.0 + dy, 160, 2.0, 0, 0.08, 0.08, 0.08, 0);
                rect_at(sb + 4 * MB_INST, 0, 47.0 + dy, 160, 1.0, 0, 0.08, 0.08, 0.08, 0);
                rect_at(sb + 5 * MB_INST, 0, 54.0 + dy, 160, 2.0, 0, 0.08, 0.08, 0.08, 0);
                rect_at(sb + 6 * MB_INST, 14, 18, 132, 44, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -140 - sc_i * 2 - fi);
                sb[6 * MB_INST + 4] = 22.0; sb[6 * MB_INST + 6] = 1.0; sb[6 * MB_INST + 7] = 1.2;
                sb[6 * MB_INST + 11] = 0x67 / 255.0; sb[6 * MB_INST + 12] = 0.6; sb[6 * MB_INST + 13] = 14.0;
                sb[6 * MB_INST + 15] = 1.0; sb[6 * MB_INST + 21] = 20.0; sb[6 * MB_INST + 22] = 0.06;
                glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                mb_render_present(sb, 7, 1.0, 1.0, 1.0); present_drain();
                fpx[fi] = read_texture(canvas, &faw, &fah);
              }
              double max_d_flat = 0.0, sum2_flat = 0.0;
              int cnt_flat = 0;
              // Flat interior: x in [44..116]pt, y in [28..52]pt (away from pill refraction bevel)
              for (int py = 28 * sc_i; py < 52 * sc_i - 1; py++) {
                for (int px = 44 * sc_i; px < 116 * sc_i; px++) {
                  uint8_t *p0 = A_PX(fpx[0], faw, px, py);
                  uint8_t *p1 = A_PX(fpx[1], faw, px, py + 1);
                  double l0 = 0.2126 * p0[2] + 0.7152 * p0[1] + 0.0722 * p0[0];
                  double l1 = 0.2126 * p1[2] + 0.7152 * p1[1] + 0.0722 * p1[0];
                  double d = fabs(l1 - l0);
                  if (d > max_d_flat) max_d_flat = d;
                  sum2_flat += d * d;
                  cnt_flat++;
                }
              }
              double rms_flat = sqrt(sum2_flat / (double)(cnt_flat > 0 ? cnt_flat : 1));
              printf("apple_render: v14b_scroll_shimmer_%dx flat_max=%.2f flat_rms=%.2f\n", sc_i, max_d_flat, rms_flat);
              CHECK(max_d_flat <= 3.0);
              free(fpx[0]); free(fpx[1]);
            }
            // V14c-DualSlot-MidSg: 2x blur=2.1pt tint=0x67 falls in 0.3 < sg <= 0.55 (sg~0.438);
            // verify slot_fill keeps ltmp (wide ambient + 4-tap AA), not raw lv[1], across fresh & cached frames.
            {
              mb_render_set_size(160, 80, 2);
              at_scale = 2;
              float mf21[MB_INST];
              memset(mf21, 0, sizeof mf21);
              mf21[0] = 14.0f; mf21[1] = 18.0f; mf21[2] = 132.0f; mf21[3] = 44.0f; mf21[4] = 22.0f;
              mf21[5] = 6.0f; mf21[6] = 1.0f; mf21[7] = 2.1f;
              mf21[8] = 253.0f / 255.0f; mf21[9] = 252.0f / 255.0f; mf21[10] = 253.0f / 255.0f; mf21[11] = 0x67 / 255.0f;
              mf21[12] = 0.6f; mf21[13] = 14.0f; mf21[15] = 1.0f; mf21[18] = 160.0f; mf21[19] = 80.0f; mf21[20] = -149.0f; mf21[21] = 20.0f;
              Grab g21;
              CHECK(grab_of(&g21, mf21, 0, 1, 1, 320, 160) == 1);
              CHECK(g21.dual_scale == 1 && g21.k == 1 && g21.sg > 0.30f && g21.sg <= 0.55f);
              CHECK(grab_blurred_ref(&g21) == &ltmp);
              double s21[3 * MB_INST];
              rect_at(s21, 0, 0, 160, 80, 0, 1.0, 1.0, 1.0, 0);
              rect_at(s21 + MB_INST, 74, 0, 12, 80, 0, 0.05, 0.05, 0.05, 0);
              rect_at(s21 + 2 * MB_INST, 14, 18, 132, 44, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -149);
              s21[2 * MB_INST + 4] = 22.0; s21[2 * MB_INST + 6] = 1.0; s21[2 * MB_INST + 7] = 2.1;
              s21[2 * MB_INST + 11] = 0x67 / 255.0; s21[2 * MB_INST + 12] = 0.6; s21[2 * MB_INST + 13] = 14.0;
              s21[2 * MB_INST + 15] = 1.0; s21[2 * MB_INST + 21] = 20.0; s21[2 * MB_INST + 22] = 0.06;
              glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
              mb_render_present(s21, 3, 1.0, 1.0, 1.0); present_drain();
              int aw1 = 0, ah1 = 0, aw2 = 0, ah2 = 0;
              uint8_t *p1 = read_texture(canvas, &aw1, &ah1);
              // Second frame hits slot cache (dirty touches glass)
              mb_host_render_dirty(0, 0, 160, 80);
              mb_render_present(s21, 3, 1.0, 1.0, 1.0); present_drain();
              uint8_t *p2 = read_texture(canvas, &aw2, &ah2);
              uint8_t *cb = A_PX(p1, aw1, 80 * 2, 40 * 2);
              uint8_t *cw1 = A_PX(p1, aw1, 50 * 2, 40 * 2);
              double l_bar = 0.2126 * cb[2] + 0.7152 * cb[1] + 0.0722 * cb[0];
              double l_wh = 0.2126 * cw1[2] + 0.7152 * cw1[1] + 0.0722 * cw1[0];
              int cache_diff = 0;
              for (int py = 24 * 2; py < 56 * 2; py++) {
                for (int px = 30 * 2; px < 130 * 2; px++) {
                  uint8_t *a1 = A_PX(p1, aw1, px, py), *a2 = A_PX(p2, aw2, px, py);
                  for (int c = 0; c < 3; c++) {
                    int d = abs((int)a1[c] - (int)a2[c]);
                    if (d > cache_diff) cache_diff = d;
                  }
                }
              }
              printf("apple_render: v14c_dual_slot_midsg sg=%.3f bar_L=%.1f wh_L=%.1f diff=%.1f cache_diff=%d\n",
                     g21.sg, l_bar, l_wh, l_wh - l_bar, cache_diff);
              CHECK(l_bar >= 185.0 && (l_wh - l_bar) <= 65.0 && cache_diff == 0);
              free(p1); free(p2);
            }
            // V15-Unified-V9-Gates: (1) 2x blur=4pt (k=2) flat 0.5 grey stays ~195 (no sRGB/linear mix corruption);
            // (2) Light 0x67 over 10% white bars on pure black stays <= 150 (no linear over-bloom on dark backdrop);
            // (3) Adaptive 0xFF solid over black vs white is identical (<= 1 LSB);
            // (4) Shared capture Light+Dark vs Dark+Light order-invariant (0 LSB diff).
            {
              int aw = 0, ah = 0;
              mb_render_set_size(160, 80, 2);
              double fg[2 * MB_INST];
              rect_at(fg, 0, 0, 160, 80, 0, 0.5, 0.5, 0.5, 0);
              rect_at(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -151);
              fg[MB_INST + 4] = 31.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 4.0;
              fg[MB_INST + 11] = 0x67 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
              fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
              glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
              mb_render_present(fg, 2, 0.5, 0.5, 0.5); present_drain();
              uint8_t *pfg = read_texture(canvas, &aw, &ah);
              uint8_t *cfg = A_PX(pfg, aw, 80 * 2, 40 * 2);
              int k2_g = cfg[1];
              free(pfg);

              mb_render_set_size(160, 80, 3);
              double wb[6 * MB_INST];
              rect_at(wb, 0, 0, 160, 80, 0, 0.0, 0.0, 0.0, 0);
              for (int bi = 0; bi < 4; bi++) rect_at(wb + (1 + bi) * MB_INST, 0, 10 + bi * 20, 160, 2.0, 0, 1.0, 1.0, 1.0, 0);
              rect_at(wb + 5 * MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -152);
              wb[5 * MB_INST + 4] = 31.0; wb[5 * MB_INST + 6] = 1.0; wb[5 * MB_INST + 7] = 1.2;
              wb[5 * MB_INST + 11] = 0x67 / 255.0; wb[5 * MB_INST + 12] = 0.6; wb[5 * MB_INST + 13] = 14.0;
              wb[5 * MB_INST + 15] = 1.0; wb[5 * MB_INST + 21] = 20.0;
              glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
              mb_render_present(wb, 6, 0.0, 0.0, 0.0); present_drain();
              uint8_t *pwb = read_texture(canvas, &aw, &ah);
              uint8_t *cwb = A_PX(pwb, aw, 80 * 3, 40 * 3);
              int dark_bar_g = cwb[1];
              free(pwb);

              mb_render_set_size(160, 80, 2);
              int ad_diff = 0;
              uint8_t ad_c[2][3];
              for (int bi = 0; bi < 2; bi++) {
                double bgv = bi ? 1.0 : 0.0;
                rect_at(fg, 0, 0, 160, 80, 0, bgv, bgv, bgv, 0);
                rect_at(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -153 - bi);
                fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 1.2;
                fg[MB_INST + 11] = 1.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 14.0;
                fg[MB_INST + 14] = -1.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 20.0;
                glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                mb_render_present(fg, 2, bgv, bgv, bgv); present_drain();
                uint8_t *pad = read_texture(canvas, &aw, &ah);
                uint8_t *cad = A_PX(pad, aw, 80 * 2, 40 * 2);
                ad_c[bi][0] = cad[2]; ad_c[bi][1] = cad[1]; ad_c[bi][2] = cad[0];
                free(pad);
              }
              for (int c = 0; c < 3; c++) { int d = abs((int)ad_c[0][c] - (int)ad_c[1][c]); if (d > ad_diff) ad_diff = d; }

              uint8_t *sord[2];
              for (int oi = 0; oi < 2; oi++) {
                double so[4 * MB_INST];
                rect_at(so, 0, 0, 160, 80, 0, 0.95, 0.94, 0.91, 0);
                rect_at(so + MB_INST, 0, 36, 160, 8, 0, 0.05, 0.05, 0.05, 0);
                int li = oi == 0 ? 2 : 3, di = oi == 0 ? 3 : 2;
                rect_at(so + li * MB_INST, 8, 9, 64, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -156 - oi);
                so[li * MB_INST + 4] = 31.0; so[li * MB_INST + 6] = 1.0; so[li * MB_INST + 7] = 1.2;
                so[li * MB_INST + 11] = 0x67/255.0; so[li * MB_INST + 12] = 0.6; so[li * MB_INST + 13] = 14.0;
                so[li * MB_INST + 15] = 1.0; so[li * MB_INST + 21] = 20.0;
                rect_at(so + di * MB_INST, 88, 9, 64, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -156 - oi);
                so[di * MB_INST + 4] = 31.0; so[di * MB_INST + 6] = 1.0; so[di * MB_INST + 7] = 1.2;
                so[di * MB_INST + 11] = 0x67/255.0; so[di * MB_INST + 12] = 0.6; so[di * MB_INST + 13] = 14.0;
                so[di * MB_INST + 15] = 1.0; so[di * MB_INST + 21] = 20.0;
                glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                mb_render_present(so, 4, 0.95, 0.94, 0.91); present_drain();
                sord[oi] = read_texture(canvas, &aw, &ah);
              }
              int ord_diff = 0;
              for (int i = 0; i < aw * ah * 4; i++) { int d = abs((int)sord[0][i] - (int)sord[1][i]); if (d > ord_diff) ord_diff = d; }
              free(sord[0]); free(sord[1]);
              // (5) Dark 0x80 grayscale sweep Y=0..1 (21 steps): strictly monotonic, white <= 102, and non-flatline slope
              int dark_mono_ok = 1;
              double prev_dl = -1.0, dark_y20_L = 0.0, dark_y40_L = 0.0, dark_mid_L = 0.0, dark_wt_L2 = 0.0;
              for (int gi = 0; gi <= 20; gi++) {
                double gv = (double)gi / 20.0;
                rect_at(fg, 0, 0, 160, 80, 0, gv, gv, gv, 0);
                rect_at(fg + MB_INST, 14, 9, 132, 62, 6, 32.0/255.0, 32.0/255.0, 32.0/255.0, -160 - gi);
                fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
                fg[MB_INST + 11] = 0x80 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
                fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
                glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                mb_render_present(fg, 2, gv, gv, gv); present_drain();
                uint8_t *pd = read_texture(canvas, &aw, &ah);
                uint8_t *cd = A_PX(pd, aw, 80 * 2, 40 * 2);
                double dl = 0.2126 * cd[2] + 0.7152 * cd[1] + 0.0722 * cd[0];
                if (prev_dl >= 0.0 && dl < prev_dl - 0.1) dark_mono_ok = 0;
                prev_dl = dl;
                if (gi == 4) dark_y20_L = dl;
                if (gi == 8) dark_y40_L = dl;
                if (gi == 11) dark_mid_L = dl;
                if (gi == 20) dark_wt_L2 = dl;
                free(pd);
              }
              // (5b) Light 0x80 grayscale sweep Y=0..1 (21 steps): strictly monotonic, black >= 198, and non-flatline slope
              int light_mono_ok = 1;
              double prev_ll = -1.0, light_blk_L = 0.0, light_y60_L = 0.0, light_y80_L = 0.0;
              for (int gi = 0; gi <= 20; gi++) {
                double gv = (double)gi / 20.0;
                rect_at(fg, 0, 0, 160, 80, 0, gv, gv, gv, 0);
                rect_at(fg + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -200 - gi);
                fg[MB_INST + 4] = 24.0; fg[MB_INST + 6] = 1.0; fg[MB_INST + 7] = 14.0;
                fg[MB_INST + 11] = 0x80 / 255.0; fg[MB_INST + 12] = 0.6; fg[MB_INST + 13] = 20.0;
                fg[MB_INST + 14] = 0.0; fg[MB_INST + 15] = 1.0; fg[MB_INST + 21] = 16.0;
                glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                mb_render_present(fg, 2, gv, gv, gv); present_drain();
                uint8_t *pl = read_texture(canvas, &aw, &ah);
                uint8_t *cl = A_PX(pl, aw, 80 * 2, 40 * 2);
                double ll = 0.2126 * cl[2] + 0.7152 * cl[1] + 0.0722 * cl[0];
                if (prev_ll >= 0.0 && ll < prev_ll - 0.1) light_mono_ok = 0;
                prev_ll = ll;
                if (gi == 0) light_blk_L = ll;
                if (gi == 12) light_y60_L = ll;
                if (gi == 16) light_y80_L = ll;
                free(pl);
              }
              // (5c) Light 0x80 selected-row Hover (#24272B0F) over pure black & vivid blue (#007AFF): accent_text (#982E01) WCAG >= 3.0:1
              double chk_cr_blk = 0.0, chk_cr_blu = 0.0;
              {
                double row_b[3 * MB_INST];
                double acc_l = 0.2126 * pow((0x98/255.0 + 0.055)/1.055, 2.4)
                             + 0.7152 * pow((0x2E/255.0 + 0.055)/1.055, 2.4)
                             + 0.0722 * ((0x01/255.0) / 12.92);
                for (int bi = 0; bi < 2; bi++) {
                  double br = 0.0, bg = bi ? (0x7A/255.0) : 0.0, bb = bi ? 1.0 : 0.0;
                  rect_at(row_b, 0, 0, 160, 80, 0, br, bg, bb, 0);
                  rect_at(row_b + MB_INST, 14, 9, 132, 62, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -230 - bi);
                  row_b[MB_INST + 4] = 24.0; row_b[MB_INST + 6] = 1.0; row_b[MB_INST + 7] = 14.0;
                  row_b[MB_INST + 11] = 0x80 / 255.0; row_b[MB_INST + 12] = 0.6; row_b[MB_INST + 13] = 20.0;
                  row_b[MB_INST + 14] = 0.0; row_b[MB_INST + 15] = 1.0; row_b[MB_INST + 21] = 16.0;
                  rect_at(row_b + 2 * MB_INST, 24, 22, 112, 36, 0, 0x24/255.0, 0x27/255.0, 0x2B/255.0, 0);
                  row_b[2 * MB_INST + 4] = 14.0; row_b[2 * MB_INST + 11] = 0x0F / 255.0;
                  glass_forget(); mb_host_render_dirty(0, 0, 160, 80);
                  mb_render_present(row_b, 3, br, bg, bb); present_drain();
                  uint8_t *pr = read_texture(canvas, &aw, &ah);
                  uint8_t *crp = A_PX(pr, aw, 80 * 2, 40 * 2);
                  double cr_r = crp[2] / 255.0, cr_g = crp[1] / 255.0, cr_b = crp[0] / 255.0;
                  double lr = (cr_r <= 0.04045) ? cr_r / 12.92 : pow((cr_r + 0.055) / 1.055, 2.4);
                  double lg = (cr_g <= 0.04045) ? cr_g / 12.92 : pow((cr_g + 0.055) / 1.055, 2.4);
                  double lb = (cr_b <= 0.04045) ? cr_b / 12.92 : pow((cr_b + 0.055) / 1.055, 2.4);
                  double row_l = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
                  double hi = row_l > acc_l ? row_l : acc_l, lo = row_l > acc_l ? acc_l : row_l;
                  double crv = (hi + 0.05) / (lo + 0.05);
                  if (bi == 0) chk_cr_blk = crv; else chk_cr_blu = crv;
                  free(pr);
                }
              }
              // (6) Overlay outside-shadow top-edge vertical profile: smooth monotonic ramp, zero >=3 LSB cutout gap
              mb_render_set_size(200, 160, 3);
              double sh[3 * MB_INST];
              rect_at(sh, 0, 0, 200, 160, 0, 244.0/255.0, 241.0/255.0, 234.0/255.0, 0);
              rect_at(sh + MB_INST, 20, 40 + 6, 160, 100, 2, 0.0, 0.0, 0.0, 0);
              sh[MB_INST + 4] = 24.0; sh[MB_INST + 7] = 14.0; sh[MB_INST + 11] = 0x18 / 255.0;
              sh[MB_INST + 12] = 1.0; sh[MB_INST + 13] = 6.0;
              sh[MB_INST + 36] = 24.0; sh[MB_INST + 37] = 24.0; sh[MB_INST + 38] = 24.0; sh[MB_INST + 39] = 24.0;
              rect_at(sh + 2 * MB_INST, 20, 40, 160, 100, 6, 253.0/255.0, 252.0/255.0, 253.0/255.0, -190);
              sh[2 * MB_INST + 4] = 24.0; sh[2 * MB_INST + 6] = 1.0; sh[2 * MB_INST + 7] = 14.0;
              sh[2 * MB_INST + 11] = 0x80 / 255.0; sh[2 * MB_INST + 12] = 0.6; sh[2 * MB_INST + 13] = 20.0;
              sh[2 * MB_INST + 15] = 1.0; sh[2 * MB_INST + 21] = 16.0;
              sh[2 * MB_INST + 36] = 24.0; sh[2 * MB_INST + 37] = 24.0; sh[2 * MB_INST + 38] = 24.0; sh[2 * MB_INST + 39] = 24.0;
              glass_forget(); mb_host_render_dirty(0, 0, 200, 160);
              mb_render_present(sh, 3, 244.0/255.0, 241.0/255.0, 234.0/255.0); present_drain();
              uint8_t *psh = read_texture(canvas, &aw, &ah);
              double sh_max_jump = 0.0;
              double sh_prev = -1.0;
              // Profile from 20pt above menu top (y=20 -> py=60) down to 2pt above menu top (y=38 -> py=114)
              for (int py = 60; py <= 114; py++) {
                uint8_t *sp = A_PX(psh, aw, 100 * 3, py);
                double sl = 0.2126 * sp[2] + 0.7152 * sp[1] + 0.0722 * sp[0];
                if (sh_prev >= 0.0 && (sl - sh_prev) > sh_max_jump) sh_max_jump = sl - sh_prev;
                sh_prev = sl;
              }
              free(psh);
              printf("apple_render: v15_unified_v9 k2_g=%d dark_bar_g=%d ad_ff_diff=%d ord_diff=%d dark_mono=%d d20=%.1f d40=%.1f mid55=%.1f wt=%.1f light_mono=%d blk=%.1f l60=%.1f l80=%.1f chk_blk=%.2f chk_blu=%.2f sh_jump=%.2f\n",
                     k2_g, dark_bar_g, ad_diff, ord_diff, dark_mono_ok, dark_y20_L, dark_y40_L, dark_mid_L, dark_wt_L2, light_mono_ok, light_blk_L, light_y60_L, light_y80_L, chk_cr_blk, chk_cr_blu, sh_max_jump);
              CHECK(abs(k2_g - 195) <= 2);
              CHECK(dark_bar_g <= 150);
              CHECK(ad_diff <= 1);
              CHECK(ord_diff == 0);
              CHECK(dark_mono_ok == 1 && dark_wt_L2 <= 102.0 && (dark_wt_L2 - dark_y40_L) >= 6.0 && (dark_wt_L2 - dark_y20_L) >= 24.0);
              CHECK(light_mono_ok == 1 && light_blk_L >= 198.0 && (light_y60_L - light_blk_L) >= 10.0 && (light_y80_L - light_blk_L) >= 26.0);
              CHECK(chk_cr_blk >= 3.0 && chk_cr_blu >= 3.0);
              CHECK(sh_max_jump < 2.5);
            }
            mb_render_set_size(160, 80, 2);
          }
        }
        #undef A_PX
        mb_render_set_size(400, 300, 2);
      }

      // Perf-51: Dark-mode atomic (settling==0 on frame 1 + origL<0.5 + kind 0 pad_w<0 + 1<->2 switch),
      // top-bar donor delegation (tight back pill capture + CR>=4.5), 33rd cold capture donor pin, lens counterexample.
      {
        mb_render_set_size(400, 300, 2);
        static const uint8_t solid16[16] = {
          255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255
        };
        [atlas replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:solid16 bytesPerRow:4];
        double at_sz = (double)atlas.width;

        // 1. Dark-mode atomic convergence
        glass_forget();
        mb_render_set_fixed_dt(1.0 / 60.0);
        double dk[4 * MB_INST];
        rect_at(dk, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        rect_at(dk + MB_INST, 20, 20, 120, 60, 6, 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, -251);
        dk[MB_INST + 4] = 16.0; dk[MB_INST + 6] = 1.0; dk[MB_INST + 7] = 1.0;
        dk[MB_INST + 11] = 0x67 / 255.0; dk[MB_INST + 13] = 4.0; dk[MB_INST + 14] = -1.0; dk[MB_INST + 15] = 1.0;
        rect_at(dk + 2 * MB_INST, 36, 38, 24, 24, 7, 0.2, 0.2, 0.2, 0);
        dk[2 * MB_INST + 14] = 4.0 / at_sz; dk[2 * MB_INST + 15] = 4.0 / at_sz;
        dk[2 * MB_INST + 21] = 80.0; dk[2 * MB_INST + 22] = 50.0; dk[2 * MB_INST + 23] = 60.0;
        rect_at(dk + 3 * MB_INST, 84, 38, 30, 24, 0, 0.1, 0.1, 0.1, 0);
        dk[3 * MB_INST + 11] = 0.18;
        dk[3 * MB_INST + 21] = 80.0; dk[3 * MB_INST + 22] = 50.0; dk[3 * MB_INST + 23] = -60.0;

        mb_render_present(dk, 4, 1.0, 1.0, 1.0);
        present_drain();
        CHECK(mb_render_adaptive_settling() == 0);

        // Flip white -> black: frame 1 must immediately settle and match frame 15
        rect_at(dk, 0, 0, 400, 300, 0, 0.0, 0.0, 0.0, 0);
        mb_render_present(dk, 4, 0.0, 0.0, 0.0);
        present_drain();
        CHECK(mb_render_adaptive_settling() == 0);
        int pw = 0, ph = 0;
        uint8_t *px1 = read_texture(canvas, &pw, &ph);
        for (int k = 0; k < 15; k++) {
          mb_render_present(dk, 4, 0.0, 0.0, 0.0);
          present_drain();
        }
        uint8_t *px15 = read_texture(canvas, &pw, &ph);
        CHECK(memcmp(px1, px15, (size_t)pw * ph * 4) == 0);
        free(px1); free(px15);

        // 1 <-> 2 mode switch over white backdrop
        rect_at(dk, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
        mb_render_present(dk, 4, 1.0, 1.0, 1.0); present_drain();
        CHECK(mb_render_adaptive_settling() == 0);
        dk[MB_INST + 11] = 0xA8 / 255.0;
        mb_render_present(dk, 4, 1.0, 1.0, 1.0); present_drain();
        CHECK(mb_render_adaptive_settling() == 0);
        uint8_t *m2_1 = read_texture(canvas, &pw, &ph);
        for (int k = 0; k < 8; k++) { mb_render_present(dk, 4, 1.0, 1.0, 1.0); present_drain(); }
        uint8_t *m2_8 = read_texture(canvas, &pw, &ph);
        CHECK(memcmp(m2_1, m2_8, (size_t)pw * ph * 4) == 0);
        free(m2_1); free(m2_8);
        mb_render_set_fixed_dt(0.0);

        // 2. Top-bar donor delegation hit test
        glass_forget();
        for (int dark_bg = 0; dark_bg <= 1; dark_bg++) {
          double bgv = dark_bg ? 0.06 : 0.94;
          double tb[4 * MB_INST];
          rect_at(tb, 0, 0, 400, 300, 0, bgv, bgv, bgv, 0);
          rect_at(tb + MB_INST, 0, 0, 400, 96, 5, 0, 0, 0, -261);
          tb[MB_INST + 6] = 1.0; tb[MB_INST + 7] = 8.0; tb[MB_INST + 11] = 0.0; tb[MB_INST + 15] = 1.0;
          tb[MB_INST + 22] = -1.0; tb[MB_INST + 54] = 96.0; tb[MB_INST + 55] = 48.0;
          rect_at(tb + 2 * MB_INST, 12, 28, 40, 40, 6, 0.14, 0.14, 0.15, -262);
          tb[2 * MB_INST + 4] = 20.0; tb[2 * MB_INST + 6] = 1.0; tb[2 * MB_INST + 7] = 1.4;
          tb[2 * MB_INST + 11] = 0.4; tb[2 * MB_INST + 14] = -1.0; tb[2 * MB_INST + 15] = 1.0;
          tb[2 * MB_INST + 21] = 8.0; tb[2 * MB_INST + 23] = 4.0;
          rect_at(tb + 3 * MB_INST, 120, 34, 24, 24, 7, 0.9, 0.9, 0.9, 0);
          tb[3 * MB_INST + 14] = 4.0 / at_sz; tb[3 * MB_INST + 15] = 4.0 / at_sz;
          tb[3 * MB_INST + 23] = -16.0;
          mb_render_present(tb, 4, bgv, bgv, bgv);
          present_drain();
          CHECK(donor_delegated_count == 1);
          CHECK(donor_of_buf[3] == -261);
          Grab gm_del, gm_raw;
          CHECK(grab_of_with_donors(&gm_del, last_inst, 2, 3, 4, 800, 600, donor_of_buf) == 1);
          CHECK(grab_of(&gm_raw, last_inst, 2, 3, 4, 800, 600) == 1);
          CHECK(gm_del.w < gm_raw.w);
          uint8_t *px = read_texture(canvas, &pw, &ph);
          uint8_t *tp = px + ((size_t)(46 * 2) * pw + 132 * 2) * 4;
          double fg_lin = pow(tp[2] / 255.0, 2.2); // BGRA
          double bg_lin = pow(bgv, 2.2);
          double cr = (fmax(fg_lin, bg_lin) + 0.05) / (fmin(fg_lin, bg_lin) + 0.05);
          CHECK(cr >= 4.5);
          free(px);
        }

        // 3. 33rd cold capture donor pin test over opposite-brightness white region (0 LSB diff on title, blurs >= 33)
        {
          glass_forget();
          double ref[5 * MB_INST];
          rect_at(ref, 0, 0, 400, 300, 0, 1.0, 1.0, 1.0, 0);
          rect_at(ref + MB_INST, 96, 0, 304, 100, 0, 0.05, 0.05, 0.05, 0);
          rect_at(ref + 2 * MB_INST, 0, 0, 400, 96, 5, 0, 0, 0, -270);
          ref[2 * MB_INST + 6] = 1.0; ref[2 * MB_INST + 7] = 8.0; ref[2 * MB_INST + 11] = 0.0; ref[2 * MB_INST + 15] = 1.0;
          ref[2 * MB_INST + 22] = -1.0; ref[2 * MB_INST + 54] = 96.0; ref[2 * MB_INST + 55] = 48.0;
          rect_at(ref + 3 * MB_INST, 12, 28, 40, 40, 6, 0.14, 0.14, 0.15, -271);
          ref[3 * MB_INST + 4] = 20.0; ref[3 * MB_INST + 6] = 1.0; ref[3 * MB_INST + 7] = 1.4;
          ref[3 * MB_INST + 11] = 0.4; ref[3 * MB_INST + 14] = -1.0; ref[3 * MB_INST + 15] = 1.0;
          ref[3 * MB_INST + 21] = 8.0; ref[3 * MB_INST + 23] = 4.0;
          rect_at(ref + 4 * MB_INST, 120, 34, 24, 24, 7, 0.2, 0.2, 0.2, 0);
          ref[4 * MB_INST + 14] = 4.0 / at_sz; ref[4 * MB_INST + 15] = 4.0 / at_sz;
          ref[4 * MB_INST + 23] = -16.0;
          mb_render_present(ref, 5, 1.0, 1.0, 1.0); present_drain();
          int pw = 0, ph = 0;
          uint8_t *ref_px = read_texture(canvas, &pw, &ph);

          glass_forget();
          int b0 = blurs_made;
          double *st = calloc(36 * MB_INST, sizeof(double));
          memcpy(st, ref, 3 * MB_INST * sizeof(double));
          for (int i = 0; i < 31; i++) {
            double *g = st + (size_t)(3 + i) * MB_INST;
            rect_at(g, 10 + (i % 10) * 36, 110 + (i / 10) * 44, 28, 28, 5, 0.5, 0.5, 0.5, -(280 + i));
            g[6] = 1.0; g[7] = 2.0; g[11] = 0.2; g[15] = 1.0;
          }
          memcpy(st + 34 * MB_INST, ref + 3 * MB_INST, 2 * MB_INST * sizeof(double));
          mb_render_present(st, 36, 1.0, 1.0, 1.0); present_drain();
          CHECK(donor_delegated_count == 1);
          CHECK(blurs_made - b0 >= 33);
          uint8_t *st_px = read_texture(canvas, &pw, &ph);
          for (int y = 34 * 2; y < 58 * 2; y++) {
            for (int x = 120 * 2; x < 144 * 2; x++) {
              size_t off = ((size_t)y * pw + x) * 4;
              CHECK(ref_px[off + 0] == st_px[off + 0] && ref_px[off + 1] == st_px[off + 1] &&
                    ref_px[off + 2] == st_px[off + 2]);
            }
          }
          uint8_t *tc = st_px + ((size_t)(46 * 2) * pw + 132 * 2) * 4;
          CHECK(tc[2] > 180 && tc[1] > 180 && tc[0] > 180);
          free(ref_px); free(st_px); free(st);
        }

        // 3b. Textured-backdrop top-bar delegation ON vs forced OFF (donor_of=NULL) pixel parity
        {
          glass_forget();
          double tx[11 * MB_INST];
          for (int si = 0; si < 8; si++) {
            double sv = (si & 1) ? 0.95 : 0.05;
            rect_at(tx + si * MB_INST, si * 50, 0, 50, 300, 0, sv, sv, sv, 0);
          }
          rect_at(tx + 8 * MB_INST, 0, 0, 400, 96, 5, 0, 0, 0, -275);
          tx[8 * MB_INST + 6] = 1.0; tx[8 * MB_INST + 7] = 8.0; tx[8 * MB_INST + 11] = 0.0; tx[8 * MB_INST + 15] = 1.0;
          tx[8 * MB_INST + 22] = -1.0; tx[8 * MB_INST + 54] = 96.0; tx[8 * MB_INST + 55] = 48.0;
          rect_at(tx + 9 * MB_INST, 12, 28, 40, 40, 6, 0.14, 0.14, 0.15, -276);
          tx[9 * MB_INST + 4] = 20.0; tx[9 * MB_INST + 6] = 1.0; tx[9 * MB_INST + 7] = 1.4;
          tx[9 * MB_INST + 11] = 0.4; tx[9 * MB_INST + 14] = -1.0; tx[9 * MB_INST + 15] = 1.0;
          tx[9 * MB_INST + 21] = 8.0; tx[9 * MB_INST + 23] = 4.0;
          // Bare title over dark stripe x=100..150
          rect_at(tx + 10 * MB_INST, 112, 34, 24, 24, 7, 0.9, 0.9, 0.9, 0);
          tx[10 * MB_INST + 14] = 4.0 / at_sz; tx[10 * MB_INST + 15] = 4.0 / at_sz;
          tx[10 * MB_INST + 23] = -16.0;

          int pw = 0, ph = 0;
          donor_force_off = 0;
          mb_render_present(tx, 10, 0.05, 0.05, 0.05); present_drain();
          uint8_t *px_bg = read_texture(canvas, &pw, &ph);

          glass_forget();
          shown_ok = 0;
          donor_force_off = 0;
          mb_render_present(tx, 11, 0.05, 0.05, 0.05); present_drain();
          CHECK(donor_delegated_count == 1);
          uint8_t *px_on = read_texture(canvas, &pw, &ph);

          glass_forget();
          shown_ok = 0;
          donor_force_off = 1;
          mb_render_present(tx, 11, 0.05, 0.05, 0.05); present_drain();
          CHECK(donor_delegated_count == 0);
          uint8_t *px_off = read_texture(canvas, &pw, &ph);
          donor_force_off = 0;

          int max_ch_diff = 0;
          for (int y = 34 * 2; y < 58 * 2; y++) {
            for (int x = 112 * 2; x < 136 * 2; x++) {
              size_t off = ((size_t)y * pw + x) * 4;
              for (int c = 0; c < 3; c++) {
                int d = abs((int)px_on[off + c] - (int)px_off[off + c]);
                if (d > max_ch_diff) max_ch_diff = d;
              }
            }
          }
          size_t ctr_off = ((size_t)(46 * 2) * pw + 124 * 2) * 4;
          uint8_t *c_bg = px_bg + ctr_off;
          uint8_t *c_on = px_on + ctr_off;
          uint8_t *c_off = px_off + ctr_off;
          double y_bg = wcag_luma_u8(c_bg[2], c_bg[1], c_bg[0]);
          double y_on = wcag_luma_u8(c_on[2], c_on[1], c_on[0]);
          double y_off = wcag_luma_u8(c_off[2], c_off[1], c_off[0]);
          double cr_on = (fmax(y_on, y_bg) + 0.05) / (fmin(y_on, y_bg) + 0.05);
          double cr_off = (fmax(y_off, y_bg) + 0.05) / (fmin(y_off, y_bg) + 0.05);
          printf("apple_render: perf-51 textured parity cr_on=%.2f cr_off=%.2f max_ch_diff=%d bg=(%u,%u,%u)\n",
                 cr_on, cr_off, max_ch_diff, c_bg[2], c_bg[1], c_bg[0]);
          CHECK(max_ch_diff <= 1);
          CHECK(cr_on >= 4.5 && cr_off >= 4.5);
          free(px_bg); free(px_on); free(px_off);
        }

        // 4. Lens subtree counterexample
        {
          glass_forget();
          double ln[5 * MB_INST];
          rect_at(ln, 0, 0, 400, 300, 0, 0.05, 0.05, 0.05, 0);
          rect_at(ln + MB_INST, 0, 0, 400, 96, 8, 1, 1, 1, 0);
          ln[MB_INST + 7] = 2.0; ln[MB_INST + 11] = 1.0; ln[MB_INST + 12] = 1.0; ln[MB_INST + 15] = 1.0;
          rect_at(ln + 2 * MB_INST, 0, 0, 400, 96, 5, 0, 0, 0, -320);
          ln[2 * MB_INST + 6] = 1.0; ln[2 * MB_INST + 7] = 8.0; ln[2 * MB_INST + 11] = 0.0; ln[2 * MB_INST + 15] = 1.0;
          ln[2 * MB_INST + 22] = -1.0; ln[2 * MB_INST + 54] = 96.0; ln[2 * MB_INST + 55] = 48.0;
          rect_at(ln + 3 * MB_INST, 12, 28, 40, 40, 6, 0.14, 0.14, 0.15, -321);
          ln[3 * MB_INST + 4] = 20.0; ln[3 * MB_INST + 6] = 1.0; ln[3 * MB_INST + 7] = 1.4;
          ln[3 * MB_INST + 11] = 0.4; ln[3 * MB_INST + 14] = -1.0; ln[3 * MB_INST + 15] = 1.0;
          ln[3 * MB_INST + 21] = 8.0; ln[3 * MB_INST + 23] = 4.0;
          rect_at(ln + 4 * MB_INST, 120, 34, 24, 24, 7, 0.2, 0.2, 0.2, 0);
          ln[4 * MB_INST + 14] = 4.0 / at_sz; ln[4 * MB_INST + 15] = 4.0 / at_sz;
          ln[4 * MB_INST + 23] = -16.0;
          mb_render_present(ln, 5, 0.05, 0.05, 0.05); present_drain();
          CHECK(donor_delegated_count == 0);
        }
        printf("apple_render: perf-51 ok\n");
      }

      // Liquid glass (kind 6) over a native view's transparent hole (kind 9, e.g. a remote screen video stream):
      // glass_through must register a CABackdropLayer frost (falling back to uniform radius b[4] when b[36..39] are 0)
      // and the kind 6 shader must output translucent premultiplied alpha rather than treating the (0,0,0,0) hole as
      // opaque black (which turned Light 0xFDFCFD80 cards into flat 202/255 grey slabs and flipped adaptive light
      // glass to dark glass).
      {
        mb_render_set_size(400, 300, 2);
        test_frost_can = 1;
        test_frost_n = 0;
        memset(test_frost_last, 0, sizeof test_frost_last);

        double lh[2 * MB_INST];
        rect_at(lh, 0, 0, 400, 300, 9, 0, 0, 0, MB_VIEW_TEX + 7);
        rect_at(lh + MB_INST, 40, 80, 320, 120, 6, 253.0 / 255.0, 252.0 / 255.0, 253.0 / 255.0, -330);
        lh[MB_INST + 4] = 26.0;
        lh[MB_INST + 6] = 1.0;
        lh[MB_INST + 7] = 8.0;
        lh[MB_INST + 11] = 128.0 / 255.0;
        lh[MB_INST + 12] = 0.55;
        lh[MB_INST + 13] = 14.0;
        lh[MB_INST + 15] = 1.0;
        lh[MB_INST + 21] = 14.0;
        lh[MB_INST + 22] = 0.08;
        lh[MB_INST + 23] = 0.0;

        float lh_f[2 * MB_INST];
        for (int i = 0; i < 2 * MB_INST; i++) lh_f[i] = (float)lh[i];
        double fz = mlayer.contentsScale > 0 ? vscale / mlayer.contentsScale : 1.0;
        CHECK(glass_through(lh_f, 2) == 1);
        CHECK(through_n == 1);
        CHECK(test_frost_n == 1);
        CHECK(fabs(test_frost_last[8] - 26.0 * fz) < 0.01 && fabs(test_frost_last[11] - 26.0 * fz) < 0.01);
        CHECK(fabs(test_frost_last[12] - 8.0 * fz) < 0.01);
        CHECK(fabs(test_frost_last[15] - 7.0) < 0.01);

        glass_forget();
        shown_ok = 0;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(lh, 2, 0.0, 0.0, 0.0);
        present_drain();
        int pw = 0, ph = 0;
        uint8_t *px_light = read_texture(canvas, &pw, &ph);
        // Center of card at (200, 140) -> (400, 280) at 2x (BGRA8Unorm premultiplied)
        uint8_t *c_l = px_light + ((size_t)280 * pw + 400) * 4;
        int lr = c_l[2], lg = c_l[1], lb = c_l[0], la = c_l[3];
        int comp_lr = lr + (230 * (255 - la) + 127) / 255;
        int comp_lg = lg + (222 * (255 - la) + 127) / 255;
        int comp_lb = lb + (251 * (255 - la) + 127) / 255;
        printf("apple_render: liquid-over-hole light raw=(%d,%d,%d,a=%d) over-lavender=(%d,%d,%d)\n",
               lr, lg, lb, la, comp_lr, comp_lg, comp_lb);
        CHECK(la >= 132 && la <= 156);
        CHECK(lr <= la && lg <= la && lb <= la);
        CHECK(comp_lr >= 236 && comp_lg >= 232 && comp_lb >= 246 && comp_lb - comp_lg >= 8);

        // Partial redraw of a through liquid-glass card over a hole (both glass-closed corner via
        // mb_glass_damage_expand and explicit card-covering partial rect, warm & cold blur cache)
        // must match the whole-frame through canvas byte-for-byte (never double-accumulating alpha).
        for (int mode = 0; mode < 2; mode++) {
          if (mode == 1) glass_forget();
          int drawn_before = present_drawn;
          shown_ok = 0;  // keep canvas_ok=1 so draw_parts runs a true partial redraw
          if (mode == 0) {
            mb_host_render_dirty(40, 80, 120, 60);
            rw->said.glass_closure = 1;
          } else {
            mb_host_render_dirty(10, 50, 380, 180);
          }
          mb_render_present(lh, 2, 0.0, 0.0, 0.0);
          present_drain();
          CHECK(present_drawn == drawn_before + 1);
          CHECK(canvas_ok == 1);
          int pw2 = 0, ph2 = 0;
          uint8_t *px_part = read_texture(canvas, &pw2, &ph2);
          int max_diff = 0;
          if (pw2 == pw && ph2 == ph) {
            for (size_t i = 0; i < (size_t)pw * ph * 4; i++) {
              int d = abs((int)px_part[i] - (int)px_light[i]);
              if (d > max_diff) max_diff = d;
            }
          } else {
            max_diff = 255;
          }
          printf("apple_render: liquid-over-hole partial-redraw mode=%d max_diff=%d\n", mode, max_diff);
          CHECK(max_diff == 0);
          free(px_part);
        }
        free(px_light);

        // Frost overflow beyond MB_FROSTS: any tid that cannot fit all its instances is dropped from through_tid
        // (and its partial frosts stripped) so no card renders transparent without a CABackdropLayer.
        {
          float ov[(1 + MB_FROSTS + 2) * MB_INST];
          memset(ov, 0, sizeof ov);
          double ovd[MB_INST];
          rect_at(ovd, 0, 0, 400, 300, 9, 0, 0, 0, MB_VIEW_TEX + 7);
          for (int k = 0; k < MB_INST; k++) ov[k] = (float)ovd[k];
          for (int j = 0; j < MB_FROSTS + 2; j++) {
            // First 15 get unique tids (-350..-364); last 3 share tid -365 so instance 16 fits and 17/18 overflow
            double tid = j < MB_FROSTS - 1 ? -(350.0 + j) : -365.0;
            rect_at(ovd, 10 + (j % 4) * 80, 10 + (j / 4) * 40, 60, 30, 6, 1, 1, 1, tid);
            ovd[4] = 12.0; ovd[6] = 1.0; ovd[7] = 8.0; ovd[11] = 0.5; ovd[15] = 1.0;
            for (int k = 0; k < MB_INST; k++) ov[(1 + j) * MB_INST + k] = (float)ovd[k];
          }
          test_frost_n = 0;
          CHECK(glass_through(ov, 1 + MB_FROSTS + 2) == 1);
          CHECK(!is_through(-365.0f));
          CHECK(test_frost_n == MB_FROSTS - 1);
        }

        // Dark liquid_panel_glass (0x20202080) over hole: translucent and keeps white-backdrop luminance <= 105/255
        lh[MB_INST + 8] = 32.0 / 255.0;
        lh[MB_INST + 9] = 32.0 / 255.0;
        lh[MB_INST + 10] = 32.0 / 255.0;
        lh[MB_INST + 11] = 128.0 / 255.0;
        lh[MB_INST + 20] = -331;
        glass_forget();
        shown_ok = 0;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(lh, 2, 0.0, 0.0, 0.0);
        present_drain();
        uint8_t *px_dark = read_texture(canvas, &pw, &ph);
        uint8_t *c_d = px_dark + ((size_t)280 * pw + 400) * 4;
        int dr = c_d[2], dg = c_d[1], db = c_d[0], da = c_d[3];
        int comp_dw = dr + (255 * (255 - da) + 127) / 255;
        int comp_dlb = db + (251 * (255 - da) + 127) / 255;
        int comp_dlg = dg + (222 * (255 - da) + 127) / 255;
        printf("apple_render: liquid-over-hole dark raw=(%d,%d,%d,a=%d) over-white=%d over-lavender-b-g=%d\n",
               dr, dg, db, da, comp_dw, comp_dlb - comp_dlg);
        CHECK(da >= 180 && da <= 205);
        CHECK(dr <= da && dg <= da && db <= da);
        CHECK(comp_dw <= 105);
        CHECK(comp_dlb - comp_dlg >= 4);
        free(px_dark);

        // Adaptive light liquid glass over hole: stays light (does not mistake transparent hole for black backdrop)
        lh[MB_INST + 8] = 253.0 / 255.0;
        lh[MB_INST + 9] = 252.0 / 255.0;
        lh[MB_INST + 10] = 253.0 / 255.0;
        lh[MB_INST + 11] = 103.0 / 255.0;
        lh[MB_INST + 14] = -1.0;  // is_adaptive
        lh[MB_INST + 20] = -332;
        glass_forget();
        shown_ok = 0;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(lh, 2, 0.0, 0.0, 0.0);
        present_drain();
        uint8_t *px_ad = read_texture(canvas, &pw, &ph);
        uint8_t *c_a = px_ad + ((size_t)280 * pw + 400) * 4;
        printf("apple_render: liquid-over-hole adaptive-light raw=(%d,%d,%d,a=%d)\n", c_a[2], c_a[1], c_a[0], c_a[3]);
        CHECK(c_a[2] >= 120 && c_a[3] >= 125 && c_a[3] <= 150);
        free(px_ad);

        // Same Light liquid_panel_glass over an opaque black rect (no hole): stays opaque (alpha 255)
        rect_at(lh, 0, 0, 400, 300, 0, 0, 0, 0, 0);
        lh[MB_INST + 11] = 128.0 / 255.0;
        lh[MB_INST + 14] = 0.0;
        lh[MB_INST + 20] = -333;
        glass_forget();
        shown_ok = 0;
        mb_host_render_dirty(0, 0, 400, 300);
        mb_render_present(lh, 2, 0.0, 0.0, 0.0);
        present_drain();
        CHECK(test_frost_n == 0 && through_n == 0);
        uint8_t *px_op = read_texture(canvas, &pw, &ph);
        uint8_t *c_o = px_op + ((size_t)280 * pw + 400) * 4;
        CHECK(c_o[3] == 255 && c_o[2] >= 195 && c_o[2] <= 210);
        free(px_op);

        test_frost_can = 0;
      }

      glass_forget();
      free(last_inst);
      last_inst = NULL;
      last_cap = 0;
    }

    // Restore synthetic state for trim checks.
    for (int i = 0; i < MB_INST; i++) f[i] = (float)inst[i];
    last_inst = f;
    last_count = 1;
    last_bg[0] = 0.1;
    last_bg[1] = 0.2;
    last_bg[2] = 0.3;
    shown_w = 400;
    shown_h = 300;
    shown_scale = 2;
    shown_ok = 1;
    canvas_ok = 1;

    // Trimming shrinks drawableSize to 1x1 and invalidates both canvas_ok and shown_ok; after mb_render_set_size
    // restores the full drawableSize, an identical frame must not be skipped by same_as_shown.
    mb_host_render_dirty(10, 20, 30, 40);
    mb_render_trim();
    CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(1, 1)));
    CHECK(shown_ok == 0);
    CHECK(canvas_ok == 0);
    CHECK(dirty_told == 0);

    mb_render_set_size(400, 300, 2);
    CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(800, 600)));
    CHECK(same_as_shown(f, 1, 0.1, 0.2, 0.3) == 0);

    // Even if shown_ok were set while drawableSize differed from the view's size, restoring drawableSize via
    // mb_render_set_size clears shown_ok so the new drawable size is presented.
    mlayer.drawableSize = CGSizeMake(1, 1);
    shown_ok = 1;
    mb_render_set_size(400, 300, 2);
    CHECK(CGSizeEqualToSize(mlayer.drawableSize, CGSizeMake(800, 600)));
    CHECK(shown_ok == 0);
    CHECK(same_as_shown(f, 1, 0.1, 0.2, 0.3) == 0);

    last_inst = NULL;
  }
  @autoreleasepool {
    // the reflection of what is outside liquid glass (glass_reflect_cases.h)
    glass_reflect_cases();
    mb_render_set_size(320, 300, 2);
    gr_hot_frame_case(gr_window_frame);
  }
  if (!failed) printf("apple_render: ok\n");
  return failed;
}
