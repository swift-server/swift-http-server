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
    ///   - connectionStream: The stream of incoming HTTP/1.1 connections.
    ///   - connectionHandler: The connection handler invoked for each accepted connection.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveInsecureHTTP1_1<Handler: NIOHTTPServerConnectionHandler>(
        connectionStream: NIOAsyncChannelInboundStream<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>,
        connectionHandler: Handler
    ) async throws {
        // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
        // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
        // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
        // `inbound`) must be caught and handled directly.
        let inboundConnectionIterationError = await withDiscardingTaskGroup { group -> (any Error)? in
            do {
                for try await requestChannel in connectionStream {
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

    /// Adds a child task to `group` that binds a plaintext HTTP/1.1 listener at `address` and serves connections on it
    /// until the task is cancelled or the server shuts down gracefully.
    ///
    /// - Note: The bind address is yielded to the provided `addressContinuation` immediately after the TCP socket has
    ///   been bound.
    func addPlaintextHTTP1_1Listener<Handler: NIOHTTPServerConnectionHandler>(
        to group: inout ThrowingDiscardingTaskGroup<any Error>,
        address: NIOCore.SocketAddress,
        addressContinuation: AsyncThrowingStream<NIOCore.SocketAddress, any Error>.Continuation,
        connectionHandler: Handler
    ) {
        group.addTask(name: "Plaintext HTTP/1.1 over \(address)") {
            try await self.withTCPChannel(
                address: address,
                addressContinuation: addressContinuation,
                childChannelInitializer: { channel in
                    self.setupHTTP1_1Connection(channel: channel, isSecure: false)
                }
            ) { inbound in
                try await self.serveInsecureHTTP1_1(connectionStream: inbound, connectionHandler: connectionHandler)
            }
        }
    }

    /// Configures the HTTP/1.1 server pipeline and the keep-alive handler.
    func setupHTTP1_1Connection(
        channel: any Channel,
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
                configuration: .init(
                    backPressureStrategy: .init(self.configuration.backpressureStrategy),
                    isOutboundHalfClosureEnabled: true
                )
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
                guard let httpRequest = try await iterator.nextRequestHead(logger: self.logger) else {
                    break requestLoop
                }

                let requestContext = RequestContext(connectionContext: context, channel: channel)

                guard
                    let recoveredIterator = await self.invokeHandler(
                        request: httpRequest,
                        requestContext: requestContext,
                        inboundIterator: iterator,
                        outbound: outbound,
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
