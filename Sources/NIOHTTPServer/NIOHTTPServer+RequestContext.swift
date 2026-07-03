//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import HTTPAPIs
public import X509

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// The request context provided to handlers by ``NIOHTTPServer``.
    ///
    /// Conforms to:
    /// - ``HTTPServerCapability/ConnectionInfo`` — peer / local addresses.
    /// - ``HTTPServerCapability/PeerCertificate`` — mTLS-validated peer chain.
    /// - ``HTTPServerCapability/CloseableConnection`` — `signalConnectionClose()`.
    ///
    /// Generic library code can constrain on these capabilities to access
    /// per-request data without depending on ``NIOHTTPServer`` directly.
    public struct RequestContext: HTTPServerCapability.RequestContext, Sendable {
        let connectionContext: ConnectionContext

        init(connectionContext: ConnectionContext) {
            self.connectionContext = connectionContext
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.RequestContext: HTTPServerCapability.ConnectionInfo {
    /// The peer's address, when known.
    ///
    /// Returns `nil` if the underlying transport could not report an address
    /// or if the address is of an unsupported kind.
    public var remoteAddress: NIOHTTPServer.SocketAddress? {
        self.connectionContext.remoteAddress
    }

    /// The local address the connection is bound to, when known.
    ///
    /// Returns `nil` under the same conditions as ``remoteAddress``.
    public var localAddress: NIOHTTPServer.SocketAddress? {
        self.connectionContext.localAddress
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.RequestContext: HTTPServerCapability.PeerCertificate {
    /// The peer's mTLS-validated certificate chain, when available.
    ///
    /// Returns `nil` when mTLS is not configured, or when the configured
    /// custom verification callback did not return the derived validated
    /// chain. May throw if the chain cannot be retrieved.
    public var peerCertificateChain: X509.ValidatedCertificateChain? {
        get async throws {
            try await self.connectionContext.peerCertificateChain
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.RequestContext: HTTPServerCapability.CloseableConnection {
    /// Signal that the connection should close after the current response.
    ///
    /// Non-blocking and idempotent. Effective after the current response:
    ///
    /// - On HTTP/1.1, the response carries `Connection: close` and the
    ///   channel is closed once the response has been written.
    /// - On HTTP/2, the connection sends `GOAWAY`; in-flight streams
    ///   complete normally before the connection closes.
    public func signalConnectionClose() {
        self.connectionContext.signalConnectionClose()
    }
}
