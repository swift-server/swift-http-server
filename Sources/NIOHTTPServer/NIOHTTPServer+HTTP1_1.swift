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
import NIOConcurrencyHelpers
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix
import NIOSSL

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// An HTTP/1.1 connection vended by the accept loop: the async channel and
    /// the close flag the channel's ``HTTPKeepAliveHandler`` shares with the
    /// connection context.
    struct HTTP1ChildConnection: Sendable {
        let asyncChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>
        let closeFlag: NIOLockedValueBox<Bool>
    }

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
        serverChannel: NIOAsyncChannel<HTTP1ChildConnection, Never>,
        connectionHandler: Handler
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
            // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
            // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
            // `inbound`) must be caught and handled directly.
            let inboundConnectionIterationError = await withDiscardingTaskGroup { group -> (any Error)? in
                do {
                    for try await child in inbound {
                        group.addTask {
                            await self.dispatchPlaintextHTTP1_1Connection(
                                child: child,
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
        child: sending HTTP1ChildConnection,
        connectionHandler: Handler
    ) async {
        do {
            try await child.asyncChannel.executeThenClose { inbound, outbound in
                let context = NIOHTTPServer.makeHTTP1ConnectionContext(
                    requestChannel: child.asyncChannel,
                    closeFlag: child.closeFlag,
                    peerCertificateChainFuture: nil
                )
                let connection = Connection(
                    server: self,
                    context: context,
                    httpProtocol: .http1_1(inbound: inbound, outbound: outbound)
                )
                do {
                    try await connectionHandler.handleConnection(connection: connection, context: context)
                } catch {
                    self.logger.debug(
                        "Error thrown by connection handler",
                        metadata: ["error": "\(error)"]
                    )
                }
            }
        } catch {
            self.logger.debug(
                "Error tearing down HTTP/1.1 channel",
                metadata: ["error": "\(error)"]
            )
        }
    }

    func setupHTTP1_1ServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget]
    ) async throws -> [(
        NIOAsyncChannel<HTTP1ChildConnection, Never>, ServerQuiescingHelper
    )] {
        let bootstrap = ServerBootstrap(group: self.eventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)

        var serverChannels = [
            (NIOAsyncChannel<HTTP1ChildConnection, Never>, ServerQuiescingHelper)
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

        try self.addressesBound(serverChannels.map { (serverChannel, _) in serverChannel.channel.localAddress })

        return serverChannels
    }

    /// Configures the HTTP/1.1 server pipeline and the keep-alive handler, sharing
    /// a fresh close flag between the keep-alive handler (which observes it when
    /// writing the next response head) and the eventually-vended ``HTTP1ChildConnection``.
    func setupHTTP1_1Connection(
        channel: any Channel,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        isSecure: Bool
    ) -> EventLoopFuture<HTTP1ChildConnection> {
        let closeFlag = NIOLockedValueBox<Bool>(false)
        return channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: isSecure))
            try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler(closeFlag: closeFlag))
            try channel
                .pipeline
                .syncOperations
                .addTimeoutHandlers(self.configuration.connectionTimeouts)

            let asyncChannel = try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                wrappingChannelSynchronously: channel,
                configuration: asyncChannelConfiguration
            )
            return HTTP1ChildConnection(asyncChannel: asyncChannel, closeFlag: closeFlag)
        }
    }

    /// Builds a ``ConnectionContext`` for an HTTP/1.1 request channel.
    ///
    /// The context's ``ConnectionContext/signalConnectionClose()`` synchronously
    /// flips the shared close flag the channel's ``HTTPKeepAliveHandler``
    /// observes when writing the next response head. The synchronous set
    /// side-steps any race between firing a NIO event off-loop and writing the
    /// response head off-loop. The handler reacts by amending the next response
    /// head with `Connection: close` and closing the channel once the response
    /// `.end` is written.
    static func makeHTTP1ConnectionContext(
        requestChannel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        closeFlag: NIOLockedValueBox<Bool>,
        peerCertificateChainFuture: EventLoopFuture<NIOSSL.ValidatedCertificateChain?>?
    ) -> ConnectionContext {
        ConnectionContext(
            httpVersion: .http1_1,
            remoteAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.remoteAddress),
            localAddress: try? NIOHTTPServer.SocketAddress(requestChannel.channel.localAddress),
            peerCertificateChainFuture: peerCertificateChainFuture,
            closeBacking: .http1_1(closeFlag: closeFlag)
        )
    }

    /// Drives the request loop on an HTTP/1.1 connection that may carry
    /// multiple serial requests (keep-alive). Invoked from
    /// ``NIOHTTPServer/Connection/handleRequests(handler:)`` for the
    /// HTTP/1.1 case.
    ///
    /// The caller (the dispatcher) owns the channel's `executeThenClose`,
    /// so this method only iterates inbound requests and writes responses;
    /// it never closes the channel itself. The loop terminates when the
    /// peer closes the connection, the task is cancelled, the handler
    /// signals close (which causes the ``HTTPKeepAliveHandler`` to close
    /// the channel after the response — the next iterator read then returns
    /// `nil`), or an error occurs.
    func handleHTTP1RequestLoop<Handler: HTTPServerRequestHandler>(
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

                guard
                    let recoveredIterator = try await self.invokeHandler(
                        request: httpRequest,
                        iterator: iterator,
                        outbound: outbound,
                        handler: handler,
                        context: context
                    )
                else {
                    // Handler did not fully consume the request; cannot continue on this
                    // connection.
                    break requestLoop
                }

                iterator = recoveredIterator
            }
        } catch {
            self.logger.debug("Error thrown while handling HTTP/1.1 connection", metadata: ["error": "\(error)"])
        }
    }
}
