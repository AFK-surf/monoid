// The tab bar's overflow slot grown into a menu of the places that did not fit (MBTabs, ios_nav.h): the system's own
// UITabBarController keeps drawing the bar at rest, its taps, drags and lens; this view stays hidden (no display link)
// until the last slot is tapped or dragged onto, then its glass (UIGlassEffect, regular) stands exactly where the
// system's platter is, grows into the rows, and folds back before the system's bar shows again. Its numbers and state
// are ios_nav_overflow_state.h's; iOS 26 on (the glass), under its SDK's macro as the rest of ios_nav.h.

#import "ios_nav_overflow_state.h"

#ifdef __IPHONE_26_0
#import <CoreImage/CoreImage.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

// Waits without effect until the bar takes the finger, then recognizes so UIKit cancels the touch in the views under.
@interface MBTakeOver : UIGestureRecognizer
@property(nonatomic, copy) void (^onTouchDown)(CGPoint point);
- (void)take;
@end
@implementation MBTakeOver
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  UITouch *t = touches.anyObject;
  if (t && self.onTouchDown) self.onTouchDown([t locationInView:self.view]);
}
- (void)take {
  if (self.state == UIGestureRecognizerStatePossible) self.state = UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (self.state == UIGestureRecognizerStateBegan || self.state == UIGestureRecognizerStateChanged)
    self.state = UIGestureRecognizerStateChanged;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  self.state = self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateEnded;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  self.state = self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateCancelled;
}
@end

// Glass that stands upright on screen while what it holds turns with the canvas, so its rim light and shadow stay
// upright on a bar down a side.
API_AVAILABLE(ios(26.0))
@interface MBUprightGlass : NSObject
@property(nonatomic, readonly) UIVisualEffectView *glass;
@property(nonatomic, readonly) UIView *contentView;
@property(nonatomic, weak) UIView *canvas;
@property(nonatomic) CGFloat angle;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGPoint center;
- (instancetype)initWithEffect:(UIVisualEffect *)effect;
- (void)setFrame:(CGRect)frame;
@end
@implementation MBUprightGlass
- (instancetype)initWithEffect:(UIVisualEffect *)effect {
  if ((self = [super init])) {
    _glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    _contentView = [UIView new];
    [_glass.contentView addSubview:_contentView];
  }
  return self;
}
- (void)setAngle:(CGFloat)angle { _angle = angle; [self place]; }
- (void)setBounds:(CGRect)bounds { _bounds = bounds; [self place]; }
- (void)setCenter:(CGPoint)center { _center = center; [self place]; }
- (void)setFrame:(CGRect)f {
  _bounds = CGRectMake(0, 0, f.size.width, f.size.height);
  _center = CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f));
  [self place];
}
- (void)place {
  UIView *canvas = self.canvas, *host = self.glass.superview;
  if (!canvas || !host) return;
  BOOL turned = fabs(sin(self.angle)) > 0.5;
  self.glass.bounds = turned ? CGRectMake(0, 0, _bounds.size.height, _bounds.size.width) : CGRectMake(0, 0, _bounds.size.width, _bounds.size.height);
  self.glass.center = [canvas convertPoint:_center toView:host];
  CGAffineTransform turn = CGAffineTransformMakeRotation(self.angle);
  if (!CGAffineTransformEqualToTransform(self.contentView.transform, turn)) self.contentView.transform = turn;
  self.contentView.bounds = CGRectMake(0, 0, _bounds.size.width, _bounds.size.height);
  self.contentView.center = CGPointMake(CGRectGetMidX(self.glass.bounds), CGRectGetMidY(self.glass.bounds));
}
@end

// Core Image's context for the contents' blur as they cross: no colour management, so the blur is of the encoded
// values, as Core Animation's own filters blur.
static CIContext *mbo_ci(void) {
  static CIContext *ctx;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace : NSNull.null, kCIContextOutputColorSpace : NSNull.null}];
  });
  return ctx;
}

// One of the two contents that cross inside the glass (the tab row's picture, the menu's rows): drawn pieces, each
// with its own blur, opacity and offset, the whole blurred and faded with them. A Gaussian blur of `radius` points is
// one of that standard deviation, spreading past the pieces' edges. No frame of the morph renders a blur: each piece's
// picture is blurred at a few standard deviations once, off the main thread, as the piece is given (the menu's opening,
// its closing), and a frame only says which two of them show and how far between them it is (two layers' contents and
// one's opacity), two blurs one after the other being one of the root of their squares' sum.
static const CGFloat mbo_blur_levels[] = {0, 0.75, 1.5, 3, 6, 12};
#define MBO_BLUR_LEVELS 6

@interface MBOPiece : NSObject
@property(nonatomic, strong) UIImage *picture;
@property(nonatomic) CGPoint origin;  // points, from the layer's top left
@property(nonatomic) CGFloat blur, alpha, dy;
@property(nonatomic, strong) NSMutableArray *levels;  // a CGImage each once made, NSNull till then
@property(nonatomic, strong) CALayer *box, *under, *over;
@end
@implementation MBOPiece
@end

@interface MBOBlurLayer : UIView
@property(nonatomic, strong) NSArray<MBOPiece *> *pieces;
@property(nonatomic) CGFloat blur;
- (void)redraw;
@end
@implementation MBOBlurLayer
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
  }
  return self;
}
static dispatch_queue_t mbo_blur_queue(void) {
  static dispatch_queue_t q;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("mbui.nav.overflow.blur", DISPATCH_QUEUE_SERIAL); });
  return q;
}
// How far past the picture's edges level `k` spreads (points): three of its standard deviation.
static CGFloat mbo_level_margin(int k) { return k ? ceil(mbo_blur_levels[k] * 3) + 2 : 0; }
// Level `k` of `picture`: blurred by that level's standard deviation, with its margin all round; drawn on a coarser
// grid the more it is blurred (it has no detail finer than its blur) and stretched by the layer that shows it.
static CGImageRef mbo_level_image(CGImageRef picture, CGFloat scale, int k) CF_RETURNS_RETAINED {
  CGFloat sigma = mbo_blur_levels[k] * scale, margin = mbo_level_margin(k) * scale;
  CGFloat grid = 1;
  while (grid > 0.125 && sigma * grid >= 3) grid /= 2;
  CIImage *img = [[CIImage imageWithCGImage:picture options:@{kCIImageColorSpace : NSNull.null}] imageByApplyingGaussianBlurWithSigma:sigma];
  CGRect out = CGRectMake(-margin, -margin, CGImageGetWidth(picture) + margin * 2, CGImageGetHeight(picture) + margin * 2);
  img = [[img imageByCroppingToRect:out] imageByApplyingTransform:CGAffineTransformMakeScale(grid, grid)];
  return [mbo_ci() createCGImage:img fromRect:CGRectMake(out.origin.x * grid, out.origin.y * grid, out.size.width * grid, out.size.height * grid)];
}
- (void)setPieces:(NSArray<MBOPiece *> *)pieces {
  for (MBOPiece *p in _pieces)
    if (![pieces containsObject:p]) [p.box removeFromSuperlayer];
  _pieces = [pieces copy];
  CGFloat scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 2;
  NSDictionary *still = @{@"contents" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null, @"opacity" : NSNull.null, @"hidden" : NSNull.null};
  for (MBOPiece *p in _pieces) {
    if (p.box) {
      if (p.box.superlayer != self.layer) [self.layer addSublayer:p.box];
      continue;
    }
    p.box = [CALayer layer];
    p.under = [CALayer layer];
    p.over = [CALayer layer];
    p.box.actions = p.under.actions = p.over.actions = still;
    [p.box addSublayer:p.under];
    [p.box addSublayer:p.over];
    [self.layer addSublayer:p.box];
    CGImageRef picture = p.picture.CGImage;
    p.levels = [NSMutableArray arrayWithObject:picture ? (__bridge id)picture : NSNull.null];
    for (int k = 1; k < MBO_BLUR_LEVELS; k++) [p.levels addObject:NSNull.null];
    if (!picture) continue;
    UIImage *kept = p.picture;
    __weak MBOBlurLayer *weakSelf = self;
    __weak MBOPiece *piece = p;
    dispatch_async(mbo_blur_queue(), ^{
      for (int k = 1; k < MBO_BLUR_LEVELS; k++) {
        CGImageRef made = mbo_level_image(kept.CGImage, scale, k);
        if (!made) continue;
        id image = (__bridge_transfer id)made;
        dispatch_async(dispatch_get_main_queue(), ^{
          piece.levels[k] = image;
          [weakSelf redraw];
        });
      }
    });
  }
  [self redraw];
}
// What shows now: for each piece the two levels its blur lies between (the nearest made yet, while one is still being
// made), how far between them, its opacity and where it is.
- (void)redraw {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (MBOPiece *p in self.pieces) {
    BOOL shown = p.picture != nil && p.alpha > 0.001;
    if (p.box.hidden == shown) p.box.hidden = !shown;
    if (!shown) continue;
    CGFloat sigma = MIN(hypot(p.blur, self.blur), mbo_blur_levels[MBO_BLUR_LEVELS - 1]);
    int k = 0;
    while (k < MBO_BLUR_LEVELS - 2 && sigma >= mbo_blur_levels[k + 1]) k++;
    CGFloat part = (sigma - mbo_blur_levels[k]) / (mbo_blur_levels[k + 1] - mbo_blur_levels[k]);
    int a = k, b = k + 1;
    while (a > 0 && p.levels[a] == NSNull.null) a--;
    if (p.levels[b] == NSNull.null) part = 0;
    CGSize size = p.picture.size;
    p.box.frame = CGRectMake(p.origin.x, p.origin.y + p.dy, size.width, size.height);
    if (p.box.opacity != (float)p.alpha) p.box.opacity = p.alpha;
    id under = p.levels[a], over = part > 0.001 ? p.levels[b] : nil;
    if (p.under.contents != under) p.under.contents = under;
    p.under.frame = CGRectInset(p.box.bounds, -mbo_level_margin(a), -mbo_level_margin(a));
    if (p.over.contents != over) p.over.contents = over;
    p.over.frame = CGRectInset(p.box.bounds, -mbo_level_margin(b), -mbo_level_margin(b));
    if (p.over.opacity != (float)part) p.over.opacity = part;
  }
  [CATransaction commit];
}
@end

// A row for VoiceOver: activated, it chooses its place.
@interface MBOMenuRow : UIView
@property(nonatomic, copy) void (^onActivate)(void);
@end
@implementation MBOMenuRow
- (BOOL)accessibilityActivate {
  if (self.onActivate) self.onActivate();
  return YES;
}
@end

API_AVAILABLE(ios(26.0))
@interface MBOverflowMenu : UIView
// The places in the bar before the overflow slot and the ones in the menu: `id`, `title`, `icon` (nav_any's), `dot`.
@property(nonatomic, copy) NSArray<NSDictionary *> *primaryItems;
@property(nonatomic, copy) NSArray<NSDictionary *> *overflow;
@property(nonatomic, copy) NSString *selectedID;
@property(nonatomic, strong) UIColor *ink;
@property(nonatomic, strong) UIColor *accent;
// The tab row as the system's bar draws it at rest, into a picture the platter's size in the canvas (`slots` there, in
// the platter's room), for what blurs away as the menu grows: drawn by the owner, who knows the system's layout.
// `lens`: a lifted lens the menu takes over from, under which the glyphs are drawn larger and none chosen, and the
// overflow slot's left out.
@property(nonatomic, copy) void (^drawTabs)(CGContextRef cg, CGFloat canvasAngle, const CGRect *slots, int count, int chosenSlot, BOOL hasLens, CGRect lens, CGFloat lift);
// (under a lifted lens `slots` are the pressed bar's own, where the system has them then: a pressed side bar is wider and longer)
// The overflow slot's own glyph `zoom` times its size, for the lens that carries it across the takeover.
@property(nonatomic, copy) UIImage * (^overflowGlyph)(CGFloat zoom, CGFloat canvasAngle);
@property(nonatomic, copy) void (^onPick)(NSString *ident);
@property(nonatomic, copy) void (^onDismiss)(void);
// YES the frame the menu takes the platter's place, NO once the closing morph has landed.
@property(nonatomic, copy) void (^onVisibilityChange)(BOOL visible);
// YES while the menu is open (modal), NO as soon as it starts to close.
@property(nonatomic, copy) void (^onOpenChange)(BOOL open);
// Each morph frame: how visible the resting tab row is (1 at rest, 0 open), for what rides the row (its dots).
@property(nonatomic, copy) void (^onTabsShownChange)(CGFloat shown);
@property(nonatomic, strong) UIColor *pressGlowColor;
// The selection haptic's ticks so far (a test counts them).
@property(nonatomic) NSUInteger ticks;
@property(nonatomic, readonly) BOOL isOpen;
@property(nonatomic, readonly) BOOL isMorphing;
@property(nonatomic, readonly) BOOL isTracking;
@property(nonatomic, readonly) BOOL isActive;
@property(nonatomic, readonly) CGFloat tabsShown;
@property(nonatomic, readonly) CGFloat barMajorScale;
// `platter`, `slots` (NSValue rects, the overflow slot last), `lens`: in this view's room. `vertical`: a bar down a
// side, `trailing` the trailing one. `pill`: the native selection pill's size on screen at rest, `pillInset` how far
// it stands off the bar's ends (0: unknown). `thickness`: the live bar's, where a pressed side bar has widened.
- (void)openWithPlatter:(CGRect)platter slots:(NSArray<NSValue *> *)slots vertical:(BOOL)vertical trailing:(BOOL)trailing
           selectedSlot:(int)selectedSlot overflowSelected:(BOOL)overflowSelected hasLens:(BOOL)hasLens lens:(CGRect)lens
                   lift:(CGFloat)lift thickness:(CGFloat)thickness pill:(CGSize)pill pillInset:(CGFloat)pillInset
               tracking:(BOOL)tracking hasPoint:(BOOL)hasPoint point:(CGPoint)point liveSlots:(NSArray<NSValue *> *)liveSlots
               livePlatter:(CGRect)livePlatter;
- (void)beginTrackingAt:(CGPoint)point;
- (void)updateTrackingAt:(CGPoint)point;
- (void)endTrackingAt:(CGPoint)point;
- (void)cancelTracking;
- (void)close;
- (void)dismissImmediately;
- (void)tick:(CADisplayLink *)link;
// A point of this view in the room the tab row's picture is drawn in (the resting platter's, in the canvas).
- (CGPoint)barPointFromView:(CGPoint)p;
// The glass's middle now, in this view: what rides the tab row is pulled in toward it as the glass squeezes.
- (CGPoint)glassCenterInView;
// The lens's glyph is drawn about the lens's own middle (the owner drew it from the pressed bar as it stood), not
// about the overflow slot's.
@property(nonatomic) BOOL handoffGlyphAtLens;
// How tall the menu may grow where the bar lies across the foot (points; 0: as tall as its rows): more rows scroll.
@property(nonatomic) CGFloat maxMenuHeight;
@end

@interface MBOLinkTarget : NSObject
@property(nonatomic, weak) id menu;
@end
@implementation MBOLinkTarget
- (void)tick:(CADisplayLink *)link {
  if (@available(iOS 26.0, *)) [(MBOverflowMenu *)self.menu tick:link];
}
@end

static UIColor *mbo_default_press_glow(void) {
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
    return [UIColor colorWithWhite:1 alpha:t.userInterfaceStyle == UIUserInterfaceStyleDark ? 0.08 : 0.8];
  }];
}

@implementation MBOverflowMenu {
  MBOverflow _m;
  BOOL _trailing;
  UIView *_canvas;
  MBUprightGlass *_bar;
  // A clear lens over the bar's glass while the menu takes over from a lifted native lens, so that lens goes on
  // unbroken across the takeover frame as it turns into the grey indicator; the overflow slot's enlarged glyph inside it.
  MBUprightGlass *_handoffGlass;
  UIImageView *_handoffGlyph;
  UIView *_pressGlow;
  CGPoint _handoffGlyphOffset;
  CGPoint _tabsOrigin;
  BOOL _takenOver;
  CFTimeInterval _lastScrollStep;
  CGRect _liveSlots[MBO_MAX_SLOTS];
  int _liveCount;
  UIView *_tabContent, *_pill, *_menuClip, *_menuIndicator, *_indicatorFill, *_indicatorNativeFill, *_menuRows;
  UIVisualEffectView *_indicatorFrost;
  NSMutableArray<MBOMenuRow *> *_rowViews;
  MBOBlurLayer *_rowsLayer, *_tabsLayer;
  NSMutableArray<MBOPiece *> *_rowPieces;
  MBOPiece *_tabsPiece;
  CGSize _rowsDrawnSize;
  NSString *_rowsDrawnKey;
  CADisplayLink *_link;
  CFTimeInterval _trackUntil;
  UISelectionFeedbackGenerator *_selection;
}

static UIColor *mbo_selection_fill(void) {
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
    return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0 alpha:0.30] : [UIColor colorWithWhite:0 alpha:0.05];
  }];
}
// The system's resting selection pill over regular glass: light, black at 0.072; dark, a darker well (black at 0.48),
// not a lighter grey.
static UIColor *mbo_native_pill_fill(void) {
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
    return t.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:0 alpha:0.48] : [UIColor colorWithWhite:0 alpha:0.072];
  }];
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  mbo_init(&_m);
  _rowViews = [NSMutableArray array];
  _rowPieces = [NSMutableArray array];
  _selection = [UISelectionFeedbackGenerator new];
  self.backgroundColor = UIColor.clearColor;
  self.hidden = YES;
  self.userInteractionEnabled = NO;

  _canvas = [UIView new];
  _canvas.userInteractionEnabled = NO;
  [self addSubview:_canvas];

  UIGlassEffect *regular = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  regular.interactive = YES;
  _bar = [[MBUprightGlass alloc] initWithEffect:regular];
  _bar.canvas = _canvas;
  _bar.glass.accessibilityIdentifier = @"navOverflow.bar";
  _bar.glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:31]];
  [self addSubview:_bar.glass];

  // The lens the menu takes over from the system's bar. The system's lifted lens is clear right through (the pressed
  // bar and the page show in it); the clear glass an app can make is a white disc in light, so the regular one, which
  // lets what is under it show, stands in for it.
  UIGlassEffect *clear = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  clear.interactive = NO;
  _handoffGlass = [[MBUprightGlass alloc] initWithEffect:clear];
  _handoffGlass.canvas = _canvas;
  _handoffGlass.glass.accessibilityIdentifier = @"navOverflow.handoffLens";
  _handoffGlass.glass.userInteractionEnabled = NO;
  _handoffGlass.glass.alpha = 0;
  _handoffGlass.glass.hidden = YES;
  _handoffGlass.glass.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  _handoffGlyph = [UIImageView new];
  _handoffGlyph.contentMode = UIViewContentModeCenter;
  _handoffGlyph.userInteractionEnabled = NO;
  _handoffGlyph.backgroundColor = UIColor.clearColor;
  [_handoffGlass.contentView addSubview:_handoffGlyph];
  [self addSubview:_handoffGlass.glass];

  _pill = [UIView new];
  _pill.accessibilityIdentifier = @"navOverflow.pill";
  _pill.userInteractionEnabled = NO;
  _pill.clipsToBounds = YES;
  _pill.layer.cornerCurve = kCACornerCurveContinuous;
  _pill.backgroundColor = mbo_native_pill_fill();
  _tabContent = [UIView new];
  _tabContent.userInteractionEnabled = NO;
  _tabContent.accessibilityElementsHidden = YES;
  [_tabContent addSubview:_pill];
  _tabContent.autoresizingMask = UIViewAutoresizingNone;
  [_bar.contentView addSubview:_tabContent];

  _menuClip = [UIView new];
  _menuClip.userInteractionEnabled = NO;
  _menuClip.clipsToBounds = YES;
  _menuClip.layer.cornerCurve = kCACornerCurveContinuous;
  _menuClip.layer.cornerRadius = 31;
  _menuClip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _rowsLayer = [MBOBlurLayer new];
  _tabsLayer = [MBOBlurLayer new];
  _rowsLayer.accessibilityElementsHidden = YES;
  _tabsLayer.accessibilityElementsHidden = YES;
  // A pressed bar's glass is lit under the finger: the menu that takes over from one starts as lit and dims as the lens
  // it took over fades, so the bar's ground does not change on the takeover frame. (Measured off the system's bar:
  // pressed, it is 80% of the way to white in light, 8% in dark.)
  _pressGlow = [UIView new];
  _pressGlow.userInteractionEnabled = NO;
  _pressGlow.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _pressGlow.backgroundColor = mbo_default_press_glow();
  _pressGlow.alpha = 0;
  _pressGlow.hidden = YES;
  [_menuClip addSubview:_pressGlow];
  [_menuClip addSubview:_rowsLayer];
  [_menuClip addSubview:_tabsLayer];
  _tabsPiece = [MBOPiece new];
  _tabsPiece.alpha = 1;
  [_bar.contentView addSubview:_menuClip];

  // Clipped inside the menu's clip under its rows, so the indicator never sticks out of the squeezing glass. Its
  // frost keeps one size that covers a row lying or standing: its backdrop is never made again mid-morph.
  _menuIndicator = [UIView new];
  _menuIndicator.accessibilityIdentifier = @"navOverflow.menuIndicator";
  _menuIndicator.userInteractionEnabled = NO;
  _menuIndicator.alpha = 0;
  _menuIndicator.hidden = YES;
  _indicatorFill = [UIView new];
  _indicatorFill.clipsToBounds = YES;
  _indicatorFill.layer.cornerCurve = kCACornerCurveContinuous;
  _indicatorFill.frame = _menuIndicator.bounds;
  _indicatorFill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _indicatorFrost = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]];
  _indicatorFrost.userInteractionEnabled = NO;
  _indicatorFrost.contentView.backgroundColor = mbo_selection_fill();
  _indicatorFrost.autoresizingMask = UIViewAutoresizingNone;
  _indicatorFrost.frame = CGRectMake(0, 0, 360, 260);
  [_indicatorFill addSubview:_indicatorFrost];
  _indicatorNativeFill = [UIView new];
  _indicatorNativeFill.backgroundColor = mbo_native_pill_fill();
  _indicatorNativeFill.userInteractionEnabled = NO;
  _indicatorNativeFill.alpha = 0;
  _indicatorNativeFill.frame = _indicatorFill.bounds;
  _indicatorNativeFill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [_indicatorFill addSubview:_indicatorNativeFill];
  [_menuIndicator addSubview:_indicatorFill];
  [_menuClip insertSubview:_menuIndicator belowSubview:_rowsLayer];

  _menuRows = [UIView new];
  _menuRows.hidden = YES;
  _menuRows.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [_bar.contentView addSubview:_menuRows];
  // (Core Image's context and its blur made ready now, off the main thread, not as the menu first opens)
  dispatch_async(mbo_blur_queue(), ^{
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)];
    UIImage *dot = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [UIColor.blackColor setFill]; UIRectFill(CGRectMake(2, 2, 4, 4)); }];
    CGImageRef got = dot.CGImage ? mbo_level_image(dot.CGImage, 1, 2) : NULL;
    if (got) CGImageRelease(got);
  });
  return self;
}

- (void)setPressGlowColor:(UIColor *)c {
  _pressGlowColor = c;
  _pressGlow.backgroundColor = c ?: mbo_default_press_glow();
}
- (BOOL)isOpen { return _m.isOpen; }
- (BOOL)isMorphing { return _m.isMorphing; }
- (BOOL)isTracking { return _m.isTracking; }
- (BOOL)isActive { return _m.isOpen || _m.isMorphing; }
- (CGFloat)tabsShown { return _m.tabsShown; }
- (CGFloat)barMajorScale { return mbo_major_scale(&_m); }
- (CGFloat)canvasAngle { return !_m.vertical ? 0 : (_trailing ? -M_PI / 2 : M_PI / 2); }
- (CGPoint)canvasPoint:(CGPoint)p { return [self convertPoint:p toView:_canvas]; }
- (CGPoint)barPointFromView:(CGPoint)p {
  CGPoint c = [self canvasPoint:p];
  return CGPointMake(c.x - _m.barFrame.origin.x, c.y - _m.barFrame.origin.y);
}
- (CGPoint)glassCenterInView { return [_canvas convertPoint:mbo_glass_center(&_m) toView:self]; }

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (!self.userInteractionEnabled || self.hidden || !_m.isOpen) return nil;
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self applyCanvasBounds];
  if (!self.isActive) return;
  if (!_m.isMorphing) {
    _m.glassHeight = _m.isOpen ? mbo_menu_frame(&_m).size.height : mbo_thickness(&_m);
    _m.glassInset = 0;
  }
  [self placeGlass];
  [self layoutGlassContent];
}

- (void)applyCanvasBounds {
  _canvas.transform = CGAffineTransformIdentity;
  _canvas.bounds = _m.vertical ? CGRectMake(0, 0, self.bounds.size.height, self.bounds.size.width) : self.bounds;
  _canvas.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  _canvas.transform = CGAffineTransformMakeRotation(self.canvasAngle);
  _bar.angle = self.canvasAngle;
  _handoffGlass.angle = self.canvasAngle;
}

- (void)placeGlass {
  _bar.bounds = mbo_glass_bounds(&_m);
  _bar.center = mbo_glass_center(&_m);
}

// ---- the model ----
- (void)setOverflow:(NSArray<NSDictionary *> *)overflow {
  if ([overflow isEqual:_overflow]) return;
  _overflow = [overflow copy];
  [self rebuildMenu];
}
- (void)setSelectedID:(NSString *)selectedID {
  if ((selectedID == _selectedID) || [selectedID isEqualToString:_selectedID]) return;
  _selectedID = [selectedID copy];
  [self refreshRows];
}
- (void)setInk:(UIColor *)ink {
  if ((ink == _ink) || [ink isEqual:_ink]) return;
  _ink = ink;
  [self refreshRows];
}
- (void)setAccent:(UIColor *)accent {
  if ((accent == _accent) || [accent isEqual:_accent]) return;
  _accent = accent;
  [self refreshRows];
}

- (void)rebuildMenu {
  for (UIView *r in _rowViews) [r removeFromSuperview];
  [_rowViews removeAllObjects];
  __weak MBOverflowMenu *weakSelf = self;
  NSInteger index = 0;
  for (NSDictionary *item in self.overflow) {
    MBOMenuRow *row = [MBOMenuRow new];
    row.userInteractionEnabled = NO;
    row.isAccessibilityElement = YES;
    row.accessibilityTraits = UIAccessibilityTraitButton;
    row.accessibilityLabel = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
    row.accessibilityIdentifier = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : @"";
    NSInteger i = index++;
    row.onActivate = ^{ [weakSelf pickRow:(int)i]; };
    [_menuRows addSubview:row];
    [_rowViews addObject:row];
  }
  _m.overflowCount = (int)self.overflow.count;
  [self refreshRows];
  [self setNeedsLayout];
}

- (void)refreshRows {
  _m.activeRow = -1;
  for (NSUInteger i = 0; i < self.overflow.count && i < _rowViews.count; i++) {
    NSString *ident = self.overflow[i][@"id"];
    BOOL chosen = self.selectedID.length && [ident isEqual:self.selectedID];
    if (chosen) _m.activeRow = (int)i;
    _rowViews[i].accessibilityTraits = chosen ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected) : UIAccessibilityTraitButton;
  }
  _rowsDrawnKey = nil;
  if (self.isActive) [self layoutGlassContent];
}

// A row's picture as the menu stands upright: its icon 24 across from 14 in, its words from 50 in, the row's words in
// the bar's ink, the chosen place's in its accent as its tab is; a dot at its end where its place has one.
- (UIImage *)rowImage:(NSDictionary *)item chosen:(BOOL)chosen size:(CGSize)size {
  NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
  NSString *iconSpec = [item[@"icon"] isKindOfClass:NSString.class] ? item[@"icon"] : @"";
  UIColor *color = [(chosen ? (self.accent ?: UIColor.tintColor) : (self.ink ?: UIColor.labelColor)) resolvedColorWithTraitCollection:self.traitCollection];
  UIImage *icon = iconSpec.length ? nav_any(iconSpec, mbo_glyph) : nav_letter(title, mbo_glyph);
  BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
  BOOL dot = [item[@"dot"] boolValue];
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
  return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    if (icon) {
      UIImage *drawn = icon.renderingMode == UIImageRenderingModeAlwaysOriginal ? icon : [icon imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
      CGFloat cx = mbo_row_icon_x + mbo_glyph / 2;
      if (rtl) cx = size.width - cx;
      [drawn drawInRect:CGRectMake(cx - icon.size.width / 2, (size.height - icon.size.height) / 2, icon.size.width, icon.size.height)];
    }
    CGFloat end = dot ? 14 + 8 + 8 : 0;
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    para.alignment = rtl ? NSTextAlignmentRight : NSTextAlignmentLeft;
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
    NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : color, NSParagraphStyleAttributeName : para};
    CGFloat w = MAX(0, size.width - mbo_row_label_x - end);
    CGFloat h = MIN(size.height, ceil(font.lineHeight));
    [title drawWithRect:CGRectMake(rtl ? end : mbo_row_label_x, (size.height - h) / 2, w, h)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
             attributes:attrs
                context:nil];
    if (dot) {
      CGFloat cx = rtl ? 14 + 4 : size.width - 14 - 4;
      [UIColor.systemRedColor setFill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx - 4, size.height / 2 - 4, 8, 8)] fill];
    }
  }];
}

// The rows' pictures for the menu's size as it stands upright (made again as the rows, the colours or the size change).
- (void)drawRowsIfNeeded:(CGSize)upright {
  NSString *key = [NSString stringWithFormat:@"%.1fx%.1f/%ld/%@", upright.width, upright.height,
                                             (long)self.traitCollection.userInterfaceStyle, self.traitCollection.preferredContentSizeCategory];
  if ([key isEqualToString:_rowsDrawnKey] && _rowPieces.count == self.overflow.count) return;
  _rowsDrawnKey = key;
  [_rowPieces removeAllObjects];
  CGSize rowSize = CGSizeMake(MAX(1, upright.width - mbo_menu_padding * 2), mbo_menu_row);
  for (NSUInteger i = 0; i < self.overflow.count; i++) {
    MBOPiece *p = [MBOPiece new];
    p.picture = [self rowImage:self.overflow[i] chosen:(int)i == _m.activeRow size:rowSize];
    p.origin = CGPointMake(mbo_menu_padding, mbo_menu_padding + mbo_menu_row * i);
    p.alpha = 1;
    [_rowPieces addObject:p];
  }
  _rowsLayer.pieces = _rowPieces;
}

// What the two crossing contents show now: each row its own way in, the whole faded and blurred by the morph as it
// closes; the tab row's picture by how far the glass has grown.
- (void)drawContents {
  CFTimeInterval now = CACurrentMediaTime();
  CGFloat p = mbo_content_progress(&_m);
  for (NSUInteger i = 0; i < _rowPieces.count; i++) {
    _rowPieces[i].origin = CGPointMake(mbo_menu_padding, mbo_menu_padding + mbo_menu_row * i - _m.scroll);
    CGFloat shown = mbo_row_shown(&_m, (int)i, now);
    _rowPieces[i].alpha = shown;
    _rowPieces[i].blur = mbo_morph_blur * (1 - shown);
    _rowPieces[i].dy = mbo_row_rise_at(&_m, (int)i, now);
  }
  CGFloat rowsAlpha = _m.rowsClosing ? mbo_rows_opacity(p) : 1;
  _rowsLayer.blur = _m.rowsClosing ? mbo_morph_blur * (1 - mbo_rows_opacity(p)) : 0;
  if (fabs(_rowsLayer.alpha - rowsAlpha) > 0.001) _rowsLayer.alpha = rowsAlpha;
  if (rowsAlpha > 0.001) [_rowsLayer redraw];
  [self fadeRowEnds];
  CGFloat tabs = mbo_tabs_opacity(p);
  _tabsLayer.blur = mbo_morph_blur * (1 - tabs);
  if (fabs(_tabsLayer.alpha - tabs) > 0.001) _tabsLayer.alpha = tabs;
  if (tabs > 0.001 && _tabsPiece.picture) [_tabsLayer redraw];
}

// Rows past either end of their room fade out toward that end (a mask over the rows as they stand upright), so it shows
// that there are more; none where they all fit.
- (void)fadeRowEnds {
  CGFloat most = mbo_max_scroll(&_m);
  if (!(most > 0)) {
    if (_rowsLayer.layer.mask) _rowsLayer.layer.mask = nil;
    return;
  }
  CAGradientLayer *fade = (CAGradientLayer *)_rowsLayer.layer.mask;
  if (![fade isKindOfClass:CAGradientLayer.class]) {
    fade = [CAGradientLayer layer];
    fade.actions = @{@"colors" : NSNull.null, @"bounds" : NSNull.null, @"position" : NSNull.null, @"locations" : NSNull.null};
    _rowsLayer.layer.mask = fade;
  }
  CGRect b = _rowsLayer.bounds;
  if (!CGRectEqualToRect(fade.frame, b)) fade.frame = b;
  CGFloat h = MAX(b.size.height, 1), pad = mbo_menu_padding, reach = 28;
  id clear = (__bridge id)[UIColor.blackColor colorWithAlphaComponent:0].CGColor, full = (__bridge id)UIColor.blackColor.CGColor;
  fade.colors = @[ _m.scroll > 0.5 ? clear : full, full, full, _m.scroll < most - 0.5 ? clear : full ];
  fade.locations = @[ @(pad / h), @((pad + reach) / h), @((h - pad - reach) / h), @((h - pad) / h) ];
}

- (void)setTabsImage:(UIImage *)img {
  // (a new picture is a new piece: its blurred levels are made for it)
  CGPoint origin = _tabsOrigin;
  _tabsPiece = [MBOPiece new];
  _tabsPiece.alpha = 1;
  _tabsPiece.origin = origin;
  _tabsPiece.picture = img;
  _tabsLayer.pieces = img ? @[ _tabsPiece ] : @[];
}

- (UIImage *)tabRowImageWithLens:(BOOL)hasLens lens:(CGRect)lens lift:(CGFloat)lift {
  CGSize size = _m.barFrame.size;
  if (!self.drawTabs || size.width < 1 || size.height < 1) return nil;
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection];
  CGFloat angle = self.canvasAngle;
  int chosen = _m.anchorSelectedSlot;
  void (^draw)(CGContextRef, CGFloat, const CGRect *, int, int, BOOL, CGRect, CGFloat) = self.drawTabs;
  MBOverflow m = _m;
  // (taking over from a lifted lens: the pressed bar's slots, which may stand past the resting bar's room; the picture
  // is as large as the layer that shows it and is not cut to the bar)
  BOOL live = hasLens && lift > 0.05 && _liveCount == m.slotCount;
  if (live) memcpy(m.slots, _liveSlots, sizeof(CGRect) * (size_t)m.slotCount);
  CGFloat pad = live ? 40 : 0;
  _tabsOrigin = CGPointMake(-pad, -pad);
  return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size.width + pad * 2, size.height + pad * 2) format:format]
      imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextTranslateCTM(ctx.CGContext, pad, pad);
        draw(ctx.CGContext, angle, m.slots, m.slotCount, chosen, hasLens, lens, lift);
      }];
}

- (void)layoutGlassContent {
  CGFloat width = _bar.bounds.size.width, height = _bar.bounds.size.height;
  CGFloat thick = mbo_thickness(&_m);
  CGFloat scaleX = mbo_major_scale(&_m);
  CGFloat angle = self.canvasAngle;
  CGPoint shift = mbo_glass_shift(&_m);
  _tabContent.frame = CGRectMake(-shift.x, height - thick - shift.y, width, thick);
  _tabContent.hidden = _m.tabContentHidden;
  if (!_tabContent.hidden) [self placeMorphPill];
  CGSize size = mbo_menu_frame(&_m).size;
  CGFloat rowsX = mbo_menu_start(&_m) - _m.glassInset - shift.x;
  _menuRows.frame = CGRectMake(rowsX, height - size.height, size.width, size.height);
  for (NSUInteger i = 0; i < _rowViews.count; i++) _rowViews[i].frame = mbo_row_frame(&_m, (int)i);
  _menuClip.frame = _bar.contentView.bounds;
  CGRect rowsFrame = CGRectMake(rowsX, 0, size.width, size.height);
  CGAffineTransform upright = CGAffineTransformMakeRotation(-angle);
  if (!CGAffineTransformEqualToTransform(_rowsLayer.transform, upright)) _rowsLayer.transform = upright;
  CGSize uprightSize = _m.vertical ? CGSizeMake(size.height, size.width) : size;
  _rowsLayer.bounds = CGRectMake(0, 0, uprightSize.width, uprightSize.height);
  _rowsLayer.center = CGPointMake(CGRectGetMidX(rowsFrame), CGRectGetMidY(rowsFrame));
  [self drawRowsIfNeeded:uprightSize];
  CGAffineTransform snap = scaleX < 0.9995 ? CGAffineTransformMakeScale(scaleX, 1) : CGAffineTransformIdentity;
  if (!CGAffineTransformEqualToTransform(_tabsLayer.transform, snap)) _tabsLayer.transform = snap;
  CGFloat barLength = _m.barFrame.size.width;
  _tabsLayer.bounds = CGRectMake(0, 0, barLength, thick);
  // (the picture is in the resting bar's room; it pulls in with the glass about the glass's own middle, which under a
  // pressed bar's shape is off the resting bar's)
  CGFloat middle = barLength > 0 ? 0.5 + mbo_glass_mid_off(&_m) / barLength : 0.5;
  _tabsLayer.layer.anchorPoint = CGPointMake(middle, 0.5);
  _tabsLayer.center = CGPointMake(width / 2, height - thick / 2 - shift.y);
  CGSize frost = CGSizeMake(MAX(MAX(size.width, _m.barFrame.size.width), 360),
                            MAX(MAX(MAX(size.height, mbo_menu_row), MAX(thick, mbo_side_menu_width)), 260));
  if (!CGSizeEqualToSize(_indicatorFrost.bounds.size, frost)) _indicatorFrost.frame = CGRectMake(0, 0, frost.width, frost.height);
  [self drawContents];
}

- (void)placeMorphPill {
  CGRect scaled = mbo_morph_pill(&_m);
  _pill.transform = CGAffineTransformIdentity;
  _pill.bounds = CGRectMake(0, 0, scaled.size.width, scaled.size.height);
  _pill.center = CGPointMake(CGRectGetMidX(scaled), CGRectGetMidY(scaled));
  _pill.layer.cornerRadius = MIN(scaled.size.width, scaled.size.height) / 2;
}

// The state's alphas and frames on the views (the pill, the indicator and the lens the menu took over from).
- (void)applyShown {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (fabs(_pill.alpha - _m.pillAlpha) > 0.001) _pill.alpha = _m.pillAlpha;
  BOOL pillHidden = _m.pillAlpha <= 0.015;
  if (_pill.hidden != pillHidden) _pill.hidden = pillHidden;
  CGRect fitted = _m.indicatorFitted;
  if (!CGRectEqualToRect(_menuIndicator.frame, fitted)) _menuIndicator.frame = fitted;
  _indicatorFill.layer.cornerRadius = MIN(fitted.size.width, fitted.size.height) / 2;
  if (fabs(_indicatorFill.alpha - _m.indicatorGrey) > 0.001) _indicatorFill.alpha = _m.indicatorGrey;
  if (fabs(_indicatorNativeFill.alpha - _m.indicatorNative) > 0.001) _indicatorNativeFill.alpha = _m.indicatorNative;
  CGFloat frostAlpha = 1 - _m.indicatorNative;
  if (fabs(_indicatorFrost.alpha - frostAlpha) > 0.001) _indicatorFrost.alpha = frostAlpha;
  if (_m.handoffShown) {
    [_handoffGlass setFrame:_m.handoffFrame];
    CGRect content = _handoffGlass.contentView.bounds;
    // (what the lens carries shows inside the lens only, as under the system's)
    CGFloat round = MIN(content.size.width, content.size.height) / 2;
    _handoffGlass.contentView.layer.cornerRadius = _m.vertical ? MIN(round, 37) : round;
    _handoffGlass.contentView.layer.masksToBounds = YES;
    _handoffGlyph.center = CGPointMake(CGRectGetMidX(content) + _handoffGlyphOffset.x * _m.handoffAlpha,
                                       CGRectGetMidY(content) + _handoffGlyphOffset.y * _m.handoffAlpha);
    if (fabs(_handoffGlyph.alpha - _m.handoffGlyphAlpha) > 0.001) _handoffGlyph.alpha = _m.handoffGlyphAlpha;
    if (fabs(_handoffGlass.glass.alpha - _m.handoffAlpha) > 0.001) _handoffGlass.glass.alpha = _m.handoffAlpha;
    if (_handoffGlass.glass.hidden) _handoffGlass.glass.hidden = NO;
  } else {
    if (fabs(_handoffGlass.glass.alpha) > 0.001) _handoffGlass.glass.alpha = 0;
    if (fabs(_handoffGlyph.alpha) > 0.001) _handoffGlyph.alpha = 0;
    if (!_handoffGlass.glass.hidden) _handoffGlass.glass.hidden = YES;
  }
  CGFloat glow = _m.handoffShown ? _m.handoffAlpha : 0;
  if (fabs(_pressGlow.alpha - glow) > 0.001) _pressGlow.alpha = glow;
  if (_pressGlow.hidden != (glow <= 0.001)) _pressGlow.hidden = glow <= 0.001;
  if (fabs(_menuIndicator.alpha - _m.indicatorAlpha) > 0.001) _menuIndicator.alpha = _m.indicatorAlpha;
  BOOL indHidden = _m.indicatorAlpha <= 0.001;
  if (_menuIndicator.hidden != indHidden) _menuIndicator.hidden = indHidden;
  [CATransaction commit];
}

- (void)tickHaptic {
  self.ticks += 1;
  [_selection selectionChanged];
}

// ---- opening, closing ----
- (void)openWithPlatter:(CGRect)platter slots:(NSArray<NSValue *> *)slots vertical:(BOOL)vertical trailing:(BOOL)trailing
           selectedSlot:(int)selectedSlot overflowSelected:(BOOL)overflowSelected hasLens:(BOOL)hasLens lens:(CGRect)lens
                   lift:(CGFloat)lift thickness:(CGFloat)thickness pill:(CGSize)pill pillInset:(CGFloat)pillInset
               tracking:(BOOL)tracking hasPoint:(BOOL)hasPoint point:(CGPoint)point liveSlots:(NSArray<NSValue *> *)liveSlots
               livePlatter:(CGRect)livePlatter {
  if (_m.isOpen || !self.overflow.count) return;
  _m.vertical = vertical;
  _m.mirrored = vertical && trailing;
  _trailing = trailing;
  [self applyCanvasBounds];
  _m.barFrame = [_canvas convertRect:platter fromView:self];
  _m.slotCount = (int)MIN(slots.count, (NSUInteger)MBO_MAX_SLOTS);
  for (int i = 0; i < _m.slotCount; i++) {
    CGRect r = [_canvas convertRect:slots[i].CGRectValue fromView:self];
    _m.slots[i] = CGRectOffset(r, -_m.barFrame.origin.x, -_m.barFrame.origin.y);
  }
  // (the pressed bar's slots, for the picture the menu takes over with from a lifted lens)
  _liveCount = liveSlots.count == slots.count ? _m.slotCount : 0;
  for (int i = 0; i < _liveCount; i++) {
    CGRect r = [_canvas convertRect:liveSlots[i].CGRectValue fromView:self];
    _liveSlots[i] = CGRectOffset(r, -_m.barFrame.origin.x, -_m.barFrame.origin.y);
  }
  _m.primaryCount = MAX(0, _m.slotCount - 1);
  _m.overflowCount = (int)self.overflow.count;
  _m.hasPillSize = pill.width > 1 && pill.height > 1;
  _m.pillSize = vertical ? CGSizeMake(pill.height, pill.width) : pill;
  _m.hasPillInset = pillInset > 0;
  _m.pillInset = pillInset;
  _m.anchorSelectedSlot = selectedSlot;
  _m.anchorOverflowSelected = overflowSelected;
  _m.maxMenuHeight = self.maxMenuHeight;

  CGFloat radius = mbo_thickness(&_m) / 2;
  _bar.glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:radius]];
  _handoffGlass.glass.cornerConfiguration = vertical ? [UICornerConfiguration capsuleConfigurationWithMaximumRadius:37]
                                                     : [UICornerConfiguration capsuleConfiguration];
  _menuClip.layer.cornerRadius = radius;

  CGRect lensInBar = CGRectZero;
  if (hasLens) {
    CGRect r = [_canvas convertRect:lens fromView:self];
    lensInBar = CGRectOffset(r, -_m.barFrame.origin.x, -_m.barFrame.origin.y);
  } else {
    lift = 0;
  }
  BOOL wasMorphing = _m.isMorphing;
  CFTimeInterval now = CACurrentMediaTime();
  CGPoint canvasPoint = hasPoint ? [self canvasPoint:point] : CGPointZero;
  // (the state opens with the glass at the bar's own size; the views follow below, in one transaction)
  BOOL hasLive = _liveCount > 0 && !CGRectIsNull(livePlatter) && !CGRectIsEmpty(livePlatter);
  CGRect liveInCanvas = hasLive ? [_canvas convertRect:livePlatter fromView:self] : CGRectZero;
  mbo_open_live(&_m, tracking, hasPoint, canvasPoint, hasLens, lensInBar, lift, hasLive ? liveInCanvas.size.height : thickness, hasLive, liveInCanvas, now);

  self.hidden = NO;
  self.userInteractionEnabled = YES;
  self.accessibilityViewIsModal = YES;
  _menuRows.hidden = YES;
  if (!wasMorphing) [self setTabsImage:[self tabRowImageWithLens:hasLens lens:lensInBar lift:lift]];
  if (hasLens && lift > 0.05) {
    CGRect moreRect = _liveCount ? _liveSlots[_m.primaryCount] : mbo_slot(&_m, _m.primaryCount);
    CGFloat zoom = 1 + 0.18 * lift;
    UIImage *img = self.overflowGlyph ? self.overflowGlyph(zoom, self.canvasAngle) : nil;
    _handoffGlyph.image = img;
    _handoffGlyph.bounds = CGRectMake(0, 0, img.size.width, img.size.height);
    _handoffGlyphOffset = self.handoffGlyphAtLens ? CGPointZero
                                                  : CGPointMake(CGRectGetMidX(moreRect) - CGRectGetMidX(lensInBar), CGRectGetMidY(moreRect) - CGRectGetMidY(lensInBar));
    _handoffGlyph.alpha = 1;
  } else {
    _handoffGlyph.image = nil;
    _handoffGlyph.alpha = 0;
    _handoffGlyphOffset = CGPointZero;
  }

  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self placeGlass];
  [self layoutGlassContent];
  [self applyShown];
  [_menuClip layoutIfNeeded];
  [CATransaction commit];

  _takenOver = !wasMorphing;
  if (self.onOpenChange) self.onOpenChange(YES);
  if (self.onVisibilityChange) self.onVisibilityChange(YES);
  [self tickHaptic];
  [self trackFor:0.1];
}

- (void)handleTrack:(int)what picked:(int)picked {
  if (what & MBOTrackTick) [self tickHaptic];
  if (what & MBOTrackPick) [self pickRow:picked];
  else if (what & MBOTrackClose) [self close];
}
- (void)beginTrackingAt:(CGPoint)point { [self handleTrack:mbo_begin_tracking(&_m, [self canvasPoint:point]) picked:-1]; }
- (void)updateTrackingAt:(CGPoint)point { [self handleTrack:mbo_update_tracking(&_m, [self canvasPoint:point]) picked:-1]; }
- (void)endTrackingAt:(CGPoint)point {
  int picked = -1;
  int what = mbo_end_tracking(&_m, [self canvasPoint:point], &picked);
  [self handleTrack:what picked:picked];
}
- (void)cancelTracking {
  if (!_m.isOpen) return;
  _m.isTracking = NO;
  [self close];
}

- (void)pickRow:(int)index {
  if (index < 0 || index >= (int)self.overflow.count) return;
  NSString *ident = self.overflow[index][@"id"];
  mbo_pick(&_m, index);
  // (the owner first: its overflow slot shows the place chosen before the closing picture of the tab row is drawn)
  if (self.onPick && [ident isKindOfClass:NSString.class]) self.onPick(ident);
  [self close];
}

- (void)close {
  if (!_m.isOpen) return;
  BOOL wasMorphing = _m.isMorphing;
  _menuRows.hidden = YES;
  self.accessibilityViewIsModal = NO;
  mbo_close(&_m, CACurrentMediaTime());
  if (self.onOpenChange) self.onOpenChange(NO);
  if (!wasMorphing) [self setTabsImage:[self tabRowImageWithLens:NO lens:CGRectZero lift:0]];
  [self layoutGlassContent];
  [self applyShown];
  [self trackFor:0.1];
}

- (void)dismissImmediately {
  if (!self.isActive) return;
  BOOL wasOpen = _m.isOpen;
  mbo_dismiss(&_m);
  _menuRows.hidden = YES;
  self.accessibilityViewIsModal = NO;
  if (wasOpen && self.onOpenChange) self.onOpenChange(NO);
  [_link invalidate];
  _link = nil;
  [self applyShown];
  _handoffGlyph.image = nil;
  [self setTabsImage:nil];
  if (self.onTabsShownChange) self.onTabsShownChange(1);
  self.hidden = YES;
  self.userInteractionEnabled = NO;
  if (self.onVisibilityChange) self.onVisibilityChange(NO);
}

// ---- the display link: only while the menu is open or morphing ----
- (void)trackFor:(CFTimeInterval)seconds {
  _trackUntil = MAX(_trackUntil, CACurrentMediaTime() + seconds);
  if (_link) return;
  MBOLinkTarget *target = [MBOLinkTarget new];
  target.menu = self;
  _link = [CADisplayLink displayLinkWithTarget:target selector:@selector(tick:)];
  _link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
  [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
  CFTimeInterval now = CACurrentMediaTime();
  if (_m.isMorphing) {
    // (the first frame after the menu took the bar's place shows it exactly as taken: the springs start from it)
    if (_takenOver) {
      _takenOver = NO;
      _m.lastMorphStep = now;
    }
    int step = mbo_step_morph(&_m, now);
    [self placeGlass];
    [_bar.contentView layoutIfNeeded];
    [self layoutGlassContent];
    if ((step & MBOStepTabsShown) && self.onTabsShownChange) self.onTabsShownChange(_m.tabsShown);
    if (step & MBOStepLandedOpen) {
      _menuRows.hidden = NO;
      [self setTabsImage:nil];
    }
    if (step & MBOStepLandedShut) {
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      [self applyShown];
      _handoffGlyph.image = nil;
      self.hidden = YES;
      self.userInteractionEnabled = NO;
      [CATransaction commit];
      [self setTabsImage:nil];
      if (self.onVisibilityChange) self.onVisibilityChange(NO);
      if (self.onDismiss) self.onDismiss();
    }
  } else if (_m.isOpen && !mbo_rows_settled(&_m, now)) {
    [self drawContents];
  }
  // (a finger held by an end of the rows' room: they scroll under it)
  CGFloat scrolled = _m.scroll;
  int moved = mbo_autoscroll(&_m, MIN(MAX(now - _lastScrollStep, 0), 0.05));
  _lastScrollStep = now;
  if (moved & MBOTrackTick) [self tickHaptic];
  if (_m.scroll != scrolled) [self layoutGlassContent];
  mbo_update_indicator(&_m, now);
  [self applyShown];
  if (now > _trackUntil && !_m.isMorphing && !_m.isOpen) {
    [_link invalidate];
    _link = nil;
  }
}
@end
#endif
