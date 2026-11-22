// Follow-the-finger/trackpad back hint for WideBack::Once on wide frames (pane_view and tape_view): slides a round
// floating arrow-left badge out from the left edge of the window, vertically centered, over all frame panels and under
// modal overlays, without taking presses or changing the cursor.

///|
/// Horizontal travel (in points / wheel delta) required before releasing a Once back gesture commits navigation.
/// Sized for macOS native trackpads, where LetGo arrives as momentum begins and `across` only reflects the finger phase.
pub let back_hint_far : Double = 60.0

///|
/// Per-frame state for the Once back gesture hint, owned by its frame node (pane_view / tape_view).
priv struct BackHint {
  host : @view.View
  active : @signals.Signal[Bool]
  across : @signals.Signal[Double]
  mut x0 : Double
  mut committed : Bool
  ready_way : @motion.NodeWay
  pop_way : @motion.NodeWay
}

///|
fn back_hint_new(host : @view.View) -> BackHint {
  {
    host,
    active: @signals.signal(false, same=fn(a, b) { a == b }),
    across: @signals.signal(0.0, same=fn(a, b) { a == b }),
    x0: 0.0,
    committed: false,
    ready_way: @motion.NodeWay::new(0.0),
    pop_way: @motion.NodeWay::new(1.0),
  }
}

///|
fn hint_clamp(v : Double, lo : Double, hi : Double) -> Double {
  dmin(hi, dmax(lo, v))
}

///|
/// Horizontal position (left edge of the circular badge in window coordinates) for a given `across` distance:
/// starts completely outside the left edge (-side), slides linearly to standard margin (card_pad) at back_hint_far,
/// and applies bounded damped travel (up to corner_inset) past back_hint_far.
fn back_hint_x(across : Double) -> Double {
  let side = @sf.float_button_side
  let margin = @sf.card_pad
  let a = dmax(0.0, across)
  if a <= back_hint_far {
    let p = a / back_hint_far
    -side + p * (side + margin)
  } else {
    let extra = a - back_hint_far
    let damp = @sf.corner_inset * (extra / (extra + back_hint_far))
    margin + damp
  }
}

///|
fn BackHint::began(self : BackHint, x : Double) -> Unit {
  self.x0 = x
  self.committed = false
  self.across.set(0.0)
  self.ready_way.put(0.0)
  self.pop_way.put(1.0)
  self.active.set(true)
}

///|
fn BackHint::moved(self : BackHint, x : Double) -> Unit {
  guard self.active.untracked() else { return }
  let a = dmax(0.0, x - self.x0)
  let was_ready = self.across.untracked() >= back_hint_far
  let now_ready = a >= back_hint_far
  self.across.set(a)
  if now_ready != was_ready {
    if @ui.reduced_motion() {
      self.ready_way.put(if now_ready { 1.0 } else { 0.0 })
    } else {
      self.ready_way.go_ms(self.host, if now_ready { 1.0 } else { 0.0 }, @sf.dur_ms)
      if now_ready {
        self.pop_way.go_from(self.host, 0.0, 1.0, @motion.tween(@sf.dur_ms, ease=Out))
      }
    }
  }
}

///|
/// Handle a BackStep for WideBack::Once; returns true when the navigation callback should run.
fn BackHint::step(self : BackHint, step : @ui.BackStep) -> Bool {
  match step {
    Began(x, _) => {
      self.began(x)
      false
    }
    Moved(x, _) => {
      self.moved(x)
      false
    }
    LetGo(x, _) =>
      if self.active.untracked() {
        let a = dmax(0.0, x - self.x0)
        self.across.set(a)
        let ok = a >= back_hint_far
        self.committed = ok
        self.ready_way.put(if ok { 1.0 } else { 0.0 })
        self.pop_way.put(1.0)
        @view.transition(within=self.host, fn() { self.active.set(false) })
        ok
      } else {
        false
      }
    CalledOff => {
      if self.active.untracked() {
        self.committed = false
        self.ready_way.put(0.0)
        self.pop_way.put(1.0)
        @view.transition(within=self.host, fn() { self.active.set(false) })
      }
      false
    }
    Back => {
      if self.active.untracked() {
        self.committed = true
        self.ready_way.put(1.0)
        self.pop_way.put(1.0)
        @view.transition(within=self.host, fn() { self.active.set(false) })
      }
      true
    }
  }
}

///|
/// Clear any active hint when the back-taking node is unmounted or loses back ownership.
fn BackHint::clear(self : BackHint) -> Unit {
  self.committed = false
  self.across.set(0.0)
  self.ready_way.put(0.0)
  self.pop_way.put(1.0)
  self.active.set(false)
}

///|
/// Mount the floating back hint overlay node on `v` (above all frame panels, below modal overlays).
/// Present only while a gesture is active; exit motion (fade-and-shrink in place on commit, slide back off-edge on
/// cancel) is driven by View::show's `leave` and `@motion.presence_in`.
/// Skipped visually on Android (platform 2), where the system predictive back gesture draws its own arrow.
fn back_hint_node(v : @view.View, hint : BackHint) -> Unit {
  v.show(at_once=true, leave=@sf.leave_ms, fn() { @ui.platform() != 2 && hint.active.get() }, fn(o) {
    o.over(Is(true)).points(Is(false)) |> ignore
    let shown = @motion.presence_in(
      o,
      @motion.tween(@sf.dur_ms, ease=Out),
      exit=@motion.tween(@sf.leave_ms, ease=Out),
      from=1.0,
      carries=true,
    )
    o.box(fn(b) {
      b.points(Is(false)).drawn_as(Is("/back-hint/")) |> ignore
      @sf.style_node(b, fn() { @sf.float_badge_look })
      let side = @sf.float_button_side
      let ready_u = fn() { hint_clamp(hint.ready_way.shown(b), 0.0, 1.0) }
      let badge_alpha = fn() {
        let u = hint_clamp(shown(), 0.0, 1.0)
        if o.leaving() {
          if hint.committed {
            u
          } else {
            let p = hint_clamp(hint.across.get() * u / back_hint_far, 0.0, 1.0)
            @sf.seen_at(0.5 + 0.5 * hint_clamp(p * 2.0, 0.0, 1.0))
          }
        } else {
          let p = hint_clamp(hint.across.get() / back_hint_far, 0.0, 1.0)
          @sf.seen_at(0.5 + 0.5 * hint_clamp(p * 2.0, 0.0, 1.0))
        }
      }
      @sf.floating_capsule_decorate(
        b,
        sharing=false,
        tint=fn() {
          let u = ready_u()
          if u <= 0.001 {
            None
          } else {
            Some(@ui.blend(@sf.glass_floating().tint, @sf.theme().p.accent, u))
          }
        },
        active=fn() { badge_alpha() > 0.001 },
        with_edge=true,
        with_shadow=true,
        clips=true,
      )
      .offset(By(fn() {
        let wh = o.window_h()
        let y = (wh - side) / 2.0
        let a = hint.across.get()
        let x = if o.leaving() && !hint.committed {
          back_hint_x(a * hint_clamp(shown(), 0.0, 1.0))
        } else {
          back_hint_x(a)
        }
        (x, y)
      }))
      .scale(
        By(fn() {
          let u = hint_clamp(shown(), 0.0, 1.0)
          if o.leaving() {
            if hint.committed {
              @sf.leave_scale + (1.0 - @sf.leave_scale) * u
            } else {
              let p = hint_clamp(hint.across.get() * u / back_hint_far, 0.0, 1.0)
              0.5 + 0.5 * p
            }
          } else {
            let p = hint_clamp(hint.across.get() / back_hint_far, 0.0, 1.0)
            let base = 0.5 + 0.5 * p
            let pop_u = hint_clamp(hint.pop_way.shown(b), 0.0, 1.0)
            let pop = 1.0 + 0.12 * 4.0 * pop_u * (1.0 - pop_u)
            base * pop
          }
        }),
        about=At(0.5, 0.5),
      )
      .alpha(By(badge_alpha))
      |> ignore
      @sf.icon_node(
        b,
        "arrow-left",
        @sf.float_button_icon,
        By(fn() { @ui.blend(@sf.theme().p.text, @ui.tree_theme().on_accent, ready_u()) }),
      )
      |> ignore
    })
    |> ignore
  })
}
