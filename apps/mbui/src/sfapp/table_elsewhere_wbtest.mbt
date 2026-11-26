// A table in what an agent said elsewhere (a Slack or Feishu thread's reply, sent_elsewhere_body's), as wide as an agent's
// own words' tables are: slid sideways out over the row's side to the pane's edge, not cut at the words' column (the
// user, 2026-11-26: a reply sent to Slack had its table cut at the column on both sides).

///|
/// A reply sent elsewhere with a table too wide for the column, as chat-feishu's agent's reply says it.
let elsewhere_table : String =
  #|对比如下：
  #|
  #|| 机制 | 现状 | 可行性 | 适合承担的职责 | 主要限制 / 坑点 |
  #||---|---|---|---|---|
  #|| 甲机制名称写长一些 | 已内置 CONFIG_NFT_TPROXY=y、CONFIG_NFT_REDIR=y、CONFIG_TUN=y | 立即可用（最推荐） | 网关侧对其他 VM 的转发流量做 L4 TPROXY | 需维护 nftables 规则与策略路由；UDP 仅支持 prerouting 路径 |

///|
test "a table in an agent's reply sent elsewhere, slid sideways on a wide list: out over the margin, not cut at the words' column" {
  new_run()
  let base = fixture("chat-feishu")
  let src : Source = {
    ..base,
    topic_read: fn(name, params) {
      let tp = base.topic(name, params).get().snapshot()
      match (name, tp.value) {
        ("chat", Some(Object(m))) =>
          match m.get("elsewhere") {
            Some(Array(es)) => {
              let v = m.copy()
              v["elsewhere"] = Json::array(
                es.map(fn(e) {
                  match e {
                    Object(o) if o.get("key") == Some(Json::string("out-1")) => {
                      let o2 = o.copy()
                      o2["text"] = Json::string(elsewhere_table)
                      Json::object(o2)
                    }
                    _ => e
                  }
                }),
              )
              { ..tp, value: Some(Json::object(v)) }
            }
            _ => tp
          }
        _ => tp
      }
    },
  }
  open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=2)
  t.run_for(@ui.move_most_ms)
  let cell = "甲机制名称写长一些"
  let (x, y) = t.drawn_of(cell).unwrap()
  // (the words' column starts where its first column's words do, at rest)
  let column = x
  t.press_at(x + 600.0, y)
  for step in 1..=10 {
    t.move_to(x + 600.0 - step.to_double() * 40.0, y)
  }
  t.run_for(long_press_ms)
  t.release(x + 200.0, y)
  let (shown, _, _, _) = t.shown_of(cell).unwrap()
  assert_true(shown < column - 1.0, msg="\{Repr((shown, column))}")
}
