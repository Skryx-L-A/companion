// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The daemon's own certificate, and the client certificates it signs.
//!
//! `DESIGN.md` § Mobil, Identität und Vertrauen: the daemon makes one long-lived,
//! self-signed certificate on its first start and keeps the private key. Its fingerprint
//! travels in the pairing QR, the app pins it, and from then on nobody between the app and
//! the daemon can pretend to be the daemon — they would need the key.
//!
//! **Why rcgen.** Three ways to get a certificate were open. Shelling out to `openssl`
//! makes a build depend on a program that is not always there and whose output has to be
//! parsed; linking the openssl crate pulls a C library and its build machinery into a
//! workspace that has neither. rcgen is a small, pure-Rust library written for exactly this
//! one job, it already speaks the DER that rustls wants, and with the `ring` backend it
//! needs no cmake and no assembler. The same argument picks the `ring` provider for rustls
//! over the default aws-lc-rs.
//!
//! **Why one certificate and not two.** The daemon's certificate is its own issuer: it is
//! the TLS server certificate *and* the authority that signs the client certificates handed
//! out during pairing. A separate leaf under a separate authority would be tidier in a
//! world with certificate chains, but here the app pins one fingerprint, and a leaf that is
//! ever renewed would break that pin. One certificate, one fingerprint, one thing to trust.

use std::path::{Path, PathBuf};

use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::paths::write_private_file;

/// What the certificate calls itself. Fixed rather than derived from the machine name,
/// because the issuer name of a signed client certificate has to keep matching it, and a
/// person may rename their machine at any time.
const COMMON_NAME: &str = "companion daemon";

/// The names the certificate is valid for.
///
/// Barely load-bearing: a client pins the fingerprint out of the QR rather than checking a
/// name. They are here so an ordinary TLS tool pointed at the daemon says something useful
/// instead of failing before it gets to the fingerprint.
const SUBJECT_NAMES: [&str; 4] = ["localhost", "companion.local", "127.0.0.1", "::1"];

#[derive(Debug, Error)]
pub enum CertificateError {
    #[error("the certificate could not be made: {0}")]
    Generate(#[from] rcgen::Error),
    #[error("io error on {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{path} holds no {what}")]
    Empty { path: String, what: &'static str },
}

/// The certificate this daemon shows and the key behind it.
#[derive(Clone)]
pub struct DaemonCertificate {
    certificate_pem: String,
    key_pem: String,
    certificate_der: Vec<u8>,
    fingerprint: String,
}

/// Never prints the private key.
///
/// The same hand-written `Debug` every sibling in this house has ([`ClientCertificate`],
/// `Tokens`, `PendingPairing`): this key is the anchor the whole pinning stands on, and a
/// derived `Debug` would put it into the log the first time somebody writes
/// `tracing::debug!(?certificate, …)`. The fingerprint is not a secret and stays, because it
/// is the one field such a log line is usually looking for.
impl std::fmt::Debug for DaemonCertificate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DaemonCertificate")
            .field("certificate_pem", &"[…]")
            .field("key_pem", &"[redacted]")
            .field(
                "certificate_der",
                &format_args!("{} bytes", self.certificate_der.len()),
            )
            .field("fingerprint", &self.fingerprint)
            .finish()
    }
}

impl DaemonCertificate {
    /// Reads the certificate of this machine, making one on the first call.
    ///
    /// Both halves have to be there together: a key without its certificate, or the other
    /// way round, is a half-written first start, and the pair is made again rather than
    /// puzzled together.
    pub fn load_or_create(
        certificate_path: &Path,
        key_path: &Path,
    ) -> Result<Self, CertificateError> {
        if let (Some(certificate_pem), Some(key_pem)) =
            (read_optional(certificate_path)?, read_optional(key_path)?)
        {
            return Self::from_pem(certificate_pem, key_pem, certificate_path);
        }

        let key = KeyPair::generate()?;
        let certificate = ca_params()?.self_signed(&key)?;
        let certificate_pem = certificate.pem();
        let key_pem = key.serialize_pem();

        write(certificate_path, &certificate_pem)?;
        write(key_path, &key_pem)?;
        Self::from_pem(certificate_pem, key_pem, certificate_path)
    }

    fn from_pem(
        certificate_pem: String,
        key_pem: String,
        path: &Path,
    ) -> Result<Self, CertificateError> {
        let certificate_der = first_certificate_der(&certificate_pem, path)?;
        let fingerprint = fingerprint_of(&certificate_der);
        Ok(Self {
            certificate_pem,
            key_pem,
            certificate_der,
            fingerprint,
        })
    }

    /// The certificate in PEM form, as it sits on disk.
    pub fn certificate_pem(&self) -> &str {
        &self.certificate_pem
    }

    /// The private key in PEM form. Never leaves the machine.
    pub fn key_pem(&self) -> &str {
        &self.key_pem
    }

    /// The certificate in DER form, which is what a TLS stack wants.
    pub fn certificate_der(&self) -> &[u8] {
        &self.certificate_der
    }

    /// SHA-256 of the DER form, lower-case hex. This is what the QR carries and what the
    /// app pins.
    pub fn fingerprint(&self) -> &str {
        &self.fingerprint
    }

    /// A client certificate for one paired device, signed by this one.
    ///
    /// `DESIGN.md` § Mobil: redeeming a pairing code hands out the device token and this
    /// certificate in the same step, so the later mutual-TLS way needs no second exchange.
    pub fn issue_client(&self, subject: &str) -> Result<ClientCertificate, CertificateError> {
        let issuer_key = KeyPair::from_pem(&self.key_pem)?;
        let issuer = Issuer::new(ca_params()?, issuer_key);

        let client_key = KeyPair::generate()?;
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        let mut name = DistinguishedName::new();
        name.push(DnType::CommonName, subject);
        params.distinguished_name = name;
        params.is_ca = IsCa::NoCa;
        params.use_authority_key_identifier_extension = true;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];

        // No `not_after`, so rcgen's default runs to the year 4096. `DESIGN.md` § Mobil says
        // so in as many words — client certificates "laufen nie ab und sind nicht
        // widerrufbar" — and hangs the identity of a device on its token instead, which the
        // daemon really can revoke. The security review of 2026-09-03 named the consequence
        // rather than a defect: when the mutual-TLS transport is built, presenting a
        // structurally valid certificate must not be treated as authorisation. It proves the
        // device was paired once, never that it still is; that answer comes from
        // `DeviceDirectory::authenticate`. Putting an expiry on the leaf would be a change to
        // that sentence in DESIGN and belongs to whoever builds that transport.
        let certificate = params.signed_by(&client_key, &issuer)?;
        Ok(ClientCertificate {
            certificate_pem: certificate.pem(),
            key_pem: client_key.serialize_pem(),
        })
    }
}

/// A certificate handed to one device, with the key that belongs to it.
#[derive(Clone)]
pub struct ClientCertificate {
    pub certificate_pem: String,
    /// Leaves the daemon exactly once, in the answer to the pairing.
    pub key_pem: String,
}

/// Never prints the private key.
impl std::fmt::Debug for ClientCertificate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ClientCertificate")
            .field("certificate_pem", &"[…]")
            .field("key_pem", &"[redacted]")
            .finish()
    }
}

/// SHA-256 of a DER certificate, lower-case hex.
pub fn fingerprint_of(der: &[u8]) -> String {
    Sha256::digest(der)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Where the certificate and its key live.
pub fn certificate_path(config_dir: &Path) -> PathBuf {
    config_dir.join("daemon-certificate.pem")
}

pub fn certificate_key_path(config_dir: &Path) -> PathBuf {
    config_dir.join("daemon-key.pem")
}

/// The parameters of the daemon's own certificate.
///
/// Deterministic, because [`DaemonCertificate::issue_client`] rebuilds them to name the
/// issuer of a client certificate: two runs have to produce the same distinguished name or
/// a client certificate would name an authority that does not exist. rcgen's default
/// validity runs to the year 4096, which is what "long-lived" means here — there is no
/// renewal path a phone could survive, since the app pins this certificate.
fn ca_params() -> Result<CertificateParams, rcgen::Error> {
    let names: Vec<String> = SUBJECT_NAMES
        .iter()
        .map(|name| (*name).to_owned())
        .collect();
    let mut params = CertificateParams::new(names)?;
    let mut name = DistinguishedName::new();
    name.push(DnType::CommonName, COMMON_NAME);
    params.distinguished_name = name;
    // Its own authority: the same certificate serves TLS and signs the client certificates
    // of paired devices.
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![
        KeyUsagePurpose::DigitalSignature,
        KeyUsagePurpose::KeyCertSign,
    ];
    params.extended_key_usages = vec![
        ExtendedKeyUsagePurpose::ServerAuth,
        ExtendedKeyUsagePurpose::ClientAuth,
    ];
    Ok(params)
}

fn read_optional(path: &Path) -> Result<Option<String>, CertificateError> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(source) => Err(CertificateError::Io {
            path: path.display().to_string(),
            source,
        }),
    }
}

fn write(path: &Path, text: &str) -> Result<(), CertificateError> {
    write_private_file(path, text.as_bytes()).map_err(|source| CertificateError::Io {
        path: path.display().to_string(),
        source,
    })
}

/// The first certificate of a PEM file, in DER form.
fn first_certificate_der(pem: &str, path: &Path) -> Result<Vec<u8>, CertificateError> {
    let mut reader = std::io::BufReader::new(pem.as_bytes());
    match rustls_pemfile::certs(&mut reader).next() {
        Some(entry) => {
            let der = entry.map_err(|source| CertificateError::Io {
                path: path.display().to_string(),
                source,
            })?;
            Ok(der.to_vec())
        }
        None => Err(CertificateError::Empty {
            path: path.display().to_string(),
            what: "certificate",
        }),
    }
}

/// Turns a PEM private key into DER, for a TLS stack that wants one.
pub fn private_key_der(pem: &str) -> Option<Vec<u8>> {
    let mut reader = std::io::BufReader::new(pem.as_bytes());
    rustls_pemfile::private_key(&mut reader)
        .ok()
        .flatten()
        .map(|key| key.secret_der().to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(name: &str) -> (PathBuf, PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "companion-certificate-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        (certificate_path(&dir), certificate_key_path(&dir), dir)
    }

    #[test]
    fn neither_certificate_ever_prints_its_private_key() {
        let (certificate, key, dir) = paths("debug");
        let daemon = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        let printed = format!("{daemon:?}");
        assert!(
            !printed.contains("PRIVATE KEY"),
            "the anchor of the pinning must never land in a log line: {printed}"
        );
        assert!(printed.contains(daemon.fingerprint()), "{printed}");

        let client = daemon.issue_client("d-test").unwrap();
        let printed = format!("{client:?}");
        assert!(!printed.contains("PRIVATE KEY"), "{printed}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_certificate_is_made_once_and_kept() {
        let (certificate, key, dir) = paths("stable");

        let first = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        let second = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        assert_eq!(
            first.fingerprint(),
            second.fingerprint(),
            "a second start must not change what the app pinned"
        );
        assert_eq!(first.fingerprint().len(), 64);
        assert!(
            first
                .certificate_pem()
                .starts_with("-----BEGIN CERTIFICATE")
        );

        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&key).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "the private key must stay owner-only");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_fingerprint_is_the_hash_of_what_goes_over_the_wire() {
        let (certificate, key, dir) = paths("fingerprint");
        let daemon = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        assert_eq!(
            daemon.fingerprint(),
            fingerprint_of(daemon.certificate_der()),
            "the pinned value has to be the hash of the DER the client sees"
        );
        assert!(private_key_der(daemon.key_pem()).is_some());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_client_certificate_is_signed_by_the_daemon_and_carries_its_own_key() {
        let (certificate, key, dir) = paths("client");
        let daemon = DaemonCertificate::load_or_create(&certificate, &key).unwrap();

        let first = daemon.issue_client("d-one").unwrap();
        let second = daemon.issue_client("d-two").unwrap();
        assert!(first.certificate_pem.starts_with("-----BEGIN CERTIFICATE"));
        assert_ne!(
            first.key_pem, second.key_pem,
            "two devices must never share a key"
        );
        assert_ne!(first.certificate_pem, second.certificate_pem);
        assert!(!format!("{first:?}").contains(&first.key_pem));

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn half_a_first_start_is_made_again_rather_than_puzzled_together() {
        let (certificate, key, dir) = paths("half");
        let first = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        std::fs::remove_file(&key).unwrap();

        let second = DaemonCertificate::load_or_create(&certificate, &key).unwrap();
        assert_ne!(
            first.fingerprint(),
            second.fingerprint(),
            "a certificate whose key is gone is no certificate"
        );
        assert!(private_key_der(second.key_pem()).is_some());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
