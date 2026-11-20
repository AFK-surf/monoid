// A message's picture as nodes of the window's tree (message_files.mbt's image_item, image_coming): in the box its data
// says (image_box: laid out so before it is decoded, nothing of it changing as it is), what it waits on (its likeness
// made of its ThumbHash, else the neutral ground) till its host says it is decoded, then brushed in
// (@sf.image_reveal_node) where its message is new while the chat shows (MessageFilesAt's `said`), else whole the
// moment it is decoded; one sent from here, or one the device had, as it is. Asked of its station and not here yet,
// all of what stands in for it breathes (@sf.breathe_node), back to whole once it is; how far it has come in a pill at
// its foot's end from 300 ms after it was first said to be on its way (fading in over 200), from that moment on the
// timeline, never from when its row was made. One that cannot be had says so; one its station could not be reached
// for, pressed, is asked again. Pressed, the preview; right clicked, its menu where; held by a finger, its menu, the
// picture lifted over the menu's scrim while it is up (@sf.lift_node). Its box is the end of the preview's flight that
// stays (View::shared), by its thumbnail's id: the preview's picture flies from it and back into it, out from under
// the chat's bar or composer first where they cover it.

///|
/// A message's picture `a` (as it is now) in `parent`, `w()` by `h()` (its box: image_box's at most the width given, bound:
/// the width given changing changes its size alone, the same nodes kept, what is held on it and how it came in), for
/// where it is shown (`place`, `at()`: as it is now, a message sent from here named by the chat's once it is the chat's)
/// and whose message it is (`by`, for 引用); `corner` how round it is (a message's file's, or a quote's own picture's,
/// concentric with its card: quote_picture_corner). What shows of it (its share of the box, what it is decoded for, where
/// it is cut from) is bound to its data too: a message sent from here, made before the core said its picture's size and
/// told it as the core's row takes it over, keeps the same nodes, its flight and how it came in. `flies`: made in the
/// change in which it is sent, how its picture flies from where it stood in the composer then (sent_flies:
/// image_reveal_node's `flies`).
fn message_image_node(
  parent : @view.View,
  src : Source,
  place : MessageFilesAt,
  a : () -> Attachment,
  by : () -> (String, String, String)?,
  at : () -> String,
  w : () -> Double,
  h : () -> Double,
  corner? : Double = @sf.message_file_corner,
  flies? : ((@view.View) -> Unit)? = None,
) -> Unit {
  let station = fn() { (place.station)() }
  let owner = fn() { owner_of(place.here(), a()) }
  let name = fn() { stored_name(a().path) }
  let id = fn() { @sfbase.file_image_id(station(), owner(), name()) }
  // (still going up: no station has it to ask yet)
  let going_up = fn() { a().upload != "" && a().path == @sfbase.upload_path(a().upload) }
  let sent = fn() { @sfbase.sent_picture_told(station(), a()) }
  // its image's key: one sent from here the picture it was picked as; else its station's ("" while it comes, "!" none)
  // (worked out once as what it reads changes: what stands in for the picture, its frame and the picture itself each
  // read it, again and again)
  let keyed = @signals.computed(
    fn(_) {
      match sent() {
        Some(k) => k
        None => if going_up() { "" } else { src.file_told(station(), owner(), name()) }
      }
    },
  )
  let key = fn() { keyed.get() }
  let unreached = fn() { key() == "!" && sent() is None && src.images.unreached_told(id()) }
  // (one sent from here or the device's: as it is, no brushing in)
  let as_is = fn() { sent() is Some(_) || src.images.held_told(id()) }
  // asked of its station and not here yet
  let asked = fn() { key() == "" && !going_up() }
  let letterbox = fn() { image_box(a(), image_least, min_side=image_min_side).2 }
  let thumb = fn() {
    @sfbase.thumb_place(station() + "/" + owner() + "/" + a().path, station(), (place.session)(), at())
  }
  // (the picture's share of the box: all of it, or a letterboxed one's own proportions in its middle; and the box at
  // its largest, as its data says it, what it is decoded for and its likeness made of whatever width it is given)
  let share = fn() { picture_share(a(), image_least, min_side=image_min_side) }
  let most = fn() {
    let (nw, nh, _) = image_box(a(), image_least, min_side=image_min_side)
    let (sw, sh) = share()
    (nw * sw, nh * sh)
  }
  let start_crop = fn() { image_cropped_from_start(a()) }
  let likeness = fn() {
    let th = @ui.tree_theme()
    let (mw, mh) = most()
    image_wait_colours(a().thumbhash, mw, mh, th.color(Neutral), th.color(Bg)).unwrap_or("")
  }
  // the menu up by a finger's hold (its serial among what is presented: lifted while it is drawn)
  let held_menu : @signals.Signal[Int?] = @signals.signal(None)
  let pressed = fn() {
    if unreached() {
      src.images.again(station())
    } else {
      open_file(place.here(), a(), at=at())
    }
  }
  @sf.action_box_node(parent, fn() { @sf.t("web-main.file.view", args=[("name", a().name)]) }, fn(_) { pressed() }, fn(f) {
    // (all of it kept, one value, as it comes to another: what is bound to it worked out again only then, not as the
    // message's data is said again with its size, its picture's share and its likeness the same: @sf.value_kept)
    let kept = @sf.value_kept(f, fn() { (w(), h(), share(), most(), start_crop(), likeness()) })
    let w = fn() { kept().0 }
    let h = fn() { kept().1 }
    let share = fn() { kept().2 }
    let most = fn() { kept().3 }
    let pw = fn() { w() * share().0 }
    let ph = fn() { h() * share().1 }
    let start_crop = fn() { kept().4 }
    let likeness = fn() { kept().5 }
    @sf.style_node(f, fn() {
      (if key() != "!" || letterbox() { image_frame } else { image_frame_waiting })
      .then(@ui.style(w=Fixed(w()), h=Fixed(h())))
      .then(frame_corner_node(corner))
    })
    let open_menu = fn(x : Double, y : Double, finger : Bool) {
      let here = place.here()
      let a = a()
      let shown = key()
      menu_doing.offered = shown
      let items : Array[@sf.MenuItem?] = []
      match quote_of(here, a, owner_of(here, a), by()) {
        Some(q) => items.push(Some(@sf.menu_item_of(@sf.t("web-main.chat.quote"), q, icon="quote")))
        None => ()
      }
      // (those offered here alone, no line where one is not: message_files's file_options)
      for x in [beside_option(here, a, @signals.untracked(at)), download_option(src, here, a, owner_of(here, a))] {
        if x is Some(_) {
          items.push(x)
        }
      }
      with_reveal(src, here, a, owner_of(here, a), fn(reveal) {
        if reveal is Some(_) {
          items.push(reveal)
        }
        if shown != "" && shown != "!" {
          items.push(Some(@sf.menu_item_of(@sf.t("desktop.contextMenu.copyImage"), fn() { menu_doing.image.set(shown) }, icon="copy")))
        }
        message_items_after(items, place.share)
        @sf.menu(items, from=@sf.at_point(x, y))
        held_menu.set(if finger { Some(@sf.last_presented()) } else { None })
      })
    }
    // (right clicked, its menu where the pointer is; held by a finger, there, felt, the press the menu's)
    @sf.menu_presses_node(f, pressed, open_menu)
    // held by a finger for its menu: lifted over the menu's scrim while that menu is drawn
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
    // (the end of the preview's flight that stays, by its thumbnail's id: drawn nowhere while the preview shows it,
    // its picture flown from here and back here, View::shared's `stays`, drawn on its way as here: covering its box,
    // from its start where it is cut so, from its middle else, or a letterboxed one contained (said covering from
    // somewhere, it covers whatever else is said; said none, contained): one binding for all three)
    f
    .image_contains(Is(true))
    .image_covers_at(
      By(fn() {
        if start_crop() {
          Some((0.0, 0.0))
        } else if letterbox() {
          None
        } else {
          Some((0.5, 0.5))
        }
      }),
    )
    .shared(By(thumb), @motion.flight_by(@motion.moved()), stays=true)
    |> ignore
    f.pick(at_once=true, fn() { key() == "!" }, fn(p, none) {
      // (all of its box, a share of it as the frame's size is said: what is in it laid out in it, its middle the box's)
      p.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
      if none {
        // one that cannot be had: its mark over 无法预览 (加载失败，点按重试 where its station was not reached)
        p.box(fn(n) {
          @sf.style_node(n, fn() { no_preview_box })
          @sf.icon_node(n, "read", no_preview_icon, By(fn() { @sf.theme().p.muted })) |> ignore
          @sf.words_node(
            n,
            fn() { @sf.t(if unreached() { "web-main.file.loadAgain" } else { "web-main.file.noPreview" }) },
            fn() { no_preview_words },
          )
          |> ignore
        })
        |> ignore
      } else {
        // what stands in for it, all of it breathing while it is asked of its station
        p.box(fn(s) {
          // (what shows of it in its middle: a letterboxed one's own proportions, else all of the box; the same nodes
          // either way, so its data told anew changes what shows of it alone: letterbox_room's, in this node itself)
          @sf.style_node(s, fn() {
            if key() != "" || letterbox() || likeness() != "" {
              letterbox_room
            } else {
              letterbox_room_waiting
            }
          })
          @sf.breathe_node(s, waits=asked)
          let picture = fn(v : @view.View) {
            @sf.image_reveal_node(
              v,
              key,
              likeness,
              pw,
              ph,
              held=as_is,
              comes=place.said,
              start_crop~,
              decoded_for=fn() { dmax(most().0, most().1) },
              flies~,
              corner~,
            )
            |> ignore
          }
          picture(s)
        })
        |> ignore
      }
    })
    |> ignore
    image_coming_node(f, src, place, a, id, asked, corner)
  })
  |> ignore
}

///|
/// How far a message's picture has come, in a pill at its box's foot's end (image_coming's): while the core downloads
/// it, how much of it is here; while it is asked of its station, how far that has come as the core says it (its size
/// not known, the spinner and the bytes so far); nothing heard yet, nothing. Shown from coming_after_ms after it was
/// first said to be on its way (ChatImages::coming_since: its picture's, or its download's), fading in
/// over coming_in_ms, at that moment on the timeline.
fn image_coming_node(
  parent : @view.View,
  src : Source,
  place : MessageFilesAt,
  a : () -> Attachment,
  id : () -> String,
  asked : () -> Bool,
  corner : Double,
) -> Unit {
  let downloading = fn() {
    let a = a()
    download_of(src, (place.station)(), owner_of(place.here(), a), stored_name(a.path))
  }
  let loading = fn() { flag(downloading(), "active") }
  // what is on its way: its download (1), its picture asked of its station (2), nothing (0)
  let which = fn() {
    if loading() {
      1
    } else if asked() {
      2
    } else {
      0
    }
  }
  // how far: the bytes here and of how many where known
  let how_far = fn() -> (Double, Double?)? {
    match which() {
      1 => {
        let d = downloading()
        let total = number(d, "size")
        Some((number(d, "loaded"), if total > 0.0 { Some(total) } else { None }))
      }
      2 => src.images.coming_told(id())
      _ => None
    }
  }
  let shown = @signals.signal(false)
  let fade = @motion.NodeWay::new(0.0)
  let due : Ref[() -> Unit] = Ref(fn() {  })
  parent.reacts(which, fn(w) {
    (due.val)()
    due.val = fn() {  }
    let now = parent.cause_at()
    let since = match w {
      1 => Some(src.images.coming_since(download_key(place, a), now))
      2 => Some(src.images.coming_since(@signals.untracked(id), now))
      _ => None
    }
    if w != 1 {
      src.images.coming_let_go(download_key(place, a))
    }
    match since {
      None => {
        fade.put(0.0)
        shown.set(false)
      }
      Some(t) => {
        let from = t + coming_after_ms
        if now >= from + coming_in_ms {
          fade.put(1.0)
          shown.set(true)
        } else if now >= from {
          // (made again on its way in: on from where it is then)
          let k = (now - from) / coming_in_ms
          fade.go_from(parent, k, 1.0, @motion.tween(coming_in_ms * (1.0 - k), ease=Linear))
          shown.set(true)
        } else {
          fade.put(0.0)
          shown.set(false)
          due.val = parent.at_moment(from, fn() {
            fade.go_ms(parent, 1.0, coming_in_ms, ease=Linear)
            shown.set(true)
          })
        }
      }
    }
  })
  parent.box(fn(room) {
    room.over(Is(true)) |> ignore
    // (in a corner other than a message's file's, as far in as makes it concentric with that: image_coming's)
    // (as high as its words' line where the system's size of words draws it higher than said, concentric with its
    // corner so: coming_pill_high)
    @sf.style_node(room, fn() {
      let h = coming_pill_high(room.words_scale())
      if corner == @sf.message_file_corner && h == coming_pill_h {
        coming_room
      } else if corner == @sf.message_file_corner {
        coming_room.then(@ui.style(p=@sf.room_of(@ui.capsule_in(@sf.message_file_corner, h))))
      } else {
        coming_room.then(@ui.style(p=@sf.capsule_fit_room(corner, h, coming_alone_in)))
      }
    })
    room.show(at_once=true, fn() { shown.get() && how_far() is Some(_) }, fn(s) {
      s.box(fn(pill) {
        @sf.style_node(pill, fn() {
          let h = coming_pill_high(pill.words_scale())
          if h == coming_pill_h {
            coming_pill
          } else {
            coming_pill.then(@ui.style(h=Fixed(h)))
          }
        })
        pill.alpha(By(fn() { fade.shown(pill) })) |> ignore
        pill.pick(at_once=true, fn() { how_far().map_or(false, fn(c) { c.1 is Some(_) }) }, fn(q, known) {
          // (its ring and its words along the pill, as the pill lays them)
          @sf.style_node(q, fn() { coming_pill_row })
          if known {
            let part = fn() {
              match how_far() {
                Some((n, Some(total))) => dmin(1.0, n / total)
                _ => 0.0
              }
            }
            @sf.progress_ring_node(q, coming_ring, part, fn() { @sf.white }) |> ignore
            @sf.words_node(q, fn() { "\{(part() * 100.0).floor().to_int()}%" }, fn() { coming_words }) |> ignore
          } else {
            @sf.spinner_node(q, size=coming_ring, ring=fn() { coming_track }, arc=fn() { @sf.white }) |> ignore
            @sf.words_node(q, fn() { @sf.file_size(how_far().map_or(0.0, fn(c) { c.0 })) }, fn() { coming_words })
            |> ignore
          }
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// A message's file's download, by where it is kept (its station, the session keeping it, its name), among what the
/// chat's pictures keep of what is on its way (ChatImages::coming_since): apart from its picture's own.
fn download_key(place : MessageFilesAt, a : () -> Attachment) -> String {
  @signals.untracked(fn() {
    let a = a()
    "download\u{1}" + @sfbase.file_image_id((place.station)(), owner_of(place.here(), a), stored_name(a.path))
  })
}

///|
/// How high a picture's pill of how far is drawn at the system's size of words `scale`: as high as its words' line
/// where that is higher than said (coming_pill_h), as the library's box_at has a video's capsule; the old view's kept
/// it as said, its words over its foot.
fn coming_pill_high(scale : Double) -> Double {
  let look = @ui.style_words(coming_words)
  let line = if look.line < 0.0 { -look.line * @ui.sp_at(scale, look.size) } else { @ui.sp_at(scale, look.line) }
  if line > coming_pill_h {
    line
  } else {
    coming_pill_h
  }
}

///|
/// What a pill of how far holds, along it (coming_pill's row: its ring and its words 4 apart, in its middle).
// kept across runs: a value (no field of it changes)
let coming_pill_row : @ui.Style = @ui.css("row gap=S1 align=ACenter")
