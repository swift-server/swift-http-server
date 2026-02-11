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
import X509

@testable import NIOHTTPServer

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
/// Provides a HTTP client with ALPN negotiation.
struct NIOSecureUpgradeClient {
    /// Valid `applicationProtocol` values are `"http/1.1"` (forces HTTP/1.1), `"h2"` (forces HTTP/2), or a
    /// comma-separated combination of both in order of preference, e.g. `"http/1.1, h2"`.
    static func setUpTLSConfig(trustRoots: [Certificate], applicationProtocol: String) throws -> TLSConfiguration {
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = .certificates(try trustRoots.map { try NIOSSLCertificate($0) })
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = [applicationProtocol]

        return clientTLSConfig
    }

    /// Creates and connects a TLS-enabled client to the specified address with ALPN negotiation.
    static func setUpClient(
        at address: NIOHTTPServer.SocketAddress,
        trustRoots: [Certificate],
        applicationProtocol: String
    ) async throws -> NegotiatedClientConnection {
        let tlsConfig = try self.setUpTLSConfig(trustRoots: trustRoots, applicationProtocol: applicationProtocol)

        return try await self._setUpClient(at: address, tlsConfig: tlsConfig)
    }

    /// Exactly like ``setUpClient(at:trustRoots:applicationProtocol:)`` but with mTLS enabled.
    static func setUpMTLSClient(
        at address: NIOHTTPServer.SocketAddress,
        clientChain: ChainPrivateKeyPair,
        trustRoots: [Certificate],
        applicationProtocol: String,
    ) async throws -> NegotiatedClientConnection {
        var tlsConfig = try self.setUpTLSConfig(trustRoots: trustRoots, applicationProtocol: applicationProtocol)
        tlsConfig.certificateChain = [try NIOSSLCertificateSource(clientChain.leaf)]
        tlsConfig.privateKey = .privateKey(try .init(clientChain.privateKey))

        return try await self._setUpClient(at: address, tlsConfig: tlsConfig)
    }

    /// Creates and connects a client to the specified address with the provided TLS configuration.
    private static func _setUpClient(
        at address: NIOHTTPServer.SocketAddress,
        tlsConfig: TLSConfiguration
    ) async throws -> NegotiatedClientConnection {
        let clientNegotiatedChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connect(to: try .init(ipAddress: address.host, port: address.port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.sslClientChannelInitializer(channel, tlsConfig: tlsConfig)
                }.flatMap {
                    self.clientChannelInitializer(channel, tlsConfig: tlsConfig)
                }
            }.get()

        switch clientNegotiatedChannel {
        case .http1_1(let http1Channel):
            return .http1(http1Channel)

        case .http2(let http2Channel):
            return .http2(.init(http2StreamMultiplexer: http2Channel))
        }
    }

    /// Sets up the input child channel with a ``NIOSSLClientHandler`` configured with the provided TLS
    /// configuration.
    static func sslClientChannelInitializer(_ channel: Channel, tlsConfig: TLSConfiguration) throws {
        let sslContext = try NIOSSLContext(configuration: tlsConfig)

        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
        try channel.pipeline.syncOperations.addHandler(sslHandler)
    }

    /// Provides channel initializers for HTTP/1.1 and HTTP/2 to the ALPN handler, which selects one based on
    /// the negotiated result.
    static func clientChannelInitializer(
        _ channel: Channel,
        tlsConfig: TLSConfiguration
    ) -> EventLoopFuture<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>,
                NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
            >
        >
    > {
        channel.configureHTTP2AsyncSecureUpgrade(
            http1ConnectionInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOHTTP1Client.clientChannelInitializer(channel)

                    return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true)
                    )
                }
            },
            http2ConnectionInitializer: { channel in
                channel.configureAsyncHTTP2Pipeline(mode: .client) { $0.eventLoop.makeSucceededFuture($0) }
            }
        )
    }
}
