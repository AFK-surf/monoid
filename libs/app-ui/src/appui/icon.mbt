// The library's icons: line icons on a 24 grid, each stroked round-capped at one width on the screen whatever its
// size (1.5 at 16 and 20, as a 2 stroke on the grid is drawn), as shapes of the node (`View::shapes`), so a part
// laying one out by its ink (a button's leading icon) can say where its drawing reaches.

///|
/// An icon of the library.
#derive(Eq, Debug)
pub(all) enum Icon {
  Plus
  Check
  ChevronRight
  Search
  Bell
  Folder
  Trash
  Alert
  Calendar
  Inbox
  Arrow
  Dot
}

///|
/// Its path on the 24 grid.
fn Icon::path(self : Icon) -> String {
  match self {
    Plus => "M12 5v14M5 12h14"
    Check => "M5 12.5l4.5 4.5L19 7"
    ChevronRight => "M9.5 6l6 6-6 6"
    Search => "M11 4.5a6.5 6.5 0 1 0 0 13a6.5 6.5 0 1 0 0-13zM16 16l4 4"
    Bell => "M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 1.5h-15zM10 20.5h4"
    Folder => "M3.5 7a1.5 1.5 0 0 1 1.5-1.5h4.5l2 2H19a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z"
    Trash => "M4.5 7h15M10 11v6M14 11v6M6.5 7l.8 11.6a1.5 1.5 0 0 0 1.5 1.4h6.4a1.5 1.5 0 0 0 1.5-1.4L17.5 7M9.5 7V4.5h5V7"
    Alert => "M12 3.5a8.5 8.5 0 1 0 0 17a8.5 8.5 0 1 0 0-17zM12 8v4.5M12 15.75v.5"
    Calendar => "M5 6.5h14a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7.5a1 1 0 0 1 1-1zM4 10.5h16M8 4v4M16 4v4"
    Inbox => "M4 13.5l2.5-8h11l2.5 8V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1zM4 13.5h4.5l1 2h5l1-2H20"
    Arrow => "M5 12h14M13 6l6 6-6 6"
    Dot => "M12 10.5a1.5 1.5 0 1 0 0 3a1.5 1.5 0 1 0 0-3z"
  }
}

///|
/// How wide its strokes are on the screen, in points, at any size.
pub let icon_stroke : Double = 1.5

///|
/// The icon's shapes `side` across in `ink`, at `scale` device pixels a point (its curves cut fine enough for them).
pub fn Icon::shapes(
  self : Icon,
  side : Double,
  ink : Int64,
  scale? : Double = 2.0,
  stroke? : Double = icon_stroke,
) -> Array[@paint.Shape] {
  let k = side / 24.0
  let outlines = @pixels.svg_path(self.path(), k * scale).map(fn(sub) {
    let (pts, closed) = sub
    (pts.map(fn(v) { v * k }), closed)
  })
  [@paint.shape_of(outlines, stroke=ink, width=stroke)]
}

///|
/// The icon in `parent`, `side` across, in `ink`; read out as a picture named `label` where it says something (""
/// none: a part's own mark, read with the part). The node.
#callsite(autofill(loc))
pub fn icon_node(
  parent : @view.View,
  icon : Icon,
  side : Double,
  ink : () -> Int64,
  label? : String = "",
  stroke? : Double = icon_stroke,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(b) {
    b.width(Is(Some(side))).height(Is(Some(side))).shrink(Is(0.0)) |> ignore
    if label != "" {
      b.says(Is(Some(@view.said(Image, label~)))) |> ignore
    }
    b.shapes(By(fn() { icon.shapes(side, ink(), scale=b.pixel_scale(), stroke~) })) |> ignore
  })
}
