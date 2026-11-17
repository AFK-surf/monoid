// One of the workspace's memory pages (设置 › 记忆 › it), one page in every frame: the global memory a part at a time,
// or a skill (what kind it is and when it is read, its pages to pick between), its text as people read it, on a card
// where the page is narrow (the narrow app's), on the page where it is wide (the web's). Its pages' pills go on in
// lines where the room ends: every one there to pick, none behind a ⋯ nor scrolled out. What it says is the core's
// (looks.ts).

///|
/// The page in view of each memory page, by its station and skill ("" the global memory): picked by its chips.
// kept across runs: said by its chips; memory_doc_reset (sfpages' reset) empties it
let doc_at : @sf.LiveMap[String, Int] = @sf.LiveMap::new()

///|
fn memory_doc_reset() -> Unit {
  doc_at.clear()
}

///|
/// The page (MemoryDoc) made once as nodes in node `v`, laid out by the `width` its frame gives it: `skill` "" the
/// global memory, `at` the part first shown; while the memory is read the first time, the page of a made-up one in its
/// bones; all of it as the core says it now.
pub fn memory_doc_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  address : String,
  skill : String,
  at : Int,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  ignore(here)
  let read = fn() { memory_of(core, address) }
  let title = if skill == "" { @sf.t("web-main.memory.global") } else { skill }
  @sf.page_node(v, fn() { title }, on_back~, frame~, said?, width?, fn() { ["doc"] }, fn(b, _) {
    b.pick(fn() { read().value is None }, fn(p, reading) {
      if reading {
        @sf.waiting_node(
          p,
          fn(s) { doc_body_node(s, "sample", skill, at, fn() { Some(doc_sample(skill)) }) },
          error=fn() {
            let e = read().error
            if e == "" {
              ""
            } else {
              @sf.t("web-main.memory.failed", args=[("error", e)])
            }
          },
        )
      } else {
        doc_body_node(p, address, skill, at, fn() { read().value })
      }
    })
  })
}

///|
/// A memory's page's body (`m`, as the core reads it, as it changes) in node `v`: `skill` "" the global memory, `at` the
/// part first shown. Its head, its pills and its text: the layers of one document, one block of the page, 16 under its
/// head and 20 under its pills; a skill no longer there, said so.
fn doc_body_node(
  v : @view.View,
  address : String,
  skill : String,
  at : Int,
  m : () -> Json?,
) -> Unit {
  let key = "memory-doc/" + address + "/" + skill
  let kv = fn() -> Json? {
    if skill == "" {
      None
    } else {
      let all = items(m(), "skills")
      match all.search_by(fn(x) { text(Some(x), "name") == skill }) {
        Some(i) => Some(all[i])
        None => None
      }
    }
  }
  v.pick(fn() { skill != "" && kv() is None }, fn(p, gone) {
    if gone {
      @sf.words_node(p, fn() { @sf.t("web-main.memory.gone") }, fn() { desk_muted }) |> ignore
      return
    }
    // its pages: the global memory's parts, or the skill's (its SKILL.md, then each other file)
    let pages = fn() {
      if skill == "" {
        items(field(m(), "global"), "sections").map(fn(x) { (text(Some(x), "title"), text(Some(x), "note"), text(Some(x), "text")) })
      } else {
        items(kv(), "pages").map(fn(x) { (text(Some(x), "label"), text(Some(x), "size"), text(Some(x), "text")) })
      }
    }
    let shown_at = fn() {
      let n = pages().length()
      let picked = doc_at.get(key).unwrap_or(at)
      if n == 0 { 0 } else if picked >= n { n - 1 } else if picked < 0 { 0 } else { picked }
    }
    // (its text on a card on a narrow page (the narrow app's), on the page itself on a wide one (the web's))
    let narrow = @sf.look_node(p) is Narrow
    p.box(fn(l) {
      @sf.style_node(l, fn() { md_doc })
      l.box(fn(h) {
        @sf.style_node(h, fn() { md_under_head })
        if skill == "" {
          let global = fn() { field(m(), "global") }
          @sf.words_node(
            h,
            fn() {
              join(
                [
                  @sf.t("web-main.memory.global.when"),
                  text(global(), "size"),
                  text(global(), "whenChanged"),
                ],
                " · ",
              )
            },
            fn() { md_when },
          )
          |> ignore
        } else {
          // what kind it is and when it is read: a card, alone where it is one of the layers (narrow), as the page's
          // cards are where it is wide
          @sf.page_card_node(h, layered=narrow, fn(k) { doc_skill_card_node(k, kv) })
        }
      })
      |> ignore
      l.box(fn(d) {
        @sf.style_node(d, fn() { md_doc })
        // the pages to pick between: pills as wide as their words, going on in lines, the one in view in the ink
        d.show(fn() { pages().length() > 1 }, fn(chips) {
          @sf.style_node(chips, fn() { md_chips })
          // (one tab list: Tab stops at the page in view, ← → choosing along them)
          let page_of = fn(k : String) { pages().get(md_page_at(k)) }
          @sf.tab_bar_node(
            chips,
            fn() { if skill == "" { @sf.t("web-main.memory.global") } else { skill } },
            fn() { Array::makei(pages().length(), fn(n) { n.to_string() }) },
            fn() { shown_at().to_string() },
            fn(k) { doc_at[key] = md_page_at(k) },
            fn(k) { page_of(k).map(fn(x) { x.0 }).unwrap_or("") },
            fn(chip, k, shown) {
              @sf.words_node(chip, fn() { page_of(k).map(fn(x) { x.0 }).unwrap_or("") }, fn() {
                if shown.front() {
                  md_chip_words_on
                } else {
                  md_chip_words
                }
              })
              |> ignore
              chip.show(fn() { page_of(k).map(fn(x) { x.1 }).unwrap_or("") != "" }, fn(o) {
                @sf.words_node(o, fn() { page_of(k).map(fn(x) { x.1 }).unwrap_or("") }, fn() {
                  if shown.front() {
                    md_chip_note_on
                  } else {
                    md_chip_note
                  }
                })
                |> ignore
              })
            },
            look=Chip,
          )
          .grow(Is(1.0))
          |> ignore
        })
        // its text: on a card on a narrow page (the narrow app's), on the page itself on a wide one (the web's)
        let words = fn() {
          let all = pages()
          let w = if all.length() == 0 { "" } else { all[shown_at()].2 }
          if w == "" {
            @sf.t("web-main.memory.empty")
          } else {
            w
          }
        }
        let text_in = fn(t : @view.View) {
          @sf.markdown_node(t, words, size=fn() { @sf.text_scale.base.0 }) |> ignore
        }
        if narrow {
          @sf.page_card_node(d, layered=true, text_in)
        } else {
          text_in(d)
        }
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A skill's card (memory_doc's head): what kind it is and when it is read, as `kv` says it now.
fn doc_skill_card_node(
  k : @view.View,
  kv : () -> Json?,
) -> Unit {
  k.box(fn(w) {
    @sf.style_node(w, fn() { md_when_box })
    @sf.words_node(w, fn() { text(kv(), "kindText") + " · " + @sf.t("web-main.memory.when") }, fn() { md_when_head }) |> ignore
    @sf.words_node(w, fn() { text(kv(), "whenText") }, fn() { md_when }) |> ignore
  })
  |> ignore
}

///|
/// Which page a tab's key (its place, as figures) is.
fn md_page_at(k : String) -> Int {
  let mut n = 0
  for c in k {
    n = n * 10 + (c.to_int() - '0'.to_int())
  }
  n
}

// ── styles ──────────────────────────────────────────────

///|
/// When it is read (memoryWhen: the muted; its head over it, the subtle, 2 apart).
// kept across runs: a value (no field of it changes)
let md_when_box : @ui.Style = @ui.css("w=Full gap=S0_5")

///|
// kept across runs: a value (no field of it changes)
let md_when_head : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Subtle, w=Full)

///|
// kept across runs: a value (no field of it changes)
let md_when : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, w=Full)

///|
/// The pages to pick between (memoryChips: their tab list, 20 over the text, @sf.tab_bar_node's Chip: 30 high, 12 in,
/// round, the card's ground, the hover's under the pointer; the one in view in the ink, its words the page's ground).
// kept across runs: a value (no field of it changes)
let md_chips : @ui.Style = @ui.css("row w=Full pb=S5")

///|
// kept across runs: a value (no field of it changes)
let md_chip_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let md_chip_words_on : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Bg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let md_chip_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let md_chip_note_on : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Subtle, wrap=false)

///|
/// What is under a document's head (its card, the global memory's when): 16 (memoryHead's, memoryWhen's).
// kept across runs: a value (no field of it changes)
let md_under_head : @ui.Style = @ui.css("w=Full mb=S4")

///|
/// Its text with its pills over it: one layer.
// kept across runs: a value (no field of it changes)
let md_doc : @ui.Style = @ui.css("w=Full")

///|
/// A memory made up, for what its page shows while it is read (doc_page in its bones): the global memory's parts, or
/// skill `skill`'s pages, each of a few paragraphs.
fn doc_sample(skill : String) -> Json {
  let words = [24, 40, 16, 32].map(@sf.sample_words).join("\n\n")
  let parts = Json::array(
    [4, 6, 5].map(fn(n) {
      Json::object({
        "title": Json::string(@sf.sample_words(n)),
        "label": Json::string(@sf.sample_words(n)),
        "note": Json::string(@sf.sample_words(3)),
        "size": Json::string(@sf.sample_words(3)),
        "text": Json::string(words),
      })
    }),
  )
  {
    "global": { "size": Json::string(@sf.sample_words(3)), "sections": parts },
    "skills": [{ "name": Json::string(skill), "kindText": Json::string(@sf.sample_words(4)), "whenText": Json::string(@sf.sample_words(16)), "pages": parts }],
  }
}
