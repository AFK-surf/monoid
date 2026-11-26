// A chat's message on the desktop (still.fail web/src/Chat.tsx MessageRow, MineMessage, OthersMessage, SystemNotice,
// BlockedLine, AgentAvatar, MessageAvatar, Quotes, PersonWords, MineBubble, ProseWithFiles, SentElsewhere; Chat.css.ts,
// styles/conversation.css.ts, styles/chat.css.ts): the viewer's own on the right in its bubble; still.fail's own a
// pill across the chat; anyone else's with its picture out in the margin before its name and time, what it quotes, its
// words (an agent's as Markdown with the files it places in it) and its files (message_files.mbt). How a notice is
// said, which files a text places and what is the viewer's are the core's (the chat view's `notice`, `placed`, `mine`).

///|
/// A message row drawn as nodes (`mine_said_node`, `person_said_node`, or `agent_said_node`), for standalone tests.
pub fn message_row_node(
  parent : @view.View,
  src : Source,
  here : MessageNodeHere,
  m : () -> Message,
  core? : @settings.Core? = None,
) -> Unit {
  let now = @signals.untracked(m)
  let key = fn() { "m:" + m().ts }
  let side = fn() { 0.0 }
  let top = fn() { 0.0 }
  if now.mine {
    mine_said_node(parent, src, here, key, side, top, m) |> ignore
  } else if now.author_kind == "person" {
    person_said_node(parent, src, here, key, side, top, m) |> ignore
  } else {
    agent_said_node(parent, src, here, key, side, top, m, core~) |> ignore
  }
}

///|
/// Where a message is shown: its chat (its station, its session, its view), and, in a list, how that list goes to a
/// message (by its seq, and the passage of it a quote's card pressed quoted: lit alone there); None out of one (a letter, a decision's). `inline`: no margin for
/// the pictures, each over its head's start. `gutter`: the
/// room beside the words either side that is only the page's margin (`--list-gutter`: a list's sides, narrow or wide,
/// its pictures out in it standing by their heads' line; none out of a list), which the message's own tables scroll
/// out over to the pane's edges. In its chat's list (`list`), how it moves there: its list's turns (what it asks
/// closes in one), its messages out of avatars (by the chat's key), the words sent flying to this row.
pub(all) struct MessageHere {
  station : String
  session : String
  view : ChatView
  go : ((String, String) -> Unit)?
  inline : Bool
  gutter : Double
  /// the core as the settings' pages have it, over the chat's workspace (a login's card, a vault request's answer);
  /// None where nothing is answered (a letter's)
  core : Core?
}

///|
/// The row's identity stays the outbox entry's when the sent message takes its place.
fn message_place(m : Message) -> String {
  if m.outgoing != "" { "o:" + m.outgoing } else { "m:" + m.ts }
}

///|
/// The runtime an agent's mark is drawn for: the one it says, Claude's where it says none (an agent's picture in a chat,
/// a chat's outline's row).
fn agent_runtime(runtime : String) -> String {
  if runtime != "" {
    runtime
  } else {
    "claude"
  }
}

///|
/// What a link of message `m` is to, as the core says (each link's `to`): of a person's words' runs, or of an agent's
/// Markdown (read as the row is, as its words are).
fn link_to_in(m : Message) -> (String) -> @sf.LinkTo {
  let links = @sfbase.message_links_to(m)
  fn(href) { links.get(href).unwrap_or(@sf.no_link_to) }
}

///|
/// The title the core says with message `m` of the chat a link of its written bare names (its `chats`).
fn chat_title_of(m : Message) -> (String) -> String? {
  fn(href) { m.linked(href).map(fn(l) { l.title }) }
}

///|
/// Whether a file is drawn as a visualization where its message places it: an HTML one (PlacedFile, kindOf).
fn is_viz(name : String) -> Bool {
  let n = name.to_lower()
  n.has_suffix(".mbui") || n.has_suffix(".wasm") || n.has_suffix(".html") || n.has_suffix(".htm")
}

///|
/// What a notice's action after its pill does: 取消 the capacity retry it announced while that waits (`session.cancelRetry`),
/// or 重试 the failed turn it is about while that is where its agent stands (`session.retry`, as a reply would), or
/// 重新分配账号 where that turn's allowance showed a limit (`session.reassign`: on to another account); as (the agent's
/// session, the action's words, the call), None for none.
fn notice_after(m : Message) -> (String, String, String)? {
  if m.notice_retry_session != "" {
    Some((m.notice_retry_session, @sf.t("common.cancel"), "session.cancelRetry"))
  } else if m.notice_again_session != "" {
    Some((m.notice_again_session, @sf.t("common.retry"), "session.retry"))
  } else if m.notice_reassign_session != "" {
    Some((m.notice_reassign_session, @sf.t("common.reassignAccount"), "session.reassign"))
  } else {
    None
  }
}


///|
/// Notices opened (all their words and their time), by message: what a notice's row reads as it is made, as it changes
/// (notice_said_node's `opened`).
// kept across runs: let go as the app begins anew (message_reset)
let notices_open : @sf.LiveMap[String, Bool] = @sf.LiveMap::new()

///|
/// Whether a runtime is being installed on `station` (`software.update` by its id).
fn install_busy(src : Source, station : String, i : Install) -> Bool {
  core_doing(src, ["software.update"], [("station", station), ("id", i.runtime)])
}

///|
/// Installs on `station` the runtime a notice or a waiting message says it lacks (`software.update`).
fn install_runtime(src : Source, station : String, i : Install) -> Unit {
  act(src, i.action, "", "software.update", { "station": Json::string(station), "id": Json::string(i.runtime) })
}

///|
/// The file of a message's `files` that is a quote's own (fileOf): the one it names.
fn quote_file(q : Quote, files : Array[Attachment]) -> Attachment? {
  if q.file == "" {
    return None
  }
  files.iter().find_first(fn(a) { a.name == q.file })
}

///|
/// A message's files but those shown in its quotes' cards (besideQuotes).
fn beside_quotes(quotes : Array[Quote], files : Array[Attachment]) -> Array[Attachment] {
  let own = quotes.filter_map(fn(q) { if q.file == "" { None } else { Some(q.file) } })
  if own.length() == 0 {
    files
  } else {
    files.filter(fn(a) { !own.contains(a.name) })
  }
}

///|
/// A message's words (styles/conversation.css.ts msg, markdown): 14, on lines 1.65 (a person's plain words 1.55: both
/// the scale's 22 here; a time's 11 its 18).
pub let body_size : Double = 14.0

///|
/// A picture in a chat (msgAvatar): 18 round; an agent's mark 12 in it.
let avatar_side : Double = 18.0

///|
let agent_mark_side : Double = 12.0

///|
/// A place's mark on a picture's corner (msgAvatarSlack): 9 in its 14.
let place_corner_side : Double = 9.0

///|
/// The viewer's bubble's sides.
let bubble_side : Double = 14.0

///|
/// How far a bubble's words are in from its top (`bubble`'s py, S2).
let bubble_top : Double = 8.0

///|
/// A message's spinner, small (Spinner inline).
let waiting_spin : Double = 12.0


///|
/// Where a message goes, its route's mark (14) and a place's mark (12).
let route_icon : Double = 14.0

///|
let route_mark : Double = 12.0

///|
/// Someone else's message (msgRow, msgMain): its words the column's width, 4 apart.
// kept across runs: a value (no field of it changes)
let msg_row : @ui.Style = @ui.css("w=Full")

///|
/// Keep the header actions clear of the preceding message's time at the same edge.
// kept across runs: a value (no field of it changes)
let msg_row_share : @ui.Style = @ui.css("w=Full mt=S1_5")

///|
/// msg_main's gap (S1): its head, its words, its files and what it asks 4 apart.
let msg_gap : Double = 4.0

///|
// kept across runs: a value (no field of it changes)
let msg_main : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let msg_main_share : @ui.Style = @ui.css("w=Full gap=S1")

///|
/// Its head (msgHead): 24 high at least, its name, route and time 6 apart.
// kept across runs: a value (no field of it changes)
let msg_head : @ui.Style = @ui.css("row w=Full min_h=S6 gap=S1_5 align=ACenter")

///|
/// Its head's line's height (S6, msg_head's and msg_head_inline's least): what goes beside it is on its middle.
let head_line_h : Double = 24.0

///|
/// An inline head (inlineHeads msgHead): in past the picture (25: its 18 and 7); where it went on a line of its own.
// kept across runs: a value (no field of it changes)
let msg_head_inline : @ui.Style = @ui.style(row=true, w=Full, min_h=S6, pl=@sf.message_head_in, gap=S1_5, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let msg_route_line : @ui.Style = @ui.css("row w=Full")

///|
// kept across runs: a value (no field of it changes)
let msg_avatar_inline : @ui.Style = @ui.style(pt=@sf.message_avatar_down)

///|
/// Its picture out in the margin (align.ts columns.avatar: 29 before the words, 3 down), held 8 under the pane's top
/// (sticky): under the chat's bar (45) and 8 more.
// kept across runs: a value (no field of it changes)
let msg_avatar_room : @ui.Style = @ui.style(pt=@sf.message_avatar_down, ml=@sf.message_avatar_out)

///|
let avatar_held_at : Double = 53.0

///|
/// A name (msgHead msgName): 13 in 600, the accent's ink, 240 at most; the accent itself under the pointer.
// kept across runs: a value (no field of it changes)
pub let msg_name_room : @ui.Style = @ui.style(w=Cut, max_w=@sf.name_max)

///|
// kept across runs: a value (no field of it changes)
pub let msg_name : @ui.TextStyle = @ui.text_style(size=Meta, weight=Semibold, leading=L5, color=AccentText, wrap=false, w=Cut)


///|
/// A time (msgTime): 11, muted.
// kept across runs: a value (no field of it changes)
let msg_time : @ui.TextStyle = @ui.text_style(size=Caption, leading=L5, color=Muted, wrap=false)

///|
/// The viewer's message (msgMine): at the column's end, 4 apart.
// kept across runs: a value (no field of it changes)
let mine_column : @ui.Style = @ui.css("w=Full gap=S1 align=AEnd")

///|
/// Its bubble (msgMine msgBubble): 8 by 14 in, 18 round, the neutral ground.
// kept across runs: a value (no field of it changes)
let bubble : @ui.Style = @ui.css("px=S3_5 py=S2 radius=Xl2 bg=Neutral")

///|
/// How far the bubble's words are in from its top and its foot (bubble's S2).
let bubble_in_y : Double = 8.0

///|
/// That its agents have yet to take it (msgWaiting): a spinner and the words 5 apart.
// kept across runs: a value (no field of it changes)
let msg_waiting : @ui.Style = @ui.css("row gap=S1_25 align=ACenter")

///|
/// An agent's picture (msgAvatarAgent): 18 round on the neutral ground, its mark in the middle.
// kept across runs: a value (no field of it changes)
let agent_avatar_ground : @ui.Style = @ui.css("w=S4_5 h=S4_5 radius=Full bg=Neutral align=ACenter justify=JCenter")

///|
/// An agent's picture ringed on its working line (no neutral disc inside the outer ring): 18 across, its mark in the middle.
// kept across runs: a value (no field of it changes)
let agent_avatar_bare : @ui.Style = @ui.css("w=S4_5 h=S4_5 align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let person_avatar_room : @ui.Style = @ui.css("w=S4_5 h=S4_5")

///|
/// A place's mark on its corner (msgAvatarSlack): 14 round, 6 past the picture's right and foot, on the list's ground
/// with a line round it.
// kept across runs: a value (no field of it changes)
let place_corner_room : @ui.Style = @ui.css("w=Full h=Full align=AEnd justify=JEnd")

///|
// kept across runs: a value (no field of it changes)
let place_corner_mark : @ui.Style = @ui.css((
  #|w=S3_5 h=S3_5 radius=Full bg=Bg border=B1 border_color=Line align=ACenter justify=JCenter
)).then(@sf.outset_end(6.0)).then(@sf.outset_bottom(6.0))

///|
/// A notice (msgSystem): across the chat, in its middle, its time 4 under it once opened.
// kept across runs: a value (no field of it changes)
let notice_across : @ui.Style = @ui.css("w=Full gap=S1 align=ACenter")

///|
/// A retry's own action follows the notice; its text gives way before the button.
// kept across runs: a value (no field of it changes)
let notice_with_action : @ui.Style = @ui.css("row max_w=Full align=ACenter")

///|
/// A run changed to another runtime or model, on its line: each side after its mark, what it ran on left out where the
/// line has not the room (system_notice's).
// kept across runs: a value (no field of it changes)
let notice_sides : @ui.Style = @ui.css("row align=ACenter gap=S1")

///|
/// A part of it: what it ran on and the arrow, or 换成 in its place.
// kept across runs: a value (no field of it changes)
let notice_sides_part : @ui.Style = @ui.css("row align=ACenter gap=S1")


///|
/// Its words closed (msgSystemBox markdown): their size and their lines', its Markdown's too.
// kept across runs: a value (never changed)
let notice_size : @ui.TextSize = Meta

///|
// kept across runs: a value (never changed)
let notice_leading : @ui.Leading = L7

///|
/// Its words about a profile (one line closed).
// kept across runs: a value (no field of it changes)
let notice_words : @ui.TextStyle = @ui.text_style(size=notice_size, leading=notice_leading, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let notice_words_open : @ui.TextStyle = @ui.text_style(size=notice_size, leading=notice_leading)

///|
/// What failed said of it, under its words when opened: smaller, in the code face, wrapping.
// kept across runs: a value (no field of it changes)
let notice_detail : @ui.TextStyle = @ui.text_style(size=Caption)

///|
// kept across runs: a value (no field of it changes)
let notice_copy_room : @ui.Style = @ui.css("row")

///|
// kept across runs: a value (no field of it changes)
let notice_act : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let notice_act_failed : @ui.TextStyle = notice_act.then(@ui.text_style(color=Danger))

///|
/// A blocked line (blocked): at the column's end, 4 apart, wrapping; red while stuck; at 60% while installing.
// kept across runs: a value (no field of it changes)
let blocked_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let blocked_words : @ui.TextStyle = @ui.text_style(size=Caption, leading=L5, color=Muted)

///|
// kept across runs: a value (no field of it changes)
let blocked_words_stuck : @ui.TextStyle = blocked_words.then(@ui.text_style(color=Danger))

///|
// kept across runs: a value (no field of it changes)
let blocked_dot : @ui.TextStyle = @ui.text_style(size=Caption, leading=L5, color=Muted, wrap=false)

///|
/// Installing (blockedAction): a word in the text's ink, 600, underlined under the pointer.
// kept across runs: a value (no field of it changes)
let blocked_act : @ui.TextStyle = @ui.text_style(size=Caption, leading=L5, weight=Semibold, color=Fg, wrap=false)

///|
/// A message's quote cards (quoteCards): one under another 4 apart, at its end when it is the viewer's.
// kept across runs: a value (no field of it changes)
let quote_cards : @ui.Style = @ui.css("w=Full gap=S1 align=AStart")

///|
/// The viewer's: as wide as the widest of them needs, at most as its bubble may be (mine_most), at the column's end
/// over it, as their message is one column there (msgMine: the web's quoteCards justified to its end).
// kept across runs: a value (no field of it changes)
let quote_cards_end : @ui.Style = @ui.css("gap=S1")

///|
/// Where it went (msgRoute): its mark in the accent, the words muted, the place, 6 apart.
// kept across runs: a value (no field of it changes)
let msg_route : @ui.Style = @ui.css("row gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let route_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
/// The place: its mark and its name, 12 in 500, 1 by 6 in, 6 round on the neutral ground; a
/// link's the hover ground under the pointer.
// kept across runs: a value (no field of it changes)
let route_place : @ui.Style = @ui.css("row px=S1_5 py=SPx gap=S1 radius=Md bg=Neutral align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let route_place_link : @ui.Style = route_place.then(@ui.css("radius=Full"))

///|
// kept across runs: a value (no field of it changes)
let route_place_hot : @ui.Style = route_place_link.then(@ui.css("bg=Hover"))

///|
// kept across runs: a value (no field of it changes)
let route_place_words : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=Fg, leading=L5, wrap=false)

///|
/// Sending it failed (Pill tone red).
// kept across runs: a value (no field of it changes)
let route_failed : @ui.Style = @ui.css("px=S1_5 py=SPx radius=Md bg=DangerBg")

///|
// kept across runs: a value (no field of it changes)
let route_failed_words : @ui.TextStyle = @ui.text_style(size=Caption, color=Danger, wrap=false)

///|
/// It failed (parts.css.ts failedMark, as a blocked line has it): 12 round, red, its "!" 8 in 600, white.
// kept across runs: a value (no field of it changes)
let failed_mark : @ui.Style = @ui.css("w=S3 h=S3 radius=Full bg=Danger align=ACenter justify=JCenter")

///|
// kept across runs: a value (no field of it changes)
let failed_bang : @ui.TextStyle = @ui.text_style(size=Caption, leading=L3, weight=Semibold, color=OnDanger, wrap=false)
