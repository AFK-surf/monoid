//! Bounded, atomic snapshots on a control stream authenticated as the issuer.
//! No partial snapshot may replace the live forwarding directory.
use crate::{announcement::{SignedAnnouncement, scope_text}, routing::Scope};
use iroh::{EndpointId, RelayUrl};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
const FRAME_LIMIT: usize = 64 * 1024;
const SAFE: u64 = 9_007_199_254_740_991;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Policy {
    pub scope: String,
    pub generation: u64,
    pub nodes: Vec<EndpointId>,
    #[serde(default)]
    pub generations: BTreeMap<EndpointId, u64>,
    #[serde(rename = "relayUrls")]
    pub relay_urls: Vec<RelayUrl>,
    #[serde(default, rename = "globalRelays")]
    pub global_relays: Vec<crate::global_registration::Registration>,
    pub count: usize,
}
impl Policy {
    pub fn transit(&self)->Result<crate::policy::TransitPolicy,String> {
        crate::policy::TransitPolicy::new(self.relay_urls.clone(),self.global_relays.iter().map(|r|
            crate::policy::Global {node:r.node,generation:r.generation}).collect())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snapshot { pub policy: Policy, pub records: Vec<SignedAnnouncement> }
struct Pending { version: u64, snapshot: Snapshot, nodes: BTreeSet<EndpointId>, neighbors: BTreeSet<EndpointId> }
pub struct Receiver { scope: Scope, node: EndpointId, issuer: EndpointId, generation: u64, last: u64, pending: Option<Pending> }
impl Receiver {
    pub fn new(scope: Scope, node: EndpointId, issuer: EndpointId, generation: u64) -> Self {
        Self { scope, node, issuer, generation, last: 0, pending: None }
    }
    pub fn frame(&mut self, bytes: &[u8]) -> Result<Option<Snapshot>, String> {
        if bytes.len() > FRAME_LIMIT { return Err("directory frame too large".into()); }
        let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
        if let Some(version) = value.get("begin").and_then(|v| v.as_u64()) {
            if self.pending.is_some() || version <= self.last || version > SAFE { return Err("invalid directory transaction".into()); }
            let policy: Policy = serde_json::from_value(value).map_err(|e| e.to_string())?;
            let unique: BTreeSet<_> = policy.nodes.iter().copied().collect();
            if policy.scope != scope_text(self.scope) || policy.generation != self.generation || policy.count > 256
                || policy.nodes.len() > 256 || policy.nodes.len() != unique.len() || !unique.contains(&self.node) || !unique.contains(&self.issuer)
                || policy.generations.len() > 256 || policy.relay_urls.len() > 32
                || policy.generations.iter().any(|(id, generation)| !unique.contains(id) || *generation == 0 || *generation > SAFE)
                || policy.generations.get(&self.node).copied() != Some(self.generation) {
                return Err("invalid scoped directory policy".into());
            }
            let mut globals = BTreeSet::new();
            if policy.global_relays.len() > 32 || unique.len() + policy.global_relays.len() > 256 {
                return Err("too many global directory identities".into());
            }
            for relay in &policy.global_relays {
                relay.validate()?;
                if unique.contains(&relay.node) || !globals.insert(relay.node) {
                    return Err("conflicting global directory identity".into());
                }
            }
            policy.transit()?;
            self.pending = Some(Pending { version, snapshot: Snapshot { policy, records: Vec::new() }, nodes: BTreeSet::new(), neighbors: BTreeSet::new() });
            return Ok(None);
        }
        if let Some(record) = value.get("record") {
            let pending = self.pending.as_mut().ok_or("directory record outside transaction")?;
            if pending.snapshot.records.len() >= pending.snapshot.policy.count { return Err("too many directory records".into()); }
            let signed: SignedAnnouncement = serde_json::from_value(record.clone()).map_err(|e| e.to_string())?;
            // Parsing this bounded body only extracts the identity. Verification
            // below authenticates it before it can reach the runtime.
            if signed.body.len() > 16 * 1024 { return Err("announcement too large".into()); }
            let body: serde_json::Value = serde_json::from_str(&signed.body).map_err(|e| e.to_string())?;
            let node: EndpointId = serde_json::from_value(body.get("node").cloned().ok_or("missing node")?).map_err(|e| e.to_string())?;
            if !pending.snapshot.policy.nodes.contains(&node) || !pending.nodes.insert(node) { return Err("unadmitted or duplicate directory node".into()); }
            let minimum = pending.snapshot.policy.generations.get(&node).copied().unwrap_or(0);
            let verified = signed.verify(self.scope, node, minimum)?;
            if !pending.neighbors.insert(verified.descriptor.address.id) { return Err("duplicate neighbor identity".into()); }
            pending.snapshot.records.push(signed);
            return Ok(None);
        }
        if let Some(version) = value.get("end").and_then(|v| v.as_u64()) {
            let pending = self.pending.take().ok_or("directory end outside transaction")?;
            if version != pending.version || pending.snapshot.records.len() != pending.snapshot.policy.count { return Err("incomplete directory transaction".into()); }
            self.last = version;
            return Ok(Some(pending.snapshot));
        }
        Err("unknown directory frame".into())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use iroh::SecretKey;
    fn fixture() -> (Receiver, serde_json::Value, SignedAnnouncement) {
        let record: SignedAnnouncement = serde_json::from_str(include_str!("../tests/fixtures/announcement.json")).unwrap();
        let node = SecretKey::from([83; 32]).public();
        let issuer = SecretKey::from([70; 32]).public();
        let begin = serde_json::json!({"begin":1,"scope":scope_text([84;32]),"generation":3,"nodes":[node,issuer],"generations":{node.to_string():3},"relayUrls":[],"count":1});
        (Receiver::new([84;32], node, issuer, 3), begin, record)
    }
    #[test]
    fn directory_is_applied_only_after_a_complete_verified_transaction() {
        let (mut receiver, begin, record) = fixture();
        assert!(receiver.frame(&serde_json::to_vec(&begin).unwrap()).unwrap().is_none());
        assert!(receiver.frame(&serde_json::to_vec(&serde_json::json!({"record":record})).unwrap()).unwrap().is_none());
        let snapshot = receiver.frame(br#"{"end":1}"#).unwrap().unwrap();
        assert_eq!(snapshot.records.len(), 1);
        assert!(receiver.frame(&serde_json::to_vec(&begin).unwrap()).is_err());
    }
    #[test]
    fn global_policy_is_bounded_disjoint_and_backwards_compatible() {
        let (_, begin, _) = fixture();
        let old: Policy = serde_json::from_value(begin.clone()).unwrap();
        assert!(old.global_relays.is_empty());
        let node = SecretKey::from([99;32]).public();
        let global = serde_json::json!({"node":node,"name":"public","generation":2,"revision":1,
            "address":iroh::EndpointAddr::new(node)});
        let check = |value: serde_json::Value| {
            let (mut receiver,_,_) = fixture();
            receiver.frame(&serde_json::to_vec(&value).unwrap()).is_ok()
        };
        let mut valid = begin.clone(); valid["globalRelays"] = serde_json::json!([global]);
        assert!(check(valid.clone()));
        let mut duplicate = valid.clone(); duplicate["globalRelays"] = serde_json::json!([global,global]);
        assert!(!check(duplicate));
        let mut overlap = valid.clone(); overlap["nodes"].as_array_mut().unwrap().push(serde_json::json!(node));
        assert!(!check(overlap));
        let mut recursive = valid.clone();
        recursive["globalRelays"][0]["address"]["addrs"] = serde_json::to_value(vec![iroh::TransportAddr::Custom(crate::transport::address([1;32],crate::policy::TransitPolicy::empty().digest(),[2;32]))]).unwrap();
        assert!(!check(recursive));
        let mut stale = valid.clone(); stale["globalRelays"][0]["generation"] = 0.into();
        assert!(!check(stale));
        let mut excessive = valid.clone(); excessive["globalRelays"] = serde_json::json!(vec![global;33]);
        assert!(!check(excessive));
        for n in 1..=254u16 {
            let mut seed = [0;32]; seed[..2].copy_from_slice(&n.to_le_bytes());
            valid["nodes"].as_array_mut().unwrap().push(serde_json::json!(SecretKey::from(seed).public()));
        }
        assert!(!check(valid),"combined private and public identity bound");
    }
    #[test]
    fn incomplete_duplicate_and_stale_generation_records_fail_closed() {
        let (mut receiver, begin, _) = fixture();
        receiver.frame(&serde_json::to_vec(&begin).unwrap()).unwrap();
        assert!(receiver.frame(br#"{"end":1}"#).is_err());
        let (mut receiver, mut begin, record) = fixture();
        begin["count"] = 2.into();
        receiver.frame(&serde_json::to_vec(&begin).unwrap()).unwrap();
        let bytes = serde_json::to_vec(&serde_json::json!({"record":record})).unwrap();
        receiver.frame(&bytes).unwrap();
        assert!(receiver.frame(&bytes).is_err());
        let (mut receiver, mut begin, _) = fixture();
        begin["generation"] = 4.into();
        assert!(receiver.frame(&serde_json::to_vec(&begin).unwrap()).is_err());
        assert!(receiver.frame(&vec![b' '; FRAME_LIMIT + 1]).is_err());
    }
}
