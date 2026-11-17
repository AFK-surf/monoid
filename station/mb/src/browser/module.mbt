// The station's browsers as a part of the station (src/browser/module.ts and service.ts): kept in <data>/browser,
// its tabs in the station's screens; the agents' tool for their chat's, each session's way to it on the agents' door
// (proxy.mbt), a person's app that draws a Farview tab itself carried to its host, and a chat's going with its chat.
// The Chrome an earlier station process left running is taken up at start, with the chats' contexts in it; when this
// process ends, it is let go of, not closed (the next one takes it up).

///|
/// What the station gives the browsers' part (parts.ts): where it registers its route on the agents' door, its
/// streams, what it is told of a session that ended, its tools.
pub(all) struct BrowserParts {
  door : (DoorBrowsers) -> Unit
  /// The `farview` streams' answer for a viewer (read-only or not) and a stream's head.
  streams : ((Bool, J) -> FarviewStream) -> Unit
  session_ended : ((String) -> Unit) -> Unit
  tools : (Array[BrowserTool]) -> Unit
  door_url : () -> String?
}

///|
/// How an app's stream to a Farview tab is answered: refused (a status and why), or carried to the tab's host's port.
pub(all) enum FarviewStream {
  Refuse(Int, String)
  Carry(Int)
}

///|
pub fn FarviewStream::to_j(self : FarviewStream) -> J {
  match self {
    Refuse(status, error) => jo([("status", ji(status)), ("error", js(error))])
    Carry(port) => jo([("status", ji(200)), ("port", ji(port))])
  }
}

///|
/// An app that draws a Farview tab itself: carried to the tab's host, its bytes both ways as they are (Farview's own
/// protocol). One who only looks is not carried: nothing tells their input from the rest on the way.
pub fn farview_stream(farview : FarviewTabs, read_only : Bool, head : J) -> FarviewStream {
  if read_only {
    return Refuse(403, "a read-only member does not drive a tab")
  }
  let id = text(at_path(Some(head), ["farview", "screen"]))
  match farview.client_port(id) {
    Some(port) => Carry(port)
    None => Refuse(404, "no such Farview tab: its chat's browser is not running")
  }
}

///|
/// What the stream's answer says when the host does not take the connection.
pub fn farview_unreachable(e : Error) -> FarviewStream {
  Refuse(503, "the tab's host does not answer: \{message_of(e)}")
}

///|
/// The browsers' part (module.ts `BrowserLive`): the chats' Farview made beside the browsers and given them, the hosts
/// an earlier station process left taken up, the door's route, the Farview streams, a session's end and the tool.
pub fn browser_live(parts : BrowserParts, browsers : Browsers, farview : FarviewTabs, clock : Clock) -> Unit {
  browsers.use_farview(farview)
  // (the chats' tabs an earlier station process left running stay among the screens)
  (clock.spawn)(async fn() {
    farview.resume() catch {
      _ => ()
    }
  })
  (parts.door)(browsers.door())
  (parts.streams)((read_only, head) => farview_stream(farview, read_only, head))
  (parts.session_ended)(session => {
    (clock.spawn)(async fn() {
      browsers.close_of(session) catch {
        _ => ()
      }
    })
    (clock.spawn)(async fn() {
      farview.close_of(session) catch {
        _ => ()
      }
    })
  })
  (parts.tools)(browser_tools(browsers.tool_browsers(), door_url=parts.door_url, farview~))
}

///|
/// The browser as a service (service.ts): <data>/browser, the Chrome left running taken up.
pub async fn browser_service(o : BrowserOptions) -> Browsers {
  let browsers = Browsers::new(o)
  (o.clock.spawn)(async fn() {
    browsers.resume() catch {
      _ => ()
    }
  })
  browsers
}
