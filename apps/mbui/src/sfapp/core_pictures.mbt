// Pictures by their address as the core gives them (`picture`: a person's account's, a station's or a workspace's
// icon; Android's Parts.kt rememberPicture, rememberStationPicture), kept as images for the app's life. One that could
// not be had (the network down a moment) is asked for again as Android's is: when it is put up anew (Compose's
// produceState, run as its picture comes into the composition: its page put on top again), not while it stays up;
// the core answers that it could not until its own while has passed (core-ts asks.ts PICTURE_RETRY_MS), then fetches
// it again. Anew is said by its page (Ctx::page_stint: its time on top, a number of its own each time it is put
// there), not by the frames drawn: a run and its replay draw different frames (a slide's), and ask the same.

///|
/// Pictures by their address, as Source.picture gives them: `(url, stint)`, put up on a page in its time on top
/// `stint` (Ctx::page_stint), is an image's key once it is here, "" until then. `ask(url, done)` asks the core's
/// `picture` (`done` gets its bytes, or None when it could not be had). One that could not be had is asked again once
/// for each time on top of a page it is put up on since.
pub fn core_pictures(ask : (String, (Bytes?) -> Unit) -> Unit) -> (String, Int) -> String {
  core_pictures_waited(ask, fn(_, done) { done(None) }).shown
}

///|
/// Pictures by their address as core_pictures gives them (`shown`), and whether a page opening waits for one (`waits`,
/// Source.picture_waits): one the device holds, while the core reads it or its decode is not done; never one the
/// device has not (the network's to bring: shown as it comes, as before) nor one that could not be had.
pub(all) struct CorePictures {
  shown : (String, Int) -> String
  waits : (String) -> Bool
}

///|
/// How large a face waited for is decoded ahead (CorePictures' `waits`), on its longer side: as large as a person's in a
/// chat's bar or over their messages is drawn at three pixels a point (28 at most), so it stands in for the decode its
/// own drawing asks till that is done (mbui's image_for).
let face_ahead_px : Double = 128.0

///|
/// core_pictures', with what a page opening waits for of them (CorePictures): `kept(url, done)` asks the core's
/// `picture` as the device holds it (`kept: true`: at once, never waiting on the network; no bytes where it has none,
/// its fetch set off for the asking that follows, which `shown` makes as ever).
pub fn core_pictures_waited(
  ask : (String, (Bytes?) -> Unit) -> Unit,
  kept : (String, (Bytes?) -> Unit) -> Unit,
) -> CorePictures {
  // an address's image key once here, "" while it is asked
  let keys : Map[String, String] = Map([])
  // those that could not be had
  let failed : Map[String, Bool] = Map([])
  // those asked as the device holds them (`kept`): on their way (true), or not on the device (false)
  let held : Map[String, Bool] = Map([])
  // each address with each page's time on top it was put up in (an address on two pages at once, each its own)
  let put_up : Map[String, Bool] = Map([])
  // each address's answers so far, followed by all that read it (a node of the window's tree shown by it, read again as
  // its answer comes, whoever asked: an old view reads it every frame it is built)
  let answers : Map[String, @signals.Signal[Int]] = Map([])
  let answered = fn(url : String) -> @signals.Signal[Int] {
    match answers.get(url) {
      Some(s) => s
      None => {
        let s = @signals.signal(0)
        answers[url] = s
        s
      }
    }
  }
  // (the key an address's image is put up as)
  let key_of = fn(url : String) { "mem:picture/\{@ui.stable_hash(url)}/\{url.length()}" }
  let shown = fn(url : String, page : Int) -> String {
    answered(url).get() |> ignore
    let at = "\{page}\u{1}" + url
    let anew = !put_up.contains(at)
    put_up[at] = true
    match keys.get(url) {
      Some(key) => key
      None => {
        if failed.contains(url) && !anew {
          return ""
        }
        failed.remove(url)
        keys[url] = ""
        // (this asking's own: an answer given at once told once it is in, not from within the asking)
        let asking = Ref(true)
        let told = fn() {
          let s = answered(url)
          s.set(s.untracked() + 1)
        }
        ask(url, fn(bytes) {
          match bytes {
            Some(b) if b.length() > 0 => {
              let key = key_of(url)
              @ui.add_image(key, b)
              keys[url] = key
            }
            _ => {
              keys.remove(url)
              failed[url] = true
            }
          }
          // (told to all that read it: at once where it came later, else as the asking ends)
          if asking.val {
            asking.val = false
          } else {
            told()
          }
        })
        // (answered at once: told to the others that read it too, now it is in)
        if !asking.val {
          told()
        }
        asking.val = false
        // (answered at once: its key already)
        keys.get(url).unwrap_or("")
      }
    }
  }
  {
    shown,
    waits: fn(url) {
      answered(url).get() |> ignore
      match (keys.get(url), held.get(url)) {
        // (here: its decode asked for now if nothing drew it yet, as what waits for it is not built where it shows)
        (Some(key), _) if key != "" => {
          @ui.image_decode_ahead(key, face_ahead_px)
          @ui.image_decoding(key)
        }
        // (the core reading it as the device holds it)
        (_, Some(true)) => true
        // (not on the device: the network's to bring, as it is shown; or one that could not be had)
        (_, Some(false)) => false
        _ if failed.contains(url) => false
        _ => {
          held[url] = true
          let asking = Ref(true)
          kept(url, fn(bytes) {
            match bytes {
              Some(b) if b.length() > 0 => {
                held.remove(url)
                if keys.get(url).unwrap_or("") == "" {
                  @ui.add_image(key_of(url), b)
                  keys[url] = key_of(url)
                }
              }
              _ => held[url] = false
            }
            if asking.val {
              asking.val = false
            } else {
              let s = answered(url)
              s.set(s.untracked() + 1)
            }
          })
          asking.val = false
          match (keys.get(url), held.get(url)) {
            (Some(key), _) if key != "" => {
              @ui.image_decode_ahead(key, face_ahead_px)
              @ui.image_decoding(key)
            }
            (_, Some(true)) => true
            _ => false
          }
        }
      }
    },
  }
}
