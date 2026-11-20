///|
/// What a button other than the primary did (View::on_buttons): went down, moved held, went up.
#derive(Eq, Debug)
pub(all) enum ButtonWent {
  ButtonDown
  ButtonMoved
  ButtonUp
}

///|
/// The pointer's secondary or middle button on a node that takes them (View::on_buttons): what it did, which button
/// (the host's: 2 the secondary, 3 the middle; 0 for a move), which of the two are held after it (`held`: 2 the
/// secondary, 4 the middle, as a browser's `buttons` says them), where, in the node's own terms as it is drawn then and
/// in the window's, and when (the event's own moment).
#derive(Eq, Debug)
pub(all) struct Buttons {
  went : ButtonWent
  button : Int
  held : Int
  x : Double
  y : Double
  wx : Double
  wy : Double
  at : Double
}

///|
/// The bit of `held` a host's button is (Buttons): 2 the secondary, 4 the middle, 0 any other.
pub fn button_bit(button : Int) -> Int {
  match button {
    2 => 2
    3 => 4
    _ => 0
  }
}

///|
/// What the pointer's secondary and middle buttons do on it, each from down to up with the moves between, in place of
/// its menu (View::on_menu: none asked of it, nor of what holds it): what a node that drives something with a whole
/// mouse needs (a button held to aim, the middle one dragged). `mask` says which button bits it takes (default `6`:
/// secondary `2` and middle `4`). Each runs as one change at its event's moment, outside any tracking; the primary
/// button and a finger are its on_press's and on_drag's, as ever, held beside these.
pub fn View::on_buttons(self : View, f : (Buttons) -> Unit, mask? : Int = 6) -> View {
  guard self.live() is Some(n) else { return self }
  self.tree.buttons_aux().on_buttons[self.at] = (n.gen, mask, f)
  self
}

///|
/// What the pointer's middle button alone does on it (mask `4`, host button `3`), leaving the secondary button to its
/// menu (View::on_menu).
pub fn View::on_middle(self : View, f : (Buttons) -> Unit) -> View {
  self.on_buttons(f, mask=4)
}

///|
/// What the secondary and middle buttons do of a tree's, beside it rather than in its nodes and itself (their layout
/// stays as it was: a field put among others moves the places of those after it in the C of every program reading
/// them, all of it compiled again): made by the first node that takes them (View::on_buttons) or the first pointer
/// held (Tree::set_moves_held), a tree that has neither none.
priv struct TreeButtonsAux {
  tree : Tree
  /// what each node that takes them does (View::on_buttons), by its place: the node of that generation's alone, with its button mask
  on_buttons : Map[Int, (Int, Int, (Buttons) -> Unit)]
  /// the node the secondary or middle button went down on that takes them, and which of them are held on it
  /// (Buttons' `held`): what they do till the last is let go its
  mut held : (NodeId, Int)?
  /// the pointer held in place by the window (the host's pointer lock): each of its moves is one, where it stays
  mut moves_held : Bool
}

///|
// kept across runs: each tree owns its entry until disposal (Tree::buttons_aux)
let tree_buttons_auxs : Array[TreeButtonsAux] = []

///|
// kept across runs: last tree's entry for O(1) lookup, cleared when its tree disposes
let tree_buttons_last : Ref[TreeButtonsAux?] = Ref(None)

///|
/// The tree's entry where it has one (none made: what reads and lets go asks this).
fn Tree::buttons_aux_opt(self : Tree) -> TreeButtonsAux? {
  if tree_buttons_auxs.is_empty() {
    return None
  }
  if tree_buttons_last.val is Some(last) && physical_equal(last.tree, self) {
    return Some(last)
  }
  for aux in tree_buttons_auxs {
    if physical_equal(aux.tree, self) {
      tree_buttons_last.val = Some(aux)
      return Some(aux)
    }
  }
  None
}

///|
/// The tree's entry, made where it has none, let go with the tree.
fn Tree::buttons_aux(self : Tree) -> TreeButtonsAux {
  if self.buttons_aux_opt() is Some(aux) {
    return aux
  }
  let aux : TreeButtonsAux = { tree: self, on_buttons: {}, held: None, moves_held: false }
  tree_buttons_auxs.push(aux)
  tree_buttons_last.val = Some(aux)
  self.root().owns_while(fn() {
    if tree_buttons_last.val is Some(last) && physical_equal(last, aux) {
      tree_buttons_last.val = None
    }
    if tree_buttons_auxs.search_by(fn(it) { physical_equal(it, aux) }) is Some(i) {
      tree_buttons_auxs.remove(i) |> ignore
    }
  }) |> ignore
  aux
}

///|
/// What the node at `at` does with the buttons matching `bit` (View::on_buttons), where it is the one that asked.
fn Tree::buttons_of(self : Tree, at : Int, bit? : Int = 6) -> ((Buttons) -> Unit)? {
  guard self.buttons_aux_opt() is Some(aux) else { return None }
  match aux.on_buttons.get(at) {
    Some((gen, mask, f)) if at < self.nodes.length() &&
      self.nodes[at].live &&
      self.nodes[at].gen == gen &&
      (mask & bit) != 0 => Some(f)
    _ => None
  }
}

///|
/// The node at `at` let go: what it did with the buttons with it (View::let_go).
fn Tree::buttons_clear_at(self : Tree, at : Int) -> Unit {
  if self.buttons_aux_opt() is Some(aux) {
    aux.on_buttons.remove(at)
  }
}

///|
/// Whether the pointer is held in place by the window (Tree::set_moves_held).
fn Tree::moves_are_held(self : Tree) -> Bool {
  match self.buttons_aux_opt() {
    Some(aux) => aux.moves_held
    None => false
  }
}

///|
fn Tree::buttons_held(self : Tree) -> (NodeId, Int)? {
  match self.buttons_aux_opt() {
    Some(aux) => aux.held
    None => None
  }
}

///|
fn Tree::set_buttons_held(self : Tree, held : (NodeId, Int)?) -> Unit {
  match (self.buttons_aux_opt(), held) {
    (Some(aux), _) => aux.held = held
    (None, None) => ()
    (None, Some(_)) => self.buttons_aux().held = held
  }
}

///|
/// The secondary (2) or middle (3) button down at (x, y) in the window at `at`: the topmost node drawn there that takes
/// a press and these buttons (View::on_buttons), else the first that holds it and does, out from it, as Tree::menu_at
/// finds a menu; told and holding them from now. True where one took it (its, not a menu's); false where none does
/// there (what the button does elsewhere as ever).
pub fn Tree::buttons_down(self : Tree, x : Double, y : Double, at : Double, button : Int) -> Bool {
  let bit = button_bit(button)
  guard bit != 0 else { return false }
  // (no node takes them: nothing asked, nothing made)
  guard self.buttons_aux_opt() is Some(aux) && !aux.on_buttons.is_empty() else { return false }
  // (one held on a node already: that node's if it takes this button too; otherwise let the button fall through)
  match aux.held {
    Some((id, held)) if self.alive_id(id) => {
      guard self.buttons_of(id.at, bit~) is Some(_) else { return false }
      aux.held = Some((id, held | bit))
      self.buttons_tell(id, ButtonDown, button, held | bit, x, y, at)
      return true
    }
    _ => aux.held = None
  }
  let took = Ref(-1)
  let asked = self.asked_at(
    x,
    y,
    at,
    fn(_) { false },
    fn(n, lx, ly, t) {
      // (held from its down on, what it does as it goes down seeing it held)
      if took.val >= 0 {
        aux.held = Some(({ at: took.val, gen: n.gen }, bit))
        match self.buttons_of(took.val, bit~) {
          Some(f) => f({ went: ButtonDown, button, held: bit, x: lx, y: ly, wx: x, wy: y, at: t })
          None => ()
        }
      }
    },
    took~,
    takes_at=Some(fn(i) { self.buttons_of(i, bit~) is Some(_) }),
  )
  asked && aux.held is Some(_)
}

///|
/// The pointer moved to (x, y) in the window at `at`: told the node a secondary or middle button is held on
/// (Tree::buttons_down), where one is. True where one is.
pub fn Tree::buttons_moved(self : Tree, x : Double, y : Double, at : Double) -> Bool {
  match self.buttons_held() {
    Some((id, held)) if self.alive_id(id) => {
      self.buttons_tell(id, ButtonMoved, 0, held, x, y, at)
      true
    }
    Some(_) => {
      self.set_buttons_held(None)
      false
    }
    None => false
  }
}

///|
/// The secondary (2) or middle (3) button up at (x, y) in the window at `at`: the node it was held on told, the last of
/// them let go its hold. True where one held it (the up its, nothing else's).
pub fn Tree::buttons_up(self : Tree, x : Double, y : Double, at : Double, button : Int) -> Bool {
  let bit = button_bit(button)
  match self.buttons_held() {
    Some((id, held)) if bit != 0 && (held & bit) != 0 => {
      let left = held & bit.lnot()
      self.set_buttons_held(if left == 0 { None } else { Some((id, left)) })
      if self.alive_id(id) {
        self.buttons_tell(id, ButtonUp, button, left, x, y, at)
      }
      true
    }
    _ => false
  }
}

///|
/// Whether a secondary or middle button is held on a node that takes them (Tree::buttons_down).
pub fn Tree::buttons_holding(self : Tree) -> Bool {
  match self.buttons_held() {
    Some((id, _)) => self.alive_id(id)
    None => false
  }
}

///|
/// Every secondary and middle button held let go of at once (the window gone out of focus, the press called off): the
/// node told each went up at (x, y).
pub fn Tree::buttons_off(self : Tree, x : Double, y : Double, at : Double) -> Unit {
  match self.buttons_held() {
    Some((_, held)) => {
      if (held & 2) != 0 {
        self.buttons_up(x, y, at, 2) |> ignore
      }
      if (held & 4) != 0 {
        self.buttons_up(x, y, at, 3) |> ignore
      }
      self.set_buttons_held(None)
    }
    None => ()
  }
}

///|
fn Tree::buttons_tell(
  self : Tree,
  id : NodeId,
  went : ButtonWent,
  button : Int,
  held : Int,
  x : Double,
  y : Double,
  at : Double,
) -> Unit {
  let t = if self.cause_at >= 0.0 { self.cause_at } else { at }
  if self.cause_at < 0.0 {
    self.bring_to(t)
  }
  self.event(t, fn() {
    self.laid_now(via=8) |> ignore
    guard self.alive_id(id) else { return }
    match self.buttons_of(id.at) {
      Some(f) => {
        let (nx, ny, ns) = self.placed(id.at)
        f({ went, button, held, x: (x - nx) / ns, y: (y - ny) / ns, wx: x, wy: y, at: t })
      }
      None => ()
    }
  })
}

///|
/// The pointer held in place by the window from now (the host's pointer lock) or not: held, each move of it is one
/// (View::on_pointer_moved told it), though it comes where the last did.
pub fn Tree::set_moves_held(self : Tree, held : Bool) -> Unit {
  match self.buttons_aux_opt() {
    Some(aux) => aux.moves_held = held
    // (not held, and none made: nothing to say)
    None => if held { self.buttons_aux().moves_held = true }
  }
}
