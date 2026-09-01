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
    /// An inbound HTTP/3 request stream.
    struct HTTP3Stream: Sendable {
        /// The stream channel.
        var channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>

        #if UnstableHTTPDatagrams
        /// The unreliable datagram stream future. `nil` if HTTP datagram support was not enabled by the server.
        var datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>?
        #endif
    }

    func serveHTTP3<Handler: NIOHTTPServerConnectionHandler>(
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<HTTP3Stream, NIOQUIC.QUICStreamCreator>,
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
        _ http3Connection: HTTP3ServerConnection<HTTP3Stream, NIOQUIC.QUICStreamCreator>,
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
            self.logger.debug(
                "Error thrown by connection handler",
                error: error
            )
        }
    }

    /// Drives the request loop on a HTTP/3 connection by iterating the stream channels and handling each stream
    /// concurrently.
    ///
    /// - Note: Stream iteration errors are logged but do not propagate to the caller.
    func handleHTTP3Connection<Handler: HTTPServerRequestHandler>(
        connection: HTTP3ServerConnection<HTTP3Stream, NIOQUIC.QUICStreamCreator>,
        handler: Handler,
        context: ConnectionContext
    ) async
    where
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.ResponseSender == ResponseSender
    {
        await withDiscardingTaskGroup { streamGroup in
            for await stream in connection.inboundStreams {
                streamGroup.addTask {
                    await stream.channel.withRequest(
                        logger: self.logger,
                        context: context
                    ) { request, context, inboundIterator, outbound in
                        #if UnstableHTTPDatagrams
                        if let datagramStreamFuture = stream.datagramStreamFuture {
                            await self.invokeDatagramsEnabledHandler(
                                request: request,
                                requestContext: context,
                                inboundIterator: inboundIterator,
                                outbound: outbound,
                                datagramStreamFuture: datagramStreamFuture,
                                handler: handler
                            )
                            return
                        }
                        #endif  // UnstableHTTPDatagrams

                        _ = await self.invokeHandler(
                            request: request,
                            requestContext: context,
                            inboundIterator: inboundIterator,
                            outbound: outbound,
                            handler: handler
                        )
                    }
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
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<HTTP3Stream, NIOQUIC.QUICStreamCreator>
    )] {
        let bootstrap = DatagramBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        var serverChannels = [(any Channel, HTTP3ServerConnectionMultiplexer<HTTP3Stream, NIOQUIC.QUICStreamCreator>)]()
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
        connectionMultiplexer: HTTP3ServerConnectionMultiplexer<HTTP3Stream, NIOQUIC.QUICStreamCreator>
    ) {
        let connectionMultiplexer = HTTP3ServerConnectionMultiplexer<HTTP3Stream, NIOQUIC.QUICStreamCreator>()

        #if UnstableHTTPDatagrams
        let quicConfiguration = QUICConfiguration(
            http3Configuration.quicConfiguration,
            authenticationConfiguration: authenticationConfiguration,
            datagramConfiguration: http3Configuration.datagramConfiguration
        )
        #else
        let quicConfiguration = QUICConfiguration(
            http3Configuration.quicConfiguration,
            authenticationConfiguration: authenticationConfiguration
        )
        #endif

        let quicHandler = QUICHandler(
            channel: channel,
            quicConfiguration: quicConfiguration,
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
    ) throws -> HTTP3ServerConnection<HTTP3Stream, NIOQUIC.QUICStreamCreator> {
        let connectionEventLoop = connectionChannel.eventLoop
        let loopBoundHandler =
            NIOLoopBoundBox<HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>?>(nil, eventLoop: connectionEventLoop)

        #if UnstableHTTPDatagrams
        let datagramsNegotiatedPromise =
            http3Configuration.datagramConfiguration.map { _ in connectionEventLoop.makePromise(of: Void.self) }
        let connectionManager = HTTP3ConnectionManager(
            eventLoop: connectionEventLoop,
            logger: self.logger,
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        let loopBoundManager = NIOLoopBound(connectionManager, eventLoop: connectionChannel.eventLoop)
        #else
        let connectionManager = HTTP3ConnectionManager(eventLoop: connectionEventLoop, logger: self.logger)
        #endif

        let connection = HTTP3ServerConnection(connectionHandler: loopBoundHandler) { streamInitializerParameters in
            let streamChannel = streamInitializerParameters.channel

            return streamChannel.eventLoop.makeCompletedFuture {
                #if UnstableHTTPDatagrams
                guard let datagramConfiguration = http3Configuration.datagramConfiguration,
                    let negotiationPromise = datagramsNegotiatedPromise
                else {
                    return HTTP3Stream(channel: try self.setupHTTP3Stream(streamChannel: streamChannel))
                }

                // Create the unreliable stream only when we know the peer supports receiving datagrams.
                let datagramStreamFuture = negotiationPromise.futureResult.map { _ in
                    let datagramStream = HTTP3UnreliableDatagramStream(
                        streamID: streamInitializerParameters.streamID,
                        connectionChannel: connectionChannel,
                        maxBufferedDatagrams: datagramConfiguration.maxBufferedStreamDatagrams
                    )
                    loopBoundManager.value.register(datagramStream: datagramStream)

                    return datagramStream
                }

                datagramStreamFuture.and(streamChannel.closeFuture).whenComplete { _ in
                    loopBoundManager.value.deregister(streamID: streamInitializerParameters.streamID)
                }

                return HTTP3Stream(
                    channel: try self.setupHTTP3Stream(streamChannel: streamChannel),
                    datagramStreamFuture: datagramStreamFuture
                )
                #else
                return HTTP3Stream(channel: try self.setupHTTP3Stream(streamChannel: streamChannel))
                #endif
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

        #if UnstableHTTPDatagrams
        let h3Settings = HTTP3Settings(
            http3Configuration.connectionSettings,
            supportsDatagrams: http3Configuration.datagramConfiguration != nil
        )
        #else
        let h3Settings = HTTP3Settings(http3Configuration.connectionSettings)
        #endif

        let http3Handler = HTTP3ConnectionHandler.server(
            eventLoop: connectionChannel.eventLoop,
            configuration: h3ServerConfig,
            settings: h3Settings,
            streamCreator: streamCreator,
            logger: self.logger,
            connection: connection
        )
        loopBoundHandler.value = http3Handler

        #if UnstableHTTPDatagrams
        try connectionChannel.pipeline.syncOperations.addHandlers([http3Handler, loopBoundManager.value])
        #else
        try connectionChannel.pipeline.syncOperations.addHandlers([http3Handler, connectionManager])
        #endif

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
