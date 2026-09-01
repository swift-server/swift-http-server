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
    ///   - connectionHandler: The connection handler invoked for each accepted connection.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveSecureUpgrade<Handler: NIOHTTPServerConnectionHandler>(
        serverChannel: NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>,
        connectionHandler: Handler
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
                            await self.dispatchSecureConnection(
                                upgradeResult: upgradeResult,
                                connectionHandler: connectionHandler
                            )
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

    private func dispatchSecureConnection<Handler: NIOHTTPServerConnectionHandler>(
        upgradeResult: EventLoopFuture<NegotiatedChannel>,
        connectionHandler: Handler
    ) async {
        let negotiatedChannel: NegotiatedChannel
        do {
            negotiatedChannel = try await upgradeResult.get()
        } catch {
            self.logger.debug(
                "Negotiating ALPN failed",
                error: error
            )
            return
        }

        switch negotiatedChannel {
        case .http1_1(let requestChannel):
            // The dispatcher owns the channel's `executeThenClose` so the
            // `NIOAsyncWriter` is finished cleanly whether or not the
            // connection handler called `handleRequests`.
            do {
                try await requestChannel.executeThenClose { inbound, outbound in
                    let chainFuture = requestChannel.channel.nioSSL_peerValidatedCertificateChain()
                    let context = ConnectionContext(
                        httpVersion: .http1_1,
                        remoteAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.remoteAddress),
                        localAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.localAddress),
                        peerCertificateChainFuture: chainFuture
                    )
                    let connection = Connection(
                        server: self,
                        context: context,
                        httpProtocol: .http1_1(
                            channel: requestChannel.channel,
                            inbound: inbound,
                            outbound: outbound
                        )
                    )
                    do {
                        try await connectionHandler.handleConnection(connection: connection, context: context)
                    } catch {
                        self.logger.debug(
                            "Error thrown by connection handler",
                            error: error
                        )
                    }
                }
            } catch {
                self.logger.debug(
                    "Error handling HTTP/1.1 connection",
                    error: error
                )
            }

        case .http2((let connectionChannel, let multiplexer)):
            let chainFuture = connectionChannel.nioSSL_peerValidatedCertificateChain()
            let context = NIOHTTPServer.makeHTTP2ConnectionContext(
                connectionChannel: connectionChannel,
                peerCertificateChainFuture: chainFuture
            )
            let connection = Connection(
                server: self,
                context: context,
                httpProtocol: .http2(connectionChannel: connectionChannel, multiplexer: multiplexer)
            )

            defer { try? await connectionChannel.close() }
            do {
                try await connectionHandler.handleConnection(connection: connection, context: context)
            } catch {
                self.logger.debug(
                    "Error thrown by connection handler",
                    error: error
                )
            }
        }
    }

    /// Builds a ``ConnectionContext`` for an HTTP/2 connection channel.
    static func makeHTTP2ConnectionContext(
        connectionChannel: any Channel,
        peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>?
    ) -> ConnectionContext {
        ConnectionContext(
            httpVersion: .http2,
            remoteAddress: try? NIOHTTPServer.SocketAddress(connectionChannel.remoteAddress),
            localAddress: try? NIOHTTPServer.SocketAddress(connectionChannel.localAddress),
            peerCertificateChainFuture: peerCertificateChainFuture
        )
    }

    /// Drives the request loop on a HTTP/2 connection by iterating the stream
    /// channels and handling each stream concurrently.
    ///
    /// This is the per-connection loop body invoked from
    /// ``NIOHTTPServer/Connection/handleRequests(handler:)`` for the HTTP/2
    /// case. After iteration ends, this method closes the connection channel.
    ///
    /// - Note: Stream iteration errors are logged but do not propagate to the caller.
    func handleHTTP2Connection<Handler: HTTPServerRequestHandler>(
        connectionChannel: any Channel,
        multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>,
        handler: Handler,
        context: ConnectionContext
    ) async
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        await withDiscardingTaskGroup { streamGroup in
            do {
                for try await streamChannel in multiplexer.inbound {
                    streamGroup.addTask {
                        await streamChannel.withRequest(
                            logger: self.logger,
                            context: context
                        ) { request, requestContext, inboundIterator, outbound in
                            _ = await self.invokeHandler(
                                request: request,
                                requestContext: requestContext,
                                inboundIterator: inboundIterator,
                                outbound: outbound,
                                handler: handler
                            )
                        }
                    }
                }
            } catch {
                self.logger.debug(
                    "Error thrown while iterating over incoming HTTP/2 streams",
                    error: error
                )
            }

            // Close the connection channel before the task group joins
            // in-flight stream tasks. This drives NIO HTTP/2's
            // `propagateChannelInactive`, which closes each stream channel so
            // its `handleHTTP2StreamChannel` task can complete cleanly.
            do {
                try await connectionChannel.close()
            } catch ChannelError.alreadyClosed {
                ()
            } catch {
                self.logger.debug(
                    "Error thrown while closing the HTTP/2 connection channel",
                    error: error
                )
            }
        }
    }

    func setupSecureUpgradeServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget],
        http2Configuration: NIOHTTPServerConfiguration.HTTP2?,
        sslContext: NIOSSLContext
    ) async throws -> [(NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>, ServerQuiescingHelper)] {
        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

        var serverChannels = [(NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>, ServerQuiescingHelper)]()
        do {
            for bindTarget in bindTargets {
                switch bindTarget.backing {
                case .hostAndPort(let host, let port):
                    let serverQuiescingHelper = ServerQuiescingHelper(group: self.eventLoopGroup)

                    let serverChannel = try await bootstrap.serverChannelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(
                                serverQuiescingHelper.makeServerChannelHandler(channel: channel)
                            )

                            if let maxConnections = self.configuration.maxConnections {
                                try channel.pipeline.syncOperations.addHandler(
                                    ConnectionLimitHandler(maxConnections: maxConnections)
                                )
                            }
                        }
                    }.bind(host: host, port: port) { channel in
                        self.setupSecureUpgradeConnectionChildChannel(
                            channel: channel,
                            http2Configuration: http2Configuration,
                            sslContext: sslContext
                        )
                    }
                    serverChannels.append((serverChannel, serverQuiescingHelper))
                }
            }
        } catch {
            // A later bind failed: close any channels we already bound to avoid leaking sockets.
            // We await the closes so the sockets are fully released by the time we throw, giving the
            // caller deterministic semantics: when `serve` throws, all cleanup is done.
            for (serverChannel, _) in serverChannels {
                try? await serverChannel.channel.close()
            }
            throw error
        }

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
                    maxIdleTime: self.configuration.connectionTimeouts.idle.map { TimeAmount($0) },
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

                        // Add read header and body timeouts per-stream for HTTP/2
                        try http2StreamChannel.pipeline.syncOperations.addReadTimeoutHandlers(
                            self.configuration.connectionTimeouts,
                            expectMultipleRequests: false
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
        http2Configuration: NIOHTTPServerConfiguration.HTTP2?,
        sslContext: NIOSSLContext
    ) -> EventLoopFuture<EventLoopFuture<NegotiatedChannel>> {
        channel.eventLoop.makeCompletedFuture {
            let sslHandler = self.makeSSLServerHandler(
                sslContext,
                self.configuration.transportSecurity.customVerificationCallback
            )
            let alpnHandler = self.makeALPNHandler(channel: channel, http2Config: http2Configuration)

            try channel.pipeline.syncOperations.addHandlers([sslHandler, alpnHandler])

            return alpnHandler.protocolNegotiationResult
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
}

@available(anyAppleOS 26.0, *)
extension NIOAsyncChannel where Inbound == HTTPRequestPart, Outbound == HTTPResponsePart {
    func withRequest(
        logger: Logger,
        context: NIOHTTPServer.ConnectionContext,
        body: (
            _ request: HTTPRequest,
            _ requestContext: NIOHTTPServer.RequestContext,
            _ inboundIterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
            _ outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        ) async -> Void
    ) async {
        do {
            try await self.executeThenClose { inbound, outbound in
                var iterator = inbound.makeAsyncIterator()

                guard let httpRequest = try await iterator.nextRequestHead(logger: logger) else {
                    outbound.finish()
                    return
                }

                let requestContext = NIOHTTPServer.RequestContext(connectionContext: context, channel: self.channel)

                await body(httpRequest, requestContext, iterator, outbound)

                // TODO: handle the remaining state scenarios for a handler that returned without throwing. For
                // example, if we didn't finish reading but we wrote back a response, we should send a RST_STREAM with
                // NO_ERROR set. If we finished reading but we didn't write back a response, then RST_STREAM is also
                // likely appropriate but unclear about the error. (A handler that throws already resets the stream;
                // see `invokeHandler`.)

                // Finish the outbound and wait on the close future to make sure all pending writes are actually
                // written.
                outbound.finish()
                try await self.channel.closeFuture.get()
            }
        } catch {
            logger.debug(
                "Error thrown while handling stream",
                error: error,
                metadata: [LoggingKeys.protocol: "\(context.httpVersion)"]
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    func makeSSLServerHandler(
        _ sslContext: NIOSSLContext,
        _ customVerificationCallback: (@Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult)?
    ) -> NIOSSLServerHandler {
        if let customVerificationCallback {
            return NIOSSLServerHandler(
                context: sslContext,
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
                            self.logger.debug(
                                "Custom certificate verification failed",
                                error: error
                            )
                            return .failed
                        }
                    }
                }
            )
        } else {
            return NIOSSLServerHandler(context: sslContext)
        }
    }
}
