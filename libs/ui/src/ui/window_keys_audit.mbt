// Framework-level window-controls clearance & alignment audit (Tester::window_keys_faults):
// verifies that when a window declares an inset window-controls overlay via `Tree::keeps_away`,
// no non-owner visible interactive control, glyph, icon, or hard top-bar edge collides with or
// drifts out of vertical alignment with the controls capsule.
//
// Rules:
// - K0: owner capsule's actual drawn rect matches `Tree::kept_away()` within 0.5 pt on all four sides
//       (and an explicitly registered `owner` must actually be drawn).
// - K1: no visible, unclipped, non-owner control, text, icon, or narrow pill overlaps the capsule
//       expanded 4.0 pt to the left `[kx - 4, kx + kw] x [ky, ky + kh]`.
// - K2: when `kept_away_band()` is true (Small dedicated top band), no non-owner visible control or
//       glyph enters `y < 2*ky + kh`; otherwise (Bar / Tape), every visible non-owner interactive
//       control of height 28..44 pt that sits inside the top bar band `[0, ky + kh + 6]` and
//       vertically overlaps `[ky, ky + kh]` has its vertical centerline within 1.0 pt of the capsule's.
// - K3: across `[kx, kx + kw]`, no visible non-owner horizontal hairline (`h <= 2`, including 0.5 pt
//       `rule_line`) intersecting `[kx, kx + kw]` or opaque bar fill (`composite alpha >= 0.75`)
//       spanning the capsule width has its bottom edge in `(ky, ky + kh + 3]`.

///|
priv struct WkFade {
  top : Double
  top_soft : Double
  foot : Double
  foot_soft : Double
  start : Double
  start_soft : Double
  end : Double
  end_soft : Double
}

///|
fn wk_fade_none() -> WkFade {
  { top: 0.0, top_soft: 0.0, foot: 0.0, foot_soft: 0.0, start: 0.0, start_soft: 0.0, end: 0.0, end_soft: 0.0 }
}

///|
/// Combine an ancestor fade rect with an accumulated `WkFade`, mirroring `inst_fade` / `inst_fade_across`.
fn wk_fade_apply(
  cur : WkFade,
  rect : (Double, Double, Double, Double),
  soft : (Double, Double, Double, Double),
) -> WkFade {
  let (x0, y0, x1, y1) = rect
  let (start_soft, top_soft, end_soft, foot_soft) = soft
  let (top, ts) = if top_soft > 0.0 && (cur.top_soft <= 0.0 || y0 + top_soft > cur.top + cur.top_soft) {
    (y0, top_soft)
  } else {
    (cur.top, cur.top_soft)
  }
  let (foot, fs) = if foot_soft > 0.0 && (cur.foot_soft <= 0.0 || y1 - foot_soft < cur.foot - cur.foot_soft) {
    (y1, foot_soft)
  } else {
    (cur.foot, cur.foot_soft)
  }
  let (start, ss) = if start_soft > 0.0 && (cur.start_soft <= 0.0 || x0 + start_soft > cur.start + cur.start_soft) {
    (x0, start_soft)
  } else {
    (cur.start, cur.start_soft)
  }
  let (end, es) = if end_soft > 0.0 && (cur.end_soft <= 0.0 || x1 - end_soft < cur.end - cur.end_soft) {
    (x1, end_soft)
  } else {
    (cur.end, cur.end_soft)
  }
  { top, top_soft: ts, foot, foot_soft: fs, start, start_soft: ss, end, end_soft: es }
}

///|
fn wk_fade_axis_min(
  lo : Double,
  hi : Double,
  a : Double,
  a_soft : Double,
  b : Double,
  b_soft : Double,
) -> Double {
  let at = fn(v : Double) -> Double {
    let f0 = if a_soft > 0.0 { dclamp((v - a) / a_soft, 0.0, 1.0) } else { 1.0 }
    let f1 = if b_soft > 0.0 { dclamp((b - v) / b_soft, 0.0, 1.0) } else { 1.0 }
    f0 * f1
  }
  dmin(at(lo), at(hi))
}

///|
/// Minimum shader `fade_r` attained by `fade` across the rectangle `[x0, x1] x [y0, y1]`.
fn wk_fade_min(fade : WkFade, x0 : Double, y0 : Double, x1 : Double, y1 : Double) -> Double {
  let fy = wk_fade_axis_min(y0, y1, fade.top, fade.top_soft, fade.foot, fade.foot_soft)
  let fx = wk_fade_axis_min(x0, x1, fade.start, fade.start_soft, fade.end, fade.end_soft)
  fy * fx
}

///|
fn wk_rect_hits(
  ax0 : Double,
  ay0 : Double,
  ax1 : Double,
  ay1 : Double,
  bx0 : Double,
  by0 : Double,
  bx1 : Double,
  by1 : Double,
) -> Bool {
  ax0 < bx1 - 0.25 && ax1 > bx0 + 0.25 && ay0 < by1 - 0.25 && ay1 > by0 + 0.25
}

///|
fn wk_clamp_box(
  d : @view.Drawn,
  bounds : (Double, Double, Double, Double),
  ww : Double,
  wh : Double,
  min_size : Double,
) -> (Double, Double, Double, Double)? {
  if d.alpha <= unseen_alpha || d.w <= 0.0 || d.h <= 0.0 || d.hosted {
    return None
  }
  let (bx0, by0, bx1, by1) = bounds
  let x0 = if d.x > bx0 { d.x } else { bx0 }
  let x0 = if x0 > 0.0 { x0 } else { 0.0 }
  let y0 = if d.y > by0 { d.y } else { by0 }
  let y0 = if y0 > 0.0 { y0 } else { 0.0 }
  let dx1 = d.x + d.w
  let x1 = if dx1 < bx1 { dx1 } else { bx1 }
  let x1 = if x1 < ww { x1 } else { ww }
  let dy1 = d.y + d.h
  let y1 = if dy1 < by1 { dy1 } else { by1 }
  let y1 = if y1 < wh { y1 } else { wh }
  if x1 - x0 <= min_size || y1 - y0 <= min_size {
    None
  } else {
    Some((x0, y0, x1, y1))
  }
}

///|
fn wk_drawn_box(
  tree : @view.Tree,
  d : @view.Drawn,
  ww : Double,
  wh : Double,
) -> (Double, Double, Double, Double)? {
  wk_clamp_box(d, tree.draw_clip_bounds(d.id), ww, wh, 0.0)
}

///|
fn wk_input_box(
  tree : @view.Tree,
  d : @view.Drawn,
  ww : Double,
  wh : Double,
) -> (Double, Double, Double, Double)? {
  wk_clamp_box(d, tree.input_bounds(d.id), ww, wh, 0.5)
}

///|
/// Audit window-controls clearance, alignment, and top-bar bottom-edge clearance against `Tree::kept_away()`.
/// Returns `[]` immediately when `Tree::kept_away()` is `None`.
pub fn Tester::window_keys_faults(self : Tester) -> Array[String] {
  self.reads_own()
  guard view_tree() is Some(tree) else { return [] }
  guard tree.kept_away() is Some((kx, ky, kw, kh)) else { return [] }
  let owner = tree.kept_away_owner()
  let is_band = tree.kept_away_band()
  let (tw, th) = @signals.untracked(fn() { tree.root().window() })
  let ww = if tw > 0.0 { tw } else { self.w }
  let wh = if th > 0.0 { th } else { self.h }
  let out : Array[String] = []
  let is_owner = fn(id : @view.NodeId) -> Bool {
    match owner {
      Some(oid) => tree.holds(oid, id)
      None => false
    }
  }
  // K0: contract consistency between kept_away() and owner's actual drawn rect.
  match owner {
    Some(oid) =>
      match tree.drawn_of(oid) {
        Some(od) =>
          if (od.x - kx).abs() > 0.5 ||
            (od.y - ky).abs() > 0.5 ||
            (od.w - kw).abs() > 0.5 ||
            (od.h - kh).abs() > 0.5 {
            out.push(
              "[WINDOW_KEYS_K0] kept_away (\{kx.round()},\{ky.round()} \{kw.round()}×\{kh.round()}) drifts from owner rect (\{od.x.round()},\{od.y.round()} \{od.w.round()}×\{od.h.round()})" +
              tree_source_said(oid),
            )
          }
        None =>
          out.push(
            "[WINDOW_KEYS_K0] kept_away (\{kx.round()},\{ky.round()} \{kw.round()}×\{kh.round()}) references an unmounted or undrawn owner node" +
            tree_source_said(oid),
          )
      }
    None => ()
  }
  let scales : Array[Double] = []
  let drawn : Array[@view.Drawn] = tree.drawn_held(scales~).map(fn(h) { h.0 })
  // Record draw-order index per node and collect non-owner opaque / top progressive scroll-edge occluders
  // using composite opacity (fill alpha * node alpha), paint clip bounds, and ancestor fade ramps.
  let draw_idx : Map[Int, Int] = Map([])
  let occluders : Array[(Int, @view.NodeId, Double, Double, Double, Double, Double, Double, WkFade)] = []
  let fading : Array[(@view.NodeId, (Double, Double, Double, Double), (Double, Double, Double, Double))] = []
  for i, d in drawn {
    draw_idx[d.id.at] = i
    while fading.length() > 0 && !tree.holds_in_order(fading[fading.length() - 1].0, d.id) {
      fading.pop() |> ignore
    }
    let mut node_fade = wk_fade_none()
    for f in fading {
      if !tree.drawn_clear_of(d.id, f.0) {
        node_fade = wk_fade_apply(node_fade, f.1, f.2)
      }
    }
    if !is_owner(d.id) {
      match wk_drawn_box(tree, d, ww, wh) {
        Some((ox0, oy0, ox1, oy1)) => {
          let ow = ox1 - ox0
          let oh = oy1 - oy0
          let raw_fill = (d.ground & 0xFFL).to_double() / 255.0 * d.alpha
          let fill_alpha = if raw_fill >= 0.75 && ow >= 40.0 && oh >= 24.0 { raw_fill } else { 0.0 }
          let scrim_alpha = match d.glass {
            Some(g) =>
              if g.progressive &&
                !g.liquid &&
                g.blur > 0.0 &&
                g.strength > 0.001 &&
                g.strength * d.alpha >= 0.85 &&
                ow >= 160.0 &&
                oy0 <= 10.0 &&
                oh >= 24.0 {
                g.strength * d.alpha
              } else {
                0.0
              }
            None => 0.0
          }
          if fill_alpha > 0.0 || scrim_alpha > 0.0 {
            occluders.push((i, d.id, ox0, oy0, ox1, oy1, fill_alpha, scrim_alpha, node_fade))
          }
        }
        None => ()
      }
    }
    let s = scales[i]
    let (f_start, f_top, f_end, f_foot) = match tree.cut_soft_of(d.id) {
      Some((over_top, over_foot, h)) => (0.0, cut_soft(over_top, h / 2.0), 0.0, cut_soft(over_foot, h / 2.0))
      None => tree.fades_of(d.id)
    }
    if f_start > 0.0 || f_top > 0.0 || f_end > 0.0 || f_foot > 0.0 {
      let past = if d.clips && !d.clips_self { tree.clips_past_of(d.id) } else { 0.0 }
      let fh = dmax(0.0, d.h + past * s)
      fading.push((d.id, (d.x, d.y, d.x + d.w, d.y + fh), (f_start * s, f_top * s, f_end * s, f_foot * s)))
    }
  }
  let is_occluded = fn(id : @view.NodeId, x0 : Double, y0 : Double, x1 : Double, y1 : Double) -> Bool {
    guard draw_idx.get(id.at) is Some(idx) else { return false }
    for occ in occluders {
      let (oidx, oid, ox0, oy0, ox1, oy1, fill_alpha, scrim_alpha, fade) = occ
      if oidx <= idx {
        continue
      }
      if tree.holds(id, oid) || tree.holds(oid, id) {
        continue
      }
      if ox0 <= x0 + 0.5 && oy0 <= y0 + 0.5 && ox1 >= x1 - 0.5 && oy1 >= y1 - 0.5 {
        let min_fade = wk_fade_min(fade, x0, y0, x1, y1)
        if (fill_alpha >= 0.75 && fill_alpha * min_fade >= 0.75) ||
          (scrim_alpha >= 0.85 && min_fade >= 0.15) {
          return true
        }
      }
    }
    false
  }
  // Collect visible, unclipped, non-occluded, non-owner interactive controls (bounded by input_bounds).
  let seen_ctrl : Map[Int, Bool] = Map([])
  let controls : Array[(@view.NodeId, Double, Double, Double, Double)] = []
  for pb in tree.press_boxes() {
    let id = pb.0
    if is_owner(id) || seen_ctrl.contains(id.at) {
      continue
    }
    let (x0, y0, x1, y1) = pb.1
    if x1 - x0 > ww * 0.5 || y1 - y0 > 80.0 || is_occluded(id, x0, y0, x1, y1) {
      continue
    }
    seen_ctrl[id.at] = true
    controls.push((id, x0, y0, x1, y1))
  }
  for d in drawn {
    if is_owner(d.id) || seen_ctrl.contains(d.id.at) || !tree.takes_presses(d.id) {
      continue
    }
    match tree.said_of(d.id) {
      Some(s) if role_interactive(s.role) =>
        match wk_input_box(tree, d, ww, wh) {
          Some((x0, y0, x1, y1)) if x1 - x0 <= ww * 0.5 &&
            y1 - y0 <= 80.0 &&
            !is_occluded(d.id, x0, y0, x1, y1) => {
            seen_ctrl[d.id.at] = true
            controls.push((d.id, x0, y0, x1, y1))
          }
          _ => ()
        }
      _ => ()
    }
  }
  let zx0 = kx - 4.0
  let zy0 = ky
  let zx1 = kx + kw
  let zy1 = ky + kh
  let k1_reported : Map[Int, Bool] = Map([])
  // K1 (controls): no non-owner interactive control overlaps [kx - 4, kx + kw] x [ky, ky + kh]
  // (unless the overlapping region itself is occluded by a later opaque bar/veil or progressive top scrim).
  for c in controls {
    let (id, x0, y0, x1, y1) = c
    if wk_rect_hits(x0, y0, x1, y1, zx0, zy0, zx1, zy1) {
      let ix0 = if x0 > zx0 { x0 } else { zx0 }
      let iy0 = if y0 > zy0 { y0 } else { zy0 }
      let ix1 = if x1 < zx1 { x1 } else { zx1 }
      let iy1 = if y1 < zy1 { y1 } else { zy1 }
      if !is_occluded(id, ix0, iy0, ix1, iy1) {
        k1_reported[id.at] = true
        out.push(
          "[WINDOW_KEYS_K1] control at (\{x0.round()},\{y0.round()} \{(x1 - x0).round()}×\{(y1 - y0).round()}) overlaps window-keys zone (\{zx0.round()},\{zy0.round()}..\{zx1.round()},\{zy1.round()})" +
          tree_source_said(id),
        )
      }
    }
  }
  // K1 (drawn text, icons, images, narrow capsules) + K3 (hard top-bar bottom edge / hairline), using paint clip bounds.
  let mut k1_text_hit = false
  for d in drawn {
    if is_owner(d.id) {
      continue
    }
    guard wk_drawn_box(tree, d, ww, wh) is Some((x0, y0, x1, y1)) else { continue }
    let bw = x1 - x0
    let bh = y1 - y0
    // K1 for visible non-owner content nodes (skip content occluded under a top bar or progressive scroll-edge scrim).
    if !k1_reported.contains(d.id.at) && wk_rect_hits(x0, y0, x1, y1, zx0, zy0, zx1, zy1) {
      let ix0 = if x0 > zx0 { x0 } else { zx0 }
      let iy0 = if y0 > zy0 { y0 } else { zy0 }
      let ix1 = if x1 < zx1 { x1 } else { zx1 }
      let iy1 = if y1 < zy1 { y1 } else { zy1 }
      if !is_occluded(d.id, ix0, iy0, ix1, iy1) {
        let has_text = bh <= 80.0 && drawn_has_visible_text(d)
        let has_icon = !d.shapes.is_empty() || !d.lines.is_empty() || d.image is Some(_)
        // Exclude top-bar solid backgrounds spanning the capsule width (their bottom edge is checked by K3).
        let is_bar_bg = d.y <= 1.0 && x0 <= kx + 0.5 && x1 >= kx + kw - 0.5 && d.glass is None
        let has_pill = !is_bar_bg &&
          d.w < ww * 0.5 &&
          d.h <= 64.0 &&
          ((d.ground & 0xFFL) > 0L || d.glass is Some(_))
        if has_text || has_icon || has_pill {
          k1_reported[d.id.at] = true
          if has_text {
            k1_text_hit = true
          }
          let kind = if has_text {
            "text"
          } else if has_icon {
            "icon/shape"
          } else {
            "capsule/fill"
          }
          out.push(
            "[WINDOW_KEYS_K1] \{kind} at (\{x0.round()},\{y0.round()} \{bw.round()}×\{bh.round()}) overlaps window-keys zone (\{zx0.round()},\{zy0.round()}..\{zx1.round()},\{zy1.round()})" +
            tree_source_said(d.id),
          )
        }
      }
    }
    // K3: horizontal hairline intersecting [kx, kx + kw] or opaque bar fill spanning [kx, kx + kw] ending in (ky, ky + kh + 3].
    if x0 < kx + kw - 0.5 && x1 > kx + 0.5 && y1 > ky + 0.5 && y1 <= ky + kh + 3.0 {
      let ix0 = if x0 > kx { x0 } else { kx }
      let ix1 = if x1 < kx + kw { x1 } else { kx + kw }
      if !is_occluded(d.id, ix0, y0, ix1, y1) {
        let is_hairline = bh <= 2.0 && bw >= 20.0 && ((d.ground & 0xFFL) > 0L || !d.lines.is_empty() || !d.rects.is_empty())
        let fill_alpha = (d.ground & 0xFFL).to_double() / 255.0 * d.alpha
        let is_solid_bar = x0 <= kx + 0.5 &&
          x1 >= kx + kw - 0.5 &&
          bh > 2.0 &&
          bh <= 80.0 &&
          d.glass is None &&
          fill_alpha >= 0.75
        if is_hairline || is_solid_bar {
          let kind = if is_hairline { "hairline" } else { "opaque bar edge" }
          out.push(
            "[WINDOW_KEYS_K3] \{kind} bottom y=\{y1.round()} intrudes into window-keys clearance (\{ky.round()}..\{(ky + kh + 3.0).round()})" +
            tree_source_said(d.id),
          )
        }
      }
    }
  }
  // K1 (glyph fallback for legacy/hosted old-view text).
  let has_hosted = drawn.any(fn(d) { d.hosted })
  if !k1_text_hit && has_hosted {
    for g in self.glyphs_seen() {
      let (gx0, gy0, gx1, gy1) = g
      if gx1 > gx0 && gy1 > gy0 && wk_rect_hits(gx0, gy0, gx1, gy1, zx0, zy0, zx1, zy1) {
        out.push(
          "[WINDOW_KEYS_K1] visible glyph at (\{gx0.round()},\{gy0.round()}..\{gx1.round()},\{gy1.round()}) overlaps window-keys zone (\{zx0.round()},\{zy0.round()}..\{zx1.round()},\{zy1.round()})",
        )
        break
      }
    }
  }
  // K2: Small dedicated top-band clearance or Bar/Tape vertical centerline alignment.
  if is_band {
    let band_h = ky * 2.0 + kh
    for c in controls {
      let (id, x0, y0, x1, y1) = c
      if y0 < band_h - 0.5 {
        out.push(
          "[WINDOW_KEYS_K2] control at (\{x0.round()},\{y0.round()} \{(x1 - x0).round()}×\{(y1 - y0).round()}) enters dedicated top band y < \{band_h.round()}" +
          tree_source_said(id),
        )
      }
    }
    for g in self.glyphs_seen() {
      let (gx0, gy0, gx1, gy1) = g
      if gx1 > gx0 && gy1 > gy0 && gy0 < band_h - 0.5 && gy1 > 0.5 {
        out.push(
          "[WINDOW_KEYS_K2] visible glyph at (\{gx0.round()},\{gy0.round()}..\{gx1.round()},\{gy1.round()}) enters dedicated top band y < \{band_h.round()}",
        )
        break
      }
    }
  } else {
    let k_mid = ky + kh / 2.0
    for c in controls {
      let (id, x0, y0, x1, y1) = c
      let h = y1 - y0
      if y0 >= -0.5 &&
        y1 <= ky + kh + 6.5 &&
        y0 < ky + kh &&
        y1 > ky &&
        h >= 28.0 &&
        h <= 44.0 {
        let mid = (y0 + y1) / 2.0
        if (mid - k_mid).abs() > 1.0 {
          out.push(
            "[WINDOW_KEYS_K2] top-bar control at (\{x0.round()},\{y0.round()} \{(x1 - x0).round()}×\{h.round()}) centerline \{mid} differs from window-keys centerline \{k_mid} by > 1pt" +
            tree_source_said(id),
          )
        }
      }
    }
  }
  out
}
