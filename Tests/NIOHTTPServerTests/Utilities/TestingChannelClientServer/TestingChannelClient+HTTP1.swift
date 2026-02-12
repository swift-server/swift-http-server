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
import NIOHTTPTypes

@testable import NIOHTTPServer

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension TestingChannelHTTP1Server {
    /// A plaintext HTTP/1.1 client backed by a `NIOAsyncTestingChannel`.
    struct Client {
        let server: NIOHTTPServer
        let serverTestChannel: NIOAsyncTestingChannel

        /// Starts a new connection with the server and executes the provided `body` closure.
        /// - Parameter body: A closure that should send a request using the provided client channel and validate the
        ///   received response.
        func withConnection(
            body: (NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>) async throws -> Void
        ) async throws {
            // Create a connection channel: we will write this to the server channel to simulate an incoming connection
            let serverTestConnectionChannel = try await NIOAsyncTestingChannel.createActiveChannel()

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
