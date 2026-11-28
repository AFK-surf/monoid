// src/host/apple_grab.h, src/host/ios_nav_state.h and src/host/ios_nav_overflow_state.h deterministic tests:
//   cc -Wall -Werror -fobjc-arc -I src/host scripts/apple_grab_nav_test.m \
//     -framework Foundation -framework CoreGraphics -framework CoreVideo -framework ImageIO \
//     -o out/apple_grab_nav_test && out/apple_grab_nav_test
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <stdio.h>
#import "apple_grab.h"
#import "ios_nav_state.h"
#import "ios_nav_overflow_state.h"

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)

static CVPixelBufferRef make_bgra_pixel_buffer(size_t w, size_t h) {
  CVPixelBufferRef pb = NULL;
  NSDictionary *attrs = @{
    (__bridge NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
    (__bridge NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
  };
  CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                   (__bridge CFDictionaryRef)attrs, &pb);
  if (r != kCVReturnSuccess || !pb) return NULL;
  CVPixelBufferLockBaseAddress(pb, 0);
  uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
  size_t bpr = CVPixelBufferGetBytesPerRow(pb);
  for (size_t y = 0; y < h; y++) {
    uint8_t *row = base + y * bpr;
    for (size_t x = 0; x < w; x++) {
      row[x * 4 + 0] = (uint8_t)((x * 255) / (w > 1 ? w - 1 : 1));
      row[x * 4 + 1] = (uint8_t)((y * 255) / (h > 1 ? h - 1 : 1));
      row[x * 4 + 2] = (uint8_t)((x + y) & 0xFF);
      row[x * 4 + 3] = 0xFF;
    }
  }
  CVPixelBufferUnlockBaseAddress(pb, 0);
  return pb;
}

static CGImageRef make_cg_image(size_t w, size_t h) {
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(cs);
  if (!c) return NULL;
  CGContextSetRGBFillColor(c, 0.25, 0.55, 0.85, 1.0);
  CGContextFillRect(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));
  CGImageRef img = CGBitmapContextCreateImage(c);
  CGContextRelease(c);
  return img;
}

static BOOL verify_jpeg_size(NSData *data, size_t expectedW, size_t expectedH) {
  if (!data || data.length < 4) return NO;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  if (bytes[0] != 0xFF || bytes[1] != 0xD8) return NO;
  if (bytes[data.length - 2] != 0xFF || bytes[data.length - 1] != 0xD9) return NO;
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
  if (!src) return NO;
  CGImageRef decoded = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if (!decoded) return NO;
  BOOL ok = CGImageGetWidth(decoded) == expectedW && CGImageGetHeight(decoded) == expectedH;
  CGImageRelease(decoded);
  return ok;
}

static void test_apple_grab(void) {
  // 1. 1920x1080 32BGRA CVPixelBuffer scaled to 640 -> valid 640x360 JPEG.
  CVPixelBufferRef pb1080 = make_bgra_pixel_buffer(1920, 1080);
  CHECK(pb1080 != NULL);
  if (pb1080) {
    NSData *jpeg = mb_apple_encode_frame_jpeg(NULL, pb1080, 640.0);
    CHECK(verify_jpeg_size(jpeg, 640, 360));
    CVPixelBufferRelease(pb1080);
  }

  // 2. CGImageRef path (scrub picture) 800x600 -> 400x300.
  CGImageRef cg800 = make_cg_image(800, 600);
  CHECK(cg800 != NULL);
  if (cg800) {
    NSData *jpeg = mb_apple_encode_frame_jpeg(cg800, NULL, 400.0);
    CHECK(verify_jpeg_size(jpeg, 400, 300));
    CGImageRelease(cg800);
  }

  // 3. No-upscale path: 320x240 with side 640 stays 320x240.
  CVPixelBufferRef pbSmall = make_bgra_pixel_buffer(320, 240);
  CHECK(pbSmall != NULL);
  if (pbSmall) {
    NSData *jpeg = mb_apple_encode_frame_jpeg(NULL, pbSmall, 640.0);
    CHECK(verify_jpeg_size(jpeg, 320, 240));

    // 4. Invalid side boundaries (0, negative, NaN, Inf) fall back safely to 1:1.
    CHECK(verify_jpeg_size(mb_apple_encode_frame_jpeg(NULL, pbSmall, 0.0), 320, 240));
    CHECK(verify_jpeg_size(mb_apple_encode_frame_jpeg(NULL, pbSmall, -120.0), 320, 240));
    CHECK(verify_jpeg_size(mb_apple_encode_frame_jpeg(NULL, pbSmall, NAN), 320, 240));
    CHECK(verify_jpeg_size(mb_apple_encode_frame_jpeg(NULL, pbSmall, INFINITY), 320, 240));
    CVPixelBufferRelease(pbSmall);
  }

  // 5. NULL inputs and non-32BGRA / planar pixel buffers return nil safely.
  CHECK(mb_apple_encode_frame_jpeg(NULL, NULL, 640.0) == nil);
  CVPixelBufferRef pbYuv = NULL;
  CVReturn yuvRes = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                        NULL, &pbYuv);
  CHECK(yuvRes == kCVReturnSuccess && pbYuv != NULL);
  if (pbYuv) {
    CHECK(mb_apple_encode_frame_jpeg(NULL, pbYuv, 640.0) == nil);
    CVPixelBufferRelease(pbYuv);
  }

  // 6. Async dispatch off caller thread + grabGen/closed stale delivery suppression.
  CVPixelBufferRef pbAsync = make_bgra_pixel_buffer(640, 360);
  CHECK(pbAsync != NULL);
  if (pbAsync) {
    dispatch_queue_t worker = dispatch_queue_create("mbui.test.grab.worker", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t deliver = dispatch_queue_create("mbui.test.grab.deliver", DISPATCH_QUEUE_SERIAL);
    __block int grabGen = 0;
    __block BOOL closed = NO;
    __block int deliveredCount = 0;
    __block NSData *deliveredData = nil;

    // 6a. Stale generation suppressed when a newer grab supersedes it before delivery.
    dispatch_semaphore_t gate1 = dispatch_semaphore_create(0);
    dispatch_semaphore_t done1 = dispatch_semaphore_create(0);
    int gen1 = ++grabGen;
    CVPixelBufferRetain(pbAsync);
    dispatch_async(worker, ^{
      dispatch_semaphore_wait(gate1, DISPATCH_TIME_FOREVER);
      NSData *jpeg = mb_apple_encode_frame_jpeg(NULL, pbAsync, 320.0);
      CVPixelBufferRelease(pbAsync);
      dispatch_async(deliver, ^{
        if (!closed && grabGen == gen1) {
          deliveredCount++;
          deliveredData = jpeg;
        }
        dispatch_semaphore_signal(done1);
      });
    });
    // Supersede before worker runs.
    int gen2 = ++grabGen;
    dispatch_semaphore_signal(gate1);
    dispatch_semaphore_wait(done1, DISPATCH_TIME_FOREVER);
    CHECK(deliveredCount == 0 && deliveredData == nil);

    // 6b. Active generation delivers valid JPEG off-thread.
    dispatch_semaphore_t done2 = dispatch_semaphore_create(0);
    CVPixelBufferRetain(pbAsync);
    dispatch_async(worker, ^{
      NSData *jpeg = mb_apple_encode_frame_jpeg(NULL, pbAsync, 320.0);
      CVPixelBufferRelease(pbAsync);
      dispatch_async(deliver, ^{
        if (!closed && grabGen == gen2) {
          deliveredCount++;
          deliveredData = jpeg;
        }
        dispatch_semaphore_signal(done2);
      });
    });
    dispatch_semaphore_wait(done2, DISPATCH_TIME_FOREVER);
    CHECK(deliveredCount == 1 && verify_jpeg_size(deliveredData, 320, 180));

    // 6c. Closed view suppresses delivery even if generation matches.
    dispatch_semaphore_t gate3 = dispatch_semaphore_create(0);
    dispatch_semaphore_t done3 = dispatch_semaphore_create(0);
    int gen3 = ++grabGen;
    CVPixelBufferRetain(pbAsync);
    dispatch_async(worker, ^{
      dispatch_semaphore_wait(gate3, DISPATCH_TIME_FOREVER);
      NSData *jpeg = mb_apple_encode_frame_jpeg(NULL, pbAsync, 320.0);
      CVPixelBufferRelease(pbAsync);
      dispatch_async(deliver, ^{
        if (!closed && grabGen == gen3) {
          deliveredCount++;
        }
        (void)jpeg;
        dispatch_semaphore_signal(done3);
      });
    });
    closed = YES;
    dispatch_semaphore_signal(gate3);
    dispatch_semaphore_wait(done3, DISPATCH_TIME_FOREVER);
    CHECK(deliveredCount == 1);

    CVPixelBufferRelease(pbAsync);
  }
}

static void test_ios_nav_state(void) {
  // 1. Overflow probe matrix.
  NSString *lkeyA = @"669x951/1/1/2/L/5/1";
  NSString *lkeyB = @"951x669/2/2/1/L/5/1";

  // First probe (overflowLayoutKey == nil) triggers probe.
  CHECK(mb_ios_nav_needs_overflow_probe(NO, YES, 0, 5, NO, lkeyA, nil));
  // bare YES -> NO with unchanged lkey and !tabsChanged skips probe.
  CHECK(!mb_ios_nav_needs_overflow_probe(NO, YES, 0, 5, NO, lkeyA, lkeyA));
  // Fold/rotate changes lkey -> triggers probe.
  CHECK(mb_ios_nav_needs_overflow_probe(NO, YES, 0, 5, NO, lkeyB, lkeyA));
  // tabsChanged while visible triggers probe even with same lkey.
  CHECK(mb_ios_nav_needs_overflow_probe(NO, YES, 0, 5, YES, lkeyA, lkeyA));
  // tabsChanged while bare clears cached overflowLayoutKey so exiting bare re-probes.
  NSString *afterBareChange = mb_ios_nav_next_overflow_layout_key(YES, YES, lkeyA);
  CHECK(afterBareChange == nil);
  CHECK(mb_ios_nav_needs_overflow_probe(NO, YES, 0, 5, NO, lkeyA, afterBareChange));
  // bare without tabsChanged preserves cached overflowLayoutKey.
  CHECK([mb_ios_nav_next_overflow_layout_key(YES, NO, lkeyA) isEqualToString:lkeyA]);
  CHECK([mb_ios_nav_next_overflow_layout_key(NO, YES, lkeyA) isEqualToString:lkeyA]);
  // Already collapsed (visibleRegularCap > 0) skips probe.
  CHECK(!mb_ios_nav_needs_overflow_probe(NO, YES, 3, 5, YES, lkeyB, nil));
  // Guardrails: bare, no window, or <= 1 place skip probe.
  CHECK(!mb_ios_nav_needs_overflow_probe(YES, YES, 0, 5, YES, lkeyB, nil));
  CHECK(!mb_ios_nav_needs_overflow_probe(NO, NO, 0, 5, YES, lkeyB, nil));
  CHECK(!mb_ios_nav_needs_overflow_probe(NO, YES, 0, 1, YES, lkeyB, nil));

  // 2. Corner cache matrix: 8 queries on same window/bounds => 1 miss + 7 hits.
  MBCornerCache cache = {0};
  uintptr_t win1 = 0x1001, win2 = 0x2002;
  CGRect b1 = CGRectMake(0, 0, 669, 951);
  CGRect b2 = CGRectMake(0, 0, 951, 669);
  double radii1[4] = {8.0, 59.0, 59.0, 8.0};
  int probes = 0;
  for (int i = 0; i < 8; i++) {
    double r = -1;
    if (!mb_corner_cache_hit(&cache, win1, b1, i & 3, &r)) {
      probes++;
      mb_corner_cache_store(&cache, win1, b1, radii1);
      r = radii1[i & 3];
    }
    CHECK(r == radii1[i & 3]);
  }
  CHECK(probes == 1);

  // Changed bounds misses.
  double outR = -1;
  CHECK(!mb_corner_cache_hit(&cache, win1, b2, 0, &outR));
  // Changed window misses.
  CHECK(!mb_corner_cache_hit(&cache, win2, b1, 0, &outR));
  // Explicit invalidation misses.
  CHECK(mb_corner_cache_hit(&cache, win1, b1, 1, &outR) && outR == 59.0);
  mb_corner_cache_invalidate(&cache);
  CHECK(!mb_corner_cache_hit(&cache, win1, b1, 1, &outR));
  // Zero winTag never hits.
  mb_corner_cache_store(&cache, 0, b1, radii1);
  CHECK(!mb_corner_cache_hit(&cache, 0, b1, 0, &outR));

  // 3. Lazy slot appliedActsKey matrix.
  CHECK(mb_ios_nav_slot_needs_bar_items(nil, @"acts-v1", YES));
  CHECK(!mb_ios_nav_slot_needs_bar_items(@"acts-v1", @"acts-v1", YES));
  CHECK(mb_ios_nav_slot_needs_bar_items(@"acts-v1", @"acts-v2", YES));
  CHECK(!mb_ios_nav_slot_needs_bar_items(nil, @"acts-v1", NO));
  CHECK(!mb_ios_nav_slot_needs_bar_items(nil, nil, YES));
  CHECK(!mb_ios_nav_slot_needs_bar_items(nil, @"", YES));

  // 4. Icon cache key uniqueness and determinism.
  NSString *k1 = mb_ios_nav_icon_cache_key('i', 24.0, 3.0, @"0 2 2 1 1 23 23");
  NSString *k1b = mb_ios_nav_icon_cache_key('i', 24.0, 3.0, @"0 2 2 1 1 23 23");
  NSString *kKind = mb_ios_nav_icon_cache_key('b', 24.0, 3.0, @"0 2 2 1 1 23 23");
  NSString *kSize = mb_ios_nav_icon_cache_key('i', 26.0, 3.0, @"0 2 2 1 1 23 23");
  NSString *kScale = mb_ios_nav_icon_cache_key('i', 24.0, 2.0, @"0 2 2 1 1 23 23");
  NSString *kSpec = mb_ios_nav_icon_cache_key('i', 24.0, 3.0, @"0 2 2 2 2 22 22");
  CHECK([k1 isEqualToString:k1b]);
  CHECK(![k1 isEqualToString:kKind]);
  CHECK(![k1 isEqualToString:kSize]);
  CHECK(![k1 isEqualToString:kScale]);
  CHECK(![k1 isEqualToString:kSpec]);

  // 5. Floating item key: field sensitivity, empty menu, row order sensitivity, different inkVal.
  NSDictionary *baseItem = @{
    @"id" : @"workspace-switch",
    @"title" : @"Workspace",
    @"icon" : @"badge:336699ff,W",
    @"dot" : @NO,
    @"prominent" : @YES,
    @"menu" : @[],
  };
  NSString *fkBase = mb_ios_nav_floating_item_key(baseItem, 0x112233FFULL);
  NSString *fkSame = mb_ios_nav_floating_item_key([baseItem copy], 0x112233FFULL);
  CHECK([fkBase isEqualToString:fkSame]);
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(baseItem, 0x445566FFULL)]);
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(baseItem, 0ULL)]);
  NSMutableDictionary *dId = [baseItem mutableCopy];
  dId[@"id"] = @"sidebar/filter";
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(dId, 0x112233FFULL)]);
  NSMutableDictionary *dTitle = [baseItem mutableCopy];
  dTitle[@"title"] = @"Other";
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(dTitle, 0x112233FFULL)]);
  NSMutableDictionary *dIcon = [baseItem mutableCopy];
  dIcon[@"icon"] = @"badge:ff0000ff,W";
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(dIcon, 0x112233FFULL)]);
  NSMutableDictionary *dDot = [baseItem mutableCopy];
  dDot[@"dot"] = @YES;
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(dDot, 0x112233FFULL)]);
  NSMutableDictionary *dProm = [baseItem mutableCopy];
  dProm[@"prominent"] = @NO;
  CHECK(![fkBase isEqualToString:mb_ios_nav_floating_item_key(dProm, 0x112233FFULL)]);

  NSDictionary *rowA = @{@"id" : @"r1", @"title" : @"All", @"checked" : @YES, @"icon" : @"i1"};
  NSDictionary *rowB = @{@"id" : @"r2", @"title" : @"Mine", @"checked" : @NO, @"icon" : @"i2"};
  NSDictionary *rowBChecked = @{@"id" : @"r2", @"title" : @"Mine", @"checked" : @YES, @"icon" : @"i2"};
  NSMutableDictionary *dMenuAB = [baseItem mutableCopy];
  dMenuAB[@"menu"] = @[ rowA, rowB ];
  NSMutableDictionary *dMenuBA = [baseItem mutableCopy];
  dMenuBA[@"menu"] = @[ rowB, rowA ];
  NSMutableDictionary *dMenuAB2 = [baseItem mutableCopy];
  dMenuAB2[@"menu"] = @[ rowA, rowBChecked ];
  NSString *fkAB = mb_ios_nav_floating_item_key(dMenuAB, 0x112233FFULL);
  NSString *fkBA = mb_ios_nav_floating_item_key(dMenuBA, 0x112233FFULL);
  NSString *fkAB2 = mb_ios_nav_floating_item_key(dMenuAB2, 0x112233FFULL);
  CHECK(![fkBase isEqualToString:fkAB]);
  CHECK(![fkAB isEqualToString:fkBA]);
  CHECK(![fkAB isEqualToString:fkAB2]);

  // Length-prefix collision resistance: delimiters inside user text cannot collide across fields.
  NSDictionary *colA = @{@"id" : @"a", @"title" : @"x|1:y", @"icon" : @"z", @"dot" : @NO, @"prominent" : @NO};
  NSDictionary *colB = @{@"id" : @"a", @"title" : @"x", @"icon" : @"y|1:z", @"dot" : @NO, @"prominent" : @NO};
  CHECK(![mb_ios_nav_floating_item_key(colA, 0x112233FFULL) isEqualToString:mb_ios_nav_floating_item_key(colB, 0x112233FFULL)]);

  // 6. Color change guard.
  CHECK(mb_ios_nav_color_changed(NO, 0ULL, 0ULL));
  CHECK(!mb_ios_nav_color_changed(YES, 0x112233FFULL, 0x112233FFULL));
  CHECK(mb_ios_nav_color_changed(YES, 0x112233FFULL, 0x11223300ULL));

  // 7. Action wash rect matcher (midpoint & width < 2pt matching nav_platter, rejects empty/Null/Infinite).
  CGRect tabR = CGRectMake(610.0, 860.0, 48.0, 48.0);
  CHECK(mb_ios_nav_wash_rect_matches(tabR, tabR));
  CHECK(mb_ios_nav_wash_rect_matches(CGRectMake(610.5, 858.0, 49.5, 54.0), tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectMake(612.0, 860.0, 48.0, 48.0), tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectMake(610.0, 862.0, 48.0, 48.0), tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectMake(609.0, 860.0, 50.0, 48.0), tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectZero, tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(tabR, CGRectZero));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectNull, tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(tabR, CGRectNull));
  CHECK(!mb_ios_nav_wash_rect_matches(CGRectInfinite, tabR));
  CHECK(!mb_ios_nav_wash_rect_matches(tabR, CGRectInfinite));

  // 8. Overflow action decision (iOS 27.1 prominent action tab where tabBarItemCount < tabsCount even with no overflow).
  CHECK(mb_ios_nav_overflow_action(0, 5, 0, 4) == MBIosNavOverflowActionNoOverflowCache);
  CHECK(mb_ios_nav_overflow_action(5, 5, 4, 4) == MBIosNavOverflowActionNoOverflowCache);
  CHECK(mb_ios_nav_overflow_action(6, 5, 4, 4) == MBIosNavOverflowActionNoOverflowCache);
  // iOS 27.1: 4 regular places + 1 prominent action tab -> tabBarItemCount=4, tabsCount=5, visiblePlaces=4 -> cache lkey!
  CHECK(mb_ios_nav_overflow_action(4, 5, 4, 4) == MBIosNavOverflowActionNoOverflowCache);
  // Frames not laid out yet (visiblePlaces == 0) -> do NOT cache lkey.
  CHECK(mb_ios_nav_overflow_action(4, 5, 0, 4) == MBIosNavOverflowActionNotLaidOut);
  // Genuine UIKit overflow: 3 of 5 regular places visible -> collapse.
  CHECK(mb_ios_nav_overflow_action(4, 6, 3, 5) == MBIosNavOverflowActionCollapse);
  // Defensive empty allPlaces.
  CHECK(mb_ios_nav_overflow_action(1, 2, 0, 0) == MBIosNavOverflowActionNoOverflowCache);

  // 9. Post-layout overflow check guard: skips once overflowLayoutKey matches lkey unless provisional confirmation is pending.
  CHECK(mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, nil, NO, 4, 5));
  CHECK(!mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, lkeyA, NO, 4, 5));
  CHECK(mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, lkeyA, YES, 4, 5));
  CHECK(mb_ios_nav_should_check_overflow_after_layout(0, lkeyB, lkeyA, NO, 4, 5));
  CHECK(!mb_ios_nav_should_check_overflow_after_layout(3, lkeyB, lkeyA, YES, 4, 5));
  CHECK(!mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, nil, YES, 0, 5));
  CHECK(!mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, nil, YES, 5, 5));

  // 10. Displayed tabs key: accent-invariant, structure-sensitive, collision-resistant.
  NSArray<NSDictionary *> *placesA = @[
    @{@"id" : @"place/chats", @"title" : @"Chats"},
    @{@"id" : @"place/settings", @"title" : @"Settings"},
  ];
  NSDictionary *actNew = @{@"id" : @"act/new", @"title" : @"New", @"icon" : @"0 2 2 1 1 23 23"};
  NSString *tkBase = mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", actNew);
  NSString *tkSame = mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", [actNew copy]);
  CHECK([tkBase isEqualToString:tkSame]);
  CHECK(tkBase.length > 0);
  // Overflow state sensitivity.
  CHECK(![tkBase isEqualToString:mb_ios_nav_tabs_key(placesA, YES, @"__mbui_more__", actNew)]);
  // Action presence / title / icon / id sensitivity.
  CHECK(![tkBase isEqualToString:mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", nil)]);
  CHECK(![tkBase isEqualToString:mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__",
                                                     @{@"id" : @"act/new", @"title" : @"Compose", @"icon" : @"0 2 2 1 1 23 23"})]);
  CHECK(![tkBase isEqualToString:mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__",
                                                     @{@"id" : @"act/new", @"title" : @"New", @"icon" : @"0 2 2 2 2 22 22"})]);
  // Length-prefix collision resistance across action fields and regular vs overflow prefix.
  NSDictionary *actCol1 = @{@"id" : @"a", @"title" : @"b|1:c", @"icon" : @"d"};
  NSDictionary *actCol2 = @{@"id" : @"a", @"title" : @"b", @"icon" : @"c|1:d"};
  CHECK(![mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", actCol1)
          isEqualToString:mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", actCol2)]);
  NSArray<NSDictionary *> *placesWithMoreLike = @[
    @{@"id" : @"place/chats"},
    @{@"id" : @"place/settings"},
    @{@"id" : @"__mbui_more__"},
  ];
  CHECK(![mb_ios_nav_tabs_key(placesA, YES, @"__mbui_more__", nil)
          isEqualToString:mb_ios_nav_tabs_key(placesWithMoreLike, NO, @"__mbui_more__", nil)]);

  // 11. Wash sync/async triggers (in-place accent change on mounted wash runs sync without async fallback).
  // Accent tap on mounted wash: washInWindow=YES, washInkMatches=NO -> sync YES, async NO.
  CHECK(mb_ios_nav_wash_needed(NO, NO, NO, YES, YES, NO));
  CHECK(!mb_ios_nav_wash_async_needed(NO, NO, NO, YES, YES));
  // Steady state on mounted wash: washInWindow=YES, washInkMatches=YES -> sync NO, async NO.
  CHECK(!mb_ios_nav_wash_needed(NO, NO, NO, YES, YES, YES));
  CHECK(!mb_ios_nav_wash_async_needed(NO, NO, NO, YES, YES));
  // Unmounted wash -> sync YES, async YES.
  CHECK(mb_ios_nav_wash_needed(NO, NO, NO, YES, NO, YES));
  CHECK(mb_ios_nav_wash_async_needed(NO, NO, NO, YES, NO));
  // tabsChanged -> sync YES, async YES (when actionInk && !bare).
  CHECK(mb_ios_nav_wash_needed(YES, NO, NO, YES, YES, YES));
  CHECK(mb_ios_nav_wash_async_needed(YES, NO, NO, YES, YES));
  // bare reveal with unchanged tabs (hiddenChanged && !bare && !tabsChanged) -> skipSyncWash (CATransaction handles it).
  CHECK(!mb_ios_nav_wash_needed(NO, YES, NO, YES, NO, YES));
  // Entering bare (hiddenChanged && bare) -> sync YES (removes wash), async NO.
  CHECK(mb_ios_nav_wash_needed(NO, YES, YES, YES, YES, YES));
  CHECK(!mb_ios_nav_wash_async_needed(NO, YES, YES, YES, YES));

  // 12. Avatar cache key: short specs use direct 'a' key; long data: URL specs hash with SHA-256 into compact keys.
  NSString *ka = mb_ios_nav_avatar_cache_key(40.0, 3.0, @"avatars:336699ff,A");
  NSString *ka2 = mb_ios_nav_avatar_cache_key(40.0, 3.0, @"avatars:336699ff,A");
  CHECK([ka isEqualToString:ka2]);
  CHECK(![ka isEqualToString:mb_ios_nav_icon_cache_key('b', 40.0, 3.0, @"avatars:336699ff,A")]);
  CHECK(![ka isEqualToString:mb_ios_nav_icon_cache_key('i', 40.0, 3.0, @"avatars:336699ff,A")]);
  CHECK(![ka isEqualToString:mb_ios_nav_avatar_cache_key(24.0, 3.0, @"avatars:336699ff,A")]);
  NSMutableString *longSpecA = [NSMutableString stringWithString:@"avatars:336699ff,A\x1f" "data:image/png;base64,"];
  for (int i = 0; i < 400; i++) [longSpecA appendString:@"A"];
  NSMutableString *longSpecB = [longSpecA mutableCopy];
  [longSpecB replaceCharactersInRange:NSMakeRange(300, 1) withString:@"B"];
  NSString *klA = mb_ios_nav_avatar_cache_key(40.0, 3.0, longSpecA);
  NSString *klA2 = mb_ios_nav_avatar_cache_key(40.0, 3.0, [longSpecA copy]);
  NSString *klB = mb_ios_nav_avatar_cache_key(40.0, 3.0, longSpecB);
  CHECK([klA isEqualToString:klA2]);
  CHECK(![klA isEqualToString:klB]);
  CHECK(klA.length < 100);

  // 13. Simulated iOS 27.1 Setting Appearance session: 1 initial probe + 1 provisional post-layout confirmation,
  // then 0 probes and 0 post-layout walks across 40 subsequent accent clicks and spec updates.
  NSString *simTabsKey = nil;
  NSString *simOverflowKey = nil;
  BOOL simProvisional = NO;
  int simTabRebuilds = 0;
  int simOverflowProbes = 0;
  int simPostLayoutWalks = 0;
  for (int step = 0; step < 41; step++) {
    NSString *nextKey = mb_ios_nav_tabs_key(placesA, NO, @"__mbui_more__", actNew);
    BOOL tabsChanged = ![nextKey isEqualToString:simTabsKey];
    if (tabsChanged) {
      simTabsKey = nextKey;
      simTabRebuilds++;
    }
    simOverflowKey = mb_ios_nav_next_overflow_layout_key(NO, tabsChanged, simOverflowKey);
    if (mb_ios_nav_needs_overflow_probe(NO, YES, 0, placesA.count, tabsChanged, lkeyA, simOverflowKey)) {
      simOverflowProbes++;
      simProvisional = tabsChanged;
      // iOS 27.1 prominent action tab: tabBarItemCount = 2 < tabsCount = 3, visiblePlaces = 2 == placesA.count.
      MBIosNavOverflowAction act = mb_ios_nav_overflow_action(placesA.count, placesA.count + 1, placesA.count, placesA.count);
      if (act == MBIosNavOverflowActionNoOverflowCache) simOverflowKey = lkeyA;
    }
    if (mb_ios_nav_should_check_overflow_after_layout(0, lkeyA, simOverflowKey, simProvisional,
                                                      placesA.count, placesA.count + 1)) {
      simPostLayoutWalks++;
      simProvisional = NO;
    }
  }
  CHECK(simTabRebuilds == 1);
  CHECK(simOverflowProbes == 1);
  CHECK(simPostLayoutWalks == 1);
}

// ---- the overflow menu's state (ios_nav_overflow_state.h), stepped frame by frame ----

// A bar of three places and the overflow slot, four places in the menu: across the foot (320×62 at 100,880), or down a
// side (the canvas turned: the bar 244 long, 48 thick).
static MBOverflow overflow_bar(bool vertical, bool mirrored, bool overflowSelected) {
  MBOverflow m;
  mbo_init(&m);
  m.vertical = vertical;
  m.mirrored = mirrored;
  m.barFrame = vertical ? CGRectMake(200, 600, 244, 48) : CGRectMake(100, 880, 320, 62);
  m.slotCount = 4;
  m.primaryCount = 3;
  m.overflowCount = 4;
  CGFloat step = vertical ? 60 : 78;
  for (int i = 0; i < 4; i++) {
    int at = mirrored ? 3 - i : i;
    m.slots[i] = vertical ? CGRectMake(2 + at * step, 2, step, 44) : CGRectMake(4 + at * step, 4, step, 54);
  }
  m.hasPillSize = true;
  m.pillSize = vertical ? CGSizeMake(58, 44) : CGSizeMake(76, 54);
  m.anchorSelectedSlot = overflowSelected ? 3 : 0;
  m.anchorOverflowSelected = overflowSelected;
  m.activeRow = overflowSelected ? 1 : -1;
  return m;
}

typedef struct {
  int frames, landedOpen, landedShut;
  double minW, maxW, maxDH, maxDW, maxDAlpha, maxDInd;
} OverflowRun;

// The morph run to its end at `fps`, the largest step of each thing seen between two frames kept.
static OverflowRun overflow_run(MBOverflow *m, double *now, double fps) {
  OverflowRun r = {0};
  r.minW = 1e9;
  CGFloat h = m->glassHeight, w = mbo_glass_bounds(m).size.width, a = m->indicatorAlpha;
  CGRect ind = mbo_indicator_frame(m);
  while (m->isMorphing && r.frames < 2000) {
    *now += 1.0 / fps;
    int s = mbo_step_morph(m, *now);
    mbo_update_indicator(m, *now);
    if (s & MBOStepLandedOpen) r.landedOpen++;
    if (s & MBOStepLandedShut) r.landedShut++;
    r.frames++;
    CGFloat nh = m->glassHeight, nw = mbo_glass_bounds(m).size.width;
    if (nw < r.minW) r.minW = nw;
    if (nw > r.maxW) r.maxW = nw;
    if (fabs(nh - h) > r.maxDH) r.maxDH = fabs(nh - h);
    if (fabs(nw - w) > r.maxDW) r.maxDW = fabs(nw - w);
    if (m->visible) {
      CGRect ni = mbo_indicator_frame(m);
      // (the indicator's place only counts while it shows)
      if (m->indicatorAlpha > 0.05 && a > 0.05) {
        double d = fmax(fabs(CGRectGetMidX(ni) - CGRectGetMidX(ind)), fabs(CGRectGetMidY(ni) - CGRectGetMidY(ind)));
        if (d > r.maxDInd) r.maxDInd = d;
      }
      if (fabs(m->indicatorAlpha - a) > r.maxDAlpha) r.maxDAlpha = fabs(m->indicatorAlpha - a);
      ind = ni;
      a = m->indicatorAlpha;
    }
    h = nh;
    w = nw;
  }
  return r;
}

static bool rect_near(CGRect a, CGRect b, CGFloat by) {
  return fabs(a.origin.x - b.origin.x) <= by && fabs(a.origin.y - b.origin.y) <= by && fabs(a.size.width - b.size.width) <= by &&
         fabs(a.size.height - b.size.height) <= by;
}

static void test_ios_nav_overflow(void) {
  // 1. A tap opens it: the first frame is the bar itself, the morph squeezes the bar's length and lands on the menu.
  {
    MBOverflow m = overflow_bar(false, false, false);
    double now = 10;
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    CHECK(m.visible && m.isOpen && m.isMorphing);
    CHECK(m.glassHeight == 62 && mbo_glass_bounds(&m).size.width == 320);
    CHECK(mbo_progress(&m) == 0 && m.tabsShown == 1);
    // (the chosen place's pill where the system's is, whole; no indicator yet: nothing in the menu is chosen)
    CHECK(m.pillAlpha == 1 && !m.tabContentHidden && m.indicatorAlpha == 0 && !m.handoffShown);
    CHECK(rect_near(mbo_morph_pill(&m), CGRectMake(10.0 / 3.0, 4, 76, 54), 0.001));
    OverflowRun r = overflow_run(&m, &now, 120);
    CHECK(r.landedOpen == 1 && r.landedShut == 0);
    CHECK(m.glassHeight == 4 * 48 + 16 && mbo_glass_bounds(&m).size.width == 320);
    CHECK(r.minW < 320 * 0.88 && r.minW > 320 * 0.78 && r.maxW <= 320.5);
    CHECK(m.tabsShown < 0.002 && m.pillAlpha < 0.002 && m.tabContentHidden && m.rowsLive);
    // (no frame of it jumps: at 120 a second the glass grows by less than 16 points a frame, and its squeeze's
    // impulse pulls its length in by less than 6.5 % of it in one)
    CHECK(r.maxDH < 16 && r.maxDW < 320 * 0.065);
    CHECK(r.frames > 40 && r.frames < 120);

    // 2. It closes on the bar exactly, squeezed on the way, and hands back.
    mbo_close(&m, now);
    CHECK(!m.isOpen && m.isMorphing && m.visible && !m.tabContentHidden);
    r = overflow_run(&m, &now, 120);
    CHECK(r.landedShut == 1 && !m.visible && !m.isMorphing);
    CHECK(m.glassHeight == 62 && mbo_glass_bounds(&m).size.width == 320 && m.tabsShown == 1);
    CHECK(r.minW < 320 * 0.90 && r.maxW <= 320.5 && r.maxDH < 16 && r.maxDW < 320 * 0.065);
  }

  // 3. The same morph at 60 and at 120 frames a second ends the same, as long to within a frame.
  {
    MBOverflow a = overflow_bar(false, false, false), b = a;
    double ta = 5, tb = 5;
    mbo_open(&a, false, false, CGPointZero, false, CGRectZero, 0, 0, ta);
    mbo_open(&b, false, false, CGPointZero, false, CGRectZero, 0, 0, tb);
    overflow_run(&a, &ta, 60);
    overflow_run(&b, &tb, 120);
    CHECK(a.glassHeight == b.glassHeight && fabs(a.tabsShown - b.tabsShown) < 0.002);
    CHECK(fabs((ta - 5) - (tb - 5)) <= 1.0 / 60 + 1e-9);
  }

  // 4. The chosen place in the menu: the indicator leaves the overflow slot's own pill (the native fill, whole) and
  // lands on the chosen row whole; closing, it lands back on that slot's pill, never on another slot's, in every pose.
  for (int pose = 0; pose < 3; pose++) {
    bool vertical = pose > 0, mirrored = pose == 2;
    MBOverflow m = overflow_bar(vertical, mirrored, true);
    double now = 3;
    CGFloat thick = mbo_thickness(&m);
    CGRect rest = mbo_resting_pill(&m, 3);
    CGRect first = mbo_resting_pill(&m, 0);
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    CHECK(m.tabContentHidden && m.pillAlpha == 0);
    CHECK(m.indicatorAlpha == 1 && m.indicatorNative == 1);
    CHECK(rect_near(mbo_indicator_frame(&m), CGRectOffset(rest, 0, m.glassHeight - thick), 0.001));
    OverflowRun r = overflow_run(&m, &now, 120);
    CHECK(r.landedOpen == 1);
    // (the follow's ease done: a few frames at rest)
    for (int i = 0; i < 60; i++) {
      now += 1.0 / 120;
      mbo_update_indicator(&m, now);
    }
    CGRect row = mbo_row_frame(&m, 1);
    // (the indicator's frame is in the bar's room: a menu shorter than the bar starts off the bar's start)
    CHECK(rect_near(mbo_indicator_frame(&m), mbo_row_in_bar(&m, 1), 0.5));
    CHECK(m.indicatorAlpha > 0.95 && m.indicatorNative == 0);
    if (!vertical) CHECK(row.size.width == 320 - 16 && row.size.height == 48);
    else CHECK(row.size.width == 48 && row.size.height == mbo_side_menu_width - 16);
    // (inside the glass)
    CHECK(row.origin.x >= 0 && row.origin.y >= 0 && CGRectGetMaxX(row) <= m.barFrame.size.width &&
          CGRectGetMaxY(row) <= mbo_menu_frame(&m).size.height);
    CHECK(r.maxDAlpha < 0.25 && r.maxDInd < 16);

    mbo_close(&m, now);
    CHECK(m.hasLeg && m.leg.closing && m.leg.intoSelection);
    // (on the frame before it lands shut, the indicator is the slot's pill, whole, in the native fill)
    CGRect last = CGRectZero;
    CGFloat lastAlpha = 0, lastNative = 0, lastHeight = 0;
    int frames = 0;
    double maxDInd = 0;
    CGRect was = mbo_indicator_frame(&m);
    while (m.isMorphing && frames++ < 2000) {
      now += 1.0 / 120;
      int s = mbo_step_morph(&m, now);
      mbo_update_indicator(&m, now);
      if (s & MBOStepLandedShut) break;
      last = mbo_indicator_frame(&m);
      lastAlpha = m.indicatorAlpha;
      lastNative = m.indicatorNative;
      lastHeight = m.glassHeight;
      double d = fmax(fabs(CGRectGetMidX(last) - CGRectGetMidX(was)), fabs(CGRectGetMidY(last) - CGRectGetMidY(was)));
      if (d > maxDInd) maxDInd = d;
      was = last;
    }
    CGRect lands = CGRectOffset(rest, 0, lastHeight - thick);
    CHECK(rect_near(last, lands, 1.0));
    CHECK(lastAlpha > 0.99 && lastNative > 0.99);
    CHECK(fabs(CGRectGetMidX(last) - CGRectGetMidX(rest)) < fabs(CGRectGetMidX(last) - CGRectGetMidX(first)));
    CHECK(maxDInd < 16);
    CHECK(!m.visible);
  }

  // 5. The haptic's ticks, the finger step by step. Opened by a finger down on the slot that lets go without moving:
  // nothing more (the owner's one tick at opening is the only one), the menu stays open.
  {
    MBOverflow m = overflow_bar(false, false, false);
    double now = 1;
    CGPoint down = CGPointMake(100 + 4 + 3 * 78 + 39, 880 + 31);
    mbo_open(&m, true, true, down, false, CGRectZero, 0, 0, now);
    int picked = -1;
    CHECK(mbo_update_tracking(&m, CGPointMake(down.x + 3, down.y - 4)) == MBOTrackNone);
    CHECK(mbo_end_tracking(&m, CGPointMake(down.x + 3, down.y - 4), &picked) == MBOTrackNone);
    CHECK(m.isOpen && picked == -1);
    overflow_run(&m, &now, 120);
    CGRect menu = mbo_menu_frame(&m);
    CGPoint row2 = CGPointMake(260, menu.origin.y + 8 + 48 * 2 + 24);
    CGPoint row1 = CGPointMake(260, menu.origin.y + 8 + 48 * 1 + 24);
    // A second finger: one tick as it comes onto a row, none while it stays on it, one for each row it comes onto, none
    // going off the menu, one coming back; let go on a row, that row is chosen (no tick of its own).
    CHECK(mbo_begin_tracking(&m, row2) == MBOTrackTick);
    CHECK(mbo_update_tracking(&m, CGPointMake(row2.x + 10, row2.y + 5)) == MBOTrackNone);
    CHECK(mbo_update_tracking(&m, row1) == MBOTrackTick);
    CHECK(mbo_update_tracking(&m, CGPointMake(row1.x, menu.origin.y - 60)) == MBOTrackNone);
    CHECK(m.hoveredRow == -1);
    CHECK(mbo_update_tracking(&m, row1) == MBOTrackTick);
    CHECK(mbo_end_tracking(&m, row1, &picked) == MBOTrackPick && picked == 1);
    mbo_pick(&m, picked);
    CHECK(m.activeRow == 1 && m.anchorOverflowSelected && m.anchorSelectedSlot == 3);
    mbo_close(&m, now);
    // (closing, the finger does nothing more)
    CHECK(mbo_update_tracking(&m, row2) == MBOTrackNone);
    overflow_run(&m, &now, 120);
    CHECK(!m.visible);

    // Opened by a finger that keeps dragging: nothing till it has left the slot by half the reach, then one tick as it
    // comes onto a row; let go off the rows, the menu closes.
    m = overflow_bar(false, false, false);
    mbo_open(&m, true, true, down, false, CGRectZero, 0, 0, now);
    CHECK(mbo_update_tracking(&m, CGPointMake(down.x, down.y - 9)) == MBOTrackNone);
    CHECK(m.hasOpenPoint);
    CHECK(mbo_update_tracking(&m, CGPointMake(down.x, down.y - 11)) == MBOTrackTick);
    CHECK(!m.hasOpenPoint && m.hoveredRow == 3 && m.fingerInRows);
    CHECK(mbo_update_tracking(&m, CGPointMake(down.x, down.y - 20)) == MBOTrackNone);
    CHECK(mbo_end_tracking(&m, CGPointMake(down.x, menu.origin.y - 80), &picked) == MBOTrackClose);
  }

  // 6. A row's frame and the row under a point agree, the bar across and down either side.
  for (int pose = 0; pose < 3; pose++) {
    MBOverflow m = overflow_bar(pose > 0, pose == 2, false);
    CGRect menu = mbo_menu_frame(&m);
    for (int i = 0; i < 4; i++) {
      CGRect f = mbo_row_frame(&m, i);
      CGPoint mid = CGPointMake(menu.origin.x + CGRectGetMidX(f), menu.origin.y + CGRectGetMidY(f));
      CHECK(mbo_row_at(&m, mid) == i);
    }
    CHECK(mbo_row_at(&m, CGPointMake(menu.origin.x - 200, menu.origin.y - 200)) == -1);
  }

  // 7. Opened from a lifted native lens (a drag that rested on the slot): the indicator starts as that lens (clear
  // glass whole, no grey), turns grey by mbo_lens_to_grey of the growth, and never jumps.
  {
    MBOverflow m = overflow_bar(false, false, false);
    double now = 2;
    CGRect lens = CGRectMake(4 + 3 * 78 - 9, -6, 96, 74);
    mbo_open(&m, true, true, CGPointMake(380, 910), true, lens, 1.0, 0, now);
    CHECK(m.tabContentHidden && m.pillAlpha == 0);
    CHECK(m.handoffShown && m.handoffAlpha == 1 && m.indicatorGrey == 0 && m.indicatorAlpha == 1);
    CHECK(rect_near(mbo_indicator_frame(&m), lens, 0.001));
    CHECK(rect_near(m.handoffFrame, CGRectOffset(lens, 100, 880), 0.001));
    // (the row it will rest on while the finger has not left the slot: the last one)
    CHECK(m.openRow == 3);
    OverflowRun r = overflow_run(&m, &now, 120);
    CHECK(r.landedOpen == 1 && !m.handoffShown && m.indicatorGrey == 1);
    CHECK(r.maxDAlpha < 0.25 && r.maxDInd < 16);
  }

  // 8. Opened again while it closes: the glass goes on from where it is.
  {
    MBOverflow m = overflow_bar(false, false, false);
    double now = 7;
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    overflow_run(&m, &now, 120);
    mbo_close(&m, now);
    for (int i = 0; i < 10; i++) {
      now += 1.0 / 120;
      mbo_step_morph(&m, now);
      mbo_update_indicator(&m, now);
    }
    CGFloat h = m.glassHeight, inset = m.glassInset;
    CHECK(h > 62 && h < 208 && m.isMorphing);
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    CHECK(m.glassHeight == h && m.glassInset == inset && m.isOpen);
    OverflowRun r = overflow_run(&m, &now, 120);
    CHECK(r.landedOpen == 1 && m.glassHeight == 208 && r.maxDH < 16);
    // Put away at once (the bar laid out anew): nothing left showing.
    mbo_dismiss(&m);
    CHECK(!m.visible && !m.isOpen && !m.isMorphing && m.tabsShown == 1 && m.indicatorAlpha == 0);
  }

  // 9. The rows come in one after another from the last, each fading in over 0.16 s and rising 14 points on a spring
  // that overshoots; the crossing of the two contents never leaves the glass empty.
  {
    MBOverflow m = overflow_bar(false, false, false);
    m.riseStart = 100;
    CHECK(mbo_row_shown(&m, 3, 100.045) < 1e-6 && mbo_row_shown(&m, 3, 100.045 + 0.16) > 1 - 1e-6);
    CHECK(mbo_row_shown(&m, 0, 100.045 + 0.032 * 3) < 1e-6 && mbo_row_shown(&m, 0, 100.045 + 0.032 * 3 + 0.16) > 1 - 1e-6);
    CHECK(mbo_row_rise_at(&m, 3, 100.04) == 14);
    double low = 14, was = 0;
    for (int i = 0; i <= 200; i++) {
      double t = 100 + i * 0.005;
      double v = mbo_row_rise_at(&m, 3, t);
      if (v < low) low = v;
      double shown = mbo_row_shown(&m, 3, t);
      CHECK(shown >= was - 1e-9 && shown >= 0 && shown <= 1);
      was = shown;
    }
    CHECK(low < -0.5 && low > -4);
    CHECK(fabs(mbo_row_rise_at(&m, 3, 101)) < 0.01 && mbo_rows_settled(&m, 101.2) && !mbo_rows_settled(&m, 100.2));
    for (int i = 0; i <= 100; i++) {
      double p = i / 100.0;
      CHECK(mbo_tabs_opacity(p) + mbo_rows_opacity(p) > 0.4);
    }
    CHECK(mbo_tabs_opacity(0) == 1 && mbo_rows_opacity(0) == 0 && mbo_tabs_opacity(1) == 0 && mbo_rows_opacity(1) == 1);
  }

  // 10. The overflow slot's zone for a dragging finger, and a lens's lift and enlargement.
  {
    CGRect platter = CGRectMake(100, 880, 320, 62), more = CGRectMake(338, 884, 78, 54);
    CHECK(mbo_on_more_zone(CGPointMake(340, 900), more, platter, false, false, false));
    CHECK(mbo_on_more_zone(CGPointMake(500, 870), more, platter, false, false, false));
    CHECK(!mbo_on_more_zone(CGPointMake(337, 900), more, platter, false, false, false));
    CHECK(!mbo_on_more_zone(CGPointMake(340, 859), more, platter, false, false, false));
    CHECK(mbo_on_more_zone(CGPointMake(337, 900), more, platter, false, false, true));
    CGRect rail = CGRectMake(880, 300, 48, 244), railMore = CGRectMake(882, 482, 44, 60);
    CHECK(mbo_on_more_zone(CGPointMake(900, 490), railMore, rail, true, true, false));
    CHECK(!mbo_on_more_zone(CGPointMake(900, 470), railMore, rail, true, true, false));
    CHECK(!mbo_on_more_zone(CGPointMake(830, 490), railMore, rail, true, true, false));
    CHECK(mbo_lens_lift(54, 54) == 0 && mbo_lens_lift(74, 54) == 1 && mbo_lens_lift(61.5, 54) == 0.5);
    CHECK(mbo_lens_zoom(0, 48, 1) == 1.18 && mbo_lens_zoom(48, 48, 1) == 1 && mbo_lens_zoom(0, 48, 0.05) == 1);
  }

  // 11. Taking over from a pressed bar the system drew larger than at rest (a side bar pressed: wider, longer, standing
  // past its resting edge): the glass starts exactly on it with the tab row whole, that shape leaves with the tab row
  // and never comes back, and the menu lands on its own frame.
  {
    MBOverflow m = overflow_bar(true, true, false);
    double now = 4;
    CGRect live = CGRectMake(200 - 10, 600 - 14, 244 + 42, 48 + 29);  // in the canvas: 10 before, 42 longer, 15 past the outer edge
    CGRect lens = CGRectMake(-6, -20, 94, 84);
    mbo_open_live(&m, true, true, CGPointMake(230, 630), true, lens, 1.0, live.size.height, true, live, now);
    CGRect b = mbo_glass_bounds(&m);
    CGPoint c = mbo_glass_center(&m);
    CHECK(rect_near(CGRectMake(c.x - b.size.width / 2, c.y - b.size.height / 2, b.size.width, b.size.height), live, 0.001));
    CHECK(m.liveShape == 1 && mbo_content_progress(&m) == 0 && mbo_progress(&m) > 0.1);
    CHECK(mbo_tabs_opacity(mbo_content_progress(&m)) == 1);
    // (the lens stands where it was handed over, in the canvas)
    CHECK(rect_near(m.handoffFrame, CGRectOffset(lens, 200, 600), 0.001));
    CGFloat shape = m.liveShape;
    int frames = 0;
    while (m.isMorphing && frames++ < 2000) {
      now += 1.0 / 120;
      mbo_step_morph(&m, now);
      mbo_update_indicator(&m, now);
      CHECK(m.liveShape <= shape + 1e-9);
      shape = m.liveShape;
    }
    CHECK(m.liveShape == 0 && m.isOpen);
    b = mbo_glass_bounds(&m);
    c = mbo_glass_center(&m);
    CHECK(rect_near(CGRectMake(c.x - b.size.width / 2, c.y - b.size.height / 2, b.size.width, b.size.height), mbo_menu_frame(&m), 0.001));
    mbo_close(&m, now);
    OverflowRun r = overflow_run(&m, &now, 120);
    CHECK(r.landedShut == 1 && m.liveShape == 0 && m.liveP0 == 0 && r.maxW <= 244.5);
  }

  // 12. More rows than the room: a bar down a side is as long as it is (here room for four of six), the menu across
  // the foot no taller than it is let. The rows start where the chosen place's row shows; a finger held by an end of
  // the room scrolls them under it, a tick for each row that comes under it, and stops at the last.
  {
    MBOverflow m = overflow_bar(true, true, false);
    m.barFrame = CGRectMake(200, 600, 212, 48);
    m.overflowCount = 6;
    m.activeRow = 5;
    double now = 9;
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    CHECK(mbo_rows_room(&m) == 196 && mbo_max_scroll(&m) == 6 * 48 - 196 && m.scroll == mbo_max_scroll(&m));
    CGRect last = mbo_row_frame(&m, 5), menu = mbo_menu_frame(&m);
    CHECK(last.origin.x >= mbo_menu_padding - 0.001 && CGRectGetMaxX(last) <= menu.size.width - mbo_menu_padding + 0.001);
    overflow_run(&m, &now, 120);
    // (the finger comes onto the row at the far end of the room and stays: the rows scroll back to the first)
    CGPoint held = CGPointMake(menu.origin.x + menu.size.width - mbo_menu_padding - 10, menu.origin.y + 100);
    CHECK(mbo_begin_tracking(&m, held) == MBOTrackTick && m.hoveredRow == 2);
    int ticks = 0, steps = 0;
    while (m.scroll > 0 && steps++ < 600) ticks += mbo_autoscroll(&m, 1.0 / 120) == MBOTrackTick;
    CHECK(m.scroll == 0 && ticks == 2 && m.hoveredRow == 0);
    CHECK(mbo_autoscroll(&m, 1.0 / 120) == MBOTrackNone);
    int picked = -1;
    CHECK(mbo_end_tracking(&m, held, &picked) == MBOTrackPick && picked == 0);

    MBOverflow h = overflow_bar(false, false, false);
    h.overflowCount = 12;
    h.maxMenuHeight = 400;
    CHECK(mbo_menu_frame(&h).size.height == 400 && mbo_max_scroll(&h) == 12 * 48 - 384);
    h.maxMenuHeight = 0;
    CHECK(mbo_menu_frame(&h).size.height == 12 * 48 + 16 && mbo_max_scroll(&h) == 0);
  }
  // 13. Fewer rows than a bar down a side is long: the menu is as long as its rows, at the overflow slot's end of the
  // bar (either end, as the bar is mirrored). The glass is the whole bar while the tab row shows, comes in to the rows
  // as the menu stands, and is the whole bar again before the tab row is back; across the foot the menu is the bar's
  // width whatever its rows.
  for (int mirrored = 0; mirrored < 2; mirrored++) {
    MBOverflow m = overflow_bar(true, mirrored, false);
    m.overflowCount = 2;
    CGRect menu = mbo_menu_frame(&m);
    bool atEnd = mbo_more_at_end(&m);
    CHECK(atEnd == !mirrored && menu.size.width == 2 * 48 + 16 && mbo_max_scroll(&m) == 0);
    CHECK(fabs((atEnd ? CGRectGetMaxX(menu) : menu.origin.x) - (atEnd ? CGRectGetMaxX(m.barFrame) : m.barFrame.origin.x)) < 0.001);
    double now = 20;
    mbo_open(&m, false, false, CGPointZero, false, CGRectZero, 0, 0, now);
    CHECK(mbo_glass_bounds(&m).size.width == m.barFrame.size.width);
    for (int i = 0; i < 240 && m.isMorphing; i++) {
      now += 1.0 / 120;
      mbo_step_morph(&m, now);
      // (never shorter than the bar while any of the tab row shows)
      if (m.tabsShown > 0.001) CHECK(mbo_shrink(&m) == 0);
    }
    CGRect glass = mbo_glass_bounds(&m);
    CGPoint mid = mbo_glass_center(&m);
    CHECK(!m.isMorphing && fabs(glass.size.width - menu.size.width) < 0.001 && fabs(mid.x - CGRectGetMidX(menu)) < 0.001);
    // (a row of the menu is where a finger on it finds it, and the indicator on it lies inside the glass)
    CGRect row = mbo_row_frame(&m, 1);
    CHECK(mbo_row_at(&m, CGPointMake(menu.origin.x + CGRectGetMidX(row), menu.origin.y + 40)) == 1);
    CGRect inBar = mbo_row_in_bar(&m, 1);
    CHECK(fabs(inBar.origin.x - mbo_glass_shift(&m).x - row.origin.x) < 0.001);
    mbo_close(&m, now);
    for (int i = 0; i < 240 && m.isMorphing; i++) {
      now += 1.0 / 120;
      mbo_step_morph(&m, now);
      if (m.tabsShown > 0.001) CHECK(mbo_shrink(&m) == 0);
    }
    CHECK(!m.isMorphing && mbo_glass_bounds(&m).size.width == m.barFrame.size.width);
  }
  {
    MBOverflow h = overflow_bar(false, false, false);
    h.overflowCount = 1;
    CHECK(mbo_menu_frame(&h).size.width == h.barFrame.size.width && mbo_menu_start(&h) == 0);
  }
}

int main(void) {
  @autoreleasepool {
    test_apple_grab();
    test_ios_nav_state();
    test_ios_nav_overflow();
  }
  if (!failed) printf("apple_grab_nav_test: ok\n");
  return failed;
}
