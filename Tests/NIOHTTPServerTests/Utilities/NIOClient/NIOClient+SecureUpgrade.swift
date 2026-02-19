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

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
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

    /// Adds an ALPN handler (configured with both HTTP/1.1 and HTTP/2 channel initializers) to the pipeline.
    func configureTestSecureUpgradeClientPipeline() -> EventLoopFuture<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>,
                NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
            >
        >
    > {
        self.configureHTTP2AsyncSecureUpgrade(
            http1ConnectionInitializer: { channel in
                channel.configureTestHTTP1ClientPipeline()
            },
            http2ConnectionInitializer: { channel in
                channel.configureAsyncHTTP2Pipeline(mode: .client) { $0.eventLoop.makeSucceededFuture($0) }
            }
        )
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension ClientBootstrap {
    /// Connects the client to the specified address using the provided TLS configuration.
    func connectToTestSecureUpgradeHTTPServer(
        at serverAddress: NIOHTTPServer.SocketAddress,
        tlsConfig: TLSConfiguration
    ) async throws -> NegotiatedClientConnection {
        let clientNegotiatedChannel = try await self.connect(
            to: try .init(ipAddress: serverAddress.host, port: serverAddress.port)
        ) { channel in
            channel.configureTestClientSSLPipeline(tlsConfig: tlsConfig).flatMap {
                channel.configureTestSecureUpgradeClientPipeline()
            }
        }.get()

        switch clientNegotiatedChannel {
        case .http1_1(let http1Channel):
            return .http1(http1Channel)

        case .http2(let http2Channel):
            return .http2(.init(http2StreamMultiplexer: http2Channel))
        }
    }

    /// Creates and connects a TLS-enabled client to the specified address.
    func connectToTestSecureUpgradeHTTPServer(
        at serverAddress: NIOHTTPServer.SocketAddress,
        trustRoots: [Certificate],
        applicationProtocol: String
    ) async throws -> NegotiatedClientConnection {
        let tlsConfig = try TLSConfiguration.makeTestClientConfiguration(
            testTrustRoots: trustRoots,
            applicationProtocol: applicationProtocol
        )

        return try await self.connectToTestSecureUpgradeHTTPServer(at: serverAddress, tlsConfig: tlsConfig)
    }

    /// Exactly like ``connectToTestSecureUpgradeHTTPServerOverMTLS(at:trustRoots:applicationProtocol:)`` but over mTLS
    /// instead.
    func connectToTestSecureUpgradeHTTPServerOverMTLS(
        at serverAddress: NIOHTTPServer.SocketAddress,
        clientChain: ChainPrivateKeyPair,
        trustRoots: [Certificate],
        applicationProtocol: String
    ) async throws -> NegotiatedClientConnection {
        var mTLSConfig = try TLSConfiguration.makeTestClientConfiguration(
            testTrustRoots: trustRoots,
            applicationProtocol: applicationProtocol
        )
        mTLSConfig.certificateChain = [try NIOSSLCertificateSource(clientChain.leaf)]
        mTLSConfig.privateKey = .privateKey(try .init(clientChain.privateKey))

        return try await self.connectToTestSecureUpgradeHTTPServer(at: serverAddress, tlsConfig: mTLSConfig)
    }
}

extension TLSConfiguration {
    /// Valid `applicationProtocol` values are `"http/1.1"` (forces HTTP/1.1), `"h2"` (forces HTTP/2), or a
    /// comma-separated combination of both in order of preference, e.g. `"http/1.1, h2"`.
    static func makeTestClientConfiguration(
        testTrustRoots: [Certificate],
        applicationProtocol: String
    ) throws -> TLSConfiguration {
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = .certificates(try testTrustRoots.map { try NIOSSLCertificate($0) })
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = [applicationProtocol]

        return clientTLSConfig
    }
}
