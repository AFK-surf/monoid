// MBTabs' side of the overflow menu (ios_nav_overflow.h): where the system's bar is at rest, the finger that taps or
// drags onto its last slot, the system's own tabs put out of sight while the menu stands in their place and handed back
// as the menu lands shut. Everything it reads of the system's bar is public geometry (UITab's frames, views' frames
// and transforms): no private API, no class names. Included by ios_nav.h after MBTabs.

#ifdef __IPHONE_26_0
@implementation MBTabs (Overflow)

- (MBOverflowMenu *)menu API_AVAILABLE(ios(26.0)) { return (MBOverflowMenu *)self.overflowMenuView; }

// The place tabs shown before the overflow slot, in the bar's order.
- (NSArray<UITab *> *)primaryTabs {
  NSMutableArray<UITab *> *out = [NSMutableArray array];
  NSUInteger n = self.visibleRegularCap > 0 ? MIN(self.visibleRegularCap, self.allPlaces.count) : self.allPlaces.count;
  for (NSUInteger i = 0; i < n; i++) {
    UITab *t = self.tabsById[self.allPlaces[i][@"id"]];
    if (t && [self.tabs containsObject:t]) [out addObject:t];
  }
  return out;
}
- (UITab *)moreTab {
  UITab *t = self.tabsById[nav_more_id];
  return t && [self.tabs containsObject:t] ? t : nil;
}
- (UITab *)actionTab {
  UITab *t = self.action.length ? self.tabsById[self.action] : nil;
  return t && [self.tabs containsObject:t] ? t : nil;
}
static BOOL mbo_rect_ok(CGRect r) {
  return !CGRectIsNull(r) && !CGRectIsInfinite(r) && !CGRectIsEmpty(r);
}
// The page under the bars: the chosen tab's, whose views are the app's and never the bar's.
- (UIView *)standIn { return self.selectedViewController.viewIfLoaded; }

- (void)ensureOverflowMenu API_AVAILABLE(ios(26.0)) {
  if (self.overflowMenuView) return;
  MBOverflowMenu *menu = [[MBOverflowMenu alloc] initWithFrame:self.view.bounds];
  menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  __weak MBTabs *weakSelf = self;
  menu.onPick = ^(NSString *ident) { [weakSelf handleOverflowPick:ident]; };
  menu.onOpenChange = ^(BOOL open) {
    if (open) [weakSelf setNativeChromeHiddenWhileOpen:YES];
  };
  menu.onVisibilityChange = ^(BOOL visible) {
    if (!visible) {
      [weakSelf setNativeChromeHiddenWhileOpen:NO];
      [weakSelf clearStrandedDragScales];
    }
    [weakSelf updateChromeMask];
    [weakSelf placeDots];
  };
  menu.onTabsShownChange = ^(CGFloat shown) { [weakSelf updateDotsForMorph:shown]; };
  menu.drawTabs = ^(CGContextRef cg, CGFloat angle, const CGRect *slots, int count, int chosen, BOOL hasLens, CGRect lens, CGFloat lift) {
    [weakSelf drawTabRow:cg angle:angle slots:slots count:count chosen:chosen hasLens:hasLens lens:lens lift:lift];
  };
  menu.overflowGlyph = ^UIImage *(CGFloat zoom, CGFloat angle) { return [weakSelf overflowGlyphImage:zoom angle:angle]; };
  self.overflowMenuView = menu;
  [self.view addSubview:menu];

  UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleBarPress:)];
  press.minimumPressDuration = 0;
  press.allowableMovement = CGFLOAT_MAX;
  press.cancelsTouchesInView = NO;
  press.delaysTouchesEnded = NO;
  press.delegate = self;
  [self.view addGestureRecognizer:press];
  self.morePress = press;

  MBTakeOver *take = [MBTakeOver new];
  take.onTouchDown = ^(CGPoint point) { [weakSelf handleTouchDownAt:point]; };
  take.delegate = self;
  [self.view addGestureRecognizer:take];
  self.moreTakeOver = take;
}

// The menu's rows and colours as the bar has them now.
- (void)syncOverflowMenu {
  if (@available(iOS 26.0, *)) {
    BOOL has = self.overflowPlaces.count > 0 && self.shown && !self.tabBarHidden;
    if (!has) {
      [self.menu dismissImmediately];
      self.morePress.enabled = NO;
      self.moreTakeOver.enabled = NO;
      return;
    }
    [self ensureOverflowMenu];
    self.morePress.enabled = YES;
    self.moreTakeOver.enabled = YES;
    MBOverflowMenu *menu = self.menu;
    NSMutableArray<NSDictionary *> *primary = [NSMutableArray array];
    NSUInteger n = self.visibleRegularCap > 0 ? MIN(self.visibleRegularCap, self.allPlaces.count) : self.allPlaces.count;
    for (NSUInteger i = 0; i < n; i++) [primary addObject:self.allPlaces[i]];
    menu.primaryItems = primary;
    menu.ink = self.barInk ?: UIColor.labelColor;
    menu.accent = self.barAccent ?: UIColor.tintColor;
    menu.overflow = self.overflowPlaces;
    menu.selectedID = self.selectedPlaceId ?: @"";
  }
}

- (void)dismissOverflowMenu {
  if (@available(iOS 26.0, *)) [self.menu dismissImmediately];
}
- (BOOL)overflowMenuActive {
  if (@available(iOS 26.0, *)) return self.menu.isActive;
  return NO;
}

// The geometry kept is the bar's at rest: forgotten as the bar is laid out anew (its size, its side, its looks).
- (void)forgetRestingBar {
  self.moreArtKey = nil;
  self.hasRestingPlatter = NO;
  self.restingSlotFrames = nil;
  self.restingSlotArt = nil;
  self.restingBadges = nil;
  self.restingPillSize = CGSizeZero;
  self.restingPillEdgeInset = 0;
  if (@available(iOS 26.0, *)) self.menu.pressGlowColor = nil;
}

- (void)refreshOverflowLayout {
  if (@available(iOS 26.0, *)) {
    if (!self.overflowMenuView) {
      [self placeDots];
      return;
    }
    [self refreshMoreTab];
    [self cacheRestingGeometryIfIdle];
    [self placeDots];
    [self updateChromeMask];
    [self ensureOverlayOrder];
  }
}

// The menu over the system's bar, what rides the tab row (its dots) over the menu.
- (void)ensureOverlayOrder {
  UIView *menu = self.overflowMenuView;
  if (!menu) return;
  // (only when out of order: putting a view in front lays the controller's view out again)
  NSArray<UIView *> *subs = self.view.subviews;
  NSUInteger at = [subs indexOfObject:menu];
  BOOL ordered = at != NSNotFound && subs.count - at - 1 == self.moreDots.count;
  for (NSUInteger i = at + 1; ordered && i < subs.count; i++)
    if (![self.moreDots.allValues containsObject:subs[i]]) ordered = NO;
  if (ordered) return;
  [self.view bringSubviewToFront:menu];
  for (UIView *dot in self.moreDots.allValues) [self.view bringSubviewToFront:dot];
}

// ---- the overflow slot's own tab ----

// The overflow place the slot shows: the chosen place while it is in the menu, else the one chosen there last, else
// the menu's first.
- (NSDictionary *)overflowShownPlace {
  // (the app says the place: its own word, but for the row just chosen, shown ahead of its answer)
  if (self.moreSpec) {
    for (NSDictionary *d in self.overflowPlaces)
      if (self.overflowShownId.length && [d[@"id"] isEqual:self.overflowShownId]) return d;
    return self.moreSpec;
  }
  NSDictionary *last = nil;
  for (NSDictionary *d in self.overflowPlaces) {
    if (self.selectedPlaceId.length && [d[@"id"] isEqual:self.selectedPlaceId]) {
      self.overflowShownId = self.selectedPlaceId;
      return d;
    }
    if (self.overflowShownId.length && [d[@"id"] isEqual:self.overflowShownId]) last = d;
  }
  return last ?: self.overflowPlaces.firstObject;
}

// The slot's picture: the place's glyph and a chevron that points where the menu grows. Across the foot the glyph, 3
// points, a chevron up; down a side the glyph over a chevron pointing in from that side. A template for the bar to
// tint, or the glyph's own colours with the chevron in the bar's ink.
- (UIImage *)overflowTabImage:(UIImage *)source vertical:(BOOL)vertical trailing:(BOOL)trailing {
  if (!source) return nil;
  NSString *name = !vertical ? @"chevron.up" : (trailing ? @"chevron.left" : @"chevron.right");
  UIImage *chevron = [UIImage systemImageNamed:name
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightBold]];
  BOOL original = source.renderingMode == UIImageRenderingModeAlwaysOriginal;
  CGSize glyph = source.size;
  CGSize chev = chevron ? chevron.size : CGSizeZero;
  CGFloat gap = chevron ? 3 : 0;
  CGSize canvas = vertical ? CGSizeMake(ceil(MAX(glyph.width, chev.width)), ceil(glyph.height + gap + chev.height))
                           : CGSizeMake(ceil(glyph.width + gap + chev.width), ceil(MAX(glyph.height, chev.height)));
  UIColor *ink = [(self.barInk ?: UIColor.labelColor) resolvedColorWithTraitCollection:self.traitCollection];
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
  UIImage *made = [[[UIGraphicsImageRenderer alloc] initWithSize:canvas format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    CGRect g, c;
    if (vertical) {
      g = CGRectMake((canvas.width - glyph.width) / 2, 0, glyph.width, glyph.height);
      c = CGRectMake((canvas.width - chev.width) / 2, CGRectGetMaxY(g) + gap, chev.width, chev.height);
    } else {
      g = CGRectMake(0, (canvas.height - glyph.height) / 2, glyph.width, glyph.height);
      c = CGRectMake(CGRectGetMaxX(g) + gap, (canvas.height - chev.height) / 2, chev.width, chev.height);
    }
    if (original) {
      [source drawInRect:g];
      [[chevron imageWithTintColor:ink renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:c];
    } else {
      [[source imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:g];
      [[chevron imageWithTintColor:UIColor.blackColor renderingMode:UIImageRenderingModeAlwaysOriginal] drawInRect:c];
    }
  }];
  return [made imageWithRenderingMode:original ? UIImageRenderingModeAlwaysOriginal : UIImageRenderingModeAlwaysTemplate];
}

// The overflow slot's tab shows the place the menu was last used for: its title, its glyph with the chevron (made
// again only as the place, its icon, the bar's side or its looks change).
- (void)refreshMoreTab {
  if (@available(iOS 26.0, *)) {
    UITab *more = [self moreTab];
    NSDictionary *place = [self overflowShownPlace];
    if (!more || !place) return;
    BOOL vertical = NO, trailing = NO;
    [self barVertical:&vertical trailing:&trailing platter:CGRectNull];
    NSString *title = [place[@"title"] isKindOfClass:NSString.class] ? place[@"title"] : @"";
    NSString *icon = [place[@"icon"] isKindOfClass:NSString.class] ? place[@"icon"] : @"";
    NSString *key = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%d%d\x1f%ld\x1f%llx", place[@"id"], icon, title, vertical, trailing,
                                               (long)self.traitCollection.userInterfaceStyle, (unsigned long long)self.appliedInkVal];
    if ([key isEqualToString:self.moreArtKey]) return;
    self.moreArtKey = key;
    __weak MBTabs *weakSelf = self;
    UIImage *glyph = icon.length ? nav_any_then(icon, 26, ^{
      // (its picture come: the slot drawn again with it)
      weakSelf.moreArtKey = nil;
      [weakSelf refreshMoreTab];
    }) : nav_letter(title, 26);
    // (down a side the bar shows no titles at rest, and pressed it puts each under its glyph: where this slot's chevron
    // is, so this slot has none there)
    NSString *shownTitle = vertical ? @"" : title;
    if (![more.title isEqualToString:shownTitle]) more.title = shownTitle;
    more.image = [self overflowTabImage:glyph vertical:vertical trailing:trailing];
    NSString *moreWord = [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? @"更多" : @"More";
    more.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", moreWord, title];
  }
}

// ---- the system's bar, read by its geometry ----

- (NSArray<NSValue *> *)liveSlotFrames {
  NSMutableArray<NSValue *> *rects = [NSMutableArray array];
  NSArray<UITab *> *primary = [self primaryTabs];
  if (!primary.count) return @[];
  for (UITab *t in primary) {
    CGRect f = [t frameInView:self.view];
    if (!mbo_rect_ok(f)) return @[];
    [rects addObject:[NSValue valueWithCGRect:f]];
  }
  UITab *more = [self moreTab];
  CGRect f = more ? [more frameInView:self.view] : CGRectNull;
  if (!mbo_rect_ok(f)) return @[];
  [rects addObject:[NSValue valueWithCGRect:f]];
  return rects;
}

- (void)platterSearch:(UIView *)v home:(CGPoint)home more:(CGPoint)more hasAct:(BOOL)hasAct act:(CGPoint)act maxWidth:(CGFloat)maxWidth
                 best:(UIView *__strong *)best area:(CGFloat *)bestArea {
  UIView *standIn = [self standIn];
  if (v == self.overflowMenuView || (standIn && (v == standIn || [v isDescendantOfView:standIn]))) return;
  if (v != self.view && [self.moreDots.allValues containsObject:v]) return;
  if (v != self.view) {
    CGRect rect = [v convertRect:v.bounds toView:self.view];
    if (rect.size.width > 1 && rect.size.height > 1 && rect.size.width < maxWidth && CGRectContainsPoint(rect, home) &&
        CGRectContainsPoint(rect, more) && !(hasAct && CGRectContainsPoint(rect, act))) {
      CGFloat area = rect.size.width * rect.size.height;
      // (the outermost of the smallest: of views one inside another with one frame, the one that holds the rest)
      if (!*best || area < *bestArea - 0.5) {
        *best = v;
        *bestArea = area;
      }
    }
  }
  for (UIView *sub in v.subviews) [self platterSearch:sub home:home more:more hasAct:hasAct act:act maxWidth:maxWidth best:best area:bestArea];
}
// The system's platter under the place tabs (the first place and the overflow slot on it, the action's tab not): the
// smallest of the bar's views that holds them, the outermost of those with its frame, wherever the system keeps the bar
// (in the tab bar across the foot, in its floating column down a side).
- (UIView *)primaryPlatterView {
  UITab *first = [self primaryTabs].firstObject, *more = [self moreTab];
  if (!first || !more) return nil;
  CGRect homeRect = [first frameInView:self.view], moreRect = [more frameInView:self.view];
  if (!mbo_rect_ok(homeRect) || !mbo_rect_ok(moreRect)) return nil;
  UITab *act = [self actionTab];
  CGRect actRect = act ? [act frameInView:self.view] : CGRectNull;
  UIView *best = nil;
  CGFloat bestArea = 0;
  [self platterSearch:self.view
                 home:CGPointMake(CGRectGetMidX(homeRect), CGRectGetMidY(homeRect))
                 more:CGPointMake(CGRectGetMidX(moreRect), CGRectGetMidY(moreRect))
               hasAct:mbo_rect_ok(actRect)
                  act:CGPointMake(CGRectGetMidX(actRect), CGRectGetMidY(actRect))
             maxWidth:self.view.bounds.size.width * 0.95
                 best:&best
                 area:&bestArea];
  return best;
}

// The platter as it is now, in the controller's view; null where the tabs are not laid out.
- (CGRect)primaryPlatterFrame {
  UIView *platter = [self primaryPlatterView];
  if (platter) {
    CGRect rect = [platter convertRect:platter.bounds toView:self.view];
    if (rect.size.width > 1 && rect.size.height > 1) return rect;
  }
  NSArray<NSValue *> *rects = [self liveSlotFrames];
  if (!rects.count) return CGRectNull;
  CGRect all = CGRectNull;
  for (NSValue *v in rects) all = CGRectUnion(all, v.CGRectValue);
  BOOL vertical = all.size.height > all.size.width * 1.5;
  return CGRectInset(all, vertical ? -2 : -4, vertical ? -1.5 : -4);
}

// The platter as it is drawn now: pressed, the system grows the platter inside the room it keeps for it at rest, so the
// largest of the views in it that hold the first and the overflow slot is the one seen.
- (CGRect)livePlatterFrame {
  UIView *root = [self primaryPlatterView];
  CGRect best = [self primaryPlatterFrame];
  if (!root || self.restingSlotFrames.count < 2) return best;
  CGRect a = self.restingSlotFrames.firstObject.CGRectValue, b = self.restingSlotFrames.lastObject.CGRectValue;
  CGPoint home = CGPointMake(CGRectGetMidX(a), CGRectGetMidY(a)), more = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
  NSMutableArray<UIView *> *all = [NSMutableArray array];
  [self collectVisible:root into:all];
  CGFloat limit = self.view.bounds.size.width * 0.95;
  for (UIView *v in all) {
    CALayer *layer = v.layer.presentationLayer ?: v.layer;
    CGRect r = [(self.view.layer.presentationLayer ?: self.view.layer) convertRect:layer.bounds fromLayer:layer];
    if (r.size.width < limit && CGRectContainsPoint(r, home) && CGRectContainsPoint(r, more) &&
        r.size.width * r.size.height > best.size.width * best.size.height)
      best = r;
  }
  return best;
}

// The pressed bar read as it is, before its touches are called off (it falls back to rest at once then): its slots and
// where it draws their glyphs and words.
- (CGRect)shownRect:(UIView *)v {
  CALayer *root = self.view.layer.presentationLayer ?: self.view.layer;
  CALayer *layer = v.layer.presentationLayer ?: v.layer;
  return [root convertRect:layer.bounds fromLayer:layer];
}
// Every glyph and word the pressed bar shows, where it is on screen now (its presentation: a pressed bar is drawn
// larger than its views say) and in what ink; `accent` those of the copy the system shows under its lens.
- (NSArray<NSDictionary *> *)liveElements {
  UIView *platter = [self primaryPlatterView];
  if (!platter) return nil;
  NSMutableArray<UIImageView *> *images = [NSMutableArray array];
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  [self collectArt:platter images:images labels:labels];
  UIColor *accent = self.barAccent ?: self.view.tintColor;
  UITraitCollection *traits = self.traitCollection;
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  for (UIImageView *i in images) {
    CGRect r = [self shownRect:i];
    if (!(r.size.width > 1 && r.size.height > 1)) continue;
    [out addObject:@{@"rect" : [NSValue valueWithCGRect:r], @"image" : i.image, @"ink" : i.tintColor ?: UIColor.labelColor,
                     @"accent" : @(mbo_same_color(i.tintColor, accent, traits))}];
  }
  for (UILabel *l in labels) {
    CGRect r = [self shownRect:l];
    if (!(r.size.width > 1 && r.size.height > 1) || !l.font) continue;
    BOOL resting = mbo_same_color(l.textColor, self.barInk ?: UIColor.labelColor, traits);
    [out addObject:@{@"rect" : [NSValue valueWithCGRect:r], @"text" : l.text, @"font" : l.font, @"scale" : @(r.size.height / MAX(l.bounds.size.height, 1)),
                     @"ink" : resting ? l.textColor : accent, @"accent" : @(!resting)}];
  }
  return out;
}
// Samples one quiet pixel of the resting platter's ground in light mode so the press-glow veil uses normal alpha
// blending over that ground to match the system's additive press brightening (+10/255) without shifting hue. Dark mode
// keeps the translucent white @ 0.08 veil so the varying dark glass backdrop stays visible through it.
- (void)sampleRestingPressGlow:(CGRect)platter {
  if (@available(iOS 26.0, *)) {
    if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
      self.menu.pressGlowColor = nil;
      return;
    }
    if (!self.view.window || !mbo_rect_ok(platter)) return;
    BOOL vertical = platter.size.height > platter.size.width * 1.5;
    CGPoint at = vertical ? CGPointMake(CGRectGetMinX(platter) + 5, CGRectGetMidY(platter) + 33)
                          : CGPointMake(CGRectGetMidX(platter) + 33, CGRectGetMinY(platter) + 5);
    at = [self.view convertPoint:at toView:self.view.window];
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (cg) {
      CGContextTranslateCTM(cg, 0, 1);
      CGContextScaleCTM(cg, 1, -1);
      CGContextTranslateCTM(cg, -at.x, -at.y);
      UIGraphicsPushContext(cg);
      BOOL ok = [self.view.window drawViewHierarchyInRect:self.view.window.bounds afterScreenUpdates:NO];
      UIGraphicsPopContext();
      CGContextRelease(cg);
      if (ok && px[3] > 200) {
        CGFloat a = px[3] / 255.0;
        CGFloat r = MIN(1, (px[0] / 255.0) / a), g = MIN(1, (px[1] / 255.0) / a), b = MIN(1, (px[2] / 255.0) / a);
        CGFloat alpha = 0.9;
        CGFloat step = 10.0 / (255.0 * alpha);
        self.menu.pressGlowColor = [UIColor colorWithRed:MIN(1, r + step) green:MIN(1, g + step) blue:MIN(1, b + step) alpha:alpha];
      }
    }
    CGColorSpaceRelease(cs);
  }
}
- (void)captureLiveBar {
  self.liveArt = [self liveElements];
  NSArray<NSValue *> *live = [self liveSlotFrames];
  self.liveSlots = live.count ? live : nil;
  self.liveMoreSlot = live.count ? live.lastObject.CGRectValue : CGRectZero;
  self.liveBadges = live.count ? [self probeBadges] : nil;
  self.liveSlotArt = live.count ? [self probeSlotArt:live] : nil;
}

- (void)cacheRestingGeometryIfIdle {
  if (self.startedOnRegularTab || [self overflowMenuActive]) return;
  // The system shows the bar larger for a while by a transform on a view it is in (as the bar comes in, under a
  // finger): that is not its rest, and its views say then where it is not. It is looked at again once that is over.
  UIView *root = [self primaryPlatterView];
  for (UIView *v = root; v && v != self.view; v = v.superview) {
    if (CGAffineTransformIsIdentity(v.transform)) continue;
    if (self.restRetryPending) return;
    self.restRetryPending = YES;
    __weak MBTabs *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      weakSelf.restRetryPending = NO;
      [weakSelf refreshOverflowLayout];
    });
    return;
  }
  [self cacheRestingGeometry];
}
- (void)cacheRestingGeometry {
  CGRect platter = [self primaryPlatterFrame];
  if (!mbo_rect_ok(platter)) return;
  [self sampleRestingPressGlow:platter];
  NSArray<NSValue *> *slots = [self liveSlotFrames];
  if (!slots.count) return;
  self.restingPlatterFrame = platter;
  self.hasRestingPlatter = YES;
  self.restingSlotFrames = slots;
  self.restingSlotArt = [self probeSlotArt:slots];
  self.restingBadges = [self probeBadges];
  CGSize pill = CGSizeZero;
  CGFloat inset = 0;
  if ([self liveRestingPill:platter size:&pill inset:&inset]) {
    self.restingPillSize = pill;
    if (inset > 0) self.restingPillEdgeInset = inset;
  }
}

- (void)searchVerticalPill:(UIView *)current platter:(CGRect)platter targetW:(CGFloat)targetW best:(CGRect *)best has:(BOOL *)has {
  UIView *standIn = [self standIn];
  if (standIn && (current == standIn || [current isDescendantOfView:standIn])) return;
  if (current == self.overflowMenuView) return;
  if (current.hidden || !(current.alpha > 0.01)) return;
  CGRect rect = [current convertRect:current.bounds toView:self.view];
  if (CGRectContainsRect(CGRectInset(platter, -3, -3), rect) && fabs(rect.size.width - targetW) <= 2.5 && rect.size.height >= 50 &&
      rect.size.height <= 72) {
    if (!*has || fabs(rect.size.height - 58) < fabs(best->size.height - 58)) {
      *best = rect;
      *has = YES;
    }
  }
  for (UIView *sub in current.subviews) [self searchVerticalPill:sub platter:platter targetW:targetW best:best has:has];
}
- (void)searchHorizontalPill:(UIView *)current platter:(UIView *)platter targetH:(CGFloat)targetH major:(CGFloat)major
                        best:(CGRect *)best has:(BOOL *)has {
  for (UIView *sub in current.subviews) {
    if (sub.hidden || !(sub.alpha > 0.01)) continue;
    CGRect rect = [sub convertRect:sub.bounds toView:platter];
    if (fabs(rect.size.height - targetH) <= 2.5 && rect.size.width >= 55 && rect.size.width < major - 20) {
      // (the selection pill, a single slot's width, before anything wider)
      if (!*has || (rect.size.width > best->size.width && rect.size.width <= 110)) {
        *best = rect;
        *has = YES;
      }
    }
    [self searchHorizontalPill:sub platter:platter targetH:targetH major:major best:best has:has];
  }
}
// The native selection pill at rest, by geometry alone: its size, and how far it stands off the platter's ends
// (0 where that is not plain), so the menu's closing lands on it.
- (BOOL)liveRestingPill:(CGRect)platterFrame size:(CGSize *)size inset:(CGFloat *)inset {
  *inset = 0;
  if (platterFrame.size.height > platterFrame.size.width * 1.5) {
    CGFloat targetW = MAX(1, platterFrame.size.width - 4);
    CGRect best = CGRectZero;
    BOOL has = NO;
    if (self.isViewLoaded) [self searchVerticalPill:self.view platter:platterFrame targetW:targetW best:&best has:&has];
    if (has) {
      CGFloat off = MIN(CGRectGetMinY(best) - CGRectGetMinY(platterFrame), CGRectGetMaxY(platterFrame) - CGRectGetMaxY(best));
      *size = best.size;
      if (off >= 0.5 && off <= 8.0) *inset = off;
      return YES;
    }
    *size = CGSizeMake(targetW, 58);
    return YES;
  }
  UIView *platter = [self primaryPlatterView];
  if (!platter) {
    *size = CGSizeMake(MIN(94, MAX(66, platterFrame.size.width / 4 + 4)), MAX(1, platterFrame.size.height - 8));
    return YES;
  }
  CGFloat major = MAX(platter.bounds.size.width, platter.bounds.size.height);
  CGFloat targetH = MAX(1, platter.bounds.size.height - 8);
  CGRect best = CGRectZero;
  BOOL has = NO;
  [self searchHorizontalPill:platter platter:platter targetH:targetH major:major best:&best has:&has];
  if (has) {
    CGFloat off = MIN(CGRectGetMinX(best), platter.bounds.size.width - CGRectGetMaxX(best));
    *size = best.size;
    if (off >= 0.5 && off <= 8.0) *inset = off;
    return YES;
  }
  *size = CGSizeMake(MIN(94, MAX(66, platterFrame.size.width / 4 + 4)), targetH);
  return YES;
}

// Which way the bar stands: down a side where the system says so (iOS 27.1's vertical bar edge), else by its shape.
- (void)barVertical:(BOOL *)vertical trailing:(BOOL *)trailing platter:(CGRect)platter {
  *vertical = NO;
  *trailing = NO;
#ifdef __IPHONE_27_1
  if (@available(iOS 27.1, *)) {
    BOOL rtl = self.viewIfLoaded.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    UIVerticalBarEdge edge = self.traitCollection.verticalBarEdge;
    if (edge == UIVerticalBarEdgeLeading) {
      *vertical = YES;
      *trailing = rtl;
      return;
    }
    if (edge == UIVerticalBarEdgeTrailing) {
      *vertical = YES;
      *trailing = !rtl;
      return;
    }
  }
#endif
  CGRect frame = mbo_rect_ok(platter) ? platter : (self.hasRestingPlatter ? self.restingPlatterFrame : (self.isViewLoaded ? [self primaryPlatterFrame] : CGRectNull));
  if (mbo_rect_ok(frame) && frame.size.height > frame.size.width * 1.5 && self.isViewLoaded) {
    *vertical = YES;
    *trailing = CGRectGetMidX(frame) > CGRectGetMidX(self.view.bounds);
  }
}

- (void)collectVisible:(UIView *)v into:(NSMutableArray<UIView *> *)out {
  for (UIView *sub in v.subviews) {
    if (sub.hidden || !(sub.alpha > 0.01)) continue;
    [out addObject:sub];
    [self collectVisible:sub into:out];
  }
}
// The native lens lifted under a dragging finger, as it is on screen now (its presentation), and how far it is lifted:
// the lifted one of the platter's own views nearest the overflow slot; a lifted lens's size about the slot where the
// bar is not in the tab bar (down a side).
- (BOOL)nativeLens:(CGRect *)frame lift:(CGFloat *)lift {
  UITab *more = [self moreTab];
  CGRect moreRect = more ? [more frameInView:self.view] : CGRectNull;
  if (!mbo_rect_ok(moreRect)) return NO;
  UIView *platter = [self primaryPlatterView];
  if (!platter) {
    *frame = CGRectInset(moreRect, -14, -14);
    *lift = 0.9;
    return YES;
  }
  BOOL sideBar = platter.bounds.size.height > platter.bounds.size.width * 1.5;
  CGFloat platterMajor = MAX(platter.bounds.size.width, platter.bounds.size.height);
  CGPoint moreCenter = CGPointMake(CGRectGetMidX(moreRect), CGRectGetMidY(moreRect));
  CALayer *root = self.view.layer.presentationLayer ?: self.view.layer;
  UITab *first = [self primaryTabs].firstObject;
  CGRect slot = first ? [first frameInView:self.view] : moreRect;
  if (!mbo_rect_ok(slot)) slot = moreRect;
  CGFloat restMinor = MIN(slot.size.width, slot.size.height);
  BOOL has = NO;
  CGRect bestRect = CGRectZero;
  CGFloat bestLift = 0, bestDist = 0;
  NSMutableArray<UIView *> *all = [NSMutableArray array];
  [self collectVisible:platter into:all];
  for (UIView *sub in all) {
    if (!sub.subviews.count) continue;
    CGFloat major = MAX(sub.bounds.size.width, sub.bounds.size.height);
    if (!(major > 20 && major < platterMajor - 20)) continue;
    CALayer *layer = sub.layer.presentationLayer ?: sub.layer;
    CGRect rect = [root convertRect:layer.bounds fromLayer:layer];
    if (!(rect.size.width > 1 && rect.size.height > 1 && isfinite(rect.origin.x) && isfinite(rect.origin.y))) continue;
    CGFloat l = mbo_lens_lift(MIN(rect.size.width, rect.size.height), restMinor);
    CGFloat dist = hypot(CGRectGetMidX(rect) - moreCenter.x, CGRectGetMidY(rect) - moreCenter.y);
    if (!has || l > bestLift + 0.05 || (fabs(l - bestLift) <= 0.05 && dist < bestDist)) {
      has = YES;
      bestRect = rect;
      bestLift = l;
      bestDist = dist;
    }
  }
  if (has && bestLift > 0.05) {
    *frame = bestRect;
    *lift = bestLift;
    return YES;
  }
  // (none found lifted: a lifted lens's size about the slot, a side bar's larger)
  *frame = sideBar ? CGRectInset(moreRect, -14, -14) : CGRectInset(moreRect, -8, -8);
  *lift = 0.9;
  return YES;
}

- (void)openOverflowMenuTracking:(BOOL)tracking hasPoint:(BOOL)hasPoint point:(CGPoint)point hasLens:(BOOL)hasLens
                            lens:(CGRect)lens lift:(CGFloat)lift livePlatter:(CGRect)livePlatter API_AVAILABLE(ios(26.0)) {
  MBOverflowMenu *menu = self.menu;
  if (!menu || menu.isOpen || !self.overflowPlaces.count) return;
  CGRect platter = self.hasRestingPlatter ? self.restingPlatterFrame : (mbo_rect_ok(livePlatter) ? livePlatter : [self primaryPlatterFrame]);
  if (!mbo_rect_ok(platter)) return;
  NSArray<NSValue *> *slots = self.restingSlotFrames;
  NSUInteger want = [self primaryTabs].count + 1;
  if (slots.count != want) slots = [self liveSlotFrames];
  if (slots.count != want || slots.count < 2) return;
  BOOL vertical = NO, trailing = NO;
  [self barVertical:&vertical trailing:&trailing platter:platter];
  if (!vertical && self.view.frame.origin.x > 0) {
    CGFloat minLeft = 8;
    CGFloat left = MIN(MAX(CGRectGetMinX(platter), minLeft), MAX(minLeft, CGRectGetMaxX(platter) - 180));
    CGFloat right = MAX(MIN(CGRectGetMaxX(platter), self.view.bounds.size.width - 8), left + 180);
    platter = CGRectMake(left, platter.origin.y, right - left, platter.size.height);
  }
  CGFloat thickness = 0;
  if (vertical && mbo_rect_ok(livePlatter) && livePlatter.size.width > platter.size.width + 2) thickness = livePlatter.size.width;
  // (a dot put on or taken off a tab lays out the system's bar, not this view: the dots kept from the last layout are
  // looked at again while the system's bar still stands, so the row drawn in its place has the dots it has)
  if (!(hasLens && lift > 0.05)) {
    NSArray<NSDictionary *> *now = [self probeBadges];
    if (now.count != self.restingBadges.count) self.restingBadges = now;
  }
  UITab *more = [self moreTab];
  BOOL overflowSelected = self.selectedTab == more;
  int selectedSlot = 0;
  if (overflowSelected) selectedSlot = (int)want - 1;
  else {
    NSUInteger idx = [[self primaryTabs] indexOfObject:self.selectedTab];
    selectedSlot = idx == NSNotFound ? 0 : (int)idx;
  }
  CGSize pill = self.restingPillSize;
  CGFloat inset = self.restingPillEdgeInset;
  if (!(pill.width > 1) || !(inset > 0)) {
    CGSize livePill = CGSizeZero;
    CGFloat liveInset = 0;
    if ([self liveRestingPill:platter size:&livePill inset:&liveInset]) {
      if (!(pill.width > 1)) pill = livePill;
      if (!(inset > 0)) inset = liveInset;
    }
  }
  // Taking over from a lifted lens: the pressed bar as the system has it now (a side bar pressed is wider and longer,
  // and shows its words), for the picture the menu starts from.
  NSArray<NSValue *> *live = hasLens && lift > 0.05 && self.liveSlots.count == slots.count ? self.liveSlots : nil;
  if (!live) self.liveSlotArt = nil;
  if (!live) self.liveBadges = nil;
  if (!live) self.liveArt = nil;
  self.liveLens = live ? lens : CGRectZero;
  menu.handoffGlyphAtLens = live && self.liveArt.count > 0;
  self.liveSlots = nil;
  [self syncOverflowMenu];
  [self ensureOverlayOrder];
  // (across the foot the menu grows up to the top's safe room, less a margin; more rows scroll)
  menu.maxMenuHeight = MAX(120, CGRectGetMaxY(platter) - self.view.safeAreaInsets.top - 16);
  [menu openWithPlatter:platter slots:slots vertical:vertical trailing:trailing selectedSlot:selectedSlot overflowSelected:overflowSelected
                hasLens:hasLens lens:lens lift:lift thickness:thickness pill:pill pillInset:inset tracking:tracking hasPoint:hasPoint point:point
              liveSlots:live
            livePlatter:live ? livePlatter : CGRectNull];
}

// The overflow slot tapped (the system asked whether to choose it): the menu opened where it is not.
- (void)openOverflowFromTab {
  if (@available(iOS 26.0, *)) {
    if (![self overflowMenuActive])
      [self openOverflowMenuTracking:NO hasPoint:NO point:CGPointZero hasLens:NO lens:CGRectZero lift:0 livePlatter:CGRectNull];
  }
}

// A row chosen: said to the app as a tab chosen is, the overflow slot the chosen tab from now (the app's answer, its
// bars said again with the place chosen, finds it so).
- (void)handleOverflowPick:(NSString *)ident {
  if (!ident.length) return;
  self.selectedPlaceId = ident;
  self.overflowShownId = ident;
  [self refreshMoreTab];
  // (the bars as the app said them last no longer what is shown: said again, they are applied again)
  self.spec = nil;
  [self selectWantedTab];
  [self syncOverflowMenu];
  say_system(@{@"nav" : ident});
}

// ---- the finger: nothing done on the place tabs; a tap or a drag onto the overflow slot handed to the menu ----

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  // The takeover stays possible while the system's own drag is on a place tab, so it can still take the finger (and
  // call the views' touches off) once it has rested on the overflow slot.
  UIGestureRecognizer *take = self.moreTakeOver, *press = self.morePress;
  if (g == take || other == take) {
    if (take.state == UIGestureRecognizerStatePossible) return YES;
    return g == press || other == press;
  }
  return YES;
}

- (void)cancelTracking:(UIView *)root {
  for (UIGestureRecognizer *g in root.gestureRecognizers) {
    if (!g.enabled || g == self.morePress || g == self.moreTakeOver) continue;
    if (g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStatePossible) {
      g.enabled = NO;
      g.enabled = YES;
    }
  }
  UIView *standIn = [self standIn];
  for (UIView *sub in root.subviews) {
    if (sub == standIn || sub == self.overflowMenuView) continue;
    [self cancelTracking:sub];
  }
}
// Every touch and gesture of the system's bar called off, so it drops its lifted lens and lets its pressed glass go.
- (void)cancelTabBarTracking API_AVAILABLE(ios(26.0)) {
  [(MBTakeOver *)self.moreTakeOver take];
  if (self.isViewLoaded) [self cancelTracking:self.view];
}

- (BOOL)isOnMoreZone:(CGPoint)point {
  UITab *more = [self moreTab];
  CGRect moreRect = more ? [more frameInView:self.view] : CGRectNull;
  CGRect platter = self.hasRestingPlatter ? self.restingPlatterFrame : [self primaryPlatterFrame];
  if (!mbo_rect_ok(moreRect) || !mbo_rect_ok(platter)) return NO;
  BOOL vertical = NO, trailing = NO;
  [self barVertical:&vertical trailing:&trailing platter:platter];
  BOOL rtl = self.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
  return mbo_on_more_zone(point, moreRect, platter, vertical, trailing, rtl);
}

- (void)cancelMenuDwell {
  if (self.menuDwell) dispatch_block_cancel(self.menuDwell);
  self.menuDwell = nil;
}
// A dragging finger come to rest on the overflow slot: the menu opened under it after mbo_menu_dwell, the lens it
// dragged there taken over as it is.
- (void)armMenuDwellAt:(CGPoint)point API_AVAILABLE(ios(26.0)) {
  if (self.menuDwell && hypot(point.x - self.dwellAnchor.x, point.y - self.dwellAnchor.y) <= mbo_dwell_slop) {
    self.dwellPoint = point;
    return;
  }
  [self cancelMenuDwell];
  self.dwellAnchor = point;
  self.dwellPoint = point;
  __weak MBTabs *weakSelf = self;
  dispatch_block_t work = dispatch_block_create(0, ^{
    MBTabs *s = weakSelf;
    if (!s || !s.startedOnRegularTab || s.menu.isOpen) return;
    s.menuDwell = nil;
    CGRect lens = CGRectZero;
    CGFloat lift = 0;
    BOOL hasLens = [s nativeLens:&lens lift:&lift];
    CGRect livePlatter = [s livePlatterFrame];
    [s captureLiveBar];
    [s cancelTabBarTracking];
    [s openOverflowMenuTracking:YES hasPoint:YES point:s.dwellPoint hasLens:hasLens lens:lens lift:lift livePlatter:livePlatter];
  });
  self.menuDwell = work;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(mbo_menu_dwell * NSEC_PER_SEC)), dispatch_get_main_queue(), work);
}

- (void)handleTouchDownAt:(CGPoint)point {
  if (@available(iOS 26.0, *)) {
    self.openedOnTouchDown = NO;
    if ([self overflowMenuActive]) return;
    UITab *more = [self moreTab];
    CGRect moreRect = more ? [more frameInView:self.view] : CGRectNull;
    if (!mbo_rect_ok(moreRect) || !CGRectContainsPoint(moreRect, point)) return;
    self.startedOnRegularTab = NO;
    self.openedOnTouchDown = YES;
    [self cancelTabBarTracking];
    [self openOverflowMenuTracking:YES hasPoint:YES point:point hasLens:NO lens:CGRectZero lift:0 livePlatter:CGRectNull];
  }
}

- (void)handleBarPress:(UILongPressGestureRecognizer *)gesture {
  if (@available(iOS 26.0, *)) {
    MBOverflowMenu *menu = self.menu;
    CGPoint point = [gesture locationInView:self.view];
    [self followDotsFor:gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged ? 3600 : 0.8];
    switch (gesture.state) {
      case UIGestureRecognizerStateBegan: {
        if (self.openedOnTouchDown) {
          self.openedOnTouchDown = NO;
          return;
        }
        if (menu.isOpen) {
          [menu beginTrackingAt:point];
          return;
        }
        if (menu.isActive) return;
        UITab *more = [self moreTab];
        CGRect moreRect = more ? [more frameInView:self.view] : CGRectNull;
        if (mbo_rect_ok(moreRect) && CGRectContainsPoint(moreRect, point)) {
          self.startedOnRegularTab = NO;
          [self cancelTabBarTracking];
          [self openOverflowMenuTracking:YES hasPoint:YES point:point hasLens:NO lens:CGRectZero lift:0 livePlatter:CGRectNull];
          return;
        }
        CGRect platter = self.hasRestingPlatter ? self.restingPlatterFrame : [self primaryPlatterFrame];
        self.startedOnRegularTab = mbo_rect_ok(platter) && CGRectContainsPoint(CGRectInset(platter, -20, -20), point);
        break;
      }
      case UIGestureRecognizerStateChanged:
        if (menu.isOpen) {
          [menu updateTrackingAt:point];
          return;
        }
        if (!self.startedOnRegularTab) return;
        if ([self isOnMoreZone:point]) [self armMenuDwellAt:point];
        else [self cancelMenuDwell];
        break;
      case UIGestureRecognizerStateEnded:
        self.openedOnTouchDown = NO;
        [self cancelMenuDwell];
        if (menu.isOpen) {
          [menu endTrackingAt:point];
          self.startedOnRegularTab = NO;
          return;
        }
        if (self.startedOnRegularTab && [self isOnMoreZone:point]) {
          CGRect lens = CGRectZero;
          CGFloat lift = 0;
          BOOL hasLens = [self nativeLens:&lens lift:&lift];
          CGRect livePlatter = [self livePlatterFrame];
          [self captureLiveBar];
          [self cancelTabBarTracking];
          [self openOverflowMenuTracking:NO hasPoint:NO point:CGPointZero hasLens:hasLens lens:lens lift:lift livePlatter:livePlatter];
        }
        self.startedOnRegularTab = NO;
        break;
      default:
        self.openedOnTouchDown = NO;
        [self cancelMenuDwell];
        if (menu.isOpen && menu.isTracking) [menu cancelTracking];
        self.startedOnRegularTab = NO;
        break;
    }
  }
}

// ---- the system's tabs out of sight while the menu stands in their place ----

// The platter's own views: the outermost with the platter's frame and all in it. What else the system draws by the
// tabs (the action's tab, the bars' buttons) is not theirs and stays as it is.
- (UIView *)platterRoot {
  UIView *platter = [self primaryPlatterView];
  if (!platter) return nil;
  if (self.hasRestingPlatter) {
    CGRect r = [platter convertRect:platter.bounds toView:self.view];
    CGRect rest = self.restingPlatterFrame;
    // (the bar found now must be the one the menu stands on: pressed, a side bar is wider, never elsewhere)
    if (!CGRectContainsPoint(r, CGPointMake(CGRectGetMidX(rest), CGRectGetMidY(rest)))) return nil;
  }
  return platter;
}
- (void)hideChrome:(UIView *)current {
  if (current.hidden) return;
  [self.hiddenNativeViews addPointer:(__bridge void *)current];
  current.hidden = YES;
  for (UIView *sub in current.subviews) [self hideChrome:sub];
}
// Every view of the system's platter hidden from the menu's opening till its closing morph has landed. Hidden, not
// only masked: a lens lifted on a bar down a side is drawn through a portal that no ancestor's mask clips, and the
// glass of a bar along the bottom shows through a mask on its platter (its rim stood round the narrower closing menu).
- (void)setNativeChromeHiddenWhileOpen:(BOOL)hidden {
  if (!self.isViewLoaded) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (hidden) {
    if (!self.hiddenNativeViews.count) {
      self.hiddenNativeViews = [NSPointerArray weakObjectsPointerArray];
      UIView *root = [self platterRoot];
      if (root) [self hideChrome:root];
    }
  } else if (self.hiddenNativeViews.count) {
    for (UIView *v in self.hiddenNativeViews.allObjects) v.hidden = NO;
    self.hiddenNativeViews = [NSPointerArray weakObjectsPointerArray];
    [self clearStrandedDragScales];
  }
  [CATransaction commit];
  [self updateChromeMask];
}

// While the menu is open or morphing the system's platter is masked to nothing: its tabs keep their alpha, so
// VoiceOver has them, and nothing of its glass shows under the menu's. At rest the mask is taken off and the system's
// bar is untouched.
- (void)updateChromeMask {
  if (!self.isViewLoaded) return;
  BOOL want = [self overflowMenuActive];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (want) {
    if (!self.maskedChrome) self.maskedChrome = [NSMapTable weakToStrongObjectsMapTable];
    UIView *v = self.maskedChrome.count ? nil : [self platterRoot];
    if (v) {
      CALayer *mask = [CALayer layer];
      mask.backgroundColor = UIColor.blackColor.CGColor;
      mask.frame = CGRectZero;
      [self.maskedChrome setObject:@[ mask, v.layer.mask ?: (id)NSNull.null ] forKey:v];
      v.layer.mask = mask;
    }
  } else if (self.maskedChrome.count) {
    for (UIView *v in self.maskedChrome.keyEnumerator.allObjects) {
      NSArray *kept = [self.maskedChrome objectForKey:v];
      if (v.layer.mask == kept[0]) v.layer.mask = kept[1] == (id)NSNull.null ? nil : kept[1];
    }
    [self.maskedChrome removeAllObjects];
  }
  [CATransaction commit];
}

- (void)resetScales:(UIView *)current standIn:(UIView *)standIn {
  if (standIn && (current == standIn || [current isDescendantOfView:standIn])) return;
  if (current == self.overflowMenuView) return;
  CGAffineTransform t = current.transform;
  if (fabs(t.b) < 0.001 && fabs(t.c) < 0.001 && fabs(t.tx) < 0.001 && fabs(t.ty) < 0.001 && fabs(t.a - t.d) < 0.01 && t.a > 1.01 && t.a <= 1.5) {
    [current.layer removeAllAnimations];
    current.transform = CGAffineTransformIdentity;
  }
  for (UIView *sub in current.subviews) [self resetScales:sub standIn:standIn];
}
// A lifted lens's enlargement left on a tab's glyph when a drag onto the overflow slot was cut short while the bar was
// hidden: any view of the bar still scaled evenly by 1.01 to 1.5 with no turn or move is put back.
- (void)clearStrandedDragScales {
  UIView *root = self.isViewLoaded ? [self platterRoot] : nil;
  if (!root) return;
  [UIView performWithoutAnimation:^{ [self resetScales:root standIn:[self standIn]]; }];
}

// ---- what rides the tab row: the tabs' dots ----

// A tab's dot is drawn here, over the bar (the system's own badge is a disc of 18 points): 8 points across, its middle
// on the corner of the tab's glyph (13 points out and up from the middle of a 26 point glyph), wherever the system
// draws that glyph now (a pressed bar moves and enlarges its glyphs).
static const CGFloat mbo_dot_size = 8;
static const CGFloat mbo_dot_reach = 13;
- (NSArray<NSDictionary *> *)probeBadges {
  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  if (!self.dotTabIds.count || self.tabBarHidden || !self.shown) return out;
  // (frame by frame under a finger the platter is the one found as the following began, not looked for again)
  UIView *platter = self.followPlatter.window ? self.followPlatter : [self primaryPlatterView];
  NSMutableArray<UIImageView *> *images = [NSMutableArray array];
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  if (platter) [self collectArt:platter images:images labels:labels];
  BOOL rtl = self.view.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
  for (UITab *tab in self.tabs) {
    if (![self.dotTabIds containsObject:tab.identifier]) continue;
    CGRect slot = [tab frameInView:self.view];
    if (!mbo_rect_ok(slot)) continue;
    CGFloat halfH = tab.image ? tab.image.size.height / 2 : mbo_dot_reach;
    CGPoint c = CGPointMake(CGRectGetMidX(slot) + (rtl ? -mbo_dot_reach : mbo_dot_reach), CGRectGetMidY(slot) - halfH);
    for (UIImageView *i in images) {
      CGRect r = [self shownRect:i];
      if (!mbo_rect_ok(r) || !CGRectContainsPoint(slot, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) {
        r = [i convertRect:i.bounds toView:self.view];
        if (!CGRectContainsPoint(slot, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) continue;
      }
      // (the glyph is the first 26 points of the picture: the overflow slot's has its chevron after or under it)
      // The picture stands in the middle of its view, which may be larger than it.
      CGFloat k = r.size.height / MAX(i.bounds.size.height, 1);
      CGSize pic = CGSizeMake(i.image.size.width * k, i.image.size.height * k);
      CGRect p = CGRectMake(CGRectGetMidX(r) - pic.width / 2, CGRectGetMidY(r) - pic.height / 2, pic.width, pic.height);
      CGFloat glyph = MIN(mbo_dot_reach * 2 * k, pic.width);
      c = CGPointMake(rtl ? CGRectGetMaxX(p) - glyph : CGRectGetMinX(p) + glyph, CGRectGetMinY(p));
      break;
    }
    [out addObject:@{@"rect" : [NSValue valueWithCGRect:CGRectMake(c.x - mbo_dot_size / 2, c.y - mbo_dot_size / 2, mbo_dot_size, mbo_dot_size)],
                     @"color" : UIColor.systemRedColor, @"radius" : @(mbo_dot_size / 2)}];
  }
  return out;
}
// The app said which tabs carry a dot.
- (void)dotsSaid:(NSSet<NSString *> *)tabIds {
  if (self.dotTabIds == tabIds || [self.dotTabIds isEqualToSet:tabIds]) return;
  self.dotTabIds = tabIds;
  if (@available(iOS 26.0, *)) {
    if (!self.menu.isActive) self.restingBadges = [self probeBadges];
  }
  [self placeDots];
}
// While a finger is on the bar, and as the bar settles after it, the system moves and enlarges its glyphs: the dots
// follow them frame by frame.
- (void)followDotsFor:(CFTimeInterval)seconds {
  if (!self.dotTabIds.count) return;
  self.dotLinkUntil = CACurrentMediaTime() + seconds;
  if (self.dotLink) return;
  self.followPlatter = [self primaryPlatterView];
  self.dotLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(dotLinkTick:)];
  [self.dotLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)dotLinkTick:(CADisplayLink *)link {
  if (CACurrentMediaTime() > self.dotLinkUntil || !self.dotTabIds.count) {
    [self.dotLink invalidate];
    self.dotLink = nil;
    self.followPlatter = nil;
  }
  BOOL active = NO;
  if (@available(iOS 26.0, *)) active = self.menu.isActive;
  if (!active) [self placeDots];
}

// The dots, each a view over the bar and over the menu: at rest where the system draws the tabs' glyphs now; while the
// menu stands in the platter's place where they were as it took over, riding the tab row (pulled in with the squeezing
// glass along the bar) and fading with it, so the menu's glass never bends them.
- (void)placeDots {
  if (@available(iOS 26.0, *)) {
    MBOverflowMenu *menu = self.menu;
    BOOL active = menu.isActive;
    if (!self.moreDots) self.moreDots = [NSMutableDictionary dictionary];
    // (opening from a pressed bar: its dots where the system had them then; closing, where they are at rest)
    NSArray<NSDictionary *> *badges = !active ? [self probeBadges] : (menu.isOpen && self.liveBadges.count ? self.liveBadges : self.restingBadges);
    CGFloat shown = active ? menu.tabsShown : 1;
    CGFloat scale = active ? menu.barMajorScale : 1;
    CGRect platter = self.restingPlatterFrame;
    BOOL vertical = platter.size.height > platter.size.width * 1.5;
    for (NSUInteger i = 0; i < badges.count; i++) {
      NSString *key = @(i).stringValue;
      UIView *dot = self.moreDots[key];
      if (!dot) {
        dot = [UIView new];
        dot.userInteractionEnabled = NO;
        dot.accessibilityElementsHidden = YES;
        self.moreDots[key] = dot;
        [self.view addSubview:dot];
      }
      CGRect r = [badges[i][@"rect"] CGRectValue];
      CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
      if (scale < 0.9995) {
        CGPoint about = [menu glassCenterInView];
        if (vertical) c.y = about.y + (c.y - about.y) * scale;
        else c.x = about.x + (c.x - about.x) * scale;
      }
      CGRect next = CGRectMake(c.x - r.size.width / 2, c.y - r.size.height / 2, r.size.width, r.size.height);
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      dot.backgroundColor = badges[i][@"color"];
      dot.layer.cornerRadius = [badges[i][@"radius"] doubleValue];
      if (!CGRectEqualToRect(dot.frame, next)) dot.frame = next;
      if (fabs(dot.alpha - shown) > 0.001) dot.alpha = shown;
      if (dot.hidden) dot.hidden = NO;
      [CATransaction commit];
    }
    for (NSString *key in self.moreDots.allKeys) {
      if (key.integerValue < (NSInteger)badges.count) continue;
      UIView *dot = self.moreDots[key];
      if (!dot.hidden) dot.hidden = YES;
    }
    if (badges.count) [self ensureOverlayOrder];
  }
}
- (void)updateDotsForMorph:(CGFloat)shown {
  if (shown > 0.001) {
    [self placeDots];
  } else {
    for (UIView *dot in self.moreDots.allValues)
      if (fabs(dot.alpha - shown) > 0.001) dot.alpha = shown;
  }
}

// ---- the tab row's picture ----

- (void)collectArt:(UIView *)v images:(NSMutableArray<UIImageView *> *)images labels:(NSMutableArray<UILabel *> *)labels {
  if (v.hidden || !(v.alpha > 0.01)) return;
  if ([v isKindOfClass:UIImageView.class]) {
    UIImageView *i = (UIImageView *)v;
    if (i.image && i.bounds.size.width > 4 && i.bounds.size.height > 4) [images addObject:i];
  } else if ([v isKindOfClass:UILabel.class]) {
    UILabel *l = (UILabel *)v;
    if (l.text.length && l.bounds.size.width > 1 && l.bounds.size.height > 1) [labels addObject:l];
  }
  for (UIView *sub in v.subviews) [self collectArt:sub images:images labels:labels];
}
static BOOL mbo_same_color(UIColor *a, UIColor *b, UITraitCollection *t) {
  if (!a || !b) return NO;
  CGFloat ar, ag, ab, aa, br, bg, bb, ba;
  if (![[a resolvedColorWithTraitCollection:t] getRed:&ar green:&ag blue:&ab alpha:&aa]) return NO;
  if (![[b resolvedColorWithTraitCollection:t] getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
  return fabs(ar - br) < 0.01 && fabs(ag - bg) < 0.01 && fabs(ab - bb) < 0.01 && fabs(aa - ba) < 0.01;
}
// Where the system lays out each slot's glyph and words at rest, and in what ink (read off its own image views and
// labels inside the platter, public UIKit classes found by where they are): what the tab row's picture is drawn from,
// so it stands on the system's row point for point in every pose (words under the glyphs across the foot, none down a
// side). The system keeps each slot twice, once in the accent for under its selection: the one not in the accent is the
// resting one.
- (NSArray<NSDictionary *> *)probeSlotArt:(NSArray<NSValue *> *)slots {
  UIView *platter = [self primaryPlatterView];
  if (!platter) return nil;
  NSMutableArray<UIImageView *> *images = [NSMutableArray array];
  NSMutableArray<UILabel *> *labels = [NSMutableArray array];
  [self collectArt:platter images:images labels:labels];
  UIColor *accent = self.barAccent ?: self.view.tintColor;
  UITraitCollection *traits = self.traitCollection;
  NSMutableArray<NSMutableDictionary *> *out = [NSMutableArray array];
  for (NSValue *v in slots) {
    CGRect slot = v.CGRectValue;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (UIImageView *i in images) {
      CGRect r = [i convertRect:i.bounds toView:self.view];
      if (!CGRectContainsPoint(slot, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) continue;
      BOOL inAccent = mbo_same_color(i.tintColor, accent, traits);
      if (d[@"image"] && inAccent) continue;
      d[@"image"] = [NSValue valueWithCGRect:CGRectOffset(r, -slot.origin.x, -slot.origin.y)];
      if (!inAccent && i.tintColor) d[@"ink"] = i.tintColor;
      if (!inAccent) break;
    }
    for (UILabel *l in labels) {
      CGRect r = [l convertRect:l.bounds toView:self.view];
      if (!CGRectContainsPoint(slot, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) continue;
      // (the resting copy's words are in the bar's ink; the copy under the selection is in the tint)
      BOOL resting = mbo_same_color(l.textColor, self.barInk ?: UIColor.labelColor, traits);
      if (d[@"label"] && !resting) continue;
      d[@"label"] = [NSValue valueWithCGRect:CGRectOffset(r, -slot.origin.x, -slot.origin.y)];
      if (l.font) d[@"font"] = l.font;
      if (resting) d[@"labelInk"] = l.textColor;
      if (resting) break;
    }
    [out addObject:d];
  }
  // (the chosen slot's resting copy is not in the resting ink while it is chosen: every slot takes the ink of one that
  // is not chosen, so a slot chosen when this was read is drawn right once another is)
  NSArray<UITab *> *primary = [self primaryTabs];
  NSUInteger chosen = self.selectedTab == [self moreTab] ? primary.count : [primary indexOfObject:self.selectedTab];
  UIColor *ink = nil, *labelInk = nil;
  for (NSUInteger i = 0; i < out.count; i++) {
    if (i == chosen) continue;
    ink = ink ?: out[i][@"ink"];
    labelInk = labelInk ?: out[i][@"labelInk"];
  }
  for (NSMutableDictionary *d in out) {
    if (ink) d[@"ink"] = ink;
    if (labelInk) d[@"labelInk"] = labelInk;
  }
  return out;
}

// One slot as the system draws it, upright, its top left at the origin: its glyph where the system has it (in the
// slot's middle where that is not known), its words under it where the system shows them.
- (void)drawSlot:(NSUInteger)index size:(CGSize)size chosen:(BOOL)chosen live:(BOOL)live {
  NSArray<UITab *> *primary = [self primaryTabs];
  UITab *tab = index < primary.count ? primary[index] : [self moreTab];
  if (!tab) return;
  NSArray<NSDictionary *> *arts = live && self.liveSlotArt.count ? self.liveSlotArt : self.restingSlotArt;
  NSDictionary *art = index < arts.count ? arts[index] : nil;
  UITraitCollection *traits = self.traitCollection;
  UIColor *accent = [(self.barAccent ?: UIColor.tintColor) resolvedColorWithTraitCollection:traits];
  UIColor *resting = self.barInk ?: UIColor.labelColor;
  UIColor *ink = chosen ? accent : [(art[@"ink"] ?: resting) resolvedColorWithTraitCollection:traits];
  UIColor *labelInk = chosen ? accent : [(art[@"labelInk"] ?: resting) resolvedColorWithTraitCollection:traits];
  UIImage *image = tab.image;
  if (image) {
    CGRect r = art[@"image"] ? [art[@"image"] CGRectValue]
                             : CGRectMake((size.width - image.size.width) / 2, (size.height - image.size.height) / 2, image.size.width, image.size.height);
    UIImage *drawn = image.renderingMode == UIImageRenderingModeAlwaysOriginal ? image : [image imageWithTintColor:ink renderingMode:UIImageRenderingModeAlwaysOriginal];
    // (in its own size, in the middle of where the system's image view is)
    [drawn drawInRect:CGRectMake(CGRectGetMidX(r) - image.size.width / 2, CGRectGetMidY(r) - image.size.height / 2, image.size.width, image.size.height)];
  }
  if (art[@"label"] && tab.title.length) {
    CGRect r = [art[@"label"] CGRectValue];
    UIFont *font = art[@"font"] ?: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = NSTextAlignmentCenter;
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : labelInk, NSParagraphStyleAttributeName : para};
    CGSize s = [tab.title sizeWithAttributes:attrs];
    CGFloat w = MAX(r.size.width, MIN(ceil(s.width), size.width));
    [tab.title drawInRect:CGRectMake(CGRectGetMidX(r) - w / 2, CGRectGetMidY(r) - ceil(s.height) / 2, w, ceil(s.height)) withAttributes:attrs];
  }
}

// One of the pressed bar's glyphs or words, upright about the origin, as large as it was on screen.
- (void)drawLiveElement:(NSDictionary *)e {
  CGRect r = [e[@"rect"] CGRectValue];
  UIColor *ink = [(UIColor *)e[@"ink"] resolvedColorWithTraitCollection:self.traitCollection];
  UIImage *image = e[@"image"];
  if (image) {
    UIImage *drawn = image.renderingMode == UIImageRenderingModeAlwaysOriginal ? image : [image imageWithTintColor:ink renderingMode:UIImageRenderingModeAlwaysOriginal];
    [drawn drawInRect:CGRectMake(-r.size.width / 2, -r.size.height / 2, r.size.width, r.size.height)];
    return;
  }
  UIFont *font = e[@"font"];
  font = [font fontWithSize:font.pointSize * [e[@"scale"] doubleValue]];
  NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : ink};
  CGSize s = [e[@"text"] sizeWithAttributes:attrs];
  [e[@"text"] drawAtPoint:CGPointMake(-s.width / 2, -s.height / 2) withAttributes:attrs];
}

// The tab row drawn as the system's bar has it at rest, in the menu's canvas (`slots` in the platter's room, turned
// with a bar down a side: each slot drawn upright about its middle), the chosen one in the accent: the picture that
// blurs away as the menu grows and back in as it folds. Under a lifted lens the menu takes over from, none is drawn
// chosen, the glyphs near it are larger as the lens shows them, and the overflow slot's own is left to the lens.
- (void)drawTabRow:(CGContextRef)cg angle:(CGFloat)angle slots:(const CGRect *)slots count:(int)count chosen:(int)chosen
           hasLens:(BOOL)hasLens lens:(CGRect)lens lift:(CGFloat)lift {
  if (!hasLens) lift = 0;
  BOOL turned = fabs(sin(angle)) > 0.5;
  if (lift > 0.05 && self.liveArt.count) {
    // Taking over from a pressed bar: every glyph and word of its resting copy where and as large as the system had it
    // on screen (the overflow slot's left to the lens), so the takeover frame stands on the system's own.
    if (@available(iOS 26.0, *)) {
      MBOverflowMenu *menu = self.menu;
      CGRect more = self.liveMoreSlot;
      for (NSDictionary *e in self.liveArt) {
        if ([e[@"accent"] boolValue]) continue;
        CGRect r = [e[@"rect"] CGRectValue];
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        if (CGRectContainsPoint(more, c)) continue;
        CGPoint at = [menu barPointFromView:c];
        CGContextSaveGState(cg);
        CGContextTranslateCTM(cg, at.x, at.y);
        CGContextRotateCTM(cg, -angle);
        [self drawLiveElement:e];
        CGContextRestoreGState(cg);
      }
    }
    return;
  }
  for (int i = 0; i < count; i++) {
    BOOL isOverflow = i == count - 1;
    if (isOverflow && lift > 0.05) continue;
    BOOL selected = lift > 0.05 ? NO : i == chosen;
    CGRect rect = slots[i];
    CGFloat zoom = lift > 0.05 ? mbo_lens_zoom(fabs(CGRectGetMidX(rect) - CGRectGetMidX(lens)), lens.size.width / 2, lift) : 1;
    CGSize upright = turned ? CGSizeMake(rect.size.height, rect.size.width) : rect.size;
    CGContextSaveGState(cg);
    CGContextTranslateCTM(cg, CGRectGetMidX(rect), CGRectGetMidY(rect));
    if (zoom > 1.001) CGContextScaleCTM(cg, zoom, zoom);
    CGContextRotateCTM(cg, -angle);
    CGContextTranslateCTM(cg, -upright.width / 2, -upright.height / 2);
    [self drawSlot:(NSUInteger)i size:upright chosen:selected live:lift > 0.05];
    CGContextRestoreGState(cg);
  }
}

// The overflow slot's glyph (and words) `zoom` times its size about the slot's middle, turned as the canvas is, for
// the lens that carries it across the takeover: as the system's lifted lens shows it, in the accent, the pressed bar's
// slot.
- (UIImage *)overflowGlyphImage:(CGFloat)zoom angle:(CGFloat)angle {
  if (self.liveArt.count && self.liveLens.size.width > 1) {
    // What the system's lifted lens showed (its accent copy, already enlarged), about the lens's middle.
    CGRect lens = self.liveLens;
    CGFloat side = ceil(MAX(lens.size.width, lens.size.height) + 24);
    CGPoint mid = CGPointMake(CGRectGetMidX(lens), CGRectGetMidY(lens));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
      CGContextRef cg = ctx.CGContext;
      CGContextTranslateCTM(cg, side / 2, side / 2);
      CGContextRotateCTM(cg, -angle);
      for (NSDictionary *e in self.liveArt) {
        // (the overflow slot's own only: a neighbour's words that reach under the lens stay the row's)
        if (![e[@"accent"] boolValue]) continue;
        CGRect r = [e[@"rect"] CGRectValue];
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        if (!CGRectContainsPoint(self.liveMoreSlot, c)) continue;
        CGContextSaveGState(cg);
        CGContextTranslateCTM(cg, c.x - mid.x, c.y - mid.y);
        [self drawLiveElement:e];
        CGContextRestoreGState(cg);
      }
    }];
  }
  UITab *more = [self moreTab];
  NSUInteger index = [self primaryTabs].count;
  CGRect slot = self.liveSlotArt.count && self.liveMoreSlot.size.width > 1 ? self.liveMoreSlot
                : index < self.restingSlotFrames.count ? self.restingSlotFrames[index].CGRectValue : (more ? [more frameInView:self.view] : CGRectNull);
  if (!mbo_rect_ok(slot)) return nil;
  CGFloat side = ceil((MAX(slot.size.width, slot.size.height) + 8) * zoom);
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
  return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    CGContextRef cg = ctx.CGContext;
    CGContextTranslateCTM(cg, side / 2, side / 2);
    CGContextScaleCTM(cg, zoom, zoom);
    CGContextRotateCTM(cg, -angle);
    CGContextTranslateCTM(cg, -slot.size.width / 2, -slot.size.height / 2);
    [self drawSlot:index size:slot.size chosen:YES live:YES];
  }];
}
@end
#endif
