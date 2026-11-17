// How many layout passes the tree ran (Tree::laid_out, each that laid out or placed something: Work's `passes`; one
// that only ran bindings or changed looks is none), and, where the tree keeps sources (a Tester's), what ran each: run
// again inside another for what it told as it ended (`again_names`), or what laid the tree out (`pass_vias`), with the
// node whose layout was first marked for it and the node whose binding was first due in it, each said where it was
// made, and the moment it laid out as of. For a Tester to hold each cause to a few passes, by its moment (each event
// taken whole; outside them each moment: a frame's, each come due on the timeline, the changes told at one moment
// together) and say where one ran more (ui's tester_passes.mbt): a change committed piece by piece, each piece laying
// the tree out again (#6525: a frame's 28 answers each settled as a change of its own at one moment, 56 passes), is
// found by every test that does it, with no count of its own written, whatever rate its frames come at.

///|
/// What laid the tree out outside any pass (Tree's `pass_via`, in this order): a frame (Tree::frame), an input brought to
/// its moment (Tree::bring_to), where things are as of now for what reads them (Tree::laid_now), settled once a change
/// was told whole (Tree::settle_now), what is under the pointer after that (Tree::withins_restored).
let pass_vias : FixedArray[String] = [
  "frame", "brought", "now", "settled", "pointer", "now for the pointer", "now for the pointer on the timeline", "now for a wheel",
  "now for what is asked", "now for a drag", "now for what the focus holds", "now for what shows across", "now as asked",
  "now for the hand through",
]

///|
/// The next pass run again inside one for what `again_names[k]` names (Tree::laid_out).
fn Tree::again_said(self : Tree, k : Int) -> Unit {
  self.work.again[k] += 1
  self.pass_again = k
}

///|
/// A pass, said by its causes (Tree::pass_logged): what ran it again inside another (`again_names`' index, -1 none),
/// what laid the tree out outside any (`pass_vias`' index, -1 none), the node whose layout was first marked for it and
/// the node whose binding was first due in it (-1 none), the moment it laid out as of, and whether an event taken whole
/// ran it.
struct PassSaid {
  again : Int
  via : Int
  laid : Int
  bound : Int
  at : Double
  in_event : Bool
}

///|
/// A pass that laid out or placed something as of `upto` (Tree::laid_out), `bound` its first binding's node: kept, with
/// what ran it, and counted to its moment where no event runs it (Tree::moment_passes_taken). Where the tree keeps
/// sources.
fn Tree::pass_logged(self : Tree, upto : Double, bound : Int) -> Unit {
  let in_event = self.in_events > 0
  self.pass_log.push({
    again: self.pass_again,
    via: self.pass_via,
    laid: self.layout_first,
    bound,
    at: upto,
    in_event,
  })
  self.pass_via = -1
  self.pass_again = -1
  self.layout_first = -1
  if !in_event {
    for i, m in self.moment_passes {
      if m.0 == upto {
        self.moment_passes[i] = (upto, m.1 + 1)
        return
      }
    }
    self.moment_passes.push((upto, 1))
  }
}

///|
/// The moment outside events taken whole that the most passes laid out as of since this was last asked, and how many
/// (each moment a cause of its own: a frame's, each moment come due on its timeline, each change a test or a host told
/// at a moment; passes of one moment told change by change add up): (-1, 0) none. Where the tree keeps sources. Taken.
pub fn Tree::moment_passes_taken(self : Tree) -> (Double, Int) {
  let mut most = (-1.0, 0)
  for m in self.moment_passes {
    if m.1 > most.1 {
      most = m
    }
  }
  self.moment_passes.clear()
  most
}

///|
/// The layout passes the tree ran so far (Work's `passes`, without copying the rest of it).
pub fn Tree::passes_run(self : Tree) -> Int {
  self.work.passes
}

///|
/// What ran each pass since this was last asked, each said as a line (where the tree keeps sources; else none): what it
/// was run again for, or what laid the tree out, and where what was marked first for it and what was first due in it
/// were made; only those of moment `at` outside events where it is said, of the events where `events`. Taken: the next
/// asking says those after.
pub fn Tree::passes_said(self : Tree, at? : Double, events? : Bool = false) -> Array[String] {
  let said : Array[String] = []
  for p in self.pass_log {
    match at {
      Some(t) if p.in_event || p.at != t => continue
      _ => ()
    }
    if events && !p.in_event {
      continue
    }
    let why = if p.again >= 0 && p.again < again_names.length() {
      "again for " + again_names[p.again]
    } else if p.via >= 0 && p.via < pass_vias.length() {
      pass_vias[p.via]
    } else {
      "own"
    }
    let place = fn(at : Int) -> String {
      if at < 0 || at >= self.nodes.length() || !self.nodes[at].live {
        return ""
      }
      let n = self.nodes[at]
      let (made, part) = self.source_of({ at, gen: n.gen })
      if part != "" {
        "\{made} (in \{part})"
      } else {
        made
      }
    }
    let laid_at = place(p.laid)
    let bound_at = place(p.bound)
    said.push(
      why +
      (if laid_at != "" { " laid " + laid_at } else { "" }) +
      (if bound_at != "" { " bound " + bound_at } else { "" }),
    )
  }
  self.pass_log.clear()
  said
}

///|
/// An event taken whole (Tree::event_said, outside any other) ran `n` passes.
fn Tree::event_passes_counted(self : Tree, n : Int) -> Unit {
  self.event_passes += n
  if n > self.event_passes_most {
    self.event_passes_most = n
  }
}

///|
/// The passes run in the events taken whole since this was last asked, all of them and the most one ran: what of the
/// passes since then was run by the host's events, each a cause of its own between frames, not by the frame. Taken.
pub fn Tree::event_passes_taken(self : Tree) -> (Int, Int) {
  let n = (self.event_passes, self.event_passes_most)
  self.event_passes = 0
  self.event_passes_most = 0
  n
}
