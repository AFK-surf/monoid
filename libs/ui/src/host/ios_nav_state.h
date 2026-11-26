// Pure Foundation/CoreGraphics state helpers for ios_nav.h, kept UIKit-free so macOS unit tests can verify them.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdint.h>

typedef struct {
  BOOL valid;
  uintptr_t winTag;
  CGRect bounds;
  double radii[4];
} MBCornerCache;

// Clear the cached overflow layout signature if tabs changed while the tab bar was hidden (`bare`), so exiting `bare`
// still re-probes overflow with the new tab list.
static inline NSString *mb_ios_nav_next_overflow_layout_key(BOOL bare, BOOL tabsChanged, NSString *overflowLayoutKey) {
  if (bare && tabsChanged) return nil;
  return overflowLayoutKey;
}

// Re-probe UIKit tab overflow only when tabs are visible, attached to a window, uncollapsed, have more than one place,
// and either the tabs or the layout signature changed (never on a plain `bare: YES -> NO` reveal with unchanged layout).
static inline BOOL mb_ios_nav_needs_overflow_probe(BOOL bare, BOOL hasWindow, NSUInteger visibleRegularCap,
                                                   NSUInteger placesCount, BOOL tabsChanged, NSString *lkey,
                                                   NSString *overflowLayoutKey) {
  return !bare && hasWindow && visibleRegularCap == 0 && placesCount > 1 &&
         (tabsChanged || ![lkey isEqualToString:overflowLayoutKey]);
}

// Whether a tab slot needs its navigation bar items synchronized to the latest `actsKey`.
static inline BOOL mb_ios_nav_slot_needs_bar_items(NSString *appliedActsKey, NSString *actsKey, BOOL hasLastItems) {
  if (!hasLastItems || !actsKey.length) return NO;
  return ![appliedActsKey isEqualToString:actsKey];
}

// Cache key for rendered nav bar icon, badge, and letter images.
static inline NSString *mb_ios_nav_icon_cache_key(char kind, CGFloat size, CGFloat scale, NSString *spec) {
  return [NSString stringWithFormat:@"%c:%.2f:%.2f:%@", kind, (double)size, (double)scale, spec ?: @""];
}

static inline BOOL mb_corner_cache_hit(const MBCornerCache *cache, uintptr_t winTag, CGRect bounds, int corner,
                                       double *outRadius) {
  if (!cache || !cache->valid || winTag == 0 || cache->winTag != winTag) return NO;
  if (!CGRectEqualToRect(cache->bounds, bounds)) return NO;
  if (outRadius) *outRadius = cache->radii[corner & 3];
  return YES;
}

static inline void mb_corner_cache_store(MBCornerCache *cache, uintptr_t winTag, CGRect bounds, const double radii[4]) {
  if (!cache) return;
  cache->valid = (winTag != 0);
  cache->winTag = winTag;
  cache->bounds = bounds;
  for (int i = 0; i < 4; i++) cache->radii[i] = radii[i];
}

static inline void mb_corner_cache_invalidate(MBCornerCache *cache) {
  if (!cache) return;
  cache->valid = NO;
  cache->winTag = 0;
  cache->bounds = CGRectZero;
}
