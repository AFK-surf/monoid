// Picking a passage of a message where it is, in its chat, as both frames do it. With a finger (still.fail apps/android
// chat/screens/MessagePick.kt, ui/Pick.kt; web mobile/pick.tsx): held still on its words it picks the word under it
// and, sliding on, widens it by words (the list holds still meanwhile); lifted, the passage has handles at its ends to
// move, and a bar over it to quote it into the chat's draft, copy it, or take all of the message; a tap anywhere else
// lets go of it, as going back does. With a mouse on the desktop (web Chat.tsx useSelectionQuote, Chat.css.ts
// quotePop): the page's selection (Ctx::selectable), and once it is let go a small dark pill over what is picked, 引用,
// quoting it. How a finger picks is mbui's (@kit.Pick, over @ui.Ctx::words: a message's paragraphs as one text, where
// each is, the passage drawn behind them); what is here is the chat's: which message, its handles', its bar's and its
// pill's look. Where the words go is the frame's (`quote`). A message of a chat's list offers its turn shared as a
// picture too (`share`): on the finger's bar, and in the menu a right click on it opens (share_offered).

///|
/// What is picked in the chat: one passage of one message at a time (mbui's @kit.Pick), the message it is of, who
/// said it and as what (agent | person), what shares its turn (None: it is not a chat's list's), the link to it ("":
/// none); the press something else in the message took (a link's menu, an image quoted: its frame), which picks nothing.
pub(all) struct ChatPick {
  /// the message picked from ("" none)
  mut ts : String
  /// the message to quote, when its picking identity is not its station timestamp ("" means not there yet)
  mut source_ts : String?
  mut author : String
  mut role : String
  mut share : (() -> Unit)?
  mut link : String
  sel : @kit.Pick
  mut taken_at : Int
}

///|
pub let pk : ChatPick = { ts: "", source_ts: None, author: "", role: "", share: None, link: "", sel: @kit.Pick::new(), taken_at: -1 }

///|
/// What is picked as told (picked): one passage at a time, by an identity of its own (`serial`: a number each passage
/// picked takes, never one given again; 0 none), the message it is of and where it ran as it was picked (from, to:
/// a finger's, in its words; -1 a mouse's, the page's selection holding it).
#derive(Eq, Debug)
pub(all) struct Picked {
  serial : Int
  ts : String
  a : Int
  b : Int
}

///|
/// Nothing picked.
pub let picked_none : Picked = { serial: 0, ts: "", a: -1, b: -1 }

///|
/// What is picked, told once as a passage is picked (a new identity, what is known of it then said with it, once) and
/// once as it is let go: what follows picking reads it, never `pk` frame by frame. Where it is made is still a build's
/// (a finger's hold made into words, a mouse's selection read, as the old view builds: kit's Pick, Ctx::selection_box),
/// so it is told as that build makes it.
// kept across runs: nothing picked as a run begins (pick_reset); its identities only count on
pub let picked : @signals.Signal[Picked] = @signals.signal(picked_none, same=fn(a, b) { a == b })

///|
/// The identity the last passage picked took (picked's `serial`).
// kept across runs: only counts on (an identity a run before gave never given again)
let pick_serial : Ref[Int] = Ref(0)

///|
/// A passage of message `ts` picked anew (its metadata in `pk` already), told once: its identity, where it runs.
fn pick_told_new(ts : String, a : Int, b : Int) -> Unit {
  pick_serial.val = pick_serial.val + 1
  picked.set({ serial: pick_serial.val, ts, a, b })
}

///|
/// What was picked let go: told once (nothing told where nothing was picked).
fn pick_told_gone() -> Unit {
  picked.set(picked_none)
}

///|
/// A message right clicked: where (the right click's place, which says the right click it is: sfdesk's
/// context_opened_at), its share, link and complete text, and its row's key, for the window's menu. None once its menu
/// closes, or another right click elsewhere opens it. What shows the menu (built apart from the message: another old
/// view's) follows it: told as another is offered, not as the same one is offered again (its turn's action aside).
// kept across runs: none as a run begins (pick_reset)
pub let share_offered : @signals.Signal[(Double, Double, () -> Unit, String, String, String)?] = @signals.signal_by(
  None,
  same=fn(a, b) {
    match (a, b) {
      (Some(a), Some(b)) => a.0 == b.0 && a.1 == b.1 && a.3 == b.3 && a.4 == b.4 && a.5 == b.5
      (None, None) => true
      _ => false
    }
  },
)

///|
/// The message whose right click's menu is open (its row's key, as share_offered says it; "" none), told by what shows
/// that menu: its row lit meanwhile (message_menu_on).
// kept across runs: none as a run begins (pick_reset)
pub let message_menu : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// The message whose ⋯'s menu is open on the page made as nodes (its key, as its MessageShare says it; "" none), told
/// by its ⋯ as it opens that menu and as the menu goes: the message lit meanwhile, every piece of a long one, whichever
/// piece's ⋯ opened it (message_menu_on).
// kept across runs: none as a run begins (pick_reset)
pub let message_more : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })

///|
/// Whether message `key`'s menu is open: its right click's, or its ⋯'s (share_turn_tool's, message_more's).
pub fn message_menu_on(key : String) -> Bool {
  message_menu.get() == key || message_more.get() == key || @sf.menu_shown(key + "/message-menu")
}

///|
/// The turn of a message right clicked offered (share_offered).
pub fn share_offer(x : Double, y : Double, go : () -> Unit, link : String, words : String, key : String) -> Unit {
  share_offered.set(Some((x, y, go, link, words, key)))
}

///|
/// A message's own items (its ⋯, its right click's): its words, link and turn's picture, where each exists.
pub fn message_items(link : String, words : String, go : () -> Unit) -> Array[@sf.MenuItem?] {
  let items : Array[@sf.MenuItem?] = []
  if words.trim(chars=" \n\t") != "" {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-main.chat.copyMessage"), icon="copy", fn() {
          copy_out(words, said=@sf.t("common.copied"))
        }),
      ),
    )
  }
  if link != "" {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-main.chat.copyMessageLink"), icon="link", fn() {
          copy_out(link, said=@sf.t("common.link.copied"))
        }),
      ),
    )
  }
  items.push(
    Some(
      @sf.menu_item_of(@sf.t("web-main.chat.selectMessages"), icon="check-circle", fn() {
        pick_clear()
        go()
      }),
    ),
  )
  items
}

///|
/// Let go of what is picked.
pub fn pick_clear() -> Unit {
  pk.ts = ""
  pk.sel.clear()
  pick_told_gone()
}

///|
/// A passage picked here as the app is opened so (a fixture's): told as one picked by a hand is.
pub fn pick_told_given() -> Unit {
  if pk.ts != "" {
    pick_told_new(pk.ts, pk.sel.a, pk.sel.b)
  }
}

///|
/// As at the start (tests): nothing picked, no press remembered.
pub fn pick_reset() -> Unit {
  pick_clear()
  pk.source_ts = None
  pk.author = ""
  pk.role = ""
  pk.share = None
  pk.link = ""
  share_offered.set(None)
  message_menu.set("")
  message_more.set("")
  pk.taken_at = -1
  pk.sel.reset()
  picked.set(picked_none)
}

///|
/// Whether words are picked as a desktop's (a mouse's selection over the page, its pill) rather than as a phone's
/// (held, the handles, the bar): by the hand alone, in any layout (@ui.pointing).
pub fn mouse_picks() -> Bool {
  @sf.pointer_rests()
}

///|
/// How much of the accent a picked passage's ground is.
pub let picked_alpha : Double = 0.26

///|
/// How long the pick's bar takes to come (@motion.pop_in's).
pub let pick_bar_in_ms : Double = @motion.pop_ms
