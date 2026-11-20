# mbui Motion Library (`libs/mbui/src/motion`)

Causal, closed-form, FPS-invariant motion primitives and node-level tools for mbui.

## 1. Timing Curves (`@ui.Ease`)

| Curve | Parameters / Formula | Typical Use |
|---|---|---|
| `Move` | Critically damped spring with `@ui.move_ms(distance)` | Distance-adaptive layout/panel travel |
| `Out` | `cubic-bezier(0.2, 0.7, 0.2, 1.0)` | Entry, control hover/press response, fills |
| `Leave` | `cubic-bezier(0.4, 0.0, 1.0, 1.0)` | Exit fade/shrink, accelerating off-screen |
| `InOut` | `cubic-bezier(0.42, 0.0, 0.58, 1.0)` | Breathing loops, stroke drawing |
| `Linear` | `p -> p` | Rotation cycles, custom curve drivers |
| `Flight` | `cubic-bezier(0.6, 0.0, 0.2, 1.0)` | Sent-message flight to its row |

## 2. Semantic Spring Presets (`catalog.mbt`)

| Preset | Parameters | Behavior | Typical Use |
|---|---|---|---|
| `snappy_damped` | `ζ = 1.0, k = 420` | Critically damped (0 overshoot) | Hover handoff, discrete stops, toolbar indicator |
| `move_damped` | `visual = 0.28s, bounce = 0` | Critically damped | Segmented controls, tabs, regular displacement |
| `carousel_spring` | `visual = 0.32s, bounce = 0` | Critically damped | Carousels, horizontal media strips, sheets |
| `tactile_bounce` | `visual = 0.25s, bounce = 0.35` | Light bounce (`ζ = 0.65`) | Long-press lift, finger drag follow |
| `glass_lens_springs()` | `(press, scale_x, scale_y)` | Press + anisotropic lens bounce | Liquid glass switch/bar capsules |

Symmetric overlay presets: `dialog_out_ms` (`100 ms`), `dialog_out`, `tip_out_ms` (`100 ms`), `tip_out`.

Sampling helpers: `move_duration_ms(distance)`, `sample_ease(ease, steps)`, `sample_spec(spec, duration_ms, steps)`.

## 3. High-Frequency Node Tools (`tools.mbt`)

### `hover_fade`
```moonbit
let hover_p = @motion.hover_fade(node, fn() { node.pointed() }, duration_ms=140.0)
node.ground_over(By(fn() { with_alpha(hover_ink, hover_p()) })) |> ignore
```

### `flash_way`
```moonbit
let flash_p = @motion.flash_way(node, fn() { flash_seq.get() })
node.ground_over(By(fn() { with_alpha(accent_bg, flash_p()) })) |> ignore
```

### `breathe_alpha`
```moonbit
let alpha = @motion.breathe_alpha(node, period_ms=1400.0, low=0.5, resident=true)
node.alpha(By(alpha)) |> ignore
```

### `resident_cycle` / `resident_step`
```moonbit
let step = @motion.resident_step(node, 800.0, 8) // 0..7 at 10 Hz
```

### `indicator_rect`
```moonbit
let rect = @motion.indicator_rect(bar, fn() { active_rect.get() }, spec=@motion.snappy_damped)
bar.ground_drawn(By(fn() {
  match rect() {
    Some((x, y, w, h)) => { dx: x, dy: y, dw: w, dh: h, corners: None }
    None => @view.ground_as_laid
  }
})) |> ignore
```

### `overlay_presence`
```moonbit
let (look, modal_live) = @motion.overlay_presence(panel, enter=@motion.dialog_in, exit=@motion.dialog_out)
panel.modal(By(modal_live)).alpha(By(fn() { look().alpha })).scale(By(fn() { look().sx })) |> ignore
```

## 4. Core Primitives

- `NodeWay` / `Way`: closed-form causal value trajectories on a node's timeline.
- `ShakeWay`: horizontal refusal shake with `View::shakes_while` steadiness support.
- `HoldWay` (`hold_way`): safety hold confirmation progress (not shortened by reduced motion).
- `Handoff` / `HandPart`: continuous position + velocity handoff across sibling nodes.
- `PressFeel` (`press_feel`): unified hover + press sink feel.
- `SheetWay` / `PushWay`: gesture-coupled bottom sheet and edge-swipe push transitions.
- `Zoom`: pinch, pan, double-tap, and inertia fling state machine.
