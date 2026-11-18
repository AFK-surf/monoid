// 待处理's panel on 中屏 and 大屏 (attention.mbt), as nodes of the window's tree over the wide frame: presented by the
// library's presenters (@sf.panel_nodes: a small panel beside what opened it, Escape, back and a press outside closing
// it, the bell's own press as much as any) as 待处理 is opened (wide.attention_open: the rail's bell, the sidebar's
// 待处理, the system's bell beside its tabs), closed as it is closed; and what the frame keeps true of 待处理 while it
// shows, each at its cause: the stations' trouble let go once they are all reached again, what was stopped here let
// go once the core lists it no more.

///|
/// The serial of 待处理's panel presented over the wide frame (@sf.last_presented; 0 none).
// kept across runs: put back by wide_reset
let attention_shown : Ref[Int] = Ref(0)

///|
/// The sidebar's 待处理 (side_node's, where the rail has no bell): what 待处理's panel opens under then.
// kept across runs: set as it is made, let go with it
let side_attention : Ref[@view.View?] = Ref(None)

///|
/// 待处理 over the wide frame, in node `v` (a shell's, taped_shell's and paned_shell's): its panel presented as it is
/// opened and closed as it is closed (attention_open_now); the window turned beside the system's tabs, closed, what it
/// opened from elsewhere now. And, while the frame shows, the stations' trouble kept as seen let go as they are all
/// reached again (trouble_forget, as the chats and the prefs say it, and as another core comes), what was stopped here
/// let go of as the core no longer lists it (open_jobs_prune).
pub fn attention_panel_node(v : @view.View, src : Source) -> Unit {
  let workspace = fn() { @sfbase.workspace_in_view(src).0 }
  v.reacts(
    fn() {
      match workspace() {
        Some(w) => {
          let chats = @sfbase.chats_topic(src, w.id)
          let prefs = src.topic("prefs", {}).get()
          // (another core's prefs told anew, an answer of its: what it keeps cleared again where it was not)
          Some((w.id, chats.value, chats.error is None, prefs.value, prefs.version, (src.generation)("prefs", {}).0))
        }
        None => None
      }
    },
    fn(_) {
      match @signals.untracked(workspace) {
        Some(w) => trouble_forget(src, w)
        None => ()
      }
    },
  )
  v.reacts(
    fn() {
      match workspace() {
        // (read only while something is kept stopped here)
        Some(w) if !open_jobs_gone.is_empty() => Some(src.topic("longJobs", long_jobs_asked(w.id)).get().value)
        _ => None
      }
    },
    fn(now) {
      match (now, @signals.untracked(workspace)) {
        (Some(_), Some(w)) => open_jobs_prune(src, w)
        _ => ()
      }
    },
  )
  v.reacts(fn() { wide.attention_open.get() }, fn(open) {
    if open {
      match @signals.untracked(workspace) {
        Some(w) => attention_open_now(src, w)
        None => ()
      }
    } else {
      attention_close_now()
    }
  })
  // (the window turned or folded beside the system's tabs: what it opened from is elsewhere, closed, as the system's
  // popovers are)
  v.reacts(fn() { v.window().0 }, at_start=false, fn(_) {
    if @sf.native_on() && wide.attention_open.untracked() {
      attention_set(false)
    }
  })
  v.owns(attention_close_now) |> ignore
}

///|
/// 待处理's panel presented over the wide frame of workspace `w` (attention_present's), 300 wide, untitled: beside the
/// rail's bell, 10 past it, where it was as it opened (the bell where it is now, opened before it was placed: a
/// fixture's); beside the system's bell beside its tabs (in its column down the side, from its top; at the top's lead,
/// under it); with no bell in the rail, under 待处理 under 新建对话, 6 under it. A row pressed, 全部已读's neighbour
/// 通知设置, Escape, back or a press outside (the bell's too) close it, 待处理 closed with it.
fn attention_open_now(src : Source, w : Workspace) -> Unit {
  attention_close_now()
  let railed = rail_items(src, w.id).contains("attention")
  let (from, side, offset) : (@sf.Anchor, @ui.Side, Double) = if @sf.native_on() {
    (Of(native_mark.val), if @sf.native_side() { Left } else { Bottom }, if railed { attention_off_rail } else { attention_off_side })
  } else if railed {
    // (where the bell was as it opened; opened before the bell was placed (a fixture's, as the frame is first made):
    // beside the bell's node, where it comes to be drawn)
    match (attention_from.val, rail_drawn.get("attention")) {
      (Some((x, y, aw, ah)), _) if aw > 0.0 || ah > 0.0 => (At(x, y, aw, ah), Right, attention_off_rail)
      (None, Some(bell)) if bell.alive() => (Node(bell), Right, attention_off_rail)
      _ => (Unanchored, Right, attention_off_rail)
    }
  } else {
    match side_attention.val {
      Some(s) if s.alive() => (Node(s), Bottom, attention_off_side)
      _ => (Unanchored, Bottom, attention_off_side)
    }
  }
  attention_present(
    src,
    w,
    from,
    "",
    railed,
    fn(_) { fn() { attention_set(false) } },
    width=attention_w,
    foot_style=att_foot_beside,
    side~,
    along=Start,
    offset~,
    gone=fn() {
      attention_shown.val = 0
      attention_set(false)
    },
  )
  attention_shown.val = @sf.last_presented()
}

///|
/// 待处理's panel over the wide frame closed, where it is presented.
fn attention_close_now() -> Unit {
  let shown = attention_shown.val
  if shown > 0 {
    attention_shown.val = 0
    @sf.close_presented_of(shown)
  }
}
