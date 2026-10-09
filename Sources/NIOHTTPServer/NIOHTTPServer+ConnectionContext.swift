//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
public import X509

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    /// The application-level HTTP version negotiated for a connection.
    @nonexhaustive
    public enum HTTPVersion: String, Sendable, Hashable, CaseIterable {
        case plaintextHTTP1_1 = "Plaintext HTTP/1.1"
        case http1_1 = "HTTP/1.1"
        case http2 = "HTTP/2"
        #if HTTP3
        case http3 = "HTTP/3"
        #endif
    }
}

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    /// Connection-scoped state.
    ///
    /// Carries connection-scoped data such as the negotiated HTTP version, the
    /// peer / local addresses, and the peer's validated certificate chain (when
    /// applicable), along with the events that happen on the connection.
    ///
    /// User code accesses this state via the corresponding ``RequestContext``
    /// capabilities (``HTTPServerCapability/ConnectionInfo``,
    /// ``HTTPServerCapability/PeerCertificate``,
    /// ``HTTPServerCapability/ConnectionEvents``) when handling individual
    /// requests, and directly when implementing an
    /// ``NIOHTTPServerConnectionHandler``.
    public struct ConnectionContext: Sendable {
        /// The application-level HTTP version negotiated for this connection.
        public let httpVersion: HTTPVersion

        /// The peer's address, when known.
        ///
        /// Over HTTP/3 this can change during the connection's lifetime, when the client migrates the connection to a
        /// new network path. ``connectionEvents`` reports each change.
        public var remoteAddress: NIOHTTPServer.SocketAddress? {
            self.currentRemoteAddress.withLockedValue { $0 }
        }

        /// The local address the connection is bound to, when known.
        public let localAddress: NIOHTTPServer.SocketAddress?

        /// The peer's validated certificate chain. Returns `nil` if a custom verification callback was not set when
        /// configuring mTLS in the server configuration, or if the custom verification callback did not return the
        /// derived validated chain.
        public var validatedPeerCertificateChain: X509.ValidatedCertificateChain?

        /// The events that happen on this connection, such as the peer's address changing.
        ///
        /// The sequence finishes once the connection closes. See ``ConnectionEvents``.
        public let connectionEvents: ConnectionEvents

        /// Shared by every copy of this context, so that the connection's ``ConnectionEventsHandler`` keeps them all
        /// current.
        private let currentRemoteAddress: NIOLockedValueBox<NIOHTTPServer.SocketAddress?>

        init(
            httpVersion: HTTPVersion,
            remoteAddress: NIOHTTPServer.SocketAddress? = nil,
            localAddress: NIOHTTPServer.SocketAddress? = nil,
            validatedPeerCertificateChain: X509.ValidatedCertificateChain? = nil
        ) {
            self.httpVersion = httpVersion
            self.currentRemoteAddress = NIOLockedValueBox(remoteAddress)
            self.localAddress = localAddress
            self.validatedPeerCertificateChain = validatedPeerCertificateChain
            self.connectionEvents = ConnectionEvents(broadcaster: ConnectionEventBroadcaster())
        }

        /// Applies `event` to this context, then delivers it to every iterator of ``connectionEvents``.
        func apply(_ event: ConnectionEvent) {
            switch event {
            case .remoteAddressChanged(let address):
                self.currentRemoteAddress.withLockedValue { $0 = address }
            }

            self.connectionEvents.broadcaster.yield(event)
        }

        /// Ends every iterator of ``connectionEvents``, now that the connection has closed.
        func finishConnectionEvents() {
            self.connectionEvents.broadcaster.finish()
        }
    }
}
