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
                            await self.handleRequestChannel(channel: http1Channel, handler: handler)
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

    func setupHTTP1_1ServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget]
    ) async throws -> [NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>] {
        let bootstrap = ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .serverChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        self.serverQuiescingHelper.makeServerChannelHandler(channel: channel)
                    )
                }
            }

        var serverChannels = [NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>]()
        do {
            for bindTarget in bindTargets {
                switch bindTarget.backing {
                case .hostAndPort(let host, let port):
                    let serverChannel =
                        try await bootstrap.bind(host: host, port: port) { channel in
                            self.setupHTTP1_1ConnectionChildChannel(
                                channel: channel,
                                asyncChannelConfiguration: .init(
                                    backPressureStrategy: .init(self.configuration.backpressureStrategy),
                                    isOutboundHalfClosureEnabled: true
                                )
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

    func setupHTTP1_1ConnectionChildChannel(
        channel: any Channel,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration
    ) -> EventLoopFuture<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>> {
        channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))

            return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                wrappingChannelSynchronously: channel,
                configuration: asyncChannelConfiguration
            )
        }
    }
}
