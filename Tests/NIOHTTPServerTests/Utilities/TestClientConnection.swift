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

import HTTPTypes
import Logging
import NIOCore
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import Testing

@testable import NIOHTTPServer

#if HTTP3
import HTTP3
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOQUIC
import NIOQUICHelpers
#endif

/// A testing utility that wraps an established HTTP/1.1, HTTP/2, or HTTP/3 client connection and provides an opaque
/// interface for creating request streams.
@available(anyAppleOS 26.0, *)
struct TestClientConnection {
    enum ConnectionProtocol {
        case http1(connectionChannel: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>)

        case http2(
            connectionChannel: any Channel,
            streamMultiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
        )

        #if HTTP3
        case http3(
            quicChannel: any Channel,
            connectionChannel: any Channel,
            connection: HTTP3ClientConnection<Never, NIOQUIC.QUICStreamCreator>
        )
        #endif
    }

    let connectionProtocol: ConnectionProtocol

    /// Asserts the negotiated protocol matches `expectedHTTPVersion`, then returns a request stream.
    func makeRequestChannel(
        expectedHTTPVersion: NIOHTTPServer.HTTPVersion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        switch self.connectionProtocol {
        case .http1(let http1Channel):
            try #require(
                expectedHTTPVersion == .plaintextHTTP1_1 || expectedHTTPVersion == .http1_1,
                "Unexpectedly established an HTTP/1 connection.",
                sourceLocation: sourceLocation
            )
            return http1Channel

        case .http2(_, let streamMultiplexer):
            try #require(
                expectedHTTPVersion == .http2,
                "Unexpectedly established an HTTP/2 connection.",
                sourceLocation: sourceLocation
            )
            return try await streamMultiplexer.makeRequestStream()

        #if HTTP3
        case .http3(_, _, let http3Connection):
            try #require(
                expectedHTTPVersion == .http3,
                "Unexpectedly established an HTTP/3 connection.",
                sourceLocation: sourceLocation
            )
            return try await http3Connection.makeRequestStream()
        #endif
        }
    }

    /// Asserts the connection is HTTP/2, then opens a stream exposing raw `HTTP2Frame.FramePayload`s so a test can
    /// observe frames the HTTP client codec would drop (such as `RST_STREAM`).
    func makeRawHTTP2RequestStream(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload> {
        guard case .http2(_, let streamMultiplexer) = self.connectionProtocol else {
            Issue.record("Expected an HTTP/2 connection.", sourceLocation: sourceLocation)
            throw TestError.invalidClientConfiguration
        }
        return try await streamMultiplexer.makeRawRequestStream()
    }

    /// Closes the underlying connection.
    func close() async throws {
        switch self.connectionProtocol {
        case .http1(let asyncChannel):
            do {
                try await asyncChannel.channel.close()
            } catch ChannelError.alreadyClosed {
                ()
            }

        case .http2(let channel, _):
            do {
                try await channel.close()
            } catch ChannelError.alreadyClosed {
                ()
            }

        #if HTTP3
        case .http3(let quicChannel, let connectionChannel, _):
            do {
                try await quicChannel.close()
                try await connectionChannel.close()
            } catch ChannelError.alreadyClosed {
                ()
            }
        #endif
        }
    }
}

@available(anyAppleOS 26.0, *)
extension TestClientConnection {
    init(
        alpnNegotiationResult: NIONegotiatedHTTPVersion<
            NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>,
            NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
        >,
        connectionChannel: any Channel
    ) async throws {
        switch alpnNegotiationResult {
        case .http1_1(let http1AsyncChannel):
            self.init(connectionProtocol: .http1(connectionChannel: http1AsyncChannel))

        case .http2(let http2StreamMultiplexer):
            self.init(
                connectionProtocol: .http2(
                    connectionChannel: connectionChannel,
                    streamMultiplexer: http2StreamMultiplexer
                )
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension TestClientConnection {
    /// The information needed to establish a test client connection to a ``NIOHTTPServer``.
    struct Configuration {
        var logger: Logger
        var httpVersion: NIOHTTPServer.HTTPVersion
        var trustRootsPEMPath: String?
        var chain: ChainPrivateKeyPair? = nil

        #if HTTP3
        /// The client's QUIC configuration. Only applies when ``httpVersion`` is `.http3`.
        var quicConfiguration: QUICConfiguration? = nil

        /// The HTTP/3 settings the client sends to the server. Only applies when ``httpVersion`` is `.http3`.
        var http3ConnectionSettings = HTTP3Settings()
        #endif
    }

    /// Establishes a client connection to `serverAddress` based on the provided `httpVersion`, runs `body` with the
    /// resulting ``TestClientConnection``. The stream and the underlying connection are closed when `body` returns.
    static func withConnection(
        configuration: Configuration,
        serverAddress: NIOHTTPServer.SocketAddress,
        body: (TestClientConnection) async throws -> Void
    ) async throws {
        let connection: TestClientConnection

        switch (configuration.httpVersion, configuration.trustRootsPEMPath) {
        case (.plaintextHTTP1_1, .none):
            connection = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestHTTP1Server(at: serverAddress)

        case (.http1_1, .some(let trustRootsPEMPath)), (.http2, .some(let trustRootsPEMPath)):
            let tlsConfiguration =
                if let clientChain = configuration.chain {
                    try TLSConfiguration.makeTestClientMTLSConfiguration(
                        testTrustRoots: .file(trustRootsPEMPath),
                        clientChain: clientChain,
                        applicationProtocol: configuration.httpVersion.alpnIdentifier
                    )
                } else {
                    try TLSConfiguration.makeTestClientConfiguration(
                        testTrustRoots: .file(trustRootsPEMPath),
                        applicationProtocol: configuration.httpVersion.alpnIdentifier
                    )
                }

            connection = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .connectToTestSecureUpgradeHTTPServer(at: serverAddress, tlsConfig: tlsConfiguration)

        #if HTTP3
        case (.http3, .some(let trustRootsPEMPath)):
            let (quicChannel, connectionCreator) =
                try await DatagramBootstrap(group: .singletonMultiThreadedEventLoopGroup).setupTestHTTP3Client(
                    logger: configuration.logger,
                    trustRootsPath: trustRootsPEMPath,
                    quicConfiguration: configuration.quicConfiguration
                        ?? .makeClientQUICConfig(caPath: trustRootsPEMPath),
                    http3ConnectionSettings: configuration.http3ConnectionSettings
                )

            let multiplexer = HTTP3ClientConnectionMultiplexer<
                TestHTTP3SingleConnectionCreator, NIOQUIC.QUICStreamCreator
            >(
                eventLoop: quicChannel.eventLoop,
                createNewConnection: connectionCreator
            )

            let h3Connection = try await multiplexer.concurrencyView.createConnection(
                serverName: "127.0.0.1",
                remoteAddress: .init(ipAddress: serverAddress.host, port: serverAddress.port),
                inboundPushStreamInitializer: { _ in fatalError("Push streams not supported") }
            )

            let connectionChannel = try await quicChannel.eventLoop.flatSubmit {
                connectionCreator.value.connectionChannelPromise.futureResult
            }.get()

            connection = TestClientConnection(
                connectionProtocol: .http3(
                    quicChannel: quicChannel,
                    connectionChannel: connectionChannel,
                    connection: h3Connection
                )
            )
        #endif

        default:
            throw TestError.invalidClientConfiguration
        }

        do {
            try await body(connection)
            try await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    /// Establishes a client connection to `serverAddress`, opens a request stream on it, and runs the `body` closure.
    /// The stream and the underlying connection are closed when `body` returns.
    static func withConnectedRequestChannel(
        configuration: Configuration,
        serverAddress: NIOHTTPServer.SocketAddress,
        body: (
            NIOAsyncChannelInboundStream<HTTPResponsePart>,
            NIOAsyncChannelOutboundWriter<HTTPRequestPart>
        ) async throws -> Void
    ) async throws {
        try await Self.withConnection(configuration: configuration, serverAddress: serverAddress) { connection in
            try await connection.makeRequestChannel(expectedHTTPVersion: configuration.httpVersion)
                .executeThenClose(body)
        }
    }

    #if HTTP3 && UnstableHTTPDatagrams
    /// Establishes a client connection to `serverAddress`, opens a request stream on it, and runs the `body` closure
    /// with the HTTP/3 connection channel (for reading/writing datagrams) and the request stream channel. The stream
    /// and the underlying connection are closed when `body` returns.
    static func withConnectedHTTP3ConnectionAndRequestChannel(
        configuration: Configuration,
        serverAddress: NIOHTTPServer.SocketAddress,
        body: (
            _ streamID: QUICStreamID,
            _ connectionChannel: NIOAsyncChannel<HTTP3Datagram, HTTP3Datagram>,
            _ streamChannel: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>
        ) async throws -> Void
    ) async throws {
        try await Self.withConnection(configuration: configuration, serverAddress: serverAddress) { connection in
            guard case .http3(_, let connectionChannel, let connectionHandle) = connection.connectionProtocol else {
                Issue.record("Expected an HTTP/3 connection")
                return
            }

            // Wrap the connection channel in an async channel so we can conveniently read/write datagrams.
            let asyncConnectionChannel = try await connectionChannel.eventLoop.submit {
                try NIOAsyncChannel<HTTP3Datagram, HTTP3Datagram>(wrappingChannelSynchronously: connectionChannel)
            }.get()

            let streamChannel = try await connectionHandle.makeRequestStream()
            let streamID = try await streamChannel.channel.getOption(.quicStreamID).get()

            try await body(
                QUICStreamID(rawValue: streamID),
                asyncConnectionChannel,
                streamChannel
            )
        }
    }
    #endif  // HTTP3 && UnstableHTTPDatagrams
}

extension NIOHTTP2Handler.AsyncStreamMultiplexer<Channel> {
    /// A wrapper over `openStream(_:)` that first initializes the stream channel with the
    /// `HTTP2FramePayloadToHTTPClientCodec` channel handler, and wraps it in a `NIOAsyncChannel` (with outbound half
    /// closure enabled).
    func makeRequestStream() async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        try await self.openStream { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTPClientCodec())
                return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }
    }

    /// Opens a stream without the `HTTP2FramePayloadToHTTPClientCodec`, exposing raw `HTTP2Frame.FramePayload`s.
    ///
    /// Unlike ``makeRequestStream()``, this lets a test observe frames the codec would otherwise drop, such as
    /// `RST_STREAM`.
    func makeRawRequestStream() async throws -> NIOAsyncChannel<
        HTTP2Frame.FramePayload, HTTP2Frame.FramePayload
    > {
        try await self.openStream { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTP2Frame.FramePayload, HTTP2Frame.FramePayload>(
                    wrappingChannelSynchronously: channel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }
    }
}
