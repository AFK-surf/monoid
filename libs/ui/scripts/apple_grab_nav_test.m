// src/host/apple_grab.h and src/host/ios_nav_state.h deterministic tests:
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

int main(void) {
  @autoreleasepool {
    test_apple_grab();
    test_ios_nav_state();
  }
  if (!failed) printf("apple_grab_nav_test: ok\n");
  return failed;
}
