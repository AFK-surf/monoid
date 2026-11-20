// On large-screen startup restoring to a chat with a login card (`machineLogin`) or service card (`job`), when the
// card topic has no local value yet and the core reports `waiting: true` (waiting on a remote station), `chat_opens`
// and the first page release immediately without hitting `first_page_ms` or showing the loading bar. When
// `waiting: false` (the local core has not answered yet), the first page still waits normally.

///|
let card_wait_margin_ms : Double = 50.0

///|
fn chat_with_service_link(base : Source) -> Source {
  {
    ..base,
    topic_read: fn(name, params) {
      let got = (base.topic_read)(name, params)
      if name == "chat" && got.value is Some(Object(o)) {
        let m : Map[String, Json] = Map([])
        for k, v in o {
          m[k] = v
        }
        let msgs : Array[Json] = match o.get("messages") {
          Some(Array(a)) => a.copy()
          _ => []
        }
        msgs.push({
          "seq": 999.0,
          "ts": "t999",
          "authorKind": "person",
          "text": "预览服务",
          "words": [
            {
              "text": "预览服务",
              "link": "https://app.still.fail/s/ws1/st1/service/j-web",
              "to": { "card": "service", "station": "ws1/st1", "job": "j-web" },
            },
          ],
          "by": { "name": "Ada" },
        })
        m["messages"] = Json::array(msgs)
        { ..got, value: Some(Json::object(m)) }
      } else {
        got
      }
    },
  }
}

///|
test "wide startup restoring to a chat with a login card: remote waiting releases first page immediately; local unanswered still waits" {
  for remote_waiting in [true, false] {
    new_run()
    let base = fixture("chat")
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        if name == "machineLogin" {
          { value: None, error: None, version: 0 }
        } else {
          base.topic(name, params).get().snapshot()
        }
      },
      waits: fn(name, _params) { name == "machineLogin" && remote_waiting },
    }
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    if remote_waiting {
      t.run_for(@sf.local_ms)
      assert_true(first_shown.get(), msg="machineLogin waiting=true must release first page immediately")
      assert_true(!@sfbase.first_page_waits.get(), msg="machineLogin waiting=true must clear first_page_waits")
      assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="no loading bar when machineLogin waits on station")
    } else {
      t.run_for(first_page_ms - card_wait_margin_ms)
      assert_true(!first_shown.get(), msg="machineLogin waiting=false must still hold first page before first_page_ms")
      assert_true(@sfbase.first_page_waits.get(), msg="machineLogin waiting=false must keep first_page_waits")
    }
  }
}

///|
test "wide startup restoring to a chat with a service job card: remote waiting releases first page immediately; local unanswered still waits" {
  for remote_waiting in [true, false] {
    new_run()
    let base = chat_with_service_link(fixture("chat"))
    let src : Source = {
      ..base,
      topic_read: fn(name, params) {
        if name == "job" {
          { value: None, error: None, version: 0 }
        } else {
          (base.topic_read)(name, params)
        }
      },
      waits: fn(name, _params) { name == "job" && remote_waiting },
    }
    open_chat({ station: "ws1/st1", session: "s-c1", title: "整理发布清单", station_name: "Willow" })
    let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=1280.0, h=800.0, platform=0)
    if remote_waiting {
      t.run_for(@sf.local_ms)
      assert_true(first_shown.get(), msg="job waiting=true must release first page immediately")
      assert_true(!@sfbase.first_page_waits.get(), msg="job waiting=true must clear first_page_waits")
      assert_true(t.find(tr("android-misc.workspaces.loading")) is None, msg="no loading bar when job waits on station")
    } else {
      t.run_for(first_page_ms - card_wait_margin_ms)
      assert_true(!first_shown.get(), msg="job waiting=false must still hold first page before first_page_ms")
      assert_true(@sfbase.first_page_waits.get(), msg="job waiting=false must keep first_page_waits")
    }
  }
}
