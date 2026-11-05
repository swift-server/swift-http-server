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

import Synchronization

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    /// Something that happened on a connection, as reported to the handler passed to
    /// ``ConnectionContext/withConnectionEventHandler(operation:onEvent:)``.
    @nonexhaustive
    public enum ConnectionEvent: Sendable, Hashable {
        /// The peer's address changed.
        ///
        /// Over HTTP/3, a client can migrate its QUIC connection to a new network path (RFC 9000 § 9): for example,
        /// when it moves from Wi-Fi to cellular, or when a NAT rebinds the port it is reachable on. The associated value
        /// is the peer's new address, which ``ConnectionContext/remoteAddress`` reports from then on.
        case remoteAddressChanged(NIOHTTPServer.SocketAddress)
    }
}

/// Keeps track of the handlers that want to hear about a connection's events, and calls them when an event happens.
///
/// Handlers are called while holding the lock that registering and removing them also takes. A handler is therefore
/// never running once it has been removed, at the cost of it not being able to register or remove handlers itself.
@available(anyAppleOS 27.0, *)
final class ConnectionEventManager: Sendable {
    private struct Handler {
        var id: Int
        var handler: @Sendable (NIOHTTPServer.ConnectionEvent) -> Void
    }

    private struct State {
        var handlers: [Handler] = []
        var nextHandlerID = 0
    }

    private let state = Mutex(State())

    /// Registers `handler` to be called with every event from now on, and returns an ID to remove it with.
    func registerHandler(_ handler: @escaping @Sendable (NIOHTTPServer.ConnectionEvent) -> Void) -> Int {
        self.state.withLock { state in
            let id = state.nextHandlerID
            state.nextHandlerID += 1
            state.handlers.append(Handler(id: id, handler: handler))
            return id
        }
    }

    /// Removes the handler registered with `id`. It is not called again.
    func removeHandler(id: Int) {
        self.state.withLock { state in
            state.handlers.removeAll { $0.id == id }
        }
    }

    /// Calls every registered handler with `event`, in the order they were registered.
    func send(_ event: NIOHTTPServer.ConnectionEvent) {
        self.state.withLock { state in
            for handler in state.handlers {
                handler.handler(event)
            }
        }
    }
}
