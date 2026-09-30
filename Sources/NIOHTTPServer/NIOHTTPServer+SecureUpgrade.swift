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
    struct NegotiationResult {
        enum NegotiatedChannel {
            case http1_1(HTTPRequestChannelAndCancellationSignal)
            case http2(
                any Channel,
                NIOHTTP2Handler.AsyncStreamMultiplexer<HTTPRequestChannelAndCancellationSignal>
            )
        }

        let channel: NegotiatedChannel
        let validatedPeerCertificateChain: X509.ValidatedCertificateChain?
    }

    /// Serves incoming connections. Each connection undergoes ALPN negotiation to determine whether to use HTTP/1.1 or
    /// HTTP/2, and requests are then handled over the negotiated protocol.
    ///
    /// Each accepted connection is handled concurrently in its own child task. Individual negotiation errors and
    /// connection errors are handled within the child tasks and do not affect other connections.
    ///
    /// - Parameters:
    ///   - connectionStream: The stream of incoming connections.
    ///   - connectionHandler: The connection handler invoked for each accepted connection.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveSecureUpgrade<Handler: NIOHTTPServerConnectionHandler>(
        connectionStream: NIOAsyncChannelInboundStream<EventLoopFuture<NegotiationResult>>,
        connectionHandler: Handler
    ) async throws {
        // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
        // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
        // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
        // `inbound`) must be caught and handled directly.
        let inboundConnectionIterationError = await withDiscardingTaskGroup { connectionGroup -> (any Error)? in
            do {
                for try await upgradeResult in connectionStream {
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

    private func dispatchSecureConnection<Handler: NIOHTTPServerConnectionHandler>(
        upgradeResult: EventLoopFuture<NegotiationResult>,
        connectionHandler: Handler
    ) async {
        let result: NegotiationResult
        do {
            result = try await upgradeResult.get()
        } catch {
            self.logger.debug("Negotiating ALPN failed", error: error)
            return
        }

        switch result.channel {
        case .http1_1(let requestChannel):
            // The dispatcher owns the channel's `executeThenClose` so the
            // `NIOAsyncWriter` is finished cleanly whether or not the
            // connection handler called `handleRequests`.
            do {
                try await requestChannel.channel.executeThenClose { inbound, outbound in
                    let context = ConnectionContext(
                        httpVersion: .http1_1,
                        remoteAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.channel.remoteAddress),
                        localAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.channel.localAddress),
                        validatedPeerCertificateChain: result.validatedPeerCertificateChain
                    )
                    let connection = Connection(
                        server: self,
                        context: context,
                        httpProtocol: .http1_1(
                            channel: requestChannel.channel.channel,
                            inbound: inbound,
                            outbound: outbound,
                            clientClosed: requestChannel.clientClosed
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

        case .http2(let connectionChannel, let multiplexer):
            let context = NIOHTTPServer.makeHTTP2ConnectionContext(
                connectionChannel: connectionChannel,
                validatedPeerCertificateChain: result.validatedPeerCertificateChain
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
        validatedPeerCertificateChain: X509.ValidatedCertificateChain?
    ) -> ConnectionContext {
        ConnectionContext(
            httpVersion: .http2,
            remoteAddress: try? NIOHTTPServer.SocketAddress(connectionChannel.remoteAddress),
            localAddress: try? NIOHTTPServer.SocketAddress(connectionChannel.localAddress),
            validatedPeerCertificateChain: validatedPeerCertificateChain
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
        multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<HTTPRequestChannelAndCancellationSignal>,
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
                for try await stream in multiplexer.inbound {
                    streamGroup.addTask {
                        await stream.channel.withRequest(
                            clientClosed: stream.clientClosed,
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

    /// Adds a child task to `group` that binds a listener at `address` and serves connections on it until the task is
    /// cancelled or the server shuts down gracefully. Each accepted connection negotiates HTTP/1.1 or HTTP/2 via ALPN.
    ///
    /// - Note: The bind address is yielded to the provided `addressContinuation` immediately after the TCP socket has
    ///   been bound.
    func addSecureUpgradeListener<Handler: NIOHTTPServerConnectionHandler>(
        to group: inout ThrowingDiscardingTaskGroup<any Error>,
        address: NIOCore.SocketAddress,
        configuration: ListenerConfiguration.SecureUpgrade,
        addressContinuation: AsyncThrowingStream<NIOCore.SocketAddress, any Error>.Continuation,
        connectionHandler: Handler
    ) {
        group.addTask(name: "Secure Upgrade over \(address)") {
            try await self.withTCPChannel(
                address: address,
                addressContinuation: addressContinuation,
                childChannelInitializer: { channel in
                    self.setupSecureUpgradeConnection(channel: channel, configuration: configuration)
                }
            ) { inbound in
                try await self.serveSecureUpgrade(connectionStream: inbound, connectionHandler: connectionHandler)
            }
        }
    }

    private func setupHTTP2Connection(
        channel: any Channel,
        configuration: NIOHTTPServerConfiguration.HTTP2
    ) -> EventLoopFuture<
        (any Channel, NIOHTTP2Handler.AsyncStreamMultiplexer<HTTPRequestChannelAndCancellationSignal>)
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

                        // Reports this stream going inactive, so an in-flight request handler can be
                        // cancelled. Scoped to the stream rather than the connection: NIO closes the stream
                        // channel both for a client RST_STREAM and when the connection beneath it dies, so
                        // the stream sees everything the connection would.
                        let (clientClosed, clientClosedContinuation) = AsyncStream<Void>.makeStream()
                        try http2StreamChannel.pipeline.syncOperations.addHandler(
                            ClientClosedMonitor(clientClosed: clientClosedContinuation)
                        )

                        return HTTPRequestChannelAndCancellationSignal(
                            channel: try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                wrappingChannelSynchronously: http2StreamChannel,
                                configuration: .init(
                                    backPressureStrategy: .init(self.configuration.backpressureStrategy),
                                    isOutboundHalfClosureEnabled: true
                                )
                            ),
                            clientClosed: clientClosed
                        )
                    }
                }
            )
        }
        .flatMap { multiplexer in
            channel.eventLoop.makeCompletedFuture(.success((channel, multiplexer)))
        }
    }

    func setupSecureUpgradeConnection(
        channel: any Channel,
        configuration: ListenerConfiguration.SecureUpgrade
    ) -> EventLoopFuture<EventLoopFuture<NegotiationResult>> {
        channel.eventLoop.makeCompletedFuture {
            let sslHandler = self.makeSSLServerHandler(
                configuration.sslContext,
                self.configuration.transportSecurity.customVerificationCallback
            )
            let alpnHandler = self.makeALPNHandler(channel: channel, http2Config: configuration.http2Configuration)

            try channel.pipeline.syncOperations.addHandlers([sslHandler, alpnHandler])

            return alpnHandler.protocolNegotiationResult
        }
    }

    private func makeALPNHandler(
        channel: any Channel,
        http2Config: NIOHTTPServerConfiguration.HTTP2?
    ) -> NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> {
        NIOTypedApplicationProtocolNegotiationHandler<NegotiationResult> { result in
            switch (result, http2Config) {
            case (.negotiated("http/1.1"), _):
                return self.setupHTTP1_1Connection(
                    channel: channel,
                    isSecure: true
                ).map { requestChannel in
                    NegotiationResult(
                        channel: .http1_1(requestChannel),
                        validatedPeerCertificateChain: requestChannel.channel.channel
                            .extractPeerCertificateChain(logger: self.logger)
                    )
                }

            case (.negotiated("h2"), .some(let http2Config)):
                return self.setupHTTP2Connection(
                    channel: channel,
                    configuration: http2Config
                ).map { (channel, streamMultiplexer) in
                    NegotiationResult(
                        channel: .http2(channel, streamMultiplexer),
                        validatedPeerCertificateChain: channel.extractPeerCertificateChain(logger: self.logger)
                    )
                }

            case (.negotiated, _), (.fallback, _):
                // The negotiated result was an unsupported protocol, or ALPN negotiation failed / never took place.
                return channel.close().flatMap { channel.eventLoop.makeFailedFuture(NIOHTTP2Errors.invalidALPNToken()) }
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOAsyncChannel where Inbound == HTTPRequestPart, Outbound == HTTPResponsePart {
    /// - Parameter clientClosed: Yields when the client stops waiting for a response, at which point `body`
    ///   is cancelled. Paired with the continuation held by this stream's `ClientClosedMonitor`.
    func withRequest(
        clientClosed: AsyncStream<Void>,
        logger: Logger,
        context: NIOHTTPServer.ConnectionContext,
        body:
            @escaping @Sendable (
                _ request: HTTPRequest,
                _ requestContext: NIOHTTPServer.RequestContext,
                _ inboundIterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
                _ outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
            ) async -> Void
    ) async {
        do {
            try await self.executeThenClose { inbound, outbound in
                // Racing the whole request against the client going away is what cancels `body` if the
                // client abandons the exchange. Built inside this closure because the iterator is
                // non-`Sendable` and cannot cross into a child task. See `ClientClosed.swift`.
                @Sendable func handleRequest() async throws {
                    var iterator = inbound.makeAsyncIterator()

                    guard let httpRequest = try await iterator.nextRequestHead(logger: logger) else {
                        outbound.finish()
                        return
                    }

                    let requestContext = NIOHTTPServer.RequestContext(
                        connectionContext: context,
                        channel: self.channel
                    )

                    await body(httpRequest, requestContext, iterator, outbound)

                    // TODO: handle the remaining state scenarios for a handler that returned without throwing.
                    // For example, if we didn't finish reading but we wrote back a response, we should send a
                    // RST_STREAM with NO_ERROR set. If we finished reading but we didn't write back a response,
                    // then RST_STREAM is also likely appropriate but unclear about the error. (A handler that
                    // throws already resets the stream; see `invokeHandler`.)

                    // Finish the outbound and wait on the close future to make sure all pending writes are
                    // actually written.
                    outbound.finish()
                    try await self.channel.closeFuture.get()
                }

                try await withCancellationWhenClientCloses(
                    signalledBy: clientClosed,
                    operation: handleRequest
                )
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

extension Channel {
    func extractPeerCertificateChain(logger: Logger) -> X509.ValidatedCertificateChain? {
        self.eventLoop.preconditionInEventLoop()

        do {
            let peerChain = try self.pipeline.syncOperations.nioSSL_peerValidatedCertificateChain()
            if let peerChain {
                return .init(uncheckedCertificateChain: try peerChain.map { try Certificate($0) })
            }
        } catch {
            logger.debug("Failed to extract the peer's certificate chain", error: error)
        }

        return nil
    }
}
