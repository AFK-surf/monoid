//! TLS client/server helpers, `PrefixedIo`, and `race_tls_stream` regional entry connector.

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, pem::PemObject};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream as ClientTlsStream;
use tokio_rustls::{TlsAcceptor, TlsConnector};

use crate::net::tcp_connect_keepalive;
use crate::{Handle, err};

/// Default client TLS config using ring + Mozilla webpki roots.
pub(crate) fn tls_config() -> rustls::ClientConfig {
    tls_config_with_ca(None, None)
}

/// Client TLS config using ring + Mozilla webpki roots, plus optional extra CA PEM certificates and ALPN protocols.
/// Invalid PEM blocks are ignored (preserving existing `custom_http_client` compatibility).
pub(crate) fn tls_config_with_ca(ca_pem: Option<&str>, alpn: Option<&[String]>) -> rustls::ClientConfig {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    if let Some(pem) = ca_pem {
        for cert in CertificateDer::pem_slice_iter(pem.as_bytes()).flatten() {
            let _ = roots.add(cert);
        }
    }
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    if let Some(protos) = alpn.filter(|p| !p.is_empty()) {
        config.alpn_protocols = protos.iter().map(|s| s.as_bytes().to_vec()).collect();
    }
    config
}

/// Strict client TLS config for explicit `caPem` inputs (`tls.connect`, `race: true`, `ws.open`):
/// fails if `ca_pem` contains invalid PEM or zero valid certificates.
pub(crate) fn tls_config_with_strict_ca(ca_pem: &str, alpn: Option<&[String]>) -> Result<rustls::ClientConfig, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    let mut added = 0usize;
    for item in CertificateDer::pem_slice_iter(ca_pem.as_bytes()) {
        let cert = item.map_err(|e| format!("invalid caPem: {e}"))?;
        roots.add(cert).map_err(|e| format!("invalid caPem: {e}"))?;
        added += 1;
    }
    if added == 0 {
        return Err("invalid caPem: no certificates found".into());
    }
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    if let Some(protos) = alpn.filter(|p| !p.is_empty()) {
        config.alpn_protocols = protos.iter().map(|s| s.as_bytes().to_vec()).collect();
    }
    Ok(config)
}

/// Server TLS config using ring, PEM certificate chain, PEM private key (PKCS#8, PKCS#1, or SEC1), and optional ALPN.
pub(crate) fn server_tls_config(cert_pem: &str, key_pem: &str, alpn: Option<&[String]>) -> Result<rustls::ServerConfig, String> {
    let certs: Vec<CertificateDer<'static>> = CertificateDer::pem_slice_iter(cert_pem.as_bytes())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("invalid certPem: {e}"))?;
    if certs.is_empty() {
        return Err("certPem contains no certificates".into());
    }
    let key = PrivateKeyDer::from_pem_slice(key_pem.as_bytes()).map_err(|e| format!("invalid keyPem: {e}"))?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(err)?
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(err)?;
    if let Some(protos) = alpn.filter(|p| !p.is_empty()) {
        config.alpn_protocols = protos.iter().map(|s| s.as_bytes().to_vec()).collect();
    }
    Ok(config)
}

/// Parse a host string (stripping IPv6 brackets if present) into a rustls `ServerName`.
pub(crate) fn server_name_of(host: &str) -> Result<ServerName<'static>, String> {
    let bare = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    ServerName::try_from(bare.to_string()).map_err(|e| format!("invalid server name {host}: {e}"))
}

/// An `AsyncRead + AsyncWrite` wrapper that replays buffered `prefix` bytes before reading from `inner`.
/// Used by `tls.upgrade_server` when the caller has already read leading ClientHello bytes.
pub(crate) struct PrefixedIo<T> {
    prefix: Vec<u8>,
    pos: usize,
    inner: T,
}

impl<T> PrefixedIo<T> {
    pub(crate) fn new(prefix: Vec<u8>, inner: T) -> Self {
        Self { prefix, pos: 0, inner }
    }
}

impl<T: AsyncRead + Unpin> AsyncRead for PrefixedIo<T> {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        if this.pos < this.prefix.len() {
            let remaining = &this.prefix[this.pos..];
            let n = remaining.len().min(buf.remaining());
            buf.put_slice(&remaining[..n]);
            this.pos += n;
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut this.inner).poll_read(cx, buf)
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for PrefixedIo<T> {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

/// Combines independent boxed `AsyncRead` and `AsyncWrite` halves back into a single duplex stream.
pub(crate) struct CombinedIo {
    read: Box<dyn AsyncRead + Send + Unpin>,
    write: Box<dyn AsyncWrite + Send + Unpin>,
}

impl CombinedIo {
    pub(crate) fn new(read: Box<dyn AsyncRead + Send + Unpin>, write: Box<dyn AsyncWrite + Send + Unpin>) -> Self {
        Self { read, write }
    }
}

impl AsyncRead for CombinedIo {
    fn poll_read(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.get_mut().read).poll_read(cx, buf)
    }
}

impl AsyncWrite for CombinedIo {
    fn poll_write(self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut *self.get_mut().write).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.get_mut().write).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut *self.get_mut().write).poll_shutdown(cx)
    }
}

/// Dial a single TCP+TLS connection to `(host, port)` verifying SNI & certificate against `sni`.
async fn dial_tls_once(host: String, port: u16, sni: ServerName<'static>, tls: Arc<rustls::ClientConfig>) -> Result<ClientTlsStream<TcpStream>, String> {
    let tcp = tcp_connect_keepalive(&host, port).await?;
    TlsConnector::from(tls).connect(sni, tcp).await.map_err(|e| format!("tls handshake ({host}:{port}): {e}"))
}

/// Regional entry race connector aligned with `station/src/cloud/transport.ts` `dialCloud`:
/// - Starts direct dial to `(direct.0, direct.1)` with SNI/cert verification bound to `sni_host`.
/// - If direct fails or does not finish within `hedge`, starts a second dial to `(entry.0, entry.1)`
///   with SNI/cert verification still bound to `sni_host`.
/// - Both candidates share `budget`. Whichever finishes verified TLS handshake first wins; the other
///   candidate's future (and its underlying TCP/TLS socket) is dropped immediately.
/// - Each candidate performs at most 1 TLS handshake; no application bytes are ever sent here.
pub(crate) async fn race_tls_stream(
    direct: (String, u16),
    entry: (String, u16),
    sni_host: &str,
    tls: Arc<rustls::ClientConfig>,
    hedge: Duration,
    budget: Duration,
) -> Result<ClientTlsStream<TcpStream>, String> {
    let sni = server_name_of(sni_host)?;
    let racing = async move {
        type DialFut = Pin<Box<dyn Future<Output = Result<ClientTlsStream<TcpStream>, String>> + Send>>;

        let mut direct_fut: Option<DialFut> = Some(Box::pin(dial_tls_once(direct.0, direct.1, sni.clone(), tls.clone())));
        let mut entry_fut: Option<DialFut> = None;
        let mut entry_started = false;
        let mut failures: Vec<String> = Vec::new();

        // timer: delayed connection hedge before starting the regional entry candidate
        let hedge_sleep = tokio::time::sleep(hedge);
        tokio::pin!(hedge_sleep);
        let mut hedge_armed = true;

        loop {
            tokio::select! {
                res = async { direct_fut.as_mut().unwrap().await }, if direct_fut.is_some() => {
                    direct_fut = None;
                    match res {
                        Ok(stream) => {
                            // Drop loser immediately so its TCP/TLS socket closes right away.
                            drop(entry_fut);
                            return Ok(stream);
                        }
                        Err(e) => {
                            failures.push(format!("direct: {e}"));
                            if !entry_started {
                                entry_started = true;
                                hedge_armed = false;
                                entry_fut = Some(Box::pin(dial_tls_once(entry.0.clone(), entry.1, sni.clone(), tls.clone())));
                            } else if entry_fut.is_none() {
                                return Err(format!("TLS race failed: {}", failures.join("; ")));
                            }
                        }
                    }
                }
                _ = &mut hedge_sleep, if hedge_armed => {
                    hedge_armed = false;
                    if !entry_started {
                        entry_started = true;
                        entry_fut = Some(Box::pin(dial_tls_once(entry.0.clone(), entry.1, sni.clone(), tls.clone())));
                    }
                }
                res = async { entry_fut.as_mut().unwrap().await }, if entry_fut.is_some() => {
                    entry_fut = None;
                    match res {
                        Ok(stream) => {
                            // Drop loser immediately so its TCP/TLS socket closes right away.
                            drop(direct_fut);
                            return Ok(stream);
                        }
                        Err(e) => {
                            failures.push(format!("entry: {e}"));
                            if direct_fut.is_none() {
                                return Err(format!("TLS race failed: {}", failures.join("; ")));
                            }
                        }
                    }
                }
            }
        }
    };

    // timer: shared timeout budget for direct + regional entry TLS race
    tokio::time::timeout(budget, racing)
        .await
        .map_err(|_| format!("TLS race timed out within {} ms", budget.as_millis()))?
}

/// Upgrade an accepted raw TCP socket (plus optional pre-read `head` bytes) to a server-side TLS stream
/// using a pre-validated `rustls::ServerConfig`.
pub(crate) async fn upgrade_server_tls_with_config(
    read: Box<dyn AsyncRead + Send + Unpin>,
    write: Box<dyn AsyncWrite + Send + Unpin>,
    head: Vec<u8>,
    config: Arc<rustls::ServerConfig>,
    timeout: Option<Duration>,
) -> Result<Handle, String> {
    let io = PrefixedIo::new(head, CombinedIo::new(read, write));
    let accept = TlsAcceptor::from(config).accept(io);
    let tls_stream = match timeout {
        // timer: caller-specified deadline on server-side TLS handshake
        Some(d) => tokio::time::timeout(d, accept)
            .await
            .map_err(|_| format!("tls.upgrade_server timed out within {} ms", d.as_millis()))?,
        None => accept.await,
    }
    .map_err(|e| format!("tls.upgrade_server: {e}"))?;
    let (r, w) = tokio::io::split(tls_stream);
    Ok(Handle::tcp(r, w))
}

/// Dial an outbound client TLS connection to `(host, port)`, optionally writing `head` bytes after handshake.
pub(crate) async fn connect_client_tls(
    host: &str,
    port: u16,
    sni: Option<&str>,
    ca_pem: Option<&str>,
    alpn: Option<&[String]>,
    timeout: Option<Duration>,
    head: Option<Vec<u8>>,
) -> Result<Handle, String> {
    let sni_name = server_name_of(sni.unwrap_or(host))?;
    let config = Arc::new(match ca_pem {
        Some(pem) => tls_config_with_strict_ca(pem, alpn)?,
        None => tls_config_with_ca(None, alpn),
    });
    let host_owned = host.to_string();
    let work = async move {
        let tcp = tcp_connect_keepalive(&host_owned, port).await?;
        let mut tls_stream = TlsConnector::from(config)
            .connect(sni_name, tcp)
            .await
            .map_err(|e| format!("tls.connect: {e}"))?;
        if let Some(bytes) = head.filter(|b| !b.is_empty()) {
            tls_stream.write_all(&bytes).await.map_err(err)?;
            tls_stream.flush().await.map_err(err)?;
        }
        let (r, w) = tokio::io::split(tls_stream);
        Ok::<Handle, String>(Handle::tcp(r, w))
    };
    match timeout {
        // timer: caller-specified deadline on outbound TLS connect + handshake
        Some(d) => tokio::time::timeout(d, work).await.map_err(|_| format!("tls.connect timed out within {} ms", d.as_millis()))?,
        None => work.await,
    }
}

#[cfg(test)]
pub(crate) mod test_certs {
    /// Test CA cert (EC P-256, valid 2026-2046, CN=stillfail-test-ca).
    pub(crate) const CA_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIBfDCCASKgAwIBAgIUAtCt4EKJlRT1LC5aVNFN40aZxdYwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRc3RpbGxmYWlsLXRlc3QtY2EwHhcNMjYxMTI2MTMyMDQ3WhcN
NDYxMTIxMTMyMDQ3WjAcMRowGAYDVQQDDBFzdGlsbGZhaWwtdGVzdC1jYTBZMBMG
ByqGSM49AgEGCCqGSM49AwEHA0IABESephPjSQKUzzpt2kp4C3dHEA1dtKPCWAf8
HpRrfgSOwbjAl4eXQRjNyDzxvlEIH2HgRKCbxry0V691+Y4G7g2jQjBAMB0GA1Ud
DgQWBBRrSzGH9XwzZYuU/07CQD7/YTsTUDAPBgNVHRMBAf8EBTADAQH/MA4GA1Ud
DwEB/wQEAwIBBjAKBggqhkjOPQQDAgNIADBFAiEAz4Rq3UAiZJ9lniGWOA3wgzpe
pr8AbwnU2laNtdEXPuICIAg1lC6kPQDcJ6IRxv7FUi3gK43QJNss902SieBPcr/Q
-----END CERTIFICATE-----
";

    /// Leaf cert signed by CA_PEM with SAN DNS:localhost, DNS:cloud.test, IP:127.0.0.1.
    pub(crate) const LEAF_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIBgjCCASigAwIBAgIUV6v+Fell270mRT4j9tQBAfmhU/cwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRc3RpbGxmYWlsLXRlc3QtY2EwHhcNMjYxMTI2MTMyMDQ3WhcN
NDYxMTIxMTMyMDQ3WjAVMRMwEQYDVQQDDApjbG91ZC50ZXN0MFkwEwYHKoZIzj0C
AQYIKoZIzj0DAQcDQgAE/vI6icEBOMgAPjGiZNk8rGJ5xckVwGe/+EXSWAzpgIpx
ZNzGyvT7kJuRCQMdSwOK5seSU7hOvuGR+HHjqkoPZKNPME0wJgYDVR0RBB8wHYIJ
bG9jYWxob3N0ggpjbG91ZC50ZXN0hwR/AAABMA4GA1UdDwEB/wQEAwIHgDATBgNV
HSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNIADBFAiEAiywmekYrfcraekSP
/6byGL+/UNAhLu/YCbAZCjwvT/QCIAe91jHEEJmmbISgUMn1F7NZdc1rUb4eoxiR
v8qfaVf2
-----END CERTIFICATE-----
";

    /// PKCS#8 private key matching LEAF_PEM.
    pub(crate) const LEAF_PKCS8_KEY: &str = "\
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgpa7hF5adGKb78jwb
UrgoxQT5uLWzbUeWN5a6mkHP/CyhRANCAAT+8jqJwQE4yAA+MaJk2TysYnnFyRXA
Z7/4RdJYDOmAinFk3MbK9PuQm5EJAx1LA4rmx5JTuE6+4ZH4ceOqSg9k
-----END PRIVATE KEY-----
";

    /// SEC1 EC private key matching LEAF_PEM.
    pub(crate) const LEAF_SEC1_KEY: &str = "\
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIKWu4ReWnRim+/I8G1K4KMUE+bi1s21HljeWuppBz/wsoAoGCCqGSM49
AwEHoUQDQgAE/vI6icEBOMgAPjGiZNk8rGJ5xckVwGe/+EXSWAzpgIpxZNzGyvT7
kJuRCQMdSwOK5seSU7hOvuGR+HHjqkoPZA==
-----END EC PRIVATE KEY-----
";

    /// Leaf cert signed by CA_PEM with SAN DNS:other.test (for SNI mismatch tests).
    pub(crate) const WRONG_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIBcjCCARegAwIBAgIUV6v+Fell270mRT4j9tQBAfmhU/gwCgYIKoZIzj0EAwIw
HDEaMBgGA1UEAwwRc3RpbGxmYWlsLXRlc3QtY2EwHhcNMjYxMTI2MTMyMDQ3WhcN
NDYxMTIxMTMyMDQ3WjAVMRMwEQYDVQQDDApvdGhlci50ZXN0MFkwEwYHKoZIzj0C
AQYIKoZIzj0DAQcDQgAENkXh+NA9EcBmwIzKP1Swf/8Y58soHDFUzATY0qDtWrM0
egeaymo9801+VTqogwGTs9H2dri64u087nfmMff5oKM+MDwwFQYDVR0RBA4wDIIK
b3RoZXIudGVzdDAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEw
CgYIKoZIzj0EAwIDSQAwRgIhAMcsfl4PQUCWbY3CXEMWQSCIDS3JzOMNcTi5rtJ2
vmiBAiEAnp4gKhalRZxPgMG3sK5oRksYOcnxOrtpT/6i1XWFmBs=
-----END CERTIFICATE-----
";

    /// PKCS#8 private key matching WRONG_PEM.
    pub(crate) const WRONG_PKCS8_KEY: &str = "\
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg6tJgn0ZsfZvx8agP
ZBgbkzuASfC8coVccOMMQYJSpHWhRANCAAQ2ReH40D0RwGbAjMo/VLB//xjnyygc
MVTMBNjSoO1aszR6B5rKaj3zTX5VOqiDAZOz0fZ2uLri7Tzud+Yx9/mg
-----END PRIVATE KEY-----
";

    /// Self-signed RSA cert + PKCS#1 private key (to verify PKCS#1 key loading).
    pub(crate) const RSA_PEM: &str = "\
-----BEGIN CERTIFICATE-----
MIIC6DCCAdCgAwIBAgIUUVCqULzyvzcsPX9hogTGH+Ab8uAwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTEyNjEzMjA1NFoXDTQ2MTEy
MTEzMjA1NFowFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA0wCOjZhQOpktTq5TqbqFZT+hRESbwS+9JptnNFa9Ro4Q
oSBdNy38cWmi2JPYmJJ9IvPSbzXWmB/T6SJGx2faaRvLqbSQD4P/ed2fM4K5a06N
v4qfttXRdxDDB44kX7yCU5/mi7+Xla/9mGaKGiF7ZSef9Fs3ERTPsOfmHSE+U4d6
rCB54+3IBklhv14/q6y+2kLICGzg37zDZB6cH5L7n+ZaNcyBtfy3jwghGKUJFoMk
wiYTtCckfN27MtmNBQVdR7bMXA8d1QmEahgoCjNHiluGwPsxG5HzrAK8ZFbg/b5n
FnWqr8cA0XRpgUeHV0R1HIC6FqOHvP8RBRq41CS22wIDAQABozIwMDAdBgNVHQ4E
FgQUT2YKPK3WqNWJoCi1tUKXUWFeh28wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG
9w0BAQsFAAOCAQEAV1CRWftMjhMxXVz8Hg+8Z9I1SWFzhi9cmShB5u61lpTJh06Q
KXjwLPf5K8YhqO+FZJ+PTFbuabgbM+HoDTPmNhfrmGaSgbNkgMU0wOtneS4WHG3e
l1ZJexIp//9W+D170atVolI6fxrK/w1Q+r/hgucUQBsYgTMAQeI68ymv+Y0j+0H+
jqTj5tLgI7HQh8VFrtBv9Xx/Gs9/aXOaa/c6HIWcdw+LZDk/OiMCuqMcBJjK2glP
7EnYN+5ZuXzWJhk9B04aek9c9XVvIOGj4aCEwEcB5rNevzyw6/oyQ0K7j4XpN0Az
n7ddsz+4lckFRWan48KNTTw6RMIEgzSlxcQZ3w==
-----END CERTIFICATE-----
";

    pub(crate) const RSA_PKCS1_KEY: &str = "\
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0wCOjZhQOpktTq5TqbqFZT+hRESbwS+9JptnNFa9Ro4QoSBd
Ny38cWmi2JPYmJJ9IvPSbzXWmB/T6SJGx2faaRvLqbSQD4P/ed2fM4K5a06Nv4qf
ttXRdxDDB44kX7yCU5/mi7+Xla/9mGaKGiF7ZSef9Fs3ERTPsOfmHSE+U4d6rCB5
4+3IBklhv14/q6y+2kLICGzg37zDZB6cH5L7n+ZaNcyBtfy3jwghGKUJFoMkwiYT
tCckfN27MtmNBQVdR7bMXA8d1QmEahgoCjNHiluGwPsxG5HzrAK8ZFbg/b5nFnWq
r8cA0XRpgUeHV0R1HIC6FqOHvP8RBRq41CS22wIDAQABAoIBAE3i/TwANtFCnKpY
CDL1UmtK3x0DlFjt5cz7/U8hG5IRO8s2VqJZO7+jhkSa4o+DN2TxCsMZZQLXcNI0
YFsYF1PIOlgE+k5345SY/by2avpUz1cedRE5AS6JxewiiIO8YoE624/HY82R3rLk
WuMFa/atd0psZznLbFT5bQRgspCDHHnxTNeHYfqWjr5lCikThVTw9oFrl7CPEZrl
gm3pTy5QflP60qQ2NTdLixClwFuMEQ0yibMyxOThE+gkY7vOb8wFtqzXiODAY6DV
eEwgsJzjPFom1IRng+4CFmdShtFmhk5uIIWnkVXJPLjvNcjwcKuVB4bV4nzL1mcQ
Gt1SlkkCgYEA+cvI9H4QESurswUCaeNzo++U0oRgXSimWHep75ZrdOZ53L6T3zT6
beQcjZ8d2FX5c3uC7/wz1M13Rssp1k5J1OrqUX/VlGzsBci2X/PRgvIp7oGY/ZLH
ck90NuklQNJM34rq9erx6Rnw7a1xgBk/qoAc70/ajRJl3lbVABIcJXkCgYEA2D4e
YRuj0vikg+Av7G1HCEbKF6vTkgP1ncbklpK77NjIShg1A64gu81g5b6GssR7BOjn
ewvAXhCZKWaxnVMwYsZcli19H4SUHg9V6C1QULfg5xYdw6Vc2qCwspl5w2NclGs5
chkM1FCcepUOxJPzByw6BdvH+clByrzkQT42DfMCgYAr/xei8H01+QIh4tT8/4HD
sxP8TDKI1fsOg+0bdNvyWBHIroxu+O7O4imhTBA+pU3taCi0yi/64EGM54Wz6FAa
v1GMDz74CIM9tY9hsRkKvkpiZtMifnLAkHwAm+ni0+eUS+x8aeg3zUjhI/ZkwI21
IyF1iRQOWto0YgjcHVR1yQKBgQCQ+3Ua3pFETfjfglwfRFUvs2aj4EyFxanUExoH
6nGdJuuC4iAJS6IeyGCDKO7exOVGMXGiCgr8BlzqaTQEq1Xxo9VHy0/s5dL5JIcQ
l/EVbXOY/DcQibpryvkthcEhw2i7CfkGCs2TPEjt1yqDmj6DPJ/adbTqQImgCG1x
YOiVCQKBgQDDXgTZdC+jBIxXI6dlTqbBhAVEMk+BlWXUekhFTP3Ht3Y58nXuLZlG
eaHBH379bjYMd0jl4yqrqe6O9zlGZaogKAEmrtO4s3xSTlkZkzWeXnRwgNVnp7kp
Dx4Quq7lEsD5Jmg+IIOTLWo5tzMC88l0G3qmzzKo5bvlmD7QYLODwQ==
-----END RSA PRIVATE KEY-----
";
}

#[cfg(test)]
mod tests {
    use super::test_certs::*;
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::AsyncReadExt;
    use tokio::net::TcpListener;

    #[test]
    fn server_tls_config_supports_pkcs8_sec1_and_pkcs1_keys() {
        assert!(server_tls_config(LEAF_PEM, LEAF_PKCS8_KEY, Some(&["http/1.1".into()])).is_ok());
        assert!(server_tls_config(LEAF_PEM, LEAF_SEC1_KEY, None).is_ok());
        assert!(server_tls_config(RSA_PEM, RSA_PKCS1_KEY, None).is_ok());
        assert!(server_tls_config("", LEAF_PKCS8_KEY, None).is_err());
        assert!(server_tls_config(LEAF_PEM, "not-a-key", None).is_err());
    }

    #[tokio::test]
    async fn prefixed_io_replays_prefix_then_reads_inner() {
        let (mut a, b) = tokio::io::duplex(64);
        a.write_all(b"world").await.unwrap();
        a.shutdown().await.unwrap();
        let mut io = PrefixedIo::new(b"hello ".to_vec(), b);
        let mut out = Vec::new();
        io.read_to_end(&mut out).await.unwrap();
        assert_eq!(out, b"hello world");
    }

    #[tokio::test]
    async fn race_tls_stream_direct_wins_without_dialing_entry() {
        let server_cfg = Arc::new(server_tls_config(LEAF_PEM, LEAF_PKCS8_KEY, None).unwrap());
        let direct_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct_port = direct_listener.local_addr().unwrap().port();
        let entry_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let entry_port = entry_listener.local_addr().unwrap().port();

        let direct_hits = Arc::new(AtomicUsize::new(0));
        let entry_hits = Arc::new(AtomicUsize::new(0));

        let dh = direct_hits.clone();
        let sc = server_cfg.clone();
        let direct_task = tokio::spawn(async move {
            let (tcp, _) = direct_listener.accept().await.unwrap();
            dh.fetch_add(1, Ordering::SeqCst);
            let mut tls = TlsAcceptor::from(sc).accept(tcp).await.unwrap();
            tls.write_all(b"direct").await.unwrap();
            tls.shutdown().await.unwrap();
        });

        let eh = entry_hits.clone();
        let entry_task = tokio::spawn(async move {
            if let Ok((_tcp, _)) = entry_listener.accept().await {
                eh.fetch_add(1, Ordering::SeqCst);
            }
        });

        let client_cfg = Arc::new(tls_config_with_ca(Some(CA_PEM), None));
        let mut stream = race_tls_stream(
            ("127.0.0.1".into(), direct_port),
            ("127.0.0.1".into(), entry_port),
            "cloud.test",
            client_cfg,
            Duration::from_secs(5),
            Duration::from_secs(5),
        )
        .await
        .unwrap();

        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.unwrap();
        assert_eq!(buf, b"direct");
        direct_task.await.unwrap();
        entry_task.abort();
        assert_eq!(direct_hits.load(Ordering::SeqCst), 1);
        assert_eq!(entry_hits.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn race_tls_stream_direct_stalled_entry_wins_and_closes_loser() {
        let server_cfg = Arc::new(server_tls_config(LEAF_PEM, LEAF_PKCS8_KEY, None).unwrap());
        let direct_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct_port = direct_listener.local_addr().unwrap().port();
        let entry_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let entry_port = entry_listener.local_addr().unwrap().port();

        let direct_hits = Arc::new(AtomicUsize::new(0));
        let entry_hits = Arc::new(AtomicUsize::new(0));

        // Direct accepts TCP but never completes TLS; verify the client closes it once entry wins.
        let dh = direct_hits.clone();
        let direct_closed = tokio::spawn(async move {
            let (mut tcp, _) = direct_listener.accept().await.unwrap();
            dh.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 512];
            // Read ClientHello then wait for EOF from loser cancellation.
            let _ = tcp.read(&mut buf).await;
            loop {
                match tcp.read(&mut buf).await {
                    Ok(0) | Err(_) => return true,
                    Ok(_) => continue,
                }
            }
        });

        let eh = entry_hits.clone();
        let sc = server_cfg.clone();
        let entry_task = tokio::spawn(async move {
            let (tcp, _) = entry_listener.accept().await.unwrap();
            eh.fetch_add(1, Ordering::SeqCst);
            let mut tls = TlsAcceptor::from(sc).accept(tcp).await.unwrap();
            tls.write_all(b"entry").await.unwrap();
            tls.shutdown().await.unwrap();
        });

        let client_cfg = Arc::new(tls_config_with_strict_ca(CA_PEM, None).unwrap());
        let mut stream = race_tls_stream(
            ("127.0.0.1".into(), direct_port),
            ("127.0.0.1".into(), entry_port),
            "cloud.test",
            client_cfg,
            Duration::from_millis(20),
            Duration::from_secs(5),
        )
        .await
        .unwrap();

        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.unwrap();
        assert_eq!(buf, b"entry");
        entry_task.await.unwrap();
        // timer: test assertion deadline verifying loser socket closed promptly
        assert!(tokio::time::timeout(Duration::from_secs(2), direct_closed).await.unwrap().unwrap());
        assert_eq!(direct_hits.load(Ordering::SeqCst), 1);
        assert_eq!(entry_hits.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn race_tls_stream_direct_fails_immediately_switches_to_entry_without_hedge_wait() {
        // Bind and immediately drop to obtain a closed port (ECONNREFUSED).
        let closed_port = {
            let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
            l.local_addr().unwrap().port()
        };
        let server_cfg = Arc::new(server_tls_config(LEAF_PEM, LEAF_PKCS8_KEY, None).unwrap());
        let entry_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let entry_port = entry_listener.local_addr().unwrap().port();
        let entry_hits = Arc::new(AtomicUsize::new(0));

        let eh = entry_hits.clone();
        let entry_task = tokio::spawn(async move {
            let (tcp, _) = entry_listener.accept().await.unwrap();
            eh.fetch_add(1, Ordering::SeqCst);
            let mut tls = TlsAcceptor::from(server_cfg).accept(tcp).await.unwrap();
            tls.write_all(b"fast-entry").await.unwrap();
            tls.shutdown().await.unwrap();
        });

        // Hedge (60s) exceeds budget (5s): if direct failure did not bypass hedge immediately,
        // the race would time out instead of succeeding via entry.
        let client_cfg = Arc::new(tls_config_with_strict_ca(CA_PEM, None).unwrap());
        let mut stream = race_tls_stream(
            ("127.0.0.1".into(), closed_port),
            ("127.0.0.1".into(), entry_port),
            "cloud.test",
            client_cfg,
            Duration::from_secs(60),
            Duration::from_secs(5),
        )
        .await
        .unwrap();

        let mut buf = Vec::new();
        stream.read_to_end(&mut buf).await.unwrap();
        assert_eq!(buf, b"fast-entry");
        entry_task.await.unwrap();
        assert_eq!(entry_hits.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn race_tls_stream_rejects_certificate_sni_mismatch() {
        let wrong_cfg = Arc::new(server_tls_config(WRONG_PEM, WRONG_PKCS8_KEY, None).unwrap());
        let direct_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct_port = direct_listener.local_addr().unwrap().port();
        let entry_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let entry_port = entry_listener.local_addr().unwrap().port();

        let sc1 = wrong_cfg.clone();
        let t1 = tokio::spawn(async move {
            if let Ok((tcp, _)) = direct_listener.accept().await {
                let _ = TlsAcceptor::from(sc1).accept(tcp).await;
            }
        });
        let sc2 = wrong_cfg.clone();
        let t2 = tokio::spawn(async move {
            if let Ok((tcp, _)) = entry_listener.accept().await {
                let _ = TlsAcceptor::from(sc2).accept(tcp).await;
            }
        });

        let client_cfg = Arc::new(tls_config_with_strict_ca(CA_PEM, None).unwrap());
        let res = race_tls_stream(
            ("127.0.0.1".into(), direct_port),
            ("127.0.0.1".into(), entry_port),
            "cloud.test",
            client_cfg,
            Duration::from_millis(20),
            Duration::from_secs(5),
        )
        .await;
        assert!(res.is_err(), "cert for other.test must be rejected when SNI is cloud.test");
        let _ = tokio::join!(t1, t2);
    }

    #[tokio::test]
    async fn race_tls_stream_timeout_closes_all_pending_connections() {
        let direct_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct_port = direct_listener.local_addr().unwrap().port();
        let entry_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let entry_port = entry_listener.local_addr().unwrap().port();

        let (d_acc_tx, d_acc_rx) = tokio::sync::oneshot::channel();
        let (e_acc_tx, e_acc_rx) = tokio::sync::oneshot::channel();

        let wait_eof = |listener: TcpListener, accepted_tx: tokio::sync::oneshot::Sender<()>| {
            tokio::spawn(async move {
                let (mut tcp, _) = listener.accept().await.unwrap();
                let _ = accepted_tx.send(());
                let mut buf = [0u8; 512];
                loop {
                    match tcp.read(&mut buf).await {
                        Ok(0) | Err(_) => return true,
                        Ok(_) => continue,
                    }
                }
            })
        };
        let d_eof = wait_eof(direct_listener, d_acc_tx);
        let e_eof = wait_eof(entry_listener, e_acc_tx);

        let client_cfg = Arc::new(tls_config_with_strict_ca(CA_PEM, None).unwrap());
        let race_task = tokio::spawn(race_tls_stream(
            ("127.0.0.1".into(), direct_port),
            ("127.0.0.1".into(), entry_port),
            "cloud.test",
            client_cfg,
            Duration::from_millis(20),
            Duration::from_secs(60),
        ));

        // Confirm both direct and entry listeners accepted before pausing time and triggering timeout.
        // timer: test assertion deadline waiting for both listeners to accept TCP connections
        tokio::time::timeout(Duration::from_secs(5), d_acc_rx).await.unwrap().unwrap();
        // timer: test assertion deadline waiting for both listeners to accept TCP connections
        tokio::time::timeout(Duration::from_secs(5), e_acc_rx).await.unwrap().unwrap();

        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(61)).await;

        let err_msg = race_task.await.unwrap().expect_err("race must time out when both stall");
        assert!(err_msg.contains("timed out"), "unexpected error: {err_msg}");
        tokio::time::resume();
        // timer: test assertion deadline verifying both pending sockets closed on timeout
        assert!(tokio::time::timeout(Duration::from_secs(2), d_eof).await.unwrap().unwrap());
        // timer: test assertion deadline verifying both pending sockets closed on timeout
        assert!(tokio::time::timeout(Duration::from_secs(2), e_eof).await.unwrap().unwrap());
    }

    #[test]
    fn tls_config_with_strict_ca_rejects_empty_or_malformed_pem() {
        assert!(tls_config_with_strict_ca(CA_PEM, None).is_ok());
        assert!(tls_config_with_strict_ca("", None).is_err());
        assert!(tls_config_with_strict_ca("-----BEGIN CERTIFICATE-----\nnot-base64!!!\n-----END CERTIFICATE-----\n", None).is_err());
    }
}
