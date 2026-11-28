// Pure Foundation/CoreGraphics state helpers for ios_nav.h, kept UIKit-free so macOS unit tests can verify them.
#import <CommonCrypto/CommonDigest.h>
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

typedef enum {
  MBIosNavOverflowActionNoOverflowCache = 0, // All places fit (or tabBar has no overflow); cache lkey.
  MBIosNavOverflowActionNotLaidOut = 1,      // Regular tab frames are not laid out yet; clear cached lkey.
  MBIosNavOverflowActionCollapse = 2,        // Genuine overflow: 0 < visiblePlaces < allPlacesCount.
} MBIosNavOverflowAction;

// Decide overflow outcome after measuring regular place tab frames. On iOS 27.1+ with a prominent action tab,
// `tabBarItemCount < tabsCount` holds even when every regular place fits (`visiblePlaces >= allPlacesCount`);
// caching `lkey` prevents repeated synchronous `layoutIfNeeded` overflow probes on every `nav_bar` spec change.
static inline MBIosNavOverflowAction mb_ios_nav_overflow_action(NSUInteger tabBarItemCount, NSUInteger tabsCount,
                                                                NSUInteger visiblePlaces, NSUInteger allPlacesCount) {
  if (tabBarItemCount == 0 || tabBarItemCount >= tabsCount) return MBIosNavOverflowActionNoOverflowCache;
  if (allPlacesCount == 0 || visiblePlaces >= allPlacesCount) return MBIosNavOverflowActionNoOverflowCache;
  if (visiblePlaces == 0) return MBIosNavOverflowActionNotLaidOut;
  return MBIosNavOverflowActionCollapse;
}

// Whether `checkOverflowAfterLayout` should inspect per-tab frames when uncollapsed. Skips once `overflowLayoutKey`
// already matches `lkey` unless `provisional` is set (allowing one post-layout confirmation pass after `tabsChanged`
// in case UIKit deferred prominent-bar layout past the synchronous `layoutIfNeeded`).
static inline BOOL mb_ios_nav_should_check_overflow_after_layout(NSUInteger visibleRegularCap, NSString *lkey,
                                                                 NSString *overflowLayoutKey, BOOL provisional,
                                                                 NSUInteger tabBarItemCount, NSUInteger tabsCount) {
  if (visibleRegularCap > 0) return NO;
  if (!provisional && lkey.length && [lkey isEqualToString:overflowLayoutKey]) return NO;
  return tabBarItemCount > 0 && tabBarItemCount < tabsCount;
}

// Deterministic length-prefixed key for displayed tab structure (regular places, overflow More tab, and action tab).
// Intentionally omits accent color (`chosen_ink`) so accent/theme changes update tint/wash in place without tearing
// down and rebuilding `UITabBarController.tabs`.
static inline NSString *mb_ios_nav_tabs_key(NSArray<NSDictionary *> *visible, BOOL hasOverflow, NSString *moreId,
                                            NSDictionary *act) {
  NSMutableString *key = [NSMutableString string];
  for (id row in visible) {
    if (![row isKindOfClass:NSDictionary.class]) continue;
    NSDictionary *t = (NSDictionary *)row;
    NSString *ident = [t[@"id"] isKindOfClass:NSString.class] ? t[@"id"] : @"";
    [key appendFormat:@"%lu:%@|", (unsigned long)ident.length, ident];
  }
  if (hasOverflow) {
    NSString *mid = moreId ?: @"";
    [key appendFormat:@"M%lu:%@|", (unsigned long)mid.length, mid];
  }
  if ([act isKindOfClass:NSDictionary.class]) {
    NSString *aid = [act[@"id"] isKindOfClass:NSString.class] ? act[@"id"] : @"";
    NSString *atitle = [act[@"title"] isKindOfClass:NSString.class] ? act[@"title"] : @"";
    NSString *aicon = [act[@"icon"] isKindOfClass:NSString.class] ? act[@"icon"] : @"";
    [key appendFormat:@"!%lu:%@|%lu:%@|%lu:%@", (unsigned long)aid.length, aid,
         (unsigned long)atitle.length, atitle, (unsigned long)aicon.length, aicon];
  }
  return key;
}

// Whether `apply:` should synchronously invoke `washAction` to attach, hide, or re-tint the prominent tab's glass wash.
static inline BOOL mb_ios_nav_wash_needed(BOOL tabsChanged, BOOL hiddenChanged, BOOL bare, BOOL hasActionInk,
                                          BOOL washInWindow, BOOL washInkMatches) {
  BOOL skipSyncWash = hiddenChanged && !bare && !tabsChanged;
  if (skipSyncWash) return NO;
  if (tabsChanged || hiddenChanged) return YES;
  return hasActionInk && !bare && (!washInWindow || !washInkMatches);
}

// Whether `apply:` should also schedule an async follow-up `washAction` on the next runloop turn (only needed when
// UIKit may still be creating or re-mounting the platter, not for an in-place re-tint of a mounted wash).
static inline BOOL mb_ios_nav_wash_async_needed(BOOL tabsChanged, BOOL hiddenChanged, BOOL bare, BOOL hasActionInk,
                                                BOOL washInWindow) {
  if (!hasActionInk || bare) return NO;
  return tabsChanged || hiddenChanged || !washInWindow;
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

// Cache key for composite avatar icons (`nav_avatars`). Hashes specs longer than 256 characters (e.g. inline
// base64 `data:` URLs) with SHA-256 so large URLs are not copied verbatim into NSCache keys on every lookup.
static inline NSString *mb_ios_nav_avatar_cache_key(CGFloat size, CGFloat scale, NSString *spec) {
  NSString *s = spec ?: @"";
  if (s.length <= 256) return mb_ios_nav_icon_cache_key('a', size, scale, s);
  NSData *utf8 = [s dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(utf8.bytes, (CC_LONG)utf8.length, digest);
  static const char hex[] = "0123456789abcdef";
  char out[CC_SHA256_DIGEST_LENGTH * 2 + 1];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
    out[i * 2] = hex[(digest[i] >> 4) & 0xF];
    out[i * 2 + 1] = hex[digest[i] & 0xF];
  }
  out[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
  return [NSString stringWithFormat:@"a#:%.2f:%.2f:%lu:%s", (double)size, (double)scale, (unsigned long)utf8.length, out];
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
