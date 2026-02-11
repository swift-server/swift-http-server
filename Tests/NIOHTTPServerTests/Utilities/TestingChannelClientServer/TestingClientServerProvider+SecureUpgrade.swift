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
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOSSL
import X509

@testable import NIOHTTPServer

/// A testing utility that sets up a `NIOHTTPServer` instance (with the secure upgrade transport) based on
/// `NIOAsyncTestingChannel` (instead of the `ServerSocketChannel` that `NIOHTTPServer` normally uses) and vends a
/// client instance for sending requests and observing responses.
///
/// Like ``HTTP1ClientServerProvider``, but for the secure upgrade transport.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HTTPSecureUpgradeClientServerProvider {
    let server: NIOHTTPServer
    let serverTestChannel: NIOAsyncTestingChannel

    let serverTLSConfiguration: TLSConfiguration
    let verificationCallback: (@Sendable ([Certificate]) async throws -> CertificateVerificationResult)?

    let http2Configuration: NIOHTTP2Handler.Configuration

    /// Sets up the server with a testing channel and the provided request handler, starts the server, and provides
    /// `Self` to the `body` closure. Call `withConnectedClient(clientTLSConfiguration:body:)` on the provided instance
    /// to simulate incoming connections.
    static func withProvider(
        logger: Logger,
        tlsConfiguration: TLSConfiguration,
        tlsVerificationCallback: (@Sendable ([Certificate]) async throws -> CertificateVerificationResult)? = nil,
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        handler: some HTTPServerRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter>,
        body: (HTTPSecureUpgradeClientServerProvider) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: logger,
            // The server won't actually be bound to this host and port; we just have to pass this argument
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 8000))
        )

        // Create a test channel. We will run the server on this channel.
        let serverTestChannel = NIOAsyncTestingChannel()

        try await withThrowingTaskGroup { group in
            // We are ready now. Start the server with the test channel.
            group.addTask {
                try await server.serveSecureUpgradeWithTestChannel(testChannel: serverTestChannel, handler: handler)
            }

            // Execute the provided closure with a `HTTPSecureUpgradeClientServerProvider` instance
            try await body(
                HTTPSecureUpgradeClientServerProvider(
                    server: server,
                    serverTestChannel: serverTestChannel,
                    serverTLSConfiguration: tlsConfiguration,
                    verificationCallback: tlsVerificationCallback,
                    http2Configuration: http2Configuration
                )
            )

            group.cancelAll()
        }
    }

    /// Starts a new TLS connection with ALPN negotiation to the server and executes the provided `body` closure with
    /// the negotiated ALPN result as an argument.
    func withConnectedClient(
        tlsConfig: TLSConfiguration,
        body: (NegotiatedClientConnection) async throws -> Void
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
        let negotiatedServerConnectionFuture = try await serverTestConnectionChannel.eventLoop.flatSubmit {
            self.server.setupSecureUpgradeConnectionChildChannel(
                channel: serverTestConnectionChannel,
                tlsConfiguration: self.serverTLSConfiguration,
                asyncChannelConfiguration: .init(),
                http2Configuration: self.http2Configuration,
                verificationCallback: self.verificationCallback
            )
        }.get()

        // Write the connection channel to the server channel to simulate an incoming connection
        try await self.serverTestChannel.writeInbound(negotiatedServerConnectionFuture)

        // Now we could write requests directly to the server channel, but it expects `ByteBuffer` inputs. This is
        // cumbersome to work with in tests.
        // So, we create a client channel, and use it to send requests and observe responses in terms of HTTP types.
        let (clientTestChannel, clientNegotiatedConnectionFuture) = try await self.setUpClientConnection(
            tlsConfig: tlsConfig
        )

        try await withThrowingDiscardingTaskGroup { group in
            // We must forward all client outbound writes to the server and vice-versa.
            group.addTask { try await clientTestChannel.glueTo(serverTestConnectionChannel) }

            try await body(.init(negotiationResult: try await clientNegotiatedConnectionFuture.get()))

            try await serverTestConnectionChannel.close()
        }
    }

    private func setUpClientConnection(
        tlsConfig: TLSConfiguration
    ) async throws -> (
        NIOAsyncTestingChannel,
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>, NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
            >
        >
    ) {
        let clientTestChannel = try await NIOAsyncTestingChannel { channel in
            _ = channel.eventLoop.makeCompletedFuture {
                try NIOSecureUpgradeClient.sslClientChannelInitializer(channel, tlsConfig: tlsConfig)
            }
        }

        let clientNegotiatedConnection = try await NIOSecureUpgradeClient.clientChannelInitializer(
            clientTestChannel,
            tlsConfig: tlsConfig
        ).get()

        let connectionPromise = clientTestChannel.eventLoop.makePromise(of: Void.self)
        clientTestChannel.connect(to: try .init(ipAddress: "127.0.0.1", port: 8000), promise: connectionPromise)
        try await connectionPromise.futureResult.get()

        return (clientTestChannel, clientNegotiatedConnection)
    }
}
