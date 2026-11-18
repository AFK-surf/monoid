//! A relay redeems a one-use workspace invite over an authenticated connection.
//! Tokens never serve as the relay's persistent identity.
use iroh::{Endpoint, EndpointAddr, EndpointId, PublicKey, RelayUrl};
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const ALPN: &[u8] = b"stillfail/mesh-enrollment/1";
const LIMIT: usize = 16 * 1024;
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct IssuerAddress {
    pub id: EndpointId,
    #[serde(default)]
    pub relays: Vec<RelayUrl>,
    #[serde(default)]
    pub ips: Vec<std::net::SocketAddr>,
    #[serde(default, rename = "disabledRelays")]
    pub disabled_relays: Vec<RelayUrl>,
}
#[derive(Clone, Deserialize, Serialize)]
pub struct Invitation {
    pub scope: String,
    pub issuer: EndpointId,
    pub token: String,
    pub endpoint: IssuerAddress,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Registration {
    pub scope: String,
    pub node: EndpointId,
    pub issuer: EndpointId,
    pub generation: u64,
    pub name: String,
    pub made_by: String,
    pub revoked: u8,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SignedRegistration {
    pub body: String,
    pub signature: String,
}
impl SignedRegistration {
    pub fn verify(&self, issuer: PublicKey, node: EndpointId, scope: &str) -> Result<Registration, String> {
        if self.body.len() > LIMIT || self.signature.len() != 128 { return Err("invalid registration size".into()); }
        if !self.signature.bytes().all(|b| b.is_ascii_hexdigit()) { return Err("invalid registration signature".into()); }
        let mut bytes = [0; 64];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&self.signature[i * 2..i * 2 + 2], 16).map_err(|_| "invalid registration signature")?;
        }
        let signature = iroh_base::Signature::from_bytes(&bytes);
        let message = format!("mesh-relay-registration/v1\0{}", self.body);
        issuer.verify(message.as_bytes(), &signature).map_err(|_| "invalid registration signature")?;
        let record: Registration = serde_json::from_str(&self.body).map_err(|e| e.to_string())?;
        if record.issuer != issuer || record.node != node || record.scope != scope
            || record.revoked != 0 || record.generation == 0 || record.generation > 9_007_199_254_740_991
            || record.name.is_empty() || record.name.len() > 320 || record.made_by.len() > 800 {
            return Err("registration does not match this relay and scope".into());
        }
        Ok(record)
    }
}

#[derive(Debug)]
pub enum RequestError {
    Transport(String),
    Rejected { code: Option<String>, message: String },
}
impl From<String> for RequestError { fn from(message: String) -> Self { Self::Transport(message) } }
impl From<&str> for RequestError { fn from(message: &str) -> Self { Self::Transport(message.into()) } }
impl std::fmt::Display for RequestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self { Self::Transport(message) | Self::Rejected { message, .. } => f.write_str(message) }
    }
}
impl RequestError {
    pub fn registration_removed(&self) -> bool {
        matches!(self, Self::Rejected { code: Some(code), .. } if code == "relay_not_registered" || code == "relay_scope_unavailable")
    }
}

/// A lost reply is recovered with `resume`, using the same private endpoint key.
/// No second token is needed. The caller persists that key before calling here.
pub async fn request(endpoint: &Endpoint, invite: &Invitation, resume: bool) -> Result<SignedRegistration, String> {
    request_status(endpoint, invite, resume).await.map_err(|e| e.to_string())
}
pub async fn request_status(endpoint: &Endpoint, invite: &Invitation, resume: bool) -> Result<SignedRegistration, RequestError> {
    if invite.endpoint.id != invite.issuer || invite.scope.len() != 64
        || !invite.scope.bytes().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
        || invite.endpoint.relays.len() > 32 || invite.endpoint.ips.len() > 8
        || invite.endpoint.disabled_relays.len() > 64 || (!resume && invite.token.len() != 43) {
        return Err("invalid relay invitation".into());
    }
    let operation = async {
        let mut addr = EndpointAddr::new(invite.issuer);
        for url in &invite.endpoint.relays {
            if !invite.endpoint.disabled_relays.contains(url) { addr = addr.with_relay_url(url.clone()); }
        }
        for ip in &invite.endpoint.ips { addr = addr.with_ip_addr(*ip); }
        let options = iroh::endpoint::ConnectOptions::new().with_disabled_relays(invite.endpoint.disabled_relays.clone());
        let conn = endpoint.connect_with_opts(addr, ALPN, options).await.map_err(|e| e.to_string())?
            .await.map_err(|e| e.to_string())?;
        let result = async {
            let (mut send, mut recv) = conn.open_bi().await.map_err(|e| e.to_string())?;
            let value = if resume { serde_json::json!({"op":"resume", "scope":invite.scope}) }
                else { serde_json::json!({"op":"enroll", "scope":invite.scope, "token":invite.token}) };
            let mut bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
            bytes.push(b'\n');
            send.write_all(&bytes).await.map_err(|e| e.to_string())?;
            send.finish().map_err(|e| e.to_string())?;
            let bytes = recv.read_to_end(LIMIT).await.map_err(|e| e.to_string())?;
            let response: serde_json::Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            if let Some(error) = response.get("error").and_then(|v| v.as_str()) { return Err(RequestError::Rejected { code: response.get("code").and_then(|v| v.as_str()).map(str::to_owned), message: error.to_owned() }); }
            let signed: SignedRegistration = serde_json::from_value(response.get("ok").cloned().ok_or("missing registration reply")?).map_err(|e| e.to_string())?;
            signed.verify(invite.issuer, endpoint.id(), &invite.scope)?;
            Ok(signed)
        }.await;
        conn.close(0u32.into(), b"enrollment reply received");
        result
    };
    tokio::time::timeout(Duration::from_secs(10), operation).await.map_err(|_| "relay enrollment deadline".to_owned())?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn node_signed_registration_fixture_verifies() {
        let signed: SignedRegistration = serde_json::from_str(include_str!("../tests/fixtures/registration.json")).unwrap();
        let issuer = iroh::SecretKey::from([70; 32]).public();
        let node = iroh::SecretKey::from([71; 32]).public();
        let public = signed.verify(issuer, node, &"ab".repeat(32)).unwrap();
        assert_eq!(public.name, "测试 relay");
    }

    #[test]
    fn signed_registration_cannot_change_its_scope_identity_or_generation() {
        let issuer = iroh::SecretKey::from([70; 32]);
        let node = iroh::SecretKey::from([71; 32]).public();
        let scope = "ab".repeat(32);
        let record = Registration { scope: scope.clone(), node, issuer: issuer.public(), generation: 7, name: "relay".into(), made_by: "test".into(), revoked: 0 };
        let body = serde_json::to_string(&record).unwrap();
        let signature = issuer.sign(format!("mesh-relay-registration/v1\0{body}").as_bytes()).to_string();
        let signed = SignedRegistration { body, signature };
        assert_eq!(signed.verify(issuer.public(), node, &scope).unwrap().generation, 7);
        assert!(signed.verify(issuer.public(), issuer.public(), &scope).is_err());
        assert!(signed.verify(issuer.public(), node, &"cd".repeat(32)).is_err());
        let mut tampered = signed.clone();
        tampered.body = tampered.body.replace("\"generation\":7", "\"generation\":8");
        assert!(tampered.verify(issuer.public(), node, &scope).is_err());
    }
}
