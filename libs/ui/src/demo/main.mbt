// The prototype's demo: a chat screen with 10,000 messages in a virtual
// list (`View::scrolls_window`) and a header bar.

///|
struct Msg {
  author : Int
  text : String
  time : String
}

///|
let names : Array[String] = ["Ada", "林小雨", "Grace", "陈默", "Linus", "王珂"]

///|
let colors : Array[Int64] = [
  0xFF9F0AFFL, 0x30D158FFL, 0x0A84FFFFL, 0xBF5AF2FFL, 0xFF375FFFL, 0x64D2FFFFL,
]

///|
let phrases : Array[String] = [
  "好的，我晚点看一下这个 PR。",
  "The layout pass is about 0.3 ms for this screen.",
  "输入法的候选框现在会跟着光标走了 🎉",
  "Can you check whether the list keeps its position when rows grow?",
  "我把滚动的惯性改成了指数衰减，手感接近系统的。",
  "MoonBit compiles this whole app in under a second.",
  "周末一起去爬山吗？天气预报说是晴天 ☀️",
  "Merged. Thanks for the quick fix!",
  "这段文字故意写得比较长，用来测试自动换行：中文可以在任意两个字之间断开，English words should only break at spaces, and mixed 中英文 text should wrap naturally without overflowing the bubble.",
  "👍",
  "Let's ship it after the benchmark looks good on the iPhone simulator.",
  "收到",
  "家人们谁懂啊，这个 bug 只在周五下午出现 😂",
  "Line one\nLine two after a hard break",
]

///|
fn make_messages(n : Int) -> Array[Msg] {
  let out = []
  let mut seed = 12345
  for i in 0..<n {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    let a = seed % names.length()
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    let p = seed % phrases.length()
    let mins = i / 3
    let hh = 9 + mins / 60 % 12
    let mm = mins % 60
    let time = "\{hh}:\{if mm < 10 { "0" } else { "" }}\{mm}"
    out.push({ author: a, text: phrases[p], time })
  }
  out
}

///|
fn demo_look(size : Double, weight? : Int = 400, wrap? : Bool = true) -> @view.WordsLook {
  { size, weight, line: 0.0, wrap, tracking: Points(0.0), balance: false, max_lines: 0 }
}

///|
fn message_row(parent : @view.View, m : Msg) -> Unit {
  let mine = m.author == 0
  parent.box(fn(row) {
    row
    .row(Is(true))
    .padding(Is((16.0, 6.0, 16.0, 6.0)))
    .gap(Is(10.0))
    .lines_up(Is(Some(Start)))
    |> ignore
    row.box(fn(av) {
      av
      .width(Is(Some(36.0)))
      .height(Is(Some(36.0)))
      .radius(Is(18.0))
      .ground(Is(colors[m.author]))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      |> ignore
      av.words(Is(names[m.author][0:1].to_owned()), ink=0xFFFFFFFFL, look=demo_look(15.0, weight=600, wrap=false))
      |> ignore
    })
    |> ignore
    row.box(fn(col) {
      col.grow(Is(1.0)).gap(Is(4.0)).lines_up(Is(Some(Start))) |> ignore
      col.box(fn(meta) {
        meta.row(Is(true)).gap(Is(8.0)) |> ignore
        meta.words(Is(names[m.author]), look=demo_look(13.0, weight=600, wrap=false)) |> ignore
        meta.words(Is(m.time), ink=0x8E8E93FFL, look=demo_look(12.0, wrap=false)) |> ignore
      })
      |> ignore
      col.box(fn(bubble) {
        bubble
        .padding(Is((12.0, 8.0, 12.0, 8.0)))
        .radius(Is(14.0))
        .ground(Is(if mine { 0x0A84FFFFL } else { 0xFFFFFFFFL }))
        |> ignore
        bubble.words(
          Is(m.text),
          ink=if mine { 0xFFFFFFFFL } else { 0x1D1D1FFFL },
          look=demo_look(15.0),
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
fn demo_tree(root : @view.View) -> Unit {
  let msgs = make_messages(10000)
  let keys : @signals.Signal[Array[Int]] = @signals.signal(Array::makei(msgs.length(), fn(i) { i }))
  let scroll = @view.Scroll::list()
  root.grow(Is(1.0)).ground(Is(0xF5F5F7FFL)) |> ignore
  // header
  root.box(fn(head) {
    head
    .row(Is(true))
    .padding(Is((16.0, 10.0, 16.0, 10.0)))
    .gap(Is(12.0))
    .lines_up(Is(Some(Middle)))
    .ground(Is(0xFFFFFFFFL))
    |> ignore
    head.words(Is("MoonBit UI"), look=demo_look(17.0, weight=700, wrap=false)) |> ignore
    head.box(fn(sp) { sp.grow(Is(1.0)) |> ignore }) |> ignore
    head.words(Is("\{msgs.length()} 条"), ink=0x8E8E93FFL, look=demo_look(12.0, wrap=false)) |> ignore
  })
  |> ignore
  root.box(fn(line) { line.height(Is(Some(1.0))).ground(Is(0xE5E5EAFFL)) |> ignore }) |> ignore
  root.box(fn(list) {
    list
    .grow(Is(1.0))
    .scrolls_window(
      scroll,
      fn() { keys.get() },
      fn(row, i) { message_row(row, msgs[i]) },
      est=64.0,
      from_end=true,
    )
    |> ignore
  })
  |> ignore
}

///|
fn main {
  @ui.run("MoonBit UI 原型", demo_tree, theme=fn() { @ui.Theme::ios_light() })
}
