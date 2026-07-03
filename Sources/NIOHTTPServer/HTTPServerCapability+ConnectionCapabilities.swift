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
extension HTTPServerCapability {
    /// A request-context capability exposing connection-scoped peer and local addresses.
    ///
    /// Servers whose request context conforms to this capability surface the
    /// peer's address and the local address the connection is bound to. Both
    /// are reported best-effort: implementations may return `nil` when the
    /// underlying transport cannot report an address.
    public protocol ConnectionInfo: RequestContext {
        /// The peer's address, when known.
        var remoteAddress: NIOHTTPServer.SocketAddress? { get }

        /// The local address the connection is bound to, when known.
        var localAddress: NIOHTTPServer.SocketAddress? { get }
    }

    /// A request-context capability exposing the validated peer certificate chain.
    ///
    /// Servers whose request context conforms to this capability surface the
    /// peer's mTLS-validated certificate chain (when applicable). Implementations
    /// return `nil` if mTLS isn't configured, or if no validated chain was
    /// derived.
    public protocol PeerCertificate: RequestContext {
        /// The peer's validated certificate chain, when available.
        var peerCertificateChain: X509.ValidatedCertificateChain? { get async throws }
    }

    /// A request-context capability that lets a request handler signal that the
    /// connection should close after the current response.
    ///
    /// Servers whose request context conforms to this capability allow handlers
    /// to indicate that the underlying connection should be closed once the
    /// in-flight response has been sent. Implementations make the signal
    /// effective on a best-effort basis (HTTP/1.1 typically appends
    /// `Connection: close` and closes the channel; HTTP/2 typically sends
    /// `GOAWAY` and lets in-flight streams complete normally).
    public protocol CloseableConnection: RequestContext {
        /// Signal that the connection should close after the current response.
        ///
        /// Non-blocking and idempotent. Subsequent calls have no additional
        /// effect.
        func signalConnectionClose()
    }
}
