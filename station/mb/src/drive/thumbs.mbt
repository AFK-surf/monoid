// Small copies of the images sent in chats, and of the drive's (thumbs.ts): which files, where they are kept
// (<data>/thumbs, by the image's path), when one is made again (`since`), and what a message keeps (its ThumbHash).
// Decoding, resizing and encoding are the codecs' (the native addon's thumbs.rs), given as `Codecs`.

///|
/// An image already this small is shown itself.
pub let small : Double = 24576.0

///|
/// Where the thumbnails are kept.
pub fn thumbs_dir(data_dir : String) -> String {
  join([data_dir, "thumbs"])
}

///|
fn ends_with_any(name : String, exts : Array[String]) -> Bool {
  let low = name.to_lower()
  exts.iter().any(e => low.has_suffix(e))
}

///|
/// thumbs.ts `wanted`: an image a thumbnail is made for (a GIF would lose its motion).
pub fn image_wanted(name : String) -> Bool {
  ends_with_any(name, [".png", ".jpg", ".jpeg", ".webp"])
}

///|
/// thumbs.ts `idOf`: the first 16 bytes of the SHA-256 of the image's path, in hex.
pub fn id_of(image : String) -> String {
  hex(@hash.sha256(@utf8.encode(image))[0:16])
}

///|
/// A thumbnail: where it is, its type.
pub(all) struct Thumbnail {
  path : String
  type_ : String
} derive(Show, Eq)

///|
/// thumbs.ts `kept`: the thumbnail made before, if there is one; one made before `since` removed.
pub fn kept(thumbs : String, id : String, since? : Double) -> Thumbnail? raise {
  for p in [("jpg", "image/jpeg"), ("png", "image/png")] {
    let path = join([thumbs, "\{id}.\{p.0}"])
    let st = try Some(stat(path)) catch {
      FsError({ code: "ENOENT" | "ENOTDIR", .. }) => None
      e => raise e
    }
    guard st is Some(st) && st.file else { continue }
    if since is Some(s) && st.mtime_ms < s {
      rm_force(path)
      return None
    }
    return Some({ path, type_: p.1 })
  }
  None
}

///|
/// The addon's codecs (thumbs.ts `Codecs`): an image's thumbnail and preview made in a folder, and its ThumbHash
/// (base64) with its size as seen.
pub(all) struct Codecs {
  thumbnail : (String, String) -> Thumbnail? raise
  preview : (String, String) -> Thumbnail? raise
  thumbhash : (String, String?) -> (String, Double, Double)? raise
}

///|
/// thumbs.ts `thumbnail`: the image's thumbnail, made if it is not there yet (or made again when older than `since`);
/// None when the image is shown itself.
pub fn thumbnail(
  image : String,
  thumbs : String,
  codecs : Codecs?,
  since? : Double,
) -> Thumbnail? raise {
  guard codecs is Some(c) else { return None }
  if since is Some(s) {
    kept(thumbs, id_of(image), since=s) |> ignore
  }
  (c.thumbnail)(image, thumbs) catch {
    _ => None
  }
}

///|
/// thumbs.ts `preview`: the image's preview for the whole-window viewer (at most 2048 across), made if it is not there
/// yet; None when the image is shown itself.
pub fn preview(
  image : String,
  thumbs : String,
  codecs : Codecs?,
) -> Thumbnail? {
  guard codecs is Some(c) else { return None }
  (c.preview)(image, thumbs) catch {
    _ => None
  }
}

///|
/// thumbs.ts `hashOf`: the image's ThumbHash and its size as seen.
pub fn hash_of(image : String, codecs : Codecs?) -> (String, Double, Double)? {
  guard codecs is Some(c) else { return None }
  (c.thumbhash)(image, None) catch {
    _ => None
  }
}

///|
/// thumbs.ts `keep`: the images of a message about to be kept, each given its ThumbHash.
pub fn keep(files : Array[JV], thumbs : String, codecs : Codecs?) -> Array[JV] {
  let name_of = (f : JV) => ostr(f, "name").unwrap_or("")
  guard codecs is Some(c) && files.iter().any(f => image_wanted(name_of(f))) else {
    return files
  }
  files.map(file => {
    if !image_wanted(name_of(file)) {
      return file
    }
    let hashed = (c.thumbhash)(ostr(file, "path").unwrap_or(""), Some(thumbs)) catch {
      _ => None
    }
    match hashed {
      None => file
      Some((hash, _, _)) => {
        let copy = match file {
          Obj(f) => JV::Obj(f.copy())
          v => v
        }
        oset(copy, "thumbhash", jvs(hash))
        copy
      }
    }
  })
}

///|
/// The SHA-256 of `data`: `@hash.sha256`'s, kept here for what calls it by this package.
pub fn sha256_bytes(data : Bytes) -> Bytes {
  @hash.sha256(data[:])
}
