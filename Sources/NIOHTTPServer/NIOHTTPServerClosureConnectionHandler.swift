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

/// A closure-based ``NIOHTTPServerConnectionHandler``.
///
/// Used internally by ``NIOHTTPServer/NIOHTTPServer/serve(connectionHandler:)-((NIOHTTPServer.Connection,NIOHTTPServer.ConnectionContext)->Void)``
/// to bridge a closure to the protocol-based connection-handler API.
@available(anyAppleOS 27.0, *)
struct NIOHTTPServerClosureConnectionHandler: NIOHTTPServerConnectionHandler {
    let body:
        @Sendable (
            consuming sending NIOHTTPServer.Connection,
            NIOHTTPServer.ConnectionContext
        ) async throws -> Void

    func handleConnection(
        connection: consuming sending NIOHTTPServer.Connection,
        context: NIOHTTPServer.ConnectionContext
    ) async throws {
        try await self.body(connection, context)
    }
}
