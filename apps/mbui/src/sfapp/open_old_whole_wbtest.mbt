// What an old body's sheet opened whole (sfbase's open_old_whole: the chat's 任务 sheet, an agent's card, its letters)
// asked ahead is held by that sheet while it is drawn and let go of once it is gone: it puts nothing on the stack, so
// handed to the stack's entry as a page's opening is, it was let go at once, its body then reading its jobs anew from
// nothing and drawing its bones (#6537 made the made-up core answer as a device's does, which showed it).
///|
test "a chat's 任务 sheet on 小屏 opened over a core that answers its jobs 40 ms late, then closed: what was asked for it held while it shows, let go of once it is gone" {
  new_run()
  app.nav.replace_above(0, [Home, Chat(layer_chat)])
  let sent : Array[String] = []
  let jobs_whole = fn(name : String, params : Map[String, Json]) { name == "chatJobs" && !params.contains("summary") }
  let src : Source = {
    ..round_trip_again(fixture("settings"), 0.0, heard=fn(m) { if m.has_prefix("out ") { sent.push(m) } }, late=fn(name, params) {
      if jobs_whole(name, params) { open_late_ms } else { 0.0 }
    }),
    reads_ahead: fn() { true },
    gates_opens: fn() { true },
  }
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0)
  t.draw()
  t.run_for(@ui.move_most_ms * 2.0)
  @ui.view_tree().unwrap().event(t.time(), fn() { open_chat_jobs(src, layer_chat) })
  t.run_for(open_late_ms + @ui.move_most_ms * 2.0)
  assert_eq(t.bones_drawn(), 0)
  let jobs_ids = fn() {
    let asked : Array[Int] = []
    let gone : Array[Int] = []
    for m in sent {
      let j = @json.parse(m[4:].to_owned()) catch { _ => continue }
      match j {
        Object(o) =>
          match (o.get("id"), o.get("subscribe"), o.get("unsubscribe")) {
            (Some(Number(n, ..)), Some(Object(s)), _) if s.get("topic") == Some(Json::string("chatJobs")) &&
              !s.contains("summary") => asked.push(n.to_int())
            (Some(Number(n, ..)), _, Some(True)) => gone.push(n.to_int())
            _ => ()
          }
        _ => ()
      }
    }
    (asked, gone)
  }
  let (asked, gone) = jobs_ids()
  assert_true(asked.length() > 0 && asked.iter().any(fn(id) { !gone.contains(id) }), msg="its jobs held while it shows: asked \{Repr(asked)}, let go of \{Repr(gone)}")
  @ui.view_tree().unwrap().event(t.time(), fn() { @sf.close_presented_of(@sf.last_presented()) })
  t.run_for(@ui.move_most_ms * 2.0)
  let (asked, gone) = jobs_ids()
  assert_true(asked.iter().all(fn(id) { gone.contains(id) }), msg="its jobs let go of once it is gone: asked \{Repr(asked)}, let go of \{Repr(gone)}")
}
