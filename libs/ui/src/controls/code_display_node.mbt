// A code shown to be read off and typed elsewhere (a trusted device's security code, a sign-in's): its letters large
// in the code face, in groups as @ui.code_field_node lays its boxes out (3 and 3, 24 apart), so what is read here
// is grouped as what is typed there.

///|
/// `code` cut into `groups` (their sizes in order: [3, 3] a six-letter code into two threes). Where they do not add up
/// to its length (another kind of code, one that has its own dashes) or one of them is not above 0, the code whole;
/// none for an empty one.
pub fn code_segments(code : String, groups? : Array[Int] = [3, 3]) -> Array[String] {
  let chars : Array[Char] = []
  for ch in code {
    chars.push(ch)
  }
  if chars.is_empty() {
    return []
  }
  let mut total = 0
  for n in groups {
    if n <= 0 {
      return [code]
    }
    total += n
  }
  if groups.is_empty() || total != chars.length() {
    return [code]
  }
  let out : Array[String] = []
  let mut at = 0
  for n in groups {
    let b = StringBuilder()
    for i in at..<(at + n) {
      b.write_char(chars[i])
    }
    out.push(b.to_string())
    at += n
  }
  out
}

///|
/// A verification or security code `code()` in `parent`, in groups (`groups`, default `[3, 3]`: @ui.code_field_node's
/// grouping and the 24 between its groups), large semibold in the code face, in the middle of what holds it. Narrower
/// than one line, its groups go one under another, each in the middle (8 apart). The groups' row.
#callsite(autofill(loc))
pub fn code_display_node(parent : @view.View, code : () -> String, groups? : Array[Int] = [3, 3], loc~ : SourceLoc) -> @view.View {
  parent.box(made_for=loc, fn(outer) {
    style_node(outer, fn() { code_display_row })
    outer.wraps(Is(Some(@ui.Space::S2.px()))) |> ignore
    outer.each(
      fn() { code_segments(code(), groups~).mapi(fn(i, s) { (i, s) }) },
      fn(e) { e.0 },
      fn(cell, e) {
        cell
        .words_runs(By(fn() { [@ui.span(e.get().1, mono=true)] }), look=code_display_look)
        .ink(By(fn() { theme().p.text }))
        |> ignore
      },
      along_row=true,
    )
  })
}

///|
/// The groups side by side, 24 apart, in the middle of all of the width.
// kept across runs: a value (no field of it changes)
let code_display_row : @ui.Style = @ui.css("w=Full row gap=S6 align=ACenter justify=JCenter")

///|
/// A group: 34 semibold in the code face, 44 a line, on one line (mono's, as it was said: size=34, weight=600, line=44),
/// its letters 0.15 em (5 at 34) apart. Not by spaces between them: the code face's spaces are as wide as its figures,
/// which left the 24 between groups hardly wider than the room between two figures of one.
// kept across runs: a value (no field of it changes)
let code_display_look : @view.WordsLook = {
  size: 34.0,
  weight: 600,
  line: 44.0,
  wrap: false,
  tracking: @view.Spacing::Ems(0.15),
  balance: false,
  max_lines: 0,
}
