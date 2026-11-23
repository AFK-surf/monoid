// A person's round picture (avatarColor, initial), wherever one is shown: the chat's
// bar and messages, the list's rows, the settings' people.

///|
/// The people's colours.
// kept across runs: a table, never written
let avatar_colors : Array[Int64] = [
  0x5877AEFFL, 0x248753FFL, 0xB9471FFFL, 0x8768ADFFL, 0x32818DFFL, 0x9A6F11FFL,
]

///|
/// A person's colour, by their id lowered (floorMod).
pub fn avatar_color(id : String) -> Int64 {
  let n = avatar_colors.length()
  let mut h = 0
  for i in 0..<id.length() {
    let k = id.at(i).to_int()
    h = h * 31 + (if k >= 65 && k <= 90 { k + 32 } else { k })
  }
  let m = h % n
  avatar_colors[if m < 0 { m + n } else { m }]
}

///|
/// The first letter of a name, upper case; "?" for none.
pub fn initial(name : String) -> String {
  for ch in name {
    let k = ch.to_int()
    if k == 32 || k == 9 || k == 10 {
      continue
    }
    return if k >= 97 && k <= 122 {
      (k - 32).unsafe_to_char().to_string()
    } else {
      ch.to_string()
    }
  }
  "?"
}

///|
/// Under a picture that fills its tile: nothing.
let transparent_ground : Int64 = 0L

///|
/// A picture picked as a person's own (账号's 更换头像), as still.fail cloud keeps it (`account.setPicture`): its middle
/// square at face_picture_px, on white where it is clear, a JPEG (85) as a data URL. Made again from its pixels, so
/// nothing of the file it came from (where it was taken, by what) goes with it.
pub fn face_picture(w : Int, h : Int, px : FixedArray[Byte]) -> String {
  let face = @pixels.Canvas::new(face_picture_px, face_picture_px)
  face.fill(0xFFFFFFFFL)
  let s = if w < h { w } else { h }
  let x = (w - s) / 2
  let y = (h - s) / 2
  let side = face_picture_px.to_double()
  face.draw(w, h, px, (x, y, x + s, y + s), (0.0, 0.0, side, side))
  "data:image/jpeg;base64," + @codec.base64(@pixels.jpeg(face_picture_px, face_picture_px, face.pixels(), quality=85))
}

///|
/// How large a person's own picture is made: past the largest face drawn (the settings' 46) on a screen of 3 pixels a
/// point, 138.
pub let face_picture_px : Int = 256

///|
/// How large a picture picked as a person's own is read before its middle is made theirs: its shorter side
/// face_picture_px at least, for one up to 4 times as long as it is wide.
pub let face_picture_read : Int = 1024
