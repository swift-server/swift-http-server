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

/// A protocol for handling the lifecycle of a single ``NIOHTTPServer`` connection.
///
/// Conforming types receive each new connection in ``handleConnection(connection:context:)``. In this method, the
/// request loop can be started by calling ``NIOHTTPServer/Connection/handleRequests(handler:)-(Handler)`` on the
/// connection.
///
/// Conforming types can choose to perform connection-scoped setup (loggers, metric dimensions, atomic counters) in this
/// method. State that must outlive ``handleConnection(connection:context:)`` should live in reference types (classes,
/// actors, atomics) the conformer captures or closes over. The `connection` argument is consumed.
///
/// Handlers that conform to this protocol can be used through
/// ``NIOHTTPServer/NIOHTTPServer/serve(connectionHandler:)-(Handler)`` (the protocol-based form) or
/// ``NIOHTTPServer/serve(connectionHandler:)-((Connection,ConnectionContext)->Void)`` (the closure-based form). If only
/// request-level handling is needed, prefer ``NIOHTTPServer/NIOHTTPServer/serve(handler:)``, which uses a built-in
/// default connection handler (see ``NIOHTTPServer/NIOHTTPServerDefaultConnectionHandler``)
@available(anyAppleOS 26.0, *)
public protocol NIOHTTPServerConnectionHandler: Sendable {
    /// Handle a single connection.
    ///
    /// - Parameters:
    ///   - connection: The active connection. The handler is expected to run the request loop by calling
    ///     ``NIOHTTPServer/Connection/handleRequests(handler:)-(Handler)`` on it. If `handleConnection` returns without
    ///     calling `handleRequests`, the connection is closed on scope exit.
    ///   - context: Connection-scoped data.
    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws
}
