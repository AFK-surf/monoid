// The overflow menu the tab bar's last slot grows into (ios_nav_overflow.h): its numbers, springs, geometry, indicator
// and finger tracking, as pure C over CoreGraphics' rects so a macOS unit test steps it frame by frame
// (scripts/apple_grab_nav_test.m). No UIKit here: the view only draws what this says.
//
// All rects are in the menu's canvas: the bar lying along x with the menu growing toward smaller y, whatever way the
// bar stands on screen (the view turns the canvas for a bar down a side).
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>
#include <string.h>

// ---- metrics ----
static const CGFloat mbo_menu_row = 48;
static const CGFloat mbo_menu_padding = 8;
static const CGFloat mbo_side_menu_width = 224;
static const CGFloat mbo_glyph = 24;
// How far the outgoing and incoming contents blur while the bar turns into the menu and back.
static const CGFloat mbo_morph_blur = 12;
static const double mbo_morph_duration = 0.35;
static const CGFloat mbo_morph_bounce = 0.28;
// The major axis pulls in by this share at its peak as the menu opens, on a critically damped spring of its own.
static const CGFloat mbo_morph_squeeze = 0.20;
static const double mbo_squeeze_response = 0.50;
static const CGFloat mbo_close_squeeze = 0.18;
static const double mbo_squeeze_close_response = 0.36;
static const double mbo_close_duration = 0.28;
static const CGFloat mbo_close_damping = 0.94;
// Each row rises from this far below, overshoots a little and settles, one after another from the bottom.
static const CGFloat mbo_row_rise = 14;
static const double mbo_row_stagger = 0.032;
static const double mbo_row_delay = 0.045;
static const double mbo_row_spring_duration = 0.38;
static const double mbo_row_spring_bounce = 0.42;
static const double mbo_row_fade = 0.16;
// The indicator: how fast it follows the finger to a new row and fades, and by how far into the glass's growth a lens
// it starts from has turned grey.
static const double mbo_indicator_follow = 0.05;
static const double mbo_indicator_fade = 0.08;
static const CGFloat mbo_lens_to_grey = 0.35;
// How far a finger that opened the menu moves off the bar before picking rows.
static const CGFloat mbo_menu_reach = 20;
// How long a dragging finger rests on the last slot before the menu opens.
static const double mbo_menu_dwell = 0.3;
static const CGFloat mbo_dwell_slop = 8;
static const CGFloat mbo_row_icon_x = 14;
static const CGFloat mbo_row_label_x = 50;

#define MBO_MAX_SLOTS 16

static inline CGFloat mbo_clamp(CGFloat x, CGFloat lo, CGFloat hi) { return x < lo ? lo : (x > hi ? hi : x); }
static inline CGFloat mbo_smoothstep(CGFloat a, CGFloat b, CGFloat x) {
  CGFloat t = mbo_clamp((x - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
}
static inline CGRect mbo_lerp(CGRect a, CGRect b, CGFloat t) {
  return CGRectMake(a.origin.x + (b.origin.x - a.origin.x) * t, a.origin.y + (b.origin.y - a.origin.y) * t,
                    a.size.width + (b.size.width - a.size.width) * t, a.size.height + (b.size.height - a.size.height) * t);
}
// How the two contents cross as the glass grows (0 the bar, 1 the menu): the tab row leaves over the first 60 % and the
// rows arrive from 20 %, so the glass is never empty.
static inline CGFloat mbo_tabs_opacity(CGFloat p) { return 1 - mbo_smoothstep(0, 0.6, p); }
static inline CGFloat mbo_rows_opacity(CGFloat p) { return mbo_smoothstep(0.2, 0.9, p); }

// A rect kept by its distance from the glass's top, or from its bottom while the glass grows.
typedef struct {
  CGRect rect;
  bool fromBottom;
} MBOAnchored;
static inline MBOAnchored mbo_top(CGRect r) { return (MBOAnchored){r, false}; }
static inline MBOAnchored mbo_bottom(CGRect r, CGFloat height) {
  return (MBOAnchored){CGRectMake(r.origin.x, height - r.origin.y, r.size.width, r.size.height), true};
}
static inline CGRect mbo_resolve(MBOAnchored a, CGFloat height) {
  return a.fromBottom ? CGRectMake(a.rect.origin.x, height - a.rect.origin.y, a.rect.size.width, a.rect.size.height) : a.rect;
}

typedef struct {
  MBOAnchored from;
  CGFloat fromProgress;
  bool hasTo;
  MBOAnchored to;
  CGFloat toProgress;
  CGFloat startAlpha;
  bool fromGlass;
  bool closing;
  bool intoSelection;
} MBOLeg;

typedef struct {
  // -- the anchor: the native bar at rest, in the canvas --
  CGRect barFrame;
  CGRect slots[MBO_MAX_SLOTS];  // in barFrame's own room
  int slotCount;
  int primaryCount;  // the slots before the overflow slot
  int overflowCount;
  bool vertical;
  bool mirrored;
  bool hasPillSize;
  CGSize pillSize;
  bool hasPillInset;
  CGFloat pillInset;
  int anchorSelectedSlot;
  bool anchorOverflowSelected;
  int activeRow;  // the chosen place's row in the menu, -1 where it is not in it

  // -- what is going on --
  bool isOpen, isMorphing, isTracking;
  bool fingerInRows;
  bool hasOpenPoint;
  CGPoint openPoint;
  int hoveredRow, openRow, lastPickedRow;
  bool tabContentHidden;
  bool rowsLive;  // the rows take VoiceOver and touches (the morph landed open)

  // -- the morph's springs --
  CGFloat glassHeight, glassVelocity, glassTarget;
  CGFloat springStiffness, springDamping;
  double lastMorphStep;
  CGFloat glassSqueeze, glassSqueezeVelocity;
  CGFloat squeezeStiffness, squeezeDamping;
  CGFloat glassInset;
  // The pressed bar the menu took over from, where the system drew it larger than at rest (a side bar pressed is wider
  // and longer): how far its start (x), its length and its outer edge stood off the resting bar's, the progress the
  // glass started at, and how much of that shape is left (1 at the takeover, 0 once the tab row has left).
  CGFloat liveDX, liveDW, liveOuter, liveP0, liveShape;
  // More rows than the menu has room for (a bar down a side is as long as it is; across the foot the menu grows no
  // taller than `maxMenuHeight`, 0 for no limit): how far the rows are scrolled, and where the finger was last.
  CGFloat maxMenuHeight, scroll;
  CGPoint lastPoint;

  // -- the indicator --
  bool hasLeg;
  MBOLeg leg;
  bool hasTarget;
  CGRect target;
  CGFloat indicatorShown;
  double lastIndicatorStep;

  // -- what the view shows (written here, drawn there) --
  CGFloat pillAlpha;
  CGRect indicatorFitted;  // the indicator's frame in the squeezed glass
  CGFloat indicatorAlpha;
  CGFloat indicatorGrey;    // the grey fill over the lens it came from
  CGFloat indicatorNative;  // the native pill's fill crossed in as it lands on the slot
  bool handoffShown;
  CGRect handoffFrame;  // in the canvas
  CGFloat handoffAlpha;
  CGFloat handoffGlyphAlpha;
  CGFloat tabsShown;
  bool rowsClosing;
  double riseStart;
  bool visible;
} MBOverflow;

static inline void mbo_init(MBOverflow *m) {
  memset(m, 0, sizeof *m);
  m->activeRow = m->hoveredRow = m->openRow = m->lastPickedRow = -1;
  m->glassHeight = m->glassTarget = 62;
  m->tabsShown = 1;
  m->rowsClosing = true;
  m->indicatorGrey = 1;
}

static inline CGFloat mbo_thickness(const MBOverflow *m) { return fmax(m->barFrame.size.height, 44); }

static inline CGRect mbo_slot(const MBOverflow *m, int i);
// The menu's length along the bar. Across the foot the bar's; down a side its rows are stacked along the bar, so it is
// no longer than they are (fewer rows than the bar has room for leave no empty glass), at the overflow slot's end.
static inline CGFloat mbo_menu_length(const MBOverflow *m) {
  CGFloat bar = m->barFrame.size.width;
  return m->vertical ? fmin(bar, m->overflowCount * mbo_menu_row + mbo_menu_padding * 2) : bar;
}
static inline bool mbo_more_at_end(const MBOverflow *m) {
  return CGRectGetMidX(mbo_slot(m, m->primaryCount)) > m->barFrame.size.width / 2;
}
// The bar grown into the menu, anchored to its outer edge.
static inline CGRect mbo_menu_frame(const MBOverflow *m) {
  CGRect bar = m->barFrame;
  CGFloat height = m->vertical ? mbo_side_menu_width
                               : fmax(bar.size.height, m->overflowCount * mbo_menu_row + mbo_menu_padding * 2);
  if (!m->vertical && m->maxMenuHeight > 0) height = fmax(bar.size.height, fmin(height, m->maxMenuHeight));
  CGFloat length = mbo_menu_length(m);
  return CGRectMake(bar.origin.x + (mbo_more_at_end(m) ? bar.size.width - length : 0), CGRectGetMaxY(bar) - height, length, height);
}
// Where the menu's room starts along the bar, off the bar's start.
static inline CGFloat mbo_menu_start(const MBOverflow *m) { return mbo_menu_frame(m).origin.x - m->barFrame.origin.x; }
static inline CGFloat mbo_content_progress(const MBOverflow *m);
// How much shorter than the bar the glass is now, for a menu shorter than the bar: none while the tab row still shows
// (it is whole till then), all of it as the menu stands open.
static inline CGFloat mbo_shrink(const MBOverflow *m) {
  CGFloat less = m->barFrame.size.width - mbo_menu_length(m);
  return less > 0 ? less * mbo_smoothstep(0.6, 1, mbo_content_progress(m)) : 0;
}
// The glass's middle along the bar, off the resting bar's.
static inline CGFloat mbo_glass_mid_off(const MBOverflow *m) {
  CGFloat shrink = mbo_shrink(m);
  return (m->liveDX + m->liveDW / 2) * m->liveShape + (mbo_more_at_end(m) ? shrink / 2 : -shrink / 2);
}

// The glass's length along the bar before its squeeze: the bar's, and what is left of a pressed bar's extra.
static inline CGFloat mbo_glass_length(const MBOverflow *m) {
  return m->barFrame.size.width + m->liveDW * m->liveShape - mbo_shrink(m);
}
// The glass as it stands now, in the canvas.
static inline CGRect mbo_glass_bounds(const MBOverflow *m) {
  return CGRectMake(0, 0, mbo_glass_length(m) - m->glassInset * 2, m->glassHeight);
}
static inline CGPoint mbo_glass_center(const MBOverflow *m) {
  return CGPointMake(CGRectGetMidX(m->barFrame) + mbo_glass_mid_off(m),
                     CGRectGetMaxY(m->barFrame) + m->liveOuter * m->liveShape - m->glassHeight / 2);
}
// Where the glass's own room starts in the canvas, off the resting bar's start and outer edge.
static inline CGPoint mbo_glass_shift(const MBOverflow *m) {
  return CGPointMake(m->liveDX * m->liveShape + (mbo_more_at_end(m) ? mbo_shrink(m) : 0), m->liveOuter * m->liveShape);
}
// How far the squeezing glass has pulled in along the bar (1 at rest).
static inline CGFloat mbo_major_scale(const MBOverflow *m) {
  CGFloat w = mbo_glass_length(m);
  return w > 0 ? fmax((w - m->glassInset * 2) / w, 0.01) : 1;
}
static inline CGFloat mbo_progress(const MBOverflow *m) {
  CGFloat span = mbo_menu_frame(m).size.height - mbo_thickness(m);
  return span > 0 ? mbo_clamp((m->glassHeight - mbo_thickness(m)) / span, 0, 1) : 0;
}
// The progress the two contents cross by: the glass's own, counted from where it started when it took over from a
// pressed bar thicker than the resting one (the tab row is whole on the takeover frame).
static inline CGFloat mbo_content_progress(const MBOverflow *m) {
  CGFloat p = mbo_progress(m);
  return m->liveP0 > 0 && m->liveP0 < 1 ? mbo_clamp((p - m->liveP0) / (1 - m->liveP0), 0, 1) : p;
}

static inline CGRect mbo_slot(const MBOverflow *m, int i) {
  if (i < 0 || i >= m->slotCount)
    return CGRectMake(4, 4, fmax(44, m->barFrame.size.width - 8), fmax(36, mbo_thickness(m) - 8));
  return m->slots[i];
}

// The native selection pill at rest on slot `i`, in the bar's room: its measured size, the outer slots' flush to
// whichever end of the bar they sit at, so the closing morph lands on the native pill.
static inline CGRect mbo_resting_pill(const MBOverflow *m, int i) {
  CGRect slot = mbo_slot(m, i);
  CGFloat thick = mbo_thickness(m);
  CGFloat insetX = m->hasPillInset ? m->pillInset : (m->vertical ? 1.5 : (thick >= 54 ? 10.0 / 3.0 : 4));
  CGFloat insetY = m->vertical ? 2 : 4;
  CGFloat maxW = fmax(1, m->barFrame.size.width - insetX * 2);
  CGFloat maxH = fmax(1, thick - insetY * 2);
  CGSize size;
  if (m->hasPillSize && m->pillSize.width > 1 && m->pillSize.height > 1)
    size = CGSizeMake(fmin(m->pillSize.width, maxW), fmin(m->pillSize.height, maxH));
  else
    size = CGSizeMake(fmin(slot.size.width, maxW), fmin(slot.size.height, maxH));
  CGFloat minX = insetX;
  CGFloat maxX = fmax(insetX, m->barFrame.size.width - insetX - size.width);
  CGFloat x;
  if (i == 0 || i == m->primaryCount) x = CGRectGetMidX(slot) < m->barFrame.size.width / 2 ? minX : maxX;
  else x = fmin(fmax(CGRectGetMidX(slot) - size.width / 2, minX), maxX);
  return CGRectMake(x, (thick - size.height) / 2, size.width, size.height);
}

// The chosen slot's pill inside the squeezed glass's tab row.
static inline CGRect mbo_morph_pill(const MBOverflow *m) {
  CGRect rest = mbo_resting_pill(m, m->anchorSelectedSlot);
  CGFloat s = mbo_major_scale(m);
  return CGRectMake(rest.origin.x * s, rest.origin.y, rest.size.width * s, rest.size.height);
}

static inline void mbo_set_pill_alpha(MBOverflow *m, CGFloat a) { m->pillAlpha = mbo_clamp(a, 0, 1); }
static inline void mbo_set_indicator_alpha(MBOverflow *m, CGFloat a) { m->indicatorAlpha = mbo_clamp(a, 0, 1); }

// ---- rows ----
// The room the rows have along the way they are stacked, and how far they can be scrolled in it.
static inline CGFloat mbo_rows_room(const MBOverflow *m) {
  CGSize size = mbo_menu_frame(m).size;
  return (m->vertical ? size.width : size.height) - mbo_menu_padding * 2;
}
static inline CGFloat mbo_max_scroll(const MBOverflow *m) {
  return fmax(0, m->overflowCount * mbo_menu_row - mbo_rows_room(m));
}
// The rows scrolled so that row `i` is whole in the room.
static inline void mbo_scroll_to_row(MBOverflow *m, int i) {
  CGFloat top = i * mbo_menu_row, room = mbo_rows_room(m);
  if (top < m->scroll) m->scroll = top;
  if (top + mbo_menu_row > m->scroll + room) m->scroll = top + mbo_menu_row - room;
  m->scroll = mbo_clamp(m->scroll, 0, mbo_max_scroll(m));
}
static inline CGRect mbo_row_frame(const MBOverflow *m, int i) {
  CGSize size = mbo_menu_frame(m).size;
  CGFloat pad = mbo_menu_padding, row = mbo_menu_row;
  if (!m->vertical) return CGRectMake(pad, pad + i * row - m->scroll, size.width - pad * 2, row);
  CGFloat along = m->mirrored ? size.width - pad - row * (i + 1) + m->scroll : pad + row * i - m->scroll;
  return CGRectMake(along, pad, row, size.height - pad * 2);
}

// Row `i` in the resting bar's room (the indicator's: it comes from the tab row's pill or lens).
static inline CGRect mbo_row_in_bar(const MBOverflow *m, int i) { return CGRectOffset(mbo_row_frame(m, i), mbo_menu_start(m), 0); }

// The row under a point of the canvas, -1 off the menu.
static inline int mbo_row_at(const MBOverflow *m, CGPoint p) {
  if (m->overflowCount <= 0) return -1;
  CGRect frame = mbo_menu_frame(m);
  if (!CGRectContainsPoint(CGRectInset(frame, m->vertical ? 0 : -24, m->vertical ? -24 : 0), p)) return -1;
  CGFloat along;
  if (m->vertical) {
    CGFloat x = p.x - frame.origin.x;
    along = m->mirrored ? frame.size.width - mbo_menu_padding - x : x - mbo_menu_padding;
  } else {
    along = p.y - frame.origin.y - mbo_menu_padding;
  }
  along += m->scroll;
  int r = (int)floor(along / mbo_menu_row);
  return r < 0 ? 0 : (r > m->overflowCount - 1 ? m->overflowCount - 1 : r);
}

// How far row `i` has come in at `now` (0 gone, 1 here): an ease-out of its own after its turn's delay, the last row
// first.
static inline double mbo_ease_out(double t) {
  // cubic-bezier(0, 0, 0.58, 1): x(u) = 3(1-u)u²·0.58 + u³, y(u) = 3(1-u)u² + u³
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  double u = t;
  for (int k = 0; k < 8; k++) {
    double x = 3 * (1 - u) * u * u * 0.58 + u * u * u - t;
    double dx = 3 * 0.58 * (2 * u - 3 * u * u) + 3 * u * u;
    if (fabs(dx) < 1e-9) break;
    u = u - x / dx;
    if (u < 0) u = 0;
    if (u > 1) u = 1;
  }
  return 3 * (1 - u) * u * u + u * u * u;
}
static inline double mbo_row_wait(const MBOverflow *m, int i) {
  int order = m->overflowCount - 1 - i;
  return mbo_row_delay + mbo_row_stagger * order;
}
static inline double mbo_row_shown(const MBOverflow *m, int i, double now) {
  return mbo_ease_out((now - m->riseStart - mbo_row_wait(m, i)) / mbo_row_fade);
}
// How far below its place row `i` still is at `now`: a spring of 0.38 s that bounces by 0.42 (mass 1, stiffness
// (2π/duration)², damping ratio 1 - bounce), from mbo_row_rise to 0.
static inline CGFloat mbo_row_rise_at(const MBOverflow *m, int i, double now) {
  double t = now - m->riseStart - mbo_row_wait(m, i);
  if (t <= 0) return mbo_row_rise;
  double omega = 2 * M_PI / mbo_row_spring_duration;
  double zeta = 1 - mbo_row_spring_bounce;
  double wd = omega * sqrt(1 - zeta * zeta);
  double left = exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t));
  return mbo_row_rise * left;
}
// Whether every row has come in and settled (nothing left to draw each frame for them).
static inline bool mbo_rows_settled(const MBOverflow *m, double now) {
  double t = now - m->riseStart - mbo_row_wait(m, 0);
  double omega = 2 * M_PI / mbo_row_spring_duration;
  return t > mbo_row_fade && mbo_row_rise * exp(-(1 - mbo_row_spring_bounce) * omega * t) < 0.01;
}

// ---- the indicator ----
// The indicator's frame in the unsqueezed glass.
static inline CGRect mbo_indicator_frame(const MBOverflow *m) {
  CGFloat s = mbo_major_scale(m);
  CGPoint shift = mbo_glass_shift(m);
  CGRect f = m->indicatorFitted;
  return CGRectMake(f.origin.x / s + shift.x, f.origin.y + shift.y, f.size.width / s, f.size.height);
}
static inline int mbo_indicator_row(const MBOverflow *m) {
  if (!m->isOpen) return -1;
  if (m->isTracking && m->fingerInRows) return m->hoveredRow;
  if (m->hoveredRow >= 0) return m->hoveredRow;
  if (m->openRow >= 0) return m->openRow;
  return m->activeRow;
}

static inline void mbo_hide_handoff(MBOverflow *m) {
  m->handoffAlpha = 0;
  m->handoffGlyphAlpha = 0;
  m->handoffShown = false;
}

static inline void mbo_update_indicator(MBOverflow *m, double now) {
  double dt = fmin(fmax(now - m->lastIndicatorStep, 0), 0.05);
  m->lastIndicatorStep = now;
  CGFloat height = m->glassHeight;
  CGFloat progress = mbo_progress(m);
  int row = mbo_indicator_row(m);
  if (row >= 0) {
    CGRect want = mbo_bottom(mbo_row_in_bar(m, row), mbo_menu_frame(m).size.height).rect;
    CGFloat ease = 1 - exp(-dt / mbo_indicator_follow);
    m->target = m->hasTarget ? mbo_lerp(m->target, want, ease) : want;
    m->hasTarget = true;
  }
  CGRect target = CGRectZero;
  if (m->hasTarget) target = mbo_resolve((MBOAnchored){m->target, true}, height);
  if (!(m->isOpen || (m->hasLeg && m->leg.closing))) return;

  CGRect frame = mbo_indicator_frame(m);
  CGFloat alpha, grey = 1, glassAlpha = 0, nativeBlend = 0;
  if (m->hasLeg) {
    MBOLeg leg = m->leg;
    CGFloat span = leg.toProgress - leg.fromProgress;
    CGFloat t = span == 0 ? 1 : mbo_clamp((progress - leg.fromProgress) / span, 0, 1);
    CGRect start = mbo_resolve(leg.from, height);
    CGRect end = leg.hasTo ? mbo_resolve(leg.to, height) : (m->hasTarget ? target : start);
    frame = mbo_lerp(start, end, t);
    if (leg.closing) {
      if (leg.intoSelection) {
        // Eases to full alpha and crosses into the native pill's fill before it lands on the slot, so handing back to
        // the system's bar jumps neither in light nor in blur.
        alpha = leg.startAlpha + (1 - leg.startAlpha) * mbo_smoothstep(0, 0.45, t);
        nativeBlend = mbo_smoothstep(0.35, 0.85, t);
      } else {
        alpha = leg.startAlpha * fmin(1, (1 - t) * 1.5);
      }
    } else {
      m->indicatorShown += ((row < 0 ? 0 : 1) - m->indicatorShown) * (1 - exp(-dt / mbo_indicator_fade));
      alpha = leg.startAlpha + (m->indicatorShown - leg.startAlpha) * t;
      if (leg.fromGlass) {
        grey = mbo_smoothstep(0, mbo_lens_to_grey, t);
        glassAlpha = 1 - grey;
      } else if (m->anchorOverflowSelected) {
        nativeBlend = 1 - mbo_smoothstep(0, 0.45, t);
      }
    }
  } else {
    if (m->hasTarget) frame = target;
    m->indicatorShown += ((row < 0 ? 0 : 1) - m->indicatorShown) * (1 - exp(-dt / mbo_indicator_fade));
    alpha = m->indicatorShown * mbo_rows_opacity(progress);
  }
  CGFloat scaleX = mbo_major_scale(m);
  CGPoint shift = mbo_glass_shift(m);
  // (the frame is in the resting bar's room: the glass's own starts `shift` off it while a pressed bar's shape is left)
  CGRect fitted = CGRectMake((frame.origin.x - shift.x) * scaleX, frame.origin.y - shift.y, frame.size.width * scaleX, frame.size.height);
  m->indicatorFitted = fitted;
  m->indicatorGrey = grey;
  m->indicatorNative = mbo_clamp(nativeBlend, 0, 1);
  CGFloat clampedGlass = mbo_clamp(glassAlpha * alpha, 0, 1);
  if (clampedGlass > 0.01) {
    m->handoffFrame = CGRectOffset(fitted, m->barFrame.origin.x + shift.x + m->glassInset, CGRectGetMaxY(m->barFrame) + shift.y - m->glassHeight);
    m->handoffGlyphAlpha = m->tabsShown * clampedGlass;
    m->handoffAlpha = clampedGlass;
    m->handoffShown = true;
  } else {
    mbo_hide_handoff(m);
  }
  mbo_set_indicator_alpha(m, alpha);
}

// `lens`: the native selection lens lifted under the finger as the menu takes over (in the bar's room), `lift` 0...1.
static inline void mbo_start_indicator(MBOverflow *m, bool tracking, bool hasLens, CGRect lens, CGFloat lift, double now) {
  CGFloat height = m->glassHeight;
  CGFloat offY = height - mbo_thickness(m);
  CGFloat progress = mbo_progress(m);
  if (!hasLens) lift = 0;
  m->lastPickedRow = -1;
  m->openRow = tracking && lift > 0.05 ? (m->activeRow >= 0 ? m->activeRow : m->overflowCount - 1) : -1;
  m->hasTarget = false;
  MBOLeg leg = {0};
  leg.toProgress = 1;
  leg.fromProgress = progress;
  if (m->indicatorAlpha > 0.01 && m->hasLeg) {
    leg.from = mbo_bottom(mbo_indicator_frame(m), height);
    leg.startAlpha = m->indicatorAlpha;
    m->leg = leg;
    m->hasLeg = true;
  } else if (hasLens && lift > 0.05) {
    leg.from = mbo_bottom(CGRectOffset(lens, 0, offY), height);
    leg.startAlpha = 1;
    leg.fromGlass = true;
    m->leg = leg;
    m->hasLeg = true;
    mbo_set_pill_alpha(m, 0);
  } else if (m->anchorOverflowSelected) {
    leg.from = mbo_bottom(CGRectOffset(mbo_resting_pill(m, m->primaryCount), 0, offY), height);
    leg.startAlpha = 1;
    m->leg = leg;
    m->hasLeg = true;
    mbo_set_pill_alpha(m, 0);
  } else {
    m->hasLeg = false;
  }
  m->indicatorShown = m->hasLeg ? 1 : 0;
  m->lastIndicatorStep = now;
  mbo_update_indicator(m, now);
}

static inline void mbo_end_indicator(MBOverflow *m) {
  CGFloat progress = mbo_progress(m);
  CGFloat height = m->glassHeight;
  if (!(progress > 0.01)) {
    mbo_set_indicator_alpha(m, 0);
    mbo_hide_handoff(m);
    m->hasLeg = false;
    return;
  }
  if (m->anchorOverflowSelected) {
    CGRect fromRect;
    CGFloat startAlpha;
    CGRect restInGlass = CGRectOffset(mbo_resting_pill(m, m->primaryCount), 0, height - mbo_thickness(m));
    int row = m->lastPickedRow >= 0 ? m->lastPickedRow : (m->hoveredRow >= 0 ? m->hoveredRow : m->activeRow);
    if (m->indicatorAlpha > 0.05) {
      fromRect = mbo_indicator_frame(m);
      startAlpha = m->indicatorAlpha;
    } else if (row >= 0) {
      fromRect = mbo_resolve(mbo_bottom(mbo_row_in_bar(m, row), mbo_menu_frame(m).size.height), height);
      startAlpha = 0;
    } else {
      fromRect = restInGlass;
      startAlpha = 0;
    }
    MBOLeg leg = {0};
    leg.from = mbo_bottom(fromRect, height);
    leg.fromProgress = progress;
    leg.hasTo = true;
    leg.to = mbo_bottom(restInGlass, height);
    leg.toProgress = 0;
    leg.startAlpha = startAlpha;
    leg.closing = true;
    leg.intoSelection = true;
    m->leg = leg;
    m->hasLeg = true;
    return;
  }
  if (!(m->indicatorAlpha > 0.01)) {
    mbo_set_indicator_alpha(m, 0);
    mbo_hide_handoff(m);
    m->hasLeg = false;
    return;
  }
  MBOLeg leg = {0};
  leg.from = mbo_top(mbo_indicator_frame(m));
  leg.fromProgress = progress;
  leg.hasTo = true;
  leg.to = leg.from;
  leg.toProgress = 0;
  leg.startAlpha = m->indicatorAlpha;
  leg.closing = true;
  m->leg = leg;
  m->hasLeg = true;
}

// ---- the morph ----
// The opening squeeze: an impulse on a critically damped spring that peaks at mbo_morph_squeeze and eases back with no
// overshoot.
static inline void mbo_start_opening_squeeze(MBOverflow *m) {
  CGFloat omega = 2 * M_PI / mbo_squeeze_response;
  m->squeezeStiffness = omega * omega;
  m->squeezeDamping = 2 * omega;
  m->glassSqueezeVelocity = mbo_morph_squeeze * omega * exp(1);
}
static inline void mbo_start_closing_squeeze(MBOverflow *m) {
  CGFloat omega = 2 * M_PI / mbo_squeeze_close_response;
  m->squeezeStiffness = omega * omega;
  m->squeezeDamping = 2 * omega;
  CGFloat impulse = mbo_close_squeeze * omega * exp(1);
  CGFloat headroom = fmax(0, 1 - m->glassSqueeze / mbo_close_squeeze);
  m->glassSqueezeVelocity = fmax(m->glassSqueezeVelocity, impulse * headroom);
}
static inline void mbo_start_morph(MBOverflow *m, CGFloat height, double response, CGFloat ratio, double now) {
  m->glassTarget = height;
  m->springStiffness = pow(2 * M_PI / response, 2);
  m->springDamping = 2 * ratio * sqrt(m->springStiffness);
  if (!m->isMorphing) m->lastMorphStep = now;
  m->isMorphing = true;
}

// What the glass's new height means for what it holds. Says whether the tab row's visibility is to be told on.
static inline bool mbo_apply_glass_height(MBOverflow *m) {
  // (a pressed bar's shape leaves with the tab row, and never comes back as the glass folds)
  if (m->liveShape > 0) m->liveShape = fmin(m->liveShape, mbo_tabs_opacity(mbo_content_progress(m)));
  m->glassInset = mbo_glass_length(m) * fmax(m->glassSqueeze, 0) / 2;
  CGFloat rowShown = mbo_tabs_opacity(mbo_content_progress(m));
  bool told = false;
  if (fabs(m->tabsShown - rowShown) > 0.001 || (rowShown > 0.001 && m->glassInset > 0.05)) {
    m->tabsShown = rowShown;
    told = true;
  }
  CGFloat pillTarget = m->anchorOverflowSelected ? 0 : (m->isOpen ? fmin(m->pillAlpha, rowShown) : rowShown);
  mbo_set_pill_alpha(m, pillTarget);
  return told;
}

typedef enum {
  MBOStepNone = 0,
  MBOStepTabsShown = 1,   // the tab row's visibility changed: tell the owner
  MBOStepLandedOpen = 2,  // the morph settled open
  MBOStepLandedShut = 4,  // the morph settled shut: hide, hand back to the system's bar
} MBOStep;

static inline void mbo_finish_shut(MBOverflow *m) {
  mbo_set_pill_alpha(m, 0);
  mbo_set_indicator_alpha(m, 0);
  mbo_hide_handoff(m);
  m->visible = false;
  m->hasLeg = false;
  m->hasTarget = false;
  m->hoveredRow = m->openRow = m->lastPickedRow = -1;
  m->tabsShown = 1;
}

// One display frame of the morph: both springs stepped at 480 Hz over the time since the last, at most 50 ms.
static inline int mbo_step_morph(MBOverflow *m, double now) {
  if (!m->isMorphing) return MBOStepNone;
  double remaining = fmin(fmax(now - m->lastMorphStep, 0), 0.05);
  m->lastMorphStep = now;
  const double step = 1.0 / 480;
  while (remaining > 0) {
    CGFloat dt = fmin(step, remaining);
    CGFloat force = -m->springStiffness * (m->glassHeight - m->glassTarget) - m->springDamping * m->glassVelocity;
    m->glassVelocity += force * dt;
    m->glassHeight += m->glassVelocity * dt;
    if (m->squeezeStiffness > 0) {
      CGFloat sf = -m->squeezeStiffness * m->glassSqueeze - m->squeezeDamping * m->glassSqueezeVelocity;
      m->glassSqueezeVelocity += sf * dt;
      m->glassSqueeze += m->glassSqueezeVelocity * dt;
    }
    remaining -= dt;
  }
  bool heightSettled = fabs(m->glassHeight - m->glassTarget) < 0.2 && fabs(m->glassVelocity) < 2;
  bool squeezeSettled = fabs(m->glassSqueeze) < 0.003 && fabs(m->glassSqueezeVelocity) < 0.02;
  if (heightSettled) {
    m->glassHeight = m->glassTarget;
    m->glassVelocity = 0;
  }
  if (squeezeSettled) {
    m->glassSqueeze = 0;
    m->glassSqueezeVelocity = 0;
  }
  int out = mbo_apply_glass_height(m) ? MBOStepTabsShown : MBOStepNone;
  if (heightSettled && squeezeSettled) {
    m->isMorphing = false;
    if (m->isOpen) {
      m->tabContentHidden = true;
      m->rowsLive = true;
      out |= MBOStepLandedOpen;
    } else {
      mbo_finish_shut(m);
      m->liveShape = m->liveP0 = 0;
      out |= MBOStepLandedShut | MBOStepTabsShown;
    }
  }
  return out;
}

// ---- opening, closing ----
// Opens from the anchor already written into `m` (barFrame, slots, the pill's measures, the chosen slot). `point`: where
// the finger is, when one opened it and still holds; `lens`: the native lens under it. The owner ticks its selection
// haptic once.
// `live`: the pressed bar's own frame in the canvas where the menu takes over from it (a lifted lens), else none.
static inline void mbo_open_live(MBOverflow *m, bool tracking, bool hasPoint, CGPoint point, bool hasLens, CGRect lens,
                                 CGFloat lift, CGFloat initialThickness, bool hasLive, CGRect live, double now);
static inline void mbo_open(MBOverflow *m, bool tracking, bool hasPoint, CGPoint point, bool hasLens, CGRect lens,
                            CGFloat lift, CGFloat initialThickness, double now) {
  mbo_open_live(m, tracking, hasPoint, point, hasLens, lens, lift, initialThickness, false, CGRectZero, now);
}
static inline void mbo_open_live(MBOverflow *m, bool tracking, bool hasPoint, CGPoint point, bool hasLens, CGRect lens,
                                 CGFloat lift, CGFloat initialThickness, bool hasLive, CGRect live, double now) {
  if (!m->isMorphing) {
    CGFloat start = fmax(mbo_thickness(m), initialThickness > 0 ? initialThickness : mbo_thickness(m));
    m->glassHeight = start;
    m->glassTarget = start;
    m->glassVelocity = 0;
    m->glassSqueeze = 0;
    m->glassSqueezeVelocity = 0;
    m->glassInset = 0;
    m->liveDX = m->liveDW = m->liveOuter = m->liveP0 = m->liveShape = 0;
    if (hasLive && hasLens && lift > 0.05) {
      m->liveDX = live.origin.x - m->barFrame.origin.x;
      m->liveDW = live.size.width - m->barFrame.size.width;
      m->liveOuter = CGRectGetMaxY(live) - CGRectGetMaxY(m->barFrame);
      m->liveP0 = mbo_progress(m);
      m->liveShape = 1;
    }
  }
  if (!hasLens) lift = 0;
  m->isOpen = true;
  m->isTracking = tracking;
  m->fingerInRows = false;
  m->hasOpenPoint = tracking && hasPoint;
  m->openPoint = point;
  m->hoveredRow = -1;
  m->visible = true;
  m->rowsLive = false;
  if (!m->anchorOverflowSelected && lift <= 0.05) mbo_set_pill_alpha(m, 1);
  else mbo_set_pill_alpha(m, 0);
  m->tabContentHidden = m->anchorOverflowSelected || lift > 0.05;
  // (the rows start where the row the menu rests on shows: the one a dragging finger opens it over, else the chosen
  // place's, else the first)
  m->scroll = 0;
  mbo_scroll_to_row(m, tracking && lift > 0.05 ? (m->activeRow >= 0 ? m->activeRow : m->overflowCount - 1) : (m->activeRow >= 0 ? m->activeRow : 0));
  mbo_start_indicator(m, tracking, hasLens, lens, lift, now);
  mbo_start_opening_squeeze(m);
  mbo_start_morph(m, mbo_menu_frame(m).size.height, mbo_morph_duration, 1 - mbo_morph_bounce, now);
  m->rowsClosing = false;
  m->riseStart = now;
}

static inline void mbo_close(MBOverflow *m, double now) {
  if (!m->isOpen) return;
  m->isOpen = false;
  m->isTracking = false;
  m->hasOpenPoint = false;
  m->rowsLive = false;
  m->rowsClosing = true;
  mbo_end_indicator(m);
  if (!m->anchorOverflowSelected) m->tabContentHidden = false;
  mbo_start_closing_squeeze(m);
  mbo_start_morph(m, mbo_thickness(m), mbo_close_duration, mbo_close_damping, now);
}

static inline void mbo_dismiss(MBOverflow *m) {
  m->liveShape = 0;
  m->isOpen = false;
  m->isTracking = false;
  m->isMorphing = false;
  m->glassSqueeze = 0;
  m->glassSqueezeVelocity = 0;
  m->glassInset = 0;
  m->hasOpenPoint = false;
  m->rowsLive = false;
  m->rowsClosing = true;
  mbo_finish_shut(m);
}

// ---- the finger ----
typedef enum {
  MBOTrackNone = 0,
  MBOTrackTick = 1,   // one selection haptic
  MBOTrackPick = 2,   // the row in `*picked` was chosen: tell the owner, then mbo_close
  MBOTrackClose = 4,  // let go off the rows: mbo_close
} MBOTrack;

static inline int mbo_track_menu(MBOverflow *m, CGPoint p) {
  m->lastPoint = p;
  if (m->hasOpenPoint) {
    CGPoint start = m->openPoint;
    bool movedIntoMenu = start.y - p.y > mbo_menu_reach / 2 || (m->vertical && fabs(p.x - start.x) > mbo_menu_row / 2);
    if (!movedIntoMenu) return MBOTrackNone;
    m->hasOpenPoint = false;
    m->openRow = -1;
  }
  int row = mbo_row_at(m, p);
  if (row == m->hoveredRow) return MBOTrackNone;
  m->hoveredRow = row;
  if (row >= 0) {
    m->fingerInRows = true;
    return MBOTrackTick;
  }
  return MBOTrackNone;
}
// A finger held on the rows by an end of their room, with rows past that end: they scroll under it (300 points a
// second), and the row under it is the one it is on. Says MBOTrackTick when that row changed.
static inline int mbo_autoscroll(MBOverflow *m, double dt) {
  if (!m->isOpen || !m->isTracking || !m->fingerInRows || m->hasOpenPoint) return MBOTrackNone;
  CGFloat most = mbo_max_scroll(m);
  if (!(most > 0)) return MBOTrackNone;
  CGRect frame = mbo_menu_frame(m);
  CGFloat room = mbo_rows_room(m), at;
  if (m->vertical) {
    CGFloat x = m->lastPoint.x - frame.origin.x;
    at = m->mirrored ? frame.size.width - mbo_menu_padding - x : x - mbo_menu_padding;
  } else {
    at = m->lastPoint.y - frame.origin.y - mbo_menu_padding;
  }
  CGFloat was = m->scroll, edge = 28, speed = 300;
  if (at < edge) m->scroll -= speed * dt;
  else if (at > room - edge) m->scroll += speed * dt;
  m->scroll = mbo_clamp(m->scroll, 0, most);
  if (m->scroll == was) return MBOTrackNone;
  int row = mbo_row_at(m, m->lastPoint);
  if (row == m->hoveredRow) return MBOTrackNone;
  m->hoveredRow = row;
  return row >= 0 ? MBOTrackTick : MBOTrackNone;
}
static inline int mbo_begin_tracking(MBOverflow *m, CGPoint p) {
  if (!m->isOpen) return MBOTrackNone;
  m->isTracking = true;
  m->fingerInRows = false;
  m->hasOpenPoint = false;
  return mbo_track_menu(m, p);
}
static inline int mbo_update_tracking(MBOverflow *m, CGPoint p) {
  if (!m->isOpen || !m->isTracking) return MBOTrackNone;
  return mbo_track_menu(m, p);
}
static inline int mbo_end_tracking(MBOverflow *m, CGPoint p, int *picked) {
  if (!m->isOpen || !m->isTracking) return MBOTrackNone;
  m->isTracking = false;
  if (m->hasOpenPoint) {
    m->hasOpenPoint = false;
    m->openRow = -1;
    return MBOTrackNone;
  }
  int row = mbo_row_at(m, p);
  if (row >= 0) {
    *picked = row;
    return MBOTrackPick;
  }
  return MBOTrackClose;
}
// A row chosen (a finger let go on it, VoiceOver's activation): the overflow slot is the chosen one from here on.
static inline void mbo_pick(MBOverflow *m, int row) {
  m->lastPickedRow = row;
  m->activeRow = row;
  m->anchorSelectedSlot = m->primaryCount;
  m->anchorOverflowSelected = true;
}

// ---- the owner's side: the last slot's zone, the lens it lifts ----
// Whether a dragging finger is on the overflow slot's side of the bar (the slot and all past it, a little off the bar
// too), in the owner's view. `more`: the slot; `platter`: the bar at rest; `trailing`: a bar down the trailing side.
static inline bool mbo_on_more_zone(CGPoint p, CGRect more, CGRect platter, bool vertical, bool trailing, bool rtl) {
  if (CGRectIsEmpty(more)) return false;
  if (!vertical) {
    if (!(p.y >= CGRectGetMinY(platter) - 20)) return false;
    return rtl ? p.x <= CGRectGetMaxX(more) : p.x >= CGRectGetMinX(more);
  }
  bool withinPerp = trailing ? p.x >= CGRectGetMinX(platter) - 40 : p.x <= CGRectGetMaxX(platter) + 40;
  if (!withinPerp) return false;
  return p.y >= CGRectGetMinY(more);
}
// How far a lens of `lensMinor` across is lifted off a slot of `restMinor` at rest (0...1).
static inline CGFloat mbo_lens_lift(CGFloat lensMinor, CGFloat restMinor) {
  return restMinor > 0 ? mbo_clamp((lensMinor - restMinor - 0.5) / 14, 0, 1) : 0;
}
// How much larger a glyph `reach` from a lifted lens's middle is drawn (a lens `half` across each way).
static inline CGFloat mbo_lens_zoom(CGFloat reach, CGFloat half, CGFloat lift) {
  if (!(lift > 0.05) || !(half > 0) || !(reach < half)) return 1;
  CGFloat u = 1 - reach / half;
  return 1 + (0.18 * lift) * (u * u * (3 - 2 * u));
}
