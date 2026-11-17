// Farview's release (src/browser/farview-release.ts; AFK-surf/farview's `tools/package.sh`: bin/host.exe,
// bin/agent.exe, lib/), got by a station that has it nowhere else: where config.json names no directory of its own, a
// station on a system Farview is built for takes the release this station's version names (its commit, as
// apps/mbui/farview.pin pins the client the app draws its tabs with, and the SHA-256 of its tarball), downloaded the
// first time a chat's Farview is started, its digest checked before anything of it is unpacked, and kept in the
// machine's cache of native parts. Farview is private: its releases are that repository's own (the release `builds`),
// got with the machine's `gh` (the lead, 2026-11-16); then still.fail's store of native parts and the release
// `native-artifacts` of AFK-surf/monoid.

///|
/// A release of Farview's: the commit it was built from and its tarball's SHA-256.
pub(all) struct FarviewRelease {
  rev : String
  sha256 : String
}

///|
/// The release a station of this version takes, by the system it runs on (`<os>-<arch>`). Its commit is the one
/// apps/mbui/farview.pin names (test/farview-release.test.ts holds them together).
pub fn farview_releases() -> Array[(String, FarviewRelease)] {
  [
    (
      "darwin-arm64",
      {
        rev: "9d17e3234313c1bd83906e20571ffff1676bdd9e",
        sha256: "3395bbf8eeaea491f42a3640162d6f093ea999c3ad299cc25e3b60ddd01fa6d1",
      },
    ),
    (
      "linux-x64",
      {
        rev: "9d17e3234313c1bd83906e20571ffff1676bdd9e",
        sha256: "ef3b383ee2fd01e2245ce7b15ed0dd9c6ae34b65d432ebae9328bae242180136",
      },
    ),
    (
      "linux-arm64",
      {
        rev: "9d17e3234313c1bd83906e20571ffff1676bdd9e",
        sha256: "7d75b108bd36f1e414a22ad0837441e33dd39753f963911a38a2f7f2b2ae2cd2",
      },
    ),
  ]
}

///|
/// The system a station runs on, as the releases name them (`other` for an OS no build names).
pub fn farview_target(build_os : String?, arch : String) -> String {
  "\{build_os.unwrap_or("other")}-\{arch}"
}

///|
/// The tarball's name, in the store and the release alike.
pub fn farview_asset(target : String, release : FarviewRelease) -> String {
  "farview-\{target}-\{slice(release.rev, 0, b=12)}.tar.gz"
}

///|
/// Where a release is kept, unpacked (bin/host.exe in it), under the machine's cache of native parts.
pub fn farview_cache_dir(native_cache : String, target : String, release : FarviewRelease) -> String {
  pjoin([native_cache, "farview", "\{slice(release.rev, 0, b=12)}-\{target}"])
}

///|
/// Where a release's tarball is asked for, in turn: each of $STILLFAIL_FARVIEW_SOURCES (comma-separated: an address the
/// name goes after, or `gh:<owner>/<repo>@<tag>`, a release `gh` downloads), else Farview's own release (`gh`),
/// still.fail's store of native parts and the GitHub release of them.
pub fn farview_sources(name : String, env : Map[String, String]) -> Array[String] {
  let said = env
    .get("STILLFAIL_FARVIEW_SOURCES")
    .unwrap_or("")
    .split(",")
    .map(s => trim(s.to_string()))
    .filter(s => s != "")
    .collect()
  if said.length() > 0 {
    return said.map(s => "\{s}/\{name}")
  }
  let store = env.get("STILLFAIL_NATIVE_STORE").unwrap_or("https://app.still.fail/releases/natives")
  let repo = env.get("STILLFAIL_NATIVE_REPO").unwrap_or("AFK-surf/monoid")
  let release = env.get("STILLFAIL_NATIVE_RELEASE").unwrap_or("native-artifacts")
  [
    "gh:AFK-surf/farview@builds/\{name}", "\{store}/\{name}", "https://github.com/\{repo}/releases/download/\{release}/\{name}",
  ]
}

///|
fn no_space(s : String) -> Bool {
  for i in 0..<s.length() {
    if @jscase.is_space(s.unsafe_charcode_at(i)) {
      return false
    }
  }
  true
}

///|
/// A `gh:<owner>/<repo>@<tag>/<name>` source as `gh release download` takes it (repo, tag, name); None for any other.
pub fn gh_source(url : String) -> (String, String, String)? {
  if !url.has_prefix("gh:") {
    return None
  }
  let rest = slice(url, 3)
  let at_ = index_of(rest, "@")
  if at_ < 0 {
    return None
  }
  let repo = slice(rest, 0, b=at_)
  let after = slice(rest, at_ + 1)
  let rparts = repo.split("/").map(p => p.to_string()).collect()
  let aparts = after.split("/").map(p => p.to_string()).collect()
  if rparts.length() != 2 || aparts.length() != 2 {
    return None
  }
  for p in rparts + aparts {
    if p == "" || !no_space(p) {
      return None
    }
  }
  Some((repo, aparts[0], aparts[1]))
}

///|
/// The SHA-256 of `b`, in lowercase hex.
pub fn sha256_of(b : Bytes) -> String {
  let msg : Array[Int] = []
  for x in b {
    msg.push(x.to_int())
  }
  let bits = b.length().to_int64() * 8L
  msg.push(0x80)
  while msg.length() % 64 != 56 {
    msg.push(0)
  }
  for i in 0..<8 {
    msg.push(((bits >> (56 - 8 * i)) & 0xFFL).to_int())
  }
  let k : FixedArray[UInt] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
    0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
    0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
    0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
    0xc67178f2,
  ]
  let rotr = (x : UInt, n : Int) => (x >> n) | (x << (32 - n))
  let h : FixedArray[UInt] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]
  let w : FixedArray[UInt] = FixedArray::make(64, 0)
  let mut off = 0
  while off < msg.length() {
    for t in 0..<16 {
      let j = off + t * 4
      w[t] = (msg[j].reinterpret_as_uint() << 24) |
        (msg[j + 1].reinterpret_as_uint() << 16) |
        (msg[j + 2].reinterpret_as_uint() << 8) |
        msg[j + 3].reinterpret_as_uint()
    }
    for t in 16..<64 {
      let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
      let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    }
    let mut a = h[0]
    let mut b_ = h[1]
    let mut c = h[2]
    let mut d = h[3]
    let mut e = h[4]
    let mut f = h[5]
    let mut g = h[6]
    let mut hh = h[7]
    for t in 0..<64 {
      let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
      let ch = (e & f) ^ (e.lnot() & g)
      let t1 = hh + s1 + ch + k[t] + w[t]
      let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
      let maj = (a & b_) ^ (a & c) ^ (b_ & c)
      let t2 = s0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b_
      b_ = a
      a = t1 + t2
    }
    h[0] = h[0] + a
    h[1] = h[1] + b_
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
    off += 64
  }
  let digits = "0123456789abcdef".to_array()
  let out = StringBuilder::new()
  for x in h {
    for i in 0..<8 {
      out.write_char(digits[((x >> (28 - 4 * i)) & 0xFU).reinterpret_as_int()])
    }
  }
  out.to_string()
}

///|
/// What unpacking a release asks of the machine besides its files: a tarball's bytes written, a gzip'd tar unpacked
/// (`tar -xzf <tgz> -C <out>`), random bytes in hex.
pub(all) struct ReleaseIo {
  write_bytes : async (String, Bytes) -> Unit
  untar : async (String, String) -> Unit
  random_hex : (Int) -> String
}

///|
/// Release `release` for `target` unpacked at `dir`, got from `sources` in turn where it is not there yet: a tarball
/// whose SHA-256 is not the release's is refused (and the next source asked), nothing of it unpacked. Unpacked beside
/// `dir` and moved there whole, so a station that stops half way, or another that unpacks it too, leaves no half of one
/// where it is looked for.
pub async fn unpack_release(
  dir : String,
  target : String,
  release : FarviewRelease,
  sources : Array[String],
  get : async (String) -> Bytes?,
  files : Files,
  io : ReleaseIo,
) -> Unit {
  let host_exe = (d : String) => pjoin([d, "bin", "host.exe"])
  if (files.exists)(host_exe(dir)) {
    return
  }
  let name = farview_asset(target, release)
  let refused = []
  let mut bytes : Bytes? = None
  for url in sources {
    guard get(url) is Some(got) else { continue }
    let sha = sha256_of(got)
    if sha == release.sha256 {
      bytes = Some(got)
      break
    }
    refused.push("\{url} (SHA-256 \{sha}, not \{release.sha256})")
  }
  guard bytes is Some(got) else {
    raise fail_(
      if refused.length() > 0 {
        "Farview's release \{name} was refused: \{refused.join("; ")}"
      } else {
        "Farview's release \{name} could not be downloaded (\{sources.join(", ")}): say where an unpacked one is in config.json `browser.farview`, or `browser.farview: false` for Chrome alone."
      },
    )
  }
  let parent = pjoin([dir, ".."])
  (files.mkdir)(parent, 0o777)
  let work = pjoin([parent, ".\{name}.\{(io.random_hex)(6)}"])
  (files.mkdir)(work, 0o777)
  let r = attempt(async fn() {
    let tgz = pjoin([work, name])
    (io.write_bytes)(tgz, got)
    let out = pjoin([work, "out"])
    (files.mkdir)(out, 0o777)
    (io.untar)(tgz, out)
    // (the tarball holds the release in a directory of its own: farview-macos-arm64/bin/host.exe)
    let mut root = out
    if !(files.exists)(host_exe(out)) {
      let inner = (files.readdir)(out).filter(n => !n.has_prefix("."))
      if inner.length() != 1 {
        raise fail_("Farview's release \{name} holds no bin/host.exe")
      }
      root = pjoin([out, inner[0]])
      if !(files.exists)(host_exe(root)) {
        raise FsError("ENOENT", "ENOENT: no such file or directory, access '\{host_exe(root)}'")
      }
    }
    match attempt(async fn() { (files.rename)(root, dir) }) {
      Ok(_) => ()
      // (another station process unpacked it meanwhile: theirs is the same release)
      Err(e) => if !(files.exists)(host_exe(dir)) { raise e }
    }
  })
  (files.rm)(work, true) catch {
    _ => ()
  }
  match r {
    Ok(_) => ()
    Err(e) => raise e
  }
}
