// One's own message sent on the chat's page made as nodes, on 大屏 and 小屏: what is under its words (its time) comes in
// on their flight's own way (the old page's desktop flight, every composer's: flight_settled is flight_across) and is
// whole as they land, never a fade of its own after it, and nothing of it changes as the station takes the message, at
// once or 400 ms late; one the station has not taken sending_shows_ms after it went says 正在发送 in its time's place
// then, not before. Their bubble's ground comes round them as they go across (flight_ground of the desktop's), not a
// quarter of the way late (the user, 2026-11-17: 「感觉存在系统性的问题」, the time came in a moment after the words
// landed and 刚刚 a second time as the station took the message).

///|
/// One frame after the press that sends: when (ms from the run's start), where its words are drawn (x, y, w, h), every
/// 刚刚 and 正在发送 drawn (x, y, w, how opaque: which is its own is told by where its words land, sent_under), and how
/// opaque the most opaque ground round its words is (none: 0).
priv struct SentFrame {
  at : Double
  words : (Double, Double, Double, Double)
  times : Array[(Double, Double, Double, Double)]
  sendings : Array[(Double, Double, Double, Double)]
  ground : Double
}

///|
/// Of `drawn` (SentFrame's `times` or `sendings`), the one under its words: the lowest ending where they end once
/// landed (`right`), the column's end (an answer's time is in its head, at the column's start), if any.
fn sent_under(drawn : Array[(Double, Double, Double, Double)], right : Double) -> (Double, Double, Double, Double)? {
  let mut at : (Double, Double, Double, Double)? = None
  for d in drawn {
    if (d.0 + d.2 - right).abs() < 40.0 {
      at = match at {
        Some(was) if was.1 >= d.1 => Some(was)
        _ => Some(d)
      }
    }
  }
  at
}

///|
/// Frame by frame (60 a second) from the press that sends `text` in fixture `mode`, the station taking it
/// `delivered_in` after: each frame its words are drawn by the chat (SentFrame), from the first.
fn sent_time_frames(screen : (String, Double, Double, Int), script : String, text : String, delivered_in : Double) -> Array[SentFrame] {
  let (_, w, h, platform) = screen
  let out : Array[SentFrame] = []
  dk_host_each("chat", w, h, platform, script, delivered_in~, fn(_t, at) {
    guard @ui.view_tree() is Some(tr) else { return }
    let drawn = tr.drawn()
    guard drawn.search_by(fn(d) { d.words == text && d.alpha > 0.05 }) is Some(i) else { return }
    let wd = drawn[i]
    let all = fn(words : String) {
      drawn.filter(fn(d) { d.words == words }).map(fn(d) { (d.x, d.y, d.w, d.alpha) })
    }
    // (a ground round the words drawn by the window's tree, as big as a bubble at most (not the column's, the list's))
    let (cx, cy) = (wd.x + wd.w / 2.0, wd.y + 4.0)
    let mut ground = 0.0
    for d in drawn {
      if (d.ground & 0xFFL) > 0L && d.w < 0.6 * w && d.h < 200.0 && d.x <= cx && d.x + d.w >= cx && d.y <= cy && d.y + d.h >= cy {
        ground = @sf.dmax(ground, (d.ground & 0xFFL).to_double() / 255.0)
      }
    }
    out.push({
      at,
      words: (wd.x, wd.y, wd.w, wd.h),
      times: all("刚刚"),
      sendings: all(@sf.t("web-main.chat.sending")),
      ground,
    })
  })
  out
}

///|
/// How long after it is sent what is under it is looked at: past the station's taking it however late these tests have
/// it, before the fixture's agent answers under it.
let sent_time_seen_ms : Double = 1300.0

///|
/// The index of the frame its words land in (`frames`, sent_time_frames'): the first from which they are drawn where
/// they rest (as in the frame `sent_time_seen_ms` after the first, the list moving them no more), -1 never.
fn sent_landed(frames : Array[SentFrame]) -> Int {
  let at0 = frames[0].at
  let mut rest = -1
  for i, f in frames {
    if f.at <= at0 + sent_time_seen_ms {
      rest = i
    }
  }
  guard rest >= 0 else { return -1 }
  let (rx, ry, _, _) = frames[rest].words
  let mut landed = rest
  let mut i = rest
  while i >= 0 {
    let (x, y, _, _) = frames[i].words
    if (x - rx).abs() > 0.5 || (y - ry).abs() > 0.5 {
      break
    }
    landed = i
    i -= 1
  }
  landed
}

///|
/// What is wrong in `frames` of words the station took `delivered_in` after they went (sent_time_frames'): its time
/// coming in other than as they go across (how opaque it is, against how far across they are: the same way, from the
/// press, nothing after it), any frame after they land without it or with it elsewhere under them or another width,
/// 正在发送 seen where it has not been sending_shows_ms on its way or the station has it; where the station is later
/// than that, 正在发送 not in its place once it is.
fn sent_time_faults(name : String, frames : Array[SentFrame], delivered_in : Double) -> Array[String] {
  let bad = []
  guard frames.length() > 2 else { return ["\{name}: its words drawn in \{frames.length()} frames"] }
  let at0 = frames[0].at
  let landed = sent_landed(frames)
  guard landed > 0 else { return ["\{name}: its words never at rest"] }
  let late = delivered_in > @sfpages.sending_shows_ms
  // (how far across they are: from where they set out to where they land)
  let (x0, xr) = (frames[0].words.0, frames[landed].words.0)
  let right = xr + frames[landed].words.2
  guard (xr - x0).abs() > 20.0 else { return ["\{name}: its words went \{xr - x0} across, too little to tell"] }
  let mut rest : (Double, Double, Double, Double)? = None
  for i, f in frames {
    let ms = (f.at - at0).round()
    if f.at > at0 + sent_time_seen_ms {
      break
    }
    let time = sent_under(f.times, right)
    let sending = sent_under(f.sendings, right).map(fn(d) { d.3 }).unwrap_or(0.0)
    // (正在发送 only once it has been on its way that long with the station not having it)
    let sends = late && f.at - at0 >= @sfpages.sending_shows_ms + @sf.leave_ms
    if sending > 0.05 && !(late && f.at - at0 >= @sfpages.sending_shows_ms) {
      bad.push("\{name} @\{ms}ms: 正在发送 seen at \{sending}")
    }
    if sends {
      if sending < 0.99 {
        bad.push("\{name} @\{ms}ms: 正在发送 not seen whole once it has been on its way a while (\{sending})")
      }
      continue
    }
    if late && f.at - at0 >= @sfpages.sending_shows_ms {
      continue
    }
    let a = match time {
      Some((_, _, _, a)) => a
      None => 0.0
    }
    let across = @sf.dclamp((f.words.0 - x0) / (xr - x0), 0.0, 1.0)
    if (a - across).abs() > 0.03 {
      bad.push("\{name} @\{ms}ms: its time at \{a}, its words \{across} of the way across")
    }
    if i < landed {
      continue
    }
    match (time, rest) {
      (None, _) => bad.push("\{name} @\{ms}ms: its time not drawn, its words landed")
      (Some((x, ty, tw, _)), Some((rx, ry, rw, wy))) => {
        let y = f.words.1
        if (x - rx).abs() > 0.5 || (ty - y - (ry - wy)).abs() > 0.5 || (tw - rw).abs() > 0.5 {
          bad.push("\{name} @\{ms}ms: its time at \{x},\{ty} \{tw} wide, its words at \{y}; as they landed \{rx},\{ry} \{rw} wide, \{wy}")
        }
      }
      (Some((x, ty, tw, _)), None) => rest = Some((x, ty, tw, f.words.1))
    }
  }
  bad
}

///|
let sent_time_script : String =
  #|timeout 20000
  #|until 发消息
  #|wait 600
  #|tap 发消息
  #|wait 500
  #|type 发布前再看一眼签名
  #|wait 700
  #|tap icon:arrow-up
  #|wait 2000
  #|exit

///|
test "one's own message sent in a chat: its time comes in on their flight's way, whole as its words land, and nothing changes as the station takes it, at once or 400 ms late" {
  let bad = []
  for screen in dk_screens {
    for late in [0.0, 400.0] {
      let frames = sent_time_frames(screen, sent_time_script, "发布前再看一眼签名", late)
      bad.append(sent_time_faults("\{screen.0}, taken \{late}ms after", frames, late))
    }
  }
  assert_eq(bad.length(), 0, msg=bad.join("\n"))
}

///|
test "one's own message the station has not taken sending_shows_ms after it went: its time as it lands, 正在发送 in its place once it has been on its way that long" {
  let bad = []
  for screen in dk_screens {
    let late = 2.0 * @sfpages.sending_shows_ms
    let frames = sent_time_frames(screen, sent_time_script, "发布前再看一眼签名", late)
    bad.append(sent_time_faults("\{screen.0}, taken \{late}ms after", frames, late))
  }
  assert_eq(bad.length(), 0, msg=bad.join("\n"))
}

///|
test "words sent: their bubble's ground comes round them as they go across, from the press, as the old page's desktop flight (every composer's)" {
  let bad = []
  for screen in dk_screens {
    let frames = sent_time_frames(screen, sent_time_script, "发布前再看一眼签名", 0.0)
    guard frames.length() > 2 else {
      bad.push("\{screen.0}: its words drawn in \{frames.length()} frames")
      continue
    }
    let landed = sent_landed(frames)
    let at0 = frames[0].at
    let way = frames[landed].at - at0
    // (the first quarter of the way: some ground round them, coming in, never none till a quarter of it)
    let early = frames.filter(fn(f) { f.at - at0 > 0.0 && f.at - at0 < 0.24 * way })
    if early.is_empty() || !early.iter().any(fn(f) { f.ground > 0.0 }) {
      bad.push("\{screen.0}: no ground round them in the first quarter of their \{way}ms way")
    }
    let mut was = 0.0
    for f in frames[:landed + 1] {
      if f.ground < was - 0.01 {
        bad.push("\{screen.0} @\{(f.at - at0).round()}ms: their ground went back from \{was} to \{f.ground}")
      }
      was = f.ground
    }
  }
  assert_eq(bad.length(), 0, msg=bad.join("\n"))
}
