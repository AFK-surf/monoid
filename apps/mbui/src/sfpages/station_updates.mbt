// The newer releases of a workspace's stations that wait for a person, offered as the app's own newer build is (the
// user, 2026-11-14: 「用户有 station 要更新并且没有开自动更新的情况下，应该也像客户端更新一样提示，点击有弹窗列出需要更新的
// station，可以分别决定更新」): the core's `stationUpdates` (an owner's or admin's, of the stations that do not update
// themselves), a key beside the app's update on 中屏 and 大屏 (sfdesk side_node.mbt) and on Home's bar on 小屏 (sfapp
// home_node.mbt), the app's own update mark, and pressed, their dialog: a row a station, dense (the user, 2026-11-14:
// 「信息密度太低，更新提示用跟 app 更新一样的图标」): its name, what runs and what is out, and 更新 at its end; under
// way how far, failed why and 重试. Each updated on its own.

///|
/// What the core says of workspace `ws`'s stations whose newer release waits for this person (its `stationUpdates`),
/// None till it is answered.
pub fn station_updates_now(core : Core, ws : String) -> Json? {
  (core.topic)("stationUpdates", { "scope": str(ws) }).get().value
}

///|
/// What their key says (2 台 station 有新版本; 1 台 station 正在更新 while all of them are under way): "" while none is
/// listed, and the key not shown.
pub fn station_updates_said(core : Core, ws : String) -> String {
  text(station_updates_now(core, ws), "labelText")
}

///|
/// The dialog of workspace `ws`'s stations whose newer release waits (a sheet from the foot on 小屏), over what is open:
/// one card, a row a station (station_update_row_node); a station updated, or turned to update itself, leaves it, and
/// with the last gone it closes.
pub fn station_updates_dialog(core : Core, ws : String) -> Unit {
  let listed = fn() { items(station_updates_now(core, ws), "items") }
  let title = fn() { text(station_updates_now(core, ws), "titleText") }
  @sf.panel_nodes(
    @signals.untracked(title),
    fn(v, close) {
      // (closed once none is left: none listed as it opened is none it closes for)
      let had = Ref(@signals.untracked(listed).length() > 0)
      v.reacts(fn() { listed().length() > 0 }, fn(some) {
        if some {
          had.val = true
        } else if had.val {
          close()
        }
      })
      // (its card under the title as a part of a dialog stands, its foot corners concentric with the dialog's)
      v.box(fn(block) {
        @sf.style_node(block, fn() { station_updates_block.then(@sf.panel_card_last_node(block)) })
        @sf.group_node(block, fn(g) {
          g.each(listed, fn(it) { text(Some(it), "station") }, fn(row, it) {
            station_update_row_node(row, core, fn() { Some(it.get()) })
          })
        })
      })
      |> ignore
    },
    from=Unanchored,
    live=fn() { (title(), "", "") },
  )
}

///|
/// A station of the dialog in `row`, `it` as the core lists it (StationUpdate): its name over what runs and what is out
/// (under way, where it is; failed, what it said, or why the press failed here); at its end 更新 (重试 once failed),
/// under way how far where its station says. Not pressed again while its update is asked.
fn station_update_row_node(row : @view.View, core : Core, it : () -> Json?) -> Unit {
  let station = text(@signals.untracked(it), "station")
  let busy = fn() { is_doing(core, ["software.update"], [("station", station), ("id", "station")]) }
  let update = fn() { software_call(core, station, "software.update", [("id", str("station"))]) }
  @sf.item_row_node(row, fn(r) {
    @sf.row_lines_node(
      r,
      fn(h) {
        h.box(fn(n) {
          @sf.style_node(n, fn() { sw_name_line.then(sw_name_grow) }, in_row=true)
          n.min_width(Is(Some(0.0))) |> ignore
          @sf.words_node(n, fn() { text(it(), "name") }, fn() { sw_name }) |> ignore
        })
        |> ignore
        h.pick(fn() { text(it(), "state") }, fn(e, state) {
          @sf.style_node(e, fn() { sw_rest })
          match state {
            "updating" =>
              e.show(fn() { field(it(), "percent") is Some(Number(_, ..)) }, fn(b) {
                b.box(fn(bar) {
                  bar.width(Is(Some(sw_progress_w))) |> ignore
                  @sf.progress_node(bar, fn() { Some(number(it(), "percent") / 100.0) }, fn() { @ui.tree_theme().line }, fn() {
                    @sf.theme().p.accent
                  })
                  |> ignore
                })
                |> ignore
              })
            "failed" =>
              @sf.button_node(e, fn() { @sf.t("common.retry") }, update, disabled=fn() { busy() || !flag(it(), "canUpdate") })
              |> ignore
            _ =>
              @sf.button_node(e, fn() { @sf.t("web-main.versions.update") }, update, tone=Primary, disabled=fn() {
                busy() || !flag(it(), "canUpdate")
              })
              |> ignore
          }
        })
      },
      fn(u) {
        @sf.words_node(u, fn() { text(it(), "versionText") }, fn() { sw_version }) |> ignore
        u.show(fn() { text(it(), "detail") != "" || software_failed.get(station) is Some(_) }, fn(w) {
          @sf.words_node(
            w,
            fn() {
              match software_failed.get(station) {
                Some(why) => why
                None => text(it(), "detail")
              }
            },
            fn() { if text(it(), "state") == "failed" || software_failed.get(station) is Some(_) { sw_failed_line } else { sw_note } },
          )
          |> ignore
        })
      },
      spaced=true,
    )
  })
}

///|
/// The dialog's card's block: the room a part of a dialog has over it (composer_ref's ref_block's).
// kept across runs: a value (no field of it changes)
let station_updates_block : @ui.Style = @ui.css("w=Full pt=S3_5")
