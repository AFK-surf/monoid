//! Bind the independent neighbor identity to an application's endpoint key.
//! A valid self-signature is not a membership grant. The caller must also admit
//! the endpoint in the scope and apply revocation and relay-disable policy.
use crate::routing::{Node, Scope};
use iroh::{PublicKey, SecretKey};
use iroh_base::Signature;
use serde::{Deserialize, Serialize};

const DOMAIN: &[u8] = b"mesh-neighbor-binding/v2\0";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Binding {
    pub scope: Scope,
    pub policy: [u8;32],
    pub endpoint: Node,
    pub neighbor: Node,
    pub generation: u64,
    pub transit: bool,
    pub signature: Signature,
}

/// A private key per scope keeps the outer protocol separate from the business
/// endpoint. Knowing either public key gives no way to compute this secret.
pub fn neighbor_secret(endpoint: &SecretKey, scope: Scope, policy: [u8;32]) -> SecretKey {
    let mut hash = blake3::Hasher::new_derive_key("mesh-neighbor-secret/v2");
    hash.update(&endpoint.to_bytes());
    hash.update(&scope);
    hash.update(&policy);
    SecretKey::from(*hash.finalize().as_bytes())
}

impl Binding {
    pub fn sign(endpoint: &SecretKey, scope: Scope, policy: [u8;32], generation: u64, transit: bool) -> Self {
        let node = *endpoint.public().as_bytes();
        let neighbor = *neighbor_secret(endpoint, scope, policy).public().as_bytes();
        let signature = endpoint.sign(&message(scope, policy, node, neighbor, generation, transit));
        Self {
            scope,
            policy,
            endpoint: node,
            neighbor,
            generation,
            transit,
            signature,
        }
    }
    pub fn verify(&self, scope: Scope, minimum_generation: u64) -> Result<(), &'static str> {
        if self.generation == 0 || self.generation > 9_007_199_254_740_991 {
            return Err("invalid mesh binding generation");
        }
        if self.scope != scope {
            return Err("mesh binding has another scope");
        }
        if self.generation < minimum_generation {
            return Err("mesh binding is stale");
        }
        if self.neighbor == self.endpoint {
            return Err("mesh neighbor must use a separate identity");
        }
        let endpoint =
            PublicKey::from_bytes(&self.endpoint).map_err(|_| "invalid mesh endpoint key")?;
        PublicKey::from_bytes(&self.neighbor).map_err(|_| "invalid mesh neighbor key")?;
        endpoint
            .verify(
                &message(
                    self.scope,
                    self.policy,
                    self.endpoint,
                    self.neighbor,
                    self.generation,
                    self.transit,
                ),
                &self.signature,
            )
            .map_err(|_| "invalid mesh binding signature")
    }
}

fn message(
    scope: Scope,
    policy: [u8;32],
    endpoint: Node,
    neighbor: Node,
    generation: u64,
    transit: bool,
) -> Vec<u8> {
    let mut message = Vec::with_capacity(DOMAIN.len() + 137);
    message.extend_from_slice(DOMAIN);
    message.extend_from_slice(&scope);
    message.extend_from_slice(&policy);
    message.extend_from_slice(&endpoint);
    message.extend_from_slice(&neighbor);
    message.extend_from_slice(&generation.to_be_bytes());
    message.push(u8::from(transit));
    message
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binding_cannot_be_moved_to_another_scope_identity_or_role() {
        let key = SecretKey::from([1; 32]);
        let binding = Binding::sign(&key, [2; 32], crate::policy::TransitPolicy::empty().digest(), 7, true);
        binding.verify([2; 32], 7).unwrap();
        assert!(binding.verify([3; 32], 7).is_err());
        assert!(binding.verify([2; 32], 8).is_err());
        let mut forged = binding.clone();
        forged.policy[0] ^= 1;
        assert!(forged.verify([2;32],7).is_err());
        assert_ne!(neighbor_secret(&key,[2;32],binding.policy).to_bytes(),neighbor_secret(&key,[2;32],forged.policy).to_bytes());
        let mut forged = binding.clone();
        forged.transit = false;
        assert!(forged.verify([2; 32], 7).is_err());
        let mut forged = binding.clone();
        forged.neighbor = *SecretKey::from([5; 32]).public().as_bytes();
        assert!(forged.verify([2; 32], 7).is_err());
        let mut forged = binding.clone();
        forged.endpoint = forged.neighbor;
        assert!(forged.verify([2; 32], 7).is_err());
        assert_ne!(
            neighbor_secret(&key, [2; 32], binding.policy).public(),
            neighbor_secret(&key, [3; 32], binding.policy).public()
        );
    }
}
