//! Signed address records shared with admitted scope members, never an admission
//! grant on their own. Revisions are persisted by the owner before publication.
use crate::{identity::Binding, routing::Scope};
use iroh::{EndpointAddr, EndpointId, SecretKey, TransportAddr};
use serde::{Deserialize, Serialize};
const DOMAIN: &str = "mesh-announcement/v1\0";
const LIMIT: usize = 16 * 1024;
const MAX_SAFE: u64 = 9_007_199_254_740_991;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Descriptor { pub binding: Binding, pub address: EndpointAddr }
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Announcement {
    pub scope: String,
    pub node: EndpointId,
    pub revision: u64,
    pub descriptor: Descriptor,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SignedAnnouncement { pub body: String, pub signature: String }
pub fn scope_text(scope: Scope) -> String { scope.iter().map(|b| format!("{b:02x}")).collect() }
impl SignedAnnouncement {
    pub fn sign(key: &SecretKey, scope: Scope, revision: u64, descriptor: Descriptor) -> Result<Self, String> {
        let value = Announcement { scope: scope_text(scope), node: key.public(), revision, descriptor };
        let body = serde_json::to_string(&value).map_err(|e| e.to_string())?;
        let signature = key.sign(format!("{DOMAIN}{body}").as_bytes()).to_string();
        let signed = Self { body, signature };
        signed.verify(scope, key.public(), 0)?;
        Ok(signed)
    }
    pub fn verify(&self, scope: Scope, node: EndpointId, minimum_generation: u64) -> Result<Announcement, String> {
        if self.body.len() > LIMIT || self.signature.len() != 128 || !self.signature.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("invalid mesh announcement size or signature".into());
        }
        let mut bytes = [0; 64];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&self.signature[i * 2..i * 2 + 2], 16).map_err(|_| "invalid signature")?;
        }
        node.verify(format!("{DOMAIN}{}", self.body).as_bytes(), &iroh_base::Signature::from_bytes(&bytes)).map_err(|_| "invalid announcement signature")?;
        let value: Announcement = serde_json::from_str(&self.body).map_err(|e| e.to_string())?;
        if value.scope != scope_text(scope) || value.node != node || value.revision == 0 || value.revision > MAX_SAFE {
            return Err("announcement scope, identity or revision mismatch".into());
        }
        let b = &value.descriptor.binding;
        b.verify(scope, minimum_generation)?;
        if b.endpoint != *node.as_bytes() || b.neighbor != *value.descriptor.address.id.as_bytes() || b.generation > MAX_SAFE {
            return Err("announcement binding mismatch".into());
        }
        if value.descriptor.address.addrs.len() > 8 || value.descriptor.address.addrs.iter().any(|a| !matches!(a, TransportAddr::Ip(_) | TransportAddr::Relay(_))) {
            return Err("announcement must name bounded underlay addresses".into());
        }
        Ok(value)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::neighbor_secret;
    #[test]
    fn verifies_the_node_signed_wire_fixture() {
        let signed: SignedAnnouncement = serde_json::from_str(include_str!("../tests/fixtures/announcement.json")).unwrap();
        let value = signed.verify([84; 32], SecretKey::from([83; 32]).public(), 3).unwrap();
        assert_eq!(value.revision, 7);
        assert_eq!(value.descriptor.address.addrs.len(), 1);
    }
    #[test]
    fn addresses_and_revisions_are_bound_to_the_scope_owner() {
        let key = SecretKey::from([83; 32]);
        let scope = [84; 32];
        let descriptor = Descriptor { binding: Binding::sign(&key, scope, crate::policy::TransitPolicy::empty().digest(), 3, true), address: EndpointAddr::new(neighbor_secret(&key, scope, crate::policy::TransitPolicy::empty().digest()).public()).with_ip_addr("127.0.0.1:1234".parse().unwrap()) };
        let record = SignedAnnouncement::sign(&key, scope, 7, descriptor.clone()).unwrap();
        assert_eq!(record.verify(scope, key.public(), 3).unwrap().revision, 7);
        assert!(record.verify(scope, key.public(), 4).is_err());
        assert!(record.verify([85; 32], key.public(), 0).is_err());
        assert!(record.verify(scope, SecretKey::from([86; 32]).public(), 0).is_err());
        let mut tampered = record.clone(); tampered.body = tampered.body.replace("1234", "1235");
        assert!(tampered.verify(scope, key.public(), 0).is_err());
        assert!(SignedAnnouncement::sign(&key, scope, 0, descriptor.clone()).is_err());
        assert!(SignedAnnouncement::sign(&key, scope, MAX_SAFE + 1, descriptor).is_err());
    }
}
