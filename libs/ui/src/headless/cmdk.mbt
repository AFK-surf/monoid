// A command palette's list as Paco Coursey's cmdk has it (github.com/pacocoursey/cmdk, v1.1.1, fb4ea04, MIT): how
// well what was written matches each choice (its own copy of command-score, superhuman's, MIT: `command_score`), which
// choices a search shows, in what order, under which group's heading and with which rule between groups
// (`cmdk_filter`), and where the keys move the one the keys are on (`cmdk_first`, `cmdk_keep`, `cmdk_move`). Numbers and
// keys alone: nothing here makes a node or says anything of one (headless.mbt). A palette is a combobox
// (combobox.mbt) whose `keys` are the items of `cmdk_filter`'s rows and whose `active` its caller keeps by `cmdk_keep`
// as what is written changes; its look draws the headings and the rules.
//
// Where this differs from cmdk, on purpose:
// - A choice's keywords are each scored alone, the best of its label's and theirs taken (`cmdk_score`); cmdk writes
//   them after its label and scores the whole (`command_score`'s `aliases`, kept as it is). Typed `ni`, a choice whose
//   keyword is `new item` scores 0.891, its label `Create new item` 0.802: it comes before `New document in …` (0.890),
//   as one who types `ni` means.
// - Letters are made small by ASCII's rule alone, on every target the same, so each character keeps its place (cmdk's
//   `toLowerCase` turns `İ` into two, and what it compares no longer lines up).
// - Characters are counted as MoonBit's `Char`s (code points), not JavaScript's halves of one: the same for every
//   character of the Basic Multilingual Plane.
// - Those that score the same keep the order they were given in; cmdk keeps the order its last search left them in.
//   With nothing written, the order given (the choices of no group first, then each group where its first was given),
//   never the last search's.

///|
/// A match of the next character just after the last (or at the start): the best.
let score_continue_match : Double = 1.0

///|
/// A match at a word's start after a space or a `-`.
let score_space_word_jump : Double = 0.9

///|
/// A match at a word's start after one of `\ / _ + . # " @ [ ( { &`.
let score_non_space_word_jump : Double = 0.8

///|
/// A match anywhere else (cmdk's 0.17; command-score's own was 0.3).
let score_character_jump : Double = 0.17

///|
/// Two characters written the other way round.
let score_transposition : Double = 0.1

///|
/// For each character (or each word's break) skipped over.
let penalty_skipped : Double = 0.999

///|
/// A character matched in another case.
let penalty_case_mismatch : Double = 0.9999

///|
/// All that was written matched before the label's end.
let penalty_not_complete : Double = 0.99

///|
/// `b` to the power `n` (n ≥ 0): JavaScript's `Math.pow` of a whole number, by multiplying.
fn score_pow(b : Double, n : Int) -> Double {
  let mut r = 1.0
  for _ in 0..<n {
    r = r * b
  }
  r
}

///|
/// Whether `c` breaks a word other than a space: JavaScript's `/[\\\/_+.#"@\[\(\{&]/`.
fn score_gap(c : Int) -> Bool {
  c == '\\'.to_int() ||
  c == '/'.to_int() ||
  c == '_'.to_int() ||
  c == '+'.to_int() ||
  c == '.'.to_int() ||
  c == '#'.to_int() ||
  c == '"'.to_int() ||
  c == '@'.to_int() ||
  c == '['.to_int() ||
  c == '('.to_int() ||
  c == '{'.to_int() ||
  c == '&'.to_int()
}

///|
/// Whether `c` is a space or a `-`: JavaScript's `/[\s-]/` (its `\s` whole).
fn score_space(c : Int) -> Bool {
  (c >= 0x09 && c <= 0x0D) ||
  c == 0x20 ||
  c == '-'.to_int() ||
  c == 0xA0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200A) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202F ||
  c == 0x205F ||
  c == 0x3000 ||
  c == 0xFEFF
}

///|
/// `s` as it is compared: its letters small (ASCII's alone), each space and `-` a space (cmdk's `formatInput`), one
/// character for one, so each keeps its place.
fn score_folded(s : Array[Int]) -> Array[Int] {
  s.map(fn(c) {
    if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      c + 32
    } else if score_space(c) {
      0x20
    } else {
      c
    }
  })
}

///|
/// The character at `at` of `s`, -1 off either end (JavaScript's `charAt` there is "", equal to another "").
fn score_at(s : Array[Int], at : Int) -> Int {
  if at >= 0 && at < s.length() {
    s[at]
  } else {
    -1
  }
}

///|
/// Where `c` is first in `s` from `from` on, -1 nowhere.
fn score_index_of(s : Array[Int], c : Int, from : Int) -> Int {
  for i in from..<s.length() {
    if s[i] == c {
      return i
    }
  }
  -1
}

///|
/// How many of `s` from `start` to before `end` are such as `such`.
fn score_count(s : Array[Int], start : Int, end : Int, such : (Int) -> Bool) -> Int {
  let mut n = 0
  for i in start..<end {
    if such(s[i]) {
      n = n + 1
    }
  }
  n
}

///|
/// command-score's `commandScoreInner`, line for line: the best score of what is written from `ai` on, matched in the
/// label from `si` on, each pair worked out once (`memo`, -1 not yet).
fn score_inner(
  s : Array[Int],
  a : Array[Int],
  ls : Array[Int],
  la : Array[Int],
  si : Int,
  ai : Int,
  memo : FixedArray[Double],
) -> Double {
  // (JavaScript's `===`; `>=` for the place past the end a transposition at the last character would ask, which its
  // own conditions never reach)
  if ai >= a.length() {
    return if si == s.length() { score_continue_match } else { penalty_not_complete }
  }
  let key = si * (a.length() + 1) + ai
  if memo[key] >= 0.0 {
    return memo[key]
  }
  let c = la[ai]
  let mut index = score_index_of(ls, c, si)
  let mut high = 0.0
  while index >= 0 {
    let mut score = score_inner(s, a, ls, la, index + 1, ai + 1, memo)
    if score > high {
      if index == si {
        score = score * score_continue_match
      } else if score_gap(score_at(s, index - 1)) {
        score = score * score_non_space_word_jump
        let breaks = score_count(s, si, index - 1, score_gap)
        if breaks > 0 && si > 0 {
          score = score * score_pow(penalty_skipped, breaks)
        }
      } else if score_space(score_at(s, index - 1)) {
        score = score * score_space_word_jump
        let breaks = score_count(s, si, index - 1, score_space)
        if breaks > 0 && si > 0 {
          score = score * score_pow(penalty_skipped, breaks)
        }
      } else {
        score = score * score_character_jump
        if si > 0 {
          score = score * score_pow(penalty_skipped, index - si)
        }
      }
      if s[index] != a[ai] {
        score = score * penalty_case_mismatch
      }
    }
    // (two written the other way round; or a letter written twice, matched once: command-score's #7428)
    if (score < score_transposition && score_at(ls, index - 1) == score_at(la, ai + 1)) ||
      (score_at(la, ai + 1) == score_at(la, ai) && score_at(ls, index - 1) != score_at(la, ai)) {
      let transposed = score_inner(s, a, ls, la, index + 1, ai + 2, memo)
      if transposed * score_transposition > score {
        score = transposed * score_transposition
      }
    }
    if score > high {
      high = score
    }
    index = score_index_of(ls, c, index + 1)
  }
  memo[key] = high
  high
}

///|
/// How well `query` matches `words`, from 0 (not at all: not shown) to 1 (the same): cmdk's `commandScore`, its
/// `aliases` written after the words with a space between, as cmdk scores its keywords. A palette scores by
/// `cmdk_score`.
pub fn command_score(words : String, query : String, aliases? : Array[String] = []) -> Double {
  let whole = StringBuilder()
  whole.write_string(words)
  for one in aliases {
    whole.write_char(' ')
    whole.write_string(one)
  }
  let s = whole.to_string().to_array().map(fn(c) { c.to_int() })
  let a = query.to_array().map(fn(c) { c.to_int() })
  let memo = FixedArray::make((s.length() + 1) * (a.length() + 1), -1.0)
  score_inner(s, a, score_folded(s), score_folded(a), 0, 0, memo)
}

///|
/// How well `query` matches a choice of these words and keywords: the best of its words' score and each keyword's
/// alone (cmdk scores the keywords written after the words: this file's head says why not). A choice of no words
/// scores 0, as in cmdk.
pub fn cmdk_score(words : String, query : String, keywords? : Array[String] = []) -> Double {
  if words == "" {
    return 0.0
  }
  let mut best = command_score(words, query)
  for k in keywords {
    let score = command_score(k, query)
    if score > best {
      best = score
    }
  }
  best
}

///|
/// A choice of a palette: its key (what it is chosen by, the same as long as it is the same choice), its label (what is
/// scored and shown), its keywords (scored, not shown), its group ("" none: also the heading its look draws over the
/// group's first) and whether it can be chosen (`disabled`: shown, passed over by the keys).
#derive(Eq, Debug)
pub(all) struct CmdkItem[K] {
  key : K
  label : String
  keywords : Array[String]
  group : String
  disabled : Bool
}

///|
/// A choice keyed `key`, called `label`.
pub fn[K] cmdk_item(
  key : K,
  label : String,
  keywords? : Array[String] = [],
  group? : String = "",
  disabled? : Bool = false,
) -> CmdkItem[K] {
  { key, label, keywords, group, disabled }
}

///|
/// A row of a palette's list, in order: the heading of the group whose choices follow (its name); a rule between the
/// group before and the one named, which follows (so each row has a key of its own: the group's name, "" none); a
/// choice and its score (0 where nothing is written). A heading only over a group's first, a rule only between two
/// groups: never two together, never one first or last.
#derive(Eq, Debug)
pub(all) enum CmdkEntry[K] {
  Heading(String)
  Separator(String)
  Item(CmdkItem[K], Double)
}

///|
/// The rows a palette of `items` shows with `query` written (cmdk's `filterItems` and `sort`). Nothing written (spaces
/// alone): every choice, the choices of no group first, then each group where its first was given, each in the order
/// given. Else those that score above 0 (by `score`, cmdk_score's unless said): the choices of no group first, then each
/// group that has one shown, the group with the best score first, each group's best first; ties in the order given.
pub fn[K] cmdk_filter(
  items : Array[CmdkItem[K]],
  query : String,
  score? : (String, String, Array[String]) -> Double = fn(w, q, k) { cmdk_score(w, q, keywords=k) },
) -> Array[CmdkEntry[K]] {
  let searching = query.trim().to_owned() != ""
  let scores = items.map(fn(it) { if searching { score(it.label, query, it.keywords) } else { 0.0 } })
  let shown = fn(i : Int) { !searching || scores[i] > 0.0 }
  // (best first, ties in the order given: a sort that keeps them; nothing written, the order given)
  let by_score = fn(xs : Array[Int]) -> Array[Int] {
    let out = xs.copy()
    if searching {
      out.sort_by(fn(x, y) {
        let c = scores[y].compare(scores[x])
        if c != 0 {
          c
        } else {
          x.compare(y)
        }
      })
    }
    out
  }
  let all = Array::makei(items.length(), fn(i) { i })
  let order : Array[Int] = by_score(all.filter(fn(i) { items[i].group == "" && shown(i) }))
  // (the groups in the order their first was given, each with its best score; those with none shown left out)
  let names : Array[String] = []
  for it in items {
    if it.group != "" && !names.contains(it.group) {
      names.push(it.group)
    }
  }
  let lit : Array[(Int, Double)] = []
  for n, name in names {
    let mut best = 0.0
    let mut any = false
    for i in 0..<items.length() {
      if items[i].group == name && shown(i) {
        any = true
        if scores[i] > best {
          best = scores[i]
        }
      }
    }
    if any {
      lit.push((n, best))
    }
  }
  if searching {
    lit.sort_by(fn(x, y) {
      let c = y.1.compare(x.1)
      if c != 0 {
        c
      } else {
        x.0.compare(y.0)
      }
    })
  }
  for g in lit {
    let name = names[g.0]
    order.append(by_score(all.filter(fn(i) { items[i].group == name && shown(i) })))
  }
  let rows : Array[CmdkEntry[K]] = []
  let mut before : String? = None
  for i in order {
    let g = items[i].group
    let new_group = match before {
      None => true
      Some(b) => b != g
    }
    if new_group {
      if before is Some(_) {
        rows.push(Separator(g))
      }
      if g != "" {
        rows.push(Heading(g))
      }
    }
    rows.push(Item(items[i], scores[i]))
    before = Some(g)
  }
  rows
}

///|
/// The choices of `rows`, in order (what a combobox's `keys` are).
pub fn[K] cmdk_keys(rows : Array[CmdkEntry[K]]) -> Array[K] {
  rows.filter_map(fn(r) {
    match r {
      Item(it, _) => Some(it.key)
      _ => None
    }
  })
}

///|
/// The choices of `rows` that can be chosen, in order.
fn[K] cmdk_valid(rows : Array[CmdkEntry[K]]) -> Array[CmdkItem[K]] {
  rows.filter_map(fn(r) {
    match r {
      Item(it, _) if !it.disabled => Some(it)
      _ => None
    }
  })
}

///|
/// The first choice of `rows` that can be chosen (none: none can): where the keys go as a palette opens and as what is
/// written changes (cmdk's `selectFirstItem`).
pub fn[K] cmdk_first(rows : Array[CmdkEntry[K]]) -> K? {
  cmdk_valid(rows).get(0).map(fn(it) { it.key })
}

///|
/// Where the keys are once the rows changed: `selected` while it is still shown and can be chosen (a choice come or gone
/// elsewhere changes nothing), else the first that can be (cmdk: the one selected gone, the first).
pub fn[K : Eq] cmdk_keep(rows : Array[CmdkEntry[K]], selected : K?) -> K? {
  match selected {
    Some(k) => {
      let valid = cmdk_valid(rows)
      let mut found = false
      for i = 0; i < valid.length(); i = i + 1 {
        if valid[i].key == k {
          found = true
          break
        }
      }
      if found {
        Some(k)
      } else {
        cmdk_first(rows)
      }
    }
    None => cmdk_first(rows)
  }
}

///|
/// Where a key moves the keys: the next choice or the one before (↓ ↑), the first or the last (Home and End), the next
/// group's first or the one before's (⌥↓ ⌥↑).
#derive(Eq, Debug)
pub(all) enum CmdkMove {
  NextItem
  PrevItem
  FirstItem
  LastItem
  NextGroup
  PrevGroup
}

///|
/// Where the keys are after `by` from `selected` (cmdk's `updateSelectedByItem`, `updateSelectedByGroup`,
/// `updateSelectedToIndex`), the choices that cannot be chosen passed over; `selected` where there is nowhere to go
/// (none selected or not shown: NextItem and FirstItem go to the first, PrevItem and LastItem to the last). `wraps` (cmdk's `loop`):
/// past the last to the first and before the first to the last. By group: the first that can be chosen of the next
/// group shown (or the one before) that has one; from a choice of no group, or with no group further, as by one.
pub fn[K : Eq] cmdk_move(
  rows : Array[CmdkEntry[K]],
  selected : K?,
  by : CmdkMove,
  wraps? : Bool = false,
) -> K? {
  let valid = cmdk_valid(rows)
  let n = valid.length()
  if n == 0 {
    return selected
  }
  let at = match selected {
    Some(k) => {
      let mut found : Int? = None
      for i = 0; i < valid.length(); i = i + 1 {
        if valid[i].key == k {
          found = Some(i)
          break
        }
      }
      found
    }
    None => None
  }
  let key = fn(i : Int) { Some(valid[i].key) }
  let by_one = fn(change : Int) {
    match at {
      None => if change > 0 { key(0) } else { key(n - 1) }
      Some(i) =>
        if i + change < 0 {
          if wraps {
            key(n - 1)
          } else {
            selected
          }
        } else if i + change >= n {
          if wraps {
            key(0)
          } else {
            selected
          }
        } else {
          key(i + change)
        }
    }
  }
  match by {
    NextItem => by_one(1)
    PrevItem => by_one(-1)
    FirstItem => key(0)
    LastItem => key(n - 1)
    NextGroup | PrevGroup => {
      let change = if by == NextGroup { 1 } else { -1 }
      // (the groups as they show: each a run of the choices shown of one group)
      let runs : Array[(String, Array[CmdkItem[K]])] = []
      for r in rows {
        if r is Item(it, _) {
          match runs.last() {
            Some((g, xs)) if g == it.group => xs.push(it)
            _ => runs.push((it.group, [it]))
          }
        }
      }
      let mine = match selected {
        Some(k) => {
          let mut found : Int? = None
          for i = 0; i < runs.length(); i = i + 1 {
            let r = runs[i]
            if r.0 != "" {
              let mut hit = false
              for j = 0; j < r.1.length(); j = j + 1 {
                if r.1[j].key == k {
                  hit = true
                  break
                }
              }
              if hit {
                found = Some(i)
                break
              }
            }
          }
          found
        }
        None => None
      }
      guard mine is Some(m) else { return by_one(change) }
      // (run by run, past the choices of no group, to the first group that has one to choose)
      let mut r = m + change
      while r >= 0 && r < runs.length() {
        let (g, xs) = runs[r]
        if g != "" {
          match xs.iter().find_first(fn(it) { !it.disabled }) {
            Some(it) => return Some(it.key)
            None => ()
          }
        }
        r = r + change
      }
      by_one(change)
    }
  }
}
