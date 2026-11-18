//! A transit lane discloses only permitted underlays and public relay identities,
//! never a workspace roster. Canonical policy bytes bind every hop to one lane.
use iroh::{EndpointId,RelayUrl};
use serde::{Deserialize,Serialize};
#[derive(Clone,Debug,PartialEq,Eq,PartialOrd,Ord,Serialize,Deserialize)]
pub struct Global { pub node:EndpointId, pub generation:u64 }
#[derive(Clone,Debug,PartialEq,Eq,Serialize,Deserialize)]
pub struct TransitPolicy {
    #[serde(rename="relayUrls")]
    pub relay_urls:Vec<RelayUrl>,
    pub globals:Vec<Global>,
}
impl TransitPolicy {
    pub fn empty()->Self {Self {relay_urls:vec![],globals:vec![]}}
    pub fn new(mut relay_urls:Vec<RelayUrl>,mut globals:Vec<Global>)->Result<Self,String> {
        if relay_urls.len()>32 || globals.len()>32 {return Err("transit policy capacity".into());}
        relay_urls.sort();relay_urls.dedup();globals.sort();globals.dedup();
        let policy=Self {relay_urls,globals};policy.validate()?;Ok(policy)
    }
    pub fn validate(&self)->Result<(),String> {
        if self.relay_urls.len()>32 || self.globals.len()>32
            || self.relay_urls.windows(2).any(|v|v[0]>=v[1])
            || self.globals.windows(2).any(|v|v[0].node>=v[1].node)
            || self.globals.iter().any(|g|g.generation==0||g.generation>9_007_199_254_740_991)
            || self.relay_urls.iter().any(|u|u.as_str().len()>2048)
            || self.relay_urls.iter().map(|u|u.as_str().len()).sum::<usize>()>8192 {
            return Err("invalid or noncanonical transit policy".into());
        }
        Ok(())
    }
    pub fn digest(&self)->[u8;32] {
        let mut hash=blake3::Hasher::new_derive_key("mesh-transit-policy/v1");
        hash.update(&(self.relay_urls.len() as u32).to_be_bytes());
        for url in &self.relay_urls {let bytes=url.as_str().as_bytes();hash.update(&(bytes.len() as u32).to_be_bytes());hash.update(bytes);}
        hash.update(&(self.globals.len() as u32).to_be_bytes());
        for global in &self.globals {hash.update(global.node.as_bytes());hash.update(&global.generation.to_be_bytes());}
        *hash.finalize().as_bytes()
    }
    pub fn admits(&self,node:EndpointId,generation:u64)->bool {self.globals.iter().any(|g|g.node==node&&g.generation==generation)}
    pub fn underlay(&self,operator:&[RelayUrl])->Vec<RelayUrl> {self.relay_urls.iter().filter(|url|operator.contains(url)).cloned().collect()}
}
#[cfg(test)]mod tests {
    use super::*;
    #[test]fn canonical_digest_separates_permissions_and_generations() {
        let a:RelayUrl="https://a.example".parse().unwrap();let b:RelayUrl="https://b.example".parse().unwrap();
        let narrow=TransitPolicy::new(vec![a.clone()],vec![]).unwrap();
        assert_eq!(narrow,TransitPolicy::new(vec![a.clone(),a.clone()],vec![]).unwrap());
        let wide=TransitPolicy::new(vec![b.clone(),a.clone()],vec![]).unwrap();assert_ne!(narrow.digest(),wide.digest());
        assert_eq!(wide.underlay(&[a.clone()]),vec![a]);
        let node=iroh::SecretKey::from([11;32]).public();
        assert_ne!(TransitPolicy::new(vec![],vec![Global{node,generation:1}]).unwrap().digest(),TransitPolicy::new(vec![],vec![Global{node,generation:2}]).unwrap().digest());
        assert!(TransitPolicy::new(vec![],vec![Global{node,generation:1},Global{node,generation:2}]).is_err());
        assert!(TransitPolicy{relay_urls:vec![b.clone(),b],globals:vec![]}.validate().is_err());
    }
}
