// A short tag of words on a small ground of its own, said and not pressed (a runtime's on 账号's page, a plan's on
// 添加账号's, a status's pill, a badge): round as a tag is (Radius::Base: a capsule is what is pressed), as high as said at
// the default size of words; its words grow with the system's size of words, and the tag with them (box_at). A status's
// pill and a badge, inked by their tone, are one (static_tag_in); a runtime's tag is all of one style (tag_node).

///|
/// What a kind of static tag is drawn as (static_tag_in's): its box (a row, its padding at its ends, what leads it 4
/// before its words, round as a tag is; no ground: its caller's), how high it is said (`h`), its words' look, and what
/// box_at keeps of it.
priv struct TagKind {
  box : @ui.Style
  h : Double
  words : @ui.TextStyle
  kept : Ref[WordsBoxKept?]
}

///|
/// Node `b` made a static tag of kind `kind` (tag_node's, pill_node's, badge_node's, row_tag_node's) holding `words`
/// as they say it now in `ink`, on `ground` where it is given: as high as `kind` says, or as its words' line where the
/// system's size of words draws it higher (box_at); `lead` before its words (an icon, a mark); where it `cuts`, its
/// words cut short where its row has not the room for them, else as wide as they are; one piece in bones.
#callsite(autofill(loc))
fn static_tag_in(
  b : @view.View,
  kind : TagKind,
  words : () -> String,
  ink : () -> Int64,
  ground? : () -> Int64,
  lead? : (@view.View) -> Unit,
  cuts? : Bool = false,
  in_row? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  style_node(b, fn() { box_at(kind.kept, kind.box, kind.h, kind.words, b.words_scale()) }, in_row~, loc~)
  match ground {
    Some(g) => b.ground(By(g)).bone_whole(Is(true)) |> ignore
    None => ()
  }
  if cuts {
    b.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
  } else {
    b.shrink(Is(0.0)) |> ignore
  }
  match lead {
    Some(f) => f(b)
    None => ()
  }
  b.box(fn(w) {
    w.words(By(words)).words_look(By(fn() { @ui.style_words(kind.words) })).ink(By(ink)) |> ignore
    if cuts {
      w.cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    }
  })
  |> ignore
}

///|
/// Node `tag` made a tag (ui.tsx's runtimeTag: 18 high, 4 in, the hover's ground) holding `words` as they say it now,
/// the caption's size, medium, muted, on one line: as high as their line where the system's size of words draws it
/// higher than 18 (box_at, as static_tag_in's). Its look all of one style and its words' own (words_node): what a list of
/// rows each with a tag makes and binds no more than its words do (2026-11-18: the shared kernel's bindings were a page's
/// budget's more).
#callsite(autofill(loc))
pub fn tag_node(
  tag : @view.View,
  words : () -> String,
  lead? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  style_node(tag, fn() { box_at(tag_kept, tag_box, tag_h, tag_words, tag.words_scale()) }, loc~)
  match lead {
    Some(f) => f(tag)
    None => ()
  }
  words_node(tag, words, fn() { tag_words }, loc~) |> ignore
}

///|
/// A tag's height as said (tag_box's h=S4_5).
// kept across runs: a value
let tag_h : Double = 18.0

///|
// kept across runs: a value (no field of it changes)
let tag_box : @ui.Style = @ui.css("row h=S4_5 px=S1 gap=S1 align=ACenter radius=Base bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let tag_words : @ui.TextStyle = @ui.text_style(size=Caption, leading=L4, weight=Medium, color=Muted, wrap=false)

///|
// kept across runs: the last theme and size of words a tag was asked at and its style (box_at), worked out again for any
// other
let tag_kept : Ref[WordsBoxKept?] = Ref(None)

///|
/// A status pill (pill_node's): pill_h high, pill_in in at either end, the meta's size, medium.
// kept across runs: a value (what it keeps, box_at's)
let pill_kind : TagKind = {
  box: @ui.css("row gap=S1 align=ACenter radius=Base").then(@ui.style(h=Fixed(pill_h), px=room(pill_in))),
  h: pill_h,
  words: pill_words,
  kept: Ref(None),
}

///|
/// A badge (badge_node's): a tag's height, 5 in at either end, the caption's size, medium.
// kept across runs: a value (what it keeps, box_at's)
let badge_kind : TagKind = {
  box: @ui.css("row h=S4_5 px=S1_25 gap=S1 align=ACenter radius=Base"),
  h: tag_h,
  words: @ui.text_style(size=Caption, leading=L4, weight=Medium, wrap=false),
  kept: Ref(None),
}
