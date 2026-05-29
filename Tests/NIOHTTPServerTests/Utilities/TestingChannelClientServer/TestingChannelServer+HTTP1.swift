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

import HTTPAPIs
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTPTypes

@testable import NIOHTTPServer

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
@available(anyAppleOS 26.0, *)
struct TestingChannelHTTP1Server {
    let server: NIOHTTPServer
    let serverTestChannel: NIOAsyncTestingChannel

    /// Creates a `NIOHTTPServer` backed by a `NIOAsyncTestingChannel` and the provided request handler, starts it, and
    /// provides `Self` to the `body` closure.
    static func serve(
        logger: Logger,
        handler: some HTTPServerRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter>,
        body: (Self) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: logger,
            // The server won't actually be bound to this host and port; we just have to pass this argument.
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
        // Create a test channel. We will run the server on this channel.
        let serverTestChannel = NIOAsyncTestingChannel()

        try await withThrowingTaskGroup { group in
            // We are ready now. Start the server with the test channel.
            group.addTask {
                try await server.serveInsecureHTTP1_1WithTestChannel(testChannel: serverTestChannel, handler: handler)
            }

            // Execute the provided closure with `Self`.
            try await body(Self(server: server, serverTestChannel: serverTestChannel))

            group.cancelAll()
        }
    }

    /// Starts a new connection with the server and executes the provided `body` closure.
    /// - Parameter body: A closure that should send a request using the provided client channel and validate the
    ///   received response.
    func withConnectedClient(
        body: (_ connectionChannel: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) async throws -> Void
    ) async throws {
        // Create a connection channel: we will write this to the server channel to simulate an incoming connection
        let serverTestConnectionChannel = try await NIOAsyncTestingChannel.createActiveChannel()

        // Set up the required channel handlers on `serverTestConnectionChannel`
        let serverAsyncConnectionChannel = try await self.server.setupHTTP1_1Connection(
            channel: serverTestConnectionChannel,
            asyncChannelConfiguration: .init(),
            isSecure: false
        ).get()

        // Write the connection channel to the server channel to simulate an incoming connection
        try await self.serverTestChannel.writeInbound(serverAsyncConnectionChannel)

        let clientTestingChannel = try await NIOAsyncTestingChannel.createActiveChannel()
        let clientAsyncChannel = try await clientTestingChannel.eventLoop.flatSubmit {
            clientTestingChannel.configureTestHTTP1ClientPipeline()
        }.get()

        try await withThrowingDiscardingTaskGroup { group in
            // We must forward all client outbound writes to the server and vice-versa.
            group.addTask { try await clientTestingChannel.glueTo(serverTestConnectionChannel) }

            try await body(clientAsyncChannel)

            try? await serverTestConnectionChannel.close()
        }
    }
}
