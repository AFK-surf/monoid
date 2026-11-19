// What a link's card holds over a link (sfpages' web_peek_node, file_card_node, chat_card_node) and a link's card in an
// agent's words (sfbase's screen_links_node), as nodes of the window's tree, made once: the looks alone, what each
// shows given as it is now by the app, which reads the core for it (its topics, what they say worked out into words)
// and says what a press does. A web page's tile, a pull request's or an issue's card, its address or a file's path to
// copy at its foot's end; a file's head, its lines, its picture, its entries, its foot; a chat's head, where it is and
// the message a link names; a link's capsule with its mark, its title over its line. What is over them (the hover
// card, opened as the pointer rests on what names them) is hover_card_node's, not these.

// ── a web link's ──────────────────────────────────────────────

///|
/// A fact a pull request's or an issue's card shows (peek_change_node's): who opened it (their login, their picture's
/// image's key, "" none), a pull request's size (added, taken out), a fact in a pill, how its checks stand (as a state:
/// failed, pending, passed; in words).
#derive(Eq, Hash)
pub(all) enum PeekFact {
  Person(String, String)
  Size(Int, Int)
  Chip(String)
  Checks(String, String)
}

///|
/// A page's tile (a web link's card for no pull request nor issue) in `parent`: its icon in its thumb (`icon`: a site's
/// icon's image's key; "" none, GitHub's mark where `github`, else the globe), its `title` over where it goes (`url`);
/// its picture over it where `picture` names one (its image's key, "" none), as wide as the card; its foot, `copy` at
/// its end. Each as it changes.
#callsite(autofill(loc))
pub fn peek_page_tile_node(
  parent : @view.View,
  title : () -> String,
  url : () -> String,
  icon : () -> String,
  github : () -> Bool,
  picture : () -> String,
  copy : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  // (its thumb in the card's corner, or, under its picture, beside its title's first line: pictured)
  let tile = fn(holder : @view.View, pictured : Bool) {
    holder.box(made_for=loc, fn(t) {
      style_node(t, fn() { peek_tile })
      t.box(fn(th) {
        style_node(th, fn() { if pictured { peek_thumb_under } else { peek_thumb } }, in_row=true)
        th.pick(fn() { (icon(), github()) }, fn(m, k) {
          match k {
            ("", true) => peek_github_mark_node(m, peek_thumb_mark, fn() { theme().p.muted })
            ("", false) => icon_node(m, "web", peek_thumb_icon, By(fn() { theme().p.muted })) |> ignore
            (key, _) =>
              m
              .width(Is(Some(peek_thumb_mark)))
              .height(Is(Some(peek_thumb_mark)))
              .image(Is(Some((key, "", peek_image_most))))
              // (all of it in its square, as page_tile's FitContain: a site's icon not square kept as it is)
              .image_contains(Is(true))
              |> ignore
          }
        })
      })
      |> ignore
      t.box(fn(body) {
        style_node(body, fn() { peek_tile_body }, in_row=true)
        words_node(body, title, fn() { peek_tile_title }) |> ignore
        // (as wide as its words, as the old view's (w=Cut): cut where it is longer, not stretched across)
        body.box(fn(u) {
          u.lines_up(Is(Some(@view.Along::Start))) |> ignore
          words_node(u, url, fn() { peek_tile_url }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  parent.pick(fn() { picture() != "" }, fn(b, pictured) {
    // (in a hover card's room: its words the panel's padding and theirs in from the card's edges, what reaches out to its
    // corners concentric with it)
    corner_card_node(b, fn() { r_menu }, inset=fn() { panel_pad + peek_words_in })
    if pictured {
      // (its picture over it, 16:9, in the card's top corners as the thumb is in its corner without one)
      style_node(b, fn() { peek_with_picture })
      b.box(fn(i) {
        style_node(i, fn() { peek_picture })
        i
        .aspect(Is(peek_picture_aspect))
        |> ignore
        concentric_radius_node(i, fn() { peek_picture_r }, extra_inset=fn() { peek_thumb_out })
        i
        .ground(By(fn() { theme().p.hover }))
        .image(By(fn() { Some((picture(), "", peek_image_most)) }))
        .image_covers(Is(true))
        |> ignore
      })
      |> ignore
    }
    tile(b, pictured)
  })
  // (its copy in its foot's end corner, as a file's card's is: file_foot)
  parent.box(made_for=loc, fn(f) {
    style_node(f, fn() { peek_file_foot })
    f.box(fn(r) { style_node(r, fn() { peek_ref }, in_row=true) }) |> ignore
    copy(f)
  })
  |> ignore
}

///|
/// A pull request's (`pr`) or an issue's card in `parent`: its `state`'s pill (GitHub's glyph of it, `state_words`),
/// where it is (`where`) and when it last changed (`ago`, none where ""); its `title`; who opened it and its `facts`,
/// `copy` at their line's end. Each as it changes.
#callsite(autofill(loc))
pub fn peek_change_node(
  parent : @view.View,
  pr : Bool,
  state : () -> String,
  state_words : () -> String,
  where_ : () -> String,
  ago : () -> String,
  title : () -> String,
  facts : () -> Array[PeekFact],
  copy : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(rich) {
    style_node(rich, fn() { peek_rich })
    rich.box(fn(meta) {
      style_node(meta, fn() { peek_change_meta })
      peek_state_pill_node(
        meta,
        state,
        fn() { if pr { peek_pr_glyph(state()) } else { peek_issue_glyph(state()) } },
        state_words,
      )
      meta.box(fn(r) {
        style_node(r, fn() { peek_ref }, in_row=true)
        // (its words as wide as they are, cut where it has not the room, as an old view's in a column are)
        r.lines_up(Is(Some(@view.Along::Start))) |> ignore
        words_node(r, where_, fn() { peek_meta_words }) |> ignore
      })
      |> ignore
      meta.show(fn() { ago() != "" }, fn(a) { words_node(a, ago, fn() { peek_meta_words }) |> ignore })
    })
    |> ignore
    // (its title as wide as it is, cut to its lines where it has not the room, as an old view's words in a column are:
    // in a box across the card of its own, not stretched across it)
    rich.box(fn(b) {
      b.lines_up(Is(Some(@view.Along::Start))) |> ignore
      words_node(b, title, fn() { peek_title }) |> ignore
    })
    |> ignore
    // its facts, and at their line's end what is pressed to copy it (in the card's bottom end corner, as a file's is)
    rich.box(fn(line) {
      style_node(line, fn() { peek_facts_line })
      line.box(fn(fs) {
        style_node(fs, fn() { peek_facts }, in_row=true)
        // (what the copy at the line's end leaves of it, from none, its facts wrapping in that: not as wide as they all
        // are in a line)
        fs.wraps(Is(Some(@ui.Space::S2.px()))).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        fs.each(fn() { facts().mapi(fn(i, f) { (i, f) }) }, fn(f) { f }, fn(cell, item) {
          peek_fact_node(cell, item.untracked().1)
        })
      })
      |> ignore
      line.box(fn(e) {
        style_node(e, fn() { peek_copy_end }, in_row=true)
        copy(e)
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Fact `f` drawn in `cell` (its own node in the facts' line): who opened it, their picture (round, a capsule's
/// height; the line's ground where they have none) by their name; a size's two figures, green and red, in a pill; a
/// fact in a pill; how its checks stand in a state's pill (no glyph).
#callsite(autofill(loc))
fn peek_fact_node(cell : @view.View, f : PeekFact, loc~ : SourceLoc) -> Unit {
  match f {
    Person(login, avatar) => {
      style_node(cell, fn() { peek_person }, in_row=true)
      cell.box(made_for=loc, fn(a) {
        if avatar == "" {
          style_node(a, fn() { peek_avatar })
        } else {
          a
          .width(Is(Some(peek_avatar_d)))
          .height(Is(Some(peek_avatar_d)))
          .radius(Is(peek_avatar_d / 2.0))
          .ground(By(fn() { theme().p.hover }))
          .image(Is(Some((avatar, "", peek_image_most))))
          .image_covers(Is(true))
          |> ignore
        }
      })
      |> ignore
      words_node(cell, fn() { login }, fn() { peek_person_words }) |> ignore
    }
    Size(add, del) => {
      style_node(cell, fn() { peek_chip }, in_row=true)
      // (in the green states' ink: Positive is a badge's fill, too light to read on the hover's ground)
      words_node(cell, fn() { "+" + add.to_string() }, fn() { peek_add })
      .ink(By(fn() { theme().p.green_ink }))
      |> ignore
      words_node(cell, fn() { "\u{2212}" + del.to_string() }, fn() { peek_del }) |> ignore
    }
    Chip(words) => {
      style_node(cell, fn() { peek_chip }, in_row=true)
      words_node(cell, fn() { words }, fn() { peek_meta_words }) |> ignore
    }
    Checks(how, said) => peek_state_pill_node(cell, fn() { how }, fn() { None }, fn() { said }, own=true)
  }
}

///|
/// A state in a tinted pill in `parent`, or (`own`) drawn in `parent` itself: its glyph (GitHub's, 12, a 16 by 16
/// path) where `glyph` says one and its name (`words`), 500, in the state's colours (peek_state_colours), each as it
/// changes; `style` its pill's look (a pill 20 high, its glyph 6 in and its words 8 from its end; with no glyph, its words
/// 8 in from both ends: peek_state_words_only).
#callsite(autofill(loc))
pub fn peek_state_pill_node(
  parent : @view.View,
  state : () -> String,
  glyph : () -> String?,
  words : () -> String,
  own? : Bool = false,
  style? : @ui.Style = peek_state,
  loc~ : SourceLoc,
) -> Unit {
  let pill = fn(p : @view.View) {
    // (the glyph's 6 in is for a glyph alone: words alone stand as far in from both ends)
    style_node(
      p,
      fn() { if physical_equal(style, peek_state) && glyph() is None { peek_state_words_only } else { style } },
      in_row=true,
    )
    p.ground(By(fn() { peek_state_colours(state()).1 })) |> ignore
    p.show(fn() { glyph() is Some(_) }, fn(g) {
      g
      .width(Is(Some(peek_glyph)))
      .height(Is(Some(peek_glyph)))
      .shapes(By(fn() {
        match glyph() {
          Some(d) => @ui.vector_shapes(peek_glyph_of(d, peek_state_colours(state()).0), peek_glyph, g.pixel_scale())
          None => []
        }
      }))
      |> ignore
    })
    words_node(p, words, fn() { peek_state_words }).ink(By(fn() { peek_state_colours(state()).0 })) |> ignore
  }
  if own {
    pill(parent)
  } else {
    parent.box(made_for=loc, pill) |> ignore
  }
}

///|
/// GitHub's mark in `parent`, `w` wide, in `ink` as it changes.
#callsite(autofill(loc))
pub fn peek_github_mark_node(parent : @view.View, w : Double, ink : () -> Int64, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(g) {
    g
    .width(Is(Some(w)))
    .height(Is(Some(w)))
    .shapes(By(fn() { @ui.vector_shapes(peek_glyph_of(peek_github_path, ink()), w, g.pixel_scale()) }))
    |> ignore
  })
  |> ignore
}

///|
/// What is copied from a card (a web link's address, a file's path) in `parent`: `idle` to press (its words' key), 已复制
/// for copied_ms once copied (from the moment it was pressed: pressed again while it says so, from then). By what it
/// copies (`value`), in `copied_at` (the app's, when each was last copied): a card of it made again while that lasts
/// (gone and pointed at again) says 已复制 till its end.
pub fn peek_copy_node(
  parent : @view.View,
  value : () -> String,
  idle : String,
  copied_at : Map[String, Double],
) -> Unit {
  let copied = @signals.signal(false, same=fn(a, b) { a == b })
  let off : Ref[() -> Unit] = Ref(fn() {  })
  // (said so from `at`, the moment it was copied, till copied_ms on; off as of then)
  let said_from = fn(at : Double) {
    (off.val)()
    if parent.cause_at() < at + copied_ms {
      copied.set(true)
      off.val = parent.at_moment(at + copied_ms, fn() { copied.set(false) })
    } else {
      copied.set(false)
    }
  }
  // (made while it says so from the last copy of it, on another card of it: till that one's end)
  parent.reacts(fn() { () }, fn(_) {
    match copied_at.get(@signals.untracked(value)) {
      Some(at) => said_from(at)
      None => ()
    }
  })
  panel_button_node(
    parent,
    fn() { t(if copied.get() { "common.copied" } else { idle }) },
    fn() {
      let v = @signals.untracked(value)
      @ui.clipboard_set(v)
      let at = parent.cause_at()
      copied_at[v] = at
      said_from(at)
    },
    tone=Quiet,
  )
  |> ignore
  parent.owns(fn() { (off.val)() }) |> ignore
}

///|
/// A state's ink and ground (a pull request's or an issue's, its checks').
pub fn peek_state_colours(state : String) -> (Int64, Int64) {
  let p = theme().p
  match state {
    "open" | "passed" => (p.green_ink, p.green_bg)
    "merged" | "completed" => {
      let ink = if theme().dark { peek_merged_dark } else { peek_merged_light }
      (ink, tone_ground(ink))
    }
    "closed" | "failed" => (p.red, p.red_bg)
    "pending" => (p.warn_ink, p.amber_bg)
    _ => (p.muted, p.hover)
  }
}

///|
/// GitHub's purple for what was merged or completed, each theme's a step deeper or lighter than GitHub's
/// (#8250df, #a371f7) to read on its ground, the purple at the theme's tone opacity (tone_ground).
let peek_merged_light : Int64 = 0x6830BFFFL

///|
let peek_merged_dark : Int64 = 0xC4A9FFFFL

///|
/// GitHub's own octicons for a pull request's state (MIT, primer/octicons: Peeks.tsx PR_GLYPH), 16 by 16.
pub fn peek_pr_glyph(state : String) -> String? {
  Some(
    match state {
      "draft" => "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 14a2.25 2.25 0 1 1 0-4.5 2.25 2.25 0 0 1 0 4.5ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM14 7.5a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Zm0-4.25a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Z"
      "merged" => "M5.45 5.154A4.25 4.25 0 0 0 9.25 7.5h1.378a2.251 2.251 0 1 1 0 1.5H9.25A5.734 5.734 0 0 1 5 7.123v3.505a2.25 2.25 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.95-.218ZM4.25 13.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5Zm8.5-4.5a.75.75 0 1 0 0-1.5.75.75 0 0 0 0 1.5ZM5 3.25a.75.75 0 1 0 0 .005V3.25Z"
      "closed" => "M3.25 1A2.25 2.25 0 0 1 4 5.372v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.251 2.251 0 0 1 3.25 1Zm9.5 5.5a.75.75 0 0 1 .75.75v3.378a2.251 2.251 0 1 1-1.5 0V7.25a.75.75 0 0 1 .75-.75Zm-2.03-5.273a.75.75 0 0 1 1.06 0l.97.97.97-.97a.748.748 0 0 1 1.265.332.75.75 0 0 1-.205.729l-.97.97.97.97a.751.751 0 0 1-.018 1.042.751.751 0 0 1-1.042.018l-.97-.97-.97.97a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l.97-.97-.97-.97a.75.75 0 0 1 0-1.06ZM2.5 3.25a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0ZM3.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm9.5 0a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"
      _ => "M1.5 3.25a2.25 2.25 0 1 1 3 2.122v5.256a2.251 2.251 0 1 1-1.5 0V5.372A2.25 2.25 0 0 1 1.5 3.25Zm5.677-.177L9.573.677A.25.25 0 0 1 10 .854V2.5h1A2.5 2.5 0 0 1 13.5 5v5.628a2.251 2.251 0 1 1-1.5 0V5a1 1 0 0 0-1-1h-1v1.646a.25.25 0 0 1-.427.177L7.177 3.427a.25.25 0 0 1 0-.354ZM3.75 2.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm0 9.5a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Zm8.25.75a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Z"
    },
  )
}

///|
/// GitHub's octicons for an issue's state (Peeks.tsx ISSUE_GLYPH).
pub fn peek_issue_glyph(state : String) -> String? {
  let ring = "M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM1.5 8a6.5 6.5 0 1 0 13 0 6.5 6.5 0 0 0-13 0Z"
  let done = "M11.28 6.78a.75.75 0 0 0-1.06-1.06L7.25 8.69 5.78 7.22a.75.75 0 0 0-1.06 1.06l2 2a.75.75 0 0 0 1.06 0l3.5-3.5ZM16 8A8 8 0 1 1 0 8a8 8 0 0 1 16 0Zm-1.5 0a6.5 6.5 0 1 0-13 0 6.5 6.5 0 0 0 13 0Z"
  Some(
    match state {
      "completed" | "closed" => done
      "not_planned" => ring +
        "m9.78-2.22-5.5 5.5a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734l5.5-5.5a.751.751 0 0 1 1.042.018.751.751 0 0 1 .018 1.042Z"
      _ => "M8 9.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z" + ring
    },
  )
}

///|
/// A 16 by 16 path filled in `ink`.
fn peek_glyph_of(d : String, ink : Int64) -> @pixels.Vector {
  {
    w: 16.0,
    h: 16.0,
    layers: [{ d, fill: ink, stroke: 0L, width: 0.0, even_odd: false, sx: 1.0, sy: 1.0, tx: 0.0, ty: 0.0 }],
  }
}

///|
/// GitHub's mark (Peeks.tsx GitHubMark), 16 by 16.
let peek_github_path : String = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"

// ── a file's ──────────────────────────────────────────────

///|
/// A card's parts in a column (`body` makes them in it), 8 apart, across the card: a pull request's, a file's, a
/// chat's.
#callsite(autofill(loc))
pub fn peek_rich_node(parent : @view.View, body : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(rich) {
    style_node(rich, fn() { peek_rich })
    body(rich)
  })
  |> ignore
}

///|
/// A file's head in `parent`: its mark (14, muted; a folder's where `dir`) 6 from its name (one line, 500; a directory's
/// ending in `/`) and when it was written (`ago`: muted, at the end, where it says); its whole `path` under them in the
/// code face, as it is to be shown (a home directory as `~`).
#callsite(autofill(loc))
pub fn peek_file_head_node(
  parent : @view.View,
  name : () -> String,
  dir : () -> Bool,
  path : () -> String,
  ago : () -> String,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(h) {
    style_node(h, fn() { peek_file_head })
    h.box(fn(t) {
      style_node(t, fn() { peek_chat_title })
      icon_node(t, "file", peek_file_icon, By(fn() { theme().p.muted }), name_now=fn() {
        if dir() {
          "folder"
        } else {
          "file"
        }
      })
      |> ignore
      t.box(fn(r) {
        style_node(r, fn() { peek_ref }, in_row=true)
        r.lines_up(Is(Some(@view.Along::Start))) |> ignore
        words_node(r, fn() { if dir() { name() + "/" } else { name() } }, fn() { peek_title }) |> ignore
      })
      |> ignore
      t.show(fn() { ago() != "" }, fn(a) { words_node(a, ago, fn() { peek_meta_words }) |> ignore })
    })
    |> ignore
    peek_mono_node(h, fn() { [@ui.span(path(), mono=true)] }, peek_file_path, loc~)
  })
  |> ignore
}

///|
/// A file's lines, drawn in `parent` itself: each numbered from `start` (34 wide, muted, 8 before the line), the one at
/// `at` on the accent's pale ground, each one line, cut; in the code face at the caption's size, each in the runs
/// `colored` says of it where it says some (a language's colours), plain else.
#callsite(autofill(loc))
pub fn peek_file_lines_node(
  parent : @view.View,
  start : () -> Int,
  words : () -> Array[String],
  at : () -> Int?,
  colored : () -> Array[Array[@ui.Run]],
  loc~ : SourceLoc,
) -> Unit {
  style_node(parent, fn() { peek_file_lines })
  parent.each(fn() { Array::makei(words().length(), fn(k) { k }) }, fn(k) { k }, fn(row, k) {
    let n = fn() { start() + k.get() }
    style_node(row, fn() { if at() == Some(n()) { peek_file_line_at } else { peek_file_line } })
    row.box(fn(no) {
      style_node(no, fn() { peek_file_line_no }, in_row=true)
      peek_mono_node(no, fn() { [@ui.span(n().to_string(), mono=true)] }, peek_file_no, loc~)
    })
    |> ignore
    row.box(fn(r) {
      style_node(r, fn() { peek_ref }, in_row=true)
      peek_mono_node(
        r,
        fn() {
          match colored().get(k.get()) {
            Some(runs) if runs.length() > 0 => runs
            _ => {
              let t = words().get(k.get()).unwrap_or("")
              [@ui.span(if t != "" { t } else { " " }, mono=true)]
            }
          }
        },
        peek_file_code,
        loc~,
      )
    })
    |> ignore
  })
}

///|
/// A file's picture, drawn in `parent` itself: all in its box (180 high, 8 round), fading in once it is decoded for the
/// room it is given (`picture`: its image's key), the hover's ground under it till then.
pub fn peek_file_picture_node(parent : @view.View, picture : () -> String) -> Unit {
  parent.by_room(fn(g, room) {
    g
    .height(Is(Some(peek_file_image_h)))
    .radius(Is(peek_file_image_r))
    .ground(By(fn() {
      let w = room.width()
      let side = if w > peek_file_image_h { w } else { peek_file_image_h }
      // (its decode asked as the card is made, a pointer resting on a link opening it: there by the frame after, as
      // drawn; View::image_ask)
      g.image_ask(picture(), side * g.pixel_scale())
      if g.image_ready(picture(), side * g.pixel_scale()) {
        0L
      } else {
        theme().p.hover
      }
    }))
    .image(By(fn() { Some((picture(), "", peek_image_most)) }))
    .image_contains(Is(true))
    .image_fades(Is(true))
    |> ignore
  })
  |> ignore
}

///|
/// A directory's first entries, drawn in `parent` itself, two to a row, each its mark (12, muted; a folder's for a name
/// ending in `/`) and its name in the code face (without its `/`), cut.
#callsite(autofill(loc))
pub fn peek_file_entries_node(parent : @view.View, entries : () -> Array[String], loc~ : SourceLoc) -> Unit {
  style_node(parent, fn() { peek_file_entries })
  let name = fn(k : Int) { entries().get(k).unwrap_or("") }
  parent.each(fn() { Array::makei((entries().length() + 1) / 2, fn(r) { r }) }, fn(r) { r }, fn(row, r) {
    style_node(row, fn() { peek_file_entry_row })
    row.each(
      fn() {
        let r = r.get()
        Array::makei(if 2 * r + 2 <= entries().length() { 2 } else { entries().length() - 2 * r }, fn(i) { 2 * r + i })
      },
      fn(k) { k },
      fn(e, k) {
        let dir = fn() { name(k.get()).has_suffix("/") }
        style_node(e, fn() { peek_file_entry }, in_row=true)
        icon_node(e, "file", peek_file_entry_icon, By(fn() { theme().p.muted }), name_now=fn() {
          if dir() {
            "folder"
          } else {
            "file"
          }
        })
        |> ignore
        e.box(fn(b) {
          style_node(b, fn() { peek_ref }, in_row=true)
          peek_mono_node(
            b,
            fn() {
              let n = name(k.get())
              [@ui.span(if dir() { n.exact_view(end=n.length() - 1).to_owned() } else { n }, mono=true)]
            },
            peek_file_code,
            loc~,
          )
        })
        |> ignore
      },
    )
  })
}

///|
/// A file's foot in `parent`: what it is in words (`what`, muted), and `copy` (its path to copy) in the card's bottom
/// end corner, concentric with it.
#callsite(autofill(loc))
pub fn peek_file_foot_node(
  parent : @view.View,
  what : () -> String,
  copy : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(f) {
    style_node(f, fn() { peek_file_foot })
    f.box(fn(r) {
      style_node(r, fn() { peek_ref }, in_row=true)
      r.lines_up(Is(Some(@view.Along::Start))) |> ignore
      words_node(r, what, fn() { peek_meta_words }) |> ignore
    })
    |> ignore
    copy(f)
  })
  |> ignore
}

///|
/// Words in the code face (mono's) in `parent`: `runs`, as `style` says them otherwise (its size, ink, one line and cut
/// where it says so).
#callsite(autofill(loc))
fn peek_mono_node(parent : @view.View, runs : () -> Array[@ui.Run], style : @ui.TextStyle, loc~ : SourceLoc) -> Unit {
  // (cut where its line has not the room, else as wide as it is, as an old view's words in a column are: not stretched
  // across it)
  if @ui.style_cut(style) {
    parent.lines_up(Is(Some(@view.Along::Start))) |> ignore
  }
  parent.box(made_for=loc, fn(w) {
    w
    .words_runs(By(runs))
    .words_look(By(fn() { @ui.style_words(style) }))
    .ink(By(fn() { @ui.style_ink(style) }))
    |> ignore
    if @ui.style_cut(style) {
      w.cuts(Is(true)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    } else if @ui.style_fills(style) && !@signals.untracked(fn() { @ui.style_words(style).wrap }) {
      w.allow_ellipsis(Is(true)) |> ignore
    }
  })
  |> ignore
}

// ── a chat's ──────────────────────────────────────────────

///|
/// A chat's head in `parent`: its mark (`mark`, made in a box of its own while `marked`; nothing in its place else, not
/// even the room between), its `title` (what is left of the line, cut) and when it was last active (`ago`, muted, where
/// it says).
#callsite(autofill(loc))
pub fn peek_chat_head_node(
  parent : @view.View,
  title : () -> String,
  marked? : () -> Bool = fn() { false },
  mark? : (@view.View) -> Unit = fn(_) {  },
  ago? : () -> String = fn() { "" },
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(t) {
    style_node(t, fn() { peek_chat_title })
    t.show(marked, mark)
    t.box(fn(r) {
      style_node(r, fn() { peek_ref }, in_row=true)
      r.lines_up(Is(Some(@view.Along::Start))) |> ignore
      words_node(r, title, fn() { peek_title }) |> ignore
    })
    |> ignore
    t.show(fn() { ago() != "" }, fn(a) { words_node(a, ago, fn() { peek_meta_words }) |> ignore })
  })
  |> ignore
}

///|
/// Where a chat is, in `parent` while `shows`: its station's mark (11, muted: `emoji`, `icon`) where `elsewhere`, 4 from
/// `words` (its station's name, that the link is its agent's execution history), one line, cut.
pub fn peek_chat_where_node(
  parent : @view.View,
  shows : () -> Bool,
  elsewhere : () -> Bool,
  emoji : () -> String,
  icon : () -> String,
  words : () -> String,
) -> Unit {
  parent.show(shows, fn(m) {
    style_node(m, fn() { peek_meta })
    m.box(fn(w) {
      style_node(w, fn() { peek_chat_where }, in_row=true)
      w.show(elsewhere, fn(s) {
        station_mark_node(s, emoji, icon, peek_station_mark, fn() { theme().p.muted }, fn() { 0 })
      })
      words_node(w, words, fn() { peek_meta_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// A message a link names, drawn in `parent` itself: who said it and when (`head`, where it says: as wide as it is, cut
/// where it has not the room) over its `words` (six lines at most).
pub fn peek_message_node(parent : @view.View, head : () -> String, words : () -> String) -> Unit {
  parent.show(fn() { head() != "" }, fn(h) {
    h.lines_up(Is(Some(@view.Along::Start))) |> ignore
    words_node(h, head, fn() { peek_meta_words }) |> ignore
  })
  words_node(parent, words, fn() { peek_message }) |> ignore
}

///|
/// A message a link names while it is read: a made-up one's bones (waiting_node's), in `parent`.
pub fn peek_message_bones_node(parent : @view.View) -> Unit {
  waiting_node(parent, fn(bones) {
    words_node(bones, fn() { sample_words(8) }, fn() { peek_meta_words }) |> ignore
    words_node(bones, fn() { sample_words(60) }, fn() { peek_message }) |> ignore
  })
}

///|
/// What a card says of what it shows (a chat's words, three lines at most), in `parent`.
#callsite(autofill(loc))
pub fn peek_excerpt_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> Unit {
  words_node(parent, words, fn() { peek_excerpt }, loc~) |> ignore
}

///|
/// What a card says where it has nothing to show (why not, that it is gone), muted, in `parent`.
#callsite(autofill(loc))
pub fn peek_note_node(parent : @view.View, words : () -> String, loc~ : SourceLoc) -> Unit {
  words_node(parent, words, fn() { peek_note }, loc~) |> ignore
}

// ── a link's card in an agent's words ──────────────────────────────

///|
/// A link's card in `v`: a capsule a file's card's size (236 by 52, on the bubble's ground), its mark in its room
/// (`mark`: an icon's name, 24, muted; none, the room kept), its `title` over its `line` (each as high as its words at
/// least), the title quieter where `gone`; pressed, `press` (where the link leads). Named as a link by its title. Each
/// as it changes.
#callsite(autofill(loc))
pub fn link_card_node(
  v : @view.View,
  mark : () -> String?,
  title : () -> String,
  line : () -> String,
  gone : () -> Bool,
  press : () -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  v.box(made_for=loc, fn(b) {
    style_node(b, fn() { link_card_box })
    presses_node(b, press)
    b.says(By(fn() { Some(@view.said(Link, label=title())) })) |> ignore
    link_mark_node(b, mark)
    link_words_node(b, title, line, gone, in_row=true)
  })
  |> ignore
}

///|
/// A link card's two lines in `v`, in a box of `look` (`in_row`: laid out along a row; across what is left, else as
/// under a screen's preview, `look` its room): its `title` over its `line`, each as high as its words at least, the
/// title quieter where `gone`. Each as it changes.
#callsite(autofill(loc))
pub fn link_words_node(
  v : @view.View,
  title : () -> String,
  line : () -> String,
  gone : () -> Bool,
  in_row? : Bool = false,
  look? : @ui.Style = link_card_words,
  loc~ : SourceLoc,
) -> Unit {
  v.box(made_for=loc, fn(w) {
    style_node(w, fn() { look }, in_row~)
    w.box(fn(l) {
      style_node(l, fn() { link_title_line_node })
      words_node(l, title, fn() { if gone() { link_card_title_gone } else { link_card_title } }) |> ignore
    })
    |> ignore
    w.box(fn(l) {
      style_node(l, fn() { link_line_line_node })
      words_node(l, line, fn() { link_card_line }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A link card's mark in its room, 24, muted, in `v` (`mark`: an icon's name); none, its room kept, while `mark` says
/// none.
#callsite(autofill(loc))
pub fn link_mark_node(v : @view.View, mark : () -> String?, loc~ : SourceLoc) -> Unit {
  v.box(made_for=loc, fn(r) {
    style_node(r, fn() { link_card_mark_box }, in_row=true)
    r.pick(mark, fn(i, name) {
      match name {
        Some(n) => icon_node(i, n, 24.0, By(fn() { theme().p.muted })) |> ignore
        None => ()
      }
    })
  })
  |> ignore
}

// ── their look ──────────────────────────────────────────────

///|
/// How far a hover card's words stand in from its panel's padding (hover_card_node's 10): what reaches out of them to
/// its corners stands out past them that far.
let peek_words_in : Double = 10.0

///|
/// What a card holds as what it shows has it, laid out as a hover card lays out what it holds: 8 apart.
// kept across runs: a value (no field of it changes)
pub let peek_card_part : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// The most pixels a card's picture, a page's icon or a face is asked at (as a chat's things' tiles are).
let peek_image_most : Int = 8192

///|
/// A tile: its thumb and its words, 10 apart, at their tops: the thumb in the card's corner as far from its top as
/// from its side, however many lines its title takes.
// kept across runs: a value (no field of it changes)
let peek_tile : @ui.Style = @ui.css("row w=Full gap=S2_5 align=AStart")

///|
/// Its thumb: 36 square on the hover's ground, what it shows in its middle (20); in the card's corner as far in as makes
/// the small block's corner concentric with the card's there, out past the card's words to there.
// kept across runs: a value (no field of it changes)
let peek_thumb : @ui.Style = peek_thumb_under.then(@ui.style(mt=room_of(peek_thumb_out)))

///|
/// Its thumb under a picture (no corner of the card's there): its top at its title's, out to where the picture's start is.
// kept across runs: a value (no field of it changes)
let peek_thumb_under : @ui.Style = @ui.css("w=S9 h=S9 bg=Hover align=ACenter justify=JCenter clip=true").then(
  @ui.style(radius=small_radius, ml=room_of(peek_thumb_out)),
)

///|
/// How far the thumb stands out of the card's words (the panel's padding and peek_words_in) to be concentric there.
let peek_thumb_out : Double = r_menu - small_corner - panel_pad - peek_words_in

///|
let peek_thumb_mark : Double = 20.0

///|
let peek_thumb_icon : Double = 18.0

///|
/// Its words: its title (two lines at most, 500) over where it goes (12, muted, one line), 1 apart.
// kept across runs: a value (no field of it changes)
let peek_tile_body : @ui.Style = @ui.css("gap=SPx").then(@ui.style(w=grow))

///|
// kept across runs: a value (no field of it changes)
pub let peek_tile_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, w=Full, max_lines=2)

///|
// kept across runs: a value (no field of it changes)
let peek_tile_url : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
/// A page's picture over its tile: 10 over the tile, across what the card's words are.
// kept across runs: a value (no field of it changes)
let peek_with_picture : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
/// The picture: across the card, out past its words on both sides and over them as far as the thumb is in its corner
/// (peek_thumb_out), so it stands as far in from the card's top as from its sides, its corners concentric with the
/// card's however wide the card is.
// kept across runs: a value (no field of it changes)
let peek_picture : @ui.Style = @ui.style(w=Full, mx=room_of(peek_thumb_out), mt=room_of(peek_thumb_out))

///|
/// Its width for its height: 16:9.
let peek_picture_aspect : Double = 16.0 / 9.0

///|
/// Its corner: in the card's top corners, concentric with the card's there, as the tile's thumb.
let peek_picture_r : Double = small_corner

///|
/// A rich card: its meta, its title, its facts, 8 apart.
// kept across runs: a value (no field of it changes)
let peek_rich : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// Its meta: what it is, where it is (taking what is left, cut), when it changed; 8 apart.
// kept across runs: a value (no field of it changes)
let peek_meta : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// A pull request's or an issue's meta, its state's pill first: in the card's top start corner as far from both its
/// edges as makes it concentric with it (capsule_in), out past the panel's padding and the card's words' to there.
// kept across runs: a value (no field of it changes)
let peek_change_meta : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter").then(
  @ui.style(mt=room_of(peek_capsule_in), ml=room_of(peek_capsule_in)),
)

///|
/// How far a capsule 20 high in a card's corner (a state's pill, a fact's, a face) stands from where its words start,
/// out past them: concentric with the card's corner.
let peek_capsule_in : Double = @ui.capsule_in(r_menu, peek_capsule_h) - panel_pad - peek_words_in

///|
/// A capsule's height: a state's, a fact's, a face.
let peek_capsule_h : Double = 20.0

///|
// kept across runs: a value (no field of it changes)
let peek_ref : @ui.Style = @ui.css("clip=true").then(@ui.style(w=grow))

///|
// kept across runs: a value (no field of it changes)
let peek_meta_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let peek_title : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
/// Its facts: in a line that goes on to another, 8 apart across and between its lines; its first (who opened it, or a
/// fact's pill) in the card's bottom start corner, concentric with it as its state is in its top start.
// kept across runs: a value (no field of it changes)
let peek_facts : @ui.Style = @ui.css("row gap=S2 align=ACenter").then(@ui.style(w=grow))

///|
/// Their line (the card's last): out to the card's bottom start corner for its first pill (peek_capsule_in), what
/// copies it at its end.
// kept across runs: a value (no field of it changes)
let peek_facts_line : @ui.Style = @ui.css("row w=Full gap=S2 align=AEnd").then(
  @ui.style(mb=room_of(peek_capsule_in), ml=room_of(peek_capsule_in)),
)

///|
/// What copies it, in the card's bottom end corner as far from both its edges as makes it concentric with it (24
/// across: peek_button_in), its line's foot out past the pills' (peek_capsule_in).
// kept across runs: a value (no field of it changes)
let peek_copy_end : @ui.Style = @ui.style(mr=room_of(peek_button_in), mb=room_of(peek_button_in - peek_capsule_in))

///|
/// Who opened it: their picture (round, a capsule's height) 6 from their name, in the words' colour.
// kept across runs: a value (no field of it changes)
let peek_person : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let peek_avatar : @ui.Style = @ui.css("w=S5 h=S5 radius=Full bg=Line")

///|
let peek_avatar_d : Double = peek_capsule_h

///|
// kept across runs: a value (no field of it changes)
let peek_person_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false)

///|
/// A fact's pill: a capsule 6 in, on the hover's ground; a size's two figures 6 apart, green (the green states' ink, to
/// read on that ground) and red.
// kept across runs: a value (no field of it changes)
let peek_chip : @ui.Style = @ui.css("row h=S5 gap=S1_5 px=S1_5 radius=Full bg=Hover align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let peek_add : @ui.TextStyle = @ui.text_style(size=Meta, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let peek_del : @ui.TextStyle = @ui.text_style(size=Meta, color=Danger, wrap=false)

///|
/// A state's pill: 20 high, full corners to stand concentric in its card's corner, its glyph 6 in.
// kept across runs: a value (no field of it changes)
pub let peek_state : @ui.Style = @ui.css("row h=S5 gap=S1 pl=S1_5 pr=S2 radius=Full align=ACenter")

///|
/// A state's pill with no glyph (how its checks stand): its words 8 in from both ends.
// kept across runs: a value (no field of it changes)
let peek_state_words_only : @ui.Style = @ui.css("row h=S5 gap=S1 px=S2 radius=Full align=ACenter")

///|
let peek_glyph : Double = 12.0

///|
// kept across runs: a value (no field of it changes)
let peek_state_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, wrap=false)

///|
/// A chat's head (fileTitle): its mark, its title (what is left of the line) and its time, 6 apart, in the middle.
// kept across runs: a value (no field of it changes)
let peek_chat_title : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
/// Where a chat is: its station's mark (11) 4 from its name, then that it is the history, one line.
// kept across runs: a value (no field of it changes)
let peek_chat_where : @ui.Style = @ui.css("row gap=S1 align=ACenter clip=true").then(@ui.style(w=grow))

///|
let peek_station_mark : Double = 11.0

///|
/// What it says (excerpt): the card's words, three lines at most.
// kept across runs: a value (no field of it changes)
let peek_excerpt : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=Full, max_lines=3)

///|
/// The message a link names: the card's words, six lines at most.
// kept across runs: a value (no field of it changes)
let peek_message : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, w=Full, max_lines=6)

///|
/// What a card says when it has nothing to show (note): muted.
// kept across runs: a value (no field of it changes)
let peek_note : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, w=Full)

///|
/// A file's head: its title's line over its path, 2 apart.
// kept across runs: a value (no field of it changes)
let peek_file_head : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
let peek_file_icon : Double = 14.0

///|
/// Its path: the caption's size, muted, wrapped anywhere.
// kept across runs: a value (no field of it changes)
let peek_file_path : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, w=Full)

///|
/// Its lines: on the hover's ground, 8 round, 6 over and under them.
// kept across runs: a value (no field of it changes)
let peek_file_lines : @ui.Style = @ui.css("w=Full py=S1_5 radius=Sm bg=Hover clip=true")

///|
/// A line: its number and its words, 8 from its end; the one named on the accent's pale ground.
// kept across runs: a value (no field of it changes)
let peek_file_line : @ui.Style = @ui.css("row w=Full pr=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let peek_file_line_at : @ui.Style = @ui.css("row w=Full pr=S2 align=ACenter bg=AccentBg")

///|
/// Its number: 34 wide (8 of it after it), to its end.
// kept across runs: a value (no field of it changes)
let peek_file_line_no : @ui.Style = @ui.css("pr=S2 align=AEnd").then(@ui.style(w=Fixed(peek_file_no_w)))

///|
let peek_file_no_w : Double = 34.0

///|
// kept across runs: a value (no field of it changes)
let peek_file_no : @ui.TextStyle = @ui.text_style(size=Caption, color=Muted, wrap=false)

///|
/// A line's words, an entry's name: the caption's size, one line, cut.
// kept across runs: a value (no field of it changes)
let peek_file_code : @ui.TextStyle = @ui.text_style(size=Caption, color=Fg, wrap=false, w=Cut)

///|
/// An image's picture: as wide as the card, 180 high at most, contained, 8 round.
let peek_file_image_h : Double = 180.0

///|
let peek_file_image_r : Double = 8.0

///|
/// A directory's entries: two to a row, 12 apart, 2 between rows, 6 by 8 in, on the hover's ground, 8 round.
// kept across runs: a value (no field of it changes)
let peek_file_entries : @ui.Style = @ui.css("w=Full gap=S0_5 py=S1_5 px=S2 radius=Sm bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let peek_file_entry_row : @ui.Style = @ui.css("row w=Full gap=S3")

///|
/// An entry: its mark (12, muted) 5 from its name.
// kept across runs: a value (no field of it changes)
let peek_file_entry : @ui.Style = @ui.css("row gap=S1_25 align=ACenter clip=true").then(@ui.style(w=grow))

///|
let peek_file_entry_icon : Double = 12.0

///|
/// Its foot: what it is in words and its path to copy, in the card's bottom end corner as far from both its edges as
/// makes it concentric with it (capsule_in: the button 24 high), out past the panel's padding and the card's words'.
// kept across runs: a value (no field of it changes)
let peek_file_foot : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter").then(
  @ui.style(mb=room_of(peek_button_in), mr=room_of(peek_button_in)),
)

///|
let peek_button_in : Double = @ui.capsule_in(r_menu, 24.0) - panel_pad - peek_words_in

///|
/// A link's card: a row 236 wide, a capsule as a file's card (a row high, 52), on the chat's bubble ground: its mark,
/// 24, concentric with its round end (14 from its end, its top and its foot), 8 from its words, their end where the
/// other round end begins (file_capsule_words_end).
// kept across runs: a value (no field of it changes)
let link_card_box : @ui.Style = @ui.style(
  row=true,
  w=link_card_w,
  h=file_capsule_h,
  pl=S3_5,
  pr=room_of(file_capsule_words_end),
  gap=S2,
  align=ACenter,
  radius=Full,
  bg=Neutral,
)

///|
/// A mark's box: its own, 24 (the gap to the words the card's).
// kept across runs: a value (no field of it changes)
let link_card_mark_box : @ui.Style = @ui.css("w=S6 h=S6 align=ACenter justify=JCenter")

///|
/// The words beside the mark: what is left across.
// kept across runs: a value (no field of it changes)
let link_card_words : @ui.Style = @ui.css("w=Full")

///|
/// Each of a card's two lines a line high at least (the title's 20, the line's 16), as high as its words where the
/// system's size of words makes them higher (a box holding words grows with them).
// kept across runs: a value (no field of it changes)
let link_title_line_node : @ui.Style = @ui.css("w=Full min_h=S5")

///|
// kept across runs: a value (no field of it changes)
let link_line_line_node : @ui.Style = @ui.css("w=Full min_h=S4")

///|
/// The title (15/20, on one line); quieter for what is no longer there.
// kept across runs: a value (no field of it changes)
let link_card_title : @ui.TextStyle = card_title.then(one_line).then(full_words)

///|
// kept across runs: a value (no field of it changes)
let link_card_title_gone : @ui.TextStyle = link_card_title.then(quiet)

///|
/// What is said of it under its title (11/16, muted, on one line).
// kept across runs: a value (no field of it changes)
let link_card_line : @ui.TextStyle = card_line.then(full_words)
