// Per-Tree bitsets mirroring `Tree::inputs_in` and `Tree::inputs_at` for O(1) membership and O(depth) ancestor
// deduplication without changing `Tree`'s C struct layout, plus zero-allocation direct-flex-child lookup for
// `structure_row_sync`.

///|
priv struct InputsAux {
  in_bits : Array[UInt]
  at_bits : Array[UInt]
}

///|
// kept across runs: per-Tree side table + 1-slot MRU cache, cleared on `Tree::dispose`
let tree_inputs_auxs : Array[(Tree, InputsAux)] = []

///|
// kept across runs: 1-slot MRU cache for `Tree::inputs_aux` / `inputs_aux_opt`, cleared on `Tree::dispose`
let last_inputs_aux : Ref[(Tree, InputsAux)?] = Ref(None)

///|
fn Tree::inputs_aux_opt(self : Tree) -> InputsAux? {
  match last_inputs_aux.val {
    Some((t, aux)) if physical_equal(t, self) => return Some(aux)
    _ => ()
  }
  for entry in tree_inputs_auxs {
    if physical_equal(entry.0, self) {
      last_inputs_aux.val = Some(entry)
      return Some(entry.1)
    }
  }
  None
}

///|
fn Tree::inputs_aux(self : Tree) -> InputsAux {
  match self.inputs_aux_opt() {
    Some(aux) => aux
    None => {
      let aux : InputsAux = { in_bits: [], at_bits: [] }
      let pair = (self, aux)
      tree_inputs_auxs.push(pair)
      last_inputs_aux.val = Some(pair)
      aux
    }
  }
}

///|
fn Tree::inputs_aux_clear(self : Tree) -> Unit {
  match last_inputs_aux.val {
    Some((t, _)) if physical_equal(t, self) => last_inputs_aux.val = None
    _ => ()
  }
  match tree_inputs_auxs.search_by(fn(e) { physical_equal(e.0, self) }) {
    Some(i) => {
      let (_, aux) = tree_inputs_auxs.remove(i)
      aux.in_bits.clear()
      aux.at_bits.clear()
      aux.in_bits.shrink_to_fit()
      aux.at_bits.shrink_to_fit()
      // Release the removed (Tree, InputsAux) slot past the array end even while other Trees remain live.
      tree_inputs_auxs.shrink_to_fit()
    }
    None => ()
  }
}

///|
/// Register `within` in `self.inputs_in` with O(1) bitset membership check and O(depth) ancestor subsumption
/// (skipping descendants of an already-marked subtree root).
fn Tree::inputs_mark_within(self : Tree, within : Int) -> Unit {
  if within < 0 || within >= self.nodes.length() {
    return
  }
  let aux = self.inputs_aux()
  if rest_bit_has(aux.in_bits, within) {
    return
  }
  let mut p = self.nodes[within].parent
  while p >= 0 {
    if rest_bit_has(aux.in_bits, p) {
      return
    }
    p = self.nodes[p].parent
  }
  rest_bit_set(aux.in_bits, within)
  self.inputs_in.push(within)
}

///|
/// Register `at` in `self.inputs_at` with O(1) bitset membership check.
fn Tree::inputs_at_add(self : Tree, at : Int) -> Unit {
  let aux = self.inputs_aux()
  if !rest_bit_has(aux.at_bits, at) {
    rest_bit_set(aux.at_bits, at)
    self.inputs_at.push(at)
  }
}

///|
/// Clear `in_bits` for every entry currently in `list`.
fn Tree::inputs_in_bits_clear(self : Tree, list : Array[Int]) -> Unit {
  match self.inputs_aux_opt() {
    Some(aux) =>
      for at in list {
        rest_bit_clear(aux.in_bits, at)
      }
    None => ()
  }
}

///|
/// Prune dead or cleared entries from `self.inputs_at` while keeping `at_bits` synchronized.
fn Tree::inputs_at_prune(self : Tree) -> Unit {
  let aux_opt = self.inputs_aux_opt()
  let live : Array[Int] = []
  for at in self.inputs_at {
    if at >= 0 && at < self.nodes.length() && self.nodes[at].live && self.nodes[at].input_cell is Some(_) {
      live.push(at)
    } else {
      match aux_opt {
        Some(aux) => rest_bit_clear(aux.at_bits, at)
        None => ()
      }
    }
  }
  self.inputs_at.clear()
  self.inputs_at.append(live)
}

///|
/// Return the sole direct flex child under `at` (skipping `slot` nodes) if there is exactly one, `-1` if none, or `-2`
/// as soon as a second direct flex child is seen (zero allocations, O(1) early exit on multi-child containers).
fn Tree::single_flex_kid_in(self : Tree, at : Int, found : Int) -> Int {
  let mut res = found
  for k in self.nodes[at].kids {
    let nk = self.nodes[k]
    if !nk.live {
      continue
    }
    if nk.slot {
      res = self.single_flex_kid_in(k, res)
      if res == -2 {
        return -2
      }
    } else {
      if res >= 0 {
        return -2
      }
      res = k
    }
  }
  res
}

///|
/// Return the sole direct flex child node index under `at`, or `< 0` when there are 0 or >= 2 direct flex children.
fn Tree::single_flex_kid(self : Tree, at : Int) -> Int {
  self.single_flex_kid_in(at, -1)
}
