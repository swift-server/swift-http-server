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

import NIOCore
import NIOSSL
public import X509

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// The application-level HTTP version negotiated for a connection.
    public enum HTTPVersion: String, Sendable, Hashable {
        case plaintextHTTP1_1 = "Plaintext HTTP/1.1"
        case http1_1 = "HTTP/1.1"
        case http2 = "HTTP/2"
        #if HTTP3
        case http3 = "HTTP/3"
        #endif
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Connection-scoped state.
    ///
    /// Carries connection-scoped data such as the negotiated HTTP version, the
    /// peer / local addresses, and the peer's validated certificate chain (when
    /// applicable).
    ///
    /// User code accesses this state via the corresponding ``RequestContext``
    /// capabilities (``HTTPServerCapability/ConnectionInfo``,
    /// ``HTTPServerCapability/PeerCertificate``) when handling individual
    /// requests, and directly when implementing an
    /// ``NIOHTTPServerConnectionHandler``.
    public struct ConnectionContext: Sendable {
        /// The application-level HTTP version negotiated for this connection.
        public let httpVersion: HTTPVersion

        /// The peer's address, when known.
        public let remoteAddress: NIOHTTPServer.SocketAddress?

        /// The local address the connection is bound to, when known.
        public let localAddress: NIOHTTPServer.SocketAddress?

        var peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>?

        init(
            httpVersion: HTTPVersion,
            remoteAddress: NIOHTTPServer.SocketAddress? = nil,
            localAddress: NIOHTTPServer.SocketAddress? = nil,
            peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>? = nil
        ) {
            self.httpVersion = httpVersion
            self.remoteAddress = remoteAddress
            self.localAddress = localAddress
            self.peerCertificateChainFuture = peerCertificateChainFuture
        }

        /// The peer's validated certificate chain. Returns `nil` if a custom
        /// verification callback was not set when configuring mTLS in the
        /// server configuration, or if the custom verification callback did not
        /// return the derived validated chain.
        public var peerCertificateChain: X509.ValidatedCertificateChain? {
            get async throws {
                if let certs = try await self.peerCertificateChainFuture?.get() {
                    return .init(uncheckedCertificateChain: try certs.map { try Certificate($0) })
                }
                return nil
            }
        }
    }
}
