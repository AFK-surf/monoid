// SHA-256 (FIPS 180-4), as the mesh calls it: what the key of an endpoint on one relay alone is made with (ways.mbt,
// `pinned_key`), as the TypeScript mesh makes it (client/core-ts/src/mesh.ts `pinnedKey`). Its digest is
// `@hash.sha256`'s, which a program calls too, so that none on this library writes another.

///|
/// The SHA-256 digest of `data`: 32 bytes.
pub fn sha256(data : Bytes) -> Bytes {
  @hash.sha256(data[:])
}
