// The library's parts of a station's machine as a list shows it (station_net_node.mbt): a figure in its level's ink,
// how this device reaches a station in both looks, and a card of the stations' list, each beside its states.

///|
/// A connection as the core says it: `path`, its loss and round trip at `level`.
fn u14_net(path : String, loss : String, rtt : String, level : String) -> Json {
  let o : Map[String, Json] = { "path": Json::string(path), "up": "1.2 KB/s", "down": "36 KB/s" }
  if loss != "" {
    o["loss"] = Json::object({ "text": Json::string(loss), "level": Json::string(level) })
  }
  o["rtt"] = Json::object({ "text": Json::string(rtt), "level": Json::string(level) })
  Json::object(o)
}

///|
/// Their stories, after the others.
fn stories_u14() -> Array[Story] {
  [
    {
      key: "station-net",
      group: "数据",
      name: "网络连接 StationNet",
      file: "station_net_node.mbt",
      api: [
        ("station_net_node.mbt", "station_net_line_node"),
        ("station_net_node.mbt", "level_figure_node"),
        ("station_net_node.mbt", "level_figure_style"),
      ],
      play: None,
      about: "本设备到一台 station 的连接：左边是怎么连的、丢包和往返延迟，右边是上下行速度；一行放不下时速度折到下一行，数字不截断，只截「当前延迟」几个字。数字按级别着色：amber 用警示墨色，red 用危险色。Card 是 station 列表卡片上的样子，Page 是 station 页资源区里的样子，Peek 是对话里悬停 station 时卡片上的样子；还没读到时画一条假的，作骨架。",
      cases: [
        (
          "分级数字",
          fn(card) {
            side_by_side(card, fn(r) {
              for level in [("ok", "38 ms"), ("amber", "260 ms"), ("red", "1.2 s")] {
                @sf.level_figure_node(r, fn() { Some(Json::object({ "text": Json::string(level.1), "level": Json::string(level.0) })) })
                |> ignore
              }
            })
          },
        ),
        (
          "Card（直连 / 中继丢包 / 窄处折行）",
          fn(card) {
            @sf.station_net_line_node(card, fn() { Some(u14_net("直连", "", "38 ms", "ok")) })
            @sf.station_net_line_node(card, fn() { Some(u14_net("中继", "3%", "420 ms", "amber")) })
            card.box(fn(narrow) {
              narrow.width(Is(Some(180.0))) |> ignore
              @sf.station_net_line_node(narrow, fn() { Some(u14_net("中继", "12%", "1.2 s", "red")) })
            })
            |> ignore
          },
        ),
        (
          "Page（station 页的资源区）",
          fn(card) {
            @sf.station_net_line_node(card, fn() { Some(u14_net("中继", "3%", "420 ms", "amber")) }, look=Page)
          },
        ),
        (
          "Peek（读到的 / 骨架）",
          fn(card) {
            @sf.station_net_line_node(card, fn() { Some(u14_net("中继", "3%", "420 ms", "amber")) }, look=Peek)
            @sf.waiting_node(card, fn(w) { @sf.station_net_line_node(w, fn() { None }, look=Peek) })
          },
        ),
      ],
    },
    {
      key: "summary-mark-card",
      group: "卡片",
      name: "机器卡片 SummaryMarkCard",
      file: "station_net_node.mbt",
      api: [("station_net_node.mbt", "summary_mark_card_node")],
      play: None,
      about: "机器列表（station、只跑任务的机器、设备）里的一张卡片：标记、名字和标签在首行，标记和右端的 chevron 对齐首行；说明从名字起点排起，可折行；卡片下方放页面自己的内容（负载、网络）；整张卡可按。",
      cases: [
        (
          "本机 station（带标签与网络）",
          fn(card) {
            let pressed = kept(0)
            @sf.summary_mark_card_node(
              card,
              fn(m) { @sf.icon_node(m, "server", @sf.summary_mark_side, By(fn() { @sf.theme().p.text })) |> ignore },
              fn() { "studio" },
              fn() { if pressed.get() == 0 { "3 个会话在跑 · 2 个任务排队" } else { "按了 \{pressed.get()} 次" } },
              fn() { pressed.set(pressed.get() + 1) },
              tag=fn() { "本机" },
              body=fn(b) { @sf.station_net_line_node(b, fn() { Some(u14_net("直连", "", "38 ms", "ok")) }) },
            )
          },
        ),
        (
          "设备（长说明折行）",
          fn(card) {
            @sf.summary_mark_card_node(
              card,
              fn(m) { @sf.icon_node(m, "boxes", @sf.summary_mark_side, By(fn() { @sf.theme().p.text })) |> ignore },
              fn() { "build-runner-tokyo-mac-studio-0" },
              fn() { "只跑任务 · 由左子健借给这个工作区，今天还剩 3 小时可用，到期后自动收回" },
              fn() {  },
            )
          },
        ),
      ],
    },
  ]
}
