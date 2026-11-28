// The card to share of the workspace's agents at work (2026-10-26 用户：「需要有一个地方可以显示当前多少个 chat 正在工作，
// 有利于 app 传播」「hover 这个出一个卡片」「有个复制图片应该就行」), opened from the rail's Station place's card
// (rail_cards.mbt) and the Station page's first card. The card to share: a
// picture of the agents at work on the person's stations, copied whole to paste where others see it (a chat, a post):
// a poster (the `fleet` view): the tokens each kind of account used as rings, today and the last 7 days, the chats at
// work now, still.fail's line (no QR code: 2026-10-26 用户「不用放 still fail 的二维码」); 复制图片 under it puts it on the
// clipboard, the same poster made apart and drawn as sharp on any screen (@ui.take_picture at share_scale). All of it
// is made once as nodes of the window's tree (share_pen.mbt), made anew only as the look chosen or what it says does.

// ── the card to share ────────────────────────────────────────────────────

///|
/// The card to share of workspace `w`'s agents at work, opened by nothing, on a stage of its own on every screen (a
/// panel's `stage`: the picture alone in the window's middle over the night, no dialog round it: 2026-10-26 用户「分享的
/// 弹窗有点丑，感觉应该给分享特制一个逼格高点的」): the picture (share_poster_node), under it 关闭 and 复制图片, or on a
/// phone (iOS, Android) 保存到相册: a phone keeps pictures in its photo album, where a post or a chat picks them from
/// (2026-10-26 用户：「手机上能复制图片吗？」「是不是应该是下载」「保存」). It comes in once what its poster reads (the
/// `fleet` view) is answered, as any panel of nodes does (@sf open_gate.mbt).
pub fn share_card_open(src : Source, w : Workspace) -> Unit {
  @sf.panel_nodes(
    @sf.t("web-main.stations.shareCard"),
    fn(v, _) { share_poster_node(v, src, w, false) },
    from=Unanchored,
    // (laid out as wide as it is handed out; past the window's room, drawn smaller: the stage's)
    stage=true,
    w=@sf.share_w_most,
    // the looks it can be drawn in, over its buttons (share_looks.mbt)
    above=fn(v) { share_looks_pick_node(v, src, w) },
    // (its title said as it is drawn, in the language then)
    live=fn() { (@sf.t("web-main.stations.shareCard"), "", "") },
    foot=fn(f, _) { share_out_node(f, src, w) },
  )
}

///|
/// The button that hands the picture out, at the stage's foot: only once all the look draws is here (its pictures, its
/// face: share_stand), how far they are said on the button meanwhile (2026-11-03 用户：「在没有准备好资源的时候不让保存」
/// 「每张独立下载并提供进度」); one not had, 下载失败，重试 in its place. Pressed, the poster made apart, all of it, its
/// ground to its edges, as wide as it is laid out and share_scale pixels a point (@ui.take_picture), handed out as the
/// button says (picture_out_now).
fn share_out_node(f : @view.View, src : Source, w : Workspace) -> Unit {
  let (label, icon) = @sf.picture_out_way()
  // (which button: ready, on its way (its words how far), not had; made anew only as that changes)
  let stand = fn() {
    match share_stand(src) {
      LooksReady => 0
      LooksGoing(_) => 1
      LooksNotHad(_) => 2
    }
  }
  f.pick(stand, at_once=true, fn(b, k) {
    match k {
      0 =>
        @sf.button_node(b, fn() { label }, tone=Primary, icon~, on_night=true, fn() {
          @ui.take_picture(share_shot, @sf.share_w_most, fn(paper) { share_poster_node(paper, src, w, true) }, fn(png) {
            picture_out_now(png) |> ignore
          }, scale=share_scale)
        })
        |> ignore
      1 => {
        let going = fn() {
          match share_stand(src) {
            LooksGoing(Some(p)) =>
              @sf.t("web-main.stations.shareFetching", args=[("percent", (p * 100.0).to_int().to_string())])
            _ => @sf.t("web-main.stations.shareFetchingSoon")
          }
        }
        @sf.button_node(b, going, fn() {  }, tone=Primary, busy=fn() { true }, disabled=fn() { true }, on_night=true) |> ignore
      }
      _ =>
        @sf.button_node(b, fn() { @sf.t("web-main.stations.shareFetchFailed") }, tone=Primary, icon="retry", on_night=true, fn() {
          share_fetch_again(src)
        })
        |> ignore
    }
  })
}

///|
/// The files of the chosen look not had asked for again.
fn share_fetch_again(src : Source) -> Unit {
  let look = share_look(src)
  let all = look_needs.get(look.key).unwrap_or([]).copy()
  for f in @sfbase.share_face_whole_files(senren_drawn) {
    all.push(f.0)
  }
  @sfbase.looks_files_again(src, all)
}

///|
/// The picture handed out (@ui.take_picture).
let share_shot : String = "share-card/shot"

///|
/// How many pixels a point the picture handed out has, whatever the screen it is shared from (1080 across): as sharp
/// from a screen of one pixel a point as from a phone's three (2026-10-26 用户「现在做」, of the picture as sharp
/// everywhere).
let share_scale : Double = 3.0

///|
/// The picture shared in `v`, a poster of what the agents did (the `fleet` view; 2026-10-26 用户：「改成 xx 个 xx 订阅账号的
/// xx% 周额度，分天和周统计，还有当前 chat 数量」「不要小机器人」「这玩意儿是会超过 100% 的」「不如归档 chat 多少个」): on night, the
/// same in either theme (@sf.share_ground: 「分享卡片的颜色搞高级点」), and laid out one way whatever it is seen on (a
/// portrait poster @sf.share_w_most wide: 「分享图片不应该分电脑和手机…按最合理的布局生成」), seen whole on the stage, drawn
/// smaller where the window has not the room for it (the stage's): what is handed out is all of it, as it is laid out
/// everywhere. Round as a card, or `flat` (handed out: its ground to its edges), in the look chosen under it
/// (share_look: the night's here, the others' share_looks.mbt), made anew only as another look is chosen: what the view
/// says and the words of the language are bound to the nodes that show them (share_pen.mbt), and what comes and goes by
/// them comes and goes (Pen::show, Pen::each), the rest of the picture as it was. The night's read down: still.fail's name (its dot orange) and when it is; what leads the first
/// kind's share (用 6 个 Claude 订阅账号消耗了, its ring's dot before it); the tokens each kind of account used over the 7
/// days as rings, a kind each (Activity's rings: each its share of all kinds' tokens; 2026-10-29 用户「只算 token 和价格」,
/// where it was a week's quota), beside them the first kind's first model's tokens large, the model and what they would
/// cost (2.1 亿 | Opus 5.5 | token，折合 $1,420); each other model a line with its own, each other kind a line over its
/// models (no kind's models added up: 2026-10-30 用户「按模型分开写 token 和钱」); today over the last 7 days (the chats
/// archived, what was spent), each day's chats archived a bar under them (today's orange, each day's date under its
/// bar); the chats at work now, a dot before them, and the tasks agents ran across devices over the 7 days (how many,
/// and under it how many a chat on average), the devices' icon before them; still.fail's line. With nothing used: the
/// chats at work large in its place.
fn share_poster_node(v : @view.View, src : Source, w : Workspace, flat : Bool) -> Unit {
  let fleet = share_fleet(src, w)
  v.pick(at_once=true, fn() { share_look(src).key }, fn(p, key) {
    let look = share_look_of(key)
    // (千恋＊万花's words in a face the app does not carry: had from the site as their pictures are, share_senren.mbt)
    if look.key.has_prefix(senren_prefix) {
      @sfbase.share_face_whole(src, senren_drawn)
    }
    // (the pictures a look draws are its own, whatever the view says: those it was made with)
    let files = senren_drawing(src, fn() { (look.draw)(Pen::of(p), fleet, flat) }).1
    if look_needs.get(look.key) != Some(files) {
      look_needs[look.key] = files
    }
  })
}

///|
/// The files of the looks (@sfbase.looks_file) each look drew its card with as it was last made, by its key: those it
/// is handed out only once they are here (share_stand). None for a look of the app's own alone.
// kept across runs: what a look draws its card with is the same in every run
let look_needs : @sf.LiveMap[String, Array[String]] = @sf.LiveMap::new()

///|
/// How the files the chosen look needs stand (@sfbase.looks_stand): its pictures as it drew them, and the whole share
/// face for 千恋＊万花's; a look not drawn yet is on its way.
fn share_stand(src : Source) -> @sfbase.LooksStand {
  let look = share_look(src)
  if !look.key.has_prefix(senren_prefix) {
    return LooksReady
  }
  match look_needs.get(look.key) {
    Some(files) => {
      let all = files.copy()
      for f in @sfbase.share_face_whole_files(senren_drawn) {
        all.push(f.0)
      }
      @sfbase.looks_stand(src, all)
    }
    None => LooksGoing(None)
  }
}

///|
/// What the card to share of workspace `w` says (the core's `fleet` view), whatever look draws it: read by what shows
/// it, as it is then (the topic asked as the card is made, so the card comes in once it is answered).
fn share_fleet(src : Source, w : Workspace) -> () -> Json? {
  let topic = src.topic("fleet", { "scope": Json::string(w.id) })
  fn() { topic.get().value }
}

///|
/// The night's look: still.fail's own colours, the kinds' tokens as rings.
fn night_look(c : Pen, fleet : () -> Json?, flat : Bool) -> Pen {
  let spent = fn() { items(fleet(), "spent") }
  let used = fn() { spent().length() > 0 }
  let tasks = fn() { text(fleet(), "tasksText") }
  c.box(style=if flat { pic_box_flat } else { pic_box }, fn(c) {
    c.box(style=pic_head, fn(c) {
      c.box(style=pic_grow, fn(c) {
        let words = [@ui.span("still"), @ui.span(".", color=@sf.share_orange), @ui.span("fail")]
        c.rich(words, style=pic_brand, face=@sfbase.share_face_given()) |> ignore
      })
      |> ignore
      pic_words(c, fn() { text(fleet(), "at") }, pic_at)
    })
    |> ignore
    // the first kind's said round its first model's tokens, a sentence read down (用 6 个 Claude 订阅账号消耗了 | 2.1 亿 |
    // Opus 5.5 | token，折合 $1,420: 2026-10-26 用户「你要么这么说"是用 x 个账号消耗了 xxx% 的周额度"」, then 「只算 token 和价格」), what leads
    // it over the rings and the tokens
    let first = fn() { spent().get(0) }
    let top = fn() { items(first(), "models").get(0) }
    pic_lead(c, used, first)
    c.show(used, style=pic_hero, fn(c) {
      pic_rings(c, spent)
      c.box(style=pic_hero_words, fn(c) {
        pic_words(c, fn() { text(top(), "tokensText") }, pic_number)
        // (the model a line of its own: with what they would cost after it, a line too long beside the rings)
        pic_words(c, fn() { text(top(), "name") }, pic_unit)
        pic_words(c, fn() { text(top(), "of") }, pic_unit)
      })
      |> ignore
    })
    pic_models(c, spent)
    c.show(fn() { !used() }, style=pic_hero, fn(c) {
      pic_words(c, fn() { count(fleet(), "chats").to_string() }, pic_number)
      c.box(style=pic_hero_words, fn(c) { pic_words(c, fn() { text(fleet(), "chatsText") }, pic_unit) }) |> ignore
    })
    let today = fn() { field(fleet(), "today") }
    let week = fn() { field(fleet(), "week") }
    let spans = fn() { today() is Some(Object(_)) && week() is Some(Object(_)) }
    c.show(spans, style=pic_spans, fn(c) {
      pic_span(c, today)
      pic_span(c, week)
    })
    c.show(spans, style=pic_bars_row, fn(c) { pic_bars(c, week) })
    // the chats at work now (with the tokens large: said here), the tasks chats ran on other stations over the week
    c.show(fn() { used() || tasks() != "" }, style=pic_lines, fn(c) {
      c.show(used, style=pic_live, fn(c) {
        pic_line(c, fn(c) { c.box(style=pic_live_dot, fn(_) {  }) |> ignore }, fn() { text(fleet(), "chatsText") }, fn() {
          text(fleet(), "where")
        }, false)
      })
      c.show(fn() { tasks() != "" }, style=pic_live_apart, fn(c) {
        pic_line(c, fn(c) { @sf.icon_node(c.v, "devices", pic_mark_side, Is(@sf.share_ink)) |> ignore }, tasks, fn() {
          text(fleet(), "tasksPer")
        }, true)
      })
    })
    pic_words(c, fn() { @sf.t("web-main.stations.shareTagline") }, pic_tagline)
  })
}

///|
/// Words on the night's card as `words` works them out, in the card's own face (@sfbase.share_face_given: EB Garamond
/// and 霞鹜文楷, 2026-10-31 用户 chose it from drawn versions, 「就用右边这版」), the same on every device whatever face its
/// app is set in.
fn pic_words(c : Pen, words : () -> String, style : @ui.TextStyle) -> Unit {
  c.text_by(words, style~, face=@sfbase.share_face_given())
}

///|
/// What a line under the days holds (`c`, its box: pic_live, or pic_live_apart): its mark (in a square of its own, the
/// lines' words starting together), what it says, and more of it after a dot, dimmer; `apart`, the more under it (a line
/// as long as the tasks' is broken inside a word on one line: 「…312 个任」「务」).
fn pic_line(c : Pen, mark : (Pen) -> Unit, words : () -> String, more : () -> String, apart : Bool) -> Unit {
  c.box(style=pic_mark_box, mark) |> ignore
  if apart {
    c.box(style=pic_line_words, fn(c) {
      pic_words(c, words, pic_line_lead)
      pic_words(c, more, pic_line_more)
    })
    |> ignore
  } else {
    c.rich_by(
      fn() { [@ui.span(words(), weight=700), @ui.span("  ·  " + more(), color=@sf.share_dim)] },
      style=pic_line_one,
      face=@sfbase.share_face_given(),
    )
  }
}

///|
/// The colour of the ring of kind `k` (in the core's order), the last one's past them.
fn ring_color(k : Int) -> Int64 {
  @sf.share_rings[if k < @sf.share_rings.length() { k } else { @sf.share_rings.length() - 1 }]
}

///|
/// What leads the first kind's share (用 6 个 Claude 订阅账号消耗了), while any was `used`, its ring's dot before it as
/// each other kind's line has (the share under it in white, as the second ring is: the dot says whose it is).
fn pic_lead(c : Pen, used : () -> Bool, first : () -> Json?) -> Unit {
  c.show(used, style=pic_lead_row, fn(c) {
    c.box(style=pic_lead_dot, fn(_) {  }) |> ignore
    pic_words(c, fn() { text(first(), "lead") }, pic_unit)
  })
}

///|
/// A line of pic_models: the kind `kind` (in the core's order) as its ring's key (`model` -1), or its model `model`.
#derive(Eq)
priv struct PicLine {
  kind : Int
  model : Int
  of : Json
}

///|
/// Named key for a `PicLine` row in `pic_models`.
#derive(Eq, Hash)
priv struct PicLineKey {
  kind : Int
  model : Int
}

///|
/// The models but the one said large, one line each (its name, its tokens and cost at the line's end in ink), past where
/// the dots are: the first kind's under it; then each other kind a line as its ring's key (its colour's dot, its name,
/// its accounts dimmer), its models under it; none where there is one kind of one model. One model's tokens are not
/// another's, so no kind adds its models' up (2026-10-30 用户「按模型分开写 token 和钱」). One line each whatever its
/// name: said as a sentence, a name long enough broke it, a character on a line of its own (2026-10-26 用户：「这里折行了
/// 不太好看」); a name too long for its line cut short, nothing else. Each line kept by which kind and model it is.
fn pic_models(c : Pen, spent : () -> Array[Json]) -> Unit {
  let lines = fn() {
    let out : Array[PicLine] = []
    for k, q in spent() {
      if k > 0 {
        out.push({ kind: k, model: -1, of: q })
      }
      for i, m in items(Some(q), "models") {
        if k > 0 || i > 0 {
          out.push({ kind: k, model: i, of: m })
        }
      }
    }
    out
  }
  c.show(fn() { lines().length() > 0 }, style=pic_models_box, fn(c) {
    c.each(lines, fn(l) { ({ kind: l.kind, model: l.model } : PicLineKey) }, style_of=fn(l) { if l.model < 0 { pic_other } else { pic_model } }, fn(
      c,
      l,
    ) {
      let q = fn() { Some(l().of) }
      // (which line it is is its key's: a kind's or a model's, whose colour)
      let kind = @signals.untracked(l).kind
      if @signals.untracked(l).model < 0 {
        c.box(style=pic_key_dot.then(@ui.style(bg=Data(ring_color(kind)))), fn(_) {  }) |> ignore
        pic_words(c, fn() { text(q(), "name") }, pic_key_name)
        pic_words(c, fn() { text(q(), "accountsText") }, pic_key_accounts)
      } else {
        c.box(style=pic_key_dot, fn(_) {  }) |> ignore
        pic_words(c, fn() { text(q(), "name") }, pic_key_name)
        c.box(style=pic_grow, fn(_) {  }) |> ignore
        pic_words(c, fn() { text(q(), "lineText") }, pic_key_share)
      }
    })
  })
}

///|
/// The rings: a kind of account each, from the outside in (as many as there are colours), as much of each drawn as its
/// share of all kinds' tokens (the core's `share`: @sf.rings).
fn pic_rings(c : Pen, spent : () -> Array[Json]) -> Unit {
  let rings = by_value(fn() {
    let rings : Array[(Double, Int64)] = []
    for k, q in spent() {
      if k >= @sf.share_rings.length() {
        break
      }
      rings.push((number(Some(q), "share"), ring_color(k)))
    }
    rings
  })
  @sf.rings_node(c.v, rings, pic_rings_side, pic_track_alpha, most=@sf.share_rings.length()) |> ignore
}

///|
/// A span of days (today, the last 7) on a card: its title, then each figure over what it is, each kept by its place.
fn pic_span(c : Pen, span : () -> Json?) -> Unit {
  c.box(style=pic_span_box, fn(c) {
    pic_words(c, fn() { text(span(), "title") }, pic_span_title)
    c.box(style=pic_stats, fn(c) {
      c.each(fn() { items(span(), "stats").mapi(fn(i, x) { (i, x) }) }, fn(x) { x.0 }, style_of=fn(_) { pic_stat }, fn(
        c,
        x,
      ) {
        pic_words(c, fn() { text(Some(x().1), "value") }, pic_stat_value)
        pic_words(c, fn() { text(Some(x().1), "label") }, pic_stat_label)
      })
    })
    |> ignore
  })
  |> ignore
}

///|
/// Each day's chats archived a bar, as tall as its share of the most on a day (4 at least: a day with none still seen), today's
/// orange, its date under it; each kept by its place in the week.
fn pic_bars(c : Pen, week : () -> Json?) -> Unit {
  c.each(fn() { items(week(), "days").mapi(fn(i, d) { (i, d) }) }, fn(d) { d.0 }, style_of=fn(_) { pic_day }, fn(c, d) {
    let d = fn() { Some(d().1) }
    let today = fn() { flag(d(), "today") }
    c.box(style=pic_bar_room, fn(c) {
      c.box(
        style_by=fn() {
          let h = dmax(pic_bar_least, number(d(), "share") * pic_bars_h)
          pic_bar.then(@ui.style(h=Fixed(h), bg=Data(if today() { @sf.share_orange } else { @sf.share_bar })))
        },
        fn(_) {  },
      )
      |> ignore
    })
    |> ignore
    c.text_by(fn() { text(d(), "label") }, style=pic_day_label, style_by=fn() {
      if today() {
        pic_day_today
      } else {
        pic_day_label
      }
    }, face=@sfbase.share_face_given())
  })
}

///|
/// The picture: as wide as the stage lays it out (@sf.share_w_most), 20 in (nothing at its corners but words: the
/// corners' rule asks nothing of them), its parts 12 apart, round as a card, on night (what is drawn on it seen against
/// that), its edge a hairline (@sf.stage_edge: on the stage's night, where it ends).
// kept across runs: a value (no field of it changes)
let pic_box : @ui.Style = @ui.css("w=Full gap=S3 radius=Xl3 clip border=B1").then(@ui.style(p=@sf.room_of(@sf.card_pad))).then(
  @ui.style(bg=Data(@sf.share_ground), border_color=Data(@sf.stage_edge)),
)

///|
/// The picture handed out: its ground to its edges.
// kept across runs: a value (no field of it changes)
let pic_box_flat : @ui.Style = pic_box.then(@ui.css("radius=Sharp border=B0"))

///|
// kept across runs: a value (no field of it changes)
let pic_head : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pic_grow : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let pic_brand : @ui.TextStyle = @ui.text_style(size=Xl, weight=Bold, color=Data(@sf.share_ink), wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pic_at : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(@sf.share_dim), wrap=false)

///|
/// The rings and their words beside them, in the middle of each other's height.
// kept across runs: a value (no field of it changes)
let pic_hero : @ui.Style = @ui.css("row w=Full gap=S5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pic_hero_words : @ui.Style = @ui.css("gap=S1").then(@ui.style(w=@sf.grow))

///|
/// The rings: 88 across, as tall as the share and what it is of beside them, the room for every kind's (each 10 wide, 2
/// apart, the hole 10 round: @sf.rings); their tracks the colour at 22%, as seen on the night.
let pic_rings_side : Double = 88.0

///|
let pic_track_alpha : Int64 = 0x38L

///|
/// The number, as large as a picture's one number is (the scale's past its words', Xl6 60: 170% beside the rings too),
/// drawn tight.
// kept across runs: a value (no field of it changes)
let pic_number : @ui.TextStyle = @ui.text_style(size=Xl6, weight=Bold, tracking=Tight, color=Data(@sf.share_ink), wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pic_unit : @ui.TextStyle = @ui.text_style(size=Xl, weight=Bold, color=Data(@sf.share_ink), w=Full)

///|
/// The first kind's lead: its dot, its words.
// kept across runs: a value (no field of it changes)
let pic_lead_row : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
/// Its dot, the first ring's colour (@sf.share_rings' first is the orange).
// kept across runs: a value (no field of it changes)
let pic_lead_dot : @ui.Style = pic_key_dot.then(@ui.style(bg=Data(@sf.share_orange)))

///|
/// Another kind's line.
// kept across runs: a value (no field of it changes)
let pic_other : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter pt=S1")

///|
// kept across runs: a value (no field of it changes)
let pic_key_dot : @ui.Style = @ui.css("w=S2 h=S2 radius=Full")

///|
/// A key's name, cut short where its line has not the room for it; its accounts after it, dimmer; its share in ink.
// kept across runs: a value (no field of it changes)
let pic_key_name : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(@sf.share_ink), w=Cut, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pic_key_accounts : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(@sf.share_dim), wrap=false)

///|
/// The models' lines, one under another (a kind's line further from those over it: pic_other's top).
// kept across runs: a value (no field of it changes)
let pic_models_box : @ui.Style = @ui.css("w=Full gap=S1")

///|
/// A model's line, where its kind's name starts (past a dot's room).
// kept across runs: a value (no field of it changes)
let pic_model : @ui.Style = @ui.css("row w=Full gap=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let pic_key_share : @ui.TextStyle = @ui.text_style(size=Sm, weight=Bold, color=Data(@sf.share_ink), wrap=false)

///|
/// Today over the last 7 days, 10 apart, each as wide as the picture.
// kept across runs: a value (no field of it changes)
let pic_spans : @ui.Style = @ui.css("w=Full gap=S2_5 align=AStretch")

///|
/// A span: a card of the white barely, 12 in, round; its title over its figures.
// kept across runs: a value (no field of it changes)
let pic_span_box : @ui.Style = @ui.css("p=S3 gap=S2 radius=Xl").then(@ui.style(w=@sf.grow, bg=Data(@sf.share_card)))

///|
// kept across runs: a value (no field of it changes)
let pic_span_title : @ui.TextStyle = @ui.text_style(size=Xs, weight=Medium, color=Data(@sf.share_dim), wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pic_stats : @ui.Style = @ui.css("row w=Full gap=S3")

///|
// kept across runs: a value (no field of it changes)
let pic_stat : @ui.Style = @ui.style(w=@sf.grow, gap=S0_5)

///|
// kept across runs: a value (no field of it changes)
let pic_stat_value : @ui.TextStyle = @ui.text_style(size=Lg, weight=Bold, color=Data(@sf.share_ink), wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let pic_stat_label : @ui.TextStyle = @ui.text_style(size=Xs, color=Data(@sf.share_dim), wrap=false, w=Cut)

///|
/// The days' bars side by side, 6 apart, each its date under it, as wide as it is.
// kept across runs: a value (no field of it changes)
let pic_bars_row : @ui.Style = @ui.css("row w=Full gap=S1_5")

///|
// kept across runs: a value (no field of it changes)
let pic_day : @ui.Style = @ui.style(w=@sf.grow, gap=S1, align=ACenter)

///|
/// A bar's room: as tall as the busiest day's, its bar standing on its foot.
// kept across runs: a value (no field of it changes)
let pic_bar_room : @ui.Style = @ui.css("w=Full justify=JEnd").then(@ui.style(h=Fixed(pic_bars_h)))

///|
let pic_bars_h : Double = 40.0

///|
let pic_bar_least : Double = 4.0

///|
// kept across runs: a value (no field of it changes)
let pic_bar : @ui.Style = @ui.css("w=Full radius=Sm")

///|
// kept across runs: a value (no field of it changes)
let pic_day_label : @ui.TextStyle = @ui.text_style(size=Xs, color=Data(@sf.share_dim), wrap=false)

///|
/// Today's date: in the orange, as heavy as the others (bold, 10/26 was wider than a 360 phone's day: 「10/…」).
// kept across runs: a value (no field of it changes)
let pic_day_today : @ui.TextStyle = @ui.text_style(size=Xs, color=Data(@sf.share_orange), wrap=false)

///|
/// The lines under the days (the chats at work, the tasks run across devices), 8 apart.
// kept across runs: a value (no field of it changes)
let pic_lines : @ui.Style = @ui.css("w=Full gap=S2")

///|
/// A line: its mark, what it says.
// kept across runs: a value (no field of it changes)
let pic_live : @ui.Style = @ui.css("row w=Full gap=S2 align=ACenter")

///|
/// A line with the more under it: its mark by its first line.
// kept across runs: a value (no field of it changes)
let pic_live_apart : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// Its words: what it says over the more of it, Meta's (13).
// kept across runs: a value (no field of it changes)
let pic_line_words : @ui.Style = @ui.css("gap=S0_5").then(@ui.style(w=@sf.grow))

///|
/// A line on one line, Meta's (13).
// kept across runs: a value (no field of it changes)
let pic_line_one : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(@sf.share_ink), w=Full)

///|
// kept across runs: a value (no field of it changes)
let pic_line_lead : @ui.TextStyle = @ui.text_style(size=Sm, weight=Bold, color=Data(@sf.share_ink), w=Full)

///|
// kept across runs: a value (no field of it changes)
let pic_line_more : @ui.TextStyle = @ui.text_style(size=Sm, color=Data(@sf.share_dim), w=Full)

///|
/// A line's mark: a dot (the chats at work), the devices' icon (the tasks across devices), in a square 16 across.
// kept across runs: a value (no field of it changes)
let pic_mark_box : @ui.Style = @ui.css("w=S4 h=S4 align=ACenter justify=JCenter")

///|
let pic_mark_side : Double = 16.0

///|
// kept across runs: a value (no field of it changes)
let pic_live_dot : @ui.Style = @ui.css("w=S2_5 h=S2_5 radius=Full").then(@ui.style(bg=Data(@sf.share_orange)))

///|
/// Its foot: still.fail's line, said quietly (the white thinned), its characters set apart as a line of verse.
// kept across runs: a value (no field of it changes)
let pic_tagline : @ui.TextStyle = @ui.text_style(size=Lg, weight=Semibold, color=Data(@sf.share_dim), tracking=Widest, wrap=false)
