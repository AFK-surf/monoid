//! Global relay registration stores only operator-approved bootstrap metadata.
//! The client never sends scope identities, paths, counters, or workspace data.
use iroh::{EndpointAddr,EndpointId,RelayUrl,SecretKey,TransportAddr};
use serde::{Deserialize,Serialize};
use std::{collections::BTreeSet,time::Duration};
const MAX_SAFE:u64=9_007_199_254_740_991;
#[derive(Clone,Serialize,Deserialize)]
pub struct Invitation {pub origin:String,pub token:String,#[serde(default)]pub relays:Vec<RelayUrl>}
#[derive(Clone,Debug,Serialize,Deserialize)]
pub struct Registration {pub node:EndpointId,pub name:String,pub generation:u64,pub revision:u64,pub address:EndpointAddr}
impl Registration {
    pub fn validate(&self)->Result<(),String> {
        if self.address.id!=self.node || self.name.chars().count()>40 || self.generation==0 || self.generation>MAX_SAFE || self.revision==0 || self.revision>MAX_SAFE || self.address.addrs.len()>8
            || self.address.addrs.iter().any(|a|matches!(a,TransportAddr::Custom(_))) {return Err("invalid global relay registration".into());}
        Ok(())
    }
}
#[derive(Clone,Serialize,Deserialize)]
pub struct Saved {pub invitation:Invitation,pub registration:Option<Registration>,pub revision:u64,#[serde(default)]pub registry:Vec<Registration>}
impl Saved {
    pub fn validate(&self,node:EndpointId)->Result<(),String> {
        origin(&self.invitation.origin)?;
        if self.invitation.token.len()>256 || self.invitation.relays.len()>32 || self.revision>MAX_SAFE || self.registry.len()>32 {return Err("invalid global relay state".into());}
        if let Some(registration)=&self.registration {
            registration.validate()?;
            if registration.node!=node {return Err("global registration has another identity".into());}
        }
        validate_registry(&self.registry)
    }
}
#[derive(Debug)]
pub enum Error {Transport(String),Rejected{status:u16,code:String}}
impl std::fmt::Display for Error {
    fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result {match self {
        Self::Transport(message)=>f.write_str(message),
        Self::Rejected{status,code}=>write!(f,"global registration refused ({status}): {code}"),
    }}
}
fn origin(value:&str)->Result<String,String> {
    let url=reqwest::Url::parse(value).map_err(|_|"invalid global relay origin")?;
    let local=matches!(url.host_str(),Some("localhost"|"127.0.0.1"|"[::1]"));
    if !(url.scheme()=="https" || url.scheme()=="http"&&local) || !url.username().is_empty() || url.password().is_some() || url.query().is_some() || url.fragment().is_some() || url.path()!="/" {
        return Err("global relay origin must be HTTPS (HTTP is allowed on loopback)".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}
fn validate_registry(registry:&[Registration])->Result<(),String> {
    if registry.len()>32{return Err("global relay registry too large".into());}
    let mut nodes=BTreeSet::new();
    for relay in registry {relay.validate()?;if !nodes.insert(relay.node){return Err("duplicate global relay identity".into());}}
    Ok(())
}
pub struct Client {http:reqwest::Client,origin:String}
impl Client {
    pub fn new(value:&str)->Result<Self,String> {
        let origin=origin(value)?;
        let tls=rustls::ClientConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions().map_err(|e|e.to_string())?
            .with_root_certificates(rustls::RootCertStore {roots:webpki_roots::TLS_SERVER_ROOTS.to_vec()})
            .with_no_client_auth();
        let http=reqwest::Client::builder().tls_backend_preconfigured(tls).connect_timeout(Duration::from_secs(10)).read_timeout(Duration::from_secs(60)).redirect(reqwest::redirect::Policy::none()).build().map_err(|e|e.to_string())?;
        Ok(Self {http,origin})
    }
    pub async fn list(&self)->Result<Vec<Registration>,Error> {
        let reply=self.http.get(format!("{}/v1/relays/mesh",self.origin)).timeout(Duration::from_secs(10)).send().await.map_err(|e|Error::Transport(e.to_string()))?;
        #[derive(Deserialize)]struct List {relays:Vec<Registration>}
        let list:List=serde_json::from_slice(&response(reply).await?).map_err(|e|Error::Transport(e.to_string()))?;
        validate_registry(&list.relays).map_err(Error::Transport)?;
        Ok(list.relays)
    }
    pub async fn watch(&self,key:&SecretKey,generation:u64)->Result<Events,Error> {
        let at=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e|Error::Transport(e.to_string()))?.as_millis();
        let body=serde_json::to_string(&serde_json::json!({"node":key.public(),"generation":generation,"at":at as u64})).map_err(|e|Error::Transport(e.to_string()))?;
        let signature=key.sign(format!("mesh-global-watch/v1\0{}\0{body}",self.origin).as_bytes()).to_string().to_ascii_lowercase();
        let request=self.http.post(format!("{}/v1/relays/mesh/events",self.origin)).json(&Signed {body,signature}).send();
        let reply=tokio::time::timeout(Duration::from_secs(10),request).await.map_err(|_|Error::Transport("global registry subscription timeout".into()))?
            .map_err(|e|Error::Transport(e.to_string()))?;
        if !reply.status().is_success() {response(reply).await?;return Err(Error::Transport("invalid global watch response".into()));}
        Ok(Events {reply,line:Vec::new(),chunk:bytes::Bytes::new(),position:0})
    }
    pub async fn publish(&self,key:&SecretKey,token:Option<&str>,generation:Option<u64>,revision:u64,address:EndpointAddr)->Result<Registration,Error> {
        let proof=signed_request(key,&self.origin,token,generation,revision,address.clone()).map_err(Error::Transport)?;
        let path=if token.is_some(){"enroll"}else{"address"};
        let reply=self.http.post(format!("{}/v1/relays/mesh/{path}",self.origin)).json(&proof).timeout(Duration::from_secs(10)).send().await.map_err(|e|Error::Transport(e.to_string()))?;
        let registration:Registration=serde_json::from_slice(&response(reply).await?).map_err(|e|Error::Transport(e.to_string()))?;
        registration.validate().map_err(Error::Transport)?;
        if registration.node!=key.public() || registration.address!=address || registration.revision!=revision || generation.is_some_and(|g|g!=registration.generation) {
            return Err(Error::Transport("global registry response identity mismatch".into()));
        }
        Ok(registration)
    }
}
// The decoder keeps partial frames across cancellation by address updates.
pub struct Events {reply:reqwest::Response,line:Vec<u8>,chunk:bytes::Bytes,position:usize}
impl Events {
    pub async fn next(&mut self)->Result<Vec<Registration>,Error> {
        loop {
            if self.position==self.chunk.len() {
                self.chunk=self.reply.chunk().await.map_err(|e|Error::Transport(e.to_string()))?.ok_or_else(||Error::Transport("global registry subscription ended".into()))?;
                self.position=0;
            }
            while self.position<self.chunk.len() {
                let byte=self.chunk[self.position];self.position+=1;
                if byte==b'\n' {
                    let value:serde_json::Value=serde_json::from_slice(&self.line).map_err(|e|Error::Transport(e.to_string()))?;self.line.clear();
                    if value.get("heartbeat")==Some(&serde_json::Value::Bool(true)) && value.as_object().is_some_and(|v|v.len()==1) {continue;}
                    let registry:Vec<Registration>=serde_json::from_value(value.get("relays").cloned().ok_or_else(||Error::Transport("invalid registry event".into()))?).map_err(|e|Error::Transport(e.to_string()))?;
                    validate_registry(&registry).map_err(Error::Transport)?;return Ok(registry);
                }
                if self.line.len()>=65536 {return Err(Error::Transport("global registry event too large".into()));}
                self.line.push(byte);
            }
        }
    }
}
#[derive(Serialize)]pub struct Signed {pub body:String,pub signature:String}
pub fn signed_request(key:&SecretKey,origin_value:&str,token:Option<&str>,generation:Option<u64>,revision:u64,address:EndpointAddr)->Result<Signed,String> {
    let origin=origin(origin_value)?;
    if token.is_some()==generation.is_some() || address.id!=key.public() || revision==0 || revision>MAX_SAFE || address.addrs.len()>8 {return Err("invalid global registration request".into());}
    if token.is_some_and(|token|token.len()<16||token.len()>256) || generation.is_some_and(|g|g==0||g>MAX_SAFE) || address.addrs.iter().any(|a|matches!(a,TransportAddr::Custom(_))) {return Err("invalid global registration proof".into());}
    #[derive(Serialize)]struct Body<'a> {node:EndpointId,revision:u64,address:EndpointAddr,#[serde(skip_serializing_if="Option::is_none")]token:Option<&'a str>,#[serde(skip_serializing_if="Option::is_none")]generation:Option<u64>}
    let body=serde_json::to_string(&Body {node:key.public(),revision,address,token,generation}).map_err(|e|e.to_string())?;
    if body.len()>8192{return Err("global registration body too large".into());}
    let signature=key.sign(format!("mesh-global-registration/v1\0{origin}\0{body}").as_bytes()).to_string().to_ascii_lowercase();
    Ok(Signed {body,signature})
}
async fn response(mut reply:reqwest::Response)->Result<Vec<u8>,Error> {
    let status=reply.status();let mut bytes=Vec::new();
    if reply.content_length().is_some_and(|n|n>65536){return Err(Error::Transport("global registry response too large".into()));}
    while let Some(chunk)=reply.chunk().await.map_err(|e|Error::Transport(e.to_string()))? {
        if bytes.len()+chunk.len()>65536{return Err(Error::Transport("global registry response too large".into()));}
        bytes.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        let code=serde_json::from_slice::<serde_json::Value>(&bytes).ok().and_then(|v|v.get("error").and_then(|v|v.as_str()).map(str::to_owned)).unwrap_or_else(||"invalid_response".into());
        return Err(Error::Rejected {status:status.as_u16(),code});
    }
    Ok(bytes)
}
#[cfg(test)]mod tests {
    use super::*;
    #[test]fn proof_binds_origin_identity_generation_and_address() {
        let key=SecretKey::from([90;32]);let address=EndpointAddr::new(key.public()).with_ip_addr("127.0.0.1:5432".parse().unwrap());
        let signed=signed_request(&key,"https://relay.example/",None,Some(3),7,address).unwrap();
        assert!(signed.signature.bytes().all(|b|b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),"cloud requires canonical lowercase signature hex");
        let mut bytes=[0;64];
        for (i,byte) in bytes.iter_mut().enumerate(){*byte=u8::from_str_radix(&signed.signature[i*2..i*2+2],16).unwrap();}
        let signature=iroh_base::Signature::from_bytes(&bytes);
        key.public().verify(format!("mesh-global-registration/v1\0https://relay.example\0{}",signed.body).as_bytes(),&signature).unwrap();
        assert!(key.public().verify(format!("mesh-global-registration/v1\0https://other.example\0{}",signed.body).as_bytes(),&signature).is_err());
        assert!(origin("https://user:password@relay.example").is_err());
        assert!(origin("http://relay.example").is_err());
    }
}
