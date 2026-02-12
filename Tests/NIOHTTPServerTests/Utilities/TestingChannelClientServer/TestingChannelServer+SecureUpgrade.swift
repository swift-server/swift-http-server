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
import NIOHTTP2
import NIOSSL
import X509

@testable import NIOHTTPServer

/// Like ``TestingChannelHTTP1Server``, but for Secure Upgrade.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TestingChannelSecureUpgradeServer {
    /// Sets up the server with a testing channel and the provided request handler, starts the server, and provides
    /// `Self` to the `body` closure. Call `withConnection(clientTLSConfiguration:body:)` on the provided instance to
    /// simulate incoming connections.
    static func withClient(
        logger: Logger,
        tlsConfiguration: TLSConfiguration,
        tlsVerificationCallback: (@Sendable ([Certificate]) async throws -> CertificateVerificationResult)? = nil,
        http2Configuration: NIOHTTP2Handler.Configuration = .init(),
        handler: some HTTPServerRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter>,
        body: (Client) async throws -> Void
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

            // Execute the provided closure with a test client instance.
            try await body(
                Client(
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
}
