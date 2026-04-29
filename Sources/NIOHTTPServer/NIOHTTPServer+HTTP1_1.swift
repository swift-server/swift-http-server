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
import NIOCore
import NIOExtras
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServer {
    /// Serves incoming plaintext HTTP/1.1 connections.
    ///
    /// Each connection is handled concurrently in its own child task. Individual connection errors are handled within
    /// the child tasks and do not affect other connections.
    ///
    /// - Parameters:
    ///   - serverChannel: The async channel that produces incoming HTTP/1.1 connections.
    ///   - handler: The request handler.
    ///
    /// - Throws: If an error occurs while iterating the incoming connection stream.
    func serveInsecureHTTP1_1(
        serverChannel: NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async throws {
        try await serverChannel.executeThenClose { inbound in
            // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child
            // task would immediately propagate upwards, cancelling all child tasks and bringing down the entire server.
            // We instead use a non-throwing discarding task group so that errors in the body (e.g. from iterating
            // `inbound`) must be caught and handled directly.
            let inboundConnectionIterationError = await withDiscardingTaskGroup { group -> (any Error)? in
                do {
                    for try await http1Channel in inbound {
                        group.addTask {
                            await self.handleHTTP1RequestChannel(channel: http1Channel, handler: handler)
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

    func setupHTTP1_1ServerChannel(
        bindTarget: NIOHTTPServerConfiguration.BindTarget
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never> {
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
                    self.setupHTTP1_1ConnectionChildChannel(
                        channel: channel,
                        asyncChannelConfiguration: .init(
                            backPressureStrategy: .init(self.configuration.backpressureStrategy),
                            isOutboundHalfClosureEnabled: true
                        )
                    )
                }

            try self.addressBound(serverChannel.channel.localAddress)

            return serverChannel
        }
    }

    func setupHTTP1_1ConnectionChildChannel(
        channel: any Channel,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration
    ) -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> {
        channel.pipeline.addHandler(LoggingHandler()).flatMap {
            channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))

                return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                    wrappingChannelSynchronously: channel,
                    configuration: asyncChannelConfiguration
                )
            }
        }
    }

    /// Handles an HTTP/1.1 connection channel, which may carry multiple serial requests on the
    /// same connection (keep-alive).
    func handleHTTP1RequestChannel(
        channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: some HTTPServerRequestHandler<RequestConcludingReader, ResponseConcludingWriter>
    ) async {
        do {
            try await channel.executeThenClose { inbound, outbound in
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
                            handler: handler
                        )
                    else {
                        // Handler did not fully consume the request; cannot continue on this
                        // connection.
                        break requestLoop
                    }

                    iterator = recoveredIterator
                }
            }
        } catch {
            self.logger.debug("Error thrown while handling HTTP/1.1 connection", metadata: ["error": "\(error)"])
            try? await channel.channel.close()
        }
    }
}

import Runtime
final class LoggingHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        print("channelRead: \(self.unwrapInboundIn(data))")
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        print("channelReadComplete")
        context.fireChannelReadComplete()
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if #available(macOS 26.0, *) {
            print("close", try! Backtrace.capture().symbolicated()?.description)
        } else {
            // Fallback on earlier versions
        }
        context.close(mode: mode, promise: promise)
    }

    func flush(context: ChannelHandlerContext) {
        print("flush")
        context.flush()
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        print("write: \(self.unwrapOutboundIn(data))")
        context.write(data, promise: promise)
    }
}
