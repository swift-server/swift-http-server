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
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import X509

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
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TestingChannelServer {
    /// Creates a `NIOHTTPServer` backed by a `NIOAsyncTestingChannel` and the provided request handler, starts it, and
    /// provides a `HTTP1Client` to the `body` closure.
    static func withPlaintextHTTP1Client(
        logger: Logger,
        serverRequestHandler: some HTTPServerRequestHandler<
            HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter
        >,
        body: (PlaintextHTTP1Client) async throws -> Void
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

            // Execute the provided closure with a `PlaintextHTTP1Client` instance created from the server instance and
            // the test channel instance.
            try await body(PlaintextHTTP1Client(server: server, serverTestChannel: serverTestChannel))

            group.cancelAll()
        }
    }

    /// Creates a connection channel that can be written to the server channel to simulate an incoming connection.
    static func createServerConnectionChannel() async throws -> NIOAsyncTestingChannel {
        let serverTestConnectionChannel = NIOAsyncTestingChannel()

        let connectionPromise = serverTestConnectionChannel.eventLoop.makePromise(of: Void.self)
        // The `to` address has no significance here, it is just a random address. We are just interested in making the
        // channel "active"; calling `connect` is the way to achieve that.
        serverTestConnectionChannel.connect(
            to: try .init(ipAddress: "127.0.0.1", port: 8000),
            promise: connectionPromise
        )
        try await connectionPromise.futureResult.get()

        return serverTestConnectionChannel
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension TestingChannelServer {
    /// A plaintext HTTP/1.1 client backed by a `NIOAsyncTestingChannel`.
    struct PlaintextHTTP1Client {
        let server: NIOHTTPServer
        let serverTestChannel: NIOAsyncTestingChannel

        /// Starts a new connection with the server and executes the provided `body` closure.
        /// - Parameter body: A closure that should send a request using the provided client channel and validate the
        ///   received response.
        func withConnection(
            body: (NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) async throws -> Void
        ) async throws {
            // Create a connection channel: we will write this to the server channel to simulate an incoming connection
            let serverTestConnectionChannel = try await TestingChannelServer.createServerConnectionChannel()

            // Set up the required channel handlers on `serverTestConnectionChannel`
            let serverAsyncConnectionChannel = try await self.server.setupHTTP1_1ConnectionChildChannel(
                channel: serverTestConnectionChannel,
                asyncChannelConfiguration: .init()
            ).get()

            // Write the connection channel to the server channel to simulate an incoming connection
            try await self.serverTestChannel.writeInbound(serverAsyncConnectionChannel)

            // Now, we could write requests directly to `serverAsyncConnectionChannel`, but it expects `ByteBuffer`
            // inputs. This is cumbersome to work with in tests, so we create a client channel, and use it to send
            // requests and observe responses in terms of HTTP types.
            let (clientTestChannel, clientAsyncChannel) = try await self.setUpClientConnection()

            try await withThrowingDiscardingTaskGroup { group in
                // We must forward all client outbound writes to the server and vice-versa.
                group.addTask { try await clientTestChannel.glueTo(serverTestConnectionChannel) }

                try await body(clientAsyncChannel)

                try await serverTestConnectionChannel.close()
            }
        }

        /// Creates a client testing channel configured with HTTP channel handlers and wraps it in a `NIOAsyncChannel`.
        private func setUpClientConnection() async throws -> (
            NIOAsyncTestingChannel,
            NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>
        ) {
            let clientTestChannel = try await NIOAsyncTestingChannel { channel in
                try NIOHTTP1Client.clientChannelInitializer(channel)
            }

            // Wrap the client channel in a NIOAsyncChannel for convenience
            let clientAsyncChannel = try await clientTestChannel.eventLoop.submit {
                try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: clientTestChannel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }.get()

            return (clientTestChannel, clientAsyncChannel)
        }
    }
}
