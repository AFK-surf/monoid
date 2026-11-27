// Shared tokens and round-capped progress ring for compact corner badges overlaid on media thumbnails
// (chat image loading/download pills and video duration/download capsules).

///|
/// Media corner badge height: 24pt (radius 12pt), standing 14pt concentric inside a 26pt media card corner
/// (`@ui.capsule_in(26, 24) == 14`, within `corner_fit`'s [4, 16]) and giving 6pt concentric margin around a
/// 12pt leading ring or play mark on top, bottom, and left.
pub let media_badge_h : Double = 24.0

///|
/// Leading progress ring / play-mark box size inside a media corner badge: 12pt full-bleed so `(24 - 12) / 2 = 6pt`
/// places the ring's center at `(12, 12)`, strictly concentric with the capsule's left 12pt semicircle.
pub let media_badge_ring : Double = 12.0

///|
/// Progress ring and spinner stroke weight inside a media corner badge.
pub let media_badge_stroke : Double = 1.6

///|
/// Uniform translucent track colour for media badge progress rings and indeterminate spinners (~27% white).
pub let media_badge_track : Int64 = 0xFFFFFF45L

///|
/// Optical horizontal insets of a media corner badge: 6pt before the 12pt leading mark (concentric with the
/// left 12pt semicircle) and 7pt after the trailing numerals (+1pt optical compensation against the right curve,
/// staying within 1pt of the left inset).
pub let media_badge_pl : @ui.Space = S1_5

///|
pub let media_badge_pr : @ui.Space = room(7.0)

///|
/// +1pt optical right compensation carried by a media badge's words slot so an icon-only badge stays symmetric.
pub let media_badge_optical_pr : @ui.Space = room(1.0)

///|
/// Horizontal padding `(pl, pr)` keeping the 12pt leading ring concentric with the left semicircle at any
/// pill height `h >= media_badge_h` (e.g. under large system font scales >= 1.6x).
pub fn media_badge_pad_for(h : Double) -> (@ui.Space, @ui.Space) {
  let pl = (h - media_badge_ring) / 2.0
  (room(pl), room(pl + 1.0))
}

///|
/// Media corner badge typography: Caption size, Medium (500) weight for crisp white-on-scrim legibility,
/// single-line, tabular numerals so percentages and timestamps never jitter horizontally.
// kept across runs: a value (no field of it changes)
pub let media_badge_words : @ui.TextStyle = @ui.text_style(
  size=Caption,
  weight=Medium,
  color=white_ink,
  wrap=false,
  tabular=true,
)

///|
/// Crisp round-capped progress ring for compact dark media badges (`media_badge_ring` = 12pt full-bleed, `1.6pt`
/// stroke): draws the translucent track as a smooth GPU SDF circle border (zero `@ui.line` segment-join beading)
/// and the opaque white progress arc as a round-capped `@ui.line` starting at 12 o'clock clockwise, easing updates
/// smoothly over `@motion.progress_ms` while settling the initial share immediately.
#callsite(autofill(loc))
pub fn media_ring_node(
  parent : @view.View,
  part : () -> Double,
  label? : () -> String = fn() { "" },
  loc~ : SourceLoc,
) -> @view.View {
  let size = media_badge_ring
  let stroke = media_badge_stroke
  let ring = SpinRing::new(size, stroke)
  let first = spin_part(@signals.untracked(part))
  let at = @motion.NodeWay::new(first)
  @headless.progress(
    parent,
    fn() { Some(spin_part(part())) },
    fn(v, _p) {
      v
      .width(Is(Some(size)))
      .height(Is(Some(size)))
      .radius(Is(size / 2.0))
      .edge(Is((stroke, media_badge_track)))
      .lines(By(fn() {
        let shown = spin_part(at.shown(v))
        if shown > 0.0 {
          let arc = @ui.arc(ring.mid, ring.mid, ring.r, from=-0.5 * spin_pi, sweep=shown * 2.0 * spin_pi)
          [@ui.line(arc, width=stroke, color=white)]
        } else {
          []
        }
      }))
      |> ignore
      v.reacts(part, fn(k) {
        at.go_ms(v, spin_part(k), @motion.progress_ms, ease=Out)
      })
    },
    min=0.0,
    max=1.0,
    label~,
    made_for=loc,
    loc~,
  )
}
