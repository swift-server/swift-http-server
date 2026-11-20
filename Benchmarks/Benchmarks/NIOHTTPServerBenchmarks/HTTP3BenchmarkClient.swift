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

import HTTP3
import Logging
import NIOCore
import NIOHTTP3
import NIOHTTPServer
import NIOPosix
import NIOQUIC

struct HTTP3BenchmarkClient {
    private let quicHandler: NIOLoopBound<QUICHandler<QUICStreamChannels>>
    private let serverAddress: SocketAddress
    private let logger: Logger

    private init(
        quicHandler: NIOLoopBound<QUICHandler<QUICStreamChannels>>,
        serverAddress: SocketAddress,
        logger: Logger
    ) {
        self.quicHandler = quicHandler
        self.serverAddress = serverAddress
        self.logger = logger
    }

    static func withClient(
        connectingTo serverAddress: NIOHTTPServer.SocketAddress,
        certificate: BenchmarkCertificate,
        body: (HTTP3BenchmarkClient) async throws -> Void
    ) async throws {
        let logger = Logger(label: "NIOHTTPServerBenchmarks.client")
        let remoteAddress = try SocketAddress(ipAddress: serverAddress.host, port: serverAddress.port)
        let quicConfiguration = QUICConfiguration.forClient(
            verificationConfiguration: .x509Certificates(trustRootsFilePath: certificate.certificatePath),
            applicationProtocols: ["h3"]
        )
        let trustRootsPath = certificate.certificatePath

        try await MultiThreadedEventLoopGroup.withEventLoopGroup(numberOfThreads: 1) { group in
            let (quicChannel, quicHandler) = try await DatagramBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let quicHandler = QUICHandler(
                            channel: channel,
                            quicConfiguration: quicConfiguration,
                            asyncVerifier: try AsyncVerifier(
                                trustRootsPath: trustRootsPath,
                                certificateVerification: .noHostnameVerification,
                                eventLoop: channel.eventLoop
                            ),
                            authenticator: nil,
                            logger: logger,
                            inboundConnectionInitializer: { connectionChannel, _ in connectionChannel.close() },
                            inboundStreamInitializer: { streamChannel in streamChannel.close() },
                            noMoreConnections: {}
                        )
                        try channel.pipeline.syncOperations.addHandler(quicHandler)
                        return (channel, NIOLoopBound(quicHandler, eventLoop: channel.eventLoop))
                    }
                }

            let client = HTTP3BenchmarkClient(quicHandler: quicHandler, serverAddress: remoteAddress, logger: logger)
            do {
                try await body(client)
                try await quicChannel.close()
            } catch {
                try? await quicChannel.close()
                throw error
            }
        }
    }

    func withConnection(_ body: (HTTP3BenchmarkConnection) async throws -> Void) async throws {
        let (connectionChannel, connection) = try await self.connect()
        do {
            try await body(HTTP3BenchmarkConnection(connection: connection))
            try await connectionChannel.close()
        } catch {
            try? await connectionChannel.close()
            throw error
        }
    }

    private func connect() async throws -> (any Channel, HTTP3ClientConnection<Void, QUICStreamCreator>) {
        let quicHandler = self.quicHandler
        let serverAddress = self.serverAddress
        let logger = self.logger

        return try await quicHandler.eventLoop.flatSubmit {
            let outputPromise = quicHandler.eventLoop.makePromise(
                of: (any Channel, HTTP3ClientConnection<Void, QUICStreamCreator>).self
            )

            let connectionFuture = quicHandler.value.createOutboundConnection(
                serverName: "127.0.0.1",
                remoteAddress: serverAddress,
                connectionInitializer: { connectionChannel, streamCreator in
                    let output = connectionChannel.eventLoop.makeCompletedFuture {
                        let connection = try connectionChannel.pipeline.syncOperations
                            .configureAsyncHTTP3ClientPipeline(
                                streamCreator: streamCreator,
                                logger: logger,
                                inboundPushStreamInitializer: { _ in }
                            )
                        return (connectionChannel, connection)
                    }
                    output.cascade(to: outputPromise)
                    return output.map { _ in }
                },
                inboundStreamInitializer: { streamChannel in
                    do {
                        let http3Handler = try streamChannel.parent!.pipeline.syncOperations.handler(
                            type: HTTP3ConnectionHandler<QUICStreamCreator, HTTP3ClosureInboundStreamInitializer>.self
                        )
                        return http3Handler.inboundStreamReceived(streamChannel)
                    } catch {
                        return streamChannel.eventLoop.makeFailedFuture(error)
                    }
                }
            )
            connectionFuture.cascadeFailure(to: outputPromise)
            return connectionFuture.flatMap { _ in outputPromise.futureResult }
        }.getAbandoningOnCancel()
    }
}

@available(*, unavailable)
extension HTTP3BenchmarkClient: Sendable {}
