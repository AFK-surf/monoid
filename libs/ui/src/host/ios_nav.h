// The system's own bars for the app's places and actions (@hostapi.nav_bar, src/hostapi/nav.mbt): where the system
// lays out an app's tabs in every pose of its screens (an iPhone Duo's, iOS 27.1: down the trailing edge on its side
// and on its outer screen, across the top and foot upright), the app's tabs, its actions and its menus handed to it,
// laid out and drawn by it in its own glass. Included by ios_app.m, whose statics it uses (the_view, the_controller,
// say_system); all of it apart from the app's own frame, which every other iPhone keeps. What came after iOS 18 is
// under its SDK's macro as well as @available: the app is built with iOS 18's SDK too (CI's Xcode 16).

// ---- the system's own bars (@hostapi.nav_bar: src/hostapi/nav.mbt) ----
// The app's view in a UITabBarController's chosen tab, each tab a UINavigationController over a slot the app's
// controller moves into as its tab is chosen: the places the app hands over its tabs, its actions the navigation bar's
// items, laid out by the system as its own apps' are (down the trailing edge on an iPhone Duo's outer screen and its
// inner one on its side, iOS 27.1; across the view's top and foot upright), in its own glass. No tabs (the app's own
// frame on a phone): neither bar, the app's view the whole window as before. Chosen, a tab or an item said to the app on
// the system channel (`{"nav": id}`).

#import "ios_nav_state.h"

static NSCache<NSString *, UIImage *> *nav_img_cache(void) {
  static NSCache<NSString *, UIImage *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
    cache.countLimit = 256;
  });
  return cache;
}

static CGFloat nav_display_scale(void) {
  CGFloat s = the_view ? the_view.traitCollection.displayScale : 0;
  if (s <= 0) s = the_controller ? the_controller.traitCollection.displayScale : 0;
  return s > 0 ? s : 2.0;
}

// An icon of the app's (sfapp icon_data: groups of a kind (0 a line, 1 closed, 2 filled), a stroke's width, how many
// points and the points, on a 24 grid) as a template image `size` across, for the bars to tint.
static UIImage *nav_icon(NSString *data, CGFloat size) {
  NSString *cacheKey = mb_ios_nav_icon_cache_key('i', size, nav_display_scale(), data);
  UIImage *cached = [nav_img_cache() objectForKey:cacheKey];
  if (cached) return cached;
  NSArray<NSString *> *parts = [data componentsSeparatedByString:@" "];
  NSMutableArray<NSNumber *> *n = [NSMutableArray arrayWithCapacity:parts.count];
  for (NSString *p in parts)
    if (p.length) [n addObject:@(p.doubleValue)];
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
  UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    CGContextScaleCTM(ctx.CGContext, size / 24, size / 24);
    [UIColor.blackColor setStroke];
    [UIColor.blackColor setFill];
    NSUInteger i = 0;
    // (7: a piece of one shape of many, filled once the pieces end, by the even-odd rule where its width is 1)
    UIBezierPath *compound = nil;
    while (i + 2 < n.count) {
      int kind = n[i].intValue;
      double width = n[i + 1].doubleValue;
      NSUInteger k = n[i + 2].unsignedIntegerValue;
      i += 3;
      if (i + 2 * k > n.count) break;
      if (kind != 7 && compound) {
        [compound fill];
        compound = nil;
      }
      if (kind == 7) {
        if (!compound) {
          compound = [UIBezierPath bezierPath];
          compound.usesEvenOddFillRule = width > 0.5;
        }
        for (NSUInteger j = 0; j < k; j++) {
          CGPoint pt = CGPointMake(n[i + 2 * j].doubleValue, n[i + 2 * j + 1].doubleValue);
          if (j == 0) [compound moveToPoint:pt];
          else [compound addLineToPoint:pt];
        }
        [compound closePath];
        i += 2 * k;
        continue;
      }
      // (4: the alpha of what comes after, its width; 5: a shape cut out of what is drawn)
      if (kind == 4) {
        CGContextSetAlpha(ctx.CGContext, width);
        continue;
      }
      UIBezierPath *p = [UIBezierPath bezierPath];
      p.lineCapStyle = kCGLineCapRound;
      p.lineJoinStyle = kCGLineJoinRound;
      for (NSUInteger j = 0; j < k; j++) {
        CGPoint pt = CGPointMake(n[i + 2 * j].doubleValue, n[i + 2 * j + 1].doubleValue);
        if (j == 0) [p moveToPoint:pt];
        else [p addLineToPoint:pt];
      }
      i += 2 * k;
      if (kind >= 1) [p closePath];
      if (kind == 5) [p fillWithBlendMode:kCGBlendModeClear alpha:1];
      else if (kind == 2) [p fill];
      else {
        p.lineWidth = width;
        [p stroke];
      }
    }
    if (compound) [compound fill];
  }];
  UIImage *out = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  if (out) [nav_img_cache() setObject:out forKey:cacheKey];
  return out;
}

// People as an icon (`avatars:` then each `rrggbbaa,letter` (an alpha of 0: no disc, the letter alone) apart by `\x1d`, at most three; `\x1f` and a picture's
// address after one that has one): their discs, each its picture once loaded (`then` told), else its letter in white
// on its colour, the ones after a little over the one before, in their own colours (not the bar's tint).
static UIImage *nav_picture(NSString *url, CGFloat size, BOOL round, void (^then)(void));
static UIImage *nav_avatars(NSString *spec, CGFloat size, void (^then)(void)) {
  NSArray<NSString *> *each = [[spec substringFromIndex:8] componentsSeparatedByString:@"\x1d"];
  NSUInteger n = MIN(each.count, (NSUInteger)3);
  if (!n) return nil;
  CGFloat d = size, step = size * 0.6, ring = 1.5;
  CGSize all = CGSizeMake(d + step * (n - 1), d);
  NSMutableArray *faces = [NSMutableArray array];
  for (NSUInteger i = 0; i < n; i++) {
    NSRange pic = [each[i] rangeOfString:@"\x1f"];
    UIImage *got = pic.location == NSNotFound ? nil : nav_picture([each[i] substringFromIndex:pic.location + 1], d, YES, then);
    [faces addObject:got ?: NSNull.null];
  }
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:all];
  UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    for (NSUInteger i = 0; i < n; i++) {
      NSString *one = each[i];
      NSRange pic = [one rangeOfString:@"\x1f"];
      if (pic.location != NSNotFound) one = [one substringToIndex:pic.location];
      NSArray<NSString *> *p = [one componentsSeparatedByString:@","];
      if (p.count < 2) continue;
      unsigned long long c = strtoull(p[0].UTF8String, NULL, 16);
      UIColor *ground = [UIColor colorWithRed:((c >> 24) & 0xFF) / 255.0 green:((c >> 16) & 0xFF) / 255.0
                                          blue:((c >> 8) & 0xFF) / 255.0 alpha:1];
      CGRect disc = CGRectMake(step * i, 0, d, d);
      // (cut out of the one before by a ring, as the app's stack has them)
      if (i > 0) [[UIBezierPath bezierPathWithOvalInRect:CGRectInset(disc, -ring, -ring)] fillWithBlendMode:kCGBlendModeClear alpha:1];
      if (faces[i] != NSNull.null) {
        [(UIImage *)faces[i] drawInRect:disc];
        continue;
      }
      // (a colour of no alpha: the letter (an emoji) on the glass alone, larger)
      BOOL bare = (c & 0xFF) == 0;
      if (!bare) {
        [ground setFill];
        [[UIBezierPath bezierPathWithOvalInRect:disc] fill];
      }
      NSString *letter = [[p subarrayWithRange:NSMakeRange(1, p.count - 1)] componentsJoinedByString:@","];
      UIFont *font = [UIFont systemFontOfSize:d * (bare ? 0.62 : 0.5) weight:UIFontWeightSemibold];
      NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : UIColor.whiteColor};
      CGSize s = [letter sizeWithAttributes:attrs];
      [letter drawAtPoint:CGPointMake(CGRectGetMidX(disc) - s.width / 2, CGRectGetMidY(disc) - s.height / 2) withAttributes:attrs];
    }
  }];
  return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// A workspace's mark as an icon (`badge:rrggbbaa,letter`): its letter (or emoji) in white on a rounded square of its
// colour, in its own colours, a little smaller than the tabs' icons so the system's lit ground shows round it.
static UIImage *nav_badge(NSString *spec, CGFloat size) {
  NSString *cacheKey = mb_ios_nav_icon_cache_key('b', size, nav_display_scale(), spec);
  UIImage *cached = [nav_img_cache() objectForKey:cacheKey];
  if (cached) return cached;
  NSArray<NSString *> *p = [[spec substringFromIndex:6] componentsSeparatedByString:@","];
  if (p.count < 2) return nil;
  unsigned long long c = strtoull(p[0].UTF8String, NULL, 16);
  UIColor *ground = [UIColor colorWithRed:((c >> 24) & 0xFF) / 255.0 green:((c >> 16) & 0xFF) / 255.0
                                      blue:((c >> 8) & 0xFF) / 255.0 alpha:1];
  NSString *letter = [[p subarrayWithRange:NSMakeRange(1, p.count - 1)] componentsJoinedByString:@","];
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
  UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    CGRect box = CGRectInset(CGRectMake(0, 0, size, size), 1, 1);
    [ground setFill];
    [[UIBezierPath bezierPathWithRoundedRect:box cornerRadius:size * 0.28] fill];
    UIFont *font = [UIFont systemFontOfSize:size * 0.5 weight:UIFontWeightSemibold];
    NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : UIColor.whiteColor};
    CGSize s = [letter sizeWithAttributes:attrs];
    [letter drawAtPoint:CGPointMake(CGRectGetMidX(box) - s.width / 2, CGRectGetMidY(box) - s.height / 2) withAttributes:attrs];
  }];
  UIImage *out = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
  if (out) [nav_img_cache() setObject:out forKey:cacheKey];
  return out;
}

// The side of a workspace's mark on the bar's button (nav_avatars): the glass a thin ring round it.
static const CGFloat nav_face = 40;

// A picture by its address (an https link, a data: URL) as a mark: rounded, in its own colours; loaded once, kept by
// its address (nil while it comes: `then` is told once it is here, each asker's, not the first's alone: the bars are
// made again while it comes, and only the items made last are shown).
static NSMutableDictionary<NSString *, UIImage *> *nav_pictures;
static NSMutableDictionary<NSString *, NSMutableArray *> *nav_loading;
static UIImage *nav_picture(NSString *url, CGFloat size, BOOL round, void (^then)(void)) {
  if (!nav_pictures) {
    nav_pictures = [NSMutableDictionary dictionary];
    nav_loading = [NSMutableDictionary dictionary];
  }
  NSString *key = [NSString stringWithFormat:@"%@\x1f%.0f%@", url, size, round ? @"o" : @""];
  UIImage *had = nav_pictures[key];
  if (had) return had;
  void (^made)(NSData *) = ^(NSData *data) {
    UIImage *raw = data ? [UIImage imageWithData:data] : nil;
    if (!raw) return;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
      CGRect box = round ? CGRectMake(0, 0, size, size) : CGRectInset(CGRectMake(0, 0, size, size), 1, 1);
      [(round ? [UIBezierPath bezierPathWithOvalInRect:box] : [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:size * 0.24]) addClip];
      // (covering the square, as the app's marks are: FitCover)
      CGFloat k = MAX(box.size.width / raw.size.width, box.size.height / raw.size.height);
      CGSize s = CGSizeMake(raw.size.width * k, raw.size.height * k);
      [raw drawInRect:CGRectMake(CGRectGetMidX(box) - s.width / 2, CGRectGetMidY(box) - s.height / 2, s.width, s.height)];
    }];
    nav_pictures[key] = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
  };
  if ([url hasPrefix:@"data:"]) {
    NSRange comma = [url rangeOfString:@","];
    if (comma.location == NSNotFound) return nil;
    made([[NSData alloc] initWithBase64EncodedString:[url substringFromIndex:comma.location + 1]
                                             options:NSDataBase64DecodingIgnoreUnknownCharacters]);
    return nav_pictures[key];
  }
  NSURL *u = [NSURL URLWithString:url];
  if (!u) return nil;
  NSMutableArray *waiting = nav_loading[key];
  if (waiting) {
    if (then) [waiting addObject:then];
    return nil;
  }
  nav_loading[key] = waiting = [NSMutableArray array];
  if (then) [waiting addObject:then];
  [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSArray *told = nav_loading[key];
      [nav_loading removeObjectForKey:key];
      made(err ? nil : data);
      if (nav_pictures[key])
        for (void (^t)(void) in told) t();
    });
  }] resume];
  return nil;
}

// An icon of the app's in any of its forms: people's faces, a workspace's mark (its picture, `\x1e` and its
// address after it, in place of the mark once loaded: `then` told), else its shapes.
static UIImage *nav_any_then(NSString *icon, CGFloat size, void (^then)(void)) {
  NSRange pic = [icon rangeOfString:@"\x1e"];
  if (pic.location != NSNotFound) {
    UIImage *got = nav_picture([icon substringFromIndex:pic.location + 1], size, NO, then);
    if (got) return got;
    icon = [icon substringToIndex:pic.location];
  }
  if ([icon hasPrefix:@"avatars:"]) return nav_avatars(icon, size, then);
  if ([icon hasPrefix:@"badge:"]) return nav_badge(icon, size);
  return nav_icon(icon, size);
}

static UIImage *nav_any(NSString *icon, CGFloat size) { return nav_any_then(icon, size, nil); }

// An item with no icon of its own (a workspace's): its first letter, set in the system's font, as its icon.
static UIImage *nav_letter(NSString *title, CGFloat size) {
  if (!title.length) return nil;
  NSString *letter = [title substringWithRange:[title rangeOfComposedCharacterSequenceAtIndex:0]];
  NSString *cacheKey = mb_ios_nav_icon_cache_key('l', size, nav_display_scale(), letter);
  UIImage *cached = [nav_img_cache() objectForKey:cacheKey];
  if (cached) return cached;
  UIFont *font = [UIFont systemFontOfSize:size * 0.72 weight:UIFontWeightSemibold];
  NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : UIColor.blackColor};
  CGSize s = [letter sizeWithAttributes:attrs];
  UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
  UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    [letter drawAtPoint:CGPointMake((size - s.width) / 2, (size - s.height) / 2) withAttributes:attrs];
  }];
  UIImage *out = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  if (out) [nav_img_cache() setObject:out forKey:cacheKey];
  return out;
}

// The system's tab bar for the app's places (iOS 18's UITabBarController with UITabs: on an iPhone Duo's inner screen on
// its side and its outer one, iOS 27.1 lays it down the trailing edge at its foot; upright, across the view's foot), in
// its own glass, with its own motion; the one action most wanted a tab of its own after them (pinned, iOS 27's prominent tab, set
// apart as the system sets search apart), which does what it says and is never chosen. Each tab a
// UINavigationController over a slot the app's controller moves into as its tab is chosen, its bar hidden: what a page
// does is the page's own, in its content. No tabs (the app's own frame on a phone): none, the app's view the whole
// window as before. Chosen, a tab is said to the app on the system channel (`{"nav": id}`).

// A tab's page: the app's controller in it while its tab is chosen, the status bar, the home indicator and the turns
// asked of it.
@interface MBSlot : UIViewController
@property(nonatomic, strong) NSDictionary<NSString *, UIBarButtonItem *> *barItems;
@property(nonatomic, strong) NSDictionary<NSString *, NSDictionary *> *barSpecs;
@property(nonatomic, strong) UIColor *barInk;
@property(nonatomic, strong) UIColor *barAccent;
@property(nonatomic, copy) NSString *appliedActsKey;
@end

@implementation MBSlot
- (UIViewController *)childViewControllerForStatusBarStyle { return the_controller; }
- (UIViewController *)childViewControllerForStatusBarHidden { return the_controller; }
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return the_controller; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return the_controller.supportedInterfaceOrientations; }
@end

// The visual capsule follows the app's header height; its touch target remains at least 44 points high.
@interface MBFloatingButton : UIButton
@property(nonatomic) BOOL inputBlocked;
@end
@implementation MBFloatingButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  if (self.inputBlocked) return NO;
  return CGRectContainsPoint(CGRectInset(self.bounds, -MAX(0, (44 - self.bounds.size.width) / 2),
                                        -MAX(0, (44 - self.bounds.size.height) / 2)), point);
}
@end

// The action's wash inside its tab's platter (MBTabs washAction), told when it leaves the window with a platter UIKit
// let go of (the tabs made again as the bar's places change make the platters anew): left there, the action showed
// its white glyph on untinted glass until something else laid the tabs out.
@interface MBActionWash : UIView
@property(nonatomic, copy) void (^gone)(void);
@end
@implementation MBActionWash
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (!self.window && self.superview && self.gone) self.gone();
}
@end

static NSString *const nav_more_id = @"__mbui_more__";

// Popover listing tabs that did not fit in the system tab bar, anchored to our own overflow tab so UIKit's
// full-screen moreNavigationController never replaces the app's canvas.
API_AVAILABLE(ios(18.0))
@interface MBMorePopoverController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, copy) NSString *selectedId;
@property(nonatomic, strong) UIColor *ink;
@property(nonatomic, strong) UIColor *accent;
@property(nonatomic, copy) void (^onPick)(NSString *ident);
- (void)reloadItems:(NSArray<NSDictionary *> *)items selectedId:(NSString *)selectedId ink:(UIColor *)ink accent:(UIColor *)accent;
@end

@implementation MBMorePopoverController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.tableView.backgroundColor = UIColor.clearColor;
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
  self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
  self.tableView.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, CGFLOAT_MIN)];
  self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, CGFLOAT_MIN)];
  [self updatePreferredSize];
}
- (void)reloadItems:(NSArray<NSDictionary *> *)items selectedId:(NSString *)selectedId ink:(UIColor *)ink accent:(UIColor *)accent {
  self.items = items;
  self.selectedId = selectedId;
  self.ink = ink;
  self.accent = accent;
  [self updatePreferredSize];
  if (self.isViewLoaded) [self.tableView reloadData];
}
- (void)updatePreferredSize {
  UIFont *font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  CGFloat maxW = 0;
  for (NSDictionary *d in self.items) {
    NSString *title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"";
    CGFloat w = [title sizeWithAttributes:@{NSFontAttributeName : font}].width;
    if (w > maxW) maxW = w;
  }
  CGFloat width = MIN(MAX(ceil(maxW) + 16 + 24 + 12 + 36 + 16, 184), 260);
  NSUInteger rows = MIN(self.items.count, (NSUInteger)6);
  if (self.isViewLoaded) self.tableView.scrollEnabled = self.items.count > 6;
  self.preferredContentSize = CGSizeMake(width, MAX(rows, (NSUInteger)1) * 48);
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 48; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"mbmore"];
  if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"mbmore"];
  NSDictionary *d = self.items[ip.row];
  NSString *ident = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : @"";
  NSString *title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"";
  NSString *iconSpec = [d[@"icon"] isKindOfClass:NSString.class] ? d[@"icon"] : @"";
  BOOL isSelected = self.selectedId.length && [ident isEqualToString:self.selectedId];
  BOOL dot = [d[@"dot"] boolValue];
  UIColor *rowInk = isSelected ? (self.accent ?: UIColor.tintColor) : (self.ink ?: UIColor.labelColor);
  UIListContentConfiguration *cfg = [UIListContentConfiguration cellConfiguration];
  cfg.text = title;
  cfg.textProperties.font = [UIFont systemFontOfSize:16 weight:(isSelected ? UIFontWeightSemibold : UIFontWeightRegular)];
  cfg.textProperties.color = rowInk;
  cfg.image = iconSpec.length ? nav_any(iconSpec, 22) : nav_letter(title, 22);
  cfg.imageProperties.tintColor = rowInk;
  cfg.imageProperties.maximumSize = CGSizeMake(22, 22);
  cfg.imageProperties.reservedLayoutSize = CGSizeMake(22, 22);
  cfg.imageToTextPadding = 12;
  cfg.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(0, 16, 0, 16);
  cell.contentConfiguration = cfg;
  cell.backgroundColor = UIColor.clearColor;
  if (isSelected || dot) {
    UIStackView *acc = [UIStackView new];
    acc.axis = UILayoutConstraintAxisHorizontal;
    acc.alignment = UIStackViewAlignmentCenter;
    acc.spacing = 8;
    if (dot) {
      UIView *dview = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
      dview.backgroundColor = UIColor.systemRedColor;
      dview.layer.cornerRadius = 4;
      [dview.widthAnchor constraintEqualToConstant:8].active = YES;
      [dview.heightAnchor constraintEqualToConstant:8].active = YES;
      [acc addArrangedSubview:dview];
    }
    if (isSelected) {
      UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
      UIImageView *chk = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:sc]];
      chk.tintColor = self.accent ?: UIColor.tintColor;
      [acc addArrangedSubview:chk];
    }
    CGSize fit = [acc systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    acc.frame = CGRectMake(0, 0, fit.width, fit.height);
    cell.accessoryView = acc;
  } else {
    cell.accessoryView = nil;
  }
  cell.separatorInset = (ip.row + 1 == (NSInteger)self.items.count)
                            ? UIEdgeInsetsMake(0, 0, 0, 10000)
                            : UIEdgeInsetsMake(0, 16, 0, 16);
  return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [tv deselectRowAtIndexPath:ip animated:YES];
  NSDictionary *d = ip.row < (NSInteger)self.items.count ? self.items[ip.row] : nil;
  NSString *ident = [d[@"id"] isKindOfClass:NSString.class] ? d[@"id"] : @"";
  void (^cb)(NSString *) = self.onPick;
  [self dismissViewControllerAnimated:YES completion:nil];
  if (cb && ident.length) cb(ident);
}
@end

API_AVAILABLE(ios(18.0))
@interface MBTabs : UITabBarController <UITabBarControllerDelegate, UIPopoverPresentationControllerDelegate>
@property(nonatomic, copy) NSString *spec;
@property(nonatomic, copy) NSString *tabsKey;
@property(nonatomic, copy) NSString *action;
// (iOS 27: the accent the action's glass is tinted with, and its tinted UIGlassEffect view inside the platter)
@property(nonatomic, strong) UIColor *actionInk;
@property(nonatomic, strong) UIColor *actionWashInk;
@property(nonatomic, strong) MBActionWash *actionWash;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIButton *> *floatingButtons;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *floatingKeys;
@property(nonatomic) BOOL shown;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UINavigationController *> *navs;
// Direct map from tab id to its slot so nav_put and barItems never lose the slot if UIKit rearranges a nav stack.
@property(nonatomic, strong) NSMutableDictionary<NSString *, MBSlot *> *slotsById;
// each id's one tab over its controller, kept as tabs come and go: a tab made again over a controller the one before
// still had stopped the app (UIKit's assertion in -[UITab viewController], an iPhone Duo back from hours away,
// 2026-10-30..11-01), even with the tabs before let go of first
@property(nonatomic, strong) NSMutableDictionary<NSString *, UITab *> *tabsById;
// (a tab chosen by the app, not the person: not said back)
@property(nonatomic) BOOL choosing;
// what is pressed, not gone to (the action most wanted, what opens over the page: `act/`): the navigation bar's items,
// not tabs; their key (made again only as it changes)
@property(nonatomic, copy) NSString *actsKey;
@property(nonatomic, strong) UIColor *actsInk;
@property(nonatomic, strong) UIColor *actsAccent;
// the icon each tab was drawn with, by its id (drawn again only as it changes)
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *icons;
// Full list of regular place tabs handed by the app, and any overflow folded into our own `nav_more_id` tab.
@property(nonatomic, copy) NSArray<NSDictionary *> *allPlaces;
@property(nonatomic, copy) NSDictionary *actSpec;
@property(nonatomic, copy) NSString *selectedPlaceId;
@property(nonatomic, copy) NSString *moreIconData;
@property(nonatomic, strong) NSNumber *chosenInkNum;
@property(nonatomic, strong) UIColor *barInk;
@property(nonatomic, strong) UIColor *barAccent;
@property(nonatomic, copy) NSArray<NSDictionary *> *lastBarItems;
@property(nonatomic) BOOL lastBare;
@property(nonatomic, copy) NSString *lastBarTitle;
@property(nonatomic, copy) NSArray<NSDictionary *> *overflowPlaces;
// Number of regular tabs shown directly alongside our own `nav_more_id` tab (0 = not collapsed, showing allPlaces).
@property(nonatomic) NSUInteger visibleRegularCap;
@property(nonatomic, copy) NSString *overflowLayoutKey;
@property(nonatomic) BOOL reconcilingOverflow;
@property(nonatomic) BOOL overflowCheckPending;
@property(nonatomic) CGRect lastLayoutBounds;
@property(nonatomic, weak) MBMorePopoverController *morePopover;
@end

static void nav_invalidate_corners(void);


static UIViewController *the_root;

// The app's controller in `slot`, filling it (under the bars: their room the safe area it says, `bars`).
static void nav_put(UIViewController *slot) {
  MBController *c = the_controller;
  if (!c || c.parentViewController == slot) return;
  [slot loadViewIfNeeded];
  if (c.parentViewController) {
    [c willMoveToParentViewController:nil];
    [c.view removeFromSuperview];
    [c removeFromParentViewController];
  }
  [slot addChildViewController:c];
  c.view.frame = slot.view.bounds;
  c.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [slot.view addSubview:c.view];
  [c didMoveToParentViewController:slot];
  [slot setNeedsStatusBarAppearanceUpdate];
  ime_resign_if_idle();
  [the_view requestFrame];
}

// The system's own glass a tab is drawn on: the item's platter (`_UITabBarItemPlatterView`, in an iPhone Duo's column
// and in the bar across the foot alike) whose place is the tab's, both in `v`'s room.
static UIView *nav_platter(UIView *in, UIView *v, CGRect r) {
  if ([NSStringFromClass(in.class) hasSuffix:@"TabBarItemPlatterView"]) {
    CGRect f = [in convertRect:in.bounds toView:v];
    if (fabs(CGRectGetMidX(f) - CGRectGetMidX(r)) < 2 && fabs(CGRectGetMidY(f) - CGRectGetMidY(r)) < 2 &&
        fabs(f.size.width - r.size.width) < 2)
      return in;
  }
  for (UIView *c in in.subviews) {
    UIView *p = nav_platter(c, v, r);
    if (p) return p;
  }
  return nil;
}

static UIColor *nav_rgba(id v) {
  uint32_t c = (uint32_t)[v unsignedLongLongValue];
  return [UIColor colorWithRed:((c >> 24) & 0xFF) / 255.0 green:((c >> 16) & 0xFF) / 255.0 blue:((c >> 8) & 0xFF) / 255.0
                         alpha:(c & 0xFF) / 255.0];
}

// The title of what is up over the whole window (a picture's name) over it: on a glass of its own, as the bar's items
// are (iOS 26's UIGlassEffect, a capsule round the words), not bare words over the picture (the user, 2026-10-27); iOS
// 18's bar its words. None: none.
// Native menus share the same rows whether anchored to a bar item or a content button.
static UIMenu *nav_menu(NSArray<NSDictionary *> *rows, void (^chosen)(NSString *)) {
  NSMutableArray<UIMenuElement *> *groups = [NSMutableArray array];
  NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
  void (^close)(void) = ^{
    if (actions.count) [groups addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
        options:UIMenuOptionsDisplayInline children:[actions copy]]];
    [actions removeAllObjects];
  };
  for (NSDictionary *m in rows) {
    NSString *ident = m[@"id"];
    if ([ident isEqualToString:@"-"]) { close(); continue; }
    UIImage *img = [m[@"icon"] length] ? nav_any(m[@"icon"], 22) : nil;
    UIAction *action = [UIAction actionWithTitle:m[@"title"] image:img identifier:nil handler:^(UIAction *a) { chosen(ident); }];
    action.state = [m[@"checked"] boolValue] ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:action];
  }
  close();
  return [UIMenu menuWithChildren:groups];
}

static void nav_title(UINavigationItem *item, NSString *title, UIColor *ink) {
  item.title = nil;
  item.titleView = nil;
  if (!title.length) return;
#ifdef __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    UILabel *l = [UILabel new];
    l.text = title;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    l.textColor = ink;
    l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    CGFloat h = 44, side = 16;
    CGFloat w = MIN(ceil([l sizeThatFits:CGSizeMake(CGFLOAT_MAX, h)].width), 240);
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect new]];
    glass.frame = CGRectMake(0, 0, w + 2 * side, h);
    glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
    l.frame = CGRectMake(side, 0, w, h);
    [glass.contentView addSubview:l];
    item.titleView = glass;
    return;
  }
#endif
  item.title = title;
}

@implementation MBTabs
- (UIViewController *)childViewControllerForStatusBarStyle { return the_controller; }
- (UIViewController *)childViewControllerForStatusBarHidden { return the_controller; }
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return the_controller; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return the_controller.supportedInterfaceOrientations; }
- (void)viewDidLoad {
  [super viewDidLoad];
  self.delegate = self;
  self.navs = [NSMutableDictionary dictionary];
  self.slotsById = [NSMutableDictionary dictionary];
  self.tabsById = [NSMutableDictionary dictionary];
  self.customizableViewControllers = @[];
  __weak MBTabs *weakSelf = self;
  NSMutableArray<UITrait> *traits = [NSMutableArray arrayWithObjects:
      UITraitHorizontalSizeClass.class, UITraitVerticalSizeClass.class,
      UITraitUserInterfaceStyle.class, UITraitPreferredContentSizeCategory.class, nil];
#ifdef __IPHONE_27_1
  if (@available(iOS 27.1, *)) [traits addObjectsFromArray:UITraitCollection.systemTraitsAffectingVerticalBarEdge];
#endif
  [self registerForTraitChanges:traits
                    withHandler:^(id<UITraitEnvironment> env, UITraitCollection *prev) {
    MBTabs *s = weakSelf;
    if (!s) return;
    nav_invalidate_corners();
    [s washAction];
    [s scheduleOverflowReconcile];
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf washAction]; });
  }];
  [self applyNone];
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  nav_invalidate_corners();
  [self dismissMorePopover];
  __weak MBTabs *weakSelf = self;
  [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
    [weakSelf washAction];
  } completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
    nav_invalidate_corners();
    [weakSelf reconcileOverflow];
    [weakSelf washAction];
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf washAction]; });
  }];
}
// Where the system put the action's tab (iOS 27's prominent one: an iPhone Duo's round one at its column's foot) in
// the app's view, said as it moves (`nav_action`; w 0 where none shows), for what the app lines up with it (its
// composer at the foot of the card beside it).
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!CGRectEqualToRect(self.view.bounds, self.lastLayoutBounds)) {
    self.lastLayoutBounds = self.view.bounds;
    nav_invalidate_corners();
  }
  [self checkOverflowAfterLayout];
  [self washAction];
  UIView *v = the_view;
  CGRect r = CGRectZero;
  if (v && self.action.length && !self.tabBarHidden)
    for (UITab *t in self.tabs)
      if ([t.identifier isEqualToString:self.action]) {
        r = [t frameInView:v];
      }
  if (CGRectIsNull(r) || CGRectIsInfinite(r)) r = CGRectZero;
  static CGRect said;
  if (CGRectEqualToRect(r, said)) return;
  said = r;
  say_system(@{@"nav_action" : @{@"x" : @(r.origin.x), @"y" : @(r.origin.y), @"w" : @(r.size.width), @"h" : @(r.size.height)}});
}
// iOS 27's prominent tab, the action's, on tinted Liquid Glass matching a prominent bar button item: UITab has no API
// for its platter's glass colour, and a plain 60% backgroundColor view inside `_UITabBarItemPlatterView` looked washed
// out. A capsule UIVisualEffectView with UIGlassEffectStyleRegular + tintColor, in a wash inserted at index 0 inside the
// platter, renders system-tinted glass with specular rim and refraction under the white glyph, and moves, presses and
// turns with the platter (in the vertical column and across the foot alike).
- (void)washAction {
  if (!self.actionInk || !self.action.length || self.tabBarHidden) {
    [self.actionWash removeFromSuperview];
    return;
  }
  UITab *x = self.tabsById[self.action];
  CGRect r = x ? [x frameInView:self.view] : CGRectNull;
  UIView *p = CGRectIsNull(r) || CGRectIsEmpty(r) ? nil : nav_platter(self.view, self.view, r);
  if (!p && x) {
    [self.tabBar layoutIfNeeded];
    r = [x frameInView:self.view];
    p = CGRectIsNull(r) || CGRectIsEmpty(r) ? nil : nav_platter(self.view, self.view, r);
  }
  if (!p) return;
  MBActionWash *w = self.actionWash;
  if (!w) {
    w = [MBActionWash new];
    w.userInteractionEnabled = NO;
    w.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak MBTabs *weakSelf = self;
    // (its platter let go of: into the one made in its place, once UIKit has laid it out)
    w.gone = ^{ dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf washAction]; }); };
    self.actionWash = w;
    self.actionWashInk = nil;
  }
  BOOL glass = NO;
#ifdef __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    glass = YES;
    UIVisualEffectView *g = [w.subviews.firstObject isKindOfClass:UIVisualEffectView.class] ? (UIVisualEffectView *)w.subviews.firstObject : nil;
    if (!g) {
      g = [UIVisualEffectView new];
      g.userInteractionEnabled = NO;
      g.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      g.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
      g.frame = w.bounds;
      [w addSubview:g];
      self.actionWashInk = nil;
    }
    if (![self.actionWashInk isEqual:self.actionInk]) {
      UIGlassEffect *e = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
      e.tintColor = self.actionInk;
      e.interactive = YES;
      g.effect = e;
      self.actionWashInk = self.actionInk;
    }
  }
#endif
  if (!glass) {
    // (round as the glass is: a continuous curve as wide as half its side is no circle, it bulges at four points)
    w.layer.cornerCurve = kCACornerCurveCircular;
    // (the glass seen through it, the page's words bent under it: not a disc of paint)
    w.backgroundColor = [self.actionInk colorWithAlphaComponent:0.6];
    w.layer.cornerRadius = MIN(p.bounds.size.width, p.bounds.size.height) / 2;
  }
  if (w.superview == p) {
    if (!CGRectEqualToRect(w.frame, p.bounds)) w.frame = p.bounds;
#ifdef __IPHONE_26_0
    if (@available(iOS 26.0, *)) {
      UIView *g = w.subviews.firstObject;
      if (g && !CGRectEqualToRect(g.frame, w.bounds)) g.frame = w.bounds;
    }
#endif
    return;
  }
  [w removeFromSuperview];
  w.frame = p.bounds;
#ifdef __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    UIView *g = w.subviews.firstObject;
    if (g && !CGRectEqualToRect(g.frame, w.bounds)) g.frame = w.bounds;
  }
#endif
  [p insertSubview:w atIndex:0];
}
// Apply the latest navigation bar items to a single tab slot (called eagerly for the active tab, and lazily before
// switching into any inactive tab).
- (void)applyBarItemsToSlot:(MBSlot *)slot nav:(UINavigationController *)nav animate:(BOOL)allowAnimate {
  NSArray<NSDictionary *> *items = self.lastBarItems;
  if (!slot || !nav || !items) return;
  UIColor *ink = self.actsInk ?: self.barInk ?: UIColor.labelColor;
  UIColor *accent = self.actsAccent ?: self.barAccent ?: UIColor.tintColor;
  BOOL bare = self.lastBare;
  NSString *title = self.lastBarTitle ?: @"";
  NSMutableDictionary *keptItems = [NSMutableDictionary dictionary];
  NSMutableDictionary *keptSpecs = [NSMutableDictionary dictionary];
  NSMutableArray<UIBarButtonItem *> *made = [NSMutableArray array];
  // (`lead/` the bar's leading items: the workspace's, where the system puts back and close, the column's top)
  NSMutableArray<UIBarButtonItem *> *lead = [NSMutableArray array];
  // (`act/` the toolbar's: down the side, at the column's foot over the tabs, 待处理's bell by them)
  NSMutableArray<UIBarButtonItem *> *foot = [NSMutableArray array];
  NSString *lastIdent = @"";
  // UIKit keeps an existing item's shared glass when its prominence changes; rebuild the bare viewer's group.
  BOOL regroup = NO;
  if (bare) {
    for (NSDictionary *d in items) {
      NSDictionary *before = slot.barSpecs[d[@"id"]];
      if (before && [before[@"prominent"] boolValue] != [d[@"prominent"] boolValue]) {
        regroup = YES;
        break;
      }
    }
  }
  for (NSDictionary *d in items) {
    NSString *ident = d[@"id"];
    UIBarButtonItem *b = regroup ? nil : slot.barItems[ident];
    BOOL reuse = b && [slot.barSpecs[ident] isEqual:d] && [slot.barInk isEqual:ink] && [slot.barAccent isEqual:accent];
    if (!reuse) {
      // (the same action said otherwise, its icon, words, menu or dot, in the same colours: the item there changed in
      // place, not made anew, so the system swaps what it shows on the button there and fades none of the column's
      // buttons, as Outlook's do: the user, 2026-10-31; a new item, even with its identifier, is faded in for the old)
      UIBarButtonItem *was = b && [slot.barInk isEqual:ink] && [slot.barAccent isEqual:accent] ? b : nil;
      // (a picture the host loads: drawn in once it is here, on the item, while it is shown and still said so)
      __block __weak UIBarButtonItem *drawn = nil;
      __weak MBSlot *slotWeak = slot;
      BOOL (^still)(void) = ^BOOL { return [slotWeak.barSpecs[ident] isEqual:d]; };
      NSString *spec = d[@"icon"];
      // (a workspace's mark a disc nearly the glass's own size, on the glass as it is: its picture once here, else its
      // letter on its colour, an emoji alone with no colour round it: the user, 2026-10-28)
      if ([spec hasPrefix:@"badge:"]) {
        NSRange pic = [spec rangeOfString:@"\x1e"];
        NSString *mark = pic.location == NSNotFound ? [spec substringFromIndex:6] : [spec substringWithRange:NSMakeRange(6, pic.location - 6)];
        NSRange comma = [mark rangeOfString:@","];
        if (comma.location != NSNotFound && comma.location + 1 < mark.length &&
            ![NSCharacterSet.alphanumericCharacterSet characterIsMember:[mark characterAtIndex:comma.location + 1]])
          mark = [@"00000000" stringByAppendingString:[mark substringFromIndex:comma.location]];
        spec = pic.location == NSNotFound ? [@"avatars:" stringByAppendingString:mark]
                                          : [NSString stringWithFormat:@"avatars:%@\x1f%@", mark, [spec substringFromIndex:pic.location + 1]];
      }
      UIImage *icon = [spec hasPrefix:@"avatars:"] ? nav_avatars(spec, nav_face, ^{
                        if (still()) drawn.image = nav_avatars(spec, nav_face, nil);
                      })
                      : [spec length] ? nav_any_then(spec, 24, ^{
                          if (still()) drawn.image = nav_any(spec, 24);
                        })
                                      : nav_letter(d[@"title"], 24);
      // (a chat's "…" the system's own glyph, as the "…" it folds into: the user, 2026-11-04)
      if ([ident hasSuffix:@"chat/more"]) icon = [UIImage systemImageNamed:@"ellipsis"] ?: icon;
      BOOL prominent = [d[@"prominent"] boolValue];
      // (said with where the item is in the app's view, for what opens from it: a popover at it)
      __block __weak UIBarButtonItem *weak = nil;
      UIAction *action = [UIAction actionWithTitle:d[@"title"]
                                             image:icon
                                        identifier:nil
                                           handler:^(UIAction *a) {
                                             UIBarButtonItem *it = weak;
                                             UIView *v = the_view;
                                             if (it && v) {
                                               CGRect r = [it frameInView:v];
                                               say_system(@{@"nav" : ident, @"at" : @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]});
                                             } else {
                                               say_system(@{@"nav" : ident});
                                             }
                                           }];
      // (with a menu: its rows, the one checked so, each said as chosen)
      NSArray *rows = d[@"menu"];
      if (rows.count) {
        UIMenu *menu = nav_menu(rows, ^(NSString *row) {
          UIBarButtonItem *it = drawn;
          UIView *v = the_view;
          CGRect r = it && v ? [it frameInView:v] : CGRectZero;
          say_system(@{@"nav" : row, @"at" : @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]});
        });
        if (was.menu) {
          b = was;
          b.menu = menu;
          b.image = icon;
        } else {
          b = [[UIBarButtonItem alloc] initWithImage:icon menu:menu];
        }
        b.title = d[@"title"];
        // (folded into the system's "…", its rows there as they are, not a submenu of them: a submenu opened there
        // heads its rows with its own "… 更多", the system's "…" opening a "…" (the user, 2026-11-13))
        if (@available(iOS 16.0, *))
          b.menuRepresentation = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                               options:UIMenuOptionsDisplayInline children:menu.children];
      } else if (was && !was.menu) {
        b = was;
        b.primaryAction = action;
      } else {
        b = [[UIBarButtonItem alloc] initWithPrimaryAction:action];
      }
      weak = b;
      drawn = b;
#ifdef __IPHONE_26_0
      if (@available(iOS 26.0, *)) {
        // Match the same action across configurations so UIKit carries its glass through the transition.
        b.identifier = ident;
        if (prominent) {
          b.style = UIBarButtonItemStyleProminent;
          b.tintColor = accent;
        } else {
          b.style = UIBarButtonItemStylePlain;
          b.tintColor = ink;
        }
        // (the app's own, 待处理's, on a glass of its own, apart from the card's: the user, 2026-10-27)
        if ((bare && prominent) || [ident hasPrefix:@"act/"] || [ident hasPrefix:@"lead/"]) b.sharesBackground = NO;
#ifdef __IPHONE_27_0
        // (short of room in the column, what goes first: never 待处理's bell, the user 2026-10-27, more wanted than the
        // workspace's and than any page's action; a page's first, and of a page's one that is itself a menu (a
        // chat's "…") before the rest: folded, its rows are in the system's "…" (its menuRepresentation), nothing
        // lost, where its button left beside the system's would be two "…" in the column: the user 2026-11-03)
        if (@available(iOS 27.0, *)) {
          // (the bell above all: on the outer screen's short column there is room for one of the app's own)
          if ([ident hasSuffix:@"/attention"] || [ident hasSuffix:@"side/close"]) b.visibilityPriority = UIBarButtonItemVisibilityPriorityHigh;
          else if (![ident hasPrefix:@"act/"] && ![ident hasPrefix:@"lead/"])
            b.visibilityPriority = rows.count ? UIBarButtonItemVisibilityPriorityLow - 1 : UIBarButtonItemVisibilityPriorityLow;
          // (on a glass of its own: on one with the others, short of room, the system folded those and left this "…"
          // beside its own: the user 2026-11-04)
          if (rows.count) b.sharesBackground = NO;
        }
#endif
        b.badge = [d[@"dot"] boolValue] ? [UIBarButtonItemBadge indicatorBadge] : nil;
      }
#endif
    }
    keptItems[ident] = b;
    keptSpecs[ident] = d;
    if ([ident hasPrefix:@"lead/"]) [lead addObject:b];
    else if ([ident hasPrefix:@"act/"]) [foot addObject:b];
    else {
      // (who's in a page apart from what it does: a glass each, a space between)
      BOOL who = [ident hasPrefix:@"page/who/"];
#ifdef __IPHONE_26_0
      if (@available(iOS 26.0, *))
        if (!who && made.count && [lastIdent hasPrefix:@"page/who/"]) b.sharesBackground = NO;
#endif
      [made addObject:b];
      lastIdent = ident;
    }
  }
  slot.barItems = keptItems;
  slot.barSpecs = keptSpecs;
  slot.barInk = ink;
  slot.barAccent = accent;
  slot.appliedActsKey = self.actsKey;
  // Only the visible tab transitions; initial setup and the other tabs take their items at once.
  BOOL animate = allowAnimate && nav == self.selectedViewController && nav.isViewLoaded && nav.view.window != nil &&
                 !UIAccessibilityIsReduceMotionEnabled();
  // (from the bar's end in: the action most wanted outermost)
  NSArray *right = made.reverseObjectEnumerator.allObjects;
  if (![slot.navigationItem.rightBarButtonItems isEqualToArray:right])
    [slot.navigationItem setRightBarButtonItems:right animated:animate];
  if (![slot.navigationItem.leftBarButtonItems isEqualToArray:lead])
    [slot.navigationItem setLeftBarButtonItems:lead animated:animate];
  if (![slot.toolbarItems isEqualToArray:foot]) [slot setToolbarItems:foot animated:animate];
  // (the chosen tab's alone: shown on two, the column shows its items twice; didSelectTab)
  BOOL hidden = foot.count == 0 || nav != self.selectedViewController;
  if (nav.toolbarHidden != hidden) [nav setToolbarHidden:hidden animated:animate];
  nav_title(slot.navigationItem, bare ? title : @"", ink);
  // (put away only when something is up over the whole window, its title alone: hidden with its items gone, the system's
  // column keeps showing the views of those it had, a page's actions on the next tab, the outer screen's workspace
  // button on the inner one; the user, 2026-10-27. Shown with none it takes no room: there, its items are the column's.
  // Nor with no title either (a remote screen's 全屏): put away, the column showed the chat's actions under it; shown,
  // it is told they are gone, the user 2026-10-29)
  [nav setNavigationBarHidden:(bare && made.count + lead.count == 0 && title.length > 0) animated:(bare && allowAnimate)];
}
- (void)ensureSlotBarItemsForIdent:(NSString *)ident animate:(BOOL)allowAnimate {
  if (!ident.length) return;
  UINavigationController *nav = self.navs[ident];
  MBSlot *slot = self.slotsById[ident] ?: (MBSlot *)nav.viewControllers.firstObject;
  if (!slot || !nav) return;
  if (!mb_ios_nav_slot_needs_bar_items(slot.appliedActsKey, self.actsKey, self.lastBarItems != nil)) return;
  [self applyBarItemsToSlot:slot nav:nav animate:allowAnimate];
}
// What is pressed, not gone to, as the navigation bar's own items on the active tab's page (and synced lazily on
// inactive tabs before switching): the action most wanted prominent, on the accent; a dot a badge.
// Bare (something up over the whole window, the tabs put away): `title` over them, the bar put away with none.
- (void)barItems:(NSArray<NSDictionary *> *)items ink:(UIColor *)ink accent:(UIColor *)accent bare:(BOOL)bare title:(NSString *)title {
  NSMutableString *key = [NSMutableString stringWithFormat:@"%d\x1f%@\x1e", bare, bare ? title : @""];
  for (NSDictionary *d in items) {
    [key appendFormat:@"%@\x1f%@\x1f%@\x1f%@\x1f%@", d[@"id"], d[@"icon"], d[@"dot"], d[@"title"], d[@"prominent"]];
    for (NSDictionary *m in d[@"menu"]) [key appendFormat:@"\x1d%@\x1f%@\x1f%@\x1f%@", m[@"id"], m[@"title"], m[@"checked"], m[@"icon"]];
    [key appendString:@"\x1e"];
  }
  [key appendFormat:@"%lu", (unsigned long)self.navs.count];
  BOOL colorsChanged = !((self.actsInk == ink) || [self.actsInk isEqual:ink]) ||
                       !((self.actsAccent == accent) || [self.actsAccent isEqual:accent]);
  if ([key isEqualToString:self.actsKey] && !colorsChanged) {
    NSString *activeIdent = self.selectedTab.identifier;
    if (activeIdent.length) [self ensureSlotBarItemsForIdent:activeIdent animate:YES];
    return;
  }
  if (colorsChanged) {
    for (MBSlot *s in self.slotsById.allValues) s.appliedActsKey = nil;
  }
  self.actsKey = key;
  self.actsInk = ink;
  self.actsAccent = accent;
  self.lastBarItems = items;
  self.lastBare = bare;
  self.lastBarTitle = title ?: @"";
  if (getenv("MBUI_NAV_LOG")) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *d in items) {
      NSMutableArray *rows = [NSMutableArray array];
      for (NSDictionary *m in d[@"menu"]) [rows addObject:m[@"title"] ?: @""];
      [ids addObject:rows.count ? [NSString stringWithFormat:@"%@{%@}", d[@"id"], [rows componentsJoinedByString:@","]] : d[@"id"]];
    }
    say([NSString stringWithFormat:@"NAVLOG bar items: %@", [ids componentsJoinedByString:@" "]]);
  }
  UINavigationController *activeNav = [self.selectedViewController isKindOfClass:UINavigationController.class]
                                          ? (UINavigationController *)self.selectedViewController
                                          : self.navs[self.selectedTab.identifier ?: @""];
  if (activeNav) {
    MBSlot *activeSlot = nil;
    for (NSString *k in self.navs) {
      if (self.navs[k] == activeNav) {
        activeSlot = self.slotsById[k];
        break;
      }
    }
    if (!activeSlot) activeSlot = (MBSlot *)activeNav.viewControllers.firstObject;
    if (activeSlot) [self applyBarItemsToSlot:activeSlot nav:activeNav animate:YES];
  }
}
- (UINavigationController *)navFor:(NSString *)ident {
  UINavigationController *nav = self.navs[ident];
  if (!nav) {
    MBSlot *slot = [MBSlot new];
    self.slotsById[ident] = slot;
    nav = [[UINavigationController alloc] initWithRootViewController:slot];
    [nav setNavigationBarHidden:YES animated:NO];
    self.navs[ident] = nav;
  }
  return nav;
}
- (MBSlot *)slotFor:(NSString *)ident {
  MBSlot *slot = self.slotsById[ident ?: @""];
  if (slot) return slot;
  UINavigationController *nav = self.navs[ident ?: @""];
  return (MBSlot *)nav.viewControllers.firstObject;
}
// The tab of `ident` (made once, over its controller), its words and picture as given.
- (UITab *)tabFor:(NSString *)ident title:(NSString *)title image:(UIImage *)image {
  UITab *tab = self.tabsById[ident];
  if (!tab) {
    UINavigationController *nav = [self navFor:ident];
    tab = [[UITab alloc] initWithTitle:title image:image identifier:ident viewControllerProvider:^(UITab *t) { return nav; }];
    self.tabsById[ident] = tab;
    return tab;
  }
  if (![tab.title isEqualToString:title]) tab.title = title;
  tab.image = image;
  return tab;
}
// The app reserves only the geometry. UIKit owns the glass, press feedback, title, image and popup menu.
- (void)floatingItems:(NSArray<NSDictionary *> *)items ink:(UIColor *)ink {
  if (!self.floatingButtons) {
    self.floatingButtons = [NSMutableDictionary dictionary];
    self.floatingKeys = [NSMutableDictionary dictionary];
  }
  NSMutableSet<NSString *> *live = [NSMutableSet set];
  for (NSDictionary *f in items) {
    NSDictionary *d = f[@"item"];
    NSString *ident = d[@"id"];
    if (!ident.length || !the_view) continue;
    [live addObject:ident];
    UIButton *button = self.floatingButtons[ident];
    if (!button) {
      button = [MBFloatingButton buttonWithType:UIButtonTypeSystem];
      __weak UIButton *pressed = button;
      [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UIButton *b = pressed;
        if (b.menu) return;
        CGRect r = [b convertRect:b.bounds toView:the_view];
        say_system(@{@"nav": ident, @"at": @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]});
      }] forControlEvents:UIControlEventTouchUpInside];
      button.accessibilityIdentifier = ident;
      self.floatingButtons[ident] = button;
    }
    if (button.superview != the_view) [the_view addSubview:button];
    button.frame = CGRectMake([f[@"x"] doubleValue], [f[@"y"] doubleValue], [f[@"w"] doubleValue], [f[@"h"] doubleValue]);
    BOOL blocked = [f[@"blocked"] boolValue];
    ((MBFloatingButton *)button).inputBlocked = blocked;
    button.accessibilityElementsHidden = blocked;
    // Keep the live glass stable while a canvas presenter opens. Its backdrop already
    // changes with the presenter; an extra opacity jump makes every sibling flash.
    NSString *key = [NSString stringWithFormat:@"%@/%@", d, ink];
    if (![self.floatingKeys[ident] isEqualToString:key]) {
      self.floatingKeys[ident] = key;
      BOOL withTitle = [d[@"prominent"] boolValue];
      UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
#ifdef __IPHONE_26_0
      if (@available(iOS 26.0, *)) {
        config = [UIButtonConfiguration glassButtonConfiguration];
      }
#endif
      config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
      config.baseForegroundColor = ink;
      BOOL dot = [d[@"dot"] boolValue];
      config.contentInsets = withTitle ? NSDirectionalEdgeInsetsMake(0, 8, 0, dot ? 24 : 8) : NSDirectionalEdgeInsetsZero;
      config.imagePadding = withTitle ? 6 : 0;
      if (withTitle) {
        config.titleLineBreakMode = NSLineBreakByTruncatingTail;
        config.attributedTitle = [[NSAttributedString alloc] initWithString:d[@"title"] attributes:@{
          NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
        }];
      }
      button.contentHorizontalAlignment = withTitle ? UIControlContentHorizontalAlignmentLeading : UIControlContentHorizontalAlignmentCenter;
      __weak UIButton *weak = button;
      __weak MBTabs *owner = self;
      NSString *icon = d[@"icon"];
      config.image = nav_any_then(icon, 24, ^{
        UIButton *b = weak;
        if (!b || ![owner.floatingKeys[ident] isEqualToString:key]) return;
        UIButtonConfiguration *next = b.configuration;
        next.image = nav_any(icon, 24);
        b.configuration = next;
      });
      button.configuration = config;
      button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
      button.titleLabel.numberOfLines = 1;
      button.accessibilityLabel = d[@"title"];
      button.showsMenuAsPrimaryAction = [d[@"menu"] count] > 0;
      button.menu = [d[@"menu"] count] ? nav_menu(d[@"menu"], ^(NSString *row) {
        UIButton *b = weak;
        CGRect r = b && the_view ? [b convertRect:b.bounds toView:the_view] : CGRectZero;
        say_system(@{@"nav": row, @"at": @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]});
      }) : nil;
      UIView *badge = [button viewWithTag:71];
      if (!badge) {
        badge = [UIView new]; badge.tag = 71;
        badge.userInteractionEnabled = NO;
        badge.backgroundColor = UIColor.systemBlueColor;
        badge.layer.cornerRadius = 3;
        [button addSubview:badge];
      }
      badge.hidden = !dot;
    }
    [button viewWithTag:71].frame = CGRectMake(button.bounds.size.width - 18, (button.bounds.size.height - 6) / 2, 6, 6);
  }
  for (NSString *ident in [self.floatingButtons.allKeys copy]) {
    if ([live containsObject:ident]) continue;
    [self.floatingButtons[ident] removeFromSuperview];
    [self.floatingButtons removeObjectForKey:ident];
    [self.floatingKeys removeObjectForKey:ident];
  }
}
- (NSString *)currentLayoutKey {
  CGSize sz = self.view.bounds.size;
  NSInteger vEdge = 0;
#ifdef __IPHONE_27_1
  if (@available(iOS 27.1, *)) vEdge = self.traitCollection.verticalBarEdge;
#endif
  return [NSString stringWithFormat:@"%.0fx%.0f/%ld/%ld/%ld/%@/%lu/%d",
          sz.width, sz.height, (long)vEdge,
          (long)self.traitCollection.horizontalSizeClass,
          (long)self.traitCollection.verticalSizeClass,
          self.traitCollection.preferredContentSizeCategory ?: @"",
          (unsigned long)self.allPlaces.count,
          self.actSpec != nil ? 1 : 0];
}
- (BOOL)isOverflowPlaceId:(NSString *)ident {
  if (!ident.length) return NO;
  for (NSDictionary *d in self.overflowPlaces)
    if ([d[@"id"] isEqualToString:ident]) return YES;
  return NO;
}
- (void)dismissMorePopover {
  MBMorePopoverController *pop = self.morePopover;
  if (pop && pop.presentingViewController) [pop dismissViewControllerAnimated:NO completion:nil];
  self.morePopover = nil;
}
- (void)toggleMorePopover:(UITab *)tab {
  MBMorePopoverController *existing = self.morePopover;
  if (existing && existing.presentingViewController) {
    [existing dismissViewControllerAnimated:YES completion:nil];
    self.morePopover = nil;
    return;
  }
  if (!self.overflowPlaces.count || !tab) return;
  MBMorePopoverController *pop = [[MBMorePopoverController alloc] initWithStyle:UITableViewStylePlain];
  pop.items = self.overflowPlaces;
  pop.selectedId = self.selectedPlaceId;
  pop.ink = self.barInk ?: UIColor.labelColor;
  pop.accent = self.barAccent ?: UIColor.tintColor;
  pop.onPick = ^(NSString *ident) {
    say_system(@{@"nav" : ident});
  };
  pop.modalPresentationStyle = UIModalPresentationPopover;
  UIPopoverPresentationController *ppc = pop.popoverPresentationController;
  ppc.delegate = self;
  ppc.sourceItem = tab;
  UIPopoverArrowDirection dirs = UIPopoverArrowDirectionDown;
#ifdef __IPHONE_27_1
  if (@available(iOS 27.1, *)) {
    if (self.traitCollection.verticalBarEdge == UIVerticalBarEdgeTrailing) dirs = UIPopoverArrowDirectionRight;
    else if (self.traitCollection.verticalBarEdge == UIVerticalBarEdgeLeading) dirs = UIPopoverArrowDirectionLeft;
  }
#endif
  ppc.permittedArrowDirections = dirs;
  self.morePopover = pop;
  [self presentViewController:pop animated:YES completion:nil];
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
                                                               traitCollection:(UITraitCollection *)traitCollection {
  return UIModalPresentationNone;
}
- (void)syncNavToolbars {
  UINavigationController *active = self.navs[self.selectedTab.identifier ?: @""];
  for (NSString *k in self.navs) {
    UINavigationController *n = self.navs[k];
    MBSlot *slot = [self slotFor:k];
    [n setToolbarHidden:(n != active || !slot.toolbarItems.count) animated:NO];
  }
}
- (void)selectWantedTab {
  UITab *want = nil;
  if (self.selectedPlaceId.length) {
    if ([self isOverflowPlaceId:self.selectedPlaceId]) {
      for (UITab *tab in self.tabs)
        if ([tab.identifier isEqualToString:nav_more_id]) want = tab;
    } else {
      for (UITab *tab in self.tabs)
        if ([tab.identifier isEqualToString:self.selectedPlaceId]) want = tab;
    }
  }
  // (none said: keep the tab it was opened over, unless that tab is gone)
  if (!want && !self.selectedPlaceId.length && self.selectedTab && [self.tabs containsObject:self.selectedTab])
    want = self.selectedTab;
  if (!want || (self.action.length && [want.identifier isEqualToString:self.action]))
    want = self.tabs.firstObject;
  if (want) [self ensureSlotBarItemsForIdent:want.identifier animate:NO];
  if (want && self.selectedTab != want) {
    self.choosing = YES;
    self.selectedTab = want;
    self.choosing = NO;
  }
  [self ensureSlotBarItemsForIdent:self.selectedTab.identifier animate:NO];
  MBSlot *slot = [self slotFor:self.selectedTab.identifier];
  if (slot) nav_put(slot);
  [self syncNavToolbars];
}
- (BOOL)rebuildDisplayedTabs {
  NSArray<NSDictionary *> *places = self.allPlaces ?: @[];
  NSArray<NSDictionary *> *visible = places;
  NSArray<NSDictionary *> *overflow = @[];
  if (self.visibleRegularCap > 0 && self.visibleRegularCap < places.count) {
    visible = [places subarrayWithRange:NSMakeRange(0, self.visibleRegularCap)];
    overflow = [places subarrayWithRange:NSMakeRange(self.visibleRegularCap, places.count - self.visibleRegularCap)];
  }
  NSDictionary *act = self.actSpec;
  UIColor *accent = self.barAccent ?: UIColor.tintColor;
  NSMutableString *key = [NSMutableString string];
  for (NSDictionary *t in visible) [key appendFormat:@"%@\x1e", t[@"id"]];
  if (overflow.count) [key appendFormat:@"%@\x1e", nav_more_id];
  if (act) [key appendFormat:@"!%@\x1f%@\x1f%@\x1f%@", act[@"id"], act[@"title"], act[@"icon"], self.chosenInkNum ?: @0];
  BOOL tabsChanged = ![key isEqualToString:self.tabsKey];
  self.overflowPlaces = overflow;
  if (tabsChanged) {
    self.tabsKey = key;
    NSMutableArray<UITab *> *made = [NSMutableArray array];
    // (an id twice one tab: one controller is never two tabs')
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *t in visible) {
      if ([seen containsObject:t[@"id"]]) continue;
      [seen addObject:t[@"id"]];
      UITab *tab = [self tabFor:t[@"id"] title:t[@"title"] image:nav_any(t[@"icon"], 26)];
      // (the action's tab before, a place now: pinned no more)
      tab.preferredPlacement = UITabPlacementDefault;
      [made addObject:tab];
    }
    if (overflow.count) {
      NSString *moreTitle = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? @"更多" : @"More";
      UIImage *moreImage = [UIImage systemImageNamed:@"ellipsis"] ?: (self.moreIconData.length ? nav_icon(self.moreIconData, 26) : nil);
      UITab *moreTab = [self tabFor:nav_more_id title:moreTitle image:moreImage];
      moreTab.preferredPlacement = UITabPlacementDefault;
      [made addObject:moreTab];
      [seen addObject:nav_more_id];
    }
    // (the action a tab of its own the system sets apart at the bar's end, on the system's glass, with an accent
    // glyph (iOS 27: white on its glass washed with the accent, washAction): never chosen, shouldSelectTab says it)
    self.action = act[@"id"];
    self.actionInk = nil;
    if (act && ![seen containsObject:act[@"id"]]) {
      UIImage *image = [nav_icon(act[@"icon"], 26) imageWithTintColor:accent renderingMode:UIImageRenderingModeAlwaysOriginal];
#ifdef __IPHONE_27_0
      if (@available(iOS 27.0, *)) {
        image = [nav_icon(act[@"icon"], 26) imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        self.actionInk = accent;
      }
#endif
      UITab *x = [self tabFor:act[@"id"] title:act[@"title"] image:image];
      x.preferredPlacement = UITabPlacementPinned;
      [made addObject:x];
    }
    [self.icons removeAllObjects];
    self.choosing = YES;
    // (the tabs before let go of their controllers first: one controller is never two tabs' at once)
    if (self.tabs.count) self.tabs = @[];
    self.tabs = made;
    // (apart, under the tabs' glass in the column, on its own: iOS 27's prominent tab)
#ifdef __IPHONE_27_0
    if (@available(iOS 27.0, *)) self.prominentTabIdentifier = act[@"id"];
#endif
    self.customizableViewControllers = @[];
    self.choosing = NO;
  }
  if (!self.icons) self.icons = [NSMutableDictionary dictionary];
  for (UITab *tab in self.tabs) {
    if ([tab.identifier isEqualToString:nav_more_id]) {
      BOOL anyDot = NO;
      for (NSDictionary *d in overflow)
        if ([d[@"dot"] boolValue]) anyDot = YES;
      tab.badgeValue = anyDot ? @"" : nil;
      continue;
    }
    for (NSDictionary *t in visible)
      if ([t[@"id"] isEqualToString:tab.identifier]) {
        tab.badgeValue = [t[@"dot"] boolValue] ? @"" : nil;
        if (![tab.title isEqualToString:t[@"title"]]) tab.title = t[@"title"];
        if (![self.icons[tab.identifier] isEqualToString:t[@"icon"]]) {
          NSString *icon = t[@"icon"];
          self.icons[tab.identifier] = icon;
          __weak UITab *weak = tab;
          __weak MBTabs *me = self;
          tab.image = nav_any_then(icon, 26, ^{
            // (its picture come: drawn in place of its mark, while the tab still shows it)
            if ([me.icons[weak.identifier] isEqualToString:icon]) weak.image = nav_any(icon, 26);
          });
        }
      }
  }
  if (!overflow.count) {
    [self dismissMorePopover];
  } else if (self.morePopover && self.morePopover.presentingViewController) {
    [self.morePopover reloadItems:overflow selectedId:self.selectedPlaceId ink:self.barInk accent:self.barAccent];
  }
  return tabsChanged;
}
- (void)scheduleOverflowReconcile {
  if (self.overflowCheckPending) return;
  self.overflowCheckPending = YES;
  __weak MBTabs *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MBTabs *s = weakSelf;
    if (!s) return;
    s.overflowCheckPending = NO;
    [s reconcileOverflow];
  });
}
- (void)collapseIfUIKitOverflowed:(NSString *)lkey {
  if (self.visibleRegularCap != 0) return;
  if (self.tabBar.items.count == 0 || self.tabBar.items.count >= self.tabs.count) {
    self.overflowLayoutKey = lkey;
    return;
  }
  NSUInteger vis = 0;
  for (NSDictionary *p in self.allPlaces) {
    UITab *t = self.tabsById[p[@"id"]];
    CGRect r = t ? [t frameInView:self.view] : CGRectZero;
    if (!CGRectIsNull(r) && !CGRectIsInfinite(r) && r.size.width > 0 && r.size.height > 0) vis++;
  }
  if (vis == 0 || vis >= self.allPlaces.count) return;
  self.visibleRegularCap = vis;
  self.overflowLayoutKey = lkey;
  [self rebuildDisplayedTabs];
  for (MBSlot *s in self.slotsById.allValues) s.appliedActsKey = nil;
  if (self.lastBarItems) {
    self.actsKey = nil;
    [self barItems:self.lastBarItems ink:self.barInk ?: UIColor.labelColor accent:self.barAccent ?: UIColor.tintColor
              bare:self.lastBare title:self.lastBarTitle ?: @""];
  }
  [self selectWantedTab];
  [self washAction];
}
- (void)checkOverflowAfterLayout {
  if (self.reconcilingOverflow || !self.shown || self.tabBarHidden || !self.view.window) return;
  if (self.allPlaces.count <= 1) return;
  CGSize sz = self.view.bounds.size;
  if (sz.width <= 0 || sz.height <= 0) return;
  NSString *lkey = [self currentLayoutKey];
  if (self.visibleRegularCap > 0) {
    if (![lkey isEqualToString:self.overflowLayoutKey]) [self scheduleOverflowReconcile];
    return;
  }
  if (self.tabBar.items.count > 0 && self.tabBar.items.count < self.tabs.count) {
    self.reconcilingOverflow = YES;
    [self collapseIfUIKitOverflowed:lkey];
    self.reconcilingOverflow = NO;
  } else if (self.tabBar.items.count > 0) {
    self.overflowLayoutKey = lkey;
  }
}
- (void)reconcileOverflow {
  if (self.reconcilingOverflow || !self.shown || self.tabBarHidden || !self.view.window) return;
  if (self.allPlaces.count <= 1) return;
  CGSize sz = self.view.bounds.size;
  if (sz.width <= 0 || sz.height <= 0) return;
  NSString *lkey = [self currentLayoutKey];
  self.reconcilingOverflow = YES;
  if (self.visibleRegularCap > 0 && ![lkey isEqualToString:self.overflowLayoutKey]) {
    self.visibleRegularCap = 0;
    [self rebuildDisplayedTabs];
    // Keep selection on the first tab during the probe so UIKit never pushes a trailing tab onto moreNavigationController.
    if (self.tabs.firstObject) [self ensureSlotBarItemsForIdent:self.tabs.firstObject.identifier animate:NO];
    if (self.tabs.firstObject && self.selectedTab != self.tabs.firstObject) {
      self.choosing = YES;
      self.selectedTab = self.tabs.firstObject;
      self.choosing = NO;
    }
    [self.view layoutIfNeeded];
  }
  [self collapseIfUIKitOverflowed:lkey];
  if (self.visibleRegularCap == 0) {
    [self selectWantedTab];
    [self washAction];
  }
  self.reconcilingOverflow = NO;
}
// No tabs: one tab, the bar hidden, the app's controller in it.
- (void)applyNone {
  [self dismissMorePopover];
  [self floatingItems:@[] ink:UIColor.labelColor];
  self.allPlaces = nil;
  self.actSpec = nil;
  self.action = nil;
  self.actionInk = nil;
  [self.actionWash removeFromSuperview];
  self.selectedPlaceId = nil;
  self.overflowPlaces = @[];
  self.visibleRegularCap = 0;
  self.overflowLayoutKey = nil;
  UINavigationController *nav = [self navFor:@""];
  if (self.tabsKey.length || !self.tabs.count) {
    self.tabsKey = @"";
    self.choosing = YES;
    self.tabs = @[ [self tabFor:@"" title:@"" image:nil] ];
    self.choosing = NO;
  }
  self.tabBarHidden = YES;
  self.shown = NO;
  self.actsKey = nil;
  self.actsInk = nil;
  self.actsAccent = nil;
  self.lastBarItems = nil;
  self.lastBarTitle = nil;
  for (MBSlot *s in self.slotsById.allValues) s.appliedActsKey = nil;
  // (nor the navigation bar's items: the app's own frame has them)
  MBSlot *slot = [self slotFor:@""];
  slot.navigationItem.rightBarButtonItems = nil;
  [nav setNavigationBarHidden:YES animated:NO];
  if (slot) nav_put(slot);
}
- (void)apply:(NSDictionary *)b {
  // the places: the items of the groups not folded (the card's own are its page's); the one most wanted apart
  NSMutableArray<NSDictionary *> *places = [NSMutableArray array];
  NSDictionary *act = nil;  // (none: what is pressed is the navigation bar's)
  NSMutableArray<NSDictionary *> *buttons = [NSMutableArray array];
  // (the card in use's own, before the app's own actions, on one glass with 待处理's; the action most wanted apart, last)
  NSMutableArray<NSDictionary *> *own = [NSMutableArray array];
  // (something up over the whole window: the tabs put away, its own items alone)
  BOOL bare = [b[@"bare"] boolValue];
  for (NSDictionary *g in b[@"groups"]) {
    if ([g[@"foldable"] boolValue]) {
      [own addObjectsFromArray:g[@"items"]];
      continue;
    }
    for (NSDictionary *d in g[@"items"]) {
      // (the one most wanted the tab bar's own action at its end, set apart as the system sets search apart; what opens
      // over the page the navigation bar's item)
      if ([d[@"prominent"] boolValue]) act = d;
      else if ([d[@"id"] hasPrefix:@"act/"] || [d[@"id"] hasPrefix:@"lead/"]) [buttons addObject:d];
      else [places addObject:d];
    }
  }
  if (!places.count) {
    [self applyNone];
    return;
  }
  UIColor *ink = [b[@"ink"] unsignedLongLongValue] ? nav_rgba(b[@"ink"]) : UIColor.labelColor;
  UIColor *accent = [b[@"chosen_ink"] unsignedLongLongValue] ? nav_rgba(b[@"chosen_ink"]) : UIColor.tintColor;
  self.tabBar.tintColor = accent;
  self.view.tintColor = accent;
  self.tabBar.unselectedItemTintColor = ink;
  self.barInk = ink;
  self.barAccent = accent;
  self.chosenInkNum = [b[@"chosen_ink"] isKindOfClass:NSNumber.class] ? b[@"chosen_ink"] : @0;
  self.moreIconData = [b[@"more_icon"] isKindOfClass:NSString.class] ? b[@"more_icon"] : @"";
  self.selectedPlaceId = [b[@"selected"] isKindOfClass:NSString.class] ? b[@"selected"] : @"";
  NSUInteger prevPlacesCount = self.allPlaces.count;
  BOOL prevHadAct = self.actSpec != nil;
  self.allPlaces = places;
  self.actSpec = act;
  if (bare) [self dismissMorePopover];
  // Re-probe overflow whenever the tab count or layout signature changes.
  NSString *lkey = [self currentLayoutKey];
  if (self.visibleRegularCap > 0 &&
      (prevPlacesCount != places.count || prevHadAct != (act != nil) || ![lkey isEqualToString:self.overflowLayoutKey])) {
    self.visibleRegularCap = 0;
  }
  [self floatingItems:bare ? @[] : b[@"floating"] ink:ink];
  BOOL tabsChanged = [self rebuildDisplayedTabs];
  BOOL hiddenChanged = self.tabBarHidden != bare;
  if (hiddenChanged) {
    if (!bare) {
      __weak MBTabs *weakSelf = self;
      [CATransaction begin];
      [CATransaction setCompletionBlock:^{
        [weakSelf washAction];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf washAction]; });
      }];
      [self setTabBarHidden:NO animated:YES];
      [CATransaction commit];
    } else {
      [self setTabBarHidden:YES animated:YES];
    }
  }
  self.shown = YES;
  if (bare) [buttons removeAllObjects];
  [buttons insertObjects:own atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, own.count)]];
  NSString *title = [b[@"title"] isKindOfClass:NSString.class] ? b[@"title"] : @"";
  self.lastBarItems = buttons;
  self.lastBare = bare;
  self.lastBarTitle = title;
  [self barItems:buttons ink:ink accent:accent bare:bare title:title];
  self.overflowLayoutKey = mb_ios_nav_next_overflow_layout_key(bare, tabsChanged, self.overflowLayoutKey);
  if (mb_ios_nav_needs_overflow_probe(bare, self.view.window != nil, self.visibleRegularCap, places.count,
                                      tabsChanged, lkey, self.overflowLayoutKey)) {
    self.reconcilingOverflow = YES;
    if (self.tabs.firstObject) [self ensureSlotBarItemsForIdent:self.tabs.firstObject.identifier animate:NO];
    if (self.tabs.firstObject && self.selectedTab != self.tabs.firstObject) {
      self.choosing = YES;
      self.selectedTab = self.tabs.firstObject;
      self.choosing = NO;
    }
    [self.view layoutIfNeeded];
    [self collapseIfUIKitOverflowed:lkey];
    self.reconcilingOverflow = NO;
  }
  BOOL skipSyncWash = hiddenChanged && !bare && !tabsChanged;
  if (!skipSyncWash && (tabsChanged || hiddenChanged || (self.actionInk && !bare && !self.actionWash.window))) {
    [self washAction];
    if (self.actionInk && !bare) {
      __weak MBTabs *weakSelf = self;
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf washAction]; });
    }
  }
  [self selectWantedTab];
}
- (BOOL)tabBarController:(UITabBarController *)c shouldSelectTab:(UITab *)tab {
  // Our own overflow tab opens a native popover listing the hidden places instead of UIKit's full-screen More table.
  if ([tab.identifier isEqualToString:nav_more_id]) {
    if (!self.choosing) [self toggleMorePopover:tab];
    return NO;
  }
  // the action, and a tab that opens something over the page (`act/`): done, not chosen
  if (self.action && [tab.identifier isEqualToString:self.action]) {
    if (!self.choosing) say_system(@{@"nav" : self.action});
    return NO;
  }
  if ([tab.identifier hasPrefix:@"act/"]) {
    if (!self.choosing) say_system(@{@"nav" : tab.identifier});
    return NO;
  }
  // (the workspace's tab, `menu/`: what it holds opened beside it, where the system has it, not gone to)
  if ([tab.identifier hasPrefix:@"menu/"]) {
    if (!self.choosing) {
      UIView *v = the_view;
      CGRect r = v ? [tab frameInView:v] : CGRectZero;
      say_system(@{@"nav" : tab.identifier, @"at" : @[ @(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height) ]});
    }
    return NO;
  }
  [self ensureSlotBarItemsForIdent:tab.identifier animate:NO];
  return YES;
}
- (BOOL)tabBarController:(UITabBarController *)c shouldSelectViewController:(UIViewController *)vc {
  if (vc == self.moreNavigationController) {
    [self reconcileOverflow];
    UITab *moreTab = self.tabsById[nav_more_id];
    if (moreTab && !self.choosing) [self toggleMorePopover:moreTab];
    return NO;
  }
  return YES;
}
- (void)tabBarController:(UITabBarController *)c didSelectTab:(UITab *)tab previousTab:(UITab *)was {
  if ([tab.identifier isEqualToString:nav_more_id]) {
    if (!self.choosing) [self toggleMorePopover:tab];
    return;
  }
  [self ensureSlotBarItemsForIdent:tab.identifier animate:NO];
  MBSlot *slot = [self slotFor:tab.identifier];
  if (slot) nav_put(slot);
  [self syncNavToolbars];
  if (!self.choosing && tab.identifier.length) say_system(@{@"nav" : tab.identifier});
}
@end


// No room the app keeps at the trailing edge for its own (the system's tab bar is in the safe area it says).
static CGFloat nav_right(void) { return 0; }

// The places as the app has them (nav.mbt NavBar's JSON): 1 where the system's tab bar shows them (an iPhone, iOS 26
// on), 0 where the app draws its own.
static BOOL had_hinge;

// Whether the system lays out the app's tabs and actions itself in every pose (mb_host_nav_bar takes them, the app's
// frame the same on both screens): an iPhone Duo's (a hinge), iOS 27.1 on.
int32_t mb_host_nav_able(void) {
  if (the_controller.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return 0;
  if (![the_root isKindOfClass:MBTabs.class]) return 0;
  // (a hinge once seen where the view is, the inner screen's; or the system's bars down the side, the outer one's)
  if (the_controller.hinge >= 0) had_hinge = YES;
  if (had_hinge) return 1;
#ifdef __IPHONE_27_1
  if (@available(iOS 27.1, *)) return the_controller.traitCollection.verticalBarEdge != UIVerticalBarEdgeUnspecified ? 1 : 0;
#endif
  return 0;
}

int32_t mb_host_nav_bar(moonbit_string_t spec) {
  if (the_controller.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return 0;
  if (@available(iOS 26.0, *)) {
    MBTabs *t = (MBTabs *)the_root;
    if (![t isKindOfClass:MBTabs.class]) return 0;
    NSString *s = mb_ns_from_string(spec);
    if ([s isEqualToString:t.spec]) return t.shown ? 1 : 0;
    t.spec = s;
    NSDictionary *b = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (![b isKindOfClass:NSDictionary.class]) b = @{};
    [t apply:b];
    return t.shown ? 1 : 0;
  }
  return 0;
}


// How round the window's corners are (@hostapi.window_corner, window_corner_at): the app fills the screen, whose own
// corners (40 and more) are rounder than anything by them could follow within the corner rule's ranges: said as none;
// but where the system lays out the app's tabs in every pose (an iPhone Duo's: mb_host_nav_able), the screen's own,
// the cards along its edges following them (the user, 2026-10-27): read off a view the window's size concentric with
// it (iOS 26's containerConcentricRadius), each corner its own (an iPhone Duo's outer screen: 8 along its hinge, 59
// on the other side; a uniform configuration says the roundest of them for all four).
static UIView *corner_probe;
static double corner_said[4] = {-1, -1, -1, -1};
static MBCornerCache corner_cache;
static __weak UIWindow *corner_win;
static void nav_invalidate_corners(void) {
  mb_corner_cache_invalidate(&corner_cache);
  corner_win = nil;
}
double mb_host_window_corner_at(int k) {
  if (!mb_host_nav_able()) return 0;
#ifdef __IPHONE_26_0
  if (@available(iOS 26.0, *)) {
    UIWindow *win = the_controller.view.window;
    if (!win) return 0;
    uintptr_t winTag = (uintptr_t)(__bridge void *)win;
    if (corner_win != win) {
      mb_corner_cache_invalidate(&corner_cache);
      corner_win = win;
    }
    double cached = 0;
    if (mb_corner_cache_hit(&corner_cache, winTag, win.bounds, k, &cached)) return cached;
    if (!corner_probe) {
      corner_probe = [[UIView alloc] initWithFrame:win.bounds];
      corner_probe.hidden = YES;
      corner_probe.userInteractionEnabled = NO;
      corner_probe.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
      UICornerRadius *c = [UICornerRadius containerConcentricRadius];
      corner_probe.cornerConfiguration = [UICornerConfiguration configurationWithTopLeftRadius:c topRightRadius:c
                                                                             bottomLeftRadius:c bottomRightRadius:c];
    }
    if (corner_probe.superview != win) [win addSubview:corner_probe];
    corner_probe.frame = win.bounds;
    [corner_probe layoutIfNeeded];
    // (the corner rule's order: top left, then round it)
    static const UIRectCorner which[4] = {UIRectCornerTopLeft, UIRectCornerTopRight, UIRectCornerBottomRight,
                                          UIRectCornerBottomLeft};
    double vals[4];
    for (int i = 0; i < 4; i++) {
      vals[i] = [corner_probe effectiveRadiusForCorner:which[i]];
      if (vals[i] != corner_said[i]) {
        corner_said[i] = vals[i];
        say([NSString stringWithFormat:@"ios: the screen's corner %d %.1f", i, vals[i]]);
      }
    }
    mb_corner_cache_store(&corner_cache, winTag, win.bounds, vals);
    corner_win = win;
    return vals[k & 3];
  }
#endif
  return 0;
}
double mb_host_window_corner(void) {
  double most = 0;
  for (int k = 0; k < 4; k++) {
    double r = mb_host_window_corner_at(k);
    if (r > most) most = r;
  }
  return most;
}
