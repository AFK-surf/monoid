// A device not yet confirmed in the workspace's safe mode (its lock): what it shows in the workspace's place, on every
// screen. Every station of a locked workspace refuses such a device, so its chats would only say they are offline.
// Nothing is asked by itself (the person who will compare the codes asks: 发送批准请求, the core's `lock.pair`); the
// core finds the person's trusted devices, one of them shows a code, it is typed here into six boxes (`lock.pairCode`),
// and how that goes is the lock's `me.pair` (finding, code, checking, wrong, none, failed, done). The shell puts it in
// the page's place while the lock's `me.waiting` says so, or its `me.needsAppText` (a web page nobody can approve there,
// which says only that: @settings.lock_waiting). Made once as nodes of the window's tree: the library's waiting page,
// then the steps as `me.pair` says them, each part bound to what it shows; the code typed into the code field's boxes
// (@ui.code_field_node), sent as it is complete, emptied for the next try where it is refused.

///|
/// The page in `parent`: the shield, 等待批准, what it waits for (who took its person out and whom to ask, where so),
/// then the steps (pair_steps_node); `clear()` of its top is under a bar (@sf.waiting_page_node). A web page nobody can approve here
/// (@settings.lock_needs_app): 请先安装客户端 and the core's words alone, nothing waited for and no trusted device to
/// name. The node.
pub fn lock_wait_node(
  parent : @view.View,
  core : Core,
  here : @settings.Here,
  clear? : () -> Double = fn() { 0.0 },
) -> @view.View {
  @sf.waiting_page_node(
    parent,
    "shield-check",
    fn() {
      @sf.t(
        if @settings.lock_needs_app(core, here.workspace) != "" {
          "web-pages.security.needsAppTitle"
        } else {
          "web-pages.security.waitingTitle"
        },
      )
    },
    fn() {
      match @settings.lock_needs_app(core, here.workspace) {
        // (its person taken out of an upgraded workspace: by whom and when, and whom to ask, the core's `me.outText`;
        // asked again by the steps once added back)
        "" =>
          match lock_out_text(core, here.workspace) {
            "" => @sf.t("web-pages.security.waitingLead", args=[("name", here.name)])
            out => out
          }
        words => words
      }
    },
    fn(col) { pair_steps_node(col, core, fn() { here.workspace }) },
    clear~,
  )
}

///|
/// Who took this device's person out of workspace `ws` and when, and whom to ask, as the core's `lock` says it now
/// (`me.outText`), "" none.
fn lock_out_text(core : Core, ws : String) -> String {
  text(field((core.topic)("lock", { "workspace": Json::string(ws) }).get().value, "me"), "outText")
}

///|
/// Which of the steps shows: the code typed, one being found, or what is so and the request;
/// or, the code approved but no station of the lock having taken it yet, what it waits for (`Waits`); or, a web page
/// nobody can approve here (the core's `me.needsAppText`, said as the page's lead), nothing to ask (`NeedsApp`).
#derive(Eq)
priv enum PairShows {
  Typing
  Finding
  Asked
  Waits
  NeedsApp
}

///|
/// The steps in `col` (on the waiting page; `in_card`: last on 设置 › 安全's card): typing, 输入… over the six boxes,
/// then 正在核对 (turning), or how many tries are left in red, until when the code holds and 重新获取安全码; finding
/// one, turning, 没收到，重新申请 under it while nothing is asked; else what is so, 发送批准请求 under it. Last in each,
/// under its action, the trusted devices it is about (lock_devices_node). On the waiting page each in the middle of
/// its column; `in_card`, from where the card's words start, the action's row reaching into the card's foot corner,
/// concentric with it, where it is last (@sf.foot_reach), only its sides where the devices come under it (their rows
/// alone, no ground of their own: a ground in its foot corner would not follow it).
fn pair_steps_node(col : @view.View, core : Core, ws : () -> String, in_card? : Bool = false) -> Unit {
  let pair = fn() { field(field((core.topic)("lock", { "workspace": Json::string(ws()) }).get().value, "me"), "pair") }
  let me = fn() { field((core.topic)("lock", { "workspace": Json::string(ws()) }).get().value, "me") }
  let state = fn() { text(pair(), "state") }
  let on = fn() { [("workspace", ws())] }
  let asking = fn() { @settings.is_doing(core, ["lock.pair"], on()) }
  let checking = fn() { @settings.is_doing(core, ["lock.pairCode"], on()) || state() == "checking" }
  // (the code approved, no station having taken it yet: the call's pending sentence, "" none)
  let waits : @signals.Signal[String] = @signals.signal("")
  let needs_app = fn() { @settings.lock_needs_app(core, ws()) }
  let shows = fn() {
    match state() {
      _ if needs_app() != "" => NeedsApp
      _ if waits.get() != "" => Waits
      "code" | "wrong" | "checking" => Typing
      "finding" => Finding
      _ if asking() => Finding
      _ => Asked
    }
  }
  // (the devices it dials, the core's rows; typing, those showing the code alone)
  let dialled = fn() { items(pair(), "approvers") }
  let showing = fn() { dialled().filter(fn(d) { flag(Some(d), "showing") }) }
  // (what is typed, kept while the page shows: emptied as a code is refused or a new one asked for)
  let typed = @ui.Field::new()
  col.pick(shows, fn(v, shown) {
    lock_steps_node(v, in_card)
    match shown {
      Typing => {
        lock_note_node(v, fn() { @sf.t("web-pages.security.pairEnter") }, in_card~)
        @ui.code_field_node(
          v,
          typed,
          fn(code) {
            (core.call)("lock.pairCode", { "workspace": Json::string(ws()), "code": Json::string(code) }, fn(r) {
              match r {
                Err(_) => typed.set("")
                // (approved, but no station took it yet: the code put away as on approval, its sentence said)
                Ok(v) if @settings.pending_said(v) != "" => {
                  typed.set("")
                  waits.set(@settings.pending_said(v))
                  (core.say)(@settings.pending_said(v))
                }
                Ok(_) => ()
              }
            })
          },
          label=@signals.untracked(fn() { @sf.t("web-pages.security.pairEnter") }),
          wrong=fn() { state() == "wrong" },
          enabled=fn() { !checking() },
          inks=fn() {
            let th = @ui.tree_theme()
            { digits: th.color(Fg), off: th.color(Muted), edge: th.color(@sf.code_edge), next: th.color(Fg), wrong: th.color(Danger) }
          },
        )
        |> ignore
        v.show(checking, fn(n) { lock_note_node(n, fn() { @sf.t("web-pages.security.pairChecking") }, turning=true, in_card~) })
        v.show(fn() { !checking() }, fn(n) {
          lock_steps_node(n, in_card)
          // (what the core says of it, the device showing the code maybe gone; a core of before says nothing)
          n.show(fn() { state() == "wrong" }, fn(w) {
            @sf.words_node(w, fn() {
              match text(pair(), "error") {
                "" => @sf.t("web-pages.security.pairWrong", args=[("n", count(pair(), "left").to_string())])
                words => words
              }
            }, fn() { lock_failed })
            .words_centered(Is(!in_card))
            |> ignore
          })
          // (how long the code holds, and a new one asked for at any time: the code gone or not read in time)
          n.show(fn() { text(pair(), "untilText") != "" }, fn(u) { lock_note_node(u, fn() { text(pair(), "untilText") }, in_card~) })
          lock_actions_node(n, in_card, showing, fn(a) {
            @sf.button_node(a, fn() { @sf.t("web-pages.security.pairAgain") }, fn() {
              typed.set("")
              @settings.lock_call(core, ws(), "pair", @sf.t("web-pages.security.pairAgain"), [])
            }, tone=Ghost, card_words=in_card)
            |> ignore
          })
        })
        lock_devices_node(v, showing, in_card)
      }
      Finding => {
        lock_note_node(v, fn() { @sf.t("web-pages.security.pairFinding") }, turning=true, in_card~)
        // asked again while it looks: the person opened a trusted device and nothing came up (2026-11-06 the user:
        // 「直接加个没收到重新申请的按钮」)
        v.show(fn() { !asking() }, fn(n) {
          lock_actions_node(n, in_card, dialled, fn(a) {
            @sf.button_node(a, fn() { @sf.t("web-pages.security.pairRetry") }, fn() {
              @settings.lock_call(core, ws(), "pair", @sf.t("web-pages.security.pairRetry"), [])
            }, tone=Ghost, card_words=in_card)
            |> ignore
          })
        })
        lock_devices_node(v, dialled, in_card)
      }
      Waits => lock_note_node(v, fn() { waits.get() }, in_card~)
      // (nobody could answer an ask: no button that asks, the core's words the page's lead; the owner, 2026-11-13: 「开了
      // 安全模式那就需要 app」)
      NeedsApp => ()
      Asked => {
        v.show(fn() { state() == "failed" }, fn(n) {
          @sf.words_node(n, fn() { text(pair(), "error") }, fn() { lock_failed }).words_centered(Is(!in_card)) |> ignore
        })
        v.show(fn() { state() != "failed" }, fn(n) {
          lock_note_node(n, fn() {
            match state() {
              "none" => @sf.t("web-pages.security.pairNone")
              _ => @sf.t(if flag(me(), "unsigned") { "web-pages.security.upgradeNotAsked" } else { "web-pages.security.notAsked" })
            }
          }, in_card~)
        })
        // (none found: which they are, its note having said to open one)
        let asked_devices = fn() { if state() == "none" { dialled() } else { [] } }
        lock_actions_node(v, in_card, asked_devices, fn(a) {
          @sf.button_node(a, fn() { @sf.t("web-pages.security.request") }, fn() {
            @settings.lock_call(core, ws(), "pair", @sf.t("web-pages.security.request"), [])
          }, tone=Primary, card_words=in_card)
          |> ignore
        })
        lock_devices_node(v, asked_devices, in_card)
      }
    }
  })
}

///|
/// What holds some of the steps (`v`): as the page's column lays them out, 14 apart, each as wide as it is, in the
/// middle (wait_column's); `in_card`, from where the card's words start.
fn lock_steps_node(v : @view.View, in_card : Bool) -> Unit {
  @sf.style_node(v, fn() { if in_card { lock_steps_carded } else { lock_steps } })
}

///|
// kept across runs: a value (no field of it changes)
let lock_steps : @ui.Style = @ui.css("w=Full gap=S3_5 align=ACenter")

///|
/// On 设置 › 安全's card: from where the card's words start, 8 apart (the card's own lines', closer than the waiting
/// page's).
// kept across runs: a value (no field of it changes)
let lock_steps_carded : @ui.Style = @ui.css("w=Full gap=S2 align=AStart")

///|
/// What is so (lock_note's): `words()`, a turning ring before it where `turning`; each line in the middle but
/// `in_card`.
fn lock_note_node(parent : @view.View, words : () -> String, turning? : Bool = false, in_card? : Bool = false) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() { lock_note })
    if turning {
      @sf.spinner_node(row, size=lock_spin) |> ignore
    }
    // (each line in the middle: lock_note_words' center; on a card from where its words start)
    @sf.words_node(row, words, fn() { lock_note_words }).words_centered(Is(!in_card)) |> ignore
  })
  |> ignore
}

///|
/// The trusted devices a step is about (`list()`, the core's LockApprover rows) on a quiet card under its action;
/// nothing where the list is empty. A device to a row: its mark (a phone, a computer) and which machine (the user,
/// #4213, 2026-11-10: fewer words, and under the buttons, which matter more and are never pushed out by it). `in_card`
/// (设置 › 安全's): its rows alone, from where the card's words start.
fn lock_devices_node(parent : @view.View, list : () -> Array[Json], in_card : Bool) -> Unit {
  parent.show(fn() { list().length() > 0 }, fn(room) {
    @sf.style_node(room, fn() { if in_card { lock_devices_carded } else { lock_devices } })
    room.box(fn(card) {
      @sf.style_node(card, fn() { if in_card { lock_devices_rows } else { lock_devices_card } })
      // (as wide as its rows, no wider than the steps: a long name goes on in another line)
      card.max_width(Is(Some(lock_devices_most)), within=true) |> ignore
      card.each(fn() { indexed(list()) }, fn(e) { e.0 }, fn(row, e) {
        let d = fn() { Some(e.get().1) }
        let kind = fn() { lock_device_icon(d()) }
        @sf.style_node(row, fn() { lock_device })
        @sf.icon_node(row, @signals.untracked(kind), lock_device_glyph, By(fn() { @sf.theme().p.muted }), name_now=kind) |> ignore
        row.box(fn(name) {
          // (as wide as its words, giving way where the card has not the room: they go on in another line)
          name.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(name, fn() { text(d(), "nameText") }, fn() { lock_device_name }) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
}

///|
/// The actions' row (lock_actions'), what `make` puts in it; `in_card`, last on the card (devices under it: `devices()`
/// says none) into its foot corner, concentric with it, else out to its sides alone (@sf.foot_reach, over_foot_reach).
fn lock_actions_node(
  parent : @view.View,
  in_card : Bool,
  devices : () -> Array[Json],
  make : (@view.View) -> Unit,
) -> Unit {
  parent.box(fn(row) {
    @sf.style_node(row, fn() {
      if !in_card {
        lock_actions
      } else if devices().is_empty() {
        lock_actions.then(@sf.foot_reach(@sf.button_height()))
      } else {
        lock_actions.then(@sf.over_foot_reach(@sf.button_height()))
      }
    })
    make(row)
  })
  |> ignore
}

///|
/// What is so (waitingNote: a turning ring 8 before it, muted, the meta's size); why it failed (waitingFailed: red).
// kept across runs: a value (no field of it changes)
let lock_note : @ui.Style = @ui.css("row gap=S2 align=ACenter")
///|
// kept across runs: a value (no field of it changes)
let lock_note_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true)
///|
// kept across runs: a value (no field of it changes)
let lock_failed : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Danger, center=true)
///|
let lock_spin : Double = 12.0
///|
/// The trusted devices it dials: their card's place, in the middle under the step's action.
// kept across runs: a value (no field of it changes)
let lock_devices : @ui.Style = @ui.css("w=Full align=ACenter")
///|
/// Their card: a quiet ground over whatever it is on (the page, 设置 › 安全's card), 16 and 12 in, its rows 12 apart;
/// as wide as its rows, no wider than the steps (lock_devices_most, and the room there is).
// kept across runs: a value (no field of it changes)
let lock_devices_card : @ui.Style = @ui.css("px=S4 py=S3 gap=S3 radius=Xl bg=Tint").then(@ui.style(max_w=Fixed(lock_devices_most)))
///|
let lock_devices_most : Double = 412.0
///|
/// A device's row: its mark, 12, which machine it is, from the card's start.
// kept across runs: a value (no field of it changes)
let lock_device : @ui.Style = @ui.css("row gap=S3 align=ACenter")
///|
// kept across runs: a value (no field of it changes)
let lock_device_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)
///|
let lock_device_glyph : Double = 18.0
///|
/// A device's mark by what the core says it is (LockApprover `kind`): a phone, else a computer.
fn lock_device_icon(d : Json?) -> String {
  if text(d, "kind") == "phone" {
    "phone"
  } else {
    "monitor"
  }
}
///|
/// 发送批准请求's row (actions: 10 apart).
// kept across runs: a value (no field of it changes)
let lock_actions : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")
