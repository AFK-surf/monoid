// A message's video as nodes of the window's tree (message_files.mbt's video_item): its still on black, its capsule,
// its menu (加载 / 停止加载 with the rest), lifted while a finger's hold has it up.

///|
/// A message's video `a` in `parent` (video_item's), `w()` by `h()` (bound: the width given changing changes its size
/// alone, the same nodes kept, its still as it was and what is held on it), named where it is by `at()` as it is now
/// (thumb_occurrence's): its still on black (the frame the preview was left at,
/// one sent from here the picture it was picked as, else its station's: @sfbase.video_still_node), contained where it
/// is letterboxed, its capsule in its foot's start corner (how long it is). Pressed, the preview (not while it goes
/// up); right clicked, its menu where; held by a finger, its menu, the video lifted while it is up: 引用, 在侧边打开,
/// 下载, and 加载 (brought onto this device before everything else) or 停止加载 while it is brought. Its name whole in a
/// tip in `tips` while what it shows shows cut short (video_item's, repeats). Made for one file (its still is read for
/// it): another in its place is made anew. While the core downloads it, or brings it after all else (加载, or opened
/// and let go: fill.ts), how far on its capsule (video_item's). What it reads of its data is bound: one sent from here,
/// told its station's path and length as the core's row takes it over, has its still read anew for the file it is then
/// (its station's, or the frame the preview was left at, kept by that file's id) and its capsule's length as told.
fn message_video_node(
  parent : @view.View,
  src : Source,
  tips : @sf.TipLayer,
  place : MessageFilesAt,
  a : () -> Attachment,
  by : () -> (String, String, String)?,
  at : () -> String,
  w : () -> Double,
  h : () -> Double,
  corner? : Double = @sf.message_file_corner,
  flies_from? : (Double, Double, Double, Double)? = None,
) -> Unit {
  let station = fn() { (place.station)() }
  let owner = fn() { owner_of(place.here(), a()) }
  let going_up = fn() { a().upload != "" && a().path == @sfbase.upload_path(a().upload) }
  let letterbox = fn() { image_box(a(), video_least).2 }
  let thumb = fn() {
    @sfbase.thumb_place(station() + "/" + owner() + "/" + a().path, station(), (place.session)(), at())
  }
  let held_menu : @signals.Signal[Int?] = @signals.signal(None)
  // (said the one its thumbnail's id names as it is pressed: note_thumb_node's)
  let chosen : Ref[() -> Unit] = Ref(fn() {  })
  // (its capsule seen once it is here, where it flies here from the composer's tile: none of it on the way, coming in
  // over dur_ms from its landing, as the old page's video_item's marks; at once otherwise)
  let marks = @motion.Way::new(1.0)
  // (on its way from the composer's tile till it lands: its still covering the box the way has)
  let flying = @signals.signal(flies_from is Some(_))
  parent.box(fn(f) {
    @sf.style_node(f, fn() { video_frame.then(@ui.style(w=Fixed(w()), h=Fixed(h()))).then(frame_corner_node(corner)) })
    // (sent from here a moment ago: from where its tile stood in the composer, its still in its frame all the way, as a
    // picture's flies: message_files_node's `from`, View::flies_in)
    match flies_from {
      Some(from) => {
        f.radius(Is(corner)).flies_in(sent_part_flight, fn(_) { Some(from) }, up_late=sent_up_late) |> ignore
        marks.put(0.0)
        marks.go(1.0, @motion.tween(@sf.dur_ms, ease=Out), at=f.cause_at() + @sfbase.flight_desk_ms)
        f.at_moment(f.cause_at() + @sfbase.flight_desk_ms, fn() { flying.set(false) }) |> ignore
      }
      None => ()
    }
    f.says(By(fn() { Some(@view.said(Button, label=@sf.t("web-main.file.play", args=[("name", a().name)]))) })) |> ignore
    // (its name, which nothing over its picture says, whole by it while what it shows shows cut short: video_item's tip)
    @sf.tip_node(tips, f, fn() { a().name }, repeats=true) |> ignore
    // its still: what the viewer left, one sent from here, its station's (going up: the picture this device has)
    // (made anew for the file it is now: one sent from here, its station's once the core's row takes it over, whose
    // frame the preview was left at is kept by that one's id)
    let file_id = fn() { station() + "/" + owner() + "/" + a().path }
    // (what reads its still, a function: no value of it to compare, told as it is made anew)
    let station_still : @signals.Signal[(() -> String)?] = @signals.signal_ref(None)
    f.reacts(file_id, fn(id) {
      if !@signals.untracked(going_up) {
        station_still.set(Some(@sfbase.video_still_node(f, src, station(), owner(), a(), id)))
      }
    })
    let still = fn() {
      if going_up() {
        @sfbase.sent_picture_told(station(), a()).unwrap_or("")
      } else {
        match station_still.get() {
          Some(made) => made()
          None => ""
        }
      }
    }
    let open_menu = fn(x : Double, y : Double, finger : Bool) {
      let here = place.here()
      let a = a()
      let owner = owner_of(here, a)
      let name = stored_name(a.path)
      let items : Array[@sf.MenuItem?] = []
      match quote_of(here, a, owner, by()) {
        Some(q) => items.push(Some(@sf.menu_item_of(@sf.t("web-main.chat.quote"), q, icon="quote")))
        None => ()
      }
      // (those offered here alone, no line where one is not: message_files's file_options)
      for x in [beside_option(here, a, @signals.untracked(at)), download_option(src, here, a, owner)] {
        if x is Some(_) {
          items.push(x)
        }
      }
      // (being downloaded to be saved, or going up: nothing to load or stop here)
      if !going_up() && !flag(download_of(src, here.station, owner, name), "active") {
        match keeping_of(src, here.station, owner, name) {
          Some(_) as brought => {
            let id = text(brought, "id")
            items.push(Some(@sf.menu_item_of(@sf.t("web-main.file.stopLoading"), fn() { keeping_stop(src, id) }, icon="stop")))
          }
          None => {
            let (station, size) = (here.station, a.size)
            let from : Map[String, Json] = { "session": Json::string(here.session), "file": attachment_json(a, a.owner) }
            match here.view.thread {
              Some(n) => from["thread"] = Json::number(n)
              None => ()
            }
            items.push(
              Some(
                @sf.menu_item_of(@sf.t("web-main.file.load"), fn() { fill_want(src, station, owner, name, size, Json::object(from)) }, icon="download"),
              ),
            )
          }
        }
      }
      @sf.menu(items, from=@sf.at_point(x, y))
      held_menu.set(if finger { Some(@sf.last_presented()) } else { None })
    }
    @sf.menu_presses_node(
      f,
      fn() {
        if !going_up() {
          (chosen.val)()
          open_file(place.here(), a(), at=at())
        }
      },
      open_menu,
    )
    @sf.lift_node(
      f,
      fn() { false },
      fn() {
        match held_menu.get() {
          Some(s) => @sf.presented_drawn_of(s)
          None => false
        }
      },
      file_lift_scale,
    )
    |> ignore
    // (what the preview flies from and back into, by its thumbnail's id: hidden while the preview shows it, its still
    // flown from here and back here by the viewer, its capsule with it, under the page's bar while it is under it)
    chosen.val = @sfbase.note_thumb_node(
      f,
      thumb,
      radius=corner,
      letterbox~,
      picture=fn() {
        match still() {
          "!" => ""
          k => k
        }
      },
      duration=fn() { a().duration },
    )
    // the black and its still drawn as one, its edge cut once (the black under a picture cut apart from it left a rim
    // at their rounded edge): the black round a letterboxed one (contained in its own proportions, in the middle) and
    // all of it while it is decoded
    let share = fn() { picture_share(a(), video_least) }
    // (decoded for its box at its largest, as its data says it: a width given changing asks no other decode)
    let (nw, nh, _) = @signals.untracked(fn() { image_box(a(), video_least) })
    f.box(fn(s) {
      s
      .width(By(fn() { Some(w()) }))
      .height(By(fn() { Some(h()) }))
      .image(By(fn() {
        let k = still()
        if k == "" || k == "!" {
          None
        } else {
          // (decoded as large as it is drawn, reveal_px's: asked so by what draws it, as it comes to it)
          let px = dmin(dmax(nw, nh) * s.pixel_scale(), image_px_most)
          Some((k, "", px.to_int()))
        }
      }))
      // (no still to show: the black alone)
      .ground(By(fn() {
        let k = still()
        if k == "" || k == "!" {
          @ui.tree_theme().color(@sf.video_ground)
        } else {
          0L
        }
      }))
      .image_covers(By(fn() { !letterbox() }))
      // (a letterboxed one's own proportions in the middle, the black round it, else all of its box; on its way from a
      // tile (flies_in) one not letterboxed covering the box the way has, never its box at rest scaled in it with the
      // black under it)
      .image_in(By(fn() {
        guard letterbox() || !flying.get() else { return None }
        let (w, h) = (w(), h())
        let (sw, sh) = share()
        let (pw, ph) = (w * sw, h * sh)
        Some((((w - pw) / 2.0, (h - ph) / 2.0, pw, ph), @ui.tree_theme().color(@sf.video_ground)))
      }))
      .image_fades(Is(true))
      |> ignore
    })
    |> ignore
    f.box(fn(o) {
      o.over(Is(true)).width(By(fn() { Some(w()) })).height(By(fn() { Some(h()) })) |> ignore
      o.alpha(By(fn() { marks.shown_on(o) })) |> ignore
      // (downloading, else brought after all else: how far)
      let coming = fn() -> Double? {
        let name = stored_name(a().path)
        let dl = download_of(src, station(), owner(), name)
        if flag(dl, "active") {
          Some(number(dl, "progress"))
        } else {
          match keeping_of(src, station(), owner(), name) {
            Some(_) as kept => Some(number(kept, "progress"))
            None => None
          }
        }
      }
      // (its length as its data says it now: one sent from here told it as the core's row takes it over)
      o.pick(at_once=true, fn() { a().duration }, fn(k, duration) {
        k.over(Is(true)) |> ignore
        @sf.video_capsule_node(k, duration, corner~, coming~)
      })
    })
    |> ignore
  })
  |> ignore
}
