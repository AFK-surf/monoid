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
int mb_views_frost(int n, const double *frosts) { (void)n, (void)frosts; return 0; }
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
      lq[2 * MB_INST + 7] = 1.5;  // sp = 3.0 -> k == 0
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
      lq[4 * MB_INST + 7] = 1.5;
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
      CHECK((int)bl_p[2] > 90 && (int)bl_p[1] > 90);
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
      CHECK(abs((int)cl_lens[1] - (int)cl_bg[1]) <= 2 && abs((int)cl_lens[2] - (int)cl_bg[2]) <= 2);
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
      CHECK(top0 > left0 + 30);

      mb_host_glass_light_angle(1.5707963267948966);  // PI / 2
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(la_inst, 2, 0.10, 0.10, 0.12);
      present_drain();
      uint8_t *px_la90 = read_texture(canvas, &aw, &ah);
      int top90 = (int)px_la90[(161 * aw + 320) * 4 + 1];
      int left90 = (int)px_la90[(280 * aw + 201) * 4 + 1];
      int right90 = (int)px_la90[(280 * aw + 439) * 4 + 1];
      CHECK(left90 > top90 + 30);
      CHECK(right90 > top90 + 30);
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
      uint8_t *px_ld[4];
      // (alpha byte, backdrop r, g, b)
      static const double ld_case[4][4] = {
          {0x50, 0, 0, 0}, {0x67, 0, 0, 0}, {0xD9, 0, 0, 0}, {0xD9, 0.0, 0.4, 1.0}};
      for (int i = 0; i < 4; i++) {
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
      double ld_lum[4];
      for (int i = 0; i < 4; i++) {
        uint8_t *c = px_ld[i] + (300 * aw + 400) * 4;
        ld_lum[i] = (0.2126 * c[2] + 0.7152 * c[1] + 0.0722 * c[0]) / 255.0;
        printf("apple_render: light glass 0x%02X over (%.1f, %.1f, %.1f): rgb %d %d %d, luma %.4f\n",
               (int)ld_case[i][0], ld_case[i][1], ld_case[i][2], ld_case[i][3], c[2], c[1], c[0], ld_lum[i]);
      }
      CHECK(memcmp(px_ld[0], px_ld[1], (size_t)aw * (size_t)ah * 4) == 0);
      CHECK(ld_lum[1] >= 0.25 && ld_lum[1] <= 0.36);
      CHECK(ld_lum[2] >= 0.80 && ld_lum[2] > ld_lum[1] + 0.40);
      CHECK(px_ld[3][(300 * aw + 400) * 4 + 2] >= (int)(0.72 * 255.0 + 0.5));
      for (int i = 0; i < 4; i++) free(px_ld[i]);

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
      // 3: dark glass (0x20202067) over white (bg=1.0) -> stays dark smoked glass + light ink (never flips white)
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
          CHECK(g_lum < 0.45);
          CHECK(n_lum > 0.85);
        } else if (ci == 4) {
          CHECK(n_lum > 0.70);
        } else {
          CHECK(g_lum > 0.75);
          CHECK(n_lum < 0.25);
        }
        CHECK((int)cp[2] > (int)cp[0] + 120);
        free(px_ad);
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
      CHECK(fog_peaks[1] < fog_peaks[0] - 0.15);

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
      CHECK(mb_glass_damage_expand(f, 7, r, &rn, 400, 300, 2));
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
    last_cap = 0;

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
  if (!failed) printf("apple_render: ok\n");
  return failed;
}
