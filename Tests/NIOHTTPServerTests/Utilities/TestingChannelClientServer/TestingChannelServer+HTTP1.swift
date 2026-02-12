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

import HTTPServer
import Logging
import NIOEmbedded
import NIOHTTPServer

/// A testing utility that sets up a `NIOHTTPServer` instance based on `NIOAsyncTestingChannel` (instead of the
/// `ServerSocketChannel` that `NIOHTTPServer` normally uses) and vends a client instance for sending requests and
/// observing responses.
///
/// This provider creates a `NIOHTTPServer` instance using a `NIOAsyncTestingChannel` as its listening channel. Since no
/// network socket is actually listening for incoming connections, client connections are simulated by *writing* a
/// connection channel to the server channel. This connection channel is set up with the same handlers that
/// `ServerBootstrap` would set up and vend to `NIOHTTPServer` on an incoming connection.
///
/// This provider vends a HTTP client channel (also backed by a `NIOAsyncTestingChannel`) that can be used to send
/// requests and observe responses in terms of HTTP types (`HTTPRequestPart` and `HTTPResponsePart`) to the server
/// connection channel.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TestingChannelHTTP1Server {
    /// Creates a `NIOHTTPServer` backed by a `NIOAsyncTestingChannel` and the provided request handler, starts it, and
    /// provides a `HTTP1Client` to the `body` closure.
    static func withClient(
        logger: Logger,
        serverRequestHandler: some HTTPServerRequestHandler<
            HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter
        >,
        body: (Client) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: logger,
            // The server won't actually be bound to this host and port; we just have to pass this argument.
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 8000))
        )
        // Create a test channel. We will run the server on this channel.
        let serverTestChannel = NIOAsyncTestingChannel()

        try await withThrowingTaskGroup { group in
            // We are ready now. Start the server with the test channel.
            group.addTask {
                try await server.serveInsecureHTTP1_1WithTestChannel(
                    testChannel: serverTestChannel,
                    handler: serverRequestHandler
                )
            }

            // Execute the provided closure with a test client instance.
            try await body(Client(server: server, serverTestChannel: serverTestChannel))

            group.cancelAll()
        }
    }
}
