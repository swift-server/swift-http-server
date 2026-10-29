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
    /// ``HTTPServerCapability/HTTPVersion``,
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
        /// new network path. ``withConnectionEventHandler(operation:onEvent:)`` reports each change.
        public var remoteAddress: NIOHTTPServer.SocketAddress? {
            self.currentRemoteAddress.withLockedValue { $0 }
        }

        /// The local address the connection is bound to, when known.
        public let localAddress: NIOHTTPServer.SocketAddress?

        /// The peer's validated certificate chain. Returns `nil` if a custom verification callback was not set when
        /// configuring mTLS in the server configuration, or if the custom verification callback did not return the
        /// derived validated chain.
        public var validatedPeerCertificateChain: X509.ValidatedCertificateChain?

        /// Shared by every copy of this context, so that over HTTP/3 the connection's ``ConnectionEventsHandler`` keeps
        /// them all current.
        private let currentRemoteAddress: NIOLockedValueBox<NIOHTTPServer.SocketAddress?>

        private let eventManager: ConnectionEventManager

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
            self.eventManager = ConnectionEventManager()
        }

        /// Runs `operation` while `onEvent` is called for each event that happens on the connection.
        ///
        /// Use this to react to changes in the connection beneath a request, such as the peer's address changing when a
        /// client migrates an HTTP/3 connection to a new network path:
        ///
        /// ```swift
        /// try await requestContext.withConnectionEventHandler {
        ///     try await handleRequest()
        /// } onEvent: { event in
        ///     switch event {
        ///     case .remoteAddressChanged(let address):
        ///         logger.info("Client migrated", metadata: ["address": "\(address)"])
        ///     default:
        ///         break
        ///     }
        /// }
        /// ```
        ///
        /// `onEvent` is registered before `operation` starts and removed once it finishes, whether it returns or throws,
        /// so it only hears about events that happen while `operation` is running. Events are not buffered.
        ///
        /// `onEvent` is called synchronously on the connection's event loop, concurrently with `operation`, once for
        /// each event in the order the events happen. It must return quickly and not block: to handle events
        /// asynchronously, yield them into an `AsyncStream`'s continuation. State such as ``remoteAddress`` is already
        /// up to date by the time `onEvent` is called. `onEvent` is never running once this method has returned.
        ///
        /// - Parameters:
        ///   - operation: The work to run, typically the rest of the request handler.
        ///   - onEvent: Called with each event that happens on the connection while `operation` is running.
        /// - Returns: The value returned by `operation`.
        public func withConnectionEventHandler<Return, Failure: Error>(
            operation: () async throws(Failure) -> Return,
            onEvent: @escaping @Sendable (ConnectionEvent) -> Void
        ) async throws(Failure) -> Return {
            let handlerID = self.eventManager.registerHandler(onEvent)
            defer { self.eventManager.removeHandler(id: handlerID) }

            return try await operation()
        }

        /// Applies an `event` received on the connection to this context, then passes it to the registered handlers.
        func connectionEventReceived(_ event: ConnectionEvent) {
            switch event {
            case .remoteAddressChanged(let address):
                self.currentRemoteAddress.withLockedValue { $0 = address }
            }

            self.eventManager.send(event)
        }
    }
}
