// The folders macOS protects made once (`Protected`) find what drive/fs.ts `protectedPlace` finds.

///|
test "a protected folder of the home or a mount, found by its lower-cased path" {
  let prot = Protected::new("/", "/Users/me", ["/Volumes/Data/x", "/mnt/Share", "/mnt/Share/Deep"])
  let known = (p : String) => protected_known(prot, @jscase.lower(p))
  assert_eq(known("/Users/me/Documents"), Some("/Users/me/Documents"))
  assert_eq(known("/users/ME/documents/a/b"), Some("/Users/me/Documents"))
  assert_eq(known("/Users/me/Library/CloudStorage/Box/f"), Some("/Users/me/Library/CloudStorage"))
  assert_eq(known("/Users/me/Library/Mobile Documents"), Some("/Users/me/Library/Mobile Documents"))
  assert_eq(known("/Users/me/DocumentsX"), None)
  assert_eq(known("/Users/me/code"), None)
  // the longest mount it is under; none under /Volumes/, which is looked at on the disk
  assert_eq(known("/mnt/share/deep/f"), Some("/mnt/Share/Deep"))
  assert_eq(known("/mnt/Share/f"), Some("/mnt/Share"))
  assert_eq(known("/Volumes/Data/x/f"), None)
  assert_eq(known("/mnt/Shared"), None)
}
