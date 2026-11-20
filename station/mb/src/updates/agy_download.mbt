// agy-download.ts: where the Antigravity CLI's own installer (antigravity.google/cli) reads which build to download,
// and how much of it is in as that installer downloads it.

///|
pub let agy_manifests : String = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"

///|
pub struct AgyWatch {
  manifests : String
  /// The build's name in the manifests here (platform's `agyBuild`).
  build : async () -> String?
  /// Where the installer downloads build `url` (platform's `agyStaging`).
  staging : async (String) -> String?
  /// Runs `f` after `ms` on the updates' clock; gives what cancels it.
  after : (Double, async () -> Unit) -> () -> Unit
  /// How much of `version`'s build is in, as it is looked at (`total` its size).
  said : async (String, Double, Double) -> Unit
}

///|
/// `watchAgyDownload`: says how much of the Antigravity CLI's build its installer has downloaded, looked at twice a
/// second until that is whole or this is stopped. Gives what stops it.
pub fn watch_agy_download(w : World, o : AgyWatch) -> () -> Unit {
  let stopped = Ref(false)
  let next : Ref[(() -> Unit)?] = Ref(None)
  w.go(async fn() {
    let found : (String, String, Double)? = try {
      match (o.build)() {
        None => None
        Some(build) => {
          let m = w.fetch("fetch", "\{o.manifests}/\{build}.json")
          if !m.ok() {
            None
          } else {
            let manifest = m.json(w)
            match (get(Some(manifest), "version"), get(Some(manifest), "url")) {
              (Some(Str(v)), Some(Str(u))) => {
                let version = @jsjson.sanitize_str(v)
                let url = @jsjson.sanitize_str(u)
                let file = (o.staging)(url)
                let head = w.fetch("fetch", url, meth="HEAD")
                let total = js_number(head.header("content-length").unwrap_or(""))
                match file {
                  Some(f) if head.ok() && total == total && total != @double.infinity && total > 0.0 =>
                    Some((version, f, total))
                  _ => None
                }
              }
              _ => None
            }
          }
        }
      }
    } catch {
      _ => None
    }
    guard found is Some((version, at, total)) else { return }
    let look : Ref[async () -> Unit] = Ref(fn() {  })
    look.val = async fn() {
      next.val = None
      let got = (try Some(w.stat(at).size) catch { _ => None })
      if stopped.val {
        return
      }
      match got {
        Some(g) => {
          (o.said)(version, g, total)
          if g >= total {
            return
          }
        }
        None => ()
      }
      // timer: a sample of this machine (another program, the installer, writing its download says nothing).
      next.val = Some((o.after)(500.0, async fn() { (look.val)() }))
    }
    if !stopped.val {
      (look.val)()
    }
  })
  () => {
    stopped.val = true
    match next.val {
      Some(f) => f()
      None => ()
    }
  }
}
