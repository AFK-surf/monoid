//! A station admits one authenticated device connection to one target. This is
//! a transport attachment, never an application credential or a transit grant.
use crate::{identity::Binding, routing::{Node, Scope, MAX_HOPS}};
use iroh::{PublicKey, SecretKey};
use iroh_base::Signature;
use serde::{Deserialize, Serialize};

pub const MAX_ATTACHMENTS: usize = 256;
const MAX_SAFE: u64 = 9_007_199_254_740_991;
const DOMAIN: &[u8] = b"mesh-leaf-attachment/v1\0";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Attachment {
    pub scope: Scope,
    pub policy: [u8; 32],
    pub issuer: Binding,
    pub leaf: Binding,
    pub target: Node,
    pub id: [u8; 32],
    pub expires_unix_ms: u64,
    pub signature: Signature,
}
impl Attachment {
    fn message(&self) -> Vec<u8> {
        let mut bytes = DOMAIN.to_vec();
        bytes.extend(postcard::to_allocvec(&(&self.scope,&self.policy,&self.issuer,&self.leaf,&self.target,&self.id,self.expires_unix_ms)).expect("fixed leaf attachment fields serialize"));
        bytes
    }
    pub fn sign(key: &SecretKey, issuer: Binding, leaf: Binding, target: Node, id: [u8;32], expires_unix_ms: u64) -> Result<Self, &'static str> {
        if issuer.endpoint != *key.public().as_bytes() { return Err("leaf issuer key mismatch"); }
        let mut attachment = Self { scope: issuer.scope, policy: issuer.policy, issuer, leaf, target, id, expires_unix_ms, signature: key.sign(b"") };
        attachment.signature = key.sign(&attachment.message());
        attachment.verify_signature()?;
        Ok(attachment)
    }
    /// The caller additionally proves that issuer is a station admitted in this
    /// policy lane, and that its generation is current. A self-signature alone
    /// must never call this an admitted workspace attachment.
    pub fn verify_signature(&self) -> Result<(), &'static str> {
        self.issuer.verify(self.scope,1)?;
        self.leaf.verify(self.scope,1)?;
        if !self.issuer.transit || self.leaf.transit || self.issuer.policy != self.policy || self.leaf.policy != self.policy
            || self.issuer.endpoint == self.leaf.endpoint || self.target == self.leaf.endpoint
            || self.id == [0;32] || self.expires_unix_ms > MAX_SAFE {
            return Err("invalid leaf attachment identity");
        }
        PublicKey::from_bytes(&self.issuer.endpoint).map_err(|_|"invalid leaf issuer")?
            .verify(&self.message(),&self.signature).map_err(|_|"invalid leaf attachment signature")
    }
    pub fn live(&self, now_unix_ms: u64) -> Result<(), &'static str> {
        if self.expires_unix_ms <= now_unix_ms {
            return Err("leaf attachment expired");
        }
        Ok(())
    }
    pub fn issued_by(&self, station: &Binding, scope: Scope, policy: [u8;32], now_unix_ms: u64) -> Result<(), &'static str> {
        self.verify_signature()?;
        self.live(now_unix_ms)?;
        if self.scope != scope || self.policy != policy || self.issuer.endpoint != station.endpoint
            || self.issuer.neighbor != station.neighbor || self.issuer.generation != station.generation
            || self.issuer.policy != station.policy || !station.transit { return Err("leaf issuer is not admitted in this policy lane"); }
        Ok(())
    }
    /// Discovery carries a prefix plus target. The first hop of a leaf must be
    /// its issuing station; the complete route must retain that adjacency.
    pub fn path(&self, path: &[Node], receiver: Node, discovery: bool) -> Result<(), &'static str> {
        if path.len() < 2 || path.len() > MAX_HOPS + 1 { return Err("invalid leaf path length"); }
        let leaf = self.leaf.endpoint;
        let issuer = self.issuer.endpoint;
        let forward = path.first() == Some(&leaf) && path.last() == Some(&self.target);
        let reverse = path.first() == Some(&self.target) && path.last() == Some(&leaf);
        if !forward && !reverse { return Err("leaf attachment has another target"); }
        if path.iter().skip(1).take(path.len()-2).any(|n|*n==leaf) { return Err("leaf cannot provide transit"); }
        let adjacent = if forward {path[1]} else {path[path.len()-2]};
        if adjacent == issuer { return Ok(()); }
        if !discovery || path.contains(&issuer) || receiver == leaf { return Err("leaf path bypasses its issuer"); }
        if forward && (path.len() != 2 || receiver != issuer) { return Err("leaf first hop is not its issuer"); }
        Ok(())
    }
    pub fn same(&self, other: &Self) -> bool { self.id == other.id && self.signature == other.signature }
}

#[derive(Clone)]
struct Kept { attachment: Attachment, touched: u64, local: bool }
#[derive(Clone, Default)]
pub struct Active { kept: std::collections::BTreeMap<[u8;32], Kept> }
impl Active {
    pub fn insert(&mut self, attachment: Attachment, now: u64, local: bool) -> Result<(), &'static str> {
        if let Some(old) = self.kept.get(&attachment.id) {
            if !old.attachment.same(&attachment) { return Err("leaf attachment id reused"); }
        } else if self.kept.len() >= MAX_ATTACHMENTS && !self.kept.values().any(|k|k.attachment.leaf.endpoint==attachment.leaf.endpoint && k.attachment.target==attachment.target) { return Err("leaf attachment capacity"); }
        self.kept.retain(|id,k| *id==attachment.id || k.attachment.leaf.endpoint!=attachment.leaf.endpoint || k.attachment.target!=attachment.target);
        self.kept.insert(attachment.id, Kept { attachment, touched: now, local });
        Ok(())
    }
    pub fn get(&self, id: &[u8;32]) -> Option<&Attachment> { self.kept.get(id).map(|k|&k.attachment) }
    pub fn local(&self, id: &[u8;32]) -> bool { self.kept.get(id).is_some_and(|k|k.local) }
    pub fn touch(&mut self, id: &[u8;32], now: u64) { if let Some(k) = self.kept.get_mut(id) { k.touched = now; } }
    pub fn remove(&mut self, id: &[u8;32]) -> Option<Attachment> { self.kept.remove(id).map(|k|k.attachment) }
    pub fn all(&self) -> impl Iterator<Item=&Attachment> { self.kept.values().map(|k|&k.attachment) }
    pub fn retain(&mut self, mut keep: impl FnMut(&Attachment) -> bool) { self.kept.retain(|_,k|keep(&k.attachment)); }
    pub fn expire(&mut self, now: u64, unix_ms: u64) -> bool {
        let before = self.kept.len();
        self.kept.retain(|_,k| k.attachment.live(unix_ms).is_ok() && (k.local || now.saturating_sub(k.touched) < 45_000));
        before != self.kept.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (SecretKey, Binding, Binding, Binding) {
        let policy = crate::policy::TransitPolicy::empty().digest();
        let key = SecretKey::from([91;32]);
        let issuer = Binding::sign(&key,[4;32],policy,1,true);
        let leaf = Binding::sign(&SecretKey::from([92;32]),[4;32],policy,1,false);
        let target = Binding::sign(&SecretKey::from([93;32]),[4;32],policy,1,true);
        (key,issuer,leaf,target)
    }
    #[test]
    fn attachment_is_bound_to_admitted_issuer_lane_target_and_first_hop() {
        let (key,issuer,leaf,target) = fixture();
        let a = Attachment::sign(&key,issuer.clone(),leaf.clone(),target.endpoint,[1;32],60_000).unwrap();
        a.issued_by(&issuer,issuer.scope,issuer.policy,1).unwrap();
        a.path(&[leaf.endpoint,issuer.endpoint,target.endpoint],target.endpoint,false).unwrap();
        a.path(&[target.endpoint,issuer.endpoint,leaf.endpoint],leaf.endpoint,false).unwrap();
        a.path(&[leaf.endpoint,target.endpoint],issuer.endpoint,true).unwrap();
        assert!(a.path(&[leaf.endpoint,target.endpoint],target.endpoint,true).is_err());
        assert!(a.path(&[leaf.endpoint,target.endpoint],target.endpoint,false).is_err());
        assert!(a.path(&[leaf.endpoint,issuer.endpoint,[7;32]],target.endpoint,false).is_err());
        assert!(a.issued_by(&target,issuer.scope,issuer.policy,1).is_err());
        assert!(a.issued_by(&issuer,[5;32],issuer.policy,1).is_err());
        assert!(a.issued_by(&issuer,issuer.scope,[8;32],1).is_err());
        assert!(a.live(60_000).is_err());
    }
    #[test]
    fn replacing_an_attachment_at_capacity_reclaims_its_slot() {
        let (key,issuer,leaf,target)=fixture();
        let mut active=Active::default();
        for n in 0..MAX_ATTACHMENTS {
            let mut destination=target.endpoint;destination[..2].copy_from_slice(&(n as u16).to_be_bytes());
            let mut id=[1;32];id[..2].copy_from_slice(&(n as u16).to_be_bytes());
            active.insert(Attachment::sign(&key,issuer.clone(),leaf.clone(),destination,id,60_000).unwrap(),0,true).unwrap();
        }
        let prior=active.all().next().unwrap().clone();
        let next=Attachment::sign(&key,issuer,leaf,prior.target,[2;32],60_000).unwrap();
        active.insert(next.clone(),1,true).unwrap();
        assert!(active.get(&prior.id).is_none() && active.get(&next.id).is_some() && active.all().count()==MAX_ATTACHMENTS);
    }
    #[test]
    fn reattachment_never_reactivates_the_old_identifier() {
        let (key,issuer,leaf,target) = fixture();
        let old = Attachment::sign(&key,issuer.clone(),leaf.clone(),target.endpoint,[1;32],60_000).unwrap();
        let next = Attachment::sign(&key,issuer,leaf,target.endpoint,[2;32],60_000).unwrap();
        let mut active = Active::default();
        active.insert(old.clone(),0,true).unwrap();
        active.remove(&old.id);
        active.insert(next.clone(),1,true).unwrap();
        assert!(active.get(&old.id).is_none());
        assert!(active.get(&next.id).is_some());
        assert!(active.expire(60_000,60_000));
        assert!(active.get(&next.id).is_none());
    }
}
