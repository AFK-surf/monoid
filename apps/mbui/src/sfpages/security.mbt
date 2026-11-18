// 安全, one page in every frame (web/src/cloud/Security.tsx SecuritySettings, Off, On, StationRow, DeviceRow,
// SecurityOpen; the narrow app's mobile/Security.tsx), laid out by its width: what the lock is; off, a
// card of what it is now and once on, and the way to turn it on; on, a card of how many sign and what it protects, this
// device's own pairing where it waits, the devices waiting to be confirmed, its people and their devices, its stations,
// what a web page may do, and turning it off. All of it the core's (`lock`, `lockDraft`, their words included);
// confirming a device, taking a station in and turning it off asked first (the presenters). Turning it on is a page of
// its own (SecurityOpen).

///|
/// 安全 (SecuritySettings, SecurityScreen), made once in node `v` as wide as `width` gives it, in the frame it is given:
/// the workspace's lock as the core's `lock` says it (the person's own lock is no row of its own: to people there is one
/// safe mode, the user, 2026-11-10), each part of it a block of its own come and gone as that changes (read the first time: the page as it is
/// while the lock is off, in its bones). `stint`: the page's time on top, what a station's picture is asked for on.
pub fn security_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  stint? : () -> Int = fn() { 0 },
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let ws = fn() { here().workspace }
  let topic = fn() { (core.topic)("lock", { "workspace": str(ws()) }).get() }
  let lock = fn() { topic().value }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.security.title") },
    on_back~,
    frame~,
    said?,
    width?,
    // (on: how many sign and what it protects, as the workspace page's lead says who and how many; else what it is)
    lead=fn() {
      let l = lock()
      if flag(l, "available") && flag(l, "locked") {
        @sf.t("web-pages.security.onMeta", args=[
          ("signers", count(l, "signers").to_string()),
          ("stations", count(l, "protected").to_string()),
        ])
      } else {
        @sf.t("web-pages.security.lead")
      }
    },
    fn() {
      let out : Array[String] = []
      let l = lock()
      match l {
        None => out.push("waiting")
        Some(_) if !flag(l, "available") => out.push("unavailable")
        Some(_) if flag(l, "locked") => {
          let me = field(l, "me")
          out.push("on")
          // not confirmed yet, or in the lock without signing (let in before it kept a key): asked for here too; let in
          // by its person's own lock that does not say its signer, verified once in its place (`confirmText`); a web
          // page nobody can approve here says so in its place (`needsAppText`); made its person's only trusted device
          // while the workspace binds the lock of before, whom to ask, nothing to press (`reboundText`); its person's
          // own lock begun anew elsewhere, what happened and 是我做的，继续 (`forgetText`)
          if text(me, "reboundText") != "" {
            out.push("rebound")
          } else if text(me, "forgetText") != "" {
            out.push("replaced")
          } else if flag(me, "waiting") || flag(me, "unsigned") {
            out.push("pair")
          } else if text(me, "confirmText") != "" {
            out.push("confirm-signer")
          } else if text(me, "needsAppText") != "" {
            out.push("needs-app")
          }
          // (what the upgrade of safe mode waits for, on the owner's device that is to finish it: first after the state,
          // where one looking for 安全模式 looks first)
          upgrade_keys(l, out)
          // (what was just done and is not in effect: after the state and the upgrade)
          pending_keys(l, out)
          people_keys(l, out)
          out.push("stations")
          // (an upgraded workspace turned off by one person alone: to another owner, who and the way out in its place)
          if text(l, "rootText") != "" {
            out.push("root-only")
          } else if flag(l, "owner") && flag(l, "signs") {
            out.push("turn-off")
          }
        }
        Some(_) => {
          out.push("off")
          pending_keys(l, out)
          out.push("signing")
        }
      }
      out
    },
    fn(b, key) {
      match key {
        "waiting" =>
          // (read the first time: the page as it is while the lock is off, the commonest, in its bones)
          @sf.waiting_node(
            b,
            fn(s) {
              lock_off_node(s, core.quiet(), ws, fn() { Some({ "available": true }) })
              signing_node(s)
            },
            error=fn() {
              match topic().error {
                Some(e) => error_text(e)
                None => ""
              }
            },
          )
        "unavailable" =>
          @sf.page_card_node(b, fn(k) {
            @sf.words_node(k, fn() { @sf.t("web-pages.security.unavailable") }, fn() { sec_said }) |> ignore
          })
        "off" => lock_off_node(b, core, ws, lock)
        "signing" => signing_node(b)
        "on" => lock_on_node(b, lock)
        "pair" => pair_node(b, core, ws, lock)
        "confirm-signer" => confirm_signer_node(b, core, ws, lock)
        "needs-app" => needs_app_node(b, lock)
        "rebound" => rebound_node(b, lock)
        "replaced" => replaced_node(b, core, ws, lock)
        "upgrade" => @sf.section_heading_node(b, fn() { text(field(lock(), "upgrade"), "titleText") })
        k if k.has_prefix(upgrade_key) =>
          upgrade_line_node(b, core, lock, @string.parse_int(k[upgrade_key.length():]) catch { _ => 0 })
        "pending" => @sf.section_heading_node(b, fn() { text(lock(), "pendingText") })
        k if k.has_prefix(pending_key) => pending_node(b, core, ws, lock, k.unsafe_substring(start=pending_key.length(), end=k.length()))
        // (what a web page may do, its people's devices' note: under its heading, as the workspace page's people say
        // how many they are)
        "people" =>
          @sf.section_heading_node(b, fn() { @sf.t("web-pages.security.people") }, note=fn() { @sf.t("web-pages.security.webRisk") })
        k if k.has_prefix(member_key) => member_node(b, core, ws, lock, k[member_key.length():].to_owned(), stint)
        "stations" => stations_node(b, core, ws, lock, stint)
        "turn-off" => turn_off_node(b, core, ws, here)
        "root-only" => @sf.page_note_node(b, fn() { text(lock(), "rootText") })
        _ => ()
      }
    },
  )
}

///|
/// Off (Off): the lock's state, what it is now and once on and how new devices come in, a line each with its mark; the
/// way to turn it on (where this device signs), or who may: an upgraded workspace turned off by one person alone, to
/// another owner who and the way out (`rootText`), to that person the button that turns it on again as it was
/// (`onAgainText`: `lock.open`, with nothing to choose, so no page of its own), at the card's foot, concentric with it.
fn lock_off_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?) -> Unit {
  sec_lead_node(parent, fn(k) {
    sec_state_node(k, false, fn() { @sf.t("web-pages.security.off") })
    k.box(fn(p) {
      @sf.style_node(p, fn() { sec_points })
      sec_point_node(p, "server", fn() { @sf.t("web-pages.security.now") }, fn() { @sf.t("web-pages.security.nowRisk") })
      sec_point_node(p, "key", fn() { @sf.t("web-pages.security.then") }, fn() { @sf.t("web-pages.security.thenSafe") })
      sec_point_node(p, "devices", fn() { @sf.t("web-pages.security.newDevices") }, fn() {
        @sf.t("web-pages.security.newDevicesHow")
      })
    })
    |> ignore
    k.pick(
      fn() {
        if !flag(lock(), "owner") {
          0
        } else if text(lock(), "rootText") != "" {
          3
        } else if !flag(lock(), "canSign") {
          2
        } else if text(lock(), "onAgainText") != "" {
          4
        } else {
          1
        }
      },
      fn(q, which) {
        match which {
          0 => @sf.words_node(q, fn() { @sf.t("web-pages.security.ownerOnly") }, fn() { sec_note }) |> ignore
          1 =>
            q.box(fn(a) {
              @sf.style_node(a, fn() { sec_actions })
              a.wraps(Is(Some(sec_actions_gap))) |> ignore
              @sf.button_node(a, fn() { @sf.t("web-pages.security.turnOn") }, fn() { (core.push)(SecurityOpen) }, tone=Primary)
              |> ignore
              @sf.words_node(a, fn() { @sf.t("web-pages.security.signsHere") }, fn() { sec_note_line }) |> ignore
            })
            |> ignore
          3 => @sf.words_node(q, fn() { text(lock(), "rootText") }, fn() { sec_note }) |> ignore
          4 => {
            let label = fn() { text(lock(), "onAgainText") }
            q.box(fn(a) {
              // (last on the card, reaching into its foot corner, concentric with it)
              @sf.style_node(a, fn() { sec_actions.then(@sf.foot_reach(@sf.button_height())) })
              @sf.button_node(
                a,
                label,
                fn() {
                  lock_call(core, @signals.untracked(ws), "open", @signals.untracked(label), [], done=@sf.t("web-pages.security.turnedOn"))
                },
                tone=Primary,
                busy=fn() { is_doing(core, ["lock.open"], [("workspace", ws())]) },
                card_words=true,
              )
              |> ignore
            })
            |> ignore
          }
          _ => @sf.words_node(q, fn() { @sf.t("web-pages.security.webCannotSign") }, fn() { sec_note }) |> ignore
        }
      },
    )
  })
}

///|
/// 签名: who signs, under the lock's state while it is off.
fn signing_node(parent : @view.View) -> Unit {
  @sf.section_node(parent, fn() { @sf.t("web-pages.security.signing") }, fn(s) {
    @sf.page_card_node(s, fn(k) {
      @sf.words_node(k, fn() { @sf.t("web-pages.security.signingWho") }, fn() { sec_said }) |> ignore
    })
  })
}

///|
/// The state's card, first on the page (lead: a card, as far from what follows as a section is): narrow a page's card,
/// wide the web's (sec_lead).
fn sec_lead_node(parent : @view.View, body : (@view.View) -> Unit) -> Unit {
  match @sf.look_node(parent) {
    Narrow => @sf.page_card_node(parent, body)
    Wide =>
      parent.box(fn(k) {
        @sf.style_node(k, fn() { sec_lead })
        body(k)
      })
      |> ignore
  }
}

///|
/// The lock's state on its line: its dot (green while `on`, else amber), what it is.
fn sec_state_node(parent : @view.View, on : Bool, words : () -> String) -> Unit {
  parent.box(fn(l) {
    @sf.style_node(l, fn() { sec_state_line })
    sec_dot_node(l, fn() { on })
    @sf.words_node(l, words, fn() { sec_state }) |> ignore
  })
  |> ignore
}

///|
/// A dot (dot: 7 round, the online green; amber where not `on`).
fn sec_dot_node(parent : @view.View, on : () -> Bool) -> Unit {
  parent.box(fn(d) { @sf.style_node(d, fn() { if on() { sec_dot_on } else { sec_dot_amber } }) }) |> ignore
}

///|
/// What it changes, a line (point): its mark 18 muted, its words and the rest quieter under them.
fn sec_point_node(parent : @view.View, icon : String, words : () -> String, rest : () -> String) -> Unit {
  parent.box(fn(l) {
    @sf.style_node(l, fn() { sec_point_line })
    l.box(fn(i) {
      @sf.style_node(i, fn() { sec_point_icon }, in_row=true)
      @sf.icon_node(i, icon, sec_point_glyph, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
    l.box(fn(w) {
      @sf.style_node(w, fn() { sec_point_words }, in_row=true)
      @sf.words_node(w, words, fn() { sec_point_text }) |> ignore
      @sf.words_node(w, rest, fn() { sec_point_rest }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// On (On): its state, a row on a card of its own (the online dot before it, what that means under it); how many sign
/// and what it protects is the page's lead. Where this device does not sign, why, under that in the same row.
fn lock_on_node(parent : @view.View, lock : () -> Json?) -> Unit {
  let me = fn() { field(lock(), "me") }
  // (nor where it is to be verified once: its own card says why, confirm_signer_node)
  let unsigned = fn() {
    !flag(lock(), "signs") && !flag(me(), "waiting") && !flag(me(), "unsigned") && text(me(), "confirmText") == ""
  }
  @sf.group_node(parent, fn(g) {
    @sf.link_row_node(
      g,
      fn() { @sf.t("web-pages.security.on") },
      fn() {  },
      note=fn() { @sf.t("web-pages.security.onLead") },
      lead=LeadLine(fn(l) { @sf.state_dot_node(l, fn() { "online" }) }),
      below=fn(b) {
        @sf.words_node(
          b,
          fn() {
            @sf.t(if flag(lock(), "canSign") { "web-pages.security.notSignerApp" } else { "web-pages.security.notSignerWeb" })
          },
          fn() { @sf.pg_link_note },
        )
        |> ignore
      },
      below_open=fn() { if unsigned() { 1.0 } else { 0.0 } },
      goes=false,
      chevron=false,
    )
  })
}

///|
/// This device's own pairing, where it waits or was let in without signing: what is so, then the steps (the waiting
/// page's: lock_wait_node's pair_steps_node), last on the card, in its foot corner.
fn pair_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?) -> Unit {
  sec_lead_node(parent, fn(k) {
    @sf.words_node(
      k,
      fn() {
        @sf.t(
          if flag(field(lock(), "me"), "unsigned") {
            "web-pages.security.upgradeTitle"
          } else {
            "web-pages.security.waitingTitle"
          },
        )
      },
      fn() { sec_state_lines },
    )
    |> ignore
    // (its person taken out of an upgraded workspace: by whom and when, and whom to ask, the core's `me.outText`; asked
    // again once added back)
    k.show(fn() { text(field(lock(), "me"), "outText") != "" }, fn(o) {
      @sf.words_node(o, fn() { text(field(lock(), "me"), "outText") }, fn() { sec_said }) |> ignore
    })
    // (last on the card, its action reaching into the card's foot corner, concentric with it)
    pair_steps_node(k, core, ws, in_card=true)
  })
}

///|
/// Let in by its person's own lock that does not say this device's signer (the core's `me.confirmText`): 将此设备设为
/// 受信任设备, why in the core's words (`me.stateText`), and 验证 (`lock.confirmSigner`, the person asked once) last on
/// the card, in its foot corner, concentric with it, a ring on it while that goes; no approval (none would help).
fn confirm_signer_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?) -> Unit {
  let me = fn() { field(lock(), "me") }
  let label = fn() { text(me(), "confirmText") }
  sec_lead_node(parent, fn(k) {
    @sf.words_node(k, fn() { @sf.t("web-pages.security.upgradeTitle") }, fn() { sec_state_lines }) |> ignore
    k.box(fn(v) {
      lock_steps_node(v, true)
      lock_note_node(v, fn() { text(me(), "stateText") }, in_card=true)
      v.box(fn(a) {
        @sf.style_node(a, fn() { lock_actions.then(@sf.foot_reach(@sf.button_height())) })
        @sf.button_node(
          a,
          label,
          fn() { lock_call(core, @signals.untracked(ws), "confirmSigner", @signals.untracked(label), []) },
          tone=Primary,
          busy=fn() { is_doing(core, ["lock.confirmSigner"], [("workspace", ws())]) },
          card_words=true,
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A web page left out that nobody can approve here (the core's `me.needsAppText`): in the pair's place, 请先安装客户端
/// and the core's words, with no button that asks (nobody could answer it).
fn needs_app_node(parent : @view.View, lock : () -> Json?) -> Unit {
  sec_lead_node(parent, fn(k) {
    @sf.words_node(k, fn() { @sf.t("web-pages.security.needsAppTitle") }, fn() { sec_state_lines }) |> ignore
    @sf.words_node(k, fn() { text(field(lock(), "me"), "needsAppText") }, fn() { sec_said }) |> ignore
  })
}

///|
/// Made its person's only trusted device (`lock.restartOwn`) while the workspace binds the lock of before (the core's
/// `me.reboundText`): in the pair's place, 等待批准 and whom to ask to take them out and add them again, with no button
/// (no approval lets it in till then).
fn rebound_node(parent : @view.View, lock : () -> Json?) -> Unit {
  sec_lead_node(parent, fn(k) {
    @sf.words_node(k, fn() { @sf.t("web-pages.security.waitingTitle") }, fn() { sec_state_lines }) |> ignore
    @sf.words_node(k, fn() { text(field(lock(), "me"), "reboundText") }, fn() { sec_said }) |> ignore
  })
}

///|
/// Its person's own lock begun anew on another device (the core's `me.forgetText`): in the pair's place, what happened
/// (`replacedTitleText`), what that means (`replacedNoteText`), and 是我做的，继续 (`lock.forgetOwn`) last on the card,
/// in its foot corner, concentric with it, a ring on it while that goes; after it, the pair's steps ask to join.
fn replaced_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?) -> Unit {
  let me = fn() { field(lock(), "me") }
  let label = fn() { text(me(), "forgetText") }
  sec_lead_node(parent, fn(k) {
    @sf.words_node(k, fn() { text(me(), "replacedTitleText") }, fn() { sec_state_lines }) |> ignore
    k.box(fn(v) {
      lock_steps_node(v, true)
      lock_note_node(v, fn() { text(me(), "replacedNoteText") }, in_card=true)
      v.box(fn(a) {
        @sf.style_node(a, fn() { lock_actions.then(@sf.foot_reach(@sf.button_height())) })
        @sf.button_node(
          a,
          label,
          fn() { lock_call(core, @signals.untracked(ws), "forgetOwn", @signals.untracked(label), []) },
          tone=Primary,
          busy=fn() { is_doing(core, ["lock.forgetOwn"], [("workspace", ws())]) },
          card_words=true,
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// 安全模式有一项升级尚未完成 (the core's `upgrade`, on the owner's device that is to finish it), as the page's list's
/// blocks (`out`, after what is there): its title a heading, then each line it waits for a block of its own by where it
/// stands (the core's lines have no ids: six at most and how many more), a row a piece of the section's card; none while
/// there is none. (It finishes by itself, asking nobody: client/core-ts AGENTS.md, so no button of the person's ask.)
fn upgrade_keys(l : Json?, out : Array[String]) -> Unit {
  let u = field(l, "upgrade")
  guard u is Some(Object(_)) else { return }
  out.push("upgrade")
  for i, _ in items(u, "lines") {
    out.push(upgrade_key + i.to_string())
  }
}

///|
/// An upgrade's line's block's key: this, then where it stands among the lines.
let upgrade_key : String = "upgrade/"

///|
/// How many pieces the upgrade's card is made of: its lines.
fn upgrade_pieces(u : Json?) -> Int {
  items(u, "lines").length()
}

///|
/// The upgrade's line `i` as `lock` says it now, a piece of the section's card (which by where it stands among the card's
/// pieces now), as a change not in effect is (pending_node).
fn upgrade_line_node(parent : @view.View, core : Core, lock : () -> Json?, i : Int) -> Unit {
  // (where it stands and what it says, as the core says them; gone, as they last were, while its block makes its way
  // out)
  let last : Ref[(@sf.CardPiece, Json?)] = Ref((@sf.CardPiece::CardWhole, None))
  let now = fn() {
    let u = field(lock(), "upgrade")
    let lines = items(u, "lines")
    if i < lines.length() {
      last.val = (@sf.card_piece_of(i, upgrade_pieces(u)), Some(lines[i]))
    }
    last.val
  }
  parent.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(parent, fn() { now().0 }, wide_card=true, wide_gap=sec_rows_gap, fn(k) {
    sec_upgrade_line_node(k, core, fn() { now().1 })
  })
}

///|
/// What the upgrade waits for, `lv` as it is now: the waiting mark, its sentence whole on as many lines as it takes;
/// a station's, under it, 更新 where the core says this person may update it from here (as the station's own page offers
/// its update: `software.update` of its own software, `upgrade_update`), a ring while that is asked, and, once its
/// update is under way, how much of it is in as its own page draws it (station_node's `software_end_node`).
fn sec_upgrade_line_node(parent : @view.View, core : Core, lv : () -> Json?) -> Unit {
  let station = fn() { text(lv(), "station") }
  let sending : @signals.Signal[Bool] = @signals.signal(false)
  let updating = fn() { flag(lv(), "updating") }
  let busy = fn() {
    sending.get() || updating() || is_doing(core, ["software.update"], [("station", station()), ("id", "station")])
  }
  let percent = fn() -> Double? {
    match field(lv(), "percent") {
      Some(Number(p, ..)) => Some(p / 100.0)
      _ => None
    }
  }
  sec_line_node(
    parent,
    fn() { text(lv(), "text") },
    wraps=true,
    mark=fn(m) {
      m.box(fn(b) {
        @sf.style_node(b, fn() { sec_pending_mark }, in_row=true)
        @sf.icon_node(b, "wait", sec_device_glyph, By(fn() { @sf.theme().p.muted })) |> ignore
      })
      |> ignore
    },
    // (its update under way with how much of it is in: the bar its own page draws; else 更新, a ring while it is asked)
    acts=fn(a) {
      a.pick(fn() { updating() && percent() is Some(_) }, fn(p, drawn) {
        if drawn {
          p.box(fn(bar) {
            bar.width(Is(Some(sw_progress_w))) |> ignore
            @sf.progress_node(bar, percent, fn() { @ui.tree_theme().line }, fn() { @sf.theme().p.accent }) |> ignore
          })
          |> ignore
        } else {
          sec_tap_do_node(
            p,
            fn() { @sf.t("web-main.versions.update") },
            fn() { upgrade_update(core, @signals.untracked(station), sending) },
            busy,
          )
        }
      })
    },
    acts_shown=fn() { text(lv(), "of") == "station" && (flag(lv(), "canUpdate") || busy()) },
  )
}

///|
/// 更新 pressed on the upgrade's line of `station`: its own software updated (`software.update`, as the station's own
/// page does), once: nothing more is sent while that is asked (`sending`), nor while the core says it is under way
/// (the line's ring in its place); what went wrong said as any act's is.
fn upgrade_update(core : Core, station : String, sending : @signals.Signal[Bool]) -> Unit {
  if station == "" || @signals.untracked(fn() { sending.get() }) {
    return
  }
  sending.set(true)
  (core.call)("software.update", obj([("station", str(station)), ("id", str("station"))]), fn(r) {
    sending.set(false)
    match r {
      Ok(_) => ()
      Err(e) => {
        @ui.haptic(Reject)
        (core.say)(
          @sf.t("android-misc.act.failed", args=[("what", @sf.t("web-main.stationUpdate.updateAction")), ("error", error_text(e))]),
        )
      }
    }
  })
}

///|
/// 以下改动还没有生效, as the page's list's blocks (`out`, after what is there): its heading, then each change this
/// device made that no station took yet (the core's `pending`, oldest first, of the workspace's lock and the person's
/// own alike) a block of its own by its id, a row a piece of the section's card (a block is a row: apps/mbui/AGENTS.md),
/// so one going leaves the others where they are; none while there are none.
fn pending_keys(l : Json?, out : Array[String]) -> Unit {
  let rows = items(l, "pending")
  if rows.length() > 0 {
    out.push("pending")
    for r in rows {
      out.push(pending_key + text(Some(r), "id"))
    }
  }
}

///|
/// A pending change's block's key: this, then its id.
let pending_key : String = "pending/"

///|
/// The pending change `id` as `lock` says it now, a piece of the section's card (which piece by where it stands among
/// them now: the top, one between, the foot, the whole card), the rows 12 apart wide (sec_rows').
fn pending_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?, id : String) -> Unit {
  // (where it stands and what it says, as the core says them; gone, as they last were, while its block makes its way
  // out)
  let last : Ref[(@sf.CardPiece, Json?)] = Ref((@sf.CardPiece::CardWhole, None))
  let now = fn() {
    let rows = items(lock(), "pending")
    for j, r in rows {
      if text(Some(r), "id") == id {
        last.val = (@sf.card_piece_of(j, rows.length()), Some(r))
      }
    }
    last.val
  }
  // (as tall as its block, its piece of the card in it as tall: card_piece_node)
  parent.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(
    parent,
    fn() { now().0 },
    wide_card=true,
    wide_gap=sec_rows_gap,
    fn(k) {
      sec_pending_node(k, core, ws, fn() { now().1 })
    },
  )
}

///|
/// A change not in effect, `pv` as it is now: its mark (waiting, the time's; failed, the warning's in amber), its
/// sentence whole on as many lines as it takes, why it failed under it where the core says; a failed one's
/// `dismissText` drops it (`lock.pendingDismiss`), on a line of its own under its words. A waiting one does nothing
/// pressed: it is taken by itself as a station takes it.
fn sec_pending_node(parent : @view.View, core : Core, ws : () -> String, pv : () -> Json?) -> Unit {
  let id = fn() { text(pv(), "id") }
  let failed = fn() { text(pv(), "state") == "failed" }
  let dropping = fn() { is_doing(core, ["lock.pendingDismiss"], [("workspace", ws()), ("id", id())]) }
  let mark = fn() { if failed() { "info" } else { "wait" } }
  sec_line_node(
    parent,
    fn() { text(pv(), "text") },
    note=fn() { text(pv(), "why") },
    wraps=true,
    mark=fn(m) {
      m.box(fn(b) {
        @sf.style_node(b, fn() { sec_pending_mark }, in_row=true)
        @sf.icon_node(b, @signals.untracked(mark), sec_device_glyph, By(fn() {
          if failed() {
            @sf.theme().p.warn_ink
          } else {
            @sf.theme().p.muted
          }
        }), name_now=mark)
        |> ignore
      })
      |> ignore
    },
    // (one look at either width: the accent's words, starting where the sentence starts)
    acts=fn(a) {
      sec_tap_do_node(
        a,
        fn() { text(pv(), "dismissText") },
        fn() {
          @settings.act(
            core,
            @signals.untracked(fn() { text(pv(), "dismissText") }),
            "lock.pendingDismiss",
            obj([("workspace", str(@signals.untracked(ws))), ("id", str(@signals.untracked(id)))]),
          )
        },
        dropping,
      )
    },
    acts_shown=fn() { failed() && text(pv(), "dismissText") != "" },
  )
}

///|
/// `a`'s each by where it stands (a list's rows keyed by their place: each made again only as what is there changes).
fn indexed(a : Array[Json]) -> Array[(Int, Json)] {
  a.mapi(fn(i, x) { (i, x) })
}

///|
/// A section's rows together: narrow, on a rounded card (ListCard); wide, on the web's card, 12 apart. A button in the
/// first or last row sits in the card's corner, concentric with it (`top_button`, `bottom_button`, as they say now).
fn sec_group_node(
  parent : @view.View,
  rows : (@view.View) -> Unit,
  top_button? : () -> Bool = fn() { false },
  bottom_button? : () -> Bool = fn() { false },
) -> Unit {
  match @sf.look_node(parent) {
    Narrow => @sf.group_node(parent, rows)
    Wide =>
      parent.box(fn(k) {
        @sf.style_node(k, fn() {
          let inset = @sf.room_of(@sf.card_foot_in(@sf.button_height()))
          let card = @sf.desk_card
          let card = if top_button() { card.then(@ui.style(pt=inset)) } else { card }
          if bottom_button() {
            card.then(@ui.style(pb=inset))
          } else {
            card
          }
        })
        k.box(fn(r) {
          @sf.style_node(r, fn() { sec_rows })
          rows(r)
        })
        |> ignore
      })
      |> ignore
  }
}

///|
/// A row of a section, going nowhere (sec_line's): `mark` before it, its title, `note` under it (narrow) or after it
/// (wide; amber while `warn`), `end` at its end; `acts`, what it does (while `acts_shown` says) where its title is
/// words of no length known (a device's name): at its end wide, narrow a line of its own under its words, the title
/// never squeezed by it. `over`: the name of the rows it starts, over it at its mark while it says one (a person's
/// devices of one app: still.fail 桌面版), `apart` from the rows before it. Its words as they are said. `wraps`: its
/// title a sentence, whole on as many lines as it takes, its note under it and what it does under them at either width
/// (beside it, that took the room the sentence needs), its mark at its first line (a change not in effect).
fn sec_line_node(
  parent : @view.View,
  title : () -> String,
  note? : () -> String = fn() { "" },
  warn? : () -> Bool = fn() { false },
  strong? : Bool = true,
  indent? : Bool = false,
  mark? : (@view.View) -> Unit,
  end? : (@view.View) -> Unit,
  acts? : (@view.View) -> Unit,
  acts_shown? : () -> Bool = fn() { true },
  over? : () -> String = fn() { "" },
  apart? : () -> Bool = fn() { false },
  wraps? : Bool = false,
) -> Unit {
  match @sf.look_node(parent) {
    Narrow => {
      parent.show(fn() { over() != "" }, fn(o) {
        o.box(fn(b) {
          @sf.style_node(b, fn() { sec_narrow_over })
          @sf.words_node(b, over, fn() { sec_narrow_over_words }) |> ignore
        })
        |> ignore
      })
      // (its title and what is at its end on its first line, its note under them as wide as its words: a line of its
      // own)
      let words = fn(w : @view.View) {
        match mark {
          Some(f) => f(w)
          None => ()
        }
        w.box(fn(lines) {
          @sf.style_node(lines, fn() { @sf.pg_row_words }, in_row=true)
          lines.box(fn(first) {
            @sf.style_node(first, fn() { sec_first_line })
            first.box(fn(t) {
              @sf.style_node(t, fn() { sec_title_room }, in_row=true)
              @sf.words_node(t, title, fn() { if wraps { sec_pending_body } else { narrow_row_title } }) |> ignore
            })
            |> ignore
            // (at the row's top: at a card's first row's end in its corner as far from its top as from its side, and
            // clear of its last's foot corner)
            match end {
              Some(f) =>
                first.box(fn(e) {
                  @sf.style_node(e, fn() { sec_end_top }, in_row=true)
                  f(e)
                })
                |> ignore
              None => ()
            }
          })
          |> ignore
          lines.show(fn() { note() != "" }, fn(n) {
            @sf.words_node(n, note, fn() { if warn() { sec_narrow_warn } else { @sf.pg_link_note } }) |> ignore
          })
        })
        |> ignore
      }
      parent.box(fn(r) {
        @sf.style_node(r, fn() {
          let row = (if indent { sec_narrow_row_in } else { @sf.pg_said_row }).then(sec_narrow_round)
          if wraps {
            row.then(sec_pending_top)
          } else {
            row
          }
        })
        match acts {
          None => words(r)
          // (its mark beside its title and its note as in a row doing nothing, what it does under them all from where
          // its words start)
          Some(f) =>
            r.box(fn(wa) {
              @sf.style_node(wa, fn() { sec_with_acts }, in_row=true)
              wa.box(fn(mw) {
                @sf.style_node(mw, fn() { if wraps { sec_mark_words.then(sec_pending_top) } else { sec_mark_words } })
                words(mw)
              })
              |> ignore
              wa.show(acts_shown, fn(a) {
                a.box(fn(ab) {
                  @sf.style_node(ab, fn() { if mark is Some(_) { sec_acts_past_mark } else { sec_acts_under } })
                  f(ab)
                })
                |> ignore
              })
            })
            |> ignore
        }
      })
      |> ignore
    }
    Wide => {
      parent.show(fn() { over() != "" }, fn(o) {
        o.box(fn(b) {
          @sf.style_node(b, fn() { if apart() { sec_over_apart } else { sec_over } })
          @sf.words_node(b, over, fn() { sec_over_words }) |> ignore
        })
        |> ignore
      })
      parent.box(fn(r) {
        @sf.style_node(r, fn() { if wraps { sec_pending_row } else { sec_row } })
        match mark {
          Some(f) => f(r)
          None => ()
        }
        r.box(fn(t) {
          @sf.style_node(t, fn() { if wraps { sec_pending_words } else { sec_row_text } }, in_row=true)
          t.show(fn() { title() != "" }, fn(w) {
            @sf.words_node(w, title, fn() {
              if wraps {
                sec_pending_ui
              } else if strong {
                sec_row_name
              } else {
                sec_row_words
              }
            })
            |> ignore
          })
          t.show(fn() { note() != "" }, fn(w) {
            @sf.words_node(w, note, fn() {
              if wraps {
                sec_pending_why
              } else if warn() {
                sec_warn
              } else {
                sec_row_meta
              }
            })
            |> ignore
          })
          match acts {
            Some(f) if wraps =>
              t.show(acts_shown, fn(a) {
                a.box(fn(ab) {
                  @sf.style_node(ab, fn() { sec_acts_under })
                  f(ab)
                })
                |> ignore
              })
            _ => ()
          }
        })
        |> ignore
        match end {
          Some(f) => f(r)
          None => ()
        }
        match acts {
          Some(f) if !wraps => r.show(acts_shown, f)
          _ => ()
        }
      })
      |> ignore
    }
  }
}

///|
/// What a row does as words in the link's ink (the library's tap_text_node: its words where the row's start, its room
/// to be pressed round them), a spinner in their place while it is at work: a narrow row's at its end, and a change
/// not in effect's 知道了 at either width.
fn sec_tap_do_node(parent : @view.View, label : () -> String, press : () -> Unit, busy : () -> Bool) -> Unit {
  parent.pick(busy, fn(p, at_work) {
    if at_work {
      @sf.spinner_node(p, size=sec_spin) |> ignore
    } else {
      @sf.tap_text_node(p, label, press)
    }
  })
}

///|
/// What a row says of itself at its end (受保护, a role): quieter, never cut; amber where `warn`.
fn sec_end_words_node(parent : @view.View, words : () -> String, warn? : Bool = false) -> Unit {
  let look = @sf.look_node(parent)
  @sf.words_node(parent, words, fn() {
    match (look, warn) {
      (Narrow, false) => sec_narrow_end
      (Narrow, true) => sec_narrow_end_warn
      (Wide, false) => sec_row_state
      (Wide, true) => sec_warn_state
    }
  })
  |> ignore
}

///|
/// 成员和设备: its people (DeviceRow's people), each a card of their own: who they are and their role, then their
/// devices, each a row (security_device_node). The heading's here; each person a block of the page's list by who
/// they are (`member_key`), so one coming or going leaves the others where they are.
fn people_keys(l : Json?, out : Array[String]) -> Unit {
  out.push("people")
  for m in items(l, "members") {
    out.push(member_key + text(Some(m), "sub"))
  }
}

///|
/// A person's block's key: this, then their sub.
let member_key : String = "member/"

///|
/// The person `sub` as `lock` says them now, a card of their own (MemberRow's look, the workspace page's): their
/// picture, name (你 after it for the viewer), their email under it and role at its end; under them each of their devices, the most lately used
/// first, by the app each is (the core's groups, kept in their order).
fn member_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?, sub : String, stint : () -> Int) -> Unit {
  // (what they are as the core says it now; as last, once gone, while their block goes)
  let last : Ref[Json?] = Ref(None)
  let mv = fn() {
    match items(lock(), "members").iter().find_first(fn(m) { text(Some(m), "sub") == sub }) {
      Some(m) => last.val = Some(m)
      None => ()
    }
    last.val
  }
  let devices = fn() {
    let out : Array[(String, Json)] = []
    for g in items(mv(), "groups") {
      for d in items(Some(g), "devices") {
        out.push((text(Some(d), "id"), d))
      }
    }
    out
  }
  @sf.group_node(parent, fn(g) {
    let name = fn() { text(mv(), "nameText") }
    @sf.link_row_node(
      g,
      name,
      fn() {  },
      value=fn() { text(mv(), "roleText") },
      // (their email under their name, as the workspace page's: their picture across both lines, not in the card's
      // corner)
      note=fn() { text(mv(), "email") },
      lead=LeadMade(fn(l) { ws_avatar_node(l, core, fn() { text(mv(), "email") }, name, fn() { "" }, stint) }),
      face=true,
      title_after=fn(a) { ws_you_node(a, fn() { @sf.t("android-settings.members.you") }) },
      title_after_shown=fn() { flag(mv(), "you") },
      goes=false,
      chevron=false,
    )
    g.each(devices, fn(e) { e.0 }, fn(row, e) {
      security_device_node(row, core, ws, fn() { Some(e.get().1) }, fn() { flag(lock(), "signs") })
    })
  })
}

///|
/// A device in the lock (DeviceRow), `d` as it is now, a row as every settings list's: its mark (a phone, a computer,
/// a web page: the core's `kind` and `machine`, a computer's where it cannot tell), which machine it is, and under it
/// the app, this device or when it was last used and the rest (the core's `metaText`); where it is to be renewed soon,
/// its days left after its name in amber (`leftText`). What can be done about it is a menu, the row pressed
/// (device_menu): 续期 where this device signs, 移除 (in red, asked first) where it may take it out; a row with neither
/// goes nowhere. A ring at its end while either is under way.
fn security_device_node(parent : @view.View, core : Core, ws : () -> String, d : () -> Json?, can_renew : () -> Bool) -> Unit {
  let id = fn() { text(d(), "id") }
  let on = fn() { [("workspace", ws()), ("device", id())] }
  let calls = ["lock.renew", "lock.removeDevice"]
  let busy = fn() { is_doing(core, calls, on()) }
  let failed = fn() { failed_of(core, calls, on()) }
  let renews = fn() { has(d(), "daysLeft") && can_renew() }
  let acts = fn() { renews() || flag(d(), "removable") }
  let mark = fn() { device_mark(d()) }
  parent.pick(acts, fn(r, goes) {
    @sf.link_row_node(
      r,
      fn() { text(d(), "nameText") },
      fn() {
        let (x, y, w, h) = r.placed_window_now()
        device_menu(core, @signals.untracked(ws), @signals.untracked(d), @signals.untracked(renews), At(x, y, w, h))
      },
      note=fn() { text(d(), "metaText") },
      lead=LeadIcon(@signals.untracked(mark)),
      title_after=fn(a) { @sf.words_node(a, fn() { text(d(), "leftText") }, fn() { sec_warn_state }) |> ignore },
      title_after_shown=fn() { text(d(), "leftText") != "" },
      tail=fn(e) { doing_mark_node(e, busy, failed, size=ws_doing_mark) },
      tail_shown=fn() { busy() || failed() is Some(_) },
      goes~,
      chevron=false,
    )
  })
}

///|
/// A device's mark by what the core says it is: a web page's, a phone's, else a computer's (one it cannot tell too).
fn device_mark(d : Json?) -> String {
  if text(d, "kind") == "web" {
    "web"
  } else if text(d, "machine") == "phone" {
    "phone"
  } else {
    "monitor"
  }
}

///|
/// What can be done about device `d`, beside its row (`from`: a sheet from the foot on 小屏, a popover beside it
/// else, the presenters'): 续期 where `renews`, 移除 where it may take it out, in red and asked first (remove_dialog).
fn device_menu(core : Core, ws : String, d : Json?, renews : Bool, from : @sf.Beside) -> Unit {
  let id = text(d, "id")
  let items : Array[@sf.MenuItem?] = []
  if renews {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.security.renew"), icon="refresh", fn() {
          lock_call(core, ws, "renew", @sf.t("web-pages.security.renew"), [("device", id)], done=@sf.t("web-pages.security.renewed"))
        }),
      ),
    )
  }
  if flag(d, "removable") {
    items.push(
      Some(
        @sf.menu_item_of(@sf.t("web-pages.security.remove"), icon="trash", danger=true, further=true, fn() {
          remove_dialog(core, ws, id, text(d, "fullText"))
        }),
      ),
    )
  }
  @sf.menu(items, from~, title=text(d, "fullText"), along=End)
}

///|
/// Station: the workspace's stations and whether the lock protects each (StationRow); none, said so.
fn stations_node(parent : @view.View, core : Core, ws : () -> String, lock : () -> Json?, stint : () -> Int) -> Unit {
  // (its heading as the people's, the room over it a heading's whatever is before it: a note too)
  @sf.section_heading_node(parent, fn() { "Station" })
  let stations = fn() { items(lock(), "stations") }
  parent.pick(fn() { stations().length() == 0 }, fn(p, none) {
    // (none: said in their place, as a list with none says it, no card of its own)
    if none {
      @sf.page_none_node(p, fn() { @sf.t("web-pages.security.noStations") })
      return
    }
    let can = fn() { flag(lock(), "owner") && flag(lock(), "signs") }
    @sf.group_node(p, fn(g) {
      g.each(fn() { indexed(stations()) }, fn(e) { e.0 }, fn(row, e) {
        security_station_node(row, core, ws, fn() { Some(e.get().1) }, can, stint)
      })
    })
  })
}

///|
/// A station and whether the lock protects it (StationRow), `sv` as it is now, a row as the Station page's: its mark
/// (whether it is online wide, then its emoji or icon: station_lead), its name; 受保护 at its end, or why not under its
/// name and at its end 保护 in the link's ink, the row pressed (where `can`: the owner's signing device; asked first, a
/// ring in its place while that goes), or 未保护 in amber.
fn security_station_node(
  parent : @view.View,
  core : Core,
  ws : () -> String,
  sv : () -> Json?,
  can : () -> Bool,
  stint : () -> Int,
) -> Unit {
  let id = fn() { text(sv(), "id") }
  let name = fn() { text(sv(), "name") }
  let guarded = fn() { flag(sv(), "protected") }
  let joining = fn() { is_doing(core, ["lock.joinStation"], [("workspace", ws()), ("station", id())]) }
  let wide = @sf.look_node(parent) is Wide
  let marked = fn() { @sf.has_station_mark(text(sv(), "emoji"), text(sv(), "icon")) }
  // (what is before its name as the Station page's: wide, whether it is online, then its mark; narrow its mark alone,
  // and nothing, no room kept, where it has none)
  let lead = @sf.station_lead(fn() { flag(sv(), "online") }, fn() { text(sv(), "emoji") }, fn() { text(sv(), "icon") }, stint)
  parent.pick(
    fn() {
      let state = if guarded() { 0 } else if can() { 1 } else { 2 }
      if wide || marked() {
        state
      } else {
        state + 3
      }
    },
    fn(r, which) {
      let lead = if which < 3 { lead } else { NoLead }
      match which % 3 {
        0 =>
          @sf.link_row_node(r, name, fn() {  }, value=fn() { @sf.t("web-pages.security.protected") }, lead~, goes=false, chevron=false)
        // (what it does pressed at its end, in the link's ink, as a row that acts says it: asked first, a ring in its
        // place while that goes; a button there would stand taller than its line, over the note under it)
        1 =>
          @sf.link_row_node(
            r,
            name,
            fn() { join_dialog(core, @signals.untracked(ws), @signals.untracked(id), @signals.untracked(name)) },
            value=fn() { @sf.t("web-pages.security.join") },
            value_lit=true,
            note=fn() { @sf.t("web-pages.security.unprotectedWhy") },
            lead~,
            chevron=false,
            busy=joining,
          )
        _ =>
          @sf.link_row_node(
            r,
            name,
            fn() {  },
            note=fn() { @sf.t("web-pages.security.unprotectedWhy") },
            lead~,
            tail=fn(e) { @sf.words_node(e, fn() { @sf.t("web-pages.security.unprotected") }, fn() { sec_warn_state }) |> ignore },
            goes=false,
            chevron=false,
          )
      }
    },
  )
}

///|
/// 关闭安全模式, asked first (turn_off_dialog): a row in red on a card of its own at either width (退出此 workspace's
/// look); a ring while it goes, pressed none then.
fn turn_off_node(parent : @view.View, core : Core, ws : () -> String, here : () -> Here) -> Unit {
  let off = fn() { is_doing(core, ["lock.disable"], [("workspace", ws())]) }
  let press = fn() {
    if !@signals.untracked(off) {
      turn_off_dialog(core, @signals.untracked(ws), @signals.untracked(here).name)
    }
  }
  @sf.group_node(parent, fn(g) {
    @sf.link_row_node(g, fn() { @sf.t("web-pages.security.turnOff") }, press, danger=true, chevron=false, busy=off)
  })
}

///|
/// 开启安全模式 (SecurityOpen, SecurityOpenScreen; the core's `lockDraft`), made once in node `v` as wide as `width`
/// gives it: its members, the devices and stations it would sign (each ticked in or out: `lock.toggle`), then 签名并开启
/// (`lock.open`); back to 安全 once it is on. Read the first time, a draft made up in its bones.
pub fn security_open_node(
  v : @view.View,
  core : Core,
  here : () -> Here,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
) -> Unit {
  let ws = fn() { here().workspace }
  let topic = fn() { (core.topic)("lockDraft", { "workspace": str(ws()) }).get() }
  let draft = fn() { topic().value }
  let read = fn() { !(draft() is None || flag(draft(), "loading")) }
  @sf.page_node(
    v,
    fn() { @sf.t("web-pages.security.openTitle") },
    on_back~,
    frame~,
    said?,
    width?,
    lead=fn() { @sf.t("web-pages.security.openLead") },
    fn() { if read() { ["members", "devices", "stations", "foot"] } else { ["waiting"] } },
    fn(b, key) {
      if key == "waiting" {
        @sf.waiting_node(
          b,
          fn(s) {
            for k in ["members", "devices", "stations", "foot"] {
              open_block_node(s, core.quiet(), ws, fn() { Some(open_sample()) }, k)
            }
          },
          error=fn() {
            match topic().error {
              Some(e) => error_text(e)
              None => ""
            }
          },
        )
      } else {
        open_block_node(b, core, ws, draft, key)
      }
    },
  )
}

///|
/// A block of what turning the lock on would sign (`draft`, the core's `lockDraft`, as it is now), by its key: its
/// members, the devices, the stations (each ticked in or out), 签名并开启 at its foot.
fn open_block_node(parent : @view.View, core : Core, ws : () -> String, draft : () -> Json?, key : String) -> Unit {
  let toggle = fn(id : String) {
    @settings.act(core, @sf.t("web-pages.security.turnOn"), "lock.toggle", obj([("workspace", str(@signals.untracked(ws))), ("id", str(id))]))
  }
  let checks = fn(g : @view.View, list : () -> Array[Json], name : String, note : (Json?) -> String) {
    g.each(fn() { indexed(list()) }, fn(e) { e.0 }, fn(row, e) {
      let sv = fn() { Some(e.get().1) }
      let title = fn() { text(sv(), name) }
      sec_line_node(row, title, note=fn() { note(sv()) }, mark=fn(m) {
        @sf.check_node(m, fn() { flag(sv(), "on") }, fn(_) { toggle(text(@signals.untracked(sv), "id")) }, title, disabled=fn() {
          flag(sv(), "fixed")
        })
      })
    })
  }
  match key {
    "members" =>
      @sf.section_node(
        parent,
        fn() { @sf.t("web-pages.security.members") },
        note=fn() { @sf.t("web-pages.security.peopleCount", args=[("n", items(draft(), "members").length().to_string())]) },
        fn(s) {
          sec_group_node(s, fn(g) {
            g.each(fn() { indexed(items(draft(), "members")) }, fn(e) { e.0 }, fn(row, e) {
              let mv = fn() { Some(e.get().1) }
              sec_line_node(row, fn() { text(mv(), "nameText") }, note=fn() { text(mv(), "email") }, end=fn(x) {
                sec_end_words_node(x, fn() { text(mv(), "roleText") })
              })
            })
          })
        },
      )
    "devices" =>
      @sf.section_node(
        parent,
        fn() { @sf.t("web-pages.security.devices") },
        note=fn() { @sf.t("web-pages.security.devicesWhich") },
        fn(s) { sec_group_node(s, fn(g) { checks(g, fn() { items(draft(), "devices") }, "nameText", fn(dv) { text(dv, "howText") }) }) },
      )
    "stations" =>
      @sf.section_node(parent, fn() { "Station" }, fn(s) {
        sec_group_node(s, fn(g) {
          checks(g, fn() { items(draft(), "stations") }, "name", fn(sv) {
            match (text(sv, "stateText"), text(sv, "version")) {
              ("", v) => v
              (why, "") => why
              (why, v) => why + " · " + v
            }
          })
        })
        @sf.page_note_node(s, fn() { @sf.t("web-pages.security.unprotectedNote") })
      })
    // what signing it means for a web page, cancel, 签名并开启 (foot)
    _ => {
      let wide = @sf.look_node(parent) is Wide
      let opening = fn() { is_doing(core, ["lock.open"], [("workspace", ws())]) }
      parent.box(fn(f) {
        @sf.style_node(f, fn() { if wide { sec_open_foot } else { sec_open_foot_narrow } })
        f.wraps(Is(Some(sec_open_foot_gap))) |> ignore
        @sf.words_node(
          f,
          fn() { @sf.t(if flag(draft(), "canSign") { "web-pages.security.webExpiry" } else { "web-pages.security.webCannotSign" }) },
          fn() { sec_open_foot_note },
        )
        |> ignore
        f.box(fn(a) {
          @sf.style_node(a, fn() { sec_actions })
          @sf.button_node(a, fn() { @sf.t("common.cancel") }, fn() { (core.pop)() }, tone=Ghost) |> ignore
          @sf.button_node(
            a,
            fn() { @sf.t("web-pages.security.signAndTurnOn") },
            fn() {
              @settings.act(
                core,
                @sf.t("web-pages.security.turnOn"),
                "lock.open",
                obj([("workspace", str(@signals.untracked(ws)))]),
                done=@sf.t("web-pages.security.turnedOn"),
                then=fn(_) { (core.pop)() },
              )
            },
            tone=Primary,
            busy=opening,
            disabled=fn() { !(flag(draft(), "ready") && flag(draft(), "owner") && flag(draft(), "canSign")) },
          )
          |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  }
}

///|
/// 移除「…」？: a device taken out of the lock, said what that means first.
pub fn remove_dialog(core : Core, ws : String, device : String, name : String) -> Unit {
  @sf.confirm(
    @sf.t("web-pages.security.removeTitle", args=[("name", name)]),
    @sf.t("web-pages.security.removeBody"),
    @sf.t("web-pages.security.remove"),
    danger=true,
    fn() {
      lock_call(core, ws, "removeDevice", @sf.t("web-pages.security.remove"), [("device", device)], done=@sf.t("web-pages.security.removed"))
    },
  )
}

///|
/// What turning the lock on would sign, made up, for what its page shows while it is read (open_blocks in its bones):
/// three people, two devices, two stations.
fn open_sample() -> Json {
  let line = fn(i : Int, name : Int, note : Int) -> Json {
    {
      "id": Json::string("sample" + i.to_string()),
      "nameText": Json::string(@sf.sample_words(name)),
      "name": Json::string(@sf.sample_words(name)),
      "email": Json::string(@sf.sample_words(note)),
      "howText": Json::string(@sf.sample_words(note)),
      "roleText": Json::string(@sf.sample_words(2)),
    }
  }
  {
    "members": [line(0, 3, 12), line(1, 4, 14), line(2, 3, 10)],
    "devices": [line(3, 6, 9), line(4, 5, 11)],
    "stations": [line(5, 4, 0), line(6, 5, 0)],
  }
}

///|
/// 关闭安全模式？: what turning it off gives up, a line each, and the workspace's name typed
/// before it can go (`lock.disable`, Enter too); written in as it opens.
pub fn turn_off_dialog(core : Core, ws : String, name : String) -> Unit {
  let typed = @ui.Field::new()
  let named = fn() { typed.text().trim(chars=" \t\n").to_owned() == name.trim(chars=" \t\n").to_owned() }
  let go = fn(v : @view.View, shut : () -> Unit) {
    v.focus_let_go()
    shut()
    @settings.act(core, @sf.t("web-pages.security.turnOff"), "lock.disable", obj([("workspace", str(ws))]))
  }
  open_dialog_nodes(
    @sf.t("web-pages.security.turnOffTitle"),
    description=@sf.t("web-pages.security.turnOffBody"),
    fn(v, shut) {
      v.box(fn(l) {
        @sf.style_node(l, fn() { sec_points })
        sec_off_point_node(l, "server", fn() { @sf.t("web-pages.security.nowRisk") })
        sec_off_point_node(l, "devices", fn() { @sf.t("web-pages.security.turnOffApproval") })
        sec_off_point_node(l, "key", fn() { @sf.t("web-pages.security.turnOffVault") })
      })
      |> ignore
      let label = @sf.t("web-pages.security.turnOffType", args=[("name", name)])
      @sf.field_node(v, fn() { label }, fn(f) {
        // (written in as it opens: the keyboard's focus on it, on a sheet too, as the old dialog's focus_editor)
        @sf.panel_opens_in_node(@sf.input_node(f, typed, label~, submitted=fn(_) { if named() { go(f, shut) } }))
      })
    },
    fn(v, shut) {
      @sf.button_node(
        v,
        fn() { @sf.t("common.cancel") },
        fn() {
          v.focus_let_go()
          shut()
        },
        tone=Ghost,
      )
      |> ignore
      @sf.button_node(v, fn() { @sf.t("web-pages.security.turnOff") }, fn() { go(v, shut) }, tone=DangerSolid, disabled=fn() { !named() })
      |> ignore
    },
  )
}

///|
/// One thing turning it off gives up (sec_point_node's, its words alone): its icon, muted, on its first line, beside
/// a line of it.
fn sec_off_point_node(parent : @view.View, icon : String, words : () -> String) -> Unit {
  parent.box(fn(l) {
    @sf.style_node(l, fn() { sec_point_line })
    // (on its first line, across its middle: sec_point_text's)
    @sf.first_line_node(l, Body, leading=L7, fn(i) {
      i.width(Is(Some(sec_point_column))) |> ignore
      @sf.icon_node(i, icon, sec_point_glyph, By(fn() { @sf.theme().p.muted })) |> ignore
    })
    |> ignore
    l.box(fn(w) {
      @sf.style_node(w, fn() { sec_point_words }, in_row=true)
      @sf.words_node(w, words, fn() { sec_point_text }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The sizes: what it changes, its marks 18 in a column of 20; a device's mark 16.
let sec_point_glyph : Double = 18.0

///|
/// The column a mark of what it changes stands in (sec_point_icon's w=S5).
let sec_point_column : Double = 20.0

///|
let sec_device_glyph : Double = 16.0

///|
let sec_dot_side : Double = 7.0

///|
let sec_row_least : Double = 30.0

///|
/// A spinner in place of what a narrow row does (@settings.spinner's 14).
let sec_spin : Double = 14.0

///|
/// The lines apart where a row of buttons and words goes on under (sec_actions' gap, sec_open_foot's).
let sec_actions_gap : Double = 10.0

///|
let sec_open_foot_gap : Double = 12.0

///|
/// A change not in effect (pending_node's rows): wide, a card's row with its words from its top; narrow, a group's row
/// so. Its mark beside its first line, its words the body's on as many lines as they take, why under them the meta's.
// kept across runs: a value (no field of it changes)
let sec_pending_row : @ui.Style = @ui.style(row=true, w=Full, min_h=Fixed(sec_row_least), gap=S3, align=AStart)

///|
// kept across runs: a value (no field of it changes)
let sec_pending_top : @ui.Style = @ui.css("align=AStart")

///|
// kept across runs: a value (no field of it changes)
let sec_pending_mark : @ui.Style = @ui.css("pt=S0_5")

///|
// kept across runs: a value (no field of it changes)
let sec_pending_words : @ui.Style = @ui.style(w=@sf.grow, gap=S1)

///|
// kept across runs: a value (no field of it changes)
let sec_pending_ui : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let sec_pending_body : @ui.TextStyle = @sf.body.then(@sf.full_words)

///|
// kept across runs: a value (no field of it changes)
let sec_pending_why : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
/// A narrow row's first line: its title and what is at its end (row_lines' row_first_line).
// kept across runs: a value (no field of it changes)
let sec_first_line : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
/// The state's card, first on the page, as far from what follows as a section is (lead: a card, 28 under it).
// kept across runs: a value (no field of it changes)
let sec_lead : @ui.Style = @sf.desk_card.then(@ui.css("mb=S7"))

///|
/// The state (state: the body's 14 in 500; its meta the ui's 13 muted).
// kept across runs: a value (no field of it changes)
let sec_state : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, weight=Medium, color=Fg, wrap=false)

///|
/// The state said alone on its line, the card's first (pair_node's: waiting to be approved, to be made trusted): on
/// as many lines as it takes where the card has not the room, never cut (a phone's words set larger, in English).
// kept across runs: a value (no field of it changes)
let sec_state_lines : @ui.TextStyle = sec_state.then(@sf.in_lines)

///|
// kept across runs: a value (no field of it changes)
let sec_state_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")


///|
// kept across runs: a value (no field of it changes)
let sec_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let sec_actions : @ui.Style = @ui.css("row gap=S2_5 align=ACenter")

///|
/// What it changes (points: 10 apart; each its mark in a 20 column, 8 from its words, the body's 14).
// kept across runs: a value (no field of it changes)
let sec_points : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let sec_point_line : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let sec_point_icon : @ui.Style = @ui.css("w=S5 pt=SPx align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sec_point_words : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let sec_point_text : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let sec_point_rest : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Muted, w=Full)

///|
/// A card's rows (rows: 12 apart; a row 30 high at least, 12 apart, the ui's 13; its words in a line, the name in 500,
/// what it is the meta's 12 muted 6 after it); a person's devices 42 in, 8 apart.
// kept across runs: a value (no field of it changes)
let sec_rows : @ui.Style = @ui.css("w=Full gap=S3")

///|
/// sec_rows' gap, over a pending change's piece of the card but the first (pending_node).
let sec_rows_gap : Double = 12.0

///|
/// A narrow row's title, taking what its first line leaves what is at its end.
// kept across runs: a value (no field of it changes)
let sec_title_room : @ui.Style = @ui.style(w=@sf.grow)

///|
/// A narrow row with what it does under it: its mark and its words, then that.
// kept across runs: a value (no field of it changes)
let sec_with_acts : @ui.Style = @ui.style(w=@sf.grow)

///|
/// A narrow row's mark and words over what it does, as a row doing nothing has them.
// kept across runs: a value (no field of it changes)
let sec_mark_words : @ui.Style = @ui.css("row w=Full gap=S3 align=ACenter")

///|
/// What a narrow row does (a device's: 续期, 移除), a line of its own under its words (Security.tsx's mDeviceActs: 6
/// under them, 20 apart).
// kept across runs: a value (no field of it changes)
let sec_acts_under : @ui.Style = @ui.css("row gap=S5 pt=S1_5")

///|
/// The same from where its words start, past its mark (a device's glyph, `sec_device_glyph`, and the row's 12 after it).
// kept across runs: a value (no field of it changes)
let sec_acts_past_mark : @ui.Style = @ui.css("row gap=S5 pt=S1_5 pl=S7")

///|
/// What a narrow row has at its end, at its top.
// kept across runs: a value (no field of it changes)
let sec_end_top : @ui.Style = @ui.css("row h=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let sec_row : @ui.Style = @ui.style(row=true, w=Full, min_h=Fixed(sec_row_least), gap=S3, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let sec_row_text : @ui.Style = @ui.style(row=true, w=@sf.grow, gap=S1_5, align=AEnd)

///|
// kept across runs: a value (no field of it changes)
let sec_row_name : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sec_row_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sec_row_meta : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
/// What a row says of itself at its end (受保护): the meta's words, never cut.
// kept across runs: a value (no field of it changes)
let sec_row_state : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let sec_warn : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=WarnInk, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let sec_warn_state : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=WarnInk, wrap=false)


///|
// kept across runs: a value (no field of it changes)
let sec_over : @ui.Style = @ui.css("w=Full")

///|
// kept across runs: a value (no field of it changes)
let sec_over_apart : @ui.Style = @ui.css("w=Full pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let sec_over_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Muted, wrap=false, w=Cut)

///|
/// A station's dot (dot: 7 round, the online green, amber where it is not protected).
// kept across runs: a value (no field of it changes)
let sec_dot_on : @ui.Style = @ui.style(w=Fixed(sec_dot_side), h=Fixed(sec_dot_side), radius=Full, bg=Positive)

///|
// kept across runs: a value (no field of it changes)
let sec_dot_amber : @ui.Style = sec_dot_on.then(@ui.css("bg=Warn"))

///|
/// A card's words (the web's sub: the ui's 13, muted).
// kept across runs: a value (no field of it changes)
let sec_said : @ui.TextStyle = desk_muted

///|
/// A note beside a button, as wide as it is (the row goes on under where it has not the room).
// kept across runs: a value (no field of it changes)
let sec_note_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// Narrow: a person's device under them, further in; what it is amber where
/// it is to be renewed soon; what a row says at its end (the secondary's, on one line).
// kept across runs: a value (no field of it changes)
let sec_narrow_row_in : @ui.Style = @ui.css("row w=Full pl=S6 pr=S3 py=S2_5 gap=S3 radius=Inner align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sec_narrow_round : @ui.Style = @ui.style(radius=@sf.group_row_end_radius)

///|
/// Narrow: the app a person's devices under it are, at their marks (sec_narrow_row_in's), 6 over the first (Security.tsx's
/// mobile mDeviceApp): the secondary's in 500, on a line.
// kept across runs: a value (no field of it changes)
let sec_narrow_over : @ui.Style = @ui.css("w=Full pl=S6 pr=S3 pt=S1_5")

///|
// kept across runs: a value (no field of it changes)
let sec_narrow_over_words : @ui.TextStyle = @sf.secondary.then(@ui.text_style(weight=Medium, wrap=false, w=Cut))

///|
// kept across runs: a value (no field of it changes)
let sec_narrow_warn : @ui.TextStyle = @sf.pg_link_note.then(@ui.text_style(color=WarnInk))

///|
// kept across runs: a value (no field of it changes)
let sec_narrow_end : @ui.TextStyle = @sf.secondary.then(@sf.one_line)

///|
// kept across runs: a value (no field of it changes)
let sec_narrow_end_warn : @ui.TextStyle = sec_narrow_end.then(@ui.text_style(color=WarnInk))

///|
/// 开启安全模式's foot (foot: what signing means for a web page, then cancel and 签名并开启; narrow, 16 from the page's
/// sides, 4 in its room).
// kept across runs: a value (no field of it changes)
let sec_open_foot : @ui.Style = @ui.css("row w=Full pt=S5 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sec_open_foot_narrow : @ui.Style = @ui.css("row w=Full px=S1 pt=S4 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let sec_open_foot_note : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted)

///|
/// On 设置 › 安全's card: from where the card's words start.
// kept across runs: a value (no field of it changes)
let lock_devices_carded : @ui.Style = @ui.css("w=Full align=AStart")

///|
/// On 设置 › 安全's card: the rows, no ground of their own.
// kept across runs: a value (no field of it changes)
let lock_devices_rows : @ui.Style = @ui.css("gap=S3")
