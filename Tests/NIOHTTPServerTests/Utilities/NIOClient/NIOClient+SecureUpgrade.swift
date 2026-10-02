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
import NIOHTTP2
import NIOHTTPTypes
import NIOPosix
import NIOSSL

@testable import NIOHTTPServer

@available(anyAppleOS 27.0, *)
/// Provides a HTTP client with ALPN negotiation.
extension Channel {
    /// Adds a ``NIOSSLClientHandler`` configured with the provided `TLSConfiguration` to the pipeline.
    func configureTestClientSSLPipeline(tlsConfig: TLSConfiguration) -> EventLoopFuture<Void> {
        self.eventLoop.makeCompletedFuture {
            let sslContext = try NIOSSLContext(configuration: tlsConfig)
            let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
            try self.pipeline.syncOperations.addHandler(sslHandler)
        }
    }

    /// Adds an ALPN handler (configured with both HTTP/1.1 and HTTP/2 channel initializers) to the pipeline. Once a
    /// protocol is negotiated, `additionalConnectionChannelInitializer` is optionally called after the protocol's
    /// handlers are added.
    func configureTestSecureUpgradeClientPipeline(
        additionalConnectionChannelInitializer: (@Sendable (any Channel) throws -> Void)? = nil
    ) -> EventLoopFuture<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>,
                NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
            >
        >
    > {
        self.configureHTTP2AsyncSecureUpgrade(
            http1ConnectionInitializer: { channel in
                channel.configureTestHTTP1ClientPipeline(
                    additionalConnectionChannelInitializer: additionalConnectionChannelInitializer
                )
            },
            http2ConnectionInitializer: { channel in
                channel.configureAsyncHTTP2Pipeline(mode: .client) { $0.eventLoop.makeSucceededFuture($0) }
                    .flatMapThrowing { multiplexer in
                        try additionalConnectionChannelInitializer?(channel)
                        return multiplexer
                    }
            }
        )
    }
}

@available(anyAppleOS 27.0, *)
extension ClientBootstrap {
    /// Connects the client to the specified address using the provided TLS configuration.
    func connectToTestSecureUpgradeHTTPServer(
        at serverAddress: NIOHTTPServer.SocketAddress,
        tlsConfig: TLSConfiguration,
        additionalConnectionChannelInitializer: (@Sendable (any Channel) throws -> Void)? = nil
    ) async throws -> TestClientConnection {
        let target: NIOCore.SocketAddress

        switch serverAddress.base {
        case .ipv4(let address):
            target = try NIOCore.SocketAddress(ipAddress: address.host, port: address.port)
        case .ipv6(let address):
            target = try NIOCore.SocketAddress(ipAddress: address.host, port: address.port)
        case .unixDomainSocket(let path):
            target = try NIOCore.SocketAddress(unixDomainSocketPath: path)
        }

        let (connectionChannel, alpnResultFuture) = try await self.connect(to: target) { channel in
            channel.configureTestClientSSLPipeline(tlsConfig: tlsConfig).flatMap {
                channel.configureTestSecureUpgradeClientPipeline(
                    additionalConnectionChannelInitializer: additionalConnectionChannelInitializer
                ).map { alpnResultFuture in
                    (channel, alpnResultFuture)
                }
            }
        }

        return try await TestClientConnection(
            alpnNegotiationResult: try await alpnResultFuture.get(),
            connectionChannel: connectionChannel
        )
    }
}
