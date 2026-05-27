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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    typealias NegotiatedChannel = NIONegotiatedHTTPVersion<
        NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        (any Channel, NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>)
    >

    /// Serves incoming connections. Each connection undergoes ALPN negotiation to determine whether to use HTTP/1.1 or
    /// HTTP/2, and requests are then handled over the negotiated protocol.
    ///
    /// Each accepted connection is handled concurrently in its own child task. Individual negotiation errors and
    /// connection errors are handled within the child tasks and do not affect other connections.
    ///
    /// - Parameters:
    ///   - serverChannel: The async channel that produces incoming connections.
    ///   - handler: The request handler.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveSecureUpgrade(
        serverChannel: NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
            // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
            // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
            // `inbound`) must be caught and handled directly.
            let inboundConnectionIterationError = await withDiscardingTaskGroup { connectionGroup -> (any Error)? in
                do {
                    for try await upgradeResult in inbound {
                        connectionGroup.addTask {
                            let negotiatedChannel: NegotiatedChannel

                            do {
                                negotiatedChannel = try await upgradeResult.get()
                            } catch {
                                self.logger.debug("Negotiating ALPN failed", metadata: ["error": "\(error)"])
                                return
                            }

                            switch negotiatedChannel {
                            case .http1_1(let requestChannel):
                                await self.serveHTTP1Connection(
                                    requestChannel: requestChannel,
                                    handler: handler
                                )

                            case .http2((let connectionChannel, let multiplexer)):
                                await self.serveHTTP2Connection(
                                    connectionChannel: connectionChannel,
                                    multiplexer: multiplexer,
                                    handler: handler
                                )
                            }
                        }
                    }

                    return nil
                } catch {
                    return error
                }
            }

            if let inboundConnectionIterationError {
                // The error occurred while iterating the inbound connection stream
                throw inboundConnectionIterationError
            }
        }
    }

    /// Serves a HTTP/1.1 connection.
    ///
    /// - Parameters:
    ///   - requestChannel: The HTTP/1.1 request channel.
    ///   - handler: The request handler.
    private func serveHTTP1Connection(
        requestChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async {
        let chainFuture = requestChannel.channel.nioSSL_peerValidatedCertificateChain()

        await Self.$connectionContext.withValue(ConnectionContext(chainFuture)) {
            await self.handleHTTP1RequestChannel(
                channel: requestChannel,
                handler: handler
            )
        }
    }

    /// Serves a HTTP/2 connection by iterating the stream channels and handling each stream concurrently.
    ///
    /// - Note: Stream iteration errors are logged but do not propagate to the caller.
    ///
    /// - Parameters:
    ///   - connectionChannel: The underlying NIO channel for the HTTP/2 connection.
    ///   - multiplexer: The HTTP/2 stream multiplexer.
    ///   - handler: The request handler.
    private func serveHTTP2Connection(
        connectionChannel: any Channel,
        multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async {
        await withDiscardingTaskGroup { streamGroup in
            do {
                let chainFuture = connectionChannel.nioSSL_peerValidatedCertificateChain()

                try await Self.$connectionContext.withValue(ConnectionContext(chainFuture)) {
                    for try await streamChannel in multiplexer.inbound {
                        streamGroup.addTask {
                            await self.handleHTTP2StreamChannel(
                                channel: streamChannel,
                                handler: handler
                            )
                        }
                    }
                }
            } catch {
                self.logger.error(
                    "Error thrown while iterating over incoming HTTP/2 streams",
                    metadata: ["error": "\(error)"]
                )
            }
        }
    }

    func setupSecureUpgradeServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget],
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>,
        tlsConfiguration: TLSConfiguration
    ) async throws -> [NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>] {
        let bootstrap = ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        self.serverQuiescingHelper.makeServerChannelHandler(channel: channel)
                    )
                }
            }

        var serverChannels = [NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>]()
        do {
            for bindTarget in bindTargets {
                switch bindTarget.backing {
                case .hostAndPort(let host, let port):
                    let serverChannel =
                        try await bootstrap.bind(host: host, port: port) { channel in
                            self.setupSecureUpgradeConnectionChildChannel(
                                channel: channel,
                                supportedHTTPVersions: supportedHTTPVersions,
                                tlsConfiguration: tlsConfiguration
                            )
                        }
                    serverChannels.append(serverChannel)
                }
            }
        } catch {
            // A later bind failed: close any channels we already bound to avoid leaking sockets.
            // We await the closes so the sockets are fully released by the time we throw, giving the
            // caller deterministic semantics: when `serve` throws, all cleanup is done.
            for serverChannel in serverChannels {
                try? await serverChannel.channel.close()
            }
            throw error
        }

        try self.addressesBound(serverChannels.map { $0.channel.localAddress })

        return serverChannels
    }

    private func setupHTTP2Connection(
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
                return self.setupHTTP1_1Connection(
                    channel: channel,
                    asyncChannelConfiguration: .init(
                        backPressureStrategy: .init(self.configuration.backpressureStrategy),
                        isOutboundHalfClosureEnabled: true
                    ),
                    isSecure: true
                )
                .map { .http1_1($0) }

            case (.negotiated("h2"), .some(let http2Config)):
                return self.setupHTTP2Connection(
                    channel: channel,
                    configuration: http2Config
                ).map { .http2($0) }

            case (.negotiated, _), (.fallback, _):
                // The negotiated result was an unsupported protocol, or ALPN negotiation failed / never took place.
                return channel.close().flatMap { channel.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
            }
        }
    }

    /// Handles an HTTP/2 stream channel, which carries exactly one request per stream.
    func handleHTTP2StreamChannel(
        channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async {
        do {
            try await channel
                .executeThenClose { inbound, outbound in
                    var iterator = inbound.makeAsyncIterator()

                    guard let httpRequest = try await self.nextRequestHead(from: &iterator) else {
                        outbound.finish()
                        return
                    }

                    _ = try await self.invokeHandler(
                        request: httpRequest,
                        iterator: iterator,
                        outbound: outbound,
                        handler: handler
                    )

                    // TODO: handle other state scenarios.
                    // For example, if we didn't finish reading but we wrote back a response, we
                    // should send a RST_STREAM with NO_ERROR set. If we finished reading but we
                    // didn't write back a response, then RST_STREAM is also likely appropriate but
                    // unclear about the error.

                    // Finish the outbound and wait on the close future to make sure all pending
                    // writes are actually written.
                    outbound.finish()
                    try await channel.channel.closeFuture.get()
                }
        } catch {
            self.logger.debug("Error thrown while handling HTTP/2 stream: \(error)")
            try? await channel.channel.close()
        }
    }
}

@available(anyAppleOS 26.0, *)
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
