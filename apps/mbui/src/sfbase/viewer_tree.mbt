// The image viewer as nodes of the window's tree (every shell's: sfapp's narrow_shell.mbt, tape_shell.mbt;
//), made as it opens and let go as it has gone, over the pages:
//
//   - its layer: the whole window, a modal layer while it is the one open (View::modal: what is under it, the pages
//     and what the shell draws round them, takes no press, key, wheel or stop of Tab, and is read out none, as the old
//     frame's modal overlay made it; closing, theirs again as it begins to go);
//   - its ground: the canvas's colour, as far in as the viewer has come (its flight, its fade), sampled as each frame
//     draws it while either goes;
//   - its canvas: what a finger does on the picture is this node's, each event at its own moment (one finger drags,
//     two pinch, a tap shows or hides the bars, two zoom, a hold opens the picture's menu, marking draws), and so the
//     secondary button (the picture's menu) and the wheel; the zoom told the stage's size and the picture's as either
//     changes, at that moment; what is beside it read ahead as that is said;
//   - in it, the picture where its zoom has it, moved across with the strip as the frame draws it, the one going and
//     those beside it while the strip moves, why it is not shown where it could not be decoded, the small decode that
//     learns a size not known, the marks and their pins, its flight, nodes; the words being written a field of the
//     tree's (marks_writing_node);
//   - over it the bars: the floating bar on a small screen, its picture coming, whole or marked, nodes of its own
//     (image_head, head_as_nodes: how much of it has come, its tools or marking's actions, their tips); the bar across
//     the top of a wider screen, the same, nodes too (image_bar, bar_as_nodes); the ways to the pictures beside it
//     while it is not marked (image_steps); marking's foot while it is (marks_foot_node: its tools, the notes' cards,
//     the note being written, what is written in it a field of the tree's); beside the system's bars (an iPhone Duo's),
//     its actions in theirs, said to them as what it says changes (native_said).
//
// It sets out as the node is made (that moment its cause's: the thumbnail tapped), and is done at its ways' declared
// ends (moments on the node's timeline): landed, the thumbnail shows again; gone, it is let go.
//
// What a download, a save or marking's picture asks is done by the layer at its cause (image_layer), whichever bar
// asked.
//
// No old view of its own is left in it: what is written, over the picture or in a note, is the window's tree's fields
// (@ui.field).


///|
/// The viewer the window's tree draws: the one open, else the one going (all of them: a film's and a song's too, its
/// player hosted on its stage, viewer_player).
fn tree_viewer() -> Viewer? {
  match viewer.get() {
    Some(v) => Some(v)
    None => pv_leaving.get()
  }
}

///|
/// Whether it is a film or a song, played in the player (@sf.player_node): as its name says it from the start.
pub fn Viewer::played(self : Viewer) -> Bool {
  self.kind == Some(KVideo) || self.kind == Some(KAudio)
}

///|
/// Whether it shows a picture of its own on its stage, to zoom, step, fly and mark (an image not too big to show): the
/// window's tree's nodes draw it and its bars; anything else it shows, and its bars, its old views hosted there
/// (viewer_hosted).
pub fn Viewer::markable(self : Viewer) -> Bool {
  self.shown_kind() == Some(KImage) && self.file.size <= big_file
}

///|
/// The image viewer in node `v` of the window's tree (laid out over the pages: narrow_shell, tape_shell), made as one opens and let
/// go as it has gone; another opened (a step to the one beside it) another node.
/// `stage`: how big the room it is laid out in is (the window's, less what the shell keeps clear of the system's bars),
/// what its picture is fitted to, as it changes.
pub fn viewer_node(v : @view.View, src : Source, stage : () -> (Double, Double)) -> Unit {
  // (at once: it comes and goes with the viewer's own flight and fade, so the layer has no way of its own; let go as the
  // viewer leaving is, it would set out on one long after anything shows of it)
  v.pick(
    at_once=true,
    fn() {
      match tree_viewer() {
        Some(vw) => vw.serial
        None => 0
      }
    },
    fn(n, serial) {
      match tree_viewer() {
        // (over the pages, the whole of the room it is given: not one more of what is laid out after them)
        Some(vw) if serial > 0 && vw.serial == serial => {
          n.over(Is(true)) |> ignore
          n.box(fn(layer) { image_layer(layer, src, vw, stage) }) |> ignore
        }
        _ => ()
      }
    },
  )
}

///|
/// Viewer `vw`'s layer, node `n` (viewer_node's).
fn image_layer(n : @view.View, src : Source, vw : Viewer, stage : () -> (Double, Double)) -> Unit {
  // (over the pages, a modal layer: what is under it (the pages, the bar, what the shell draws round them) takes no key,
  // no wheel, no stop of Tab, and is read out none, as the old frame's modal overlay made it; what opens over all of it,
  // a menu, a sheet, its own)
  n
  .over(Is(true))
  // (while it is the one open: closing, the pages' input theirs again as it begins to go, whatever is still drawn)
  .modal(By(fn() {
    match viewer.get() {
      Some(v) => physical_equal(v, vw)
      None => false
    }
  }))
  // (its keys, at their moment, where nothing over it (a menu, a field being written in) takes them first)
  .on_key(fn(k) { vw.key_on(src, k) })
  // (back: leaving marking first, else closing it; a sheet, a menu over it, theirs first: Ctx::back_taker)
  .takes_back(fn() {
    if !vw.closing {
      if marking.on {
        marks_back()
      } else {
        vw.shut_tree()
      }
    }
  })
  |> ignore
  // (its layer made again for another tier of the window, this one let go of after it as what is shared in it is
  // let go of as the change is committed: only the one it is in now says it is out of the tree)
  vw.tree_layers += 1
  let layer = vw.tree_layers
  vw.in_tree = true
  n.owns(fn() {
    if vw.tree_layers == layer {
      vw.in_tree = false
    }
    (vw.hold_off)()
    (vw.tap_off)()
    (vw.wheel_off)()
    vw.fingers.clear()
  })
  |> ignore
  // set out as it is made: the moment of what opened it
  vw.set_out(@ui.current(), src, n.cause_at())
  // (what marking stamps what it makes by: this source's clock, as the old view's said it each frame)
  src_now.val = src.now
  image_ends(n, vw, src)
  // what marking made, taken as the host says it is drawn (MarkedImage::ready, its answers' signal): kept, or into the
  // chat's draft, once (Viewer::marks_frame takes it), by this viewer while it is the one open and its layer here; a
  // drawing another by its id, whatever it drew
  n.reacts(
    fn() {
      marks_said()
      match marking.job {
        Some(j) => Some((j.id(), j.ready()))
        None => None
      }
    },
    fn(job) {
      match (job, viewer.get()) {
        (Some((_, true)), Some(v)) if physical_equal(v, vw) && !vw.closing => vw.marks_frame(@ui.current())
        _ => ()
      }
    },
  )
  // what was asked to be saved: a chat's file's download said to the core at the moment it was asked; what was asked
  // for before it was here saved as its whole comes; each once (Viewer::ask_save)
  n.reacts(fn() { (vw.asked_told.get(), vw.bytes.get() is Some(_), vw.previewed.get()) }, fn(_) {
    download_told(src, vw)
    if vw.whole_here() is Some(_) {
      if vw.save_after {
        vw.save_after = false
        vw.save_tree()
      }
      vw.share_came()
      vw.copy_came()
      vw.marks_finish_came()
    }
  })
  // what it reads asked of the core as what it needs comes (its kind sniffed, its bytes, a read failed)
  // (and as it is asked for: 下载 on one told of, 安装, its whole read first: Viewer::ask_save, ask_install)
  n.reacts(
    fn() {
      (
        vw.sniffed.get(),
        vw.bytes.get() is Some(_),
        vw.error.get() is Some(_),
        vw.fetching.get(),
        vw.asked_told.get(),
        vw.whole_due(),
      )
    },
    fn(_) { vw.fetch(src) },
  )
  // release the preview image once the whole image is decoded so host memory stays bounded
  n.reacts(
    fn() {
      vw.bytes.get() |> ignore
      vw.preview_image != "" &&
      vw.image != "" &&
      vw.image != vw.preview_image &&
      @ui.image_any_ready(vw.image)
    },
    fn(ready) {
      if ready {
        vw.drop_preview_image()
      }
    },
  )
  // zoomed in past fitted (or gliding there): the image itself asked for in place of its preview (Viewer::whole_due);
  // once asked, wanted till it comes, zoomed out again or not
  n.reacts(
    fn() {
      vw.zoom.told()
      let z = vw.zoom
      z.nw > 0.0 && (if z.gliding { z.g_to[0] } else { z.scale }) > z.fit() * 1.01
    },
    fn(zoomed) { if zoomed { vw.zoomed_in.set(true) } },
  )
  // Read the neighbours ahead once the open picture has come (or failed). Revisit both when imageNear changes and
  // when this picture finishes, even if no frame was drawn in between.
  n.reacts(fn() { (vw.near_ids(src), vw.bytes.get() is Some(_), vw.error.get() is Some(_)) }, fn(_) {
    let (before, after) = vw.near(src)
    vw.read_near(src, before, after)
  })
  // where its picture flies from and back into, kept as the chat lays its thumbnail out while it flies: where it was
  // last, what showed of it moved with it, for the frames it is on the screen no more (Viewer::flight_from; its nodes
  // read it where it is in the frame they draw)
  n.reacts(
    fn() {
      // (followed whether it flies or not: its flight said at each cause, the thumbnail's place as it is measured)
      vw.fly.said()
      // (all of it that the flight is drawn by: where it is, what showed of it, where its list leaves it clear, its
      // corners, how its picture sits in it, which; what it draws over its picture goes with it)
      let at = vw
        .flight_from(@ui.current())
        .map(fn(t) -> ThumbDrawn { { box: (t.x, t.y, t.w, t.h), seen: t.seen, clear: t.clear, corners: t.corners.each(), letterbox: t.letterbox, start_crop: t.start_crop, picture: t.picture } })
      if vw.flies {
        at
      } else {
        None
      }
    },
    fn(_) {
      if vw.flies {
        vw.fly_from = vw.flight_from(@ui.current())
      }
    },
  )
  // the stage: the room it is laid out in (the keyboard over it),
  // and the picture's size (as sent, else as decoded, else its stand-in's: followed by its own decodes), told the zoom
  // at the moment either changes
  n.reacts(
    fn() {
      let (w, h) = stage()
      // (a film's or a song's picture sized by its player alone, Viewer::video_natural: nothing of a picture's asked
      // for it here, its thumbnail none)
      ((w, h + n.keyboard_inset()), if vw.played() { (0.0, 0.0) } else { vw.natural_size(src) }, vw.bar_over(w), marks_foot_over())
    },
    fn(told) {
      let ((bw, bh), (nw, nh), bar, foot) = told
      let at = n.cause_at()
      vw.zoom.boxed(bw, bh, at~)
      vw.zoom.under_bars(bar, foot, at~)
      vw.zoom.natural(nw, nh, at~)
    },
  )
  // lifted over the keyboard while marking, as far as keeps what is being written (or the open note's pin, its box
  // under it) 24 clear of it: its way said as the keyboard comes or goes or what is written moves, at that moment
  // (the same lift a finger on the picture is placed by: Viewer::marks_rect)
  n.reacts(
    fn() {
      // (followed: marking, the keyboard, what the zoom is told; worked out where the picture is at the cause's
      // moment, the one the lift sets out at)
      marks_said()
      vw.zoom.told()
      let ime = n.keyboard_inset()
      let below = match marks_writing_bottom_in(vw.zoom, vw.zoom.rect_at(n.cause_at())) {
        Some(b) => b + marks_keyboard_gap - stage().1
        None => 0.0
      }
      if ime > 0.0 && below > 0.0 {
        below
      } else {
        0.0
      }
    },
    fn(to) {
      if to != vw.lift.target() {
        vw.lift.go(to, @motion.move_damped, at=n.cause_at())
      }
    },
  )
  // its ground, as far in as it has come (its flight's share, its fade): sampled as each frame draws it while either
  // goes, at their ends once neither does (the clock read no more)
  n.box(fn(g) {
    g
    .over(Is(true))
    .ground(By(fn() {
      vw.fly.said()
      vw.fade.said()
      // (and a picture taken down: the page under it shows through as far as it is down, Zoom::pulled_at)
      vw.zoom.told()
      let t = g.drawn_while(fn(at) { vw.fly.goes_at(at) || vw.fade.goes_at(at) || vw.zoom.goes_at(at) })
      // (a flying film's under its player's fade too; a song or non-flying film fades ground-first via way_at so words
      // never draw seen over the page's words)
      let under = if vw.played() && vw.flies { vw.fade.value_at(t) } else { 1.0 }
      let pulled = 1.0 - (vw.zoom.pulled_at(t) * pull_ground_rate).clamp(min=0.0, max=pull_ground_most)
      @sf.alpha(vw.ground_ink(), vw.ground_share(vw.in_at(t)) * under * pulled)
    }))
    |> ignore
  })
  |> ignore
  // (the rest clear of the column of the system's bars down the window's trailing edge, an iPhone Duo's on its side
  // (@sf.native_clear), its ground on under it, as the old frame's preview layer laid it out)
  let room = n.box(fn(r) {
    // (a film filling the window beside them: the bars put away, edge to edge: @sf.player_full_native)
    r
    .over(Is(true))
    .row(Is(true))
    .padding(By(fn() {
      if vw.played() && @sf.player_fills_native(player_width(r.window_w())) {
        (0.0, 0.0, 0.0, 0.0)
      } else {
        (0.0, 0.0, @sf.native_clear(), 0.0)
      }
    }))
    |> ignore
  })
  let n = room.box(fn(m) { m.grow(Is(1.0)) |> ignore })
  // what it shows of anything but a picture of its own, its bars and what steps it, its old views hosted here
  // (viewer_hosted)
  if vw.played() {
    viewer_player(n, src, vw)
  } else if !vw.markable() {
    viewer_hosted(n, src, vw, fn() { stage().0 })
  } else {
    // the canvas: what a finger does on it, the picture drawn in it, as far in as its fade has come (as its ground is; a
    // flight's fade is put in whole, its picture the flight's own), sampled as its ground is
    n.box(fn(canvas) {
      canvas
      .over(Is(true))
      .alpha(By(fn() {
        // (its picture the window's tree's flight: whole, its fade what is round it alone, Viewer::tree_way_told)
        if vw.tree_way.get() {
          return 1.0
        }
        vw.fade.said()
        vw.fade.value_at(canvas.drawn_while(fn(at) { vw.fade.goes_at(at) }))
      }))
      // (closed: what is on it the viewer's going alone, a finger on it called off then)
      .presses(By(fn() {
        match pv_leaving.get() {
          Some(l) => !physical_equal(l, vw)
          None => true
        }
      }))
      .on_drag(fn(d) { vw.finger_on(canvas, src, d) }, fingers=2)
      // (the pointer's secondary button on the picture: its menu, as a finger held still on it opens it)
      .on_menu(fn(m) { vw.menu_on(m) })
      // (a wheel over it, at its moment, where it is on the stage then: a trackpad's two fingers taking it down or
      // paging sideways, else what the wheel does to the picture)
      .on_wheel(fn(w) {
        if !vw.wheel_pull(canvas, w) && !vw.wheel_page(canvas, src, w) {
          vw.wheeled(vw.zoom, w.x, w.y, w.dx, w.dy, w.mods, w.at)
        }
      })
      |> ignore
      // (the moment what draws the picture reads the strip and the flight at, in `n`: viewer_flight_at)
      let strip_at = fn(n : @view.View) { viewer_flight_at(vw, n) }
      // (the picture lying flat where its zoom has it, moved across with the strip, its node (but while it flies from an
      // old view's thumbnail: its flight's nodes, thumb_of), under what is drawn over it; let go of at once as it is
      // closed back into a thumbnail the window's tree draws, flown back there by the tree as the rest fades:
      // Viewer::tree_back)
      canvas.show(at_once=true, fn() { !vw.tree_back.get() }, fn(p) {
        // (how it flies from its thumbnail and back: the app's route, out from under the chat's bar and composer first,
        // under them, then grown over all: viewer_route)
        let (route, grown_of) = viewer_route(fn() { p.window() })
        let flat = fn() {
          strip_at(p) |> ignore
          vw.bytes.get() |> ignore
          vw.picture_flat()
        }
        p
        .over(Is(true))
        .offset(By(fn() {
          match vw.marks_rect_on(p) {
            Some((x, y, _, _)) => (x + pv_strip.way.value_at(strip_at(p)), y)
            None => (0.0, 0.0)
          }
        }))
        .width(By(fn() { vw.marks_rect_on(p).map(fn(r) { r.2 }) }))
        .height(By(fn() { vw.marks_rect_on(p).map(fn(r) { r.3 }) }))
        // (its picture as it is drawn: Viewer::picture_shown)
        .image(By(fn() {
          match (flat(), vw.marks_rect_on(p)) {
            (true, Some(_)) => vw.picture_shown(src)
            _ => None
          }
        }))
        // (the end of its flight that moves, by the id of the thumbnail it shows (Viewer::thumb_id, the one it is on as
        // it steps): flown from that thumbnail where the chat shows it as a node that stays, back to it as it closes,
        // out from under the chat's bar or composer first where they cover it, that thumbnail drawn nowhere meanwhile
        // (View::shared's `stays`); none such, it comes and goes as it would; made again for another tier of the
        // window, there at once (`with_stays`))
        .shared(By(fn() { vw.thumb_id() }), @motion.flight_by(@motion.moved()), with_stays=true, route~, told=fn(
          start,
          end,
          along,
        ) {
          vw.tree_way_told(start, end, grown_of(vw.tree_back.untracked(), along))
        })
        |> ignore
      })
      // (the picture flying in or back, its nodes: from the thumbnail as the chat lays it out in the frame drawn
      // (Viewer::flight_from) to where its zoom has it, as far as its flight has come then (flight_box): what shows of it
      // on the window, the box it is cut to, its corners round, the picture in it, as Viewer::picture_shown has it, its
      // whole picture judged ready for where it lands (View::image_for: as what draws the picture judged it,
      // Viewer::shown_picture), which of them decided as it is drawn)
      image_flight(canvas, src, vw, stage, fn(t) { vw.flies_from_page() == 0 || vw.lifted_at(t) >= 1.0 })
      // (the one going while the strip's way goes, drawn from where it was, the stage's width and the gap further out to
      // the side it goes to: it has no place of its own any more (Strip's leaving, its picture as it showed then); none
      // where this one could not be decoded, its words alone)
      canvas.box(fn(l) {
        let going = fn() {
          let t = strip_at(l)
          match pv_strip.leaving {
            Some(g) if pv_strip.way.goes_at(t) && !vw.picture_failed() => Some((g, pv_strip.way.value_at(t)))
            _ => None
          }
        }
        l
        .over(Is(true))
        .offset(By(fn() {
          match going() {
            Some((g, sx)) => (g.x + sx - g.dir.to_double() * g.width, g.y)
            None => (0.0, 0.0)
          }
        }))
        .width(By(fn() { going().map(fn(g) { g.0.w }) }))
        .height(By(fn() { going().map(fn(g) { g.0.h }) }))
        .image(By(fn() { going().map(fn(g) { (g.0.picture, "", stage_max_px()) }) }))
        |> ignore
      })
      |> ignore
      // (those beside it, out of sight until the strip brings them in (none while one is going, none where this one could
      // not be decoded): each fitted to the stage, the stage's width and the gap to its side, its picture as the one
      // shown's is)
      for side in [-1.0, 1.0] {
        canvas.box(fn(s) {
          let beside = fn() {
            let t = strip_at(s)
            let sx = pv_strip.way.value_at(t)
            let going = pv_strip.leaving is Some(_) && pv_strip.way.goes_at(t)
            if sx == 0.0 || going || vw.picture_failed() {
              return None
            }
            let (before, after) = vw.near(src)
            match (if side < 0.0 { before } else { after }) {
              Some(n) => {
                let (w0, h0) = n.natural_size(src)
                let (bw, bh) = stage()
                match (fitted_rect(w0, h0, bw, bh, bar=vw.bar_over(bw)), n.picture_shown(src)) {
                  (Some((x, y, w, h)), Some(shown)) => Some((x + sx + side * (bw + slide_gap), y, w, h, shown))
                  _ => None
                }
              }
              None => None
            }
          }
          s
          .over(Is(true))
          .offset(By(fn() {
            match beside() {
              Some((x, y, _, _, _)) => (x, y)
              None => (0.0, 0.0)
            }
          }))
          .width(By(fn() { beside().map(fn(b) { b.2 }) }))
          .height(By(fn() { beside().map(fn(b) { b.3 }) }))
          .image(By(fn() { beside().map(fn(b) { b.4 }) }))
          |> ignore
        })
        |> ignore
      }
      // (its size neither sent with it nor known yet: a small decode of what it shows asked for, out of sight, that says
      // it; none drawn of it, Viewer::size_unknown)
      canvas.box(fn(s) {
        s
        .over(Is(true))
        .width(Is(Some(1.0)))
        .height(Is(Some(1.0)))
        .alpha(Is(0.0))
        .image(By(fn() {
          vw.bytes.get() |> ignore
          if !vw.picture_failed() && vw.size_unknown(src) {
            Some((vw.picture(src), "", stage_max_px()))
          } else {
            None
          }
        }))
        |> ignore
      })
      |> ignore
      // (its whole picture read and said not to decode: why, alone in the middle of the stage, 24 in from its sides, as
      // stage_note_node has it; in the theme's muted ink, as the viewer's other words: a picture lies on the page's own
      // canvas, Viewer::dark)
      canvas.show(fn() { vw.picture_failed() }, fn(f) {
        f.over(Is(true)).padding(Is((24.0, 24.0, 24.0, 24.0))).lines_up(Is(Some(Middle))) |> ignore
        f.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
        f.box(fn(w) {
          w
          .words(By(fn() { pv("android-chat.file.image.failed") }))
          .words_look(By(fn() {
            // (a size alone said, its line the theme's text_line times it, as Ctx::text has it)
            let size = @sf.theme().t.body
            { size, weight: 400, line: @ui.tree_theme().text_line * size, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
          }))
          .ink(By(fn() { @sf.theme().p.muted }))
          |> ignore
        })
        |> ignore
        f.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
      })
      // (over the picture while it marks, once where it is is known: the marks drawn and the numbered marks' pins, its
      // nodes; over them the words being written, a field of the tree's)
      canvas.show(fn() { vw.marks_shown() }, fn(h) {
        // (the marks drawn, over them their pins)
        h.over(Is(true)) |> ignore
        h.box(fn(s) { marks_shapes_node(s, vw) }) |> ignore
        h.box(fn(p) { marks_pins_node(p, vw) }) |> ignore
      })
      // (over them the words being written, where they begin on the picture, a field of the tree's: marks_writing_node)
      canvas.show(
        fn() {
          marks_said()
          vw.marks_shown() && marking.writing is Some(_)
        },
        fn(h) { marks_writing_node(h, vw) },
      )
    })
    |> ignore
  }
  // beside the system's bars (an iPhone Duo's): what is up over the window said to them, its name, its tabs put away
  // (and, not marking, its actions in their bars in place of its own bar: vf_native's), at the moment what it says
  // changes; kept as said while it is the one open (Viewer::up_still), handed over as each frame ends
  // (@sf.native_over_up)
  n.reacts(fn() { native_said(vw, src, player_width(n.window_w())) }, fn(said) {
    match said {
      // (a film's or a song's: its name and its actions there, close, 全屏 and download (vf_native_media), as wide as
      // its player is laid out; filling the window, none: the bars put away, its name none either)
      Some({ full, width, .. }) if vw.played() =>
        if @sf.native_over_up(if full { "" } else { vw.file.name }, alive=fn() { vw.up_still() }, owner="viewer", over=2) &&
          !full {
          vf_native_media(vw, @ui.current(), src, width)
        }
      Some(_) =>
        // (a picture's actions and a page's there; anything else its own bar still, its name and tabs theirs)
        if @sf.native_over_up(vf_title(vw), alive=fn() { vw.up_still() }, owner="viewer", over=2) &&
          !marking.on &&
          (vw.shown_kind() == Some(KImage) || vw.shown_kind() == Some(KHtml)) {
          vf_native(vw, @ui.current(), src)
        }
      None => ()
    }
  })
  // (the floating bar over it on a small screen, its nodes: where the old bars draw it not, head_as_nodes)
  n.show(fn() { head_as_nodes(vw, stage().0) }, fn(h) { image_head(h, src, vw, stage) })
  // (the bar across the top of a wider window, its picture whole, its nodes: where the old bars draw it not,
  // bar_as_nodes)
  n.show(fn() { bar_as_nodes(vw, stage().0) }, fn(h) { image_bar(h, src, vw, stage) })
  // (marking's foot while it marks, one column: its tools, the notes' cards, the note being written)
  n.show(
    fn() {
      marks_said()
      marking.on
    },
    fn(h) { marks_foot_node(h, fn() { (@sf.viewer_host().room)().1 }) },
  )
  // (the ways to the pictures beside it, its nodes, while it is not marked: a picture's, one too big to show too)
  n.show(
    fn() {
      marks_said()
      !marking.on && vw.shown_kind() == Some(KImage)
    },
    fn(h) { image_steps(h, src, vw, stage) },
  )
  // (a mouse's pointer along the top where the bar across it is: the bar shown while it is there, whatever is over it
  // then, the bar itself as it shows; as the pointer comes in or goes out)
  n.box(fn(top) {
    top.over(Is(true)).height(Is(Some(@sf.viewer_bar_h))) |> ignore
    top.reacts(fn() { top.pointer_within() && @sf.pointer_rests() }, fn(near) {
      if vw.near_bar != near {
        vw.near_bar = near
        vw.awake_said()
      }
    })
  })
  |> ignore
}

///|
/// How much of the ground its flight has brought at `t` (Viewer::flying's, at a moment of its own: its way alone, at
/// the stage (1) where it flies no more).
fn Viewer::flight_share_at(self : Viewer, t : Double) -> Double {
  let e = self.fly.value_at(t)
  if e >= 1.0 {
    1.0
  } else if e <= self.fly_lift {
    0.0
  } else {
    (e - self.fly_lift) / (1.0 - self.fly_lift)
  }
}

///|
/// The canvas's colour under what it shows (its ground's).
fn Viewer::ground_ink(self : Viewer) -> Int64 {
  if self.dark() {
    0x000000FFL
  } else if viewer_mbui_rendered(self) {
    @sf.theme().p.bg
  } else if self.shown_kind() == Some(KPdf) {
    let t = @sf.theme()
    @sf.mix(t.p.text, 0.05, t.p.bg)
  } else {
    @sf.theme().p.canvas
  }
}

///|
/// What is done at the ends of `vw`'s ways, on node `n`'s timeline: landed from its thumbnail, the thumbnail shown
/// again (one picture on the screen, never two); gone (back into its thumbnail, or faded out), let go of. A video
/// closing into its thumbnail waits first for the frame it shows to be grabbed (leaving_grab: its player's picture
/// where it was meanwhile), its way back said once that is answered: its end the one it goes then.
fn image_ends(n : @view.View, vw : Viewer, src : Source) -> Unit {
  if vw.flies && !vw.fly_back {
    n.at_moment(vw.fly.end(), fn() {
      if vw.flies && !vw.fly_back {
        vw.flies_set(false)
        pv_hidden.set("")
      }
    })
    |> ignore
  }
  // (closed: done at the end of the way it is said to go then)
  let ends : Ref[() -> Unit] = Ref(fn() {  })
  n.reacts(
    fn() {
      // (its way as it is said: the grab answered, a flight back set out; followed so)
      vw.grab_told.get() |> ignore
      vw.fly.said()
      vw.fade.said()
      match pv_leaving.get() {
        // (back by the tree's shared flight once that is told: its own end to the moment, not the fade's rounded up)
        Some(l) if physical_equal(l, vw) && !vw.leaving_grab =>
          Some(
            if vw.flies {
              vw.fly.end()
            } else if vw.tree_back.untracked() && vw.tree_way_end > 0.0 {
              vw.tree_way_end
            } else {
              vw.fade.end()
            },
          )
        _ => None
      }
    },
    fn(going) {
      (ends.val)()
      ends.val = fn() {  }
      if going is Some(end) {
        ends.val = n.at_moment(end, fn() {
          match pv_leaving.get() {
            Some(l) if physical_equal(l, vw) => {
              pv_hidden.set("")
              leaving_done()
            }
            _ => ()
          }
        })
      }
    },
  )
  // (a video closing into its thumbnail: the frame it shows taken as the host answers the grab, at that moment, once;
  // none to be had, back with its still: Viewer::left_with_frame. Followed by the host's answers as they are told, not
  // asked each frame)
  n.reacts(
    fn() {
      vw.grab_told.get() |> ignore
      if vw.leaving_grab {
        Some(vw.view().map(fn(v) { v.grabs_told() }))
      } else {
        None
      }
    },
    fn(waiting) {
      if waiting is Some(_) && vw.leaving_grab && vw.leaving_pic == "" {
        vw.left_with_frame(src, n.cause_at(), n.window())
      }
    },
  )
  // (that frame's picture decoded, or failed, at that moment, once: its player hidden as its flight is drawn, setting
  // out then (Viewer::left_with_picture); never before, however late)
  n.reacts(
    fn() {
      vw.grab_told.get() |> ignore
      if vw.leaving_pic != "" {
        @ui.image_state(vw.leaving_pic)
      } else {
        0
      }
    },
    fn(state) {
      if state != 0 && vw.leaving_pic != "" {
        vw.left_with_picture(src, state > 0, n.cause_at(), n.window())
      }
    },
  )
}

///|
/// What viewer `vw` says to the system's bars beside the window (an iPhone Duo's; None where there are none, or it is
/// going): what of it decides what it says there (marking, its bar shown or its picture coming, its zoom
/// fitted or not, its whole picture here, its download, the words its actions are said in; a film's, filling the
/// window `width` wide or not, turned sideways or not), as each is told.
fn native_said(vw : Viewer, src : Source, width : Double) -> NativeSaid? {
  marks_said()
  vw.zoom.told()
  pv_leaving.get() |> ignore
  if !@sf.native_on() || vw.closing {
    return None
  }
  let z = vw.zoom
  Some({
    marking: marking.on,
    shown: vw.bars_shown(),
    coming: vw.coming(),
    fitted: z.fitted,
    whole: z.fit() >= 1.0,
    here: vw.bytes.get() is Some(_),
    told: vw.told_of() && !vw.asked_now(),
    downloading: downloading(vw.download(src)),
    source: {
      vw.source_told.get() |> ignore
      vw.source
    },
    full: vw.played() && @sf.player_fills_native(width),
    width,
    sideways: match vw.media {
      Some(m) => m.is_sideways()
      None => false
    },
    // (the words its actions are said in there, in the language as it is: said again as that changes)
    words: [
      "common.close", "web-main.preview.fitKey", "web-main.preview.actualKey", "web-main.annotate.image", "common.copy",
      "web-main.stations.saveToPhotos", "android-chat.file.download", "web-main.preview.rendered", "web-main.preview.source",
      "android-misc.drive.share",
      "android-misc.drive.player.full", "android-misc.drive.player.unfull",
    ].map(fn(k) { @sf.t(k) }),
  })
}

///|
/// What decides what viewer `vw` says to the system's bars (native_said).
#derive(Eq)
struct NativeSaid {
  marking : Bool
  shown : Bool
  coming : Bool
  fitted : Bool
  whole : Bool
  here : Bool
  told : Bool
  downloading : Bool
  /// a page's 源码 shown (Viewer::set_source): its action there says the other
  source : Bool
  /// a film filling the window beside them (@sf.player_fills_native): its name and actions none there
  full : Bool
  /// how wide its player is laid out (player_width): its 全屏 there turns it sideways where that is laid out Small,
  /// else fills the window (@sf.player_full_act)
  width : Double
  /// a film turned sideways (its 全屏 there says so)
  sideways : Bool
  words : Array[String]
}

///|
/// A finger's event on the canvas of viewer `v` (node `canvas`), at its own moment: what the old view's stage worked
/// out from the frames, from the events themselves. One finger moves the picture where it is larger
/// than the stage, else the strip to the one beside it (let go: on to it, or back); two pinch round the point between
/// them; let go moving, it flings on; a tap shows or hides the bars, two zoom in or back; held still, its menu;
/// marking, one finger draws. Everything it decides is decided as things are at the event's moment (the picture's
/// place, zoomed or not, its edges, the strip: by their ways, read there), whatever frames were drawn meanwhile; where
/// on the stage, in the canvas's own terms; how far a finger went, in the window's.
fn Viewer::finger_on(self : Viewer, canvas : @view.View, src : Source, d : @view.Drag) -> Unit {
  let v = self
  let c = @ui.current()
  let z = v.zoom
  let at = d.at
  let (x, y) = (d.wx, d.wy)
  // (the canvas's own terms for a point of the window's, as it is drawn at this moment)
  let (ox, oy) = (d.x - d.wx, d.y - d.wy)
  let strip = pv_strip.way
  let (before, after) = v.near(src)
  let (has_before, has_after) = (before is Some(_), after is Some(_))
  match d.kind {
    Down => {
      v.fingers[d.finger] = (x, y)
      if v.fingers.length() == 1 {
        // (a tap's close waited for called off: this press is a second tap, or a drag)
        (v.tap_off)()
        v.tap_off = fn() {  }
        v.held = true
        v.down_x = x
        v.down_y = y
        v.down_lx = d.x
        v.down_ly = d.y
        v.last_x = x
        v.last_y = y
        v.speed.reset()
        v.speed.add(at, x, y)
        if !v.pinched {
          v.moved = 0.0
          // flinging, or sliding to the one beside it: it stops where it is, and the press taps nothing
          v.caught = z.stop_fling(at~)
          let s = strip.value_at(at)
          if strip.goes_at(at) {
            strip.put(s)
            v.caught = true
          }
          v.strip_down = s
        }
        let (rx, _, rw, _) = z.rect_at(at).unwrap_or((0.0, 0.0, 0.0, 0.0))
        v.at_left = rx >= -0.5
        v.at_right = rx + rw <= z.bw + 0.5
        if marking.on {
          match v.marks_rect(at) {
            Some(r) => marks_finger(0, d.x, d.y, r, z.nw)
            None => ()
          }
        } else if !@sf.pointer_rests() {
          // a finger held still: the picture's menu, once its whole is here, where the finger is on it (as it is then;
          // a mouse's button held asks for none: its menu is the secondary button's, Viewer::menu_on)
          let due = at + @ui.long_press_ms
          v.hold_off = canvas.at_moment(due, fn() {
            match (z.rect_at(due), v.bytes.get()) {
              (Some((rx, ry, rw, rh)), Some(_)) if v.held && v.moved <= tap_slop && !v.pinched &&
                v.fingers.length() == 1 &&
                v.down_lx >= rx &&
                v.down_lx < rx + rw &&
                v.down_ly >= ry &&
                v.down_ly < ry + rh => {
                v.caught = true
                @ui.haptic(LongPress)
                v.picture_menu_at(v.down_x, v.down_y)
              }
              _ => ()
            }
          })
        }
      } else {
        // a second finger: a pinch round the point between them; a swipe going goes back, not left between two; a mark
        // being drawn or moved, called off
        (v.hold_off)()
        marks_finger_off()
        let (cx, cy, dist) = v.pinch_now()
        v.pinch_d = dist
        v.pinch_x = cx
        v.pinch_y = cy
        v.pinched = true
        if v.swiping {
          v.swiping = false
          strip.go(0.0, @motion.carousel_spring, at~)
        }
        // (a pull going on: the pinch takes the picture from where it has it, back to fitted if let go smaller)
        v.pulling = false
        v.held = false
      }
    }
    Moved => {
      v.fingers[d.finger] = (x, y)
      if v.fingers.length() >= 2 && z.nw > 0.0 {
        // round the point between them on the stage, moved as far as it went
        let (cx, cy, dist) = v.pinch_now()
        if v.pinch_d > 0.0 && dist > 0.0 {
          z.transform(cx + ox, cy + oy, dist / v.pinch_d, cx - v.pinch_x, cy - v.pinch_y, at~)
        }
        v.pinch_d = dist
        v.pinch_x = cx
        v.pinch_y = cy
      } else {
        v.one_finger_at(d, has_before, has_after)
      }
    }
    Up | Off => {
      v.fingers.remove(d.finger)
      if !v.fingers.is_empty() {
        // one of two let go: the pinch over, the one left followed from where it is next
        v.pinch_d = 0.0
        v.held = false
        return
      }
      (v.hold_off)()
      v.hold_off = fn() {  }
      let pinched = v.pinched
      if d.kind == Off {
        // called off: nothing it would have come to (a mark being drawn dropped, one moved back)
        v.pinched = false
        marks_finger_off()
        if v.pulling {
          v.pulling = false
          v.zoom.reset(at~)
        }
        if v.swiping {
          strip.go(0.0, @motion.carousel_spring, at~)
        }
        v.swiping = false
        v.held = false
        return
      }
      // where it was let go, and when, the last of its way: as a move of its own first (however far from the last
      // move, or with none: a down and an up alone; how fast it went as of then, none where it paused longer than
      // tracker_gap_ms first: Velocity::get_at); the last of a pinch let go, nothing of its own
      if v.held {
        v.one_finger_at(d, has_before, has_after)
      }
      v.pinched = false
      if marking.on && !pinched {
        match v.marks_rect(at) {
          Some(r) => marks_finger(2, d.x, d.y, r, z.nw)
          None => ()
        }
        v.held = false
        return
      }
      v.image_let_go(c, canvas, src, d, pinched)
    }
  }
}

///|
/// One finger alone on the canvas at `d` (moved, or let go there): marking, the mark it draws or moves; else the way
/// from where it was last, how fast as of then, and what that does (the zoomed picture with it, the strip sideways, the
/// fitted one panned); after a pinch, followed from here.
fn Viewer::one_finger_at(self : Viewer, d : @view.Drag, has_before : Bool, has_after : Bool) -> Unit {
  let v = self
  let z = v.zoom
  let strip = pv_strip.way
  let at = d.at
  let (x, y) = (d.wx, d.wy)
  if marking.on && !v.pinched {
    match v.marks_rect(at) {
      Some(r) => marks_finger(1, d.x, d.y, r, z.nw)
      None => ()
    }
  } else if !v.held {
    // one finger again after a pinch: followed from where it is now
    v.held = true
    v.last_x = x
    v.last_y = y
    v.speed.reset()
    v.speed.add(at, x, y)
  } else {
    let dx = x - v.last_x
    let dy = y - v.last_y
    v.moved = v.moved + dx.abs() + dy.abs()
    // (let go: a sample only where it moved there, Velocity::up)
    if d.kind is Up {
      v.speed.up(at, x, y)
    } else {
      v.speed.add(at, x, y)
    }
    if v.moved > tap_slop {
      (v.hold_off)()
    }
    if z.zoomed_at(at) {
      // zoomed in: it goes with the finger (at once after a pinch)
      if (v.moved > tap_slop || v.pinched) && (dx != 0.0 || dy != 0.0) {
        v.drag_zoomed(z, strip, dx, dy, has_before, has_after, at)
      }
    } else {
      // fitted, one finger sideways moves the strip, under the finger from where it went down; past the first or
      // the last a third as far
      let mut dx = dx
      // (or, going down more than across, it takes the picture down with it, to close it: Viewer::image_let_go)
      if !v.swiping &&
        !v.pulling &&
        v.moved > tap_slop &&
        y - v.down_y > (x - v.down_x).abs() &&
        !v.pinched {
        v.pulling = true
      }
      if v.pulling {
        v.zoom.pull(x - v.down_x, y - v.down_y, at~)
      } else if !v.swiping &&
        v.moved > tap_slop &&
        (x - v.down_x).abs() > (y - v.down_y).abs() &&
        (has_before || has_after) &&
        !v.pinched {
        v.swiping = true
        pv_strip.leaving = None
        dx = x - v.down_x
      }
      if v.swiping {
        let s = strip.value_at(at)
        let next = s + dx
        let none = if next > 0.0 { !has_before } else { !has_after }
        strip.put(if none { s + dx / 3.0 } else { next })
      } else if !v.pulling && v.moved > tap_slop && (dx != 0.0 || dy != 0.0) {
        z.pan(dx, dy, at~)
      }
    }
    v.last_x = x
    v.last_y = y
  }
}

///|
/// The pointer's secondary button pressed on the canvas (`m`, at its moment): the picture's menu where it is on the
/// picture as it is then, once its whole is here; off it, or marking, none.
fn Viewer::menu_on(self : Viewer, m : @view.Menu) -> Unit {
  if marking.on {
    return
  }
  match (self.zoom.rect_at(m.at), self.bytes.get()) {
    (Some((rx, ry, rw, rh)), Some(_)) if m.x >= rx && m.x < rx + rw && m.y >= ry && m.y < ry + rh =>
      self.picture_menu_at(m.wx, m.wy)
    _ => ()
  }
}

///|
/// Where the picture is at `at` as marking draws it: lifted over the keyboard as far as its lift has come then.
pub fn Viewer::marks_rect(self : Viewer, at : Double) -> (Double, Double, Double, Double)? {
  let lift = self.lift.value_at(at)
  self.zoom.rect_at(at).map(fn(r) { (r.0, r.1 - lift, r.2, r.3) })
}

///|
/// What viewer `vw`'s picture is drawn as by a node (View::image): its whole picture once read, what stands in for it
/// till that is decoded for the size it is drawn at, as Viewer::shown_picture has them (which of them decided as it is
/// drawn, at its pixels then); None: nothing of it yet.
fn Viewer::picture_shown(self : Viewer, src : Source) -> (String, String, Int)? {
  let cap = self.decode_max_px()
  match self.picture(src) {
    "" => None
    picture if picture != self.image => Some((picture, "", cap))
    picture => Some((picture, self.stand_in(src), cap))
  }
}

///|
/// Whether viewer `vw`'s picture lies flat where its zoom has it, moved across with the strip of pictures (its node
/// draws it then, View::image): drawn by the window's tree, not flying (its flight's nodes draw it then), not a picture
/// that could not be decoded (its words alone: Viewer::picture_failed).
pub fn Viewer::picture_flat(self : Viewer) -> Bool {
  self.in_tree && !self.flies && !self.picture_failed()
}

///|
/// Whether viewer `vw`'s marks are drawn over its picture (marks_shapes_node, marks_pins_node, the words being written):
/// marking, where the picture is known, not one that could not be decoded (its words saying so alone). As each is told.
fn Viewer::marks_shown(self : Viewer) -> Bool {
  marks_said()
  self.zoom.told()
  marking.on && !self.picture_failed() && self.zoom.sized()
}

///|
/// How far a finger goes before what it does is a drag, not a tap (the old stage's).
let tap_slop : Double = 8.0

///|
/// The point between the first two fingers on it and how far apart they are.
fn Viewer::pinch_now(self : Viewer) -> (Double, Double, Double) {
  let ps = self.fingers.values().collect()
  if ps.length() < 2 {
    return (0.0, 0.0, 0.0)
  }
  let ((x1, y1), (x2, y2)) = (ps[0], ps[1])
  ((x1 + x2) / 2.0, (y1 + y2) / 2.0, ((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)).sqrt())
}

///|
/// The last finger let go (`d`, at its moment): a swipe on to the one beside it or back, a fling, a tap or two.
fn Viewer::image_let_go(
  self : Viewer,
  c : @ui.Ctx,
  canvas : @view.View,
  src : Source,
  d : @view.Drag,
  pinched : Bool,
) -> Unit {
  let v = self
  let z = v.zoom
  let strip = pv_strip.way
  let at = d.at
  let zoomed = z.zoomed_at(at)
  let (vx, vy) = v.speed.get_at(at)
  let s = strip.value_at(at)
  if v.pulling {
    v.pull_let_go(c, d, vy)
    return
  }
  if v.held && (v.swiping || s != 0.0) && (!zoomed || s != 0.0) {
    // on to the one beside it (this press's way far enough, or flung that way), else back
    let width = z.bw + slide_gap
    let base = if v.strip_down > width / 2.0 { -1 } else if v.strip_down < -width / 2.0 { 1 } else { 0 }
    let dx = s - v.strip_down
    let from_edge = !zoomed || (if dx > 0.0 { v.at_left } else { v.at_right })
    let step = strip_step(dx, vx, z.bw, from_edge)
    let to = base + step
    if to < 0 {
      v.go(c, src, -1, vx * 1000.0)
    } else if to > 0 {
      v.go(c, src, 1, vx * 1000.0)
    } else {
      strip.go(0.0, @motion.carousel_spring, at~, velocity=vx * 1000.0)
    }
  } else if v.held && zoomed && (v.moved > tap_slop || pinched) {
    // zoomed in, let go moving: on at the finger's speed, slowing, to a stop or its edge
    z.fling(vx, vy, at~)
  }
  v.swiping = false
  let held = v.held
  v.held = false
  // pinched smaller than fitted and let go: back to fitted (as small as it is at the let go)
  if pinched && z.scale_at(at) < z.fit() {
    z.reset(at~)
  }
  // a tap (and a second of two, View::twice: zoomed in, or back)
  if held && v.moved <= tap_slop && !pinched && !v.caught {
    let on_picture = match z.rect_at(at) {
      Some((rx, ry, rw, rh)) => d.x >= rx && d.x < rx + rw && d.y >= ry && d.y < ry + rh
      None => false
    }
    if (@sf.pointer_rests() || (!zoomed && @sf.native_able())) && !on_picture && !marking.on {
      canvas.twice_forgot()
      v.shut(c)
    } else if canvas.twice(d) {
      z.double_tap(d.x, d.y, at~)
    } else if !marking.on {
      // a tap closes it, once a second would have come (two zoom it: Viewer::finger_on's next press calls this off)
      let due = at + canvas.twice_ms()
      v.tap_off = canvas.at_moment(due, fn() {
        v.tap_off = fn() {  }
        v.shut_tree()
      })
    }
  }
}

///|
/// How far down a finger or a trackpad's two take a picture before it closes as they let it go (points), and how
/// fast a finger flung down closes it from less (points a ms).
let pull_shut : Double = 100.0

///|
let pull_fling : Double = 0.5

///|
/// A picture taken down (Viewer::pulling) let go (`d`, at its moment, as fast as `vy` down): closed from where it is,
/// back into its thumbnail or fading, where it went far enough down or was flung down; else back to fitted.
fn Viewer::pull_let_go(self : Viewer, c : @ui.Ctx, d : @view.Drag, vy : Double) -> Unit {
  self.pulling = false
  self.held = false
  self.swiping = false
  let down = d.wy - self.down_y
  if down >= pull_shut || (vy >= pull_fling && down > tap_slop) {
    self.shut(c)
  } else {
    self.zoom.reset(at=d.at)
  }
}

///|
/// Arm (or re-arm) the stillness timer shared by trackpad pull-to-close and trackpad horizontal paging.
fn Viewer::wheel_arm(self : Viewer, canvas : @view.View, due : Double, on_rest : () -> Unit) -> Unit {
  (self.wheel_off)()
  self.wheel_off = canvas.at_moment(due, fn() {
    self.wheel_off = fn() {  }
    on_rest()
  })
}

///|
/// Phase-0 (web) rebound thresholds for recognizing a new horizontal swipe while the previous swipe's momentum is
/// still decaying in `Spent`: browser momentum decays monotonically with at most ±1–2 pt quantization jitter at low
/// speeds, so requiring |dx| >= 6 pt, >= 1.8x the decay floor, and an absolute jump >= 4 pt rejects jitter while
/// catching a fresh two-finger swipe immediately.
let wheel_page_rebound_min : Double = 6.0

///|
let wheel_page_rebound_ratio : Double = 1.8

///|
let wheel_page_rebound_jump : Double = 4.0

///|
/// Whether a wheel arriving while `pv_strip.wheel` is `Spent` starts a new gesture (native momentum -> finger
/// transition, direction reversal, or phase-0 |dx| rebound after decay).
fn strip_wheel_starts_new(sw : StripWheel, dx : Double, is_mom : Bool) -> Bool {
  if sw.last_momentum && !is_mom {
    return true
  }
  let abs_dx = dx.abs()
  if dx != 0.0 && (dx > 0.0) != (sw.spent_dir > 0.0) && abs_dx >= wheel_page_rebound_min {
    return true
  }
  !is_mom &&
  sw.spent_min_dx > 0.0 &&
  abs_dx >= wheel_page_rebound_min &&
  abs_dx >= sw.spent_min_dx * wheel_page_rebound_ratio &&
  abs_dx - sw.spent_min_dx >= wheel_page_rebound_jump
}

///|
/// A wheel over the canvas of viewer `vw` (node `canvas`) as a pull (a trackpad's two fingers going down a fitted
/// picture, as a finger takes it down, the picture going with them): closed once they have it pull_shut down, back to
/// fitted where they stop short (wheel_rest_ms with none come). Whether it was one: a mouse's wheel, one with a key held,
/// one going up or across, or over a picture zoomed in is none (the wheel's, Viewer::wheeled).
fn Viewer::wheel_pull(self : Viewer, canvas : @view.View, w : @view.Wheel) -> Bool {
  let z = self.zoom
  if self.closing {
    // (closed by it: what of its way is left goes nowhere, not to the page under it)
    return self.wheel_pulling
  }
  if !@sf.pointer_rests() ||
    marking.on ||
    z.nw <= 0.0 ||
    (w.mods & @view.wheel_momentum.lnot()) != 0 ||
    self.held {
    return false
  }
  // (as the fingers go: a wheel's dy is the way the page goes under them, the other way)
  let (dx, dy) = (-w.dx, -w.dy)
  let sw = pv_strip.wheel
  if !self.wheel_pulling {
    // Mutual exclusion with an in-flight horizontal paging gesture or its spent momentum tail.
    if sw.state != Idle {
      let is_mom = (w.mods & @view.wheel_momentum) != 0
      let rested = sw.last_at >= 0.0 && w.at - sw.last_at >= wheel_rest_ms
      if !rested && (sw.state == Paging || !strip_wheel_starts_new(sw, dx, is_mom)) {
        return false
      }
      sw.reset()
    }
    if z.zoomed_at(w.at) || dy <= dx.abs() || notched(w.dx, w.dy) {
      return false
    }
    self.wheel_pulling = true
    self.pull_x = 0.0
    self.pull_y = 0.0
  }
  self.pull_x = self.pull_x + dx
  self.pull_y = self.pull_y + dy
  (self.wheel_off)()
  self.wheel_off = fn() {  }
  if self.pull_y >= pull_shut {
    self.shut_tree()
    return true
  }
  z.pull(self.pull_x, self.pull_y, at=w.at)
  let due = w.at + wheel_rest_ms
  self.wheel_arm(canvas, due, fn() {
    self.wheel_pulling = false
    if !self.closing {
      z.reset(at=due)
    }
  })
  true
}

///|
/// A trackpad's two fingers sweeping horizontally over a fitted picture: follows `pv_strip.way` (1/3 resistance past
/// the first/last image or on a single image), flips immediately upon crossing `strip_step`'s threshold without waiting
/// for momentum to end, eats the remaining momentum tail, and snaps back to 0 after `wheel_rest_ms` if released short.
fn Viewer::wheel_page(self : Viewer, canvas : @view.View, src : Source, w : @view.Wheel) -> Bool {
  let z = self.zoom
  let sw = pv_strip.wheel
  if self.closing {
    return sw.state != Idle
  }
  if !@sf.pointer_rests() ||
    marking.on ||
    z.nw <= 0.0 ||
    (w.mods & @view.wheel_momentum.lnot()) != 0 ||
    self.held ||
    z.zoomed_at(w.at) {
    return false
  }
  let (dx, dy) = (-w.dx, -w.dy)
  let is_mom = (w.mods & @view.wheel_momentum) != 0
  if sw.state != Idle && sw.last_at >= 0.0 && w.at - sw.last_at >= wheel_rest_ms {
    sw.reset()
  }
  if sw.state == Spent {
    if strip_wheel_starts_new(sw, dx, is_mom) {
      sw.reset()
      if dx.abs() <= dy.abs() {
        return false
      }
    } else {
      sw.last_at = w.at
      sw.last_momentum = is_mom
      let abs_dx = dx.abs()
      if abs_dx > 0.0 {
        sw.spent_min_dx = if sw.spent_min_dx <= 0.0 { abs_dx } else { dmin(sw.spent_min_dx, abs_dx) }
      }
      return true
    }
  }
  if sw.state == Idle {
    if dx.abs() <= dy.abs() || notched(w.dx, w.dy) || notched(w.dy, w.dx) || is_mom {
      return false
    }
    sw.state = Paging
    sw.strip_down = pv_strip.way.value_at(w.at)
    sw.speed.reset()
    sw.speed.add(w.at, 0.0, 0.0)
    pv_strip.leaving = None
  }
  sw.last_at = w.at
  sw.last_momentum = is_mom
  let (before, after) = self.near(src)
  let has_before = before is Some(_)
  let has_after = after is Some(_)
  let strip = pv_strip.way
  let s = strip.value_at(w.at)
  let delta_next = (s - sw.strip_down) + dx
  let none = if delta_next > 0.0 { !has_before } else { !has_after }
  let shown_next = if none { s + dx / 3.0 } else { s + dx }
  strip.put(shown_next)
  let delta = shown_next - sw.strip_down
  sw.speed.add(w.at, delta, 0.0)
  let (vx, _) = sw.speed.get_at(w.at)
  let step = strip_step(delta, vx, z.bw, true)
  let can_step = (step < 0 && has_before) || (step > 0 && has_after)
  if can_step {
    (self.wheel_off)()
    self.wheel_off = fn() {  }
    sw.state = Spent
    sw.spent_dir = if delta > 0.0 { 1.0 } else { -1.0 }
    sw.spent_min_dx = dx.abs()
    self.go_tree(src, step, vx * 1000.0)
    return true
  }
  let due = w.at + wheel_rest_ms
  self.wheel_arm(canvas, due, fn() {
    if pv_strip.wheel.state == Paging {
      pv_strip.wheel.reset()
      if !self.closing {
        pv_strip.way.go(0.0, @motion.carousel_spring, at=due)
      }
    }
  })
  true
}

///|
/// How long a trackpad's pull waits with no wheel come before it is let go (its fingers off and its momentum spent:
/// a browser says neither).
pub let wheel_rest_ms : Double = 160.0

///|
/// Whether a wheel's (dx, dy) is a mouse's notch said in points (a browser's: 100 or 120 a notch, a multiple of them
/// straight down), not a trackpad's way.
fn notched(dx : Double, dy : Double) -> Bool {
  let a = dy.abs()
  dx == 0.0 && a >= 100.0 && (a % 100.0 == 0.0 || a % 120.0 == 0.0)
}

///|
/// A key to viewer `vw` (its layer's: View::on_key), at its moment: Escape leaves marking (the marks it was making) or
/// else closes it; ← and → step to the picture before and after; the zoom's keys zoom (viewer_zoom_key). True where it
/// took the key; closing, it takes none.
fn Viewer::key_on(self : Viewer, src : Source, k : @view.Key) -> Bool {
  let v = self
  if v.closing {
    return false
  }
  let c = @ui.current()
  // (read in the reader, hosted: its keys its own first, what is open in it (its find, its contents) closed by Esc
  // before the viewer is, as the reader closes it after them (its on_back))
  if vf_reads(v) {
    return false
  }
  // (played: its keys the player's, hosted, Escape among them, its speeds and its list closed by it first (as the
  // player's own Escape leaves them before it leaves); in flight, before the player reads keys, Escape the viewer's
  // there too: Viewer::player_stage)
  if v.played() {
    return false
  }
  if k.code == @ui.key_escape && k.mods == 0 {
    if marking.on {
      marks_back()
    } else {
      v.shut(c)
    }
    return true
  }
  if marking.on || v.shown_kind() != Some(KImage) || (k.mods & (@ui.mod_cmd | @ui.mod_ctrl | @ui.mod_alt)) != 0 {
    return false
  }
  if k.code == @ui.key_code_left || k.code == @ui.key_code_right {
    v.go(c, src, if k.code == @ui.key_code_left { -1 } else { 1 }, 0.0)
    return true
  }
  @sf.viewer_zoom_key(v.zoom, k.code, k.mods, k.at)
}

///|
/// Whether viewer `v`'s floating bar is its nodes (image_head), `w` wide: what it shows
/// (not read in the reader), on a small screen (a phone's; a fold half open wider than one, its
/// kind and size with it), its own bar (not the system's beside it: an iPhone Duo's; there too while it marks, its
/// actions the bar's own). As each is told.
pub fn head_as_nodes(v : Viewer, w : Double) -> Bool {
  marks_said()
  v.in_tree && v.own_bar() && @sf.viewer_bar_floats(w)
}

///|
/// Whether viewer `vw`'s bar across the top is its nodes (image_bar), `w` wide: what it shows
/// (not read in the reader), not on a small screen (whose bar floats: head_as_nodes), its own bar
/// (not the system's beside it; there too while it marks, as head_as_nodes). As each is told.
pub fn bar_as_nodes(v : Viewer, w : Double) -> Bool {
  marks_said()
  v.in_tree && v.own_bar() && !@sf.viewer_bar_floats(w)
}

///|
/// How much of the window's top its own bar takes, `w` wide, its picture fitted clear of it (none where it has no bar of
/// its own). As each is told.
fn Viewer::bar_over(self : Viewer, w : Double) -> Double {
  if head_as_nodes(self, w) || bar_as_nodes(self, w) {
    @sf.viewer_bar_clear(w)
  } else {
    0.0
  }
}

///|
/// Whether it has a bar of its own (its nodes, image_head or image_bar): not read in the reader (the reader's bar), not
/// a picture or a page beside the system's own bars (an iPhone Duo's: its actions theirs, vf_native) unless it marks.
fn Viewer::own_bar(self : Viewer) -> Bool {
  marks_said()
  let theirs = @sf.native_on() &&
    (self.shown_kind() == Some(KImage) || self.shown_kind() == Some(KHtml)) &&
    !marking.on
  !vf_reads(self) && !self.played() && !theirs
}

///|
/// How far in viewer `vw` is as node `node` is drawn (its flight's share, else its fade, sampled as it is drawn while
/// either goes; where neither goes, as it is).
fn Viewer::shown_on(self : Viewer, node : @view.View) -> Double {
  let vw = self
  vw.fly.said()
  vw.fade.said()
  let t = node.drawn_while(fn(at) { vw.fly.goes_at(at) || vw.fade.goes_at(at) })
  if vw.flies {
    vw.flight_share_at(t)
  } else {
    vw.fade.value_at(t)
  }
}

///|
/// Viewer `vw`'s floating bar as nodes in `h` (viewer_head_node): its file's name (its kind and
/// size after it, wider than a phone), there while its bars are (Viewer::bars_shown), as far in as the viewer is
/// (Viewer::shown_on); while its picture comes, how much of it has once the core has said (viewer_coming_node); its
/// tools (image_tools), ×. Each press done at its moment. Their tips in a layer of its own over all of it.
fn image_head(h : @view.View, src : Source, vw : Viewer, stage : () -> (Double, Double)) -> Unit {
  h.over(Is(true)) |> ignore
  let ink = fn() { @sf.page_viewer_ink() }
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  let whole = fn() { vw.bytes.get() is Some(_) }
  let dl = fn() { vw.download(src) }
  let marked = fn() {
    marks_said()
    marking.on
  }
  @sf.viewer_head_node(
    h,
    fn() { vf_title(vw) },
    // (its kind and size after its name where the bar has room: wider than a phone, viewer_head_node)
    fn() { vf_meta(vw, src) },
    // (as it rests, a tap hides it, while it comes or upgrades it stays)
    fn() { vw.bars_shown() || vw.image_loading() },
    fn(node) { vw.shown_on(node) },
    fn() { (@sf.viewer_host().room)().0 },
    fn() { stage().0 },
    ink,
    fn() { @sf.viewer_page_glass() },
    fn(row) {
      // while it comes or upgrades, how much of it has, once the core has said: a line of the bar's own as the wide bar's is
      // (viewer_coming_node), never the stage's card (file_progress_node), taller than the bar and crowding its name out
      row.show(fn() { !marked() && vw.image_loading() && vw.got.get() is Some(_) }, fn(r) {
        @sf.viewer_coming_node(r, fn() { vw.got.get() }, fn() { vw.file.size }, ink, lead=false, track=@sf.vfr_head_coming_track)
        |> ignore
      })
      // (its tools; marking, marking's actions in their place; hidden while upgrading with progress shown on narrow head bar)
      row.show(fn() { !marked() && !(vw.upgrading() && vw.got.get() is Some(_)) }, fn(r) {
        r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@sf.keys_apart())) |> ignore
        image_tools(r, src, vw, ink, Is(@sf.tool_side / 2.0), tips)
      })
      row.show(marked, fn(r) { marks_actions_node_of(r, vw, ink, tips) })
    },
    fn() {
      // (marking, which of its actions: marks_actions_node's)
      let m = if marked() { "\{marking.busy} \{marking.error} \{marks_any()} \{vw.draft_key() != ""}" } else { "" }
      "\{whole()} \{downloading(dl())} \{vw.coming()} \{vw.upgrading()} \{vw.got.get() is Some(_)} \{m}"
    },
    fn() {
      vw.shut_tree()
    },
    tips=tips,
  )
  |> ignore
  // (its tips over all of it)
  tips_at.val = Some(h.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// Viewer `vw`'s bar across the top as nodes in `h` (viewer_bar_node): back to where it was
/// opened from by name, its file's name and the line about it (which of how many, its size, its kind, its size in
/// pixels), where the file is its tip (none for a draft's, kept on this device alone); gone up while its bars are not
/// shown (Viewer::bars_shown), as far in as the viewer is (Viewer::shown_on); while its picture comes, how much of it
/// has (viewer_coming_node); its tools once it no longer does (image_tools), each round as a page's bar's buttons are at
/// the window's corner. Its way back closes it, at the press's moment. Their tips in a layer
/// of its own over all of it.
fn image_bar(h : @view.View, src : Source, vw : Viewer, stage : () -> (Double, Double)) -> Unit {
  h.over(Is(true)) |> ignore
  let ink = fn() { @sf.page_viewer_ink() }
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  @sf.viewer_bar_node(
    h,
    fn() { vw.desk_back(src) },
    fn() { vf_title(vw) },
    fn() { vf_meta(vw, src) },
    fn() { if vw.shown_kind() == Some(KMbui) || is_mbui_viz(vw.file.name) || vw.file.path.has_prefix("draft:") { "" } else { vw.file.path } },
    // (marking, there: Viewer::bars_shown; anything but a picture's stays)
    fn() { vw.shown_kind() == Some(KImage) && !vw.bars_shown() },
    fn(node) { vw.shown_on(node) },
    fn() { (@sf.viewer_host().room)().0 },
    fn() { stage().0 },
    ink,
    fn(row, corner) {
      let marked = fn() {
        marks_said()
        marking.on
      }
      // (while it comes or upgrades, from the start)
      row.show(fn() { !marked() && vw.image_loading() }, fn(r) {
        @sf.viewer_coming_node(r, fn() { vw.got.get() }, fn() { vw.file.size }, ink) |> ignore
      })
      // (its tools; marking, marking's actions in their place)
      row.show(fn() { !marked() }, fn(r) {
        r.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(@sf.keys_apart())) |> ignore
        image_tools(r, src, vw, ink, corner, tips)
      })
      row.show(marked, fn(r) { marks_actions_node_of(r, vw, ink, tips) })
    },
    fn() {
      vw.shut_tree()
    },
    tips,
  )
  |> ignore
  tips_at.val = Some(h.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// The ways to the pictures before and after viewer `vw`'s as nodes in `h` (viewer_steps_node):
/// each while what is beside it says there is one (imageNear's, its folder's), there while its bars are
/// (Viewer::bars_shown), as far in as the viewer is (Viewer::shown_on), a phone's sizes under 640; pressed, a step to
/// that one at the press's moment (Viewer::go). Their tips in a layer of their own over all of it.
fn image_steps(h : @view.View, src : Source, vw : Viewer, stage : () -> (Double, Double)) -> Unit {
  h.over(Is(true)) |> ignore
  let tips_at : Ref[@view.View?] = Ref(None)
  let tips = @sf.TipLayer::new(fn() { tips_at.val })
  @sf.viewer_steps_node(
    h,
    fn() { vw.near_ids(src).0 is Some(_) },
    fn() { vw.near_ids(src).1 is Some(_) },
    fn() { vw.bars_shown() },
    fn(node) { vw.shown_on(node) },
    fn() { stage().0 <= @sf.viewer_small_w },
    fn(dir) { vw.go_tree(src, dir, 0.0) },
    tips,
  )
  |> ignore
  tips_at.val = Some(h.box(fn(l) { l.over(Is(true)) |> ignore }))
}

///|
/// A picture's tools in a bar's row `row` (then copy, 移到侧边 and download): mark and copy once its picture is all here (copied:
/// a check for copied_ms, from the press's moment); download (unable while there is nothing to save; a ring while the
/// core downloads it; none while it comes). Each `corner` round, in `ink`, its tip in `tips`; each press done at its
/// moment, what a download asks for told once, as it is asked.
fn image_tools(
  row : @view.View,
  src : Source,
  vw : Viewer,
  ink : () -> @sf.ViewerInk,
  corner : @view.Live[Double],
  tips : @sf.TipLayer,
) -> Unit {
  let whole = fn() { vw.bytes.get() is Some(_) }
  let dl = fn() { vw.download(src) }
  // 预览 / 源码: a table's, a page's, an mbui widget's once read (Markdown read in the reader, its own bar): the library's
  // segmented choice, its nodes (@sf.seg_node), what it chooses told (Viewer::set_source)
  row.show(fn() { whole() && vf_has_source(vw) }, fn(r) {
    // (giving way as it does where the bar is short of room: its track fitted to what there is)
    r.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    @sf.seg_node(
      r,
      fn() { [@sf.t("web-main.preview.rendered"), @sf.t("web-main.preview.source")] },
      fn() {
        vw.source_told.get() |> ignore
        if vw.source {
          1
        } else {
          0
        }
      },
      fn(k) { vw.set_source(k == 1) },
      item_w=vf_tabs_item,
    )
    |> ignore
  })
  // 标注图片: once its whole picture is here, a picture it shows
  row.show(fn() { whole() && vw.markable() }, fn(r) {
    @sf.tool_node(
      r,
      fn() { { icon: "edit", label: @sf.t("web-main.annotate.image"), on: false, disabled: false } },
      ink,
      corner,
      fn() { marks_start() },
      tip=tips,
    )
    |> ignore
  })
  // 复制: the whole picture on the clipboard, a check a moment after; one too big to show
  // too, once read
  row.show(fn() { whole() && vw.shown_kind() == Some(KImage) }, fn(r) {
    @sf.copy_tool_node(r, ink, corner, fn() { vw.ask_copy() }, tip=tips) |> ignore
  })
  // 移到侧边: where the shell has a side panel for the page under it, a file that opens there (beside_offered): the
  // whole window closed for its tab
  row.show(fn() { beside_offered(vw.file.path, vw.file.name) }, fn(r) {
    @sf.tool_node(
      r,
      fn() { { icon: "panel-open", label: @sf.t("web-main.preview.moveBeside"), on: false, disabled: false } },
      ink,
      corner,
      fn() { vw.move_beside(src) },
      tip=tips,
    )
    |> ignore
  })
  let is_mini_app = fn() { vw.shown_kind() == Some(KMbui) || is_mbui_viz(vw.file.name) }
  // 分享 on a phone (shares_out): what is here handed to the system's share sheet; one told of, read whole first. Not
  // beside 预览 / 源码 (a table, a page) or for a `.mbui` mini-program: a phone's floating bar has no room for both with the name (words at 1.3)
  row.show(fn() { !is_mini_app() && shares_out() && !vw.coming() && !downloading(dl()) && (whole() || vw.told_of()) && !(whole() && vf_has_source(vw)) }, fn(r) {
    @sf.tool_node(
      r,
      fn() {
        let here = vw.bytes.get() is Some(_) || (vw.told_of() && !vw.asked_now())
        { icon: "share", label: @sf.t("android-misc.drive.share"), on: false, disabled: !here }
      },
      ink,
      corner,
      fn() { vw.ask_share() },
      tip=tips,
    )
    |> ignore
  })
  // download: what is here saved at once; one told of, read whole first; a ring while the core downloads it (none for a `.mbui` mini-program)
  row.show(fn() { !is_mini_app() && !vw.coming() }, fn(r) {
    @sf.tool_node(
      r,
      fn() {
        let saving = vw.bytes.get() is Some(_) || (vw.told_of() && !vw.asked_now())
        { icon: "download", label: @sf.t("web-main.preview.download"), on: false, disabled: !saving }
      },
      ink,
      corner,
      fn() { vw.save_tree() },
      tip=tips,
      progress=fn() { if downloading(dl()) { Some(number(dl(), "progress")) } else { None } },
    )
    |> ignore
  })
}

///|
/// What viewer `vw` asked the core to download (Viewer::ask_save), told it once, at the moment it was asked
/// (image_layer's: as that change is done).
fn download_told(src : Source, vw : Viewer) -> Unit {
  if vw.download_asked {
    vw.download_asked = false
    download_start(src, vw.station, vw.key, vw.name, vw.file.size, from=vw.opened_from())
  }
}

///|
/// How much of a file has come (file_progress's) as nodes in `parent`: "正在读取 **4 MB** /
/// 12 MB" (the size so far in bold, in the words' ink) over a bar, on the surface (surface2 dark), 14 round, 14 and 12
/// in, 220 wide; its size not known (neither the station's, `got`'s, nor the one it was sent with, `sent`), 正在读取 over
/// a bar that sweeps. Each as it changes: what has come, the words' language, the theme. The card's node.
pub fn file_progress_node(
  parent : @view.View,
  got : () -> (Double, Double?),
  sent : () -> Double,
  said? : () -> String? = fn() { None },
) -> @view.View {
  let total = fn() -> Double? {
    match got().1 {
      Some(n) => Some(n)
      None => if sent() > 0.0 { Some(sent()) } else { None }
    }
  }
  let wide = match @sf.file_progress_w {
    Fixed(w) => w
    _ => 220.0
  }
  parent.box(fn(card) {
    card
    // (as wide as its words, 220 at least: a size never broken off its unit)
    .min_width(Is(Some(wide)))
    .padding(Is((@ui.Space::px(S3_5), @ui.Space::px(S3), @ui.Space::px(S3_5), @ui.Space::px(S3))))
    .gap(Is(@ui.Space::px(S2)))
    .lines_up(Is(Some(Middle)))
    .radius(Is(file_progress_corner))
    .ground(By(fn() {
      let t = @sf.theme()
      if t.dark {
        surface2_dark
      } else {
        t.p.card
      }
    }))
    |> ignore
    card.box(fn(w) {
      w
      .words_runs(By(fn() {
        match (said(), total()) {
          // (what is said of how far it has come in its place: a download's, the core's words)
          (Some(words), _) => [@view.words_run(words)]
          (None, Some(n)) => {
            // the size so far in bold, where the sentence has it
            let words = pv("android-chat.file.loading.size")
            let (before, after) = match words.find("{size}") {
              Some(i) => (words.exact_view(end=i).to_owned(), words.exact_view(start=i + 6).to_owned())
              None => (words, "")
            }
            [
              @view.words_run(before),
              @view.words_run(@sf.file_size(got().0), weight=600, ink=@sf.theme().p.text),
              @view.words_run(" / " + @sf.file_size(n) + after),
            ]
          }
          (None, None) => [@view.words_run(pv("common.reading"))]
        }
      }))
      .words_look(By(fn() {
        let (size, line) = @ui.tree_theme().text_size(Body)
        { size, weight: 400, line, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() { @ui.tree_theme().color(Muted) }))
      |> ignore
    })
    |> ignore
    // (as wide as the card has room)
    @sf.progress_node(
      card,
      fn() {
        match total() {
          Some(n) if n > 0.0 => Some(dmin(1.0, got().0 / n))
          _ => None
        }
      },
      fn() { @ui.tree_theme().line },
      fn() { @sf.theme().p.accent },
    )
    .width_share(Is(1.0))
    |> ignore
  })
}

///|
/// Whether viewer `vw`'s picture flying in or back is drawn by its flight's nodes: drawn by the window's tree, flying,
/// not a picture that could not be decoded (its words alone).
pub fn Viewer::flight_node(self : Viewer) -> Bool {
  self.in_tree && self.flies && !self.picture_failed()
}

///|
/// How far its flight has got at `t` (Viewer::flying's, at a moment of its own).
fn Viewer::flying_at(self : Viewer, t : Double) -> Double {
  if !self.flies {
    1.0
  } else {
    self.flight_share_at(t)
  }
}

///|
/// How far its thumbnail has gone out from under the bar or the composer at `t` (0 where the chat lays it out, 1 clear
/// of them): the first share of the flight's one Move, at a moment of its own; 1 when nothing hid it.
pub fn Viewer::lifted_at(self : Viewer, t : Double) -> Double {
  if !self.flies || self.fly_lift <= 0.0 {
    1.0
  } else {
    dmin(self.fly.value_at(t) / self.fly_lift, 1.0)
  }
}

///|
/// What a flight is drawn by of the thumbnail it flies from (Thumb's but what it draws over its picture), to tell it
/// changed.
#derive(Eq)
struct ThumbDrawn {
  box : (Double, Double, Double, Double)
  seen : (Double, Double, Double, Double)?
  clear : (Double, Double)?
  corners : (Double, Double, Double, Double)
  letterbox : Bool
  start_crop : Bool
  picture : String
}

///|
/// What the stage of a viewer that shows no picture of its own shows (as it is told: its kind sniffed, its bytes, a
/// read failed, what has come of it, 源码): told of (facts), coming, failed, or what its stage's nodes show of it (read
/// in the reader, as it comes, a page, a table, code, a PDF: viewer_stage_node).
#derive(Eq)
priv enum OuterStage {
  Hosted
  Coming
  Facts
  Failed
}

///|
fn Viewer::outer_stage(self : Viewer) -> OuterStage {
  let v = self
  v.flow_told.get() |> ignore
  match v.flow {
    Some(f) => f.parts.get() |> ignore
    None => ()
  }
  if v.flowing() || vf_reads(v) {
    Hosted
  } else if v.told_of() {
    Facts
  } else if (v.kind is None && v.sniffed.get() is None) || (v.bytes.get() is None && v.error.get() is None) {
    Coming
  } else if v.error.get() is Some(_) {
    Failed
  } else {
    Hosted
  }
}

///|
/// What viewer `vw` shows of anything but a picture of its own (a picture too big to show, told of; a page, a table,
/// code, words read as they come or in the reader, a PDF, a file of no kind), in node `n`, as far in as its way has
/// come (Viewer::words_share): told of, coming, failed, its nodes (in the middle of the stage, 24 in, 14 apart); else
/// what its stage's nodes show of it (viewer_stage_node), the stage `width()` wide. What is round them is the window's
/// tree's (image_layer: the modal layer, its keys and back, its ground, its bars, its way in and out, what it reads
/// asked); its keys theirs only where they read them first (a reader's find, its contents, Viewer::key_on).
fn viewer_hosted(n : @view.View, src : Source, vw : Viewer, width : () -> Double) -> Unit {
  let stage = fn() { vw.outer_stage() }
  n.box(fn(s) {
    s
    .over(Is(true))
    .alpha(By(fn() {
      vw.fly.said()
      vw.fade.said()
      vw.words_share(vw.in_at(s.drawn_while(fn(at) { vw.fly.goes_at(at) || vw.fade.goes_at(at) })))
    }))
    // (going, the page's: a press there its own, nothing of it here taking it)
    .presses(By(fn() {
      match pv_leaving.get() {
        Some(l) => !physical_equal(l, vw)
        None => true
      }
    }))
    |> ignore
    s.show(fn() { stage() == Hosted && viewer_mbui_rendered(vw) }, fn(m) {
      viewer_mbui_node(m, src, vw, bars=true)
    })
    s.show(fn() { stage() == Hosted && !viewer_mbui_rendered(vw) }, fn(h) { viewer_stage_node(h, src, vw, width) })
    s.show(fn() { stage() != Hosted }, fn(note) { viewer_note_node(note, src, vw, stage) })
  })
  |> ignore
  // 下载 asked on it (Viewer::ask_save): the core told at that change, on by itself whatever becomes of this viewer;
  // 安装 asked before its bytes came, done as they come (Viewer::ask_install)
  n.reacts(fn() { (vw.asked_told.get(), vw.bytes.get() is Some(_), vw.previewed.get()) }, fn(_) {
    if vw.install_after && vw.whole_here() is Some(_) {
      vw.install_after = false
      vw.ask_install()
    }
    // 分享 asked before its bytes came, handed on as they come (Viewer::ask_share)
    vw.share_came()
  })
}

///|
/// What the stage of viewer `vw` says in its middle in `note` (24 in, 14 apart) where it shows nothing else (`stage`):
/// told of, coming, failed, its nodes; a tap on it, coming or failed, shows or hides the bars, as the old stage's did
/// (tap_stage; told of, none). The whole window's (viewer_hosted) and a tab's beside a chat (viewer_tab_node: `bars`
/// false, no bars to show or hide, so no press of its own either).
fn viewer_note_node(
  note : @view.View,
  src : Source,
  vw : Viewer,
  stage : () -> OuterStage,
  bars? : Bool = true,
) -> Unit {
  note.over(Is(true)).padding(Is((24.0, 24.0, 24.0, 24.0))).gap(Is(14.0)).lines_up(Is(Some(Middle))) |> ignore
  if bars {
    note.presses(Is(true)).on_press(fn() {
      let now = @signals.untracked(stage)
      if now == Coming || now == Failed {
        vw.toggle()
      }
    })
    |> ignore
  }
  note.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
  note.show(fn() { stage() == Facts }, fn(f) { viewer_facts_node(f, src, vw) })
  note.show(fn() { stage() == Coming }, fn(f) { viewer_coming_node(f, vw) })
  note.show(fn() { stage() == Failed }, fn(f) {
    f.box(fn(w) {
      w
      .words(By(fn() { pv_fill("android-chat.file.loadFailed", [("error", vw.error.get().unwrap_or(""))]) }))
      .words_look(By(fn() {
        let size = @sf.theme().t.body
        { size, weight: 400, line: @ui.tree_theme().text_line * size, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(fn() { @sf.theme().p.muted }))
      |> ignore
    })
    |> ignore
  })
  note.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
}

///|
/// The moment what follows film `vw`'s flight and fade in `node` reads them at: as each frame draws it while either
/// goes; else as it is, the clock read no more.
fn film_at(vw : Viewer, node : @view.View) -> Double {
  vw.fly.said()
  vw.fade.said()
  node.drawn_while(fn(at) { vw.fly.goes_at(at) || vw.fade.goes_at(at) })
}

///|
/// Film `vw`'s flight (Viewer::player_flight), in `parent` (`origin` where `parent` is drawn in the window): the box it
/// is cut to, its box round, its still on the black, what its thumbnail draws over it; drawn at the moments `mine` says
/// (its own layer's, or the slot of the page it flies from under that page's bar: viewer_flight_slot), as image_flight is.
fn film_flight(
  parent : @view.View,
  src : Source,
  vw : Viewer,
  mine : (Double) -> Bool,
  origin? : () -> (Double, Double) = fn() { (0.0, 0.0) },
) -> Unit {
  let at = fn(node) { film_at(vw, node) }
  let mine_flight = fn(node : @view.View) -> (FlightBox, Double)? {
    let t = at(node)
    if mine(t) {
      vw.player_flight(src, node, t)
    } else {
      None
    }
  }
  // its flight: the box it is cut to, its box round (the thumbnail's corners as far as the flight leaves them), the
  // still in it on the black where it is letterboxed or not decoded yet (one frame), what the thumbnail draws over it
  let flight = fn(node : @view.View) -> FlightBox? { mine_flight(node).map(fn(f) { f.0 }) }
  parent.box(fn(cut) {
    cut
    .over(Is(true))
    // (a picture alone: no press taken anywhere in it, whatever is under it its own (it covers the window as it waits
    // for the frame it goes back with))
    .presses(Is(false))
    .clips(Is(true))
    .offset(By(fn() {
      match flight(cut) {
        Some(f) => {
          let (x, y) = origin()
          (f.cut.0 - x, f.cut.1 - y)
        }
        None => (0.0, 0.0)
      }
    }))
    .width(By(fn() { flight(cut).map(fn(f) { f.cut.2 }) }))
    .height(By(fn() { flight(cut).map(fn(f) { f.cut.3 }) }))
    |> ignore
    cut.box(fn(b) {
      let picture = fn() {
        vw.grab_told.get() |> ignore
        if vw.fly_pic != "" {
          vw.fly_pic
        } else if vw.shown_kind() == Some(KVideo) {
          vw.still(src)
        } else {
          ""
        }
      }
      b
      .over(Is(true))
      .clips(Is(true))
      .corners(By(fn() { flight(b).map(fn(f) { f.corners }) }))
      .offset(By(fn() {
        match flight(b) {
          Some(f) => (f.box.0 - f.cut.0, f.box.1 - f.cut.1)
          None => (0.0, 0.0)
        }
      }))
      .width(By(fn() { flight(b).map(fn(f) { f.box.2 }) }))
      .height(By(fn() { flight(b).map(fn(f) { f.box.3 }) }))
      // (no still: the black alone)
      .ground(By(fn() {
        if flight(b) is Some(_) && picture() == "" {
          0x000000FFL
        } else {
          0L
        }
      }))
      |> ignore
      // (the still and the black round it one frame filling the box, cut once by its round corners, as the old
      // flight's picture in its matte was)
      b.box(fn(f) {
        f
        .over(Is(true))
        .image(By(fn() {
          match flight(f) {
            Some(_) if picture() != "" => Some((picture(), "", stage_max_px()))
            _ => None
          }
        }))
        .image_in(By(fn() {
          match flight(f) {
            Some(fb) if picture() != "" =>
              Some(((fb.picture.0 - fb.box.0, fb.picture.1 - fb.box.1, fb.picture.2, fb.picture.3), 0x000000FFL))
            _ => None
          }
        }))
        |> ignore
      })
      |> ignore
      // what the thumbnail draws over its picture (its capsule), whole, in its box: gone by halfway out, back from
      // halfway in, as a row's content goes with its room; none seen where it flies not (its old view made as the
      // viewer is, built by the time it sets out)
      b.box(fn(o) {
        o
        .over(Is(true))
        .alpha(By(fn() {
          match mine_flight(o) {
            Some((_, p)) => dmax(0.0, 1.0 - flight_over_gone * p)
            None => 0.0
          }
        }))
        |> ignore
        // (what it draws over its picture, as its chat said it last (Viewer::thumb_over): its capsule in its foot's
        // start corner, as the thumbnail's own (@sf.video_capsule_node), where it is and how big the flight's, followed
        // by the nodes round it; none of its place read here)
        o.pick(
          fn() { vw.thumb_over().map(fn(t) { (t.duration, t.corner, t.coming is Some(_)) }) },
          fn(p, made) {
            p.over(Is(true)).alpha(By(fn() { vw.thumb_over().map_or(0.0, fn(t) { t.seen }) })) |> ignore
            match made {
              Some((duration, corner, true)) =>
                @sf.video_capsule_node(p, duration, corner~, coming=fn() { vw.thumb_over().bind(fn(t) { t.coming }) })
              Some((duration, corner, false)) => @sf.video_capsule_node(p, duration, corner~)
              None => ()
            }
          },
          at_once=true,
        )
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Whether a video's thumbnail in the chat letterboxes its still: sfpages' image_box at a video's least (96), a film
/// thinner than that across or high in the chat's box (its own proportions, sent with it or its ThumbHash's at the
/// unknown box's height, within 360×300, a tiny one drawn to 40) drawn in its proportions with the black round it, as
/// its flight draws it too (film_shared). The same rule, held to it by preview_tree_wbtest.
pub fn film_letterboxed(a : Attachment) -> Bool {
  let least = 96.0
  let (w, h) = if a.width > 0.0 && a.height > 0.0 {
    (a.width, a.height)
  } else {
    guard a.thumbhash != "" && @pixels.thumbhash_ratio(@codec.from_base64(a.thumbhash)) is Some(r) else {
      return false
    }
    ((160.0 * r).round(), 160.0)
  }
  let longer = if w > h { w } else { h }
  let tiny = if 40.0 / longer > 1.0 { 40.0 / longer } else { 1.0 }
  let across = 360.0 / w
  let down = 300.0 / h
  let scale = if tiny < across { tiny } else { across }
  let scale = if scale < down { scale } else { down }
  !(w * scale >= least && h * scale >= least)
}

///|
/// A chat's film viewer `vw` opened from a thumbnail that is a node of the window's tree (a chat's page made as nodes:
/// message_video_node's, the end of the flight that stays), in node `n`: its still where the player draws its picture,
/// under the player, flown by the tree from that thumbnail as it opens and, let go of as it closes (Viewer::tree_back,
/// once the frame it shows is grabbed: the thumbnail keeps it), the thumbnail flown back from where it was (View::shared,
/// as an image's picture is: image_layer), out from under the chat's bar or composer first where they cover it. Whether
/// its picture is the flight's now: on its way in (till its flight's end, told as it sets out: View::shared's `told`), or
/// let go of; its thumbnail no such node shown as it opens, never.
fn film_shared(n : @view.View, src : Source, vw : Viewer) -> () -> Bool {
  let id = vw.thumb_id()
  guard @signals.untracked(fn() { vw.in_tree && vw.chat_file() && vw.shown_kind() == Some(KVideo) }) &&
    tree_thumb_seen(id) else {
    return fn() { false }
  }
  // (how its thumbnail draws it: letterboxed or covering its box (message_video_node's), a quote's corner or a
  // message's file's, a draft's tile with no length over it)
  let letterbox = film_letterboxed(vw.file)
  let draft = vw.file.path.has_prefix("draft:")
  let corner = if vw.at.contains("/q:") { @sf.quote_picture_corner } else { @sf.message_file_corner }
  // (paired as it is made, its thumbnail shown then: its flight's end told once the change is committed, View::shared's
  // `told`; meanwhile as long as a flight may take at most)
  let made = n.cause_at()
  let goes = fn(t : Double) {
    // (its flight told as it sets out: till it ends, Viewer::tree_way_told; before that, as long as one may take)
    if vw.tree_way.get() {
      t < vw.tree_way_end
    } else {
      t < made + flight_most_ms
    }
  }
  n.show(at_once=true, fn() { !vw.tree_back.get() }, fn(p) {
    // (how it flies from its thumbnail and back: the app's route, as a picture's, viewer_route)
    let (route, grown_of) = viewer_route(fn() { p.window() })
    let place = fn() {
      // (where the player draws its picture: as it was last drawn once it has been, zoomed, moved, read again as it
      // closes (its frame asked for, pv_leaving); else, or where it has read no size of the film yet (a point in its
      // middle), as it fits it by the film's size its message says: never from a point)
      pv_leaving.get() |> ignore
      vw.grab_told.get() |> ignore
      match vw.player_place() {
        Some(r) if r.2 > 1.0 && r.3 > 1.0 => Some(r)
        _ => {
          let (w, h) = p.window()
          vw.video_target(src, player_width(w), h, p.cause_at())
        }
      }
    }
    p
    .over(Is(true))
    .presses(Is(false))
    .offset(By(fn() {
      match place() {
        Some((x, y, _, _)) => (x, y)
        None => (0.0, 0.0)
      }
    }))
    .width(By(fn() { place().map(fn(r) { r.2 }) }))
    .height(By(fn() { place().map(fn(r) { r.3 }) }))
    // (its still, as the thumbnail draws it; none: the black alone)
    .ground(By(fn() {
      match vw.still(src) {
        "" | "!" => 0x000000FFL
        _ => 0L
      }
    }))
    .image(By(fn() {
      match vw.still(src) {
        "" | "!" => None
        k => Some((k, "", stage_max_px()))
      }
    }))
    // (as its thumbnail draws it, so it flies as one: covering its box, a letterboxed one contained)
    .image_contains(Is(true))
    .image_covers(Is(!letterbox))
    .shared(Is(id), @motion.flight_by(@motion.moved()), with_stays=true, route~, told=fn(start, end, along) {
      vw.tree_way_told(start, end, grown_of(vw.tree_back.untracked(), along))
    })
    |> ignore
    // (its length over it as the thumbnail draws it, while it flies from there: a mark, carried at its own size by its
    // corner and gone halfway, View::flight_mark; none once it is the player's)
    p.box(fn(c) {
      c
      .over(Is(true))
      .width(By(fn() { place().map(fn(r) { r.2 }) }))
      .height(By(fn() { place().map(fn(r) { r.3 }) }))
      .alpha(By(fn() {
        vw.tree_way.get() |> ignore
        let t = c.drawn_while(goes)
        if goes(t) {
          1.0
        } else {
          0.0
        }
      }))
      |> ignore
      // (a draft's has none: its tile in the composer shows no length; a quote's picture its own corner; how far it
      // has come, as the thumbnail says it: message_video_node's)
      if !draft {
        let coming = fn() -> Double? {
          let dl = download_of(src, vw.station, vw.key, vw.name)
          if flag(dl, "active") {
            Some(number(dl, "progress"))
          } else {
            match keeping_of(src, vw.station, vw.key, vw.name) {
              Some(_) as kept => Some(number(kept, "progress"))
              None => None
            }
          }
        }
        @sf.video_capsule_node(c, vw.file.duration, corner~, coming~)
      }
    })
    |> ignore
    // (closing, the frame its player showed, grabbed, over the still: asked for here to be decoded under the player,
    // which goes back once it is (Viewer::left_with_picture), the still seen till it is)
    p.box(fn(f) {
      f
      .over(Is(true))
      .width(By(fn() { place().map(fn(r) { r.2 }) }))
      .height(By(fn() { place().map(fn(r) { r.3 }) }))
      .image(By(fn() {
        vw.grab_told.get() |> ignore
        if vw.leaving_pic != "" {
          Some((vw.leaving_pic, "", stage_max_px()))
        } else {
          None
        }
      }))
      .image_contains(Is(true))
      .image_covers(Is(!letterbox))
      |> ignore
    })
    |> ignore
  })
  fn() {
    vw.tree_back.get() || {
      // (followed: its flight told as it sets out)
      vw.tree_way.get() |> ignore
      let t = n.drawn_while(goes)
      goes(t)
    }
  }
}

///|
/// What viewer `vw` shows of a film or a song, in node `n`: the player as nodes (@sf.player_node: its picture, its bars
/// and controls, its keys, the full screen and turning sideways), as far in as its fade has come and, while the
/// picture flies, as far as its bars come with it (bars_share: none till its ground is whole); in flight its still the
/// tree's (Viewer::player_flight): from the thumbnail to where the player draws its picture and back, the black and the
/// still one frame cut once (View::image_in), what the thumbnail draws over it (its capsule) going as it leaves and back
/// as it lands; going, the page's presses theirs. Back is the player's first where it takes it (its 全屏 left, beside
/// the system's bars; turned upright), then the viewer's (its layer's: image_layer).
fn viewer_player(n : @view.View, src : Source, vw : Viewer) -> Unit {
  let at = fn(node) { film_at(vw, node) }
  // its flight, in its own layer once it is out from under the bar of the page it flies from (that page's slot draws
  // it till then, the bar over it: viewer_flight_slot)
  film_flight(n, src, vw, fn(t) { vw.flies_from_page() == 0 || vw.lifted_at(t) >= 1.0 })
  // its thumbnail a node of the window's tree (a chat's page made as nodes): its picture flown by the tree from it and
  // back into it (film_shared)
  let tree_flies = film_shared(n, src, vw)
  // (the player over its flight, its bars coming as its ground is whole)
  n.box(fn(s) {
    s
    .over(Is(true))
    .alpha(By(fn() {
      let t = at(s)
      match vw.player_flight(src, s, t) {
        Some((_, p)) => bars_share(p) * vw.fade.value_at(t)
        // (flown by the window's tree: its bars as its ground is whole, as one flown here, bars_share)
        None =>
          if vw.tree_way.get() {
            bars_share(vw.fade.value_at(t))
          } else if vw.flies {
            vw.fade.value_at(t)
          } else {
            vw.words_share(vw.in_at(t))
          }
      }
    }))
    .presses(By(fn() {
      match pv_leaving.get() {
        Some(l) => !physical_equal(l, vw)
        None => true
      }
    }))
    |> ignore
    match vw.media {
      Some(m) => {
        // (a fixture's: how it stands pinned, the same on every run)
        match vw.pinned {
          Some(p) => m.pin(p)
          None => ()
        }
        let stage = fn() {
          let (w, h) = s.window()
          (player_width(w), h)
        }
        // (where a film's picture is fitted in the viewer, what its flight goes to and back from: its vzoom told the
        // room the player leaves it and the picture's size (Viewer::video_natural) at the moment either changes)
        s.reacts(
          fn() {
            let (w, h) = stage()
            let (top, foot) = @sf.player_room(w)
            ((w, h - top - foot), vw.video_natural(src))
          },
          fn(told) {
            let ((bw, bh), (nw, nh)) = told
            let at = s.cause_at()
            vw.vzoom.boxed(bw, bh, at~)
            if nw > 0.0 && nh > 0.0 {
              vw.vzoom.natural(nw, nh, at~)
            }
          },
        )
        @sf.player_node(
          s,
          m,
          vw.player_file(),
          stage,
          back_label=fn() { vw.desk_back(src) },
          on_back=fn() { vw.shut_tree() },
          // (the chat's still where its picture will be, until its first frame shows)
          still=fn() { if vw.shown_kind() == Some(KVideo) { vw.still(src) } else { "" } },
          // (flying in, or back into its thumbnail once the frame it shows is grabbed: its picture the flight's)
          flying=fn() {
            vw.said_flying()
            (vw.flies && (!vw.closing || !vw.leaving_grab)) || tree_flies()
          },
          // (closed by its fade: its controls away at once, the page showing through as it goes)
          going=fn() {
            vw.said_flying()
            vw.closing && !vw.flies
          },
          move_beside=fn() { if beside_offered(vw.file.path, vw.file.name) { Some(fn() { vw.move_beside(src) }) } else { None } },
        )
        |> ignore
      }
      None => ()
    }
  })
  |> ignore
}

///|
/// What whether viewer `vw`'s picture flies or it goes is worked out of, followed: its flight said, the frame it closes
/// with grabbed, its flying told, its going.
fn Viewer::said_flying(self : Viewer) -> Unit {
  self.fly.said()
  self.grab_told.get() |> ignore
  self.flies_told.get() |> ignore
  pv_leaving.get() |> ignore
}

///|
/// The file viewer `v` plays as its player has it (Viewer::player_stage's): its name, size, type and facts; a film or
/// a song; where it is (a draft's none); its 下载 the viewer's.
fn Viewer::player_file(self : Viewer) -> @sf.ViewerFile {
  let v = self
  {
    name: v.file.name,
    size: v.file.size,
    mtime: 0.0,
    mime: v.mime,
    kind: if v.shown_kind() == Some(KAudio) { "audio" } else { "video" },
    title: if v.file.path.has_prefix("draft:") { "" } else { v.file.path },
    key: "",
    bytes: None,
    read: fn(_, _, done) { done(Err("")) },
    stream: None,
    direct: "",
    beside: None,
    place: fn() { NeverLeft },
    keep_place: fn(_, _) {  },
    save: fn() { v.save_tree() },
    facts: { width: v.file.width, height: v.file.height, duration: v.file.duration, frames: v.file.frames },
  }
}

///|
/// Viewer `vw` stepped from a node of the window's tree (its ‹ / › buttons or trackpad horizontal swipe), at that
/// moment; closing, nothing.
fn Viewer::go_tree(self : Viewer, src : Source, dir : Int, velocity : Double) -> Unit {
  if !self.closing {
    self.go(@ui.current(), src, dir, velocity)
  }
}

///|
/// Viewer `vw` closed from a node of the window's tree (its back, its × or its way back pressed, a finger taking it
/// down), at that moment; closing, nothing.
fn Viewer::shut_tree(self : Viewer) -> Unit {
  if !self.closing {
    self.shut(@ui.current())
  }
}

///|
/// What viewer `vw` shows asked to be saved from a node of the window's tree (its 下载), at that moment.
fn Viewer::save_tree(self : Viewer) -> Unit {
  self.ask_save(@ui.current())
}

///|
/// A film's flight as node `node` draws it at `t` (from the thumbnail where the chat lays it out, Viewer::flight_from, to
/// where its player draws its picture, or back from where it was: Viewer::fly_to) and how far it has come: None where
/// it flies not (or waits for the frame it shows to be grabbed as it closes: its player's picture where it was). That
/// frame grabbed and its picture not decoded yet (leaving_pic), it stands where the player draws its picture, under the
/// player, its picture asked for there, setting out once it can be drawn (image_ends).
fn Viewer::player_flight(self : Viewer, src : Source, node : @view.View, t : Double) -> (FlightBox, Double)? {
  let vw = self
  vw.fly.said()
  vw.grab_told.get() |> ignore
  let stands = vw.closing && vw.leaving_pic != ""
  if !stands && (!vw.flies || (vw.closing && vw.leaving_grab)) {
    return None
  }
  let (w, h) = node.window()
  let width = player_width(w)
  let to = match vw.fly_to {
    Some(r) if vw.fly_back => Some(r)
    _ => vw.video_target(src, width, h, t)
  }
  match (vw.flight_from(@ui.current()), to) {
    (Some(from), Some(to)) => {
      let (lifted, p) = if stands { (1.0, 1.0) } else { (vw.lifted_at(t), vw.flying_at(t)) }
      flight_box(from, lifted, to, p, width, h).map(fn(f) { (f, p) })
    }
    _ => None
  }
}

///|
/// How wide a film's player is laid out in a window `w` wide: all of it where it fills the window beside the system's
/// bars (@sf.player_fills_native), else clear of their column (@sf.native_clear), as the old frame's preview layer laid
/// it out.
fn player_width(w : Double) -> Double {
  @sf.player_stage_w(w)
}

///|
/// What is told of a file shown no other way (FilePreview.tsx fpNote, toldOf: a card with its extension, its name, its
/// size and kind, why it is told of; how far the core downloads it and its 取消, why that failed, why its read failed;
/// an APK's 安装 first, then 下载, the one read for saying how far it has come), in `f`, each in the stage's middle.
fn viewer_facts_node(f : @view.View, src : Source, vw : Viewer) -> Unit {
  f.lines_up(Is(Some(Middle))).gap(Is(@ui.Space::px(S5))) |> ignore
  let p = fn() { @sf.theme().p }
  let words = fn(parent : @view.View, said : () -> String, size : () -> Double, weight : Int, ink : () -> Int64) {
    parent.box(fn(w) {
      w
      .max_width(Is(Some(@ui.Space::px(S96))))
      .words(By(said))
      .words_centered(Is(true))
      .words_look(By(fn() {
        let s = size()
        { size: s, weight, line: @ui.tree_theme().text_line * s, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
      }))
      .ink(By(ink))
      |> ignore
    })
    |> ignore
  }
  // (a card standing for the file, its extension in its middle in the accent's ink; a long one or none, the file's mark)
  let ext = @sf.file_ext(vw.file.name)
  let ext_shown = ext != "" && ext.length() <= 5
  let (card_w, card_h, card_corner) = @sf.viewer_facts_card
  f.box(fn(card) {
    card
    .width(Is(Some(card_w)))
    .height(Is(Some(card_h)))
    .lines_up(Is(Some(Middle)))
    .radius(Is(card_corner))
    .ground(By(fn() { p().raised }))
    .edge(By(fn() { (1.0, p().line_strong) }))
    |> ignore
    // (its middle: what it holds as high as its words, the room above it half of what is left)
    card.box(fn(gap) { gap.grow(Is(1.0)) |> ignore }) |> ignore
    if ext_shown {
      card.box(fn(w) {
        w
        .words(Is(ext))
        .words_look(By(fn() {
          let s = @sf.theme().t.ui
          { size: s, weight: 700, line: s, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
        }))
        .ink(By(fn() { p().accent_text }))
        |> ignore
      })
      |> ignore
    } else {
      @sf.icon_node(card, "file", @sf.viewer_facts_icon / 1.5, By(fn() { p().muted })) |> ignore
    }
    card.box(fn(gap) { gap.grow(Is(1.0)) |> ignore }) |> ignore
  })
  |> ignore
  // (its name and its size, together)
  f.box(fn(g) {
    g.lines_up(Is(Some(Middle))).gap(Is(@ui.Space::px(S1))) |> ignore
    words(g, fn() { vw.file.name }, fn() { @sf.theme().t.title }, 600, fn() { p().text })
    // (its kind once: on its card where that says it)
    words(g, fn() { if ext_shown { @sf.file_size(vw.file.size) } else { @sf.facts_size(vw.file.name, vw.file.size) } }, fn() {
      @sf.theme().t.meta
    }, 400, fn() { p().muted })
  })
  |> ignore
  words(
    f,
    fn() {
      if vw.shown_kind() is None {
        @sf.t("web-main.preview.unsupported")
      } else {
        pv("android-chat.file.tooBigToShow")
      }
    },
    fn() { @sf.theme().t.meta },
    400,
    fn() { p().muted },
  )
  let dl = fn() { vw.download(src) }
  // (asked for, read first: how much has come of it)
  // (as it is asked for: 下载 on it, Viewer::ask_save's asked_told)
  let reading = fn() { vw.asked_now() && vw.bytes.get() is None && vw.error.get() is None }
  // downloaded by the core: how far it has come (on by itself as this closes; called off here)
  f.show(fn() { !reading() && downloading(dl()) }, fn(r) {
    r.lines_up(Is(Some(Middle))).gap(Is(14.0)) |> ignore
    file_progress_node(r, fn() { (number(dl(), "loaded"), Some(number(dl(), "size"))) }, fn() { vw.file.size }, said=fn() {
      Some(text(dl(), "statusText"))
    })
    |> ignore
    @sf.button_node(r, fn() { @sf.t("web-main.file.cancelDownload") }, fn() {
      vw.cancel_download(src, @signals.untracked(dl))
    }, tone=Ghost)
    |> ignore
  })
  f.show(fn() { !downloading(dl()) }, fn(r) {
    r.lines_up(Is(Some(Middle))).gap(Is(@ui.Space::px(S2))).width(Is(Some(@sf.viewer_facts_actions))) |> ignore
    // (why the core's download failed; why its read failed)
    let failed = fn(said : () -> String?) {
      r.show(fn() { said() is Some(_) }, fn(e) {
        words(e, fn() { said().unwrap_or("") }, fn() { @sf.theme().t.ui }, 400, fn() { p().red })
      })
    }
    failed(fn() { if text(dl(), "state") == "failed" { Some(text(dl(), "statusText")) } else { None } })
    failed(fn() { vw.error.get().map(fn(e) { @sf.t("web-main.preview.loadFailed", args=[("error", e)]) }) })
    // an APK: 安装 first, handed to the system's installer (strong); 下载 then the quieter. As it is read for one, that
    // one at work, saying how much has come in its words; the other not pressed meanwhile
    let apk = @sf.lower(vw.file.name).has_suffix(".apk")
    // (what it is read for: 0 下载, 1 安装, 2 分享)
    let reading_for = fn(k : Int) {
      reading() &&
      (if vw.install_after {
        1
      } else if vw.share_after {
        2
      } else {
        0
      }) ==
      k
    }
    let label = fn(k : Int, rest : String) {
      if !reading_for(k) {
        return rest
      }
      let reading_words = @sf.t("web-main.preview.loadingLabel")
      let total = match vw.got.get() {
        Some((_, Some(n))) if n > 0.0 => Some(n)
        _ => if vw.file.size > 0.0 { Some(vw.file.size) } else { None }
      }
      match (vw.got.get(), total) {
        (Some((loaded, _)), Some(n)) => reading_words + " " + (dmin(1.0, loaded / n) * 100.0).floor().to_int().to_string() + "%"
        _ => reading_words
      }
    }
    if apk {
      @sf.button_node(r, fn() { label(1, pv("android-chat.file.install")) }, fn() { vw.ask_install() }, tone=Primary, busy=fn() {
        reading_for(1)
      }, disabled=fn() { reading() && !reading_for(1) }, across=true)
      |> ignore
    }
    @sf.button_node(r, fn() { label(0, @sf.t("web-main.preview.download")) }, fn() { vw.save_tree() }, tone=if apk {
      Ghost
    } else {
      Primary
    }, icon="download", busy=fn() { reading_for(0) }, disabled=fn() { reading() && !reading_for(0) }, across=true)
    |> ignore
    // 分享 on a phone (shares_out), the quieter: read whole, then the system's share sheet
    if shares_out() {
      @sf.button_node(r, fn() { label(2, @sf.t("android-misc.drive.share")) }, fn() { vw.ask_share() }, tone=Ghost, icon="share", busy=fn() {
        reading_for(2)
      }, disabled=fn() { reading() && !reading_for(2) }, across=true)
      |> ignore
    }
  })
}

///|
/// What shows while it comes (WaitLine): how much has come out of its size once
/// the core has said, else 正在打开 by a spinner, after a moment (wait_line's).
fn viewer_coming_node(f : @view.View, vw : Viewer) -> Unit {
  f.show(fn() { vw.got.get() is Some(_) }, fn(r) {
    file_progress_node(r, fn() { vw.got.get().unwrap_or((0.0, None)) }, fn() { vw.file.size }) |> ignore
  })
  f.show(fn() { vw.got.get() is None }, fn(r) { @sf.wait_line_node(r, fn() { @sf.t("common.opening") }) |> ignore })
}

///|
/// How far in it is at `t`: its flight's share (a picture too big to show from its thumbnail flies none of it, its
/// ground coming as it would), times its fade.
fn Viewer::in_at(self : Viewer, t : Double) -> Double {
  self.flight_share_at(t) * self.fade.value_at(t)
}

///|
/// Its way in and out, what draws it `p` in (Viewer::in_at): a picture of its own, its ground as far as it is in
/// (its picture the flight's own); anything else, words of its own over the page under it, a panel's (@motion's
/// `ground_first`): its ground whole by halfway, its words after it coming in and before it going out, so that no frame
/// shows its words over the page's, both seen (words_over.mbt).
fn Viewer::way_at(self : Viewer, p : Double) -> (Double, Double) {
  // (a film flown by the window's tree too: its picture the flight's own, its ground as far as it has grown)
  if self.markable() || (self.played() && (self.flies || self.tree_way.get())) {
    (p, p)
  } else {
    let look = @motion.trans(fade=0.0, ground_first=true).at(p, 1.0)
    (look.alpha, look.alpha * look.words)
  }
}

///|
/// How far in its ground is, `p` in (Viewer::way_at).
fn Viewer::ground_share(self : Viewer, p : Double) -> Double {
  self.way_at(p).0
}

///|
/// How far in what its stage shows is, `p` in (Viewer::way_at).
fn Viewer::words_share(self : Viewer, p : Double) -> Double {
  self.way_at(p).1
}

///|
/// Whether it was asked for (Viewer::ask_save, ask_install: `asked`), as it is told (asked_told): what reads it follows
/// it.
fn Viewer::asked_now(self : Viewer) -> Bool {
  self.asked_told.get() |> ignore
  self.asked
}

///|
/// The picture of viewer `vw` flying in or back, its nodes in `parent` (`origin` where `parent` is drawn in the window):
/// from the thumbnail as the chat lays it out in the frame drawn (Viewer::flight_from) to where its zoom has it (on
/// `stage`), as far as its flight has come then (flight_box): what shows of it on the window, the box it is cut to, its
/// corners round, the picture in it, as Viewer::picture_shown has it, its whole picture judged ready for where it lands
/// (View::image_for: as what draws the picture judged it, Viewer::shown_picture), which of them decided as it is
/// drawn; drawn at the moments `mine` says (its own layer's, or the slot of the page it flies from: viewer_flight_slot).
fn image_flight(
  parent : @view.View,
  src : Source,
  vw : Viewer,
  stage : () -> (Double, Double),
  mine : (Double) -> Bool,
  origin? : () -> (Double, Double) = fn() { (0.0, 0.0) },
) -> Unit {
  let flight = fn(n : @view.View) -> (FlightBox, (Double, Double, Double, Double))? {
    let t = viewer_flight_at(vw, n)
    vw.bytes.get() |> ignore
    if !vw.flight_node() || !mine(t) {
      return None
    }
    let (w, h) = stage()
    match (vw.flight_from(@ui.current()), vw.marks_rect_on(n)) {
      (Some(from), Some(to)) =>
        flight_box(from, vw.lifted_at(t), to, vw.flying_at(t), w, h).map(fn(f) { (f, to) })
      _ => None
    }
  }
  parent.box(fn(cut) {
    cut
    .over(Is(true))
    .clips(Is(true))
    .offset(By(fn() {
      match flight(cut) {
        Some((f, _)) => {
          let (x, y) = origin()
          (f.cut.0 - x, f.cut.1 - y)
        }
        None => (0.0, 0.0)
      }
    }))
    .width(By(fn() { flight(cut).map(fn(f) { f.0.cut.2 }) }))
    .height(By(fn() { flight(cut).map(fn(f) { f.0.cut.3 }) }))
    |> ignore
    cut.box(fn(b) {
      b
      .over(Is(true))
      .clips(Is(true))
      .corners(By(fn() { flight(b).map(fn(f) { f.0.corners }) }))
      .offset(By(fn() {
        match flight(b) {
          Some((f, _)) => (f.box.0 - f.cut.0, f.box.1 - f.cut.1)
          None => (0.0, 0.0)
        }
      }))
      .width(By(fn() { flight(b).map(fn(f) { f.0.box.2 }) }))
      .height(By(fn() { flight(b).map(fn(f) { f.0.box.3 }) }))
      |> ignore
      b.box(fn(p) {
        p
        .over(Is(true))
        .offset(By(fn() {
          match flight(p) {
            Some((f, _)) => (f.picture.0 - f.box.0, f.picture.1 - f.box.1)
            None => (0.0, 0.0)
          }
        }))
        .width(By(fn() { flight(p).map(fn(f) { f.0.picture.2 }) }))
        .height(By(fn() { flight(p).map(fn(f) { f.0.picture.3 }) }))
        .image(By(fn() {
          match flight(p) {
            Some(_) => vw.picture_shown(src)
            None => None
          }
        }))
        .image_for(By(fn() {
          match (flight(p), vw.picture(src)) {
            (Some((_, (_, _, w, h))), picture) if picture != "" && picture == vw.image => (w, h)
            _ => (0.0, 0.0)
          }
        }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The moment what draws viewer `vw`'s picture reads the strip and the flight at, in `n`: as each frame draws it while
/// either goes; where neither goes, past both their ends (where each went: View::drawn_while), the clock read no more.
fn viewer_flight_at(vw : Viewer, n : @view.View) -> Double {
  vw.fly.said()
  pv_strip.way.said()
  n.drawn_while(fn(at) { pv_strip.way.goes_at(at) || vw.fly.goes_at(at) })
}

///|
/// The viewer whose picture flies from a page's list (viewer_flight_slot), one told from another by the thumbnail it
/// flies from.
priv struct FlyingFrom {
  from : Viewer?
}

///|
impl Eq for FlyingFrom with equal(a, b) {
  a.from.map(fn(v) { v.thumb_id() }) == b.from.map(fn(v) { v.thumb_id() })
}

///|
/// What of a picture flying from page `serial`'s chat list is drawn in that page, in its node `slot` (between what the
/// page shows and its bar: chat_page_made's): the viewer's while it flies from there (Viewer::flies_from_page), its
/// picture drawn here while it is not out from under the bar (Viewer::lifted_at short of 1), the bar over it as over
/// the list; in its own layer from then, and once nothing flies from here. `stage` its room; `slot` in the page where
/// the page is drawn in the window (what moves the page moves this with it).
pub fn viewer_flight_slot(slot : @view.View, src : Source, serial : Int, stage : () -> (Double, Double)) -> Unit {
  slot.over(Is(true)).presses(Is(false)) |> ignore
  let origin = fn() {
    let (x, y, _, _) = slot.rect()
    (x, y)
  }
  // (the viewer flying from here: the one open, or one going back into it)
  let flying = fn() -> Viewer? {
    for v in [viewer.get(), pv_leaving.get()] {
      match v {
        Some(vw) => {
          vw.fly.said()
          if vw.flies && vw.flies_from_page() == serial {
            return Some(vw)
          }
        }
        None => ()
      }
    }
    None
  }
  // (made again as another flies from here, given the one that does; at once: the flight draws its own way, and the
  // slot let go of as it lands would otherwise set out on one with nothing to show)
  slot.pick(at_once=true, fn() { { from: flying() } }, fn(f, which) {
    guard which.from is Some(vw) else { return }
    f.over(Is(true)).presses(Is(false)) |> ignore
    if vw.played() {
      film_flight(f, src, vw, fn(t) { vw.lifted_at(t) < 1.0 }, origin~)
    } else {
      image_flight(f, src, vw, stage, fn(t) { vw.lifted_at(t) < 1.0 }, origin~)
    }
  })
}

///|
/// Which way a picture's strip drawn `dx` across (a picture `bw` wide), let go going `vx` (points a ms), steps: on to the
/// one beside it (-1 the one before, 1 the one after) landing far enough on from that speed (@ui.lands_past) or flung
/// that way from its edge, else none (back).
fn strip_step(dx : Double, vx : Double, bw : Double, from_edge : Bool) -> Int {
  let far_at = dmin(80.0, bw / 5.0)
  let far = @ui.lands_past(dx, vx, if dx > 0.0 { far_at } else { -far_at })
  let flung = from_edge && vx.abs() > 0.3 && (vx > 0.0) == (dx > 0.0) && dx.abs() > 10.0
  if dx != 0.0 && (far || flung) {
    if dx > 0.0 {
      -1
    } else {
      1
    }
  } else {
    0
  }
}

///|
/// How much of a viewer's ground a picture taken down lets the page show through, by how far down it is (of the
/// stage's height, Zoom::pulled_at), and the most it lets through.
let pull_ground_rate : Double = 2.5

///|
let pull_ground_most : Double = 0.9
