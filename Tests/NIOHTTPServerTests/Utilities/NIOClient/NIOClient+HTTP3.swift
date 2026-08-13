//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if HTTP3

import HTTP3
import Logging
import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOHTTPServer
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix
import NIOQUIC

@available(anyAppleOS 26.0, *)
struct QUICConnectionCreator: HTTP3ConnectionCreator {
    let quicHandler: QUICHandler
    let connectionInitializer: @Sendable (any Channel, NIOQUIC.QUICStreamCreator) -> EventLoopFuture<any Channel>
    let inboundStreamInitializer: @Sendable (any Channel) -> EventLoopFuture<Void>

    func createNewConnection(
        serverName: String,
        remoteAddress: SocketAddress,
        connectionInitializer h3ConnectionInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<any Channel> {
        self.quicHandler.createOutboundConnection(
            serverName: serverName,
            remoteAddress: remoteAddress,
            connectionInitializer: { [connectionInitializer] connectionChannel, streamCreator in
                connectionInitializer(connectionChannel, streamCreator).flatMap { newConnectionChannel in
                    h3ConnectionInitializer(newConnectionChannel)
                }
            },
            inboundStreamInitializer: self.inboundStreamInitializer
        ).map { connectionChannel, _ in
            connectionChannel
        }
    }
}

@available(anyAppleOS 26.0, *)
extension Channel {
    /// Adds HTTP/3 client handlers to the pipeline.
    func configureTestHTTP3ClientPipeline(
        logger: Logger,
        settings: HTTP3Settings,
        configuration: HTTP3ClientConfiguration,
        quicConfiguration: QUICConfiguration,
        asyncVerifier: NIOQUIC.AsyncVerifier
    ) throws -> (
        any Channel,
        HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>
    ) {
        let quicHandler = QUICHandler(
            channel: self,
            quicConfiguration: quicConfiguration,
            asyncVerifier: asyncVerifier,
            authenticator: nil,
            logger: logger,
            inboundConnectionInitializer: { _, _ in fatalError() },
            inboundStreamInitializer: { _ in fatalError() },
            noMoreConnections: {}
        )
        try self.pipeline.syncOperations.addHandler(quicHandler)

        let connectionMultiplexer = HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>(
            eventLoop: self.eventLoop,
            createNewConnection: NIOLoopBound(
                QUICConnectionCreator(
                    quicHandler: quicHandler,
                    connectionInitializer: { connectionChannel, streamCreator in
                        connectionChannel.eventLoop.makeCompletedFuture {
                            let h3Handler = HTTP3ConnectionHandler.client(
                                eventLoop: connectionChannel.eventLoop,
                                configuration: configuration,
                                settings: settings,
                                streamCreator: streamCreator,
                                logger: logger,
                                inboundPushStreamInitializer: { _ in fatalError() }
                            )
                            try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                            return connectionChannel
                        }
                    },
                    inboundStreamInitializer: { streamChannel in
                        streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<QUICStreamCreator>.self)
                            .flatMap { http3Handler in
                                http3Handler.inboundStreamReceived(streamChannel)
                            }
                    }
                ),
                eventLoop: self.eventLoop
            )
        )

        return (self, connectionMultiplexer)
    }
}

@available(anyAppleOS 26.0, *)
extension DatagramBootstrap {
    /// Sets up a test HTTP/3 client and returns the QUIC connection channel and the connection multiplexer.
    func setupTestHTTP3Client(
        logger: Logger,
        trustRootsPath: String
    ) async throws -> (
        any Channel,
        HTTP3ClientConnectionMultiplexer<QUICConnectionCreator, QUICStreamCreator>
    ) {
        try await self.channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.configureTestHTTP3ClientPipeline(
                        logger: logger,
                        settings: .init(),
                        configuration: .defaults,
                        quicConfiguration: .makeClientQUICConfig(caPath: trustRootsPath),
                        asyncVerifier: try! .init(
                            trustRootsPath: trustRootsPath,
                            certificateVerification: .noHostnameVerification,
                            eventLoop: channel.eventLoop
                        )
                    )
                }
            }
    }
}

@available(anyAppleOS 26.0, *)
extension HTTP3ClientConnection {
    /// Opens a single request stream on this connection wrapped in a `NIOAsyncChannel`. The stream is closed by the
    /// caller using `executeThenClose`.
    func makeRequestStream() async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        try await self.concurrencyView.createRequestStream {
            let streamChannel = $0.channel
            return streamChannel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: streamChannel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }
    }
}

#endif  // HTTP3
