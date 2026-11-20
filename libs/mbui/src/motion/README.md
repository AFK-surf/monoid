# mbui Motion Library (`libs/mbui/src/motion`)

Causal, closed-form, FPS-invariant motion primitives and node-level tools for mbui.
Zero app-specific dependencies: every primitive is pure geometry, physics, or timing usable by any mbui application.

---

## 1. Physics & Gesture Dynamics

Closed-form spring/curve drivers, rubber-band resistance, inertia projection, and drag-to-dismiss decisions.

### Timing Curves (`@ui.Ease`) & Semantic Spring Presets (`catalog.mbt`, `presets.mbt`)

| Name | Parameters / Formula | Typical Use |
|---|---|---|
| `Move` | Critically damped spring with `@ui.move_ms(distance)` | Distance-adaptive layout/panel travel |
| `Out` | `cubic-bezier(0.2, 0.7, 0.2, 1.0)` | Entry, control hover/press response, fills |
| `Leave` | `cubic-bezier(0.4, 0.0, 1.0, 1.0)` | Exit fade/shrink, accelerating off-screen |
| `InOut` | `cubic-bezier(0.42, 0.0, 0.58, 1.0)` | Breathing loops, stroke drawing |
| `Linear` | `p -> p` | Rotation cycles, custom curve drivers |
| `snappy_damped` | `ζ = 1.0, k = 420` | Critically damped (0 overshoot): hover handoff, discrete stops, toolbar indicator |
| `move_damped` | `visual = 0.28s, bounce = 0` | Critically damped: segmented controls, tabs, regular displacement |
| `carousel_spring` | `visual = 0.32s, bounce = 0` | Critically damped: carousels, horizontal media strips |
| `tactile_bounce` | `visual = 0.25s, bounce = 0.35` | Light bounce (`ζ = 0.65`): long-press lift, finger drag follow, over-pull snap-back |
| `digit_spring` | Critically damped digit roll spring | Odometer rolling character slots |
| `glass_lens_springs()` | `(press, scale_x, scale_y)` | Press + anisotropic lens bounce for liquid-glass capsules |

Sampling helpers: `move_duration_ms(distance)`, `sample_ease(ease, steps)`, `sample_spec(spec, duration_ms, steps)`.

### Core Trajectories & Gesture Primitives

- **`Way` / `NodeWay`** (`way.mbt`, `node_way.mbt`): closed-form causal value trajectories bound to a node's timeline.
- **`rubber_band` / `rubber_band_clamped` / `project_landing` / `snap_detent`** (`physics.mbt`): UIScrollView-style rubber-band resistance and deceleration projection.
- **`EdgePull` / `dismiss_drag_offset` / `should_dismiss`** (`pull.mbt`): hyperbolic boundary over-pull with spring return, asymmetric drag-to-dismiss mapping, and velocity-aware dismiss judgment.
- **`PressFeel` (`press_feel`) / `HoldWay` (`hold_way`) / `ShakeWay`** (`press.mbt`, `shake_way.mbt`): unified hover/press feel, safety hold confirmation, and horizontal refusal shake.
- **`Zoom`** (`zoom.mbt`): pinch, pan, double-tap, and inertia fling state machine.

```moonbit
// Over-pull boundary resistance
let pull = @motion.EdgePull::new(limit=6.0)
pull.drag(past, along, span)
pull.let_go(node) // springs back to 0.0 on tactile_bounce

// Drag-to-dismiss
let visual = @motion.dismiss_drag_offset(delta, viewport_h)
if @motion.should_dismiss(visual, velocity_per_s, 120.0) { /* close */ }
```

---

## 2. Deformation & Text Morphing

Velocity-driven capsule deformation, odometer character rolls, and cell-aligned glyph transitions.

- **`velocity_capsule` / `speed_stretch` / `SpringFollow2D`** (`deform.mbt`, `presets.mbt`): velocity-stretched capsule `GroundShape` and 2D spring follower that snaps on first engagement (never flying in from `(0, 0)`).
- **`rolling_chars` / `rolling_slots_node`** (`rolling.mbt`): right-aligned per-character odometer slots driven by `View::moved_by` (zero Flex relayout) with directional roll and soft edge fades.
- **`glyph_noise` / `glyph_in` / `glyph_change` / `TextMorph`** (`text_morph.mbt`): deterministic per-glyph arrival, non-overlapping crossfade, and cell-aligned single-line width/glyph morphing with mid-flight interruption continuity (`set_out`).

```moonbit
// 2D spring-following velocity-stretched capsule
let follow = @motion.SpringFollow2D::new()
follow.chase(node, tx, ty)
let shape = follow.capsule_shape(node, 124.0, 48.0, tx, ty)

// Odometer rolling slots
@motion.rolling_slots_node(parent, words, dir, style, ink)

// Single-line text morph
let morph = @motion.TextMorph::new(was_cells, now_cells, places, salt)
let width = morph.across(k, visible)
let look = morph.look(reveal, k, glyph_at, incoming)
```

---

## 3. Spatial Flight, Presence & Curtain Reveal

Aspect-preserving hero transitions, continuous handoffs, overlay presence, and zero-relayout curtain reveals.

- **`HeroThumb` / `HeroFlightBox` / `hero_seen_of` / `hero_flight_box`** (`hero_flight.mbt`): aspect-preserving hero rectangle flight with outer clip box, cover/letterbox fit, `start_crop`, clipped-edge lift (`dy`), and corner-radius interpolation to zero.
- **`reveal_node` / `curtain_reveal`** (`reveal_node.mbt`): height-expanding reveal box and multi-strip soft-edged curtain reveal driven by `NodeWay` + pixel-snapped `View::moved_by` (zero Flex relayout, auto-unmounts at rest).
- **`Handoff` / `HandPart`** (`handoff.mbt`): continuous position + velocity handoff across sibling nodes.
- **`hover_fade` / `hover_fade_keyed`** (`tools.mbt`): causal hover/active fade in `0..1` with optional key-reuse snap.
- **`flash_way` / `flash_way_keyed`** (`tools.mbt`): `in -> hold -> out` highlight pulse with reduced-motion solid hold.
- **`indicator_rect` / `cover_indicator`** (`tools.mbt`): zero-relayout animated selection indicator rect.
- **`overlay_presence`** (`tools.mbt`): symmetric enter/exit presence (`dialog_in`/`dialog_out`, `tip_in`/`tip_out`, `pop_in`/`pop_out`) with immediate modal release on exit.
- **`breathe_alpha` / `resident_cycle` / `resident_step`** (`tools.mbt`): ambient breathing and 10 Hz resident phase drivers.

```moonbit
// Hero rectangle flight
let box = @motion.hero_flight_box(thumb, dy, target_rect, progress, stage_w, stage_h)

// Soft-edged curtain reveal
@motion.curtain_reveal(parent, fn() { revealed.get() }, fn() { bg_color })
```

---

## 4. Multi-Track & Serial Choreography

Coordinated multi-track transitions and cross-source staggered scheduling.

- **`Choreography` / `TrackSpec`** (`choreography.mbt`): multi-track scene transition sharing one cause moment, reversing mid-flight from exact position and velocity, with lifecycle-bound `arm`.
- **`SerialQueue`** (`choreography.mbt`): staggered serial queue that lets consecutive same-source arrivals start immediately while queueing cross-source arrivals behind `tail_end - lead`.

```moonbit
// Staggered cross-source scheduling
let queue = @motion.SerialQueue::new()
let start = queue.next_at(source_id, now, lead=40.0)
queue.commit(source_id, start + duration_ms)
```
