// A station's app a message links to on a line of its own (`[Title](sf-app:<id>)`, `sf-app:<id>@<rev>`: sfbase's
// viz_app.mbt), drawn where it is linked as its attached widget would be (message_viz_node's): its source read of the
// station that holds the chat (`app.get`), the current version followed (loaded again as `app.watch` says it changed),
// a version named kept; what its widget keeps kept by the chat's session as a file's is (`sf-app:<id>` its path).

///|
/// The session key a message's app keeps its state and asks its LLM by: its chat's agent's, as a file it places is
/// (owner_of's).
fn app_key_of(here : MessageHere) -> String {
  match here.view.agents.get(0) {
    Some(ag) => ag.key
    None => here.session
  }
}

///|
/// App `id` (version `rev`, or the current one, followed) that message `ts` of chat `session` on `station` links to, kept
/// by session `key`, in `parent`: its place, breathing, till it has come; the station's words where it cannot be read;
/// then the widget, bound to the app.
fn message_app_node(
  parent : @view.View,
  src : Source,
  station : String,
  session : String,
  key : String,
  ts : String,
  id : String,
  rev : Int?,
) -> Unit {
  let load = @sfbase.viz_app_load_node(parent, src, station, id, rev)
  let path = "sf-app:" + id
  let state = @sfbase.viz_ensure_state(src, station, key, path)
  parent.pick(
    fn() {
      match load() {
        None => -2
        Some(Err(_)) => -1
        // (another version come: the widget made again for it)
        Some(Ok(got)) => got.rev
      }
    },
    fn(p, k) {
      match @signals.untracked(load) {
        Some(Err(words)) if k == -1 =>
          p.box(fn(b) {
            @sf.style_node(b, fn() { @sfbase.viz_file_box })
            @sf.words_node(b, fn() { words }, fn() { @sf.body.then(@sf.bad) }) |> ignore
          })
          |> ignore
        Some(Ok(got)) =>
          match @sfbase.viz_mbui_parse(got.name, got.raw) {
            Some(widget) =>
              p.box(fn(b) {
                @sf.style_node(b, fn() { @sfbase.viz_file_box })
                let place = "chat/" + station + ":" + session + "/" + ts + "/" + path + "@" + got.rev.to_string()
                @sfbase.viz_mbui_node(
                  b,
                  place,
                  @sfbase.viz_mbui_bound_to(widget, id),
                  fn() { state.get().unwrap_or(Json::null()) },
                  {
                    keep: Some(fn(s) { @sfbase.viz_keep(src, station, key, path, s) }),
                    failed: None,
                    follow_up: Some(@sfbase.viz_follow_up(station, session)),
                    app: @sfbase.viz_app_host(src, station, key),
                  },
                  on_app=fn(said) {
                    if rev is None {
                      @sfbase.viz_app_changed(src, station, id, got.rev, said)
                    }
                  },
                )
              })
              |> ignore
            None =>
              p.box(fn(b) {
                @sf.style_node(b, fn() { @sfbase.viz_file_box })
                @sf.words_node(
                  b,
                  // (a version that is no widget: what a file that cannot be read says)
                  fn() { @sfbase.viz_tr("android-misc.viz.cantRead") },
                  fn() { @sf.body.then(@sf.bad) },
                )
                |> ignore
              })
              |> ignore
          }
        _ =>
          // its place, breathing as every wait's shapes, till it comes
          p.box(fn(w) {
            @sf.style_node(w, fn() { @sfbase.viz_wait_under })
            w.box(fn(i) {
              @sf.style_node(i, fn() { @sfbase.viz_wait })
              @sf.breathe_node(i)
            })
            |> ignore
          })
          |> ignore
      }
    },
  )
}
