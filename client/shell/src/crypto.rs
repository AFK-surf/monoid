//! Synchronous cryptographic primitives (`crypto.*`, `ed25519.sign`) for lock verification, random bytes, and vault
//! sealing.

use iroh::SecretKey;
use serde_json::{Value, json};

use crate::{err, str_of};

/// Handles synchronous cryptographic operations; returns `Ok(None)` for operations outside this module.
pub(crate) fn run_sync(op: &str, a: &Value) -> Result<Option<Value>, String> {
    // `bytes` random bytes (hex), from the system's source.
    if op == "crypto.random" {
        let mut bytes = vec![0u8; a.get("bytes").and_then(Value::as_u64).unwrap_or(0).min(1024) as usize];
        getrandom::fill(&mut bytes).map_err(err)?;
        return Ok(Some(json!(hex::encode(bytes))));
    }
    // An Ed25519 key's public half and its signature of `message` (hex both ways): a lock claim's (client/core-ts
    // lock.ts), signed for each workspace and endpoint as the core connects. In Hermes (no JIT) the JS one took ~8 ms
    // each and longer the first time, on the core's thread before anything the UI had asked for.
    if op == "ed25519.sign" {
        let seed: [u8; 32] = hex::decode(str_of(a, "seed")?).map_err(err)?.try_into().map_err(|_| "the seed is not 32 bytes".to_string())?;
        let key = SecretKey::from_bytes(&seed);
        let message = hex::decode(str_of(a, "message")?).map_err(err)?;
        return Ok(Some(json!({ "publicKey": hex::encode(key.public().as_bytes()), "signature": hex::encode(key.sign(&message).to_bytes()) })));
    }
    // Whether `signature` is `key`'s over `message` (hex all): Ed25519 (a 32-byte key, a 64-byte signature) or ECDSA
    // P-256 over SHA-256 (`ES256`: an uncompressed point and r‖s; `ES256-der`: the signature DER, as WebAuthn gives
    // it), by libcrux's formally verified implementations: what the core checks the lock's entries and the vault's
    // records by (client/core-ts vault/verified.ts) where the shell has it, not @noble's in JS.
    if op == "crypto.verify" {
        let key = hex::decode(str_of(a, "key")?).map_err(err)?;
        let signature = hex::decode(str_of(a, "signature")?).map_err(err)?;
        let message = hex::decode(str_of(a, "message")?).map_err(err)?;
        let ok = match str_of(a, "alg")? {
            "Ed25519" => match (<[u8; 32]>::try_from(key.as_slice()), <[u8; 64]>::try_from(signature.as_slice())) {
                (Ok(k), Ok(s)) => libcrux_ed25519::verify(&message, &k, &s).is_ok(),
                _ => false,
            },
            alg @ ("ES256" | "ES256-der") => {
                use libcrux_ecdsa::p256::{PublicKey, Signature, verify};
                let s = if alg == "ES256" { <[u8; 64]>::try_from(signature.as_slice()).ok().map(Signature::from_bytes) } else { Signature::from_der(&signature).ok() };
                match (s, PublicKey::try_from(key.as_slice())) {
                    (Some(s), Ok(k)) if key.len() == 65 => verify(libcrux_ecdsa::DigestAlgorithm::Sha256, &message, &s, &k).is_ok(),
                    _ => false,
                }
            }
            other => return Err(format!("no {other} here")),
        };
        return Ok(Some(json!(ok)));
    }
    // The vault's primitives (station/src/vault/crypto.ts: its seal, an item's ciphertext, the recovery key), hex
    // both ways, for the station's MoonBit (station/mb src/vault_crypto), which puts the formats together.
    vault_crypto(op, a)
}

/// The vault's primitives (`crypto.*` in `sf_shell_call_sync`); None for an op not one of them. Every byte string is hex.
/// - `crypto.sha256` {data} -> digest; `crypto.hmacSha256` {key, data} -> tag
/// - `crypto.hkdfSha256` {ikm, salt, info, length} -> length bytes (at most 255 × 32)
/// - `crypto.x25519Public` {priv} -> its public half; `crypto.x25519` {priv, pub} -> the shared secret, an error where it
///   is all zeros (a low-order point), as node:crypto's diffieHellman refuses it
/// - `crypto.chachaSeal` {key, nonce, aad, plain} -> ciphertext ‖ 16-byte tag; `crypto.chachaOpen` {key, nonce, aad,
///   sealed} -> what it held, null where it does not open (ChaCha20-Poly1305, RFC 8439)
pub(crate) fn vault_crypto(op: &str, a: &Value) -> Result<Option<Value>, String> {
    use ring::{aead, digest, hkdf, hmac};
    let bytes = |k: &str| -> Result<Vec<u8>, String> { hex::decode(str_of(a, k)?).map_err(|e| format!("{k}: {e}")) };
    let fixed = |k: &str| -> Result<[u8; 32], String> { bytes(k)?.try_into().map_err(|_| format!("{k} is not 32 bytes")) };
    let aead_key = |k: &[u8; 32]| aead::LessSafeKey::new(aead::UnboundKey::new(&aead::CHACHA20_POLY1305, k).expect("32 bytes"));
    let nonce = || -> Result<aead::Nonce, String> {
        aead::Nonce::try_assume_unique_for_key(&bytes("nonce")?).map_err(|_| "nonce is not 12 bytes".to_string())
    };
    Ok(Some(match op {
        "crypto.sha256" => json!(hex::encode(digest::digest(&digest::SHA256, &bytes("data")?))),
        "crypto.hmacSha256" => {
            let key = hmac::Key::new(hmac::HMAC_SHA256, &bytes("key")?);
            json!(hex::encode(hmac::sign(&key, &bytes("data")?)))
        }
        "crypto.hkdfSha256" => {
            struct Len(usize);
            impl hkdf::KeyType for Len {
                fn len(&self) -> usize {
                    self.0
                }
            }
            let length = a.get("length").and_then(Value::as_u64).ok_or("length is a number")? as usize;
            if length == 0 || length > 255 * 32 {
                return Err("length is 1 to 8160".into());
            }
            let info = bytes("info")?;
            let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, &bytes("salt")?).extract(&bytes("ikm")?);
            let mut out = vec![0u8; length];
            prk.expand(&[&info], Len(length)).and_then(|okm| okm.fill(&mut out)).map_err(|_| "hkdf failed")?;
            json!(hex::encode(out))
        }
        "crypto.x25519Public" => json!(hex::encode(curve25519_dalek::MontgomeryPoint::mul_base_clamped(fixed("priv")?).to_bytes())),
        "crypto.x25519" => {
            let shared = curve25519_dalek::MontgomeryPoint(fixed("pub")?).mul_clamped(fixed("priv")?).to_bytes();
            if shared == [0u8; 32] {
                return Err("the shared secret is zero (a low-order point)".into());
            }
            json!(hex::encode(shared))
        }
        "crypto.chachaSeal" => {
            let mut io = bytes("plain")?;
            aead_key(&fixed("key")?).seal_in_place_append_tag(nonce()?, aead::Aad::from(bytes("aad")?), &mut io).map_err(|_| "seal failed")?;
            json!(hex::encode(io))
        }
        "crypto.chachaOpen" => {
            let mut io = bytes("sealed")?;
            match aead_key(&fixed("key")?).open_in_place(nonce()?, aead::Aad::from(bytes("aad")?), &mut io) {
                Ok(plain) => json!(hex::encode(plain)),
                Err(_) => Value::Null,
            }
        }
        _ => return Ok(None),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The vault's primitives put together as station/src/vault/crypto.ts does (its seal, an item's ciphertext, the
    /// recovery key), on the vectors the station and the core are tested on.
    #[test]
    fn makes_the_vaults_vectors() {
        let v: Value = serde_json::from_str(include_str!("../../../station/test/fixtures/vault-vectors.json")).unwrap();
        let op = |op: &str, a: Value| -> Result<Value, String> { vault_crypto(op, &a).map(Option::unwrap) };
        let h = |op_: &str, a: Value| -> Vec<u8> { hex::decode(op(op_, a).unwrap().as_str().unwrap()).unwrap() };
        const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let b64url = |b: &[u8]| -> String {
            let mut out = String::new();
            for c in b.chunks(3) {
                let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
                for i in 0..=c.len() {
                    out.push(B64[(n >> (18 - 6 * i) & 63) as usize] as char);
                }
            }
            out
        };
        let unb64url = |s: &str| -> Vec<u8> {
            let mut bits = 0u32;
            let mut n = 0;
            let mut out = vec![];
            for ch in s.bytes() {
                bits = bits << 6 | B64.iter().position(|&x| x == ch).unwrap() as u32;
                n += 6;
                if n >= 8 {
                    n -= 8;
                    out.push((bits >> n) as u8);
                }
            }
            out
        };
        let s = |k: &Value| k.as_str().unwrap().to_string();
        let public = |priv_: &str| format!("x25519:{}", hex::encode(h("crypto.x25519Public", json!({ "priv": priv_ }))));
        // sealWith: eph's public half, then ChaCha20-Poly1305 under HKDF(shared, eph ‖ to, "stillfail-vault-seal/1"), a nonce of zeros
        let seal_with = |to: &str, plain: &[u8], context: &str, eph: &str| -> String {
            let to = to.strip_prefix("x25519:").unwrap();
            let eph_pub = h("crypto.x25519Public", json!({ "priv": eph }));
            let shared = h("crypto.x25519", json!({ "priv": eph, "pub": to }));
            let key = h("crypto.hkdfSha256", json!({ "ikm": hex::encode(&shared), "salt": format!("{}{to}", hex::encode(&eph_pub)), "info": hex::encode("stillfail-vault-seal/1"), "length": 32 }));
            let body = h("crypto.chachaSeal", json!({ "key": hex::encode(key), "nonce": "00".repeat(12), "aad": hex::encode(context), "plain": hex::encode(plain) }));
            b64url(&[eph_pub, body].concat())
        };
        let open_seal = |priv_: &str, sealed: &str, context: &str| -> Value {
            let b = unb64url(sealed);
            let (eph_pub, body) = b.split_at(32);
            let shared = h("crypto.x25519", json!({ "priv": priv_, "pub": hex::encode(eph_pub) }));
            let me = h("crypto.x25519Public", json!({ "priv": priv_ }));
            let key = h("crypto.hkdfSha256", json!({ "ikm": hex::encode(&shared), "salt": format!("{}{}", hex::encode(eph_pub), hex::encode(me)), "info": hex::encode("stillfail-vault-seal/1"), "length": 32 }));
            op("crypto.chachaOpen", json!({ "key": hex::encode(key), "nonce": "00".repeat(12), "aad": hex::encode(context), "sealed": hex::encode(body) })).unwrap()
        };
        let recovery = |entropy: &str| -> String {
            let p = h("crypto.hkdfSha256", json!({ "ikm": entropy, "salt": "", "info": hex::encode("stillfail-vault-recovery/1"), "length": 32 }));
            hex::encode(p)
        };
        let ws = s(&v["ws"]);
        let vault = s(&v["vault"]["id"]);
        let key_ctx = format!("stillfail-vault-key/1\0{ws}\0{vault}\00");
        let vault_key = hex::decode(s(&v["vaultKey"])).unwrap();
        assert_eq!(public(&s(&v["box"]["priv"])), s(&v["box"]["pub"]));
        assert_eq!(public(&s(&v["requestBox"]["priv"])), s(&v["requestBox"]["pub"]));
        for r in v["recovery"].as_array().unwrap() {
            assert_eq!(public(&recovery(&s(&r["entropy"]))), s(&r["pub"]));
        }
        assert_eq!(seal_with(&s(&v["box"]["pub"]), &vault_key, &key_ctx, &s(&v["eph"]["wrap"])), s(&v["vault"]["keys"][0]["wrapped"]));
        assert_eq!(seal_with(&public(&recovery(&s(&v["recovery"][1]["entropy"]))), &vault_key, &key_ctx, &s(&v["eph"]["recovery"])), s(&v["vault"]["recovery"]));
        let grant_ctx = format!("stillfail-vault-grant/1\0{ws}\0{}", s(&v["grant"]["request"]));
        assert_eq!(seal_with(&s(&v["requestBox"]["pub"]), s(&v["plain"]).as_bytes(), &grant_ctx, &s(&v["eph"]["grant"])), s(&v["grant"]["secret"]));
        // an item's ciphertext: its nonce, then ChaCha20-Poly1305 under the vault key with its context as additional data
        let item_ctx = format!("stillfail-vault-item/1\0{ws}\0{vault}\0{}\00\00", s(&v["item"]["id"]));
        let body = h("crypto.chachaSeal", json!({ "key": s(&v["vaultKey"]), "nonce": s(&v["nonce"]), "aad": hex::encode(&item_ctx), "plain": hex::encode(s(&v["plain"])) }));
        assert_eq!(b64url(&[hex::decode(s(&v["nonce"])).unwrap(), body].concat()), s(&v["item"]["ct"]));
        // opened under their contexts, and under no other
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["vault"]["keys"][0]["wrapped"]), &key_ctx), json!(s(&v["vaultKey"])));
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["vault"]["keys"][0]["wrapped"]), &key_ctx.replace("\00", "\01")), Value::Null);
        assert_eq!(open_seal(&s(&v["requestBox"]["priv"]), &s(&v["grant"]["secret"]), &grant_ctx), json!(hex::encode(s(&v["plain"]))));
        assert_eq!(open_seal(&s(&v["box"]["priv"]), &s(&v["grant"]["secret"]), &grant_ctx), Value::Null);
        let ct = unb64url(&s(&v["item"]["ct"]));
        let opened = |aad: &str| op("crypto.chachaOpen", json!({ "key": s(&v["vaultKey"]), "nonce": hex::encode(&ct[..12]), "aad": hex::encode(aad), "sealed": hex::encode(&ct[12..]) })).unwrap();
        assert_eq!(opened(&item_ctx), json!(hex::encode(s(&v["plain"]))));
        assert_eq!(opened(&item_ctx.replace("\00\00", "\01\00")), Value::Null);
    }

    /// Known answers: SHA-256 and HMAC-SHA256 (RFC 4231 case 2), HKDF-SHA256 (RFC 5869 case 1), X25519 (RFC 7748 §6.1),
    /// ChaCha20-Poly1305 (RFC 8439 §2.8.2); and what each refuses.
    #[test]
    fn the_vaults_primitives_answer_as_their_specs() {
        let op = |op: &str, a: Value| vault_crypto(op, &a).map(Option::unwrap);
        assert_eq!(op("crypto.sha256", json!({ "data": hex::encode("abc") })).unwrap(), json!("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
        assert_eq!(op("crypto.hmacSha256", json!({ "key": hex::encode("Jefe"), "data": hex::encode("what do ya want for nothing?") })).unwrap(), json!("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
        assert_eq!(
            op("crypto.hkdfSha256", json!({ "ikm": "0b".repeat(22), "salt": "000102030405060708090a0b0c", "info": "f0f1f2f3f4f5f6f7f8f9", "length": 42 })).unwrap(),
            json!("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
        );
        assert!(op("crypto.hkdfSha256", json!({ "ikm": "00", "salt": "", "info": "", "length": 0 })).is_err());
        assert!(op("crypto.hkdfSha256", json!({ "ikm": "00", "salt": "", "info": "", "length": 8161 })).is_err());
        let alice = "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a";
        let bob = "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb";
        assert_eq!(op("crypto.x25519Public", json!({ "priv": alice })).unwrap(), json!("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"));
        let shared = json!("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
        assert_eq!(op("crypto.x25519", json!({ "priv": alice, "pub": "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f" })).unwrap(), shared);
        assert_eq!(op("crypto.x25519", json!({ "priv": bob, "pub": "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" })).unwrap(), shared);
        assert!(op("crypto.x25519", json!({ "priv": alice, "pub": "00".repeat(32) })).is_err());
        assert!(op("crypto.x25519", json!({ "priv": "00", "pub": "00".repeat(32) })).is_err());
        let key = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";
        let nonce = "070000004041424344454647";
        let aad = "50515253c0c1c2c3c4c5c6c7";
        let plain = hex::encode("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
        let sealed = op("crypto.chachaSeal", json!({ "key": key, "nonce": nonce, "aad": aad, "plain": plain })).unwrap();
        let sealed = sealed.as_str().unwrap();
        assert!(sealed.starts_with("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6"));
        assert!(sealed.ends_with("1ae10b594f09e26a7e902ecbd0600691"));
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": aad, "sealed": sealed })).unwrap(), json!(plain));
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": "", "sealed": sealed })).unwrap(), Value::Null);
        assert_eq!(op("crypto.chachaOpen", json!({ "key": key, "nonce": nonce, "aad": aad, "sealed": "00" })).unwrap(), Value::Null);
        assert!(op("crypto.chachaSeal", json!({ "key": "00", "nonce": nonce, "aad": aad, "plain": "" })).is_err());
        assert!(op("crypto.chachaSeal", json!({ "key": key, "nonce": "00", "aad": aad, "plain": "" })).is_err());
        assert_eq!(vault_crypto("crypto.none", &json!({})).unwrap(), None);
    }
}
