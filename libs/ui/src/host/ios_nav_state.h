// Pure Foundation/CoreGraphics state helpers for ios_nav.h, kept UIKit-free so macOS unit tests can verify them.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <math.h>
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

// Compact deterministic key for a floating glass button spec + ink RGBA value, avoiding multi-line NSDictionary
// description allocations on every nav_bar apply. Every string field is length-prefixed so arbitrary user text
// (such as workspace titles containing control characters) cannot collide across field boundaries.
static inline NSString *mb_ios_nav_floating_item_key(NSDictionary *d, uint64_t inkVal) {
  if (![d isKindOfClass:NSDictionary.class]) {
    return [NSString stringWithFormat:@"%llx", (unsigned long long)inkVal];
  }
  NSString *ident = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : @"";
  NSString *title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"";
  NSString *icon = [d[@"icon"] isKindOfClass:NSString.class] ? d[@"icon"] : @"";
  int dot = [d[@"dot"] boolValue] ? 1 : 0;
  int prominent = [d[@"prominent"] boolValue] ? 1 : 0;
  NSMutableString *key = [NSMutableString stringWithFormat:@"%lu:%@|%lu:%@|%lu:%@|%d|%d|%llx",
                          (unsigned long)ident.length, ident, (unsigned long)title.length, title,
                          (unsigned long)icon.length, icon, dot, prominent, (unsigned long long)inkVal];
  NSArray *menu = [d[@"menu"] isKindOfClass:NSArray.class] ? d[@"menu"] : nil;
  for (id row in menu) {
    if (![row isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *m = (NSDictionary *)row;
    NSString *mid = [m[@"id"] isKindOfClass:NSString.class] ? m[@"id"] : @"";
    NSString *mtitle = [m[@"title"] isKindOfClass:NSString.class] ? m[@"title"] : @"";
    int mchecked = [m[@"checked"] boolValue] ? 1 : 0;
    NSString *micon = [m[@"icon"] isKindOfClass:NSString.class] ? m[@"icon"] : @"";
    [key appendFormat:@";%lu:%@|%lu:%@|%d|%lu:%@",
         (unsigned long)mid.length, mid, (unsigned long)mtitle.length, mtitle, mchecked,
         (unsigned long)micon.length, micon];
  }
  return key;
}

// Whether a tint/ink color value needs to be applied to UIKit (always true before initialization, then only on change).
static inline BOOL mb_ios_nav_color_changed(BOOL initialized, uint64_t prevVal, uint64_t nextVal) {
  return !initialized || prevVal != nextVal;
}

// Single source of truth for matching a tab bar platter rect against `[UITab frameInView:]` in root coordinates
// (midpoint and width within 2pt, rejecting empty/Null/Infinite rects). Used by both `nav_platter` and the O(1)
// `washAction` fast path so a mounted platter that has not moved always hits the fast path.
static inline BOOL mb_ios_nav_wash_rect_matches(CGRect washInRoot, CGRect tabInRoot) {
  if (CGRectIsNull(washInRoot) || CGRectIsInfinite(washInRoot) || CGRectIsEmpty(washInRoot)) return NO;
  if (CGRectIsNull(tabInRoot) || CGRectIsInfinite(tabInRoot) || CGRectIsEmpty(tabInRoot)) return NO;
  return fabs(CGRectGetMidX(washInRoot) - CGRectGetMidX(tabInRoot)) < 2.0 &&
         fabs(CGRectGetMidY(washInRoot) - CGRectGetMidY(tabInRoot)) < 2.0 &&
         fabs(washInRoot.size.width - tabInRoot.size.width) < 2.0;
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
