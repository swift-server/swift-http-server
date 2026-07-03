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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// The application-level HTTP version negotiated for a connection.
    public enum HTTPVersion: String, Sendable, Hashable {
        case http1_1 = "http/1.1"
        case http2 = "http/2"
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Connection-scoped state.
    ///
    /// Carries connection-scoped data such as the negotiated HTTP version, the
    /// peer / local addresses, the peer's validated certificate chain (when
    /// applicable), and the close-signal trigger that
    /// ``signalConnectionClose()`` invokes.
    ///
    /// User code accesses this state via the corresponding ``RequestContext``
    /// capabilities (``HTTPServerCapability/ConnectionInfo``,
    /// ``HTTPServerCapability/PeerCertificate``,
    /// ``HTTPServerCapability/CloseableConnection``) when handling individual
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

        /// Per-protocol close mechanism. HTTP/1.1 uses a shared atomic flag the
        /// channel's ``HTTPKeepAliveHandler`` reads when writing the next
        /// response head. HTTP/2 fires `ChannelShouldQuiesceEvent` on the
        /// connection channel; NIO's `NIOHTTP2ServerConnectionManagementHandler`
        /// reacts by sending `GOAWAY`, letting in-flight streams complete
        /// normally, and finally closing the connection.
        let closeBacking: CloseBacking

        enum CloseBacking: Sendable {
            case http1_1(closeFlag: NIOLockedValueBox<Bool>)
            case http2(connectionChannel: any Channel)
        }

        init(
            httpVersion: HTTPVersion,
            remoteAddress: NIOHTTPServer.SocketAddress? = nil,
            localAddress: NIOHTTPServer.SocketAddress? = nil,
            peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>? = nil,
            closeBacking: CloseBacking
        ) {
            self.httpVersion = httpVersion
            self.remoteAddress = remoteAddress
            self.localAddress = localAddress
            self.peerCertificateChainFuture = peerCertificateChainFuture
            self.closeBacking = closeBacking
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

        /// Signal that the connection should close after the current response.
        ///
        /// Non-blocking and idempotent. Effective after the current response:
        ///
        /// - On HTTP/1.1, the response carries `Connection: close` and the
        ///   channel is closed once the response has been written.
        /// - On HTTP/2, the connection sends `GOAWAY`; in-flight streams
        ///   complete normally before the connection closes.
        public func signalConnectionClose() {
            switch self.closeBacking {
            case .http1_1(let closeFlag):
                closeFlag.withLockedValue { $0 = true }
            case .http2(let connectionChannel):
                connectionChannel.pipeline.fireUserInboundEventTriggered(ChannelShouldQuiesceEvent())
            }
        }
    }
}
