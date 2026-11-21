// A sheet's foot of two buttons of nodes (button_node there, in a foot_place_node or not): each its share while both fit;
// one whose words need more than its share as wide as they need, the other giving way, none of them cut; at the
// system's size of words and larger; each where it stood when it stood where the old foot's (each Fill, kept: never
// narrower than what it holds) did.

///|
/// Where each of a sheet's foot's two buttons stands, `first` and `second` their words (the second in a place that comes
/// and goes where `place`), on a phone with a finger, the system's size of words `fs`; and what is cut short or off
/// (squeeze_faults). Closed after, gone.
fn foot_keeps_stood(
  first : String,
  second : String,
  fs : Double,
  place : Bool,
  at? : (Int, Double, Double) = phone,
  beside? : Bool = false,
) -> (Array[String], Array[String]) raise {
  let open = fn(opener : Anchor) {
    let from = if beside { opener } else { Unanchored }
    panel_nodes(
      "一个",
      from~,
      fn(v, _) { words_node(v, fn() { "它说的话" }, fn() { secondary }) |> ignore },
      foot=fn(v, _) {
        button_node(v, fn() { first }, fn() {  }, tone=Ghost) |> ignore
        if place {
          foot_place_node(v, fn() { true }, fn(p) { button_node(p, fn() { second }, fn() {  }, tone=Primary) |> ignore })
        } else {
          button_node(v, fn() { second }, fn() {  }, tone=Primary) |> ignore
        }
      },
    )
  }
  presenters_reset()
  let (platform, w, h) = at
  let t = @ui.Tester::new(
    fn(c) { c.with_theme(ui_theme(), fn() { @ui.old_views_here(c) }) },
    tree=presented_tree(presenting_view(open)),
    w~,
    h~,
    platform~,
  )
  t.check_looks(false)
  if fs != 1.0 {
    t.set_font_scale(fs)
  }
  t.draw()
  t.tap_text("打开")
  t.run_for(@ui.move_most_ms)
  t.leave()
  t.draw()
  let k = fn(v : Double) { (v * 1000.0).round() / 1000.0 }
  let stood = [first, second].map(fn(label) {
    let all = t.all(Button, label~)
    if all.length() == 1 {
      let r = all[0].rect
      "\{label} \{k(r.0)},\{k(r.1)} \{k(r.2)}x\{k(r.3)}"
    } else {
      "\{label}: \{all.length()} of it"
    }
  })
  let cut = t.squeeze_faults()
  close_all_presented()
  t.run_for(@ui.move_most_ms)
  assert_false(presented_drawn(), msg="closed")
  (stood, cut)
}

///|
test "a sheet's foot of nodes: two buttons whose words fit, each its share" {
  let seen : Array[String] = []
  for place in [false, true] {
    for fs in [1.0, 1.3] {
      let at = "place \{place}, words \{fs}"
      let (new, cut) = foot_keeps_stood("取消", "下载", fs, place)
      assert_eq(cut, [], msg=at)
      seen.push("\{at}: \{new.join(" | ")}")
    }
  }
  inspect(seen.join("\n"), content=(
    #|place false, words 1: 取消 20,788 171x32 | 下载 199,788 171x32
    #|place false, words 1.3: 取消 20,788 171x32 | 下载 199,788 171x32
    #|place true, words 1: 取消 20,788 171x32 | 下载 199,788 171x32
    #|place true, words 1.3: 取消 20,788 171x32 | 下载 199,788 171x32

  ))
}

///|
test "a sheet's foot of nodes: one button's words more than its share, it as wide as they need and the other giving way, none cut" {
  let seen : Array[String] = []
  for place in [false, true] {
    for words in [("取消", "添加到此 workspace", 1.3), ("Cancel", "Add to this workspace", 1.3), ("取消", "添加到此 workspace，然后再看一看", 1.0)] {
      let (first, second, fs) = words
      let at = "place \{place}, \{second} at \{fs}"
      let (new, cut) = foot_keeps_stood(first, second, fs, place)
      assert_eq(cut, [], msg=at)
      seen.push("\{at}: \{new.join(" | ")}")
    }
  }
  inspect(seen.join("\n"), content=(
    #|place false, 添加到此 workspace at 1.3: 取消 20,788 138.5x32 | 添加到此 workspace 166.5,788 203.5x32
    #|place false, Add to this workspace at 1.3: Cancel 20,788 109.25x32 | Add to this workspace 137.25,788 232.75x32
    #|place false, 添加到此 workspace，然后再看一看 at 1: 取消 20,788 74x32 | 添加到此 workspace，然后再看一看 102,788 268x32
    #|place true, 添加到此 workspace at 1.3: 取消 20,788 138.5x32 | 添加到此 workspace 166.5,788 203.5x32
    #|place true, Add to this workspace at 1.3: Cancel 20,788 109.25x32 | Add to this workspace 137.25,788 232.75x32
    #|place true, 添加到此 workspace，然后再看一看 at 1: 取消 20,788 74x32 | 添加到此 workspace，然后再看一看 102,788 268x32

  ))
}

///|
test "a sheet's foot of nodes: both buttons' words more than the foot has room for" {
  let seen : Array[String] = []
  for place in [false, true] {
    let (first, second) = ("先取消这一次的添加然后", "添加到此 workspace，然后再看一看")
    let (new, _) = foot_keeps_stood(first, second, 1.3, place)
    seen.push("place \{place}: \{new.join(" | ")}")
  }
  inspect(seen.join("\n"), content=(
    #|place false: 先取消这一次的添加然后 20,748 350x32 | 添加到此 workspace，然后再看一看 20,788 350x32
    #|place true: 先取消这一次的添加然后 20,748 350x32 | 添加到此 workspace，然后再看一看 20,788 350x32

  ))
}

///|
test "a dialog's foot in the middle of a window and a panel's beside what opened it: buttons whose words are long" {
  let seen : Array[String] = []
  for screen in [("dialog", false), ("beside", true)] {
    let (about, beside) = screen
    for place in [false, true] {
      for words in [("取消", "添加到此 workspace，然后再看一看"), ("先取消这一次的添加然后再说", "添加到此 workspace，然后再看一看，再看一看")] {
        let (first, second) = words
        let at = "\{about}, place \{place}, \{second}"
        let (new, _) = foot_keeps_stood(first, second, 1.3, place, at=(0, 800.0, 600.0), beside~)
        seen.push("\{at}: \{new.join(" | ")}")
      }
    }
  }
  inspect(seen.join("\n"), content=(
    #|dialog, place false, 添加到此 workspace，然后再看一看: 取消 260.4,331.3 62.4x32 | 添加到此 workspace，然后再看一看 330.8,331.3 303.2x32
    #|dialog, place false, 添加到此 workspace，然后再看一看，再看一看: 先取消这一次的添加然后再说 382.4,311.3 251.6x32 | 添加到此 workspace，然后再看一看，再看一看 244.8,351.3 389.2x32
    #|dialog, place true, 添加到此 workspace，然后再看一看: 取消 260.4,331.3 62.4x32 | 添加到此 workspace，然后再看一看 330.8,331.3 303.2x32
    #|dialog, place true, 添加到此 workspace，然后再看一看，再看一看: 先取消这一次的添加然后再说 382.4,311.3 251.6x32 | 添加到此 workspace，然后再看一看，再看一看 244.8,351.3 389.2x32
    #|beside, place false, 添加到此 workspace，然后再看一看: 取消 265.6,147.2 62.4x32 | 添加到此 workspace，然后再看一看 24.8,187.2 303.2x32
    #|beside, place false, 添加到此 workspace，然后再看一看，再看一看: 先取消这一次的添加然后再说 76.4,147.2 251.6x32 | 添加到此 workspace，然后再看一看，再看一看 -61.2,187.2 389.2x32
    #|beside, place true, 添加到此 workspace，然后再看一看: 取消 265.6,147.2 62.4x32 | 添加到此 workspace，然后再看一看 24.8,187.2 303.2x32
    #|beside, place true, 添加到此 workspace，然后再看一看，再看一看: 先取消这一次的添加然后再说 76.4,147.2 251.6x32 | 添加到此 workspace，然后再看一看，再看一看 -61.2,187.2 389.2x32

  ))
}
