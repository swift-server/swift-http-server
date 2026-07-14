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

/// A connection handler that forwards every request on the connection to a single
/// ``HTTPServerRequestHandler`` and performs no connection-scoped work.
///
/// This is the default connection handler used by ``NIOHTTPServer/serve(handler:)``.
/// User code may also instantiate it directly when it wants to pass a request
/// handler through a connection-handler API without doing per-connection work.
@available(anyAppleOS 26.0, *)
public struct NIOHTTPServerDefaultConnectionHandler<Handler: HTTPServerRequestHandler>:
    NIOHTTPServerConnectionHandler
where
    Handler.RequestContext == NIOHTTPServer.RequestContext,
    Handler.Reader == NIOHTTPServer.Reader,
    Handler.ResponseSender == NIOHTTPServer.ResponseSender
{
    /// The request handler invoked for every request on the connection.
    public let handler: Handler

    /// Create a default connection handler that forwards every request on the
    /// connection to `handler`.
    public init(handler: Handler) {
        self.handler = handler
    }

    public func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        await connection.handleRequests(handler: self.handler)
    }
}
