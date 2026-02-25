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
import NIOExtras
import NIOHTTP1
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import X509

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServer {
    typealias NegotiatedChannel = NIONegotiatedHTTPVersion<
        NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        (any Channel, NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>)
    >

    func serveSecureUpgrade(
        serverChannel: NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel.executeThenClose { inbound in
                for try await upgradeResult in inbound {
                    group.addTask {
                        do {
                            try await withThrowingDiscardingTaskGroup { connectionGroup in
                                switch try await upgradeResult.get() {
                                case .http1_1(let http1Channel):
                                    let chainFuture = http1Channel.channel.nioSSL_peerValidatedCertificateChain()
                                    Self.$connectionContext.withValue(ConnectionContext(chainFuture)) {
                                        connectionGroup.addTask {
                                            try await self.handleRequestChannel(
                                                channel: http1Channel,
                                                handler: handler
                                            )
                                        }
                                    }
                                case .http2((let http2Connection, let http2Multiplexer)):
                                    do {
                                        let chainFuture = http2Connection.nioSSL_peerValidatedCertificateChain()
                                        try await Self.$connectionContext.withValue(ConnectionContext(chainFuture)) {
                                            for try await http2StreamChannel in http2Multiplexer.inbound {
                                                connectionGroup.addTask {
                                                    try await self.handleRequestChannel(
                                                        channel: http2StreamChannel,
                                                        handler: handler
                                                    )
                                                }
                                            }
                                        }
                                    } catch {
                                        self.logger.debug("HTTP2 connection closed: \(error)")
                                    }
                                }
                            }
                        } catch {
                            self.logger.debug("Negotiating ALPN failed: \(error)")
                        }
                    }
                }
            }
        }
    }

    func setupSecureUpgradeServerChannel(
        bindTarget: NIOHTTPServerConfiguration.BindTarget,
        tlsConfiguration: TLSConfiguration,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        http2Configuration: NIOHTTPServerConfiguration.HTTP2,
        verificationCallback: (@Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult)?
    ) async throws -> NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never> {
        switch bindTarget.backing {
        case .hostAndPort(let host, let port):
            let serverChannel = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .serverChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            self.serverQuiescingHelper.makeServerChannelHandler(channel: channel)
                        )
                    }
                }
                .bind(host: host, port: port) { channel in
                    self.setupSecureUpgradeConnectionChildChannel(
                        channel: channel,
                        tlsConfiguration: tlsConfiguration,
                        asyncChannelConfiguration: asyncChannelConfiguration,
                        http2Configuration: http2Configuration,
                        verificationCallback: verificationCallback
                    )
                }

            try self.addressBound(serverChannel.channel.localAddress)

            return serverChannel
        }
    }

    func setupSecureUpgradeConnectionChildChannel(
        channel: any Channel,
        tlsConfiguration: TLSConfiguration,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        http2Configuration: NIOHTTPServerConfiguration.HTTP2,
        verificationCallback: (@Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult)?
    ) -> EventLoopFuture<EventLoopFuture<NegotiatedChannel>> {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
                self.makeSSLServerHandler(tlsConfiguration, verificationCallback)
            )
        }.flatMap {
            channel.configureHTTP2AsyncSecureUpgrade(
                http1ConnectionInitializer: { http1Channel in
                    http1Channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                        http1Channel.eventLoop.makeCompletedFuture {
                            try http1Channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: true))

                            return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                wrappingChannelSynchronously: http1Channel,
                                configuration: asyncChannelConfiguration
                            )
                        }
                    }
                },
                http2ConnectionInitializer: { http2Channel in
                    http2Channel.eventLoop.makeCompletedFuture {
                        try http2Channel.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                            mode: .server,
                            connectionManagerConfiguration: .init(
                                maxIdleTime: nil,
                                maxAge: nil,
                                maxGraceTime: http2Configuration.gracefulShutdown.maximumGracefulShutdownDuration
                                    .map { TimeAmount($0) },
                                keepalive: nil
                            ),
                            http2HandlerConfiguration: .init(httpServerHTTP2Configuration: http2Configuration),
                            streamInitializer: { http2StreamChannel in
                                http2StreamChannel.eventLoop.makeCompletedFuture {
                                    try http2StreamChannel.pipeline.syncOperations
                                        .addHandler(
                                            HTTP2FramePayloadToHTTPServerCodec()
                                        )

                                    return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                        wrappingChannelSynchronously: http2StreamChannel,
                                        configuration: asyncChannelConfiguration
                                    )
                                }
                            }
                        )
                    }
                    .flatMap { multiplexer in
                        http2Channel.eventLoop.makeCompletedFuture(.success((http2Channel, multiplexer)))
                    }
                }
            )
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServer {
    func makeSSLServerHandler(
        _ tlsConfiguration: TLSConfiguration,
        _ customVerificationCallback: (@Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult)?
    ) throws -> NIOSSLServerHandler {
        if let customVerificationCallback {
            return try NIOSSLServerHandler(
                context: .init(configuration: tlsConfiguration),
                customVerificationCallbackWithMetadata: { certificates, promise in
                    promise.completeWithTask {
                        // Convert input [NIOSSLCertificate] to [X509.Certificate]
                        let x509Certs = try certificates.map { try Certificate($0) }

                        let callbackResult = try await customVerificationCallback(x509Certs)

                        switch callbackResult {
                        case .certificateVerified(let verificationMetadata):
                            guard let peerChain = verificationMetadata.validatedCertificateChain else {
                                return .certificateVerified(.init(nil))
                            }

                            // Convert the result into [NIOSSLCertificate]
                            let nioSSLCerts = try peerChain.map { try NIOSSLCertificate($0) }
                            return .certificateVerified(.init(.init(nioSSLCerts)))

                        case .failed(let error):
                            self.logger.error(
                                "Custom certificate verification failed",
                                metadata: [
                                    "failure-reason": .string(error.reason)
                                ]
                            )
                            return .failed
                        }
                    }
                }
            )
        } else {
            return try NIOSSLServerHandler(context: .init(configuration: tlsConfiguration))
        }
    }
}
