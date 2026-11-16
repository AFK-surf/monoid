// src/host/apple_render.m's tests: after mb_render_trim shrinks the layer's drawableSize to 1x1 (the window hidden,
// covered, minimized or the Mac asleep) and mb_render_set_size restores the window's size, the next frame is drawn
// whole into a new canvas and presented, never skipped by same_as_shown as equal to the frame before the trim:
//   cc -Wall -fobjc-arc -I src/host -I "$MOON_HOME/include" scripts/apple_render_test.m -framework Foundation -framework QuartzCore -framework Metal -framework CoreGraphics -framework ImageIO -o out/apple_render_test && out/apple_render_test
#include <stdio.h>
#import "apple_render.m"

id<MTLTexture> mb_image_texture(int iid) { (void)iid; return nil; }
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
    // A frame drawn whole with no glass goes straight into the drawable: the canvas holds no frame after it.
    CHECK(canvas_ok == 0);
    // One said to differ in a part is drawn into the canvas (whole, as it held none) and copied.
    double moved[MB_INST];
    memcpy(moved, inst, sizeof moved);
    moved[0] = 12;
    mb_host_render_dirty(0, 0, 200, 100);
    mb_render_present(moved, 1, 0.1, 0.2, 0.3);
    CHECK(shown_ok == 1);
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
    CHECK(canvas_ok == 1);

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
