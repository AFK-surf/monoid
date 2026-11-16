// A tone's ground (green_bg, red_bg, accent_bg…: a pill's, a mention's) seen on every ground of its palette, and its
// ink read on it (mbui ui/contrast.mbt): 1.25 to 1 off what it lies on, as what is drawn to be seen; 4.5 to 1 for
// its words. Grounds fitted to the page alone, opaque, were 1.0 to 1.1 off a card in the dark (2026-10-27).

///|
test "tones: each tone's ground seen and its ink read on every ground of every palette" {
  let wrong : Array[String] = []
  for p in [("light", light_palette), ("dark", dark_palette), ("web light", web_light), ("web dark", web_dark)] {
    let (name, pal) = p
    let grounds = [
      ("page", pal.bg),
      ("canvas", pal.canvas),
      ("raised", pal.raised),
      ("sidebar", pal.sidebar),
      ("list", pal.list),
      ("selected", pal.selected),
      ("paper", pal.paper),
      ("card", pal.card),
      ("card2", pal.card2),
      ("chip", pal.chip),
    ]
    let tones = [
      ("green", pal.green_bg, pal.green_ink),
      ("blue", pal.blue_bg, pal.blue),
      ("amber", pal.amber_bg, pal.warn_ink),
      ("red", pal.red_bg, pal.red),
      ("accent", pal.accent_bg, pal.accent_text),
    ]
    for g in grounds {
      for tone in tones {
        let laid = over(g.1, tone.1)
        let seen = @ui.contrast_ratio(laid, g.1)
        let read = @ui.contrast_ratio(tone.2, laid)
        if seen < 1.25 {
          wrong.push("\{name}: \{tone.0}'s ground on the \{g.0} \{seen}:1, under 1.25")
        }
        if read < 4.5 {
          wrong.push("\{name}: \{tone.0}'s ink on its ground on the \{g.0} \{read}:1, under 4.5")
        }
      }
    }
  }
  if wrong.length() > 0 {
    fail(wrong.join("\n"))
  }
}

///|
test "tones: secondary emphasis band and enclosed surfaces keep contrast and hierarchy across light and dark" {
  let wrong : Array[String] = []
  for
    p in [
      ("light", light_palette),
      ("dark", dark_palette),
      ("web light", web_light),
      ("web dark", web_dark),
    ] {
    let (name, pal) = p
    let flash = over(pal.bg, pal.secondary_bg)
    let hover = over(pal.bg, pal.hover)
    if @ui.contrast_ratio(flash, pal.bg) < 1.15 {
      wrong.push("\{name}: secondary_bg on bg \{@ui.contrast_ratio(flash, pal.bg)}:1, under 1.15")
    }
    if (pal.secondary_bg >> 8) == (pal.neutral_bg >> 8) ||
      (pal.secondary_bg >> 8) == (pal.hover >> 8) ||
      (pal.secondary_bg >> 8) == (pal.line >> 8) {
      wrong.push("\{name}: secondary_bg shares RGB prefix with neutral_bg, hover or line")
    }
    for b in [("secondary", flash), ("hover", hover)] {
      let (bname, band) = b
      if @ui.contrast_ratio(pal.text, band) < 4.5 {
        wrong.push("\{name}: text on \{bname} band \{@ui.contrast_ratio(pal.text, band)}:1, under 4.5")
      }
      if @ui.contrast_ratio(pal.muted, band) < 4.5 {
        wrong.push("\{name}: muted on \{bname} band \{@ui.contrast_ratio(pal.muted, band)}:1, under 4.5")
      }
    }
    // Neutral surfaces (`neutral_bg`, `hover`) stacked over the secondary emphasis band keep AA contrast and step apart
    for
      n in [
        ("stacked neutral bubble/card", over(flash, pal.neutral_bg)),
        ("stacked hover notice", over(flash, pal.hover)),
      ] {
      let (nname, surf) = n
      if @ui.contrast_ratio(pal.muted, surf) < 4.5 {
        wrong.push("\{name}: \{nname} muted \{@ui.contrast_ratio(pal.muted, surf)}:1, under 4.5")
      }
      if surf == flash {
        wrong.push("\{name}: \{nname} collapses into secondary_bg band")
      }
    }
    // Chromatic surfaces backed by `over(pal.bg, token)` keep full AA contrast and never muddy over `secondary_bg`
    for
      s in [
        ("red notice", over(pal.bg, pal.red_bg), pal.red),
        ("green chip", over(pal.bg, pal.green_bg), pal.green_ink),
        ("blue chip", over(pal.bg, pal.blue_bg), pal.blue),
      ] {
      let (sname, surf, ink) = s
      if @ui.contrast_ratio(ink, surf) < 4.5 {
        wrong.push("\{name}: \{sname} ink \{@ui.contrast_ratio(ink, surf)}:1, under 4.5")
      }
      if surf == flash {
        wrong.push("\{name}: \{sname} collapses into secondary_bg band")
      }
    }
  }
  if wrong.length() > 0 {
    fail(wrong.join("\n"))
  }
}
