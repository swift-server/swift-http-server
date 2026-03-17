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
import NIOHTTP2
import NIOHTTPTypes
import NIOSSL
import X509

@testable import NIOHTTPServer

/// Like ``TestingChannelHTTP1Server``, but for Secure Upgrade.
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
struct TestingChannelSecureUpgradeServer {
    let server: NIOHTTPServer
    let serverTestChannel: NIOAsyncTestingChannel

    /// Sets up the server with a testing channel and the provided request handler, starts the server, and provides
    /// `Self` to the `body` closure. Call `withConnection(clientTLSConfiguration:body:)` on the provided instance to
    /// simulate incoming connections.
    static func serve(
        logger: Logger,
        transportSecurity: NIOHTTPServerConfiguration.TransportSecurity,
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>,
        handler: some HTTPServerRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter>,
        body: (Self) async throws -> Void
    ) async throws {
        let server = NIOHTTPServer(
            logger: logger,
            // The server won't actually be bound to this host and port; we just have to pass this argument
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 8000),
                supportedHTTPVersions: supportedHTTPVersions,
                transportSecurity: transportSecurity,
            )
        )

        // Create a test channel. We will run the server on this channel.
        let serverTestChannel = NIOAsyncTestingChannel()

        try await withThrowingTaskGroup { group in
            // We are ready now. Start the server with the test channel.
            group.addTask {
                try await server.serveSecureUpgradeWithTestChannel(testChannel: serverTestChannel, handler: handler)
            }

            // Execute the provided closure.
            try await body(Self(server: server, serverTestChannel: serverTestChannel))

            group.cancelAll()
        }
    }

    /// Starts a new TLS connection with ALPN negotiation to the server and executes the provided `body` closure
    /// with the negotiated ALPN result as an argument.
    func withConnectedClient(
        clientTLSConfig: TLSConfiguration,
        body: (_ negotiatedConnectionChannel: NegotiatedClientConnection) async throws -> Void
    ) async throws {
        // Create a connection channel: we will write this to the server channel to simulate an incoming connection.
        let serverTestConnectionChannel = try await NIOAsyncTestingChannel.createActiveChannel()

        let tlsConfiguration: TLSConfiguration

        switch self.server.configuration.transportSecurity.backing {
        case .plaintext:
            throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity

        case .tls(let credentials):
            tlsConfiguration = try .makeServerConfiguration(tlsCredentials: credentials, mTLSConfiguration: nil)

        case .mTLS(let credentials, let trustConfiguration):
            tlsConfiguration = try .makeServerConfiguration(
                tlsCredentials: credentials,
                mTLSConfiguration: trustConfiguration
            )
        }

        // Set up the required channel handlers on `serverTestConnectionChannel`
        let negotiatedServerConnectionFuture = try await serverTestConnectionChannel.eventLoop.flatSubmit {
            self.server.setupSecureUpgradeConnectionChildChannel(
                channel: serverTestConnectionChannel,
                supportedHTTPVersions: self.server.configuration.supportedHTTPVersions,
                tlsConfiguration: tlsConfiguration
            )
        }.get()

        // Write the connection channel to the server channel to simulate an incoming connection
        try await self.serverTestChannel.writeInbound(negotiatedServerConnectionFuture)

        let clientTestingChannel = try await NIOAsyncTestingChannel.createActiveChannel()
        let clientNegotiatedConnectionFuture = try await clientTestingChannel.eventLoop.flatSubmit {
            clientTestingChannel.configureTestClientSSLPipeline(tlsConfig: clientTLSConfig).flatMap {
                clientTestingChannel.configureTestSecureUpgradeClientPipeline()
            }
        }.get()

        try await withThrowingDiscardingTaskGroup { group in
            // We must forward all client outbound writes to the server and vice-versa.
            group.addTask { try await clientTestingChannel.glueTo(serverTestConnectionChannel) }

            try await body(.init(negotiationResult: try await clientNegotiatedConnectionFuture.get()))

            try await serverTestConnectionChannel.close()
        }
    }
}
