// Hairline separator above non-first rows inside a grouped card (`card_piece_node`), with a per-group
// lit-row tracker (`CardRowLit`) so each divider fades smoothly while either adjacent row (above or below)
// is hovered, pressed (mouse or finger), or focused.

///|
/// Tracks interactive row nodes in a grouped card by key so each hairline separator fades smoothly
/// while either adjacent row (above or below) is hovered, pressed (mouse or finger), or focused.
/// Supports an optional bottom action entry (`bind_bot`) when a row renders a sibling action row
/// below its main row inside the same `card_piece_node`.
pub struct CardRowLit {
  priv made : @signals.Signal[Int]
  priv tops : Map[String, Array[@view.View]]
  priv bots : Map[String, (@view.View, Bool)]
}

///|
/// A grouped card's lit-row tracker, none bound yet.
pub fn CardRowLit::new() -> CardRowLit {
  { made: @signals.signal(0), tops: {}, bots: {} }
}

///|
fn CardRowLit::add_top(self : CardRowLit, key : String, v : @view.View) -> Unit {
  if key == "" {
    return
  }
  match self.tops.get(key) {
    Some(list) => {
      for i in 0..<list.length() {
        if list[i].id() == v.id() {
          return
        }
      }
      list.push(v)
    }
    None => self.tops[key] = [v]
  }
}

///|
fn CardRowLit::drop_top(self : CardRowLit, key : String, v : @view.View) -> Bool {
  if key == "" {
    return false
  }
  match self.tops.get(key) {
    Some(list) => {
      let before = list.length()
      let kept = list.filter(fn(w) { w.id() != v.id() })
      if kept.length() == before {
        return false
      }
      if kept.length() == 0 {
        self.tops.remove(key)
      } else {
        self.tops[key] = kept
      }
      true
    }
    None => false
  }
}

///|
/// Register the main interactive node `v` for row `key` (unregistered automatically when `v` leaves).
pub fn CardRowLit::bind_top(self : CardRowLit, key : String, v : @view.View) -> Unit {
  if key == "" {
    return
  }
  self.add_top(key, v)
  self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
  v.owns(fn() {
    if self.drop_top(key, v) {
      self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
    }
  })
  |> ignore
}

///|
/// Register the main interactive node `v` for a reused row whose key changes reactively (`key()`).
pub fn CardRowLit::bind_top_now(self : CardRowLit, key : () -> String, v : @view.View) -> Unit {
  let cur : Ref[String] = Ref("")
  let set_key = fn(next : String) {
    let prev = cur.val
    if prev == next {
      return
    }
    self.drop_top(prev, v) |> ignore
    cur.val = next
    self.add_top(next, v)
    self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
  }
  v.reacts(key, set_key)
  v.owns(fn() {
    let prev = cur.val
    cur.val = ""
    if self.drop_top(prev, v) {
      self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
    }
  })
  |> ignore
}

///|
/// Register a sibling bottom action node `v` for row `key`. When `active` is false (e.g. a non-interactive
/// spinner), `lit_bot` returns false without reading `pointed()` and without falling back to the main row.
pub fn CardRowLit::bind_bot(self : CardRowLit, key : String, v : @view.View, active : Bool) -> Unit {
  if key == "" {
    return
  }
  self.bots[key] = (v, active)
  self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
  v.owns(fn() {
    if self.bots.get(key) is Some((w, _)) && w.id() == v.id() {
      self.bots.remove(key)
      self.made.set(@signals.untracked(fn() { self.made.get() }) + 1)
    }
  })
  |> ignore
}

///|
/// Whether any of `list` is lit (`lit_node`), asked in order until one is.
fn any_lit(list : Array[@view.View]) -> Bool {
  for i in 0..<list.length() {
    if lit_node(list[i]) {
      return true
    }
  }
  false
}

///|
/// Whether the main row of `key` is currently hovered, pressed, or focused.
pub fn CardRowLit::lit_top(self : CardRowLit, key : String) -> Bool {
  self.made.get() |> ignore
  match self.tops.get(key) {
    Some(list) => any_lit(list)
    None => false
  }
}

///|
/// Whether the bottom edge of row `key` (its bottom action if bound, else its main row) is currently lit.
pub fn CardRowLit::lit_bot(self : CardRowLit, key : String) -> Bool {
  self.made.get() |> ignore
  match self.bots.get(key) {
    Some((v, active)) => active && lit_node(v)
    None =>
      match self.tops.get(key) {
        Some(list) => any_lit(list)
        None => false
      }
  }
}

///|
/// Hairline separator above non-first rows inside a grouped card (`card_piece_node`), inset by `inset`
/// (default `S3` = 12pt to align with row content edges). Smoothly fades out while either adjacent row
/// (above or below) is hovered, pressed (mouse or finger), or focused, and fades back when released or left.
/// When both `key_now` and `key` are provided, `key_now` takes precedence over `key`.
#callsite(autofill(loc))
pub fn card_sep_node(
  card : @view.View,
  piece : () -> CardPiece,
  lit? : CardRowLit,
  key? : String = "",
  key_now? : () -> String,
  prev_key? : () -> String? = fn() { None },
  inset? : Double = @ui.Space::S3.px(),
  loc~ : SourceLoc,
) -> Unit {
  card.show(at_once=true, loc~, fn() { piece() is (CardBetween | CardFoot) }, fn(sep) {
    sep.margin(Is((inset, 0.0, inset, 0.0))).height(Is(Some(rule_w))) |> ignore
    match lit {
      Some(group) =>
        match key_now {
          Some(k_fn) => {
            let gone = @motion.hover_fade(
              sep,
              fn() {
                let k = k_fn()
                (k != "" && group.lit_top(k)) ||
                (match prev_key() {
                  Some(p) => group.lit_bot(p)
                  None => false
                })
              },
              duration_ms=dur_ms,
            )
            sep.ground(By(fn() { alpha(rule_color(), 1.0 - gone()) })) |> ignore
          }
          None if key != "" => {
            let gone = @motion.hover_fade(
              sep,
              fn() {
                group.lit_top(key) ||
                (match prev_key() {
                  Some(p) => group.lit_bot(p)
                  None => false
                })
              },
              duration_ms=dur_ms,
            )
            sep.ground(By(fn() { alpha(rule_color(), 1.0 - gone()) })) |> ignore
          }
          _ => sep.ground(By(fn() { rule_color() })) |> ignore
        }
      None => sep.ground(By(fn() { rule_color() })) |> ignore
    }
  })
}
