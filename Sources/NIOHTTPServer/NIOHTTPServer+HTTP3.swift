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

#if HTTP3
import HTTP3
import Logging
import NIOCore
import NIOEmbedded
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOHTTPTypes
import NIOPosix
import NIOQUIC
import NIOQUICHelpers
import NIOSSL
import X509

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    func serveHTTP3<Handler: NIOHTTPServerConnectionHandler>(
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
            NIOQUIC.QUICStreamCreator
        >,
        connectionHandler: Handler
    ) async {
        // We don't use a `withThrowingDiscardingTaskGroup` here because an error thrown from the body or a child task
        // would immediately propagate upwards, cancelling all child tasks and bringing down the entire server. We
        // instead use a non-throwing discarding task group so that errors in the body must be caught and handled
        // directly.
        await withDiscardingTaskGroup { connectionGroup in
            for await connection in connectionMultiplexer.inboundConnections {
                connectionGroup.addTask {
                    await self.dispatchHTTP3Connection(connection, handler: connectionHandler)
                }
            }
        }
    }

    /// Builds the per-connection ``Connection`` and ``ConnectionContext`` for a HTTP/3 connection channel and
    /// dispatches the connection to the connection handler. Errors from the connection handler are logged.
    func dispatchHTTP3Connection<Handler: NIOHTTPServerConnectionHandler>(
        _ http3Connection: HTTP3ServerConnection<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
            NIOQUIC.QUICStreamCreator
        >,
        handler: Handler
    ) async {
        let context = ConnectionContext(
            httpVersion: .http3,
            remoteAddress: nil,
            localAddress: nil,
            peerCertificateChainFuture: nil
        )

        let connection = Connection(
            server: self,
            context: context,
            httpProtocol: .http3(connection: http3Connection)
        )

        do {
            try await handler.handleConnection(connection: connection, context: context)
        } catch {
            self.logger.debug("Error thrown by connection handler", metadata: ["error": "\(error)"])
        }
    }

    /// Drives the request loop on a HTTP/3 connection by iterating the stream channels and handling each stream
    /// concurrently.
    ///
    /// - Note: Stream iteration errors are logged but do not propagate to the caller.
    func handleHTTP3Connection<Handler: HTTPServerRequestHandler>(
        connection: HTTP3ServerConnection<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
            NIOQUIC.QUICStreamCreator
        >,
        handler: Handler,
        context: ConnectionContext
    ) async
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        await withDiscardingTaskGroup { streamGroup in
            for await streamChannel in connection.inboundStreams {
                streamGroup.addTask {
                    await self.handleStreamChannel(channel: streamChannel, handler: handler, context: context)
                }
            }
        }
    }

    /// Creates and binds a QUIC channel for each of the provided bind targets, and returns every bound channel
    /// alongside the associated HTTP/3 connection multiplexer.
    func setupHTTP3ServerChannels(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget],
        http3Configuration: NIOHTTPServerConfiguration.HTTP3,
        authenticationConfiguration: NIOQUIC.AuthenticationConfiguration,
        authenticator: NIOQUIC.Authenticator?
    ) async throws -> [(
        quicChannel: any Channel,
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
            NIOQUIC.QUICStreamCreator
        >
    )] {
        let bootstrap = DatagramBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        var serverChannels = [
            (
                any Channel,
                HTTP3ServerConnectionMultiplexer<
                    NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, NIOQUIC.QUICStreamCreator
                >
            )
        ]()
        do {
            for bindTarget in bindTargets {
                switch bindTarget.backing {
                case .hostAndPort(let host, let port):
                    let (quicChannel, multiplexer) = try await bootstrap.bind(host: host, port: port) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try self.setupQUICChannel(
                                channel: channel,
                                http3Configuration: http3Configuration,
                                authenticationConfiguration: authenticationConfiguration,
                                authenticator: authenticator
                            )
                        }
                    }

                    serverChannels.append((quicChannel, multiplexer))
                }
            }
        } catch {
            // A later bind failed: close any channels that are already bound to avoid leaking sockets.
            for (serverChannel, _) in serverChannels {
                try? await serverChannel.close()
            }
            throw error
        }

        return serverChannels
    }

    /// Installs the QUIC handler on a bound datagram channel and returns the channel alongside the connection
    /// multiplexer.
    func setupQUICChannel(
        channel: any Channel,
        http3Configuration: NIOHTTPServerConfiguration.HTTP3,
        authenticationConfiguration: NIOQUIC.AuthenticationConfiguration,
        authenticator: NIOQUIC.Authenticator?
    ) throws -> (
        quicChannel: any Channel,
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, NIOQUIC.QUICStreamCreator
        >
    ) {
        let connectionMultiplexer = HTTP3ServerConnectionMultiplexer<
            NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
            NIOQUIC.QUICStreamCreator
        >()

        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: .init(
                http3Configuration.quicConfiguration,
                authenticationConfiguration: authenticationConfiguration
            ),
            // TODO: mTLS is not yet supported by NIOQUIC so we don't specify a value for `asyncVerifier`.
            asyncVerifier: nil,
            authenticator: authenticator,
            logger: self.logger,
            inboundConnectionInitializer: { connectionChannel, streamCreator in
                connectionChannel.eventLoop.makeCompletedFuture {
                    let connection = try self.setupHTTP3Connection(
                        http3Configuration: http3Configuration,
                        connectionChannel: connectionChannel,
                        streamCreator: streamCreator
                    )
                    connectionMultiplexer.yield(connection: connection)
                }
            },
            inboundStreamInitializer: { streamChannel in
                streamChannel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>.self)
                    .flatMap { http3Handler in
                        http3Handler.inboundStreamReceived(streamChannel)
                    }
            },
            noMoreConnections: {
                connectionMultiplexer.finish()
            }
        )

        try channel.pipeline.syncOperations.addHandler(quicHandler)

        return (channel, connectionMultiplexer)
    }

    /// Sets up an `HTTP3ConnectionHandler` and adds it to the connection channel pipeline.
    func setupHTTP3Connection(
        http3Configuration: NIOHTTPServerConfiguration.HTTP3,
        connectionChannel: any Channel,
        streamCreator: NIOQUIC.QUICStreamCreator,
    ) throws -> HTTP3ServerConnection<
        NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        NIOQUIC.QUICStreamCreator
    > {
        let loopBoundHandler = NIOLoopBoundBox<HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>?>(
            nil,
            eventLoop: connectionChannel.eventLoop
        )

        let connection = HTTP3ServerConnection(connectionHandler: loopBoundHandler) { streamInitializerParameters in
            let streamChannel = streamInitializerParameters.channel

            return streamChannel.eventLoop.makeCompletedFuture {
                try self.setupHTTP3Stream(streamChannel: streamChannel)
            }
        }

        var h3ServerConfig = HTTP3ServerConfiguration(http3Configuration)
        h3ServerConfig.rttProvider = {
            guard let syncOptions = connectionChannel.syncOptions else {
                // We should never reach this case; connection channels are `ChildChannel`s and
                // `ChildChannel` implements `syncOptions`.
                preconditionFailure("The connection channel does not have syncOptions set.")
            }

            guard let rtt = try? syncOptions.getOption(.rttEstimate) else {
                // Use the fallback RTT if there is an error obtaining the RTT estimate channel option.
                return NIOHTTPServerConfiguration.HTTP3.fallbackConnectionRTT
            }

            return rtt
        }

        let http3Handler = HTTP3ConnectionHandler.server(
            eventLoop: connectionChannel.eventLoop,
            configuration: h3ServerConfig,
            settings: .init(http3Configuration.connectionSettings),
            streamCreator: streamCreator,
            logger: self.logger,
            connection: connection
        )
        loopBoundHandler.value = http3Handler
        try connectionChannel.pipeline.syncOperations.addHandler(http3Handler)

        return connection
    }

    /// Configures the pipeline for an inbound HTTP/3 stream channel and wraps it in a `NIOAsyncChannel`.
    func setupHTTP3Stream(streamChannel: any Channel) throws -> NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart> {
        try streamChannel.pipeline.syncOperations.addReadTimeoutHandlers(
            self.configuration.connectionTimeouts,
            expectMultipleRequests: false
        )

        return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
            wrappingChannelSynchronously: streamChannel,
            configuration: .init(
                backPressureStrategy: .init(self.configuration.backpressureStrategy),
                isOutboundHalfClosureEnabled: true
            )
        )
    }
}
#endif  // HTTP3
