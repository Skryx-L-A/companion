// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

//! The network port: TCP with TLS, for the devices of `DESIGN.md` § Mobil.
//!
//! Off at the factory and switched on only by a person, because everything the Unix socket
//! gets for free falls away here. There the socket is 0600 inside a 0700 directory and the
//! daemon still checks the account of the peer, so a foreign process is turned away before
//! its first byte; here anybody who can reach the address may knock. What is left is the
//! certificate the device pinned when it was paired, the device token, and the attempt
//! brake behind both.
//!
//! The protocol above the transport is the same one the Unix socket speaks, served by the
//! same code: [`crate::server::serve`] takes a reader and a writer and a [`Gate`] that says
//! who may get in. Only the gate differs — device tokens instead of the two machine tokens,
//! the role `human` always, and a device that has not been paired yet may redeem a pairing
//! code instead of saying hello.

use std::sync::Arc;

use companion_core::certificate::private_key_der;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, oneshot};
use tokio::task::JoinHandle;
use tokio_rustls::TlsAcceptor;
use tracing::{debug, info, warn};

use crate::server::{Arrival, Gate, Net, ServerState, serve};

/// How many announcements of a closing port may wait for a connection.
///
/// One is enough — there is only ever the one message — but a slow reader that missed it
/// still learns from the closed channel that the port is gone.
const CLOSING_CAPACITY: usize = 1;

/// A running network listener. Dropping it leaves it running; [`NetListener::stop`] ends it.
#[derive(Debug)]
pub(crate) struct NetListener {
    address: String,
    shutdown: Option<oneshot::Sender<()>>,
    /// Told to every connection that came in through this listener when the port closes.
    closing: broadcast::Sender<()>,
    task: JoinHandle<()>,
}

impl NetListener {
    pub(crate) fn address(&self) -> &str {
        &self.address
    }

    /// Stops accepting and ends the connections that came in through this port.
    ///
    /// Both halves matter. Somebody who switches the network port off because something
    /// feels wrong means the devices that are already connected as well; a listener that
    /// only stopped accepting would leave them exactly where they were. Each connection is
    /// told why before it goes, and dropping the sender says the same thing to anybody who
    /// subscribed and has not read yet.
    pub(crate) fn stop(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        let _ = self.closing.send(());
        self.task.abort();
    }
}

/// Binds the port and starts accepting, or says why it could not.
///
/// Synchronous on the outside on purpose: turning the listener on is part of writing the
/// settings, and a settings write that returned before the port existed could report a
/// success for a port that was never taken.
pub(crate) fn start(
    address: &str,
    state: &Arc<ServerState>,
    net: &Net,
) -> Result<NetListener, String> {
    let acceptor = acceptor_for(net)?;

    let listener = std::net::TcpListener::bind(address)
        .map_err(|error| format!("cannot listen on {address}: {error}"))?;
    listener
        .set_nonblocking(true)
        .map_err(|error| format!("cannot listen on {address}: {error}"))?;
    let bound = listener
        .local_addr()
        .map(|address| address.to_string())
        .unwrap_or_else(|_| address.to_owned());
    let listener = TcpListener::from_std(listener)
        .map_err(|error| format!("cannot listen on {address}: {error}"))?;

    let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
    let (closing_tx, _) = broadcast::channel(CLOSING_CAPACITY);
    let closing = closing_tx.clone();
    let unauthenticated = Arc::clone(&net.unauthenticated);
    let brake = Arc::clone(&net.brake);
    let tls_deadline = state.tls_handshake_timeout();
    let state = Arc::clone(state);
    let task = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = &mut shutdown_rx => {
                    debug!("the network port stops accepting");
                    break;
                }
                accepted = listener.accept() => match accepted {
                    Ok((stream, peer)) => {
                        // The source of a failure is the network somebody sits in, not the
                        // exact address: over IPv6 a single machine normally has a whole
                        // /64, and a brake keyed per address would never count to two. The
                        // brake narrows that to the address itself for a /64 a device has
                        // already authenticated from, so a stranger sharing the owner's
                        // carrier segment cannot run up the wait the owner then sits out.
                        let peer = peer.ip();
                        let source = brake.source_for(peer);

                        // A connection that has not proved anything holds one of a fixed
                        // number of places. Over the limit it is closed at once instead of
                        // queued: a queue would be the same unbounded hold, one layer down.
                        let Ok(permit) = Arc::clone(&unauthenticated).try_acquire_owned()
                        else {
                            warn!(
                                source,
                                "too many connections at the network port are still \
                                 unauthenticated, closing this one"
                            );
                            continue;
                        };

                        let acceptor = acceptor.clone();
                        let state = Arc::clone(&state);
                        let closing = closing.subscribe();
                        tokio::spawn(async move {
                            // The deadline the whole TLS handshake has. Without it a TCP
                            // connection that sends no TLS at all holds a task, a socket
                            // and one of the places above for as long as somebody likes.
                            let handshake = tokio::time::timeout(
                                tls_deadline,
                                acceptor.accept(stream),
                            );
                            let stream = match handshake.await {
                                Ok(Ok(stream)) => stream,
                                Ok(Err(error)) => {
                                    debug!(%error, source, "a TLS handshake failed");
                                    return;
                                }
                                Err(_elapsed) => {
                                    debug!(source, "a TLS handshake ran out of time");
                                    return;
                                }
                            };
                            let (reader, writer) = tokio::io::split(stream);
                            let arrival = Arrival {
                                gate: Gate::Network { source, peer },
                                unauthenticated: Some(permit),
                                closing: Some(closing),
                            };
                            if let Err(error) = serve(reader, writer, state, arrival).await {
                                debug!(%error, "a device connection ended");
                            }
                        });
                    }
                    Err(error) => warn!(%error, "accept on the network port failed"),
                },
            }
        }
    });

    info!(address = %bound, "listening for devices");
    Ok(NetListener {
        address: bound,
        shutdown: Some(shutdown_tx),
        closing: closing_tx,
        task,
    })
}

/// The TLS side of the port: this daemon's own certificate, and no client certificate asked
/// for.
///
/// Not asking for one is deliberate for now. The certificate handed out at pairing is what
/// the mutual-TLS way of `DESIGN.md` § Mobil will use, and that way is built third; asking
/// for it here would lock out every device paired before it, for no gain — the device token
/// is what says who is calling, and the pinned server certificate is what says who answers.
fn acceptor_for(net: &Net) -> Result<TlsAcceptor, String> {
    let certificate = CertificateDer::from(net.certificate.certificate_der().to_vec());
    let key = private_key_der(net.certificate.key_pem())
        .ok_or_else(|| "the daemon key is not a key this build can read".to_owned())?;
    let key = PrivateKeyDer::try_from(key).map_err(|error| format!("bad daemon key: {error}"))?;

    // The provider is named rather than left to the process default: a process that never
    // installed one would otherwise fail at the first connection instead of here. The
    // version is named for the same reason and for one more: the only client this port will
    // ever have is the companion's own app, so there is nobody to be compatible with and
    // TLS 1.3 alone is the narrower door. The `tls12` feature is off in the manifest, which
    // is what makes this a compile-time fact rather than a line somebody can drop.
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .map_err(|error| format!("this build cannot speak TLS 1.3: {error}"))?
    .with_no_client_auth()
    .with_single_cert(vec![certificate], key)
    .map_err(|error| format!("the daemon certificate is not usable for TLS: {error}"))?;

    Ok(TlsAcceptor::from(Arc::new(config)))
}
