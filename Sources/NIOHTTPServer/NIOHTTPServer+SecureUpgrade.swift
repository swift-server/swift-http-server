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
import NIOCertificateReloading
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
import NIOTLS
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
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>,
        tlsConfiguration: TLSConfiguration
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
                        supportedHTTPVersions: supportedHTTPVersions,
                        tlsConfiguration: tlsConfiguration
                    )
                }

            try self.addressBound(serverChannel.channel.localAddress)

            return serverChannel
        }
    }

    private func http1ConnectionInitializer(
        channel: any Channel
    ) -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> {
        channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: true))

                return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(
                        backPressureStrategy: .init(self.configuration.backpressureStrategy),
                        isOutboundHalfClosureEnabled: true
                    )
                )
            }
        }
    }

    private func http2ConnectionInitializer(
        channel: any Channel,
        configuration: NIOHTTPServerConfiguration.HTTP2
    ) -> EventLoopFuture<
        (
            any Channel,
            NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>
        )
    > {
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.configureAsyncHTTP2Pipeline(
                mode: .server,
                connectionManagerConfiguration: .init(
                    maxIdleTime: nil,
                    maxAge: nil,
                    maxGraceTime: configuration.gracefulShutdown.maximumGracefulShutdownDuration
                        .map { TimeAmount($0) },
                    keepalive: nil
                ),
                http2HandlerConfiguration: .init(httpServerHTTP2Configuration: configuration),
                streamInitializer: { http2StreamChannel in
                    http2StreamChannel.eventLoop.makeCompletedFuture {
                        try http2StreamChannel.pipeline.syncOperations
                            .addHandler(
                                HTTP2FramePayloadToHTTPServerCodec()
                            )

                        return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                            wrappingChannelSynchronously: http2StreamChannel,
                            configuration: .init(
                                backPressureStrategy: .init(self.configuration.backpressureStrategy),
                                isOutboundHalfClosureEnabled: true
                            )
                        )
                    }
                }
            )
        }
        .flatMap { multiplexer in
            channel.eventLoop.makeCompletedFuture(.success((channel, multiplexer)))
        }
    }

    func setupSecureUpgradeConnectionChildChannel(
        channel: any Channel,
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>,
        tlsConfiguration: TLSConfiguration
    ) -> EventLoopFuture<EventLoopFuture<NegotiatedChannel>> {
        channel.eventLoop.makeCompletedFuture {
            var tlsConfiguration = tlsConfiguration
            // Set the application protocols to the appropriate value depending upon whether we want to serve HTTP/1.1,
            // HTTP/2, or both.
            tlsConfiguration.applicationProtocols = supportedHTTPVersions.alpnIdentifiers

            try channel.pipeline.syncOperations.addHandler(
                self.makeSSLServerHandler(
                    tlsConfiguration,
                    self.configuration.transportSecurity.customVerificationCallback
                )
            )
        }.flatMap {
            channel.eventLoop.makeCompletedFuture {
                let alpnHandler = self.makeALPNHandler(
                    channel: channel,
                    http2Config: supportedHTTPVersions.http2ConfigIfSupported
                )

                do {
                    try channel.pipeline.syncOperations.addHandler(alpnHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return alpnHandler.protocolNegotiationResult
            }
        }
    }

    private func makeALPNHandler(
        channel: any Channel,
        http2Config: NIOHTTPServerConfiguration.HTTP2?
    ) -> NIOTypedApplicationProtocolNegotiationHandler<NegotiatedChannel> {
        NIOTypedApplicationProtocolNegotiationHandler<NegotiatedChannel> { result in
            switch (result, http2Config) {
            case (.negotiated("http/1.1"), _):
                return self.http1ConnectionInitializer(channel: channel).map { .http1_1($0) }

            case (.negotiated("h2"), .some(let http2Config)):
                return self.http2ConnectionInitializer(channel: channel, configuration: http2Config).map { .http2($0) }

            case (.negotiated, _), (.fallback, _):
                // The negotiated result was an unsupported protocol, or ALPN negotiation failed / never took place.
                return channel.close().flatMap { channel.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
            }
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
