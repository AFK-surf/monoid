// Shared elements (MyGo's Match, set off by its cause): two nodes said to be one thing by an id (View::shared). One a
// structure lets go of or sets leaving (show, pick, each: it or what holds it) and one made with the same id in the same
// change (an event, a batch of signals set outside, a moment come on the timeline) are paired as that change is
// committed whole (Tree::pairs_now), whichever structure ran first: never by comparing frames. The new one flies from
// where the old one was drawn as the change came, as it looked then, to where the change lays it out (said once, then
// followed as a way's end is: what moves it after for another cause, a window made narrower, it goes with). On its way
// it is drawn over the rest of its layer (the node of the root's it is in), in the window's terms: cut, faded and grown
// by nothing that holds it, and found by a press where it is drawn; but where both ends are within one node that says
// so (View::flights_within: a board, its cards going from one column to another), it is drawn within where that node is
// seen, as what holds it cuts it, never over what is round it. The old one is kept as a copy on the same way, laid
// out nowhere and taking nothing, under it: the new one comes in over the first half, the old one goes over the second.
// Both are drawn as their ground, edge, corners and ink go from the old one's to the new one's (the new one's as it is
// said now, followed). What it holds is drawn as it is laid out at its end, as big as the way has it (grown with it).
// Where it is at a moment is worked out from where it set out, where it went, its way and that moment alone.
//
// No pair: one only let go of (or leaving) goes as it would have (what was let go of let go as the change ends, nothing
// drawn between); one only made comes as it would have. One let go of that no layout ever placed (made and let go in
// one change: a page's list's blocks shown by their count in one pass of its fill, then not in a later; or made in a
// box placed before, the box let go of in the same change) is none to fly from (Tree::departs_of, Node's `placed`).
// Two of an id let go of or made in one change, or one made while another of its id lives, is a fault (Tree::fault: a
// test fails), and none of them flies. A pair made again on its way (opened, then closed before it is there) sets out
// from where it is drawn then, its old copy let go of at once.
// One end may stay where it is (View::shared's `stays`: a picture's thumbnail, the other end the picture opened over
// everything): it is never let go of for a flight nor made for one, and pairs with no other that stays. One that moves
// may fly with one that stays alone (`with_stays`): made in the place of another of its id that moves (the picture's
// viewer made again for another tier of the window), it is there at once, the other let go of, no flight between. While one of its
// id that moves lives, it keeps its room and is drawn nowhere, whatever holds it says (the tree's say, by the id, never
// what holds it). One that moves made in a change while it lives flies from where it was drawn as the change came, as
// it looked; one that moves let go of in a change while it lives is drawn there no more, and it flies from where that
// one was drawn back to its own place, drawn again as it sets out. Neither fades: one picture moves. The one that moves
// is drawn where it is held, not over the rest of its layer: what is drawn after it there (its viewer's bar) over it.
// Its room cut by what holds it as it set out, and less what lies over the top of what scrolls it and what is pinned
// over that one's foot (Scroll::top_covered, a page's list's foot: the bar a chat's list runs under, its composer), is
// what is drawn of it, on its way, as far as it is there (the cut opens to the window as it leaves, closes to it as it
// comes back); one wholly under them is drawn nowhere and pairs with nothing; a picture in it drawn on the way as the end that stays draws
// it (covering, contained) in the box the way has, so it is as that end draws it at that end and as the other draws it
// at the other. What flies may say how it goes, not the framework (View::shared's `route`: the user, 2026-11-17,
// 「应该让使用的地方去控制飞行轨迹和高度（层级）」): where it is drawn along its way, how far the room it was cut to opens,
// and where it is drawn among the rest, where it is held or under the foot pinned over the column that scrolls its end
// that stays (what covers that column over it, as over the column: a thumbnail going out from under a chat's bar and
// composer); the order made again at the moment that changes. One that stays that is drawn nowhere (no layout placed it, scrolled out of the window, cut to nothing)
// pairs with nothing: the other comes or goes as it would have. A change of the id of one that moves pairs nothing:
// what stays of its old id is drawn again at once, what stays of its new one drawn nowhere; nor does one that moves let
// go of and another made in one change by other ids (a picture stepped to the one beside it, one in the other's place).
// Not yet: what the new one holds laid out again at each size on its way (it is drawn grown as it is laid out at its
// end), its words morphing glyph by glyph, its scale and turn mixed, a way going on as fast as it went.

///|
/// How a shared node flies (View::shared): for a flight `far` points long (the furthest its place or size goes), how long
/// it takes (ms; 0: there at once, as with motion reduced) and how far along it is at each ms from its start (0 → 1):
/// @motion's shared, a Move.
pub(all) struct Flight {
  way : (Double) -> (Double, (Double) -> Double)
}

///|
/// What a flight with an end that stays sets out between (View::shared's `route` is told it): where it sets out and
/// where it goes (x, y, w, h, in the window), whether it sets out from the end that stays (a thumbnail, opened) or goes
/// to it (closed back into it), and what the column that scrolls that end leaves clear down it (its top less what covers
/// it, its foot less what is pinned over it: Scroll::top_covered, a page's list's foot; none where nothing covers it).
pub(all) struct FlightEnds {
  from : (Double, Double, Double, Double)
  to : (Double, Double, Double, Double)
  from_stays : Bool
  clear : (Double, Double)?
}

///|
/// Where a flight is drawn among the rest as it goes (FlightRoute's `level`): where the one that moves is held (a
/// picture's viewer's layer, over all of the page), or under the foot pinned over the column that scrolls its end that
/// stays (a chat's composer, and so its bar, drawn over it, as over that column: a thumbnail going out from under them).
#derive(Eq, Debug)
pub(all) enum FlightLevel {
  Held
  UnderFoot
}

///|
/// How a flight with an end that stays goes, said by what flies (View::shared's `route`), each worked out of its ends
/// (FlightEnds) and how far along its way it is (0 where it sets out, 1 where it goes, as its Move has it): how far it
/// goes (the Move as long as that), where it is drawn and how big, how far the room it was cut to at the end that stays
/// (as what holds that end cuts it) has opened to the window (0 → 1), and where it is drawn among the rest. None said:
/// straight from one end to the other, cut to that end's room less what covers its column, opening as it leaves it.
pub(all) struct FlightRoute {
  far : (FlightEnds) -> Double
  place : (FlightEnds, Double) -> (Double, Double, Double, Double)
  opened : (FlightEnds, Double) -> Double
  level : (FlightEnds, Double) -> FlightLevel
}

///|
/// The look a flight sets out from (the old one's as the change came, or where one on its way had got to): its ground,
/// its edge, its corners (points, as drawn), its words' ink.
priv struct FromLook {
  ground : Int64
  edge : (Double, Int64)
  corners : (Double, Double, Double, Double)
  ink : Int64
  /// how much of the way it keeps this look before it comes to the one it goes to (View::flies_in's `look_late`)
  held : Double
}

///|
/// How far from the look it set out with to the one it goes to a flight is drawn (0 → 1), `l.k` of its way left: as
/// far as its way, or none for the share of it the look it set out with is held (FromLook's `held`), then the rest.
fn lift_look_p(l : Lift) -> Double {
  let p = 1.0 - l.k
  let held = l.from.held
  if held > 0.0 {
    dclamp((p - held) / (1.0 - held), 0.0, 1.0)
  } else {
    p
  }
}

///|
/// One drawn on a flight's way (Node's `lift`): the node whose place and size it goes to (the new one: itself, or the
/// one its old copy goes with), the node of the root's it is drawn over the rest of (the layer it is in), how far off
/// that place and size it set out (across, down, wider, taller), how much of the way is left (1 → 0) and how far it is
/// faded in (the new one) or not yet out (the old one), and the look it set out from.
priv struct Lift {
  follow : Int
  top : Int
  mut d : (Double, Double, Double, Double)
  late : Double
  mut k : Double
  /// how much of its way down or up is left (1 → 0): `k` but for one whose rise lags its way across (View::flies_in's
  /// `up_late`)
  mut ky : Double
  /// where it set out in the window, kept there (View::flies_in's): it goes from there to where it is drawn now, so
  /// what moves that place meanwhile (a list's way opening its room) is taken up on its own way, not added to it;
  /// none: off that place by `d`, which goes with it (View::shared's, and one whose node rides a way its page said:
  /// Tree::rides_said_way)
  mut fixed : (Double, Double, Double, Double)?
  mut a : Double
  from : FromLook
  /// a flight with an end that stays (View::shared's `stays`): how that end draws its picture (covering, along; contained),
  /// drawn so on the way; and its room as cut by what held it, what is drawn of it at that end (`at_start`: the end it
  /// sets out from)
  stays : StaysEnd?
  /// how far what holds it was drawn off where it is laid out as it set out (View::drawn_off): what moves it so after
  /// (a later cause's way in a page's list said `flips`) moves where it goes with it
  mut held_off : (Double, Double)
  /// the node both its ends are within that says what flies so is drawn within it (View::flights_within); none
  within : NodeId?
}

///|
/// The end of a flight that stays where it is (Lift's `stays`): how it draws its picture (View::image_covers,
/// image_covers_at, image_contains), its room in the window cut by what holds it, and whether it is where the flight
/// sets out (else where it comes to).
priv struct StaysEnd {
  cover : Bool
  cover_at : (Double, Double)?
  contain : Bool
  cut : (Double, Double, Double, Double)
  at_start : Bool
  /// what the column that scrolls it leaves clear down it, in the window (its top less what covers it, its foot less
  /// what is pinned over it: Scroll::top_covered, a page's list's foot); none where nothing scrolls it
  clear : (Double, Double)?
  /// its room as what holds it cuts it, what covers its column not taken off (a route's `opened` opens this one)
  held_cut : (Double, Double, Double, Double)
  /// the foot pinned over the column that scrolls it (a page's list's foot: Scroll's foot_at), -1 none
  foot : Int
  /// how what flies goes (View::shared's `route`, the one that moves'), and what it set out between
  mut route : FlightRoute?
  mut ends : FlightEnds
}

///|
/// A node with an id let go of (or set leaving) in the change being committed: the id, the node with it, where it was
/// drawn as the change came and as it looked, and what the structure let go of with it (it, or what holds it): parked
/// till the change is committed (`leaving`: leaving, where it is).
priv struct Departure {
  id : String
  node : NodeId
  from : (Double, Double, Double, Double)
  look : FromLook
  held : NodeId
  leaving : Bool
  /// the nearest of what held it as it was let go of that says what flies from it is drawn within it
  /// (View::flights_within); none
  within : NodeId?
}

///|
/// A flight under way: the new node, the old one's copy (none once let go), its start and length, how far along it is
/// at each ms, the layer it is drawn over, and what ends it (its binding and its end on the timeline).
priv struct Flying {
  node : NodeId
  mut ghost : NodeId?
  /// how much of its length its rise lags its way across (0: none; View::flies_in's `up_late`)
  late : Double
  /// faded in as it comes (false: one with an end that stays, one picture moving)
  fades : Bool
  from_fn : (((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?)?
  start : Double
  /// its length and how far along it is at each ms: as its flight says for how far it goes, said anew where that is
  /// laid out anew before it is first drawn (Tree::flights_refresh_now)
  mut dur : Double
  mut along : (Double) -> Double
  top : Int
  mut stop : () -> Unit
  /// what calls off its end on the timeline, set anew with its length
  mut stop_end : () -> Unit
  /// where it is drawn among the rest now (its route's `level`), and the foot it is drawn under then (-1 none)
  mut level : FlightLevel
  foot : Int
  /// how far it goes from where it sets out to where it goes (View::flies_in's `far_of`; none: flight_far's own)
  far_of : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double)?
  /// whether it leads the others of its Flight set out with it (View::flies_in's `lead`): their length and curve its
  lead : Bool
  /// whether it still waits for its hosted foot's old view to lay out its height in that change (Tree::flights_refresh_now)
  mut awaits_old : Bool
}

///|
/// One with id `id`, flying as `flight` says from the one with its id let go of in the change it is made in (or that
/// sets it this id): see the head of this file. The id said By follows what it reads; a change of it pairs nothing.
/// `stays`: the end that stays where it is. `with_stays`: one that moves flying only from or to one of its id that stays,
/// never from another that moves (the same thing made again in another place, as a window changes tier: there at once).
/// `told`, of one that moves: told as a flight between it and the end of its id that stays sets out (from that end as
/// it is made, back to it as it is let go of), in the change that sets it out: when the flight sets out and when it ends
/// (the clock's ms), and how far along its way it is at each moment (0 where it set out, 1 where it goes), so that what
/// goes with it (what is drawn round the picture that flies, a ground over the page) goes that one way from its own
/// cause. `route`, of one that moves: how a flight between it and the end of its id that stays goes, either way, and
/// where it is drawn among the rest as it goes (FlightRoute): what flies says it, not the framework.
#callsite(autofill(loc))
pub fn View::shared(
  self : View,
  id : Live[String],
  flight : Flight,
  stays? : Bool = false,
  with_stays? : Bool = false,
  told? : (Double, Double, (Double) -> Double) -> Unit,
  route? : FlightRoute,
  loc~ : SourceLoc,
) -> View {
  guard self.live() is Some(n) else { return self }
  ignore(loc)
  n.share_flight = Some(flight)
  n.share_stays = stays
  n.share_with_stays = with_stays && !stays
  n.share_told = if stays { None } else { told }
  n.share_route = if stays { None } else { route }
  let tree = self.tree
  let at = self.at
  let gen = self.gen
  let first = Ref(true)
  let set = fn(s : String) {
    let n = tree.nodes[at]
    guard n.live && n.gen == gen else { return }
    match n.share {
      Some(was) if was == s => return
      Some(was) => tree.share_counted(at, was, -1)
      None => ()
    }
    n.share = Some(s)
    tree.share_counted(at, s, 1)
    // (made in a change: one that may pair with one let go of in it, as it is committed whole; one that stays never)
    if first.val && tree.in_change() && !n.share_stays {
      tree.arrivals.push({ at, gen })
      tree.pairs_due()
    }
    first.val = false
  }
  match id {
    Is(s) => set(s)
    By(f) => {
      let stop = tree.queued(f, set)
      self.owns(stop) |> ignore
    }
  }
  self
}


///|
/// One made in a change that flies in from what is none of the window's tree (View::flies_in): the node, and where it
/// sets out given where it is laid out as that change is committed (its place and size in the window).
priv struct Incoming {
  node : NodeId
  from : ((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?
  late : Double
  bare : Bool
  look_late : Double
  far_of : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double)?
  lead : Bool
}

///|
/// How far one flying from `from` to `to` goes, as its flight's length is said by: `far_of` where it is given
/// (View::flies_in's), else the most of how far its place, its width and its height go.
fn flight_far(from : (Double, Double, Double, Double), to : (Double, Double, Double, Double), far_of : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double)?) -> Double {
  match far_of {
    Some(far) => far(from, to)
    None => {
      let dd = (from.0 - to.0, from.1 - to.1, from.2 - to.2, from.3 - to.3)
      dmax(dmax((dd.0 * dd.0 + dd.1 * dd.1).sqrt(), dd.2.abs()), dd.3.abs())
    }
  }
}

///|
/// Made in the change being committed, it flies, as that change is committed whole, from what is none of the window's
/// tree (an old view's words, a text field's: nothing of it here to let go of, so no old copy) to where that change
/// lays it out: from where `from` says, given that place and size in the window (None: no flight, there at once),
/// looking there as it is (`bare_from`: with no ground and no edge at the start, as bare words in a field do, coming to
/// its own look on the way); one thing moving, never faded, drawn over the rest of its layer all the way, as one View::shared pairs
/// (the head of this file). `flight` is the way, @motion's shared, a Move; its rise (down or up, and its height) lags
/// its way across by `up_late` of its length, both eased as the way is over the rest (0: one way; words sent: across
/// first, up a little after). Its look stays the one it sets out with for `look_late` of its way, coming to its own over
/// the rest (bare words out of the field before their ground comes round them). How far it goes, which its flight's
/// length is said by, is `far_of` of where it sets out and where it goes (none: the most of how far its place, its
/// width and its height go). Of those that fly in on one Flight (the same one, not an equal) in one change, the first
/// said `lead` leads: all of them go on its length and curve, landing as one (words, a quote and a picture grown from
/// a thumbnail sent as one), and the key of a page's list they come in is carried by its way alone (Tree::carried); none
/// said so, each goes as long as its own way, the key on the longest. Made outside a change it is there at once.
#callsite(autofill(loc))
pub fn View::flies_in(
  self : View,
  flight : Flight,
  from : ((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?,
  up_late? : Double = 0.0,
  bare_from? : Bool = false,
  look_late? : Double = 0.0,
  far_of? : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double),
  lead? : Bool = false,
  loc~ : SourceLoc,
) -> View {
  ignore(loc)
  guard self.live() is Some(n) && self.tree.in_change() else { return self }
  n.in_flight = Some(flight)
  self.tree.incoming.push({
    node: { at: self.at, gen: self.gen },
    from,
    late: dclamp(up_late, 0.0, 0.9),
    bare: bare_from,
    look_late: dclamp(look_late, 0.0, 0.9),
    far_of,
    lead,
  })
  self.tree.pairs_due()
  self
}

///|
/// Those made in the change committed now that fly in from outside the tree (View::flies_in), each set flying from
/// where it says, given where it is laid out now; one let go of meanwhile, or no longer in the window's tree, none.
fn Tree::incoming_now(self : Tree) -> Unit {
  let all = self.incoming.copy()
  self.incoming.clear()
  // (where each sets out and goes: none where it is let go of, out of the window's tree or flies from nowhere)
  let ends : Array[((Double, Double, Double, Double), (Double, Double, Double, Double))?] = all.map(fn(i) {
    guard self.alive_id(i.node) && self.attached(i.node.at) else { return None }
    let to = self.handle(i.node.at).laid_window_now()
    (i.from)(to).map(fn(from) { (from, to) })
  })
  // (the lead of each Flight, the first said so that flies: its way, by how far it goes, all of that Flight's)
  let leads : Array[(Flight, Int, (Double, (Double) -> Double))] = []
  for j, i in all {
    guard i.lead && ends[j] is Some((from, to)) && self.nodes[i.node.at].in_flight is Some(fl) else { continue }
    guard leads.search_by(fn(l) { physical_equal(l.0, fl) }) is None else { continue }
    let far = flight_far(from, to, i.far_of)
    let (ms, along) = (fl.way)(far)
    guard ms > 0.0 && far > 0.5 else { continue }
    leads.push((fl, j, (ms, along)))
  }
  let led_of = fn(j : Int, i : Incoming) {
    let led = match self.nodes[i.node.at].in_flight {
      Some(fl) => leads.search_by(fn(l) { physical_equal(l.0, fl) }).map(fn(x) { leads[x] })
      None => None
    }
    (led, led is Some((_, lj, _)) && lj == j)
  }
  // (in a page's list key's block coming in this change: that key carried by this flight, the list's one way of this
  // moment on its rise (Tree::carried); one led, by its lead's alone. All of them carried before any sets out, so that
  // what flies in a block sets out from where the block is drawn once carried, whichever of them is said first)
  for j, i in all {
    guard ends[j] is Some((from, to)) else { continue }
    let (led, leads_it) = led_of(j, i)
    if led is None || leads_it {
      self.carried(i.node.at, from, to, i.late, self.cause_now(), far_of=i.far_of, lead=leads_it)
    }
  }
  for j, i in all {
    guard ends[j] is Some((from, _)) else { continue }
    let n = self.nodes[i.node.at]
    let (led, leads_it) = led_of(j, i)
    let (a, b, c, d) = corners_of(n.look)
    let look : FromLook = {
      ground: if i.bare { n.look.ground & 0xFFFFFF00L } else { n.look.ground },
      edge: if i.bare { (0.0, n.look.edge.1 & 0xFFFFFF00L) } else { n.look.edge },
      corners: (a, b, c, d),
      ink: n.look.ink,
      held: i.look_late,
    }
    // (set out from within a node said View::flights_within that holds where it goes: drawn within it all the way)
    let within = match self.flights_within_of(i.node.at) {
      Some(w) =>
        match self.within_rect(w) {
          Some((c0, c1, c2, c3)) => {
            let (cx, cy) = (from.0 + from.2 / 2.0, from.1 + from.3 / 2.0)
            if cx >= c0 && cx <= c2 && cy >= c1 && cy <= c3 { Some(w) } else { None }
          }
          None => None
        }
      None => None
    }
    self.fly_from(
      i.node,
      from,
      look,
      None,
      i.late,
      from_fn=Some(i.from),
      within~,
      far_of=i.far_of,
      lead=leads_it,
      way=led.map(fn(l) { l.2 }),
    )
    |> ignore
  }
  // (told for this change alone)
  self.carried_rows.clear()
}
///|
/// Whether node `at` or what holds it is on a way its page said (Style's come_spec of a list key's `comes_way`, Tree's
/// come_ways_lead): its place moves on that curve, which a flight in to it takes up by going with it.
fn Tree::rides_said_way(self : Tree, at : Int) -> Bool {
  let mut p = at
  while p >= 0 {
    let n = self.nodes[p]
    if n.live && n.coming && (self.come_ways_lead.contains(p) || (n.list_key_way && n.flex.style.come_spec is Some(_))) {
      return true
    }
    // (or a page's list's block on its one way (`flips`, Tree's flip_rows): drawn off where it is laid out as that way
    // goes, a later change moving it on while the flight goes; the flight goes with it)
    if n.live && p != at && (self.flip_rows.contains(p) || self.motion_aux().flip_rows.contains(p)) {
      return true
    }
    p = n.parent
  }
  false
}

///|
/// The id it is shared by (View::shared), none where it is not.
pub fn View::shared_id(self : View) -> String? {
  guard self.live() is Some(n) else { return None }
  n.share
}

///|
/// Where the one of id `id` on a flight's way is drawn in the window now (x, y, w, h) and its corners as drawn there
/// (top left, then round it), the one that comes (not an old copy); none where none of it flies.
pub fn Tree::flight_drawn(
  self : Tree,
  id : String,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double))? {
  for f in self.flights {
    guard self.alive_id(f.node) else { continue }
    let n = self.nodes[f.node.at]
    guard n.share == Some(id) && n.lift is Some(l) else { continue }
    return Some((self.lift_rect(l), self.look_from(f.node.at, 1.0).corners))
  }
  None
}

///|
/// When the flight of the one of id `id` under way ends (ms, the clock's); none where none of it flies.
pub fn Tree::flight_ends_at(self : Tree, id : String) -> Double? {
  for f in self.flights {
    guard self.alive_id(f.node) else { continue }
    let n = self.nodes[f.node.at]
    guard n.share == Some(id) && n.lift is Some(_) else { continue }
    return Some(f.start + f.dur)
  }
  None
}

///|
/// What of the window node `id` is drawn within on a flight with an end that stays (View::shared's `stays`): that end's
/// room as cut by what held it, opening to its layer's as it leaves it, closing to it as it comes back (x0, y0, x1, y1);
/// on one both of whose ends are within a node said View::flights_within (one flying in from a place within it too),
/// where that node is seen (Tree::within_cut);
/// none, on any other flight or none.
pub fn Tree::lift_cut(self : Tree, id : NodeId) -> (Double, Double, Double, Double)? {
  guard self.alive_id(id) && self.nodes[id.at].lift is Some(l) else { return None }
  guard l.stays is Some(e) else { return self.within_cut(l) }
  let (wx, wy, ww, wh) = self.placed_window(l.top)
  let (x0, y0, x1, y1) = (wx, wy, wx + ww, wy + wh)
  // (how far it is from that end: 0 there, 1 at the other; where what flies says its route, its room as what holds it
  // cuts it opened as far as that says)
  let (cut, t) = match e.route {
    Some(r) => (e.held_cut, (r.opened)(e.ends, 1.0 - l.k))
    None => (e.cut, l.from_stays_end())
  }
  let (c0, c1, c2, c3) = cut
  let (c0, c1, c2, c3) = (dmax(c0, x0), dmax(c1, y0), dmin(c2, x1), dmin(c3, y1))
  // (and within where it is drawn on its way: what is seen of it, the box its corners round, Tree::lift_cut_corners)
  let (lx, ly, lw, lh) = self.lift_rect(l)
  Some(
    (
      dmax(c0 + (x0 - c0) * t, lx),
      dmax(c1 + (y0 - c1) * t, ly),
      dmin(c2 + (x1 - c2) * t, lx + lw),
      dmin(c3 + (y1 - c3) * t, ly + lh),
    ),
  )
}

///|
/// The corners (top left, then round it) what Tree::lift_cut gives is rounded by: the flight's own as it is drawn then,
/// so that what is seen of it on its way, cut to the window or to that room, is as round as the flight has it; within a
/// node said View::flights_within, that node's as it is drawn; none where Tree::lift_cut gives none.
pub fn Tree::lift_cut_corners(self : Tree, id : NodeId) -> (Double, Double, Double, Double)? {
  guard self.alive_id(id) && self.nodes[id.at].lift is Some(l) else { return None }
  match (l.stays, l.within) {
    (Some(_), _) => Some(self.look_from(id.at, 1.0).corners)
    (None, Some(w)) if self.within_cut(l) is Some(_) => {
      let (_, _, s) = self.placed(w.at, drawn=true)
      Some(self.look_from(w.at, s).corners)
    }
    _ => None
  }
}

///|
/// It says that what flies between two places both within it (View::shared: one let go of in it, the other made in it
/// in the same change; View::flies_in: made in it, setting out from a place within it) is drawn within it as it goes, as
/// what holds it cuts it, never over what is round it: a board, its cards going from one column to another, never over
/// the board's bar or the window's edge round it. What flies in from outside it, or out of it, is drawn as any flight is
/// (the head of shared.mbt).
#callsite(autofill(loc))
pub fn View::flights_within(self : View, loc~ : SourceLoc) -> View {
  ignore(loc)
  guard self.live() is Some(n) else { return self }
  n.flights_within = true
  self
}

///|
/// The nearest of what holds node `at` (it too) said View::flights_within, if one is.
fn Tree::flights_within_of(self : Tree, at : Int) -> NodeId? {
  let mut i = at
  while i >= 0 {
    let n = self.nodes[i]
    if n.live && n.flights_within {
      return Some({ at: i, gen: n.gen })
    }
    i = n.parent
  }
  None
}

///|
/// Where what flies on way `l` is drawn within, both its ends within a node said View::flights_within: that node where it
/// is drawn now, as what holds it cuts it (Tree::seen_bounds), in the window (x0, y0, x1, y1); none where it is not, or
/// that node is gone.
fn Tree::within_cut(self : Tree, l : Lift) -> (Double, Double, Double, Double)? {
  guard l.within is Some(w) else { return None }
  self.within_rect(w)
}

///|
/// Where node `w` is seen now, in the window (x0, y0, x1, y1): where it is drawn, as what holds it cuts it; none where it
/// is gone.
fn Tree::within_rect(self : Tree, w : NodeId) -> (Double, Double, Double, Double)? {
  guard self.alive_id(w) else { return None }
  let n = self.nodes[w.at]
  let (x, y, s) = self.placed(w.at, drawn=true)
  let (b0, b1, b2, b3) = self.seen_bounds(w)
  Some((dmax(x, b0), dmax(y, b1), dmin(x + n.flex.width * s, b2), dmin(y + n.flex.height * s, b3)))
}

///|
/// It is a mark over what holds it (a film's length over its picture), none of what flies when that flies
/// (View::shared, View::flies_in): carried at its own size by its nearest corner, gone as the way is halfway from the
/// end it lies at (Tree::mark_on_flight).
#callsite(autofill(loc))
pub fn View::flight_mark(self : View, loc~ : SourceLoc) -> View {
  ignore(loc)
  guard self.live() is Some(n) else { return self }
  n.flight_mark = true
  self.tree.look_marked_at(self.at)
  self
}

///|
/// What flies from a thing in the column whose pinned foot holds it, drawn under that foot (FlightLevel's UnderFoot), is
/// drawn just before it, not before all the foot: what the foot holds made before it (the round buttons over a chat's
/// list) under what flies, as over the column it pins over, it (the composer) over it. Made in no foot, it says nothing.
#callsite(autofill(loc))
pub fn View::flights_under(self : View, loc~ : SourceLoc) -> View {
  ignore(loc)
  guard self.live() is Some(_) else { return self }
  let tree = self.tree
  let at = self.at
  let mut i = tree.nodes[at].parent
  while i >= 0 {
    match tree.scrolls_at.get(i) {
      Some(sc) if !sc.across => {
        sc.under_at = at
        self.owns(fn() { if sc.under_at == at { sc.under_at = -1 } }) |> ignore
        return self
      }
      _ => ()
    }
    i = tree.nodes[i].parent
  }
  self
}

///|
/// Whether it is drawn on a flight's way now (View::shared): the new one or the old one's copy.
pub fn View::flies(self : View) -> Bool {
  guard self.live() is Some(n) else { return false }
  n.lift is Some(_)
}

///|
/// How many living nodes have id `id` (View::shared) told `by` more.
fn Tree::share_count(self : Tree, id : String, by : Int) -> Unit {
  let k = self.shared_live.get(id).unwrap_or(0) + by
  if k <= 0 {
    self.shared_live.remove(id)
  } else {
    self.shared_live[id] = k
  }
  self.shared_n = self.shared_n + by
}

///|
/// Node `at`'s id `id` counted `by` more (View::shared): all of them, and those that move or those that stay apart; where
/// one that moves comes to be or no longer is, what stays of its id drawn again (Tree::stays_marked).
fn Tree::share_counted(self : Tree, at : Int, id : String, by : Int) -> Unit {
  self.share_count(id, by)
  if self.nodes[at].share_stays {
    let all = self.shared_stays.get(id).unwrap_or([])
    if by > 0 {
      if !all.contains(at) {
        all.push(at)
      }
      self.shared_stays[id] = all
    } else {
      all.retain(fn(i) { i != at })
      if all.is_empty() {
        self.shared_stays.remove(id)
      } else {
        self.shared_stays[id] = all
      }
    }
    // (one that stays come or gone as one that moves lives: drawn nowhere, or there again)
    self.lift_marked(at)
    return
  }
  let was = self.shared_moving.get(id).unwrap_or(0)
  let k = was + by
  if k <= 0 {
    self.shared_moving.remove(id)
  } else {
    self.shared_moving[id] = k
  }
  if (was > 0) != (k > 0) {
    self.stays_marked(id)
  }
}

///|
/// Whether node `n` (one that stays: View::shared's `stays`) is drawn nowhere now: one of its id that moves lives.
fn Tree::stays_hidden(self : Tree, n : Node) -> Bool {
  match n.share {
    Some(id) => self.shared_moving.get(id).unwrap_or(0) > 0
    None => false
  }
}

///|
/// What stays of id `id` drawn again as it is drawn nowhere or there once more.
fn Tree::stays_marked(self : Tree, id : String) -> Unit {
  match self.shared_stays.get(id) {
    Some(all) =>
      for at in all {
        if self.nodes[at].live {
          self.lift_marked(at)
        }
      }
    None => ()
  }
}

///|
/// The one that stays of id `id` a flight may come from or go to now: living, held in the window's tree, placed by a
/// layout, and some of it seen in its layer as what holds it cuts it and as what covers what scrolls it leaves it
/// (Tree::stays_bounds); none, none.
fn Tree::stays_end(self : Tree, id : String) -> Int? {
  guard self.shared_stays.get(id) is Some(all) else { return None }
  for at in all {
    let n = self.nodes[at]
    guard n.live && n.placed && self.attached(at) else { continue }
    let (x, y, _, s) = self.projected(at, drawn=true)
    let (w, h) = (n.lw * s, n.lh * s)
    let (bx0, by0, bx1, by1) = self.stays_bounds(at)
    // (and within its layer, the window's part it is drawn in)
    let (lx, ly, lw, lh) = self.placed_window(self.top_node_of(at))
    let (x0, y0) = (dmax(dmax(x, bx0), lx), dmax(dmax(y, by0), ly))
    let (x1, y1) = (dmin(dmin(x + w, bx1), lx + lw), dmin(dmin(y + h, by1), ly + lh))
    if x1 > x0 && y1 > y0 && w > 0.0 && h > 0.0 {
      return Some(at)
    }
  }
  None
}

///|
/// What of the window node `at` (one that stays) is seen within (x0, y0, x1, y1): what holds it cuts it to
/// (Tree::seen_bounds), less what lies over the top of what scrolls it and what is pinned over its foot
/// (Scroll::top_covered, a page's list's foot: the bar it runs under, its composer), as they are said now.
fn Tree::stays_bounds(self : Tree, at : Int) -> (Double, Double, Double, Double) {
  let n = self.nodes[at]
  let (bx0, by0, bx1, by1) = self.seen_bounds({ at, gen: n.gen })
  let mut top = by0
  let mut foot = by1
  let mut i = n.parent
  while i >= 0 {
    match self.scrolls_at.get(i) {
      // (not where it is in that foot itself: a composer's own picture is not under its composer)
      Some(sc) if !sc.across && !self.in_scroll_foot(at, sc) => {
        let (_, y, s) = self.placed(i, drawn=true)
        let h = self.nodes[i].flex.height * s
        let (over, under) = @signals.untracked(fn() { (sc.top_covered(), sc.foot_hides_now()) })
        top = dmax(top, y + over * s)
        foot = dmin(foot, y + h - under * s)
      }
      _ => ()
    }
    i = self.nodes[i].parent
  }
  (bx0, top, bx1, foot)
}

///|
/// What the column that scrolls node `at` (one that stays) leaves clear down it in the window: its top less what covers
/// it, its foot less what is pinned over it (Scroll::top_covered, a page's list's foot), as they are said now; none
/// where nothing scrolls it, or nothing covers either end of it.
fn Tree::stays_clear(self : Tree, at : Int) -> (Double, Double)? {
  let mut i = self.nodes[at].parent
  while i >= 0 {
    match self.scrolls_at.get(i) {
      // (none for one in that foot itself: nothing pinned over it there)
      Some(sc) if !sc.across && self.in_scroll_foot(at, sc) => return None
      Some(sc) if !sc.across => {
        let (_, y, s) = self.placed(i, drawn=true)
        let h = self.nodes[i].flex.height * s
        let (over, under) = @signals.untracked(fn() { (sc.top_covered(), sc.foot_hides_now()) })
        return if over <= 0.0 && under <= 0.0 { None } else { Some((y + over * s, y + h - under * s)) }
      }
      _ => ()
    }
    i = self.nodes[i].parent
  }
  None
}

///|
/// Whether node `at` is in the foot pinned over the column `sc` scrolls (a page's list's foot, Scroll's foot_at, or
/// what of it is drawn over a flight under it, under_at): its composer's own.
fn Tree::in_scroll_foot(self : Tree, at : Int, sc : Scroll) -> Bool {
  let mut i = at
  while i >= 0 {
    if i == sc.foot_at || i == sc.under_at {
      return true
    }
    i = self.nodes[i].parent
  }
  false
}

///|
/// The foot pinned over the column that scrolls node `at` (a page's list's foot: Scroll's foot_at), -1 none.
fn Tree::stays_foot(self : Tree, at : Int) -> Int {
  let mut i = self.nodes[at].parent
  while i >= 0 {
    match self.scrolls_at.get(i) {
      // (none for one in that foot itself: what flies from it is not drawn under where it is)
      Some(sc) if !sc.across && self.in_scroll_foot(at, sc) => return -1
      Some(sc) if !sc.across => return if sc.under_at >= 0 { sc.under_at } else { sc.foot_at }
      _ => ()
    }
    i = self.nodes[i].parent
  }
  -1
}

///|
/// Where the one of id `id` that stays (View::shared's `stays`) and would be flown to now (Tree::stays_seen) is drawn in
/// the window (x, y, w, h), and its corners there (top left, then round it); none where none is.
pub fn Tree::stays_drawn(
  self : Tree,
  id : String,
) -> ((Double, Double, Double, Double), (Double, Double, Double, Double))? {
  guard self.stays_end(id) is Some(at) else { return None }
  let n = self.nodes[at]
  let (x, y, _, s) = self.projected(at, drawn=true)
  Some(((x, y, n.lw * s, n.lh * s), self.look_from(at, 1.0).corners))
}

///|
/// Whether one of id `id` that stays (View::shared's `stays`) would be flown to now: one placed, some of it drawn in the
/// window. What closes the other end asks it, to let that one go at once (flown back to it) rather than fade it out.
pub fn Tree::stays_seen(self : Tree, id : String) -> Bool {
  self.stays_end(id) is Some(_)
}

///|
/// The end that stays at node `at` as a flight takes it (Lift's `stays`): how it draws its picture, its room cut by what
/// holds it and by what covers what scrolls it (Tree::stays_bounds), which end it is.
fn Tree::stays_of(self : Tree, at : Int, at_start : Bool) -> StaysEnd {
  let n = self.nodes[at]
  let (bx0, by0, bx1, by1) = self.stays_bounds(at)
  {
    cover: n.look.image_cover,
    cover_at: n.look.image_cover_at,
    contain: n.look.image_contain,
    cut: (bx0, by0, bx1, by1),
    at_start,
    clear: self.stays_clear(at),
    held_cut: self.seen_bounds({ at, gen: n.gen }),
    foot: self.stays_foot(at),
    route: None,
    ends: { from: (0.0, 0.0, 0.0, 0.0), to: (0.0, 0.0, 0.0, 0.0), from_stays: at_start, clear: None },
  }
}

///|
/// Whether a change is being committed now (an event, a structure's change, a moment come on the timeline).
fn Tree::in_change(self : Tree) -> Bool {
  self.committing > 0 || self.cause_at >= 0.0
}

///|
/// The shared nodes in node `at` (it, or what it holds), the outermost of each: none in another of them.
fn Tree::shared_in(self : Tree, at : Int, out : Array[Int]) -> Unit {
  let n = self.nodes[at]
  if n.share is Some(_) {
    out.push(at)
    return
  }
  for k in n.kids {
    self.shared_in(k, out)
  }
}

///|
/// Where node `at` stands in the window as it was last placed (its place and each holder's, as far as a column scrolls
/// it: View::placed_window_now's), and how big.
fn Tree::placed_window(self : Tree, at : Int) -> (Double, Double, Double, Double) {
  let mut x = 0.0
  let mut y = 0.0
  let mut i = at
  while i >= 0 {
    let m = self.nodes[i]
    if !m.slot {
      x = x + m.lx
      y = y + m.ly
      if m.scroll_off is Some(_) {
        let (sx, sy) = self.scroll_off_now(m)
        x = x + sx
        y = y + sy
      }
    }
    i = m.parent
  }
  (x, y, self.nodes[at].lw, self.nodes[at].lh)
}

///|
/// Where node `n`, on a flight's way as `l` says, is drawn in the window now and how big: off the place and size of the
/// one it goes with by what is left of how far off it set out.
fn Tree::lift_rect(self : Tree, l : Lift) -> (Double, Double, Double, Double) {
  let (x0, y0, w, h) = self.placed_window(l.follow)
  let (hx, hy) = self.held_off(l.follow)
  let x = x0 + hx - l.held_off.0
  let y = y0 + hy - l.held_off.1
  let k = l.k
  let ky = l.ky
  // (one with an end that stays whose route says how it goes: where that has it, as far along its way)
  match l.stays {
    Some(e) =>
      match e.route {
        // (where it goes as it is now: what it follows moved meanwhile, a picture its viewer lays out anew as it is
        // decoded, its way goes on to there)
        Some(r) => return (r.place)({ ..e.ends, to: (x, y, w, h) }, 1.0 - l.k)
        None => ()
      }
    None => ()
  }
  // (a picture or tile opening in both width and height with a lagged rise (`up_late`): opened proportionally on `ky`,
  // as sfbase/flight.mbt's kind 4 does, never stretched wide before its height rises)
  let kw = if l.stays is None && l.late > 0.0 && l.d.2.abs() > 1.0 && l.d.3.abs() > 1.0 { ky } else { k }
  match l.fixed {
    Some((fx, fy, fw, fh)) =>
      (x + (fx - x) * k, y + (fy - y) * ky, dmax(w + (fw - w) * kw, 0.0), dmax(h + (fh - h) * ky, 0.0))
    None => (x + l.d.0 * k, y + l.d.1 * ky, dmax(w + l.d.2 * kw, 0.0), dmax(h + l.d.3 * ky, 0.0))
  }
}

///|
/// How far along a flight with an end that stays is from that end (0 there, 1 at the other), its way `1 - k` along.
fn Lift::from_stays_end(self : Lift) -> Double {
  let p = 1.0 - self.k
  match self.stays {
    Some(e) if !e.at_start => 1.0 - p
    _ => p
  }
}

///|
/// Node `at` said a mark (View::flight_mark): where what holds it on a flight's way (the nearest of what holds it that
/// is on one) is, where the mark is drawn then, how big and how far it is faded (x, y, scale, alpha), else none; `drawn`
/// says where each is drawn by its place in the order (x, y, scale). A mark over a picture (a film's length) is none of
/// what flies: carried at its own size (as big as what flies was drawn before its way grew or shrank it), as far in from
/// that one's nearest corner as it lies in from it at rest, and gone as the way is halfway from the end it lies at (the
/// old page's: what a thumbnail draws over its picture goes faster, gone halfway); so it neither grows nor shrinks with
/// what flies, nothing of its words seen to change their size.
fn Tree::mark_on_flight(
  self : Tree,
  at : Int,
  drawn : (Int) -> (Double, Double, Double),
) -> (Double, Double, Double, Double)? {
  let n = self.nodes[at]
  // (what flies that holds it, and where it lies in that one, as laid out)
  let mut rx = n.lx
  let mut ry = n.ly
  let mut p = n.parent
  while p >= 0 && self.nodes[p].lift is None {
    rx = rx + self.nodes[p].lx
    ry = ry + self.nodes[p].ly
    p = self.nodes[p].parent
  }
  guard p >= 0 && p < self.order_of.length() && self.order_of[p] >= 0 else { return None }
  let holder = self.nodes[p]
  guard holder.lift is Some(l) && holder.lw > 0.0 && holder.lh > 0.0 else { return None }
  let (_, _, bs) = drawn(self.order_of[p])
  let (hx, hy, hw, hh) = self.lift_rect(l)
  let grown = lift_scale(holder, hw)
  let b0 = if grown > 0.0 { bs / grown } else { bs }
  let x = if rx + n.lw / 2.0 <= holder.lw / 2.0 { hx + rx * b0 } else { hx + hw - (holder.lw - rx) * b0 }
  let y = if ry + n.lh / 2.0 <= holder.lh / 2.0 { hy + ry * b0 } else { hy + hh - (holder.lh - ry) * b0 }
  // (how far the way is from the end it lies at: a thumbnail's, from it; one that comes, from its own place)
  let away = match l.stays {
    Some(_) => l.from_stays_end()
    None => l.k
  }
  Some((x, y, b0 * n.ls, dmax(0.0, 1.0 - 2.0 * away)))
}

///|
/// How big what node `n` holds is drawn on its flight's way (`w` wide as it is drawn): as wide as it is drawn for as
/// wide as it is laid out.
fn lift_scale(n : Node, w : Double) -> Double {
  if n.lw > 0.0 {
    w / n.lw
  } else {
    1.0
  }
}

///|
/// Where node `at` is drawn in the window, how opaque and how big, where it is on a flight's way (Node's `lift`): the
/// window's terms, nothing that holds it counted.
fn Tree::lifted_place(self : Tree, n : Node, l : Lift) -> (Double, Double, Double, Double) {
  let (x, y, w, _) = self.lift_rect(l)
  (x, y, n.look.alpha * l.a, lift_scale(n, w))
}

///|
/// Its corners in points: those it says, else its radius at each.
fn corners_of(look : Look) -> (Double, Double, Double, Double) {
  match look.corners {
    Some(c) => c
    None => (look.radius, look.radius, look.radius, look.radius)
  }
}

///|
/// What node `n` looks like where it is drawn now, as a flight sets out from it: its ground, edge, corners as big as
/// it is drawn (`s`) and ink; one on a flight's way as it is drawn there.
fn Tree::look_from(self : Tree, at : Int, s : Double) -> FromLook {
  let n = self.nodes[at]
  match n.lift {
    Some(l) => {
      let p = lift_look_p(l)
      let to = self.nodes[l.follow].look
      let c = corners_mix(l.from.corners, corners_of(to), p)
      {
        ground: colour_mix(l.from.ground, blend_ground(to.ground, to.ground_over), p),
        edge: (l.from.edge.0 + (to.edge.0 - l.from.edge.0) * p, colour_mix(l.from.edge.1, to.edge.1, p)),
        corners: c,
        ink: colour_mix(l.from.ink, to.ink, p),
        held: 0.0,
      }
    }
    None => {
      let (a, b, c, d) = corners_of(n.look)
      {
        ground: n.look.ground,
        edge: (n.look.edge.0 * s, n.look.edge.1),
        corners: (a * s, b * s, c * s, d * s),
        ink: n.look.ink,
        held: 0.0,
      }
    }
  }
}

///|
/// Four corners from `a` to `b`, `p` of the way.
fn corners_mix(
  a : (Double, Double, Double, Double),
  b : (Double, Double, Double, Double),
  p : Double,
) -> (Double, Double, Double, Double) {
  (a.0 + (b.0 - a.0) * p, a.1 + (b.1 - a.1) * p, a.2 + (b.2 - a.2) * p, a.3 + (b.3 - a.3) * p)
}

///|
/// Two colours (0xRRGGBBAA) mixed `p` of the way, each channel by its square and the alpha straight (ui's mix_colour,
/// the web's mixColor); one of them none (clear): the other's colour, its alpha from none.
fn colour_mix(a : Int64, b : Int64, p : Double) -> Int64 {
  if a == b || p >= 1.0 {
    return b
  }
  if p <= 0.0 {
    return a
  }
  let a = if (a & 0xFFL) == 0L { b & 0xFFFFFF00L } else { a }
  let b = if (b & 0xFFL) == 0L { a & 0xFFFFFF00L } else { b }
  let ch = fn(c : Int64, s : Int) { ((c >> s) & 0xFFL).to_double() / 255.0 }
  let one = fn(s : Int) {
    let x = ch(a, s)
    let y = ch(b, s)
    let e = x * x + (y * y - x * x) * p
    let v = if e < 0.0 { 0.0 } else { e.sqrt() }
    (v * 255.0 + 0.5).floor().to_int64()
  }
  let x = ch(a, 0)
  let y = ch(b, 0)
  let alpha = ((x + (y - x) * p) * 255.0 + 0.5).floor().to_int64()
  (one(24) << 24) | (one(16) << 16) | (one(8) << 8) | alpha
}

///|
/// Node `n`'s content as a flight draws it (Node's `lift`): as big as its way has it (in its own terms, `s` as big as
/// what it holds is drawn), its ground, edge, corners and ink from those it set out from to the one it goes with's.
fn Tree::lifted_content(self : Tree, n : Node, l : Lift, c : Content) -> Content {
  let (_, _, w, h) = self.lift_rect(l)
  let s = lift_scale(n, w)
  let p = lift_look_p(l)
  let to = self.nodes[l.follow].look
  let (a, b, cc, d) = corners_mix(l.from.corners, corners_of(to), p)
  {
    ..c,
    w: if s > 0.0 { w / s } else { c.w },
    h: if s > 0.0 { h / s } else { c.h },
    ground: colour_mix(l.from.ground, blend_ground(to.ground, to.ground_over), p),
    edge: ((l.from.edge.0 + (to.edge.0 - l.from.edge.0) * p) / s, colour_mix(l.from.edge.1, to.edge.1, p)),
    corners: Some((a / s, b / s, cc / s, d / s)),
    radius: a / s,
    ink: colour_mix(l.from.ink, to.ink, p),
    // (a picture drawn on the way as the end that stays draws it, in the box the way has: as that end at it, as the
    // other at its end, where the box is the picture's own)
    image_cover: match l.stays {
      Some(e) => e.cover
      None => c.image_cover
    },
    image_cover_at: match l.stays {
      Some(e) => e.cover_at
      None => c.image_cover_at
    },
    image_contain: match l.stays {
      Some(e) => e.contain
      None => c.image_contain
    },
  }
}

///|
/// Node `v` (held by `holder`, a structure's) let go of in the change being committed, where it is or holds a shared
/// node: taken out of what holds it (View::park) and kept till the change is committed whole, then let go of, or kept
/// as the copy of what flies (Tree::pairs_now). Whether it was so kept.
fn Tree::departs(self : Tree, holder : View, v : View) -> Bool {
  guard self.shared_n > 0 && self.in_change() && v.live() is Some(n) && n.left_at < 0.0 else {
    return false
  }
  let found = self.departs_of(v)
  // (none to fly: `v` let go of as it would have been, nothing parked)
  guard found.length() > 0 else { return false }
  self.departed(found, v.id(), false)
  holder.park(v) |> ignore
  true
}

///|
/// Node `v` set leaving in the change being committed (View::leave), where it is or holds a shared node: what may fly
/// from it as the change is committed whole (Tree::pairs_now), it leaving meanwhile.
fn Tree::departs_leaving(self : Tree, v : View) -> Unit {
  guard self.shared_n > 0 && self.in_change() && v.live() is Some(_) else { return }
  let found = self.departs_of(v)
  guard found.length() > 0 else { return }
  self.departed(found, v.id(), true)
}

///|
/// The shared nodes in node `v` (Tree::shared_in) that may fly from where they were drawn: each a layout has placed.
/// It is the node that would fly that is asked, not `v`: one never placed (made and let go of in one change, a page's
/// list's fill's passes; or made in a change in a box placed before it, the box let go of in the same change) was drawn
/// nowhere, nothing flies from it, and it is let go of as it would have been.
fn Tree::departs_of(self : Tree, v : View) -> Array[Int] {
  let found : Array[Int] = []
  self.shared_in(v.at, found)
  found.filter(fn(at) { self.nodes[at].placed })
}

///|
/// The shared nodes `found`, let go of with `held` (or leaving with it), told as such: where each was drawn as the
/// change came (where it was on a flight's way, its flight ended), as it looked.
fn Tree::departed(self : Tree, found : Array[Int], held : NodeId, leaving : Bool) -> Unit {
  for at in found {
    let n = self.nodes[at]
    guard n.share is Some(id) else { continue }
    let (from, look) = match n.lift {
      Some(l) => {
        // (on a flight's way: where it is drawn as of the change's moment, as it looks there; that flight over)
        match self.flying_of(at) {
          Some(f) => self.flight_at(f, self.cause_now())
          None => ()
        }
        let (x, y, w, h) = self.lift_rect(l)
        let look = self.look_from(at, 1.0)
        match self.flying_of(at) {
          Some(f) => self.flight_over(f)
          None => ()
        }
        ((x, y, w, h), look)
      }
      None => {
        let (x, y, _, s) = self.projected(at, drawn=true)
        ((x, y, n.lw * s, n.lh * s), self.look_from(at, s))
      }
    }
    self.departures.push({ id, node: { at, gen: n.gen }, from, look, held, leaving, within: self.flights_within_of(at) })
  }
  self.pairs_due()
}

///|
/// What is let go of and made in the change being committed to be paired once it is committed whole: then, where it is
/// none's (a batch of signals set outside, told as its flush ends); else as that change ends (Tree::event_said,
/// Tree::advance_loop, Tree::at_cause).
fn Tree::pairs_due(self : Tree) -> Unit {
  if self.pairs_asked {
    return
  }
  self.pairs_asked = true
}

///|
/// The pairs of the change committed now at `at`, where any was told (Tree::pairs_due), outside every change: once its
/// flush ends.
fn Tree::pairs_after(self : Tree, at : Double) -> Unit {
  guard self.pairs_asked else { return }
  @signals.after_flush(fn() {
    if self.committing > 0 || self.cause_at >= 0.0 {
      return
    }
    let was = self.cause_at
    self.cause_at = at
    self.pairs_now()
    self.cause_at = was
  })
}

///|
/// The change being committed, committed whole: what was let go of and made in it with the same id paired, each pair
/// set flying from its moment; what was let go of and paired with nothing let go of now.
fn Tree::pairs_now(self : Tree) -> Unit {
  guard self.pairs_asked else { return }
  self.pairs_asked = false
  let deps = self.departures.copy()
  self.departures.clear()
  let arrs = self.arrivals.copy()
  self.arrivals.clear()
  self.committing += 1
  @signals.start_batch()
  // (made in it, there still, in the window's tree (none in what was let go of meanwhile), each once)
  let made : Array[NodeId] = []
  for a in arrs {
    if self.alive_id(a) && self.attached(a.at) && !made.contains(a) && self.nodes[a.at].share is Some(_) {
      made.push(a)
    }
  }
  let ids : Array[String] = []
  for d in deps {
    if !ids.contains(d.id) {
      ids.push(d.id)
    }
  }
  for a in made {
    match self.nodes[a.at].share {
      Some(id) if !ids.contains(id) => ids.push(id)
      _ => ()
    }
  }
  // (what was let go of with what flies from it: kept as its old copy, the rest let go of already)
  let flown : Array[NodeId] = []
  // (those that move made or let go of alone of their ids, where one of the id stays)
  let from_stays : Array[(Int, NodeId)] = []
  let to_stays : Array[(Departure, Int)] = []
  let came_alone = Ref(false)
  let went_alone = Ref(false)
  for id in ids {
    let gone = deps.filter(fn(d) { d.id == id })
    let come = made.filter(fn(a) { self.nodes[a.at].share == Some(id) })
    // (those that move: one that stays is none of them, View::shared's `stays`)
    let living = self.shared_moving.get(id).unwrap_or(0) - gone.length()
    if gone.length() > 1 || come.length() > 1 {
      // (the node it is told under: one made, else one let go of; never both looked up, as `unwrap_or(gone[0]…)`
      // did, which with none let go stopped the run on an index out of bounds before the fault was told)
      let under = match come.get(0) {
        Some(c) => c
        None => gone[0].node
      }
      self.fault(under, "shared: \{id} let go of or made more than once in one change")
    } else if come.length() == 1 && living > 1 {
      self.fault(come[0], "shared: \{id} made while another of it lives")
    } else if gone.length() == 1 && come.length() == 1 {
      // (one said `with_stays` made in the place of another that moves: the same thing made again, there at once, the
      // old let go of with the rest)
      if !self.nodes[come[0].at].share_with_stays && self.paired(gone[0], come[0]) is Some(_) {
        flown.push(gone[0].held)
      }
    } else if come.length() == 1 && gone.length() == 0 {
      came_alone.val = true
      // (one that moves made where one of its id stays: from that one, below)
      match self.stays_end(id) {
        Some(st) => from_stays.push((st, come[0]))
        None => ()
      }
    } else if gone.length() == 1 && come.length() == 0 && living == 0 {
      went_alone.val = true
      // (the last that moves let go of where one of its id stays: back to that one, below)
      match self.stays_end(id) {
        Some(st) => to_stays.push((gone[0], st))
        None => ()
      }
    }
  }
  // (one that moves let go of and another made in the same change, by other ids, is one in the other's place (a
  // picture stepped to the one beside it): neither flies to or from what stays, what stays of either id drawn again or
  // nowhere at once, as where the id of one changes; else each flies)
  let swapped = came_alone.val && went_alone.val
  if !swapped {
    for e in from_stays {
      self.from_stays(e.0, e.1)
    }
    for e in to_stays {
      if self.to_stays(e.0, e.1) {
        flown.push(e.0.held)
      }
    }
  }
  // (what was let go of with no flight from it: let go of now, as it would have been; what leaves, left leaving)
  let let_go : Array[NodeId] = []
  for d in deps {
    if !d.leaving && !flown.contains(d.held) && !let_go.contains(d.held) && self.alive_id(d.held) {
      let_go.push(d.held)
    }
  }
  for h in let_go {
    self.handle(h.at).let_go()
  }
  // (what flies in from outside the tree, made in it: View::flies_in)
  self.incoming_now()
  @signals.end_batch()
  self.committing -= 1
  self.modals_settled()
}

///|
/// Whether node `at` is held in the window's tree (by the root, through what holds it): none parked, let go of or a
/// flight's old copy.
fn Tree::attached(self : Tree, at : Int) -> Bool {
  let mut i = at
  while i > 0 {
    i = self.nodes[i].parent
  }
  i == 0
}

///|
/// The node of the root's node `at` is in (it, where the root holds it), through what holds it.
fn Tree::top_node_of(self : Tree, at : Int) -> Int {
  let mut i = at
  let mut top = at
  while i > 0 {
    if !self.nodes[i].slot {
      top = i
    }
    i = self.nodes[i].parent
  }
  top
}

///|
/// Departure `d` and node `to` made in the same change paired: `to` set flying from where `d`'s was drawn, `d`'s node
/// kept as its old copy on the same way (what it was let go of with let go of now, all but it). Its old copy, where it
/// flies.
fn Tree::paired(self : Tree, d : Departure, to : NodeId) -> NodeId? {
  guard self.alive_id(d.node) && self.alive_id(d.held) else { return None }
  let ghost = d.node.at
  let held = d.held.at
  // (leaving: none of it leaves now, it is let go of as the flight takes its place)
  if d.leaving {
    let h = self.nodes[held]
    h.left_at = -1.0
    h.back_at = -1.0
    told_going(h)
    self.timeline.retain(fn(e) {
      match e {
        Leaves(i, _) => i != d.held
        _ => true
      }
    })
    if h.parent >= 0 {
      self.handle(h.parent).park(self.handle(held)) |> ignore
    }
  }
  // (its old copy alone kept: taken out of what it was let go of with, the rest of that let go of)
  if ghost != held {
    let g = self.nodes[ghost]
    let p = g.parent
    if p >= 0 {
      match self.nodes[p].kids.search(ghost) {
        Some(i) => self.nodes[p].kids.remove(i) |> ignore
        None => ()
      }
    }
    g.parent = -1
    self.handle(held).let_go()
  }
  let g = self.nodes[ghost]
  // (taking nothing, read out as nothing, its id none of the living's: what of it reads whether it takes input told so,
  // once the change is committed whole, as a node said to take no press is: View::presses)
  g.inert = true
  self.modals_told(within=ghost)
  g.said_hidden = true
  match g.share {
    Some(id) => {
      self.share_counted(ghost, id, -1)
      g.share = None
    }
    None => ()
  }
  let to_v = self.handle(to.at)
  let flight = match self.nodes[to.at].share_flight {
    Some(f) => f
    None => return None
  }
  let (tx, ty, tw, th) = to_v.laid_window_now()
  let (fx, fy, fw, fh) = d.from
  let dd = (fx - tx, fy - ty, fw - tw, fh - th)
  let far = dmax(dmax((dd.0 * dd.0 + dd.1 * dd.1).sqrt(), dd.2.abs()), dd.3.abs())
  let (ms, along) = (flight.way)(far)
  if ms <= 0.0 || far <= 0.5 {
    self.handle(ghost).let_go()
    return None
  }
  let at = self.cause_now()
  let top = self.top_node_of(to.at)
  // (both ends within one node that says so: drawn within it all the way)
  let within = match (d.within, self.flights_within_of(to.at)) {
    (Some(a), Some(b)) if a == b => Some(a)
    _ => None
  }
  let f : Flying = {
    node: to,
    ghost: Some({ at: ghost, gen: g.gen }),
    late: 0.0,
    fades: true,
    from_fn: None,
    start: at,
    dur: ms,
    along,
    top,
    stop: fn() {  },
    stop_end: fn() {  },
    level: Held,
    foot: -1,
    far_of: None,
    lead: false,
    awaits_old: false,
  }
  self.flights.push(f)
  self.nodes[to.at].lift = Some({ follow: to.at, top, d: dd, late: 0.0, k: 1.0, ky: 1.0, a: 0.0, from: d.look, stays: None, fixed: None, held_off: self.held_off(to.at), within })
  g.lift = Some({ follow: to.at, top, d: dd, late: 0.0, k: 1.0, ky: 1.0, a: 1.0, from: d.look, stays: None, fixed: None, held_off: self.held_off(to.at), within })
  self.lifted_order()
  // (drawn as of each frame's moment while it goes; over at its end, a moment of its own)
  let stop_way = self.queued(fn() { self.drawn_at() }, fn(t) { self.flight_at(f, t) })
  f.stop_end = to_v.at_moment(at + ms, fn() { self.flight_over(f) })
  let unkeep = to_v.owns_while(fn() { self.flight_over(f) })
  f.stop = fn() {
    stop_way()
    (f.stop_end)()
    unkeep()
  }
  self.flight_told(to.at)
  Some({ at: ghost, gen: g.gen })
}

///|
/// Node `to` (one that moves) made where node `st` of its id stays: set flying from where `st` is drawn as the change
/// came, as it looks, its picture as `st` draws it, its room as cut where `st` is (the file's head). `st` drawn nowhere
/// meanwhile, as one of its id that moves lives.
fn Tree::from_stays(self : Tree, st : Int, to : NodeId) -> Unit {
  let n = self.nodes[st]
  let (x, y, _, s) = self.projected(st, drawn=true)
  let e = self.stays_of(st, true)
  e.route = self.nodes[to.at].share_route
  if self.fly_stays(to, (x, y, n.lw * s, n.lh * s), self.look_from(st, s), e) {
    self.stays_told(to.at, to.at)
  }
}

///|
/// Departure `d` (the last of its id that moves) let go of where node `st` of its id stays: `st` set flying from where
/// `d`'s was drawn, as it looked, back to its own place, its picture as it draws it, its room as cut where it is; what
/// `d`'s was let go of with let go of as it would have been, its node drawn no more. Whether it flies.
fn Tree::to_stays(self : Tree, d : Departure, st : Int) -> Bool {
  guard self.alive_id(d.node) && self.alive_id(d.held) else { return false }
  let to : NodeId = { at: st, gen: self.nodes[st].gen }
  let e = self.stays_of(st, false)
  e.route = self.nodes[d.node.at].share_route
  if !self.fly_stays(to, d.from, d.look, e) {
    return false
  }
  // (what moved told of the way back, before it is let go of)
  self.stays_told(d.node.at, st)
  // (what moved drawn no more: taken out of what it was let go of with and let go of, the rest as it would have gone)
  let at = d.node.at
  if at != d.held.at {
    let g = self.nodes[at]
    let p = g.parent
    if p >= 0 {
      match self.nodes[p].kids.search(at) {
        Some(i) => self.nodes[p].kids.remove(i) |> ignore
        None => ()
      }
    }
    g.parent = -1
    self.handle(at).let_go()
    false
  } else {
    // (it alone let go of: let go of now, nothing left of it to go)
    self.handle(at).let_go()
    true
  }
}

///|
/// The one that moves at `mover` (View::shared's `told`) told of the flight of node `flies` with an end that stays that
/// set out now: when it set out and ends, and how far along its way it is at each moment.
fn Tree::stays_told(self : Tree, mover : Int, flies : Int) -> Unit {
  guard self.nodes[mover].share_told is Some(told) &&
    self.flying_of(flies) is Some(f) &&
    self.nodes[flies].lift is Some(l) &&
    l.stays is Some(_) else {
    return
  }
  let grown = fn(t : Double) {
    let ms = t - f.start
    let p = if ms <= 0.0 {
      0.0
    } else if ms >= f.dur {
      1.0
    } else {
      (f.along)(ms)
    }
    p
  }
  told(f.start, f.start + f.dur, grown)
}

///|
/// Node `to` set flying from `from` (where it sets out, how it looks there) to its place, one picture moving: not faded,
/// no old copy, `stays` its end that stays. Whether it flies (not, at once: as with motion reduced, or as far as nothing).
fn Tree::fly_stays(
  self : Tree,
  to : NodeId,
  from : (Double, Double, Double, Double),
  look : FromLook,
  stays : StaysEnd,
) -> Bool {
  self.fly_from(to, from, look, Some(stays), 0.0)
}

///|
/// Node `to` set flying from `from` (where it sets out, how it looks there) to its place, one thing moving: not faded,
/// no old copy, `stays` its end that stays where there is one (View::shared's; none: View::flies_in's). Its rise lags its
/// way across by `late` of its length (View::flies_in's `up_late`). Whether it
/// flies (not, at once: as with motion reduced, or as far as nothing).
fn Tree::fly_from(
  self : Tree,
  to : NodeId,
  from : (Double, Double, Double, Double),
  look : FromLook,
  stays : StaysEnd?,
  late : Double,
  from_fn? : (((Double, Double, Double, Double)) -> (Double, Double, Double, Double)?)? = None,
  within? : NodeId? = None,
  far_of? : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double)? = None,
  lead? : Bool = false,
  way? : (Double, (Double) -> Double)? = None,
) -> Bool {
  // (one flying in from what is none of the tree's on that way of its own, View::flies_in; else as it flies with
  // another of its id, View::shared)
  guard self.alive_id(to) else { return false }
  let flight = match (from_fn, self.nodes[to.at].in_flight) {
    (Some(_), Some(f)) => Some(f)
    _ => self.nodes[to.at].share_flight
  }
  guard flight is Some(flight) else { return false }
  let to_v = self.handle(to.at)
  let (tx, ty, tw, th) = to_v.laid_window_now()
  let (fx, fy, fw, fh) = from
  let dd = (fx - tx, fy - ty, fw - tw, fh - th)
  let far = flight_far(from, (tx, ty, tw, th), far_of)
  // (one with an end that stays: what it sets out between told its route, as far as that says it goes; none said, as far
  // as its furthest going edge goes)
  let far = match stays {
    Some(e) => {
      e.ends = { from, to: (tx, ty, tw, th), from_stays: e.at_start, clear: e.clear }
      match e.route {
        Some(r) => (r.far)(e.ends)
        None =>
          dmax(dmax((fx - tx).abs(), (fx + fw - tx - tw).abs()), dmax((fy - ty).abs(), (fy + fh - ty - th).abs()))
      }
    }
    None => far
  }
  // (one led by another of its Flight (View::flies_in's `lead`): that one's way, how far this one goes aside)
  let (ms, along) = match way {
    Some(w) => w
    None => (flight.way)(far)
  }
  let waits_old = stays is None && from_fn is Some(_) && self.holds_hosted(0)
  if ms <= 0.0 || (!waits_old && far <= 0.5) {
    return false
  }
  // (one already on its way: over, this one from where it was)
  match self.flying_of(to.at) {
    Some(f) => self.flight_over(f)
    None => ()
  }
  let at = self.cause_now()
  let top = self.top_node_of(to.at)
  // (where it is drawn among the rest as it sets out: its route's, else where it is held)
  let (level, foot) = match stays {
    Some({ route: Some(r), ends, foot, .. }) if foot >= 0 => ((r.level)(ends, 0.0), foot)
    _ => (Held, -1)
  }
  let f : Flying = {
    node: to,
    ghost: None,
    late,
    fades: false,
    from_fn,
    start: at,
    dur: ms,
    along,
    top,
    stop: fn() {  },
    stop_end: fn() {  },
    level,
    foot,
    far_of,
    lead,
    awaits_old: waits_old,
  }
  self.flights.push(f)
  // (set out from what is none of the tree's while an old view is hosted in it: refreshed against where it is laid out
  // once that view is next built (Tree::flights_refresh_now), whether or not anything else waits for it (a page come
  // in in this change, its composer in its list's foot laid at its height only as it is built))
  if waits_old {
    self.old_built_waits.push(fn(_) {  })
  }
  // (one whose node comes on a way its page said (a list key's `comes_way`, the flight's own rise): off its node by
  // where it set out, going with it, so that it and the list rise as one; any other from its fixed start)
  let fixed = if stays is None && !self.rides_said_way(to.at) { Some(from) } else { None }
  self.nodes[to.at].lift = Some({ follow: to.at, top, d: dd, late, k: 1.0, ky: 1.0, a: 1.0, from: look, stays, fixed, held_off: self.held_off(to.at), within })
  // (drawn as it sets out from the frame it does: its look the one it sets out with, not its own till its way is next
  // read (a frame drawn before that, as a host's while its list waits for the old view in its foot, drew its bubble's
  // ground whole where its bare words set out))
  self.lift_marked(to.at)
  if self.nodes[to.at].content is Some(_) {
    self.made_again(to.at)
  }
  self.lifted_order()
  let stop_way = self.queued(fn() { self.drawn_said() }, fn(t) { self.flight_at(f, t) })
  f.stop_end = to_v.at_moment(at + ms, fn() { self.flight_over(f) })
  let unkeep = to_v.owns_while(fn() { self.flight_over(f) })
  f.stop = fn() {
    stop_way()
    (f.stop_end)()
    unkeep()
  }
  self.flight_told(to.at)
  true
}

///|
/// Flights set out in the change whose hosted old views just laid out their new height (`Tree::old_waits_run`, after a
/// list's pinned foot ran `set_out` for that height): each flight's offset `d` and `held_off` refreshed against its
/// final laid-out place `to`, so a foot shrinking on send never shifts flying items down by the room it gave back.
fn Tree::flights_refresh_now(self : Tree) -> Unit {
  guard !self.flights.is_empty() else { return }
  let now = self.drawn_said()
  let mut laid = false
  // (those set out from what is none of the tree's that have not gone far yet, and where each sets out and goes now)
  let due : Array[(Flying, (Double, Double, Double, Double)?, (Double, Double, Double, Double))] = []
  for f in self.flights.copy() {
    guard f.awaits_old && self.alive_id(f.node) && f.from_fn is Some(from_fn) && now - f.start < 100.0 else { continue }
    f.awaits_old = false
    if !laid {
      self.laid_now() |> ignore
      laid = true
    }
    let to = self.handle(f.node.at).laid_window_now()
    due.push((f, from_fn(to), to))
  }
  // (the lead of each Flight set out at one moment (View::flies_in's `lead`): its way for how far it goes now, all of
  // that Flight's)
  let leads : Array[(Flight, Double, Flying, (Double, (Double) -> Double))] = []
  for d in due {
    let (f, from, to) = d
    guard f.lead && from is Some(from) && self.flight_of_node(f.node.at) is Some(fl) else { continue }
    let far = flight_far(from, to, f.far_of)
    let (ms, along) = (fl.way)(far)
    guard ms > 0.0 && far > 0.5 else { continue }
    leads.push((fl, f.start, f, (ms, along)))
  }
  // (the keys' blocks told their way anew in this pass: the first flight in one told it as it is now, the others in it
  // as the longest)
  let told : Array[Int] = []
  // (those still flying, where each sets out from and how far off where it is laid out)
  let going : Array[(Flying, (Double, Double, Double, Double), (Double, Double, Double, Double))] = []
  for d in due {
    let (f, from, to) = d
    guard from is Some(from) else {
      self.flight_over(f)
      continue
    }
    let dd = (from.0 - to.0, from.1 - to.1, from.2 - to.2, from.3 - to.3)
    let far = flight_far(from, to, f.far_of)
    if far <= 0.5 {
      self.flight_over(f)
      continue
    }
    // (as long as its flight says for how far it goes now, not for how far it was before that view laid out its
    // height: its end on the timeline with it, what reads how far along it is told so (View::flight_across_now),
    // and the key it carries told the same (Tree::carried); one led, as long as its lead and on its curve)
    let flight = self.flight_of_node(f.node.at)
    let led = match flight {
      Some(fl) =>
        leads.search_by(fn(l) { physical_equal(l.0, fl) && l.1 == f.start }).map(fn(x) { leads[x] })
      None => None
    }
    match flight {
      Some(fl) => {
        let (ms, along) = match led {
          Some((_, _, _, w)) => w
          None => (fl.way)(far)
        }
        if ms <= 0.0 {
          self.flight_over(f)
          continue
        }
        // (its curve as it is said for how far it goes now, as long or not)
        f.along = along
        if ms != f.dur {
          f.dur = ms
          (f.stop_end)()
          f.stop_end = self.handle(f.node.at).at_moment(f.start + ms, fn() { self.flight_over(f) })
          self.flight_told(f.node.at)
        }
      }
      None => ()
    }
    match led {
      Some((_, _, lf, _)) =>
        if physical_equal(lf, f) {
          self.carried(f.node.at, from, to, f.late, f.start, far_of=f.far_of, anew=true, lead=true)
        }
      None => {
        let row = self.carried_row(f.node.at)
        self.carried(f.node.at, from, to, f.late, f.start, far_of=f.far_of, anew=!told.contains(row))
        if row >= 0 {
          told.push(row)
        }
      }
    }
    going.push((f, from, dd))
  }
  // (all of them carried before any is drawn anew, so that what flies in a block is held off where the block is drawn
  // once carried, whichever of them came first)
  for g in going {
    let (f, from, dd) = g
    match self.nodes[f.node.at].lift {
      Some(l) => {
        l.d = dd
        l.fixed = if l.stays is None && !self.rides_said_way(f.node.at) { Some(from) } else { None }
        l.held_off = self.held_off(l.follow)
      }
      None => ()
    }
    self.flight_at(f, now)
  }
}

///|
/// The Flight node `at` flies on: its own in from outside the tree (View::flies_in), else the one it is shared by.
fn Tree::flight_of_node(self : Tree, at : Int) -> Flight? {
  match self.nodes[at].in_flight {
    Some(fl) => Some(fl)
    None => self.nodes[at].share_flight
  }
}

///|
/// Flight `f` drawn as of moment `t`: how much of its way is left and how far each is faded, both marked to be drawn so.
fn Tree::flight_at(self : Tree, f : Flying, t : Double) -> Unit {
  let ms = t - f.start
  let at = fn(ms : Double) {
    if ms <= 0.0 {
      0.0
    } else if ms >= f.dur {
      1.0
    } else {
      (f.along)(ms)
    }
  }
  // (across over the first of its length, its rise as long after it lags: one way where none)
  let p = at(ms / (1.0 - f.late))
  let k = 1.0 - p
  let ky = 1.0 - at((ms - f.late * f.dur) / (1.0 - f.late))
  // (the new one in over the first half of the way, the old one under it out over the second: never both half seen)
  let a_in = dmin(1.0, dmax(0.0, p * 2.0))
  let a_out = dmin(1.0, dmax(0.0, (1.0 - p) * 2.0))
  if self.alive_id(f.node) {
    match self.nodes[f.node.at].lift {
      Some(l) => {
        l.k = k
        l.ky = ky
        l.a = if f.fades { a_in } else { 1.0 }
        self.lift_marked(f.node.at)
        // (where its route draws it among the rest as far along: the order made again as that changes)
        match l.stays {
          Some({ route: Some(r), ends, .. }) if f.foot >= 0 => {
            let level = (r.level)(ends, p)
            if level != f.level {
              f.level = level
              self.lifted_order()
            }
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  match f.ghost {
    Some(g) if self.alive_id(g) =>
      match self.nodes[g.at].lift {
        Some(l) => {
          l.k = k
          l.ky = ky
          l.a = a_out
          self.lift_marked(g.at)
          // (what it is drawn over the rest of drawn again with it)
          if self.alive_id(f.node) {
            self.touched(f.node.at)
          }
        }
        None => ()
      }
    _ => ()
  }
}

///|
/// Node `at` on a flight's way moved along it: drawn again (its content as big as it is drawn there), composed again.
fn Tree::lift_marked(self : Tree, at : Int) -> Unit {
  let n = self.nodes[at]
  self.look_marked_at(at)
  self.fillers_marked(at)
  self.composed.push({ at, gen: n.gen })
  self.places_rev = self.places_rev + 1
  self.hits_bump()
}

///|
/// Where node `at` fills what holds it (laid out at its top left, as big as it is: a picture's box in its frame, the
/// frame what flies) and that is on a flight's way: how big its content is drawn there, as big as what holds it is (its
/// content in its own terms, Tree::lifted_content). Laid out at its own size it would be drawn only as tall as its own
/// shape scaled to the way's width, a 3:2 picture flying from a square tile drawn 56 by 37 in a 56 by 56 frame, its
/// foot cut flat (2026-11-15).
fn Tree::fills_lifted(self : Tree, at : Int) -> (Double, Double)? {
  let n = self.nodes[at]
  let p = n.parent
  guard p >= 0 && p < self.nodes.length() else { return None }
  let h = self.nodes[p]
  guard h.lift is Some(l) && h.lw > 0.0 && h.lh > 0.0 else { return None }
  guard n.lx.abs() < 0.5 && n.ly.abs() < 0.5 && (n.lw - h.lw).abs() < 0.5 && (n.lh - h.lh).abs() < 0.5 else {
    return None
  }
  let (_, _, w, hh) = self.lift_rect(l)
  let s = lift_scale(h, w)
  guard s > 0.0 else { return None }
  Some((w / s, hh / s))
}

///|
/// What fills node `at` (Tree::fills_lifted) made again as `at` is drawn otherwise on its way, or comes to its rest.
fn Tree::fillers_marked(self : Tree, at : Int) -> Unit {
  let n = self.nodes[at]
  for k in n.kids {
    let c = self.nodes[k]
    if c.live && c.lx.abs() < 0.5 && c.ly.abs() < 0.5 && (c.lw - n.lw).abs() < 0.5 && (c.lh - n.lh).abs() < 0.5 {
      self.look_marked_at(k)
    }
  }
}

///|
/// Flight `f` over (come to its end, set off again, or its new one let go of): the new one drawn where it is laid out
/// again, in its place, its old copy let go of.
fn Tree::flight_over(self : Tree, f : Flying) -> Unit {
  guard self.flights.search_by(fn(o) { physical_equal(o, f) }) is Some(i) else { return }
  self.flights.remove(i) |> ignore
  let stop = f.stop
  f.stop = fn() {  }
  stop()
  if self.alive_id(f.node) {
    self.flight_told(f.node.at)
    self.nodes[f.node.at].lift = None
    self.places_rev = self.places_rev + 1
    self.look_marked_at(f.node.at)
    self.fillers_marked(f.node.at)
    self.place_marked_at(f.node.at)
  }
  match f.ghost {
    Some(g) => {
      f.ghost = None
      if self.alive_id(g) {
        self.handle(g.at).let_go()
      }
    }
    None => ()
  }
  self.lifted_order()
}

///|
/// The flight node `at` is the new one of, if it is.
fn Tree::flying_of(self : Tree, at : Int) -> Flying? {
  self.flights.iter().find_first(fn(f) { f.node.at == at && self.alive_id(f.node) })
}

///|
/// Per-tree flight, `flips` list and foot-resize tables kept off `pub struct Tree` and `struct Node` so extending them
/// keeps `Tree`'s C layout unchanged across downstream packages.
priv struct TreeMotionAux {
  tree : Tree
  flip_rows : Map[Int, ((Double, (Double) -> Double), Bool, Bool) -> Unit]
  flip_gone : Map[Int, (View, Double) -> Double]
  feet_resized : Map[Int, Double]
  feet_lead : Map[Int, (Double, Bool)]
  flight_cells : Map[Int, (Int, @signals.Signal[Int])]
  pick_faders : Map[Int, Int]
}

///|
// kept across runs: each tree owns its entry until disposal (Tree::motion_aux)
let tree_motion_auxs : Array[TreeMotionAux] = []

///|
// kept across runs: last tree's entry for O(1) lookup, cleared when its tree disposes
let tree_motion_last : Ref[TreeMotionAux?] = Ref(None)

///|
fn Tree::motion_aux(self : Tree) -> TreeMotionAux {
  if tree_motion_last.val is Some(last) && physical_equal(last.tree, self) {
    return last
  }
  for aux in tree_motion_auxs {
    if physical_equal(aux.tree, self) {
      tree_motion_last.val = Some(aux)
      return aux
    }
  }
  let aux : TreeMotionAux = {
    tree: self,
    flip_rows: {},
    flip_gone: {},
    feet_resized: {},
    feet_lead: {},
    flight_cells: {},
    pick_faders: {},
  }
  tree_motion_auxs.push(aux)
  tree_motion_last.val = Some(aux)
  self.root().owns_while(fn() {
    if tree_motion_last.val is Some(last) && physical_equal(last, aux) {
      tree_motion_last.val = None
    }
    if tree_motion_auxs.search_by(fn(it) { physical_equal(it, aux) }) is Some(i) {
      tree_motion_auxs.remove(i) |> ignore
    }
  }) |> ignore
  aux
}

///|
fn Tree::mark_pick_fader(self : Tree, at : Int) -> Unit {
  let n = self.nodes[at]
  if n.live {
    self.motion_aux().pick_faders[at] = n.gen
  }
}

///|
fn Tree::is_pick_fader(self : Tree, at : Int) -> Bool {
  let n = self.nodes[at]
  n.live && self.motion_aux().pick_faders.get(at) == Some(n.gen)
}

///|
/// What reads node `at`'s flight (View::flying_now, View::flight_across_now) told it set out, was said anew or is
/// over: at those causes alone, never as it goes (what reads how far along it is follows the clock meanwhile).
fn Tree::flight_told(self : Tree, at : Int) -> Unit {
  let n = self.nodes[at]
  match self.motion_aux().flight_cells.get(at) {
    Some((gen, c)) if gen == n.gen => c.set(c.untracked() + 1)
    _ => ()
  }
}

///|
/// The flight of the node of `v` as what reads it reads it (View::flying_now, View::flight_across_now): followed as it
/// sets out, is said anew and is over (Tree::flight_told); none where it does not fly as the new one of a flight.
fn View::flight_read(self : View) -> Flying? {
  guard self.live() is Some(n) else { return None }
  let cells = self.tree.motion_aux().flight_cells
  let cell = match cells.get(self.at) {
    Some((gen, c)) if gen == n.gen => c
    _ => {
      let c = @signals.signal(0)
      cells[self.at] = (n.gen, c)
      c
    }
  }
  cell.get() |> ignore
  self.tree.flying_of(self.at)
}

///|
/// Whether it is on its way as the new one of a flight (View::shared, View::flies_in) now, followed: true from the
/// change that sets it out, false from the moment it is there (its end, as its flight says for how far it went),
/// told at those two causes alone, never by the clock. What goes with what flies (a time under a bubble that flies in)
/// shows by it.
pub fn View::flying_now(self : View) -> Bool {
  guard self.flight_read() is Some(f) else { return false }
  self.goes_now(fn(now) { now < f.start + f.dur })
}

///|
/// When its flight as the new one (View::shared, View::flies_in) ends on the clock (ms), followed as it sets out, is
/// said anew and is over; none where it is there, or flies not.
pub fn View::flight_ends_now(self : View) -> Double? {
  guard self.flight_read() is Some(f) else { return None }
  Some(f.start + f.dur)
}

///|
/// How far across its way it is as the new one of a flight (View::shared, View::flies_in), 0 to 1, where what is drawn
/// is drawn, followed: as its flight draws it across (Tree::flight_at: over the first of its length where its rise
/// lags), as long as its flight says for how far it goes; 1 where it is there, or flies not. What goes with what flies
/// (a time under a bubble flying in, faded in as it comes) reads it in its look, never a way and a length of its own:
/// one curve, one length, one clock.
pub fn View::flight_across_now(self : View) -> Double {
  guard self.flight_read() is Some(f) else { return 1.0 }
  let ends = f.start + f.dur
  let t = self.drawn_while(fn(now) { now < ends })
  guard t < ends else { return 1.0 }
  let ms = (t - f.start) / (1.0 - f.late)
  if ms <= 0.0 {
    0.0
  } else if ms >= f.dur {
    1.0
  } else {
    (f.along)(ms)
  }
}

///|
/// What is drawn on a flight's way, come or gone: the order made again whole (what flies drawn over the rest of its
/// layer, Tree::ordered), what is found where it is drawn with it.
fn Tree::lifted_order(self : Tree) -> Unit {
  self.order_whole = true
  self.order_due = true
  self.hits_bump()
  self.draws_rev = self.draws_rev + 1
  self.draws_any_rev = self.draws_any_rev + 1
  self.marked()
}

///|
/// What flies over the rest of layer `top` (the node of the root's at `me` in the order), in the order: each flight's old
/// copy, then its new one over it.
fn Tree::ordered_lifted(self : Tree, top : Int, me : Int) -> Unit {
  for f in self.flights {
    if f.top != top {
      continue
    }
    match f.ghost {
      Some(g) if self.alive_id(g) => {
        self.lifting = true
        self.ordered(g.at, me, top)
      }
      _ => ()
    }
    if self.alive_id(f.node) && f.node.at != top && !self.under_foot(f) {
      match self.nodes[f.node.at].lift {
        Some(l) if !self.lifted_over(self.nodes[f.node.at], l) => ()
        _ => {
          self.lifting = true
          self.ordered(f.node.at, me, top)
        }
      }
    }
  }
  self.lifting = false
}

///|
/// Whether flight `f` is drawn under the foot pinned over the column that scrolls its end that stays now (its route's
/// `level`), that foot there to be drawn over it.
fn Tree::under_foot(self : Tree, f : Flying) -> Bool {
  f.level == UnderFoot && f.foot >= 0 && f.foot < self.nodes.length() && self.nodes[f.foot].live
}

///|
/// Whether node `at` is the one that moves of a flight drawn under a foot now (Tree::under_foot): put in the order
/// just before that foot (Tree::ordered), not where it is held.
fn Tree::flies_under_foot(self : Tree, at : Int) -> Bool {
  self.flights.iter().any(fn(f) { f.node.at == at && self.alive_id(f.node) && self.under_foot(f) })
}

///|
/// Whether node `n`, on flight `l`'s way, is drawn over the rest of its layer: all are but the one that moves of a
/// flight with an end that stays (the picture opened over everything from its thumbnail, and back), drawn where it is
/// held, what is drawn after it in its layer (its viewer's bar) over it, where the flight has it.
fn Tree::lifted_over(self : Tree, n : Node, l : Lift) -> Bool {
  ignore(self)
  !(l.stays is Some(_) && !n.share_stays)
}

///|
/// Node `at` let go of: a flight it is the new one of over (its old copy let go of), its id no more counted.
fn Tree::share_let_go(self : Tree, at : Int) -> Unit {
  let n = self.nodes[at]
  match n.share {
    Some(id) => {
      self.share_counted(at, id, -1)
      n.share = None
    }
    None => ()
  }
  n.share_stays = false
  n.share_with_stays = false
  n.share_told = None
  n.share_route = None
  n.share_flight = None
  n.in_flight = None
  if n.lift is Some(_) {
    match self.flying_of(at) {
      Some(f) => self.flight_over(f)
      None => ()
    }
    n.lift = None
    self.places_rev = self.places_rev + 1
  }
}

///|
/// The pictures asked for (View::image_ask) since this was last done, asked of what hosts the tree now, each where the
/// node that asked still stands in the window's tree, each once: one made and let go of before now (in a change told
/// in parts, or in one pass of a layout and gone in a later, a page's list's block) has nothing asked. Done as a change
/// ends, the outermost (Tree::change_ended), and as a frame's layout ends outside every change (Tree::brought).
fn Tree::images_asked_now(self : Tree) -> Unit {
  if self.images_wanted.is_empty() {
    return
  }
  let wanted = self.images_wanted.copy()
  self.images_wanted.clear()
  let asked : Array[(String, Double)] = []
  for w in wanted {
    let (id, src, px) = w
    if self.alive_id(id) && self.attached(id.at) && !asked.contains((src, px)) {
      asked.push((src, px))
      (self.env.image_ask)(src, px)
    }
  }
}

///|
/// A change of the tree ended (an event told, a moment come on the timeline, a change at its cause, a structure's, a
/// binding's run at the moment it was told; one told outside every event, as where things stand is settled after it:
/// Tree::settle_now): the pictures asked for in it (View::image_ask) asked now, where it was the outermost and no layout
/// is under way (a frame's ends in Tree::brought, which asks for what its passes left standing).
/// Nothing asked for, nothing done but this test.
fn Tree::change_ended(self : Tree) -> Unit {
  if self.images_wanted.is_empty() || self.in_change() || self.laying || self.draining > 0 {
    return
  }
  self.images_asked_now()
}

///|
/// Node `at`, flying in from `from` to `to` (its place in the window as the change lays it out) with its rise `late`:
/// where it lies in the block of a key a page's list brings by data in this change (Tree's carried_rows), that key is
/// carried by it: told the flight's way, as long as the flight and on the curve its rise goes, which that list's one way
/// of this moment then goes on. The cause says where it comes from; the list does the rest (the user, 2026-11-10: the
/// row grows on the same curve and length as the words leave the field; 2026-11-15). How far it goes by `far_of`
/// (View::flies_in's); `anew`: said again for where it goes now (Tree::flights_refresh_now), taken shorter or not;
/// `lead`: by the lead of its Flight, whose way no other of that moment takes the place of.
fn Tree::carried(
  self : Tree,
  at : Int,
  from : (Double, Double, Double, Double),
  to : (Double, Double, Double, Double),
  late : Double,
  cause : Double,
  far_of? : (((Double, Double, Double, Double), (Double, Double, Double, Double)) -> Double)? = None,
  anew? : Bool = false,
  lead? : Bool = false,
) -> Unit {
  guard self.flight_of_node(at) is Some(flight) else { return }
  let p = self.carried_row(at)
  guard p >= 0 else { return }
  let far = flight_far(from, to, far_of)
  let (ms, along) = (flight.way)(far)
  guard ms > 0.0 && far > 0.5 else { return }
  // (its rise: what flight_at draws its way down or up by, as a share of the time of all of it)
  let rise = fn(x : Double) {
    let m = (x * ms - late * ms) / (1.0 - late)
    if m <= 0.0 {
      0.0
    } else if m >= ms {
      1.0
    } else {
      along(m)
    }
  }
  match self.carried_rows.get(p) {
    Some(tell) if self.carried_row_now(p) => tell((ms, rise))
    _ =>
      match self.motion_aux().flip_rows.get(p) {
        Some(tell) => tell((ms, rise), anew, lead)
        None =>
          match self.flip_rows.get(p) {
            Some(tell) => tell((ms, rise))
            None => ()
          }
      }
  }
  self.feet_carried(p, cause, (ms, rise), anew~, lead~)
}

///|
/// Whether row `p`'s key comes by data in the change committed now (Tree's carried_rows: one carried by a flight).
fn Tree::carried_row_now(self : Tree, p : Int) -> Bool {
  self.carried_rows.contains(p) && self.nodes[p].live && self.nodes[p].flex.style.come_at == self.cause_now()
}

///|
/// The row or block of a page's list node `at` lies in that a flight in to it carries (Tree::carried): its key's come
/// by data in the change committed now (carried_rows), else a block of a list said `flips` (flip_rows); -1 none.
fn Tree::carried_row(self : Tree, at : Int) -> Int {
  let flip_rows = self.motion_aux().flip_rows
  let mut p = at
  while p >= 0 {
    if self.carried_row_now(p) || flip_rows.contains(p) || self.flip_rows.contains(p) {
      return p
    }
    p = self.nodes[p].parent
  }
  -1
}

///|
/// A key of a page's list carried in by a flight set out at `cause` (Tree::carried; `slot`, its block's), on `way`:
/// what in that list's pinned foot said its height goes its way at that moment on no way said with it
/// (View::resizes, `foot`: the composer giving back what it held as the words fly up out of it) goes on the same way,
/// as long, rising with the rows over it as one (the user, 2026-11-17: 发送回缩 on the rows' own curve, never one of its
/// own beside theirs).
fn Tree::feet_carried(
  self : Tree,
  slot : Int,
  cause : Double,
  way : (Double, (Double) -> Double),
  anew? : Bool = false,
  lead? : Bool = false,
) -> Unit {
  let aux = self.motion_aux()
  let resized = aux.feet_resized
  guard !resized.is_empty() && !self.list_feet.is_empty() else { return }
  // (the list's feet: those whose held column holds the slot)
  let feet : Array[Int] = []
  for foot, held in self.list_feet {
    let mut p = slot
    while p >= 0 && p != held {
      p = self.nodes[p].parent
    }
    if p >= 0 && self.nodes[foot].live {
      feet.push(foot)
    }
  }
  guard feet.length() > 0 else { return }
  for at, t in resized.copy() {
    guard t == cause && self.nodes[at].live && self.nodes[at].coming else { continue }
    let st = self.nodes[at].flex.style
    guard st.come_at == t else { continue }
    let mut p = at
    while p >= 0 && !feet.contains(p) {
      p = self.nodes[p].parent
    }
    guard p >= 0 else { continue }
    let keep = match (self.come_ways_lead.get(at), aux.feet_lead.get(at)) {
      (Some(w0), Some((t0, l0))) if !lead &&
        t0 == cause &&
        (l0 || (!anew && w0.0 > way.0)) => true
      _ => false
    }
    if keep {
      continue
    }
    aux.feet_lead[at] = (cause, lead)
    let m = self.nodes[at]
    st.come_spec = Some(way)
    // (its group's way as well when the group is settled after this (Tree::come_group_settle), as a row's: lead_way)
    self.come_ways_lead[at] = way
    match st.come_group {
      Some(g) => {
        g.spec = Some(way)
        if g.set {
          @flex.come_group_set(g)
        }
      }
      None => st.come_ends = st.come_at + way.0
    }
    // (done at its end as it is now, sooner or later than the Move it was said on)
    if st.come_ends == st.come_ends {
      let v = self.handle(at)
      (m.come_off)()
      m.come_off = v.at_moment(st.come_ends, fn() { come_done(self, v, m) })
    }
    self.marked()
  }
}

///|
/// Row `at` of a page's list, its key coming by data, carried by a flight (Tree::carried): its way and its group's on
/// `way`, said at its cause's moment still, before any frame draws it (flex's ComeGroup `spec`).
fn Tree::lead_way(self : Tree, at : Int, way : (Double, (Double) -> Double)) -> Unit {
  guard self.nodes[at].live else { return }
  let n = self.nodes[at]
  let st = n.flex.style
  n.list_key_way = true
  st.come_spec = Some(way)
  self.come_ways_lead[at] = way
  match st.come_group {
    Some(g) => {
      g.spec = Some(way)
      if g.set {
        @flex.come_group_set(g)
      }
    }
    None => if st.come_at == st.come_at {
      st.come_ends = st.come_at + way.0
    }
  }
  self.marked()
}

///|
/// How far what holds node `at` is drawn off where it is laid out (View::drawn_off of each that holds it, summed).
fn Tree::held_off(self : Tree, at : Int) -> (Double, Double) {
  let mut x = 0.0
  let mut y = 0.0
  let mut i = self.nodes[at].parent
  while i >= 0 {
    let (a, b) = self.nodes[i].look.drawn_off
    x = x + a
    y = y + b
    i = self.nodes[i].parent
  }
  (x, y)
}
