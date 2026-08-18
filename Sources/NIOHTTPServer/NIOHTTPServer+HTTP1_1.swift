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
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix
import NIOSSL

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Serves incoming plaintext HTTP/1.1 connections.
    ///
    /// Each connection is handled concurrently in its own child task. Individual connection errors are handled within
    /// the child tasks and do not affect other connections.
    ///
    /// - Parameters:
    ///   - serverChannel: The async channel that produces incoming HTTP/1.1 connections.
    ///   - connectionHandler: The connection handler invoked for each accepted connection.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveInsecureHTTP1_1<Handler: NIOHTTPServerConnectionHandler>(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>,
        connectionHandler: Handler
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
            // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
            // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
            // `inbound`) must be caught and handled directly.
            let inboundConnectionIterationError = await withDiscardingTaskGroup { group -> (any Error)? in
                do {
                    for try await requestChannel in inbound {
                        group.addTask {
                            await self.dispatchPlaintextHTTP1_1Connection(
                                requestChannel: requestChannel,
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

    /// Builds the per-connection ``Connection`` and ``ConnectionContext`` for a
    /// plaintext HTTP/1.1 child channel and dispatches to the connection
    /// handler. Errors from the connection handler are logged.
    ///
    /// The dispatcher owns the channel's `executeThenClose` so the
    /// `NIOAsyncWriter` is finished cleanly whether or not the connection
    /// handler called ``Connection/handleRequests(handler:)``.
    private func dispatchPlaintextHTTP1_1Connection<Handler: NIOHTTPServerConnectionHandler>(
        requestChannel: sending NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        connectionHandler: Handler
    ) async {
        do {
            try await requestChannel.executeThenClose { inbound, outbound in
                let context = ConnectionContext(
                    httpVersion: .plaintextHTTP1_1,
                    remoteAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.remoteAddress),
                    localAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.localAddress),
                    peerCertificateChainFuture: nil
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
                "Error tearing down HTTP/1.1 channel",
                error: error
            )
        }
    }

    func setupHTTP1_1ServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget]
    ) async throws -> [(
        NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>, ServerQuiescingHelper
    )] {
        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

        var serverChannels = [
            (NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>, ServerQuiescingHelper)
        ]()

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
                        self.setupHTTP1_1Connection(
                            channel: channel,
                            asyncChannelConfiguration: .init(
                                backPressureStrategy: .init(self.configuration.backpressureStrategy),
                                isOutboundHalfClosureEnabled: true
                            ),
                            isSecure: false
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

    /// Configures the HTTP/1.1 server pipeline and the keep-alive handler.
    func setupHTTP1_1Connection(
        channel: any Channel,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        isSecure: Bool
    ) -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> {
        channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: isSecure))
            try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())
            try channel.pipeline.syncOperations.addTimeoutHandlers(
                self.configuration.connectionTimeouts,
                expectMultipleRequests: true
            )

            return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                wrappingChannelSynchronously: channel,
                configuration: asyncChannelConfiguration
            )
        }
    }

    /// Drives the request loop on an HTTP/1.1 connection that may carry
    /// multiple serial requests (keep-alive). Invoked from
    /// ``NIOHTTPServer/Connection/handleRequests(handler:)`` for the
    /// HTTP/1.1 case.
    ///
    /// The caller (the dispatcher) owns the channel's `executeThenClose`,
    /// so this method only iterates inbound requests and writes responses;
    /// it never closes the channel itself. The loop terminates when the
    /// peer closes the connection, the task is cancelled, or an error
    /// occurs.
    func handleHTTP1RequestLoop<Handler: HTTPServerRequestHandler>(
        channel: any Channel,
        inbound: NIOAsyncChannelInboundStream<HTTPRequestPart>,
        outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
        handler: Handler,
        context: ConnectionContext
    ) async
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        do {
            var iterator = inbound.makeAsyncIterator()

            requestLoop: while !Task.isCancelled {
                guard let httpRequest = try await self.nextRequestHead(from: &iterator) else {
                    break requestLoop
                }

                let requestContext = RequestContext(connectionContext: context, channel: channel)

                guard
                    let recoveredIterator = await self.invokeHandler(
                        request: httpRequest,
                        iterator: iterator,
                        outbound: outbound,
                        requestContext: requestContext,
                        handler: handler
                    )
                else {
                    // Handler did not fully consume the request; cannot continue on this
                    // connection.
                    break requestLoop
                }

                iterator = recoveredIterator
            }
        } catch {
            self.logger.debug(
                "Error thrown while handling HTTP/1.1 connection",
                error: error
            )
        }
    }
}
