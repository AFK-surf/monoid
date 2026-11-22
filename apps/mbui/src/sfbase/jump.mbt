// A message a chat is to show: a row's state line pressed where the core says what its
// state is about, a notification's, a search's. Asked for here as the chat is opened (by either frame); its page takes
// it once the message is in, goes there and flashes it.

///|
/// The message each chat is to go to once its list is in place (Screen.Chat.at: a notification's), by chat.
pub let go_tos : Map[String, Double] = Map([])

///|
/// Told as a chat is given a message to go to (go_to, go_back_to): what goes there as it is told (a chat's page made as
/// nodes, chat_goes_to) looks again.
// kept across runs: a count, only compared
pub let go_tos_said : @signals.Signal[Int] = @signals.signal(0)

///|
/// The chat `r`, once open and in place, goes to its message `seq` (the pages before it brought in until it is
/// there), which flashes: only the `passage` of it a quote quoted, where its words
/// have it (Chat.tsx Quotes' jump); the whole message else.
/// Gone to inside the chat as it shows, placed, more than a list's height from its end (`keep_place`: not where the
/// go-to opens the chat, a notification's, a search's): where the reader was is kept (place_kept), unless a place is
/// kept already, for the way to the newest to go back to first.
pub fn go_to(r : ChatRef, seq : Double, passage? : String = "", keep_place? : Bool = true) -> Unit {
  let k = r.station + "\u{1}" + r.session
  if keep_place {
    keep_place_of(k)
  }
  go_tos[k] = seq
  go_tos_said.set(go_tos_said.untracked() + 1)
  if passage.trim(chars=" \n\t") != "" {
    go_to_passages[k] = passage
  } else {
    go_to_passages.remove(k)
  }
}

///|
/// The message each chat's window was moved about as it was asked to go to it (go_to_quoted's `chat.around`), by chat:
/// what goes there (a chat's page made as nodes, chat_goes_to) asks it no more.
pub let go_to_around : Map[String, Double] = Map([])

///|
/// The message of chat `r` a quote's card quotes (its `ts`) gone to, the `passage` it quotes lit there (go_to): where
/// what is shown holds it (`shown`: its seq, none where not) at once; else the chat's window moved about it
/// (`chat.around` by its ts, the chat's `thread`: read onto the device where it is not), then gone to; where the chat has
/// it nowhere (or the core could not say), said in a toast.
pub fn go_to_quoted(src : Source, r : ChatRef, thread : Double?, shown : Double?, ts : String, passage : String) -> Unit {
  match shown {
    Some(seq) => {
      go_to(r, seq, passage~)
      return
    }
    None => ()
  }
  let gone = fn() { toast_later(@sf.t("web-main.quote.gone")) }
  guard thread is Some(th) && ts != "" else { return gone() }
  act(
    src,
    @sf.t("web-main.quote.jump"),
    "",
    "chat.around",
    { "station": Json::string(r.station), "thread": Json::number(th), "ts": Json::string(ts) },
    ok=fn(v) {
      match v {
        Object(o) if o.get("seq") is Some(Number(seq, ..)) => {
          go_to_around[r.station + "\u{1}" + r.session] = seq
          go_to(r, seq, passage~)
        }
        _ => gone()
      }
    },
  )
}

///|
/// The passage of the message each chat is to go to that is to flash alone (go_to), by chat.
pub let go_to_passages : Map[String, String] = Map([])

///|
/// The words a search opened each chat at its message with (Screen.Chat.words), by chat: marked in
/// that message rather than it flashing.
pub let go_to_words : Map[String, Array[String]] = Map([])

///|
/// The chat `r` opened from a search at its message `seq`, the search's `words` marked there (Search.kt FoundRow,
/// Switcher.tsx's found message).
pub fn open_chat_found(r : ChatRef, seq : Double, words : Array[String]) -> Unit {
  // (the words said before the go-to, which a chat's page made as nodes and open takes as it is said)
  if words.length() > 0 {
    go_to_words[r.station + "\u{1}" + r.session] = words
  }
  go_to(r, seq, keep_place=false)
  open_page(Chat(r))
}

///|
/// Where the reader was in each chat as a go-to inside it took its list away (go_to): the message at the top of what
/// showed and how far its top was below the list's (as kept_places keeps a place), by chat. The way to the newest goes
/// back there first (go_back_to), then to the end; at the end, sending, `chat.latest` forget it (place_forget).
// kept across runs: put back by the package's reset (pages.mbt)
pub let places_back : Map[String, (Double, Double)] = Map([])

///|
/// Of the places kept to go back to (places_back), where the page that kept it draws the message at its top in pieces:
/// which piece was at the top and how far its top was below the list's, by chat (a page made as nodes alone).
// kept across runs: put back by the package's reset (pages.mbt)
pub let places_back_pieces : Map[String, (Int, Double)] = Map([])

///|
/// Told as a place is kept or forgotten: what says the way to the newest (its tip, its name) built again.
// kept across runs: a count, only compared
pub let places_back_said : @signals.Signal[Int] = @signals.signal(0)

///|
/// The offset each chat's list goes back to its place at (go_back_to): the message gone to then is put there, its top that
/// far under the list's, not flashing (list_after).
// kept across runs: put back by the package's reset (pages.mbt)
pub let go_back_offsets : Map[String, Double] = Map([])

///|
/// The piece of the message each chat's list goes back to (go_back_to), where the place kept said one: that piece and
/// its own top's offset, as kept (a page made as nodes alone; go_back_offsets stays the whole message's, the old page's).
// kept across runs: put back by the package's reset (pages.mbt)
pub let go_back_pieces : Map[String, (Int, Double)] = Map([])

///|
/// Where the reader was is kept for chat `k` (go_to's): its list showing, placed, more than its own height from the
/// chat's end as it was last laid out (Reading's `far`: the window short of the chat's end, or its last row that far
/// under the view), none kept yet. A chat's page says its list is placed only while it shows (sfpages' chat_goes_to).
fn keep_place_of(k : String) -> Unit {
  guard !places_back.contains(k) else { return }
  guard readings.get(k) is Some(rd) &&
    rd.placed &&
    rd.top_seq >= 0.0 &&
    rd.far else {
    return
  }
  places_back[k] = (rd.top_seq, rd.top_off)
  if rd.top_piece >= 0 {
    places_back_pieces[k] = (rd.top_piece, rd.top_piece_off)
  } else {
    places_back_pieces.remove(k)
  }
  places_back_said.set(places_back_said.untracked() + 1)
}

///|
/// Whether chat `k` (station and session, \u{1} between) keeps a place to go back to: read, what reads it told as that
/// changes.
pub fn place_kept(k : String) -> Bool {
  places_back_said.get() |> ignore
  places_back.contains(k)
}

///|
/// Chat `k`'s kept place forgotten (its end reached, words sent, `chat.latest`).
pub fn place_forget(k : String) -> Unit {
  places_back_pieces.remove(k)
  if places_back.contains(k) {
    places_back.remove(k) |> ignore
    places_back_said.set(places_back_said.untracked() + 1)
  }
}

///|
/// Chat `r`'s list back to the place kept (none: false), not flashing, and the place forgotten.
pub fn go_back_to(r : ChatRef) -> Bool {
  let k = r.station + "\u{1}" + r.session
  match places_back.get(k) {
    Some((seq, off)) => {
      let piece = places_back_pieces.get(k)
      place_forget(k)
      go_tos[k] = seq
      go_to_passages.remove(k) |> ignore
      go_to_words.remove(k) |> ignore
      go_back_offsets[k] = off
      match piece {
        Some(p) => go_back_pieces[k] = p
        None => go_back_pieces.remove(k)
      }
      go_tos_said.set(go_tos_said.untracked() + 1)
      true
    }
    None => false
  }
}
