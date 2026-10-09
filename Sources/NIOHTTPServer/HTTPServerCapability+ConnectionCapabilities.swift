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

@available(anyAppleOS 27.0, *)
extension HTTPServerCapability {
    /// A request-context capability exposing connection-scoped peer and local addresses.
    ///
    /// Servers whose request context conforms to this capability surface the
    /// peer's address and the local address the connection is bound to. Both
    /// are reported best-effort: implementations may return `nil` when the
    /// underlying transport cannot report an address.
    public protocol ConnectionInfo: RequestContext {
        /// The peer's address, when known.
        ///
        /// This can change during the connection's lifetime: for example, when a client migrates an HTTP/3 connection
        /// to a new network path.
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
        var validatedPeerCertificateChain: X509.ValidatedCertificateChain? { get }
    }

    /// A request-context capability exposing the events that happen on the connection carrying the request.
    ///
    /// Servers whose request context conforms to this capability let request
    /// handlers react to changes in the connection beneath them, such as the
    /// peer's address changing when a client migrates an HTTP/3 connection to
    /// a new network path.
    public protocol ConnectionEvents: RequestContext {
        /// The events that happen on the connection carrying the request.
        ///
        /// The sequence finishes once the connection closes.
        var connectionEvents: NIOHTTPServer.ConnectionEvents { get }
    }
}
