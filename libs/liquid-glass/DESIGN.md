# `ui.monoid · Liquid Glass` Design Specification

This specification defines the visual and architectural laws for `libs/liquid-glass` (32 components on `mbui`'s iOS 27 `@paint.Glass::liquid` optical model). Every component in `src/lg` and every exhibition page in `src/pages` must uphold all five laws.

---

## Law 1 — Strict Two-Layer Material Architecture

Liquid Glass is a **floating functional material**, never a wallpaper or a content container. The interface is strictly divided into two layers:

### 1. Content Layer (Zero `Glass::liquid`)
Carries information, lists, forms, badges, inspector panels, and any control placed *inside* a floating glass container (Sheet, Dialog, Popover, Menu, Toolbar, Card).

- **Material**: Calm, legible translucent or solid surface (`.ground(...)` + `0.5pt` hairline `.edge(...)` + restrained soft shadow). Never uses `.glass(Glass::liquid)`.
- **Components in this layer**:
  - Containers: `liquid_list_node`, `liquid_disclosure_node`, parameter/telemetry inspector panels (`OPTICAL PARAMETERS`, `ADAPTIVE LUMINANCE`, `CAPILLARY HYSTERESIS`).
  - Form & selection controls: `liquid_checkbox_node`, `liquid_radio_group_node`, `liquid_progress_bar_node`, `liquid_progress_ring_node`.
  - Semantic metadata: `liquid_badge_node`, `liquid_count_badge_node`.
  - Inner glass-surface actions: `liquid_button_node(..., flat=true)`, `liquid_control_item_node`, dialog/sheet/menu/action-sheet rows and close buttons.
- **Why**: Keeps text razor-sharp, hierarchy calm, and guarantees that placing badges, checkboxes, or buttons inside lists, toolbars, or sheets never causes double-refraction muddiness.

### 2. Floating Liquid Glass Layer (Single-Layer `Glass::liquid`)
Floats *above* the Content Layer and backdrop wallpaper to refract real colour fields and calibration lines underneath.

- **Material**: Single-layer `@paint.Glass::liquid` with high-contrast opaque `solid` fallback.
- **Components in this layer**:
  - Navigation & floating chrome: `liquid_nav_bar_node` (transparent layout bar hosting floating glass islands in `leading`/`trailing`, or `glass=true` only when strictly free of glass children), `liquid_toolbar_node`, `liquid_bottom_tabs_node`.
  - Standalone controls: `liquid_button_node` (`flat=false`), `liquid_icon_button_node`, `liquid_button_group_node`, `liquid_segmented_node`, `liquid_stepper_node`, `liquid_chip_node`, `liquid_text_field_node`, `liquid_search_bar_node`, `liquid_toggle_node` (lens on press), `liquid_slider_node` (lens on press).
  - Anchored & modal overlays: `liquid_menu_node`, `liquid_select_node`, `liquid_popover_node`, `liquid_tooltip_node`, `liquid_sheet_node`, `liquid_action_sheet_node`, `liquid_dialog_node`, `liquid_toast_node`.
  - Optical physics & deck specimens: `liquid_card_node`, `liquid_control_tile_node`, `liquid_adaptive_surface_node`, `liquid_magnifier_node`, `liquid_progressive_blur_node`, `liquid_merge_node`.

---

## Law 2 — Hard Zero Glass-on-Glass Invariant

At rest (non-dragged steady state), no two drawn `Glass::liquid` (`kind == 6`) rectangles may overlap or nest (`overlap_area > 1.0 pt²`):

- **Allowed exceptions**:
  1. **Transient modal/anchored overlays** (`Sheet`, `Dialog`, `ActionSheet`, `Menu`, `Popover`, `Tooltip`) floating temporarily above the underlying scene — **provided that zero child `Glass::liquid` rectangles exist inside the overlay panel itself**.
  2. **Intentional capillary fusion pairs** (`LiquidMerge` bonded droplet + capsule, which share a smooth-min merge pass).
  3. **Active press/drag loupe transitions** (`p > 0.001` while a finger holds `liquid_segmented_node` or `liquid_bottom_tabs_node`).
- **Enforcement**: Automated `assert_no_nested_glass(t, ctx)` gate over `Tester::drawn_glass()` in both `src/lg/kit_overlays_wbtest.mbt` and `src/pages/gallery_wbtest.mbt`, covering all component tests and all 6 `library` exhibition categories in both Light and Dark themes, plus open modal/anchored overlay interiors.

---

## Law 3 — Concentric Corner Ladder

Every nested rounded surface obeys exact concentric geometry:

```
R_inner = R_outer - pad
```

- Examples: `Menu` (`r=22, pad=6 -> item r=16`), `List` (`r=24, pad=6 -> row r=18`), `Disclosure` (`r=22, pad=6 -> header r=16`), `ActionSheet` (`r=28, pad=8 -> item r=20`), `Sheet` (`r=36, inset=20 -> close r=16`), `SegmentedControl` (`r=h/2, pad=3 -> thumb r=h/2-3`).
- **Enforcement**: `mbui` `Tester::audit()` (`corners.mbt`) must report **0 faults** across light and dark themes.

---

## Law 4 — Optical Restraint & Contrast

- **Contrast**: All foreground text and icons maintain **WCAG >= 4.5:1** contrast against both the glass `solid` fallback and Content Layer surfaces in Light and Dark modes (verified by `Tester::audit()`).
- **Zero hidden glass instances at rest**: Controls that reveal a clear refraction loupe only while pressed/dragged (`liquid_segmented_node`, `liquid_bottom_tabs_node`, `liquid_toggle_node`, `liquid_slider_node`) must return `None` from `.glass(...)` whenever `p <= 0.001`, submitting `Some(...)` only during active interaction. Never submit `alpha == 0` glass passes to the GPU.
- **No `outside=false` shadows under glass**: Shadows beneath `Glass::liquid` render outside the SDF contour so they never darken the refracted interior.

---

## Law 5 — Closed-Form Motion & `@headless` Semantics

- **Closed-form springs**: All motion (`DampedDrag`, `InteractiveHighlight`, `@motion.NodeWay`, `@motion.overlay_presence`, `@motion.hover_fade`) is computed purely from cause moment and elapsed time — never frame counters or tick loops — guaranteeing byte-identical trajectories at **60, 120, 24, and 7 fps**.
- **Headless semantics**: Every interactive component is built on `libs/mbui/src/headless` (`button`, `toggle`, `slider`, `radio_group`, `dialog`, `Popover`, `menu`, `disclosure`, `progress`, `TextField`). Touch/drag interactions use `View::gesture`, never `on_drag` on headless nodes.
