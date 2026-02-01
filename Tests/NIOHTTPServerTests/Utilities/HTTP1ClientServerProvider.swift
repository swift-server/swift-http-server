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

import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import X509

@testable import HTTPServer
@testable import NIOHTTPServer

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HTTP1ClientServerProvider {
    let server: NIOHTTPServer
    let serverTestChannel: NIOAsyncTestingChannel

    static func withProvider(
        handler: some HTTPServerRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter>,
        body: (HTTP1ClientServerProvider) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: .init(label: "test"),
            // The server won't actually be bound to this host and port; we just have to pass this argument
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 8000))
        )
        // Create a test channel. We will run the server on this channel.
        let serverTestChannel = NIOAsyncTestingChannel()

        try await withThrowingTaskGroup { group in
            // We are ready now. Start the server with the test channel.
            group.addTask {
                try await server.serveInsecureHTTP1_1WithTestChannel(testChannel: serverTestChannel, handler: handler)
            }

            // Execute the provided closure with a `HTTP1ClientServerProvider` instance created from the server
            // instance and the test channel instance
            try await body(
                HTTP1ClientServerProvider(server: server, serverTestChannel: serverTestChannel)
            )

            group.cancelAll()
        }
    }

    /// Starts a new connection with the server and executes the provided `body` closure.
    /// - Parameter body: A closure that should send a request using the provided client instance and validate
    ///   the received response.
    func withConnectedClient(
        body: (NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) async throws -> Void
    ) async throws {
        // Create a test connection channel
        let serverTestConnectionChannel = NIOAsyncTestingChannel()

        let connectionPromise = serverTestConnectionChannel.eventLoop.makePromise(of: Void.self)
        serverTestConnectionChannel.connect(
            to: try .init(ipAddress: "127.0.0.1", port: 8000),
            promise: connectionPromise
        )
        try await connectionPromise.futureResult.get()

        // Set up the required channel handlers on `serverTestConnectionChannel`
        let serverAsyncConnectionChannel = try await self.server.setupHTTP1_1ConnectionChildChannel(
            channel: serverTestConnectionChannel,
            asyncChannelConfiguration: .init()
        ).get()

        // Write the connection channel to the server channel to simulate an incoming connection
        try await self.serverTestChannel.writeInbound(serverAsyncConnectionChannel)

        // Now, we could write requests directly to `serverAsyncConnectionChannel`, but it expects `ByteBuffer` inputs.
        // This is cumbersome to work with in tests.
        // So, we create a client channel, and use it to send requests and observe responses in terms of HTTP types.
        let (clientTestChannel, clientAsyncChannel) = try await self.setUpClientConnection()

        try await withThrowingDiscardingTaskGroup { group in
            // We must forward all client outbound writes to the server and vice-versa.
            group.addTask { try await clientTestChannel.glueTo(serverTestConnectionChannel) }

            try await body(clientAsyncChannel)

            try await serverTestConnectionChannel.close()
        }
    }

    private func setUpClientConnection() async throws -> (
        NIOAsyncTestingChannel, NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>
    ) {
        let clientTestChannel = try await NIOAsyncTestingChannel { channel in
            try channel.pipeline.syncOperations.addHTTPClientHandlers()
            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPClientCodec())
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

extension NIOAsyncTestingChannel {
    /// Forwards all of our outbound writes to `other` and vice-versa.
    func glueTo(_ other: NIOAsyncTestingChannel) async throws {
        await withThrowingTaskGroup { group in
            // 1. Forward all `self` writes to `other`
            group.addTask {
                while !Task.isCancelled {
                    let ourPart = try await self.waitForOutboundWrite(as: ByteBuffer.self)
                    try await other.writeInbound(ourPart)
                }
            }

            // 2. Forward all `other` writes to `self`
            group.addTask {
                while !Task.isCancelled {
                    let otherPart = try await other.waitForOutboundWrite(as: ByteBuffer.self)
                    try await self.writeInbound(otherPart)
                }
            }
        }
    }
}
