// What is put into a draft from outside its composer (the system's picker answering, files shared into the app, a
// message's file quoted from its menu, a visualization's words to send, what was marked on a page or an image, a 文件
// row put in or let go on the chat), one way whichever view draws the composer: given by the draft's key (draft_give),
// it waits for that draft's composer; a composer that takes what it is given at its moment (one made as nodes) says
// so while it shows (draft_taker) and is told at once, an old view's takes it as it is next built (draft_given wakes
// it, draft_taken hands it over), the same thing either way.

///|
/// Something put into a draft from outside its composer: files the system's picker answered (Picked), files shared
/// into the app (Shared), a message's file quoted (Quoted: whose, the message's ts, its role, the file as the core
/// gives it), words a visualization asked to send (Followed), a marked picture with its quotes (Marked: its name, its
/// bytes, each quote's title, what and comment, "page" or "image"), a 文件 row (Dropped).
pub(all) enum Given {
  Picked(Array[@hostapi.Picked])
  Shared(Array[@hostapi.Picked])
  Quoted(String, String, String, Json)
  Followed(String)
  Marked(String, Bytes, Array[(String, String, String)], String)
  Dropped(Dragged)
}

///|
/// What waits for each draft's composer, by its key, in the order it was given.
// kept across runs: emptied by writings_reset (sfbase's reset)
let given_waiting : Map[String, Array[Given]] = Map([])

///|
/// The composers taking what they are given at its moment, by their draft's key (draft_taker).
// kept across runs: emptied by writings_reset (sfbase's reset); each let go with what said it
let given_takers : Map[String, () -> Unit] = Map([])

///|
/// `g` put into draft `key`: waiting for its composer, which is told (taken now by one that takes it so, else as its
/// old view is next built).
pub fn draft_give(key : String, g : Given) -> Unit {
  match given_waiting.get(key) {
    Some(list) => list.push(g)
    None => given_waiting[key] = [g]
  }
  draft_given(key)
  match given_takers.get(key) {
    Some(take) => take()
    None => ()
  }
}

///|
/// `gs` given to draft `key` at once (draft_give's, all of them before its composer is told): files let go together
/// taken in as one drop, as the old composer took them.
fn draft_give_all(key : String, gs : Array[Given]) -> Unit {
  if gs.is_empty() {
    return
  }
  match given_waiting.get(key) {
    Some(list) => list.append(gs)
    None => given_waiting[key] = gs.copy()
  }
  draft_given(key)
  match given_takers.get(key) {
    Some(take) => take()
    None => ()
  }
}

///|
/// All that waits for draft `key`'s composer, handed over in the order it was given, waiting no more; read so (what
/// builds an old view's composer built again as more comes).
pub fn draft_taken(key : String) -> Array[Given] {
  drafts_given_read(key)
  match given_waiting.get(key) {
    Some(list) => {
      given_waiting.remove(key)
      drafts_given.remove(key)
      list
    }
    None => []
  }
}

///|
/// Draft `key`'s composer takes what it is given at its moment while it shows: `take` told each time something comes,
/// and at once where something waits already. What it gives back lets it go (its composer gone).
pub fn draft_taker(key : String, take : () -> Unit) -> () -> Unit {
  given_takers[key] = take
  if given_waiting.contains(key) {
    take()
  }
  fn() {
    match given_takers.get(key) {
      Some(t) if physical_equal(t, take) => given_takers.remove(key)
      _ => ()
    }
  }
}

///|
/// Whether something waits for draft `key`'s composer (what a test reads).
pub fn draft_waiting(key : String) -> Array[Given] {
  given_waiting.get(key).unwrap_or([])
}

///|
/// What was given and taken let go of (as a run starts: writings_reset).
fn given_reset() -> Unit {
  given_waiting.clear()
  given_takers.clear()
}

///|
/// The 文件 rows put into chat `chat`'s draft (files_into) waiting for its composer, taken out of what waits: the rest
/// waits on (what a test reads of what a press put in).
pub fn files_taken(chat : String) -> Array[Dragged] {
  let all = given_waiting.get(chat).unwrap_or([])
  let rows = all.filter_map(fn(g) {
    match g {
      Dropped(d) => Some(d)
      _ => None
    }
  })
  let rest = all.filter(fn(g) { !(g is Dropped(_)) })
  if rest.is_empty() {
    given_waiting.remove(chat)
  } else {
    given_waiting[chat] = rest
  }
  rows
}
