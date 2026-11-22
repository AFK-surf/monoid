// The drive's codecs (drive/thumbs.mbt `Codecs`) as the mesh addon gave them to Node (native/mesh/src/thumbs.rs): the
// files read and written here, what is made of their bytes media/thumbs.mbt's.

///|
fn kept_thumb(dir : String, id : String) -> @drive.Thumbnail? {
  for pair in [("jpg", "image/jpeg"), ("png", "image/png")] {
    let path = @drive.join([dir, "\{id}.\{pair.0}"])
    match attempt(() => @drive.stat(path)) {
      Ok(s) if s.file => return Some({ path, type_: pair.1 })
      _ => ()
    }
  }
  None
}

///|
fn kept_preview(dir : String, id : String) -> @drive.Thumbnail? {
  for pair in [("jpg", "image/jpeg"), ("png", "image/png"), ("webp", "image/webp")] {
    let path = @drive.join([dir, "\{id}.p.\{pair.0}"])
    match attempt(() => @drive.stat(path)) {
      Ok(s) if s.file => return Some({ path, type_: pair.1 })
      _ => ()
    }
  }
  None
}

///|
/// thumbs.rs `make`: written whole beside (`<id><suffix>.<ext>.part`) before it is there to be read.
fn write_copy(
  made : (String, String, Bytes)?,
  dir : String,
  id : String,
  suffix : String,
) -> @drive.Thumbnail? {
  guard made is Some((ext, kind, bytes)) else { None }
  guard attempt(() => @drive.mkdir(dir, true)) is Ok(_) else { None }
  let path = @drive.join([dir, "\{id}\{suffix}.\{ext}"])
  let partial = "\{path}.part"
  let written = attempt(() => {
    ignore(
      @drive.write_part(partial, {
        create: true,
        offset: 0.0,
        data: bytes,
        at_least: None,
        truncate: Some(bytes.length().to_double()),
        sync: false,
      }),
    )
    @drive.rename(partial, path)
  })
  guard written is Ok(_) else { None }
  Some({ path, type_: kind })
}

///|
fn write_thumb(img : @media.Image, len : Double, dir : String, id : String) -> @drive.Thumbnail? {
  write_copy(@media.made_small(img, len), dir, id, "")
}

///|
fn write_preview(img : @media.Image, len : Double, dir : String, id : String) -> @drive.Thumbnail? {
  write_copy(@media.made_preview(img, len), dir, id, ".p")
}

///|
/// thumbs.rs `thumbnail`: the image's thumbnail in `dir` and its type, made if it is not there yet; None where the
/// image is shown itself (not a png/jpg/jpeg/webp by its name, 24 KiB or less, not readable as an image, or no smaller
/// made).
pub fn thumbnail(image : String, dir : String) -> @drive.Thumbnail? {
  guard @drive.image_wanted(image) else { None }
  guard attempt(() => @drive.stat(image)) is Ok(st) && st.size > @media.small_len else { None }
  let id = @drive.id_of(image)
  match kept_thumb(dir, id) {
    Some(t) => Some(t)
    None => {
      guard attempt(() => @drive.read_all(image)) is Ok(bytes) else { None }
      guard @media.decode_image(bytes) is Some(img) else { None }
      write_thumb(img, st.size, dir, id)
    }
  }
}

///|
/// thumbs.rs `preview`: the image's preview in `dir` (`<id>.p.jpg`, `.p.png` or `.p.webp`) and its type, made if it is
/// not there yet; None where the image is shown itself (not a png/jpg/jpeg/webp by its name, 300 KiB or less, not
/// readable as an image, or no copy at half its bytes or less).
pub fn preview(image : String, dir : String) -> @drive.Thumbnail? {
  guard @drive.image_wanted(image) else { None }
  guard attempt(() => @drive.stat(image)) is Ok(st) && st.size > @media.preview_small_len else {
    None
  }
  let id = @drive.id_of(image)
  match kept_preview(dir, id) {
    Some(t) => Some(t)
    None => {
      guard attempt(() => @drive.read_all(image)) is Ok(bytes) else { None }
      guard @media.decode_image(bytes) is Some(img) else { None }
      write_preview(img, st.size, dir, id)
    }
  }
}

///|
/// thumbs.rs `thumbhash`: the image's ThumbHash (base64) and its size as seen, decoded once; with `dir` its thumbnail
/// made from the same decoding after, when the image is over 24 KiB and has none yet. None where it is not readable
/// as an image.
pub fn thumbhash(image : String, dir : String?) -> (String, Double, Double)? {
  guard attempt(() => @drive.read_all(image)) is Ok(bytes) else { None }
  guard @media.decode_image(bytes) is Some(img) else { None }
  let hash = @media.hash_of(img)
  let len = bytes.length().to_double()
  if dir is Some(d) && len > @media.small_len {
    let id = @drive.id_of(image)
    if kept_thumb(d, id) is None {
      ignore(write_thumb(img, len, d, id))
    }
  }
  Some((hash, img.w.to_double(), img.h.to_double()))
}

///|
/// The drive's codecs (drive/thumbs.mbt `Codecs`), these.
pub fn codecs() -> @drive.Codecs {
  {
    thumbnail: (image, dir) => thumbnail(image, dir),
    preview: (image, dir) => preview(image, dir),
    thumbhash: (image, dir) => thumbhash(image, dir),
  }
}
