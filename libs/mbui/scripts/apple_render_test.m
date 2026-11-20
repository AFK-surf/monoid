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
    // again by the next read and the next glass, the canvas then the same to the byte as the frame drawn whole); a
    // slot that kept liquid glass's sharp level lets it go as frosted glass is kept in it; and glass's textures go
    // once MB_GLASS_IDLE frames in a row drew none, the glass after them blurred anew, as the frame drawn whole.
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
      CHECK(slot_rt[0] != nil);
      // the same capture frosted (kind 5), kept in the same slot: its sharp level let go
      g1[MB_INST + 5] = 5;
      g1[0] = 32;
      glass_forget();
      mb_host_render_dirty(0, 0, 400, 300);
      mb_render_present(g1, 2, 0.1, 0.2, 0.3);
      present_drain();
      CHECK(slot_bt[0] != nil);
      CHECK(slot_rt[0] == nil);
      CHECK(canvas_as_whole());

      int fw, fh;
      free(read_last(&fw, &fh));
      CHECK(read_tex != nil);
      mb_render_trim();
      CHECK(read_tex == nil);
      CHECK(lv[0] == nil && ltmp == nil && lv_w == 0 && lv_h == 0);
      CHECK(slot_bt[0] == nil && slot_rt[0] == nil);
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
      for (int i = 0; i < MB_GLASS_SLOTS; i++) CHECK(slot_bt[i] == nil && slot_rt[i] == nil);
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
