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

import BasicContainers
import HTTPAPIs
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTPTypes
import NIOPosix
import NIOQUIC
import NIOSSL
import Testing
import X509

@testable import NIOHTTPServer

extension NIOAsyncTestingChannel {
    /// Forwards all of our outbound writes to `other` and vice-versa.
    func glueTo(_ other: NIOAsyncTestingChannel) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            // 1. Forward all `self` writes to `other`
            group.addTask {
                while !Task.isCancelled {
                    do {
                        let ourPart = try await self.waitForOutboundWrite(as: ByteBuffer.self)
                        try await other.writeInbound(ourPart)
                    } catch ChannelError.ioOnClosedChannel {
                        // We only reach here if the channel has closed. `waitForOutboundWrite` uses a continuation
                        // without `withTaskCancellationHandler`, so this error is the only shutdown signal; returning
                        // allows the task group and `glueTo` to complete cleanly.
                        return
                    }
                }
            }

            // 2. Forward all `other` writes to `self`
            group.addTask {
                while !Task.isCancelled {
                    do {
                        let otherPart = try await other.waitForOutboundWrite(as: ByteBuffer.self)
                        try await self.writeInbound(otherPart)
                    } catch ChannelError.ioOnClosedChannel {
                        // Same reasoning as above: the channel has closed, and returning allows the task group and
                        // `glueTo` to complete cleanly.
                        return
                    }
                }
            }
        }
    }

    /// Returns a `NIOAsyncTestingChannel` that is set to the `active` state.
    static func createActiveChannel() async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()

        let setToActivePromise = channel.eventLoop.makePromise(of: Void.self)
        // The `to` address has no significance here: it is just a random address. We are only interested in making the
        // channel *active*; calling `connect` is the way to achieve that.
        channel.connect(
            to: try .init(ipAddress: "127.0.0.1", port: 8000),
            promise: setToActivePromise
        )
        try await setToActivePromise.futureResult.get()

        return channel
    }
}

extension NIOSSLTrustRoots {
    static func certificates(_ trustRoots: [Certificate]) throws -> NIOSSLTrustRoots {
        .certificates(try trustRoots.map { try NIOSSLCertificate($0) })
    }
}

extension TLSConfiguration {
    /// Creates a client `TLSConfiguration` that trusts `testTrustRoots` and advertises the `applicationProtocol` ALPN
    /// identifier.
    static func makeTestClientConfiguration(
        testTrustRoots: NIOSSLTrustRoots,
        applicationProtocol: String
    ) throws -> TLSConfiguration {
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = testTrustRoots
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = [applicationProtocol]

        return clientTLSConfig
    }

    /// Like ``makeTestClientConfiguration``, but with mTLS.
    @available(anyAppleOS 26.0, *)
    static func makeTestClientMTLSConfiguration(
        testTrustRoots: NIOSSLTrustRoots,
        clientChain: ChainPrivateKeyPair,
        applicationProtocol: String
    ) throws -> TLSConfiguration {
        var mTLSConfig = try TLSConfiguration.makeTestClientConfiguration(
            testTrustRoots: testTrustRoots,
            applicationProtocol: applicationProtocol
        )
        mTLSConfig.certificateChain = [try NIOSSLCertificateSource(clientChain.leaf)]
        mTLSConfig.privateKey = .privateKey(try .init(clientChain.privateKey))

        return mTLSConfig
    }
}

#if HTTP3
@available(anyAppleOS 26.0, *)
extension QUICConfiguration {
    /// Creates a client QUIC configuration.
    ///
    /// - Parameter caPath: The filepath of the client's trusted roots.
    static func makeClientQUICConfig(caPath: String?) -> QUICConfiguration {
        QUICConfiguration.client(
            verificationConfiguration: .x509Certificates(trustRootsFilePath: caPath),
            applicationProtocols: [NIOHTTPServer.HTTPVersion.http3.alpnIdentifier]
        )
    }
}
#endif

@available(anyAppleOS 26.0, *)
struct TestHelpers {
    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with the first
    /// listening address, then cancels the server task.
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestContext,
            NIOHTTPServer.Reader,
            NIOHTTPServer.ResponseSender
        >,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await self.withServer(server: server, serverHandler: serverHandler) { addresses in
            let address = try #require(addresses.first)
            try await body(address)
        }
    }

    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with the first
    /// listening address, then cancels the server task.
    static func withServer<Handler: NIOHTTPServerConnectionHandler>(
        server: NIOHTTPServer,
        connectionHandler: Handler,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await self.withServer(server: server, connectionHandler: connectionHandler) { addresses in
            let address = try #require(addresses.first)
            try await body(address)
        }
    }

    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with all listening
    /// addresses, then cancels the server task.
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestContext,
            NIOHTTPServer.Reader,
            NIOHTTPServer.ResponseSender
        >,
        body: ([NIOHTTPServer.SocketAddress]) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve(handler: serverHandler)
            }

            let listeningAddresses = try await server.listeningAddresses

            try await body(listeningAddresses)

            group.cancelAll()
        }
    }

    /// Starts `server` with `connectionHandler`, waits for it to begin listening, runs `body` with all listening
    /// addresses, then cancels the server task.
    static func withServer<Handler: NIOHTTPServerConnectionHandler>(
        server: NIOHTTPServer,
        connectionHandler: Handler,
        body: ([NIOHTTPServer.SocketAddress]) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.serve(connectionHandler: connectionHandler)
            }

            let listeningAddresses = try await server.listeningAddresses

            try await body(listeningAddresses)

            group.cancelAll()
        }
    }

    /// The information needed to establish a test client connection to a ``NIOHTTPServer``.
    struct ClientConfiguration {
        let logger: Logger
        let httpVersion: NIOHTTPServer.HTTPVersion
        let trustRootsPEMPath: String?
        var clientChain: ChainPrivateKeyPair? = nil
    }

    /// Starts `server` with `serverHandler`, establishes a client connection described by `clientConfiguration`,
    /// then runs `body` with the server's listening address and the resulting ``TestClientConnection``.
    ///
    /// The client connection is closed and the server task is cancelled when `body` returns.
    static func withClientServerConnection(
        clientConfiguration: ClientConfiguration,
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestContext,
            NIOHTTPServer.Reader,
            NIOHTTPServer.ResponseSender
        >,
        body: (NIOHTTPServer.SocketAddress, TestClientConnection) async throws -> Void
    ) async throws {
        try await Self.withServer(server: server, serverHandler: serverHandler) { serverAddress in
            try await TestClientConnection.withConnection(
                configuration: clientConfiguration,
                serverAddress: serverAddress
            ) { clientConnection in
                try await body(serverAddress, clientConnection)
            }
        }
    }

    /// Starts `server` with `connectionHandler`, establishes a client connection described by `clientConfiguration`,
    /// then runs `body` with the server's listening address and the resulting ``TestClientConnection``.
    ///
    /// The client connection is closed and the server task is cancelled when `body` returns.
    static func withClientServerConnection<Handler: NIOHTTPServerConnectionHandler>(
        clientConfiguration: ClientConfiguration,
        server: NIOHTTPServer,
        connectionHandler: Handler,
        body: (NIOHTTPServer.SocketAddress, TestClientConnection) async throws -> Void
    ) async throws {
        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            try await TestClientConnection.withConnection(
                configuration: clientConfiguration,
                serverAddress: serverAddress
            ) { clientConnection in
                try await body(serverAddress, clientConnection)
            }
        }
    }

    /// Starts `server` with `serverHandler`, establishes a client connection described by `clientConfiguration`,
    /// opens a request stream on it, then runs `body` with the server's listening address and the request stream's
    /// inbound and outbound halves.
    ///
    /// The request stream, the client connection, and the server task are all torn down when `body` returns.
    static func withClientServerRequestChannel(
        clientConfiguration: ClientConfiguration,
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestContext,
            NIOHTTPServer.Reader,
            NIOHTTPServer.ResponseSender
        >,
        body: (
            NIOHTTPServer.SocketAddress,
            NIOAsyncChannelInboundStream<HTTPResponsePart>,
            NIOAsyncChannelOutboundWriter<HTTPRequestPart>
        ) async throws -> Void
    ) async throws {
        try await Self.withServer(server: server, serverHandler: serverHandler) { serverAddress in
            try await TestClientConnection.withConnectedRequestChannel(
                configuration: clientConfiguration,
                serverAddress: serverAddress
            ) { inbound, outbound in
                try await body(serverAddress, inbound, outbound)
            }
        }
    }

    /// Starts `server` with `connectionHandler`, establishes a client connection described by `clientConfiguration`,
    /// opens a request stream on it, then runs `body` with the server's listening address and the request stream's
    /// inbound and outbound halves.
    ///
    /// The request stream, the client connection, and the server task are all torn down when `body` returns.
    static func withClientServerRequestChannel<Handler: NIOHTTPServerConnectionHandler>(
        clientConfiguration: ClientConfiguration,
        server: NIOHTTPServer,
        connectionHandler: Handler,
        body: (
            NIOHTTPServer.SocketAddress,
            NIOAsyncChannelInboundStream<HTTPResponsePart>,
            NIOAsyncChannelOutboundWriter<HTTPRequestPart>
        ) async throws -> Void
    ) async throws {
        try await Self.withServer(server: server, connectionHandler: connectionHandler) { serverAddress in
            try await TestClientConnection.withConnectedRequestChannel(
                configuration: clientConfiguration,
                serverAddress: serverAddress
            ) { inbound, outbound in
                try await body(serverAddress, inbound, outbound)
            }
        }
    }

    /// Reads from `responseStream` and asserts each part matches the expected head, body, and trailers in order.
    static func validateResponse(
        _ responseStream: NIOAsyncChannelInboundStream<HTTPResponsePart>,
        expectedHead: [HTTPResponse],
        expectedBody: [ByteBuffer],
        expectedTrailers: HTTPFields? = nil,
        expectStreamEnd: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        var responseIterator = responseStream.makeAsyncIterator()

        for expectedHeadPart in expectedHead {
            let headResponsePart = try await responseIterator.next()
            try #require(headResponsePart == .head(expectedHeadPart), sourceLocation: sourceLocation)
        }

        for expectedBodyBuffer in expectedBody {
            let bodyResponsePart = try await responseIterator.next()
            try #require(bodyResponsePart == .body(expectedBodyBuffer), sourceLocation: sourceLocation)
        }

        let endResponsePart = try await responseIterator.next()
        try #require(endResponsePart == .end(expectedTrailers), sourceLocation: sourceLocation)

        if expectStreamEnd {
            try #require(
                try await responseIterator.next() == nil,
                "Received another response part when the response stream should have finished.",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Reads the full request body and trailers from `reader`, then sends a `200 OK` response echoing them back.
    static func echoResponse(
        readUpTo limit: Int,
        reader: consuming NIOHTTPServer.Reader,
        sender: consuming NIOHTTPServer.ResponseSender
    ) async throws {
        var buffer = UniqueArray<UInt8>()
        // Reserve one extra byte beyond the limit: `collect(into:)` stops as soon as the buffer's
        // free capacity is exhausted, so an exact fit would drop the trailing fields delivered in
        // the terminal chunk.
        buffer.reserveCapacity(limit + 1)
        let trailer = try await reader.collect(into: &buffer)
        try await sender.sendAndFinish(.init(status: .ok), buffer: &buffer, trailer: trailer)
    }
}

@available(anyAppleOS 26.0, *)
extension TestHelpers {
    static func makeSecureUpgradeServerConfiguration(
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion> = [.http1_1, .http2],
        concurrentListeners: Int = 1
    ) throws -> (NIOHTTPServerConfiguration, String) {
        let (leafPath, caPath, privateKeyPath) = try TestCA.makeSelfSignedChainWithSAN().writeToDisk()

        let bindTargets = (0..<concurrentListeners).map { _ in
            NIOHTTPServerConfiguration.BindTarget.hostAndPort(host: "127.0.0.1", port: 0)
        }

        let configuration = try NIOHTTPServerConfiguration(
            bindTargets: bindTargets,
            supportedHTTPVersions: supportedHTTPVersions,
            transportSecurity: .tls(
                credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: privateKeyPath))
            )
        )

        return (configuration, caPath)
    }

    static func makeServerAndClientConfiguration(
        for version: NIOHTTPServer.HTTPVersion,
        clientLogger: Logger,
        serverLogger: Logger,
        concurrentListeners: Int = 1,
        serverConfigurationOverride: ((inout NIOHTTPServerConfiguration) -> Void)? = nil
    ) throws -> (NIOHTTPServer, ClientConfiguration) {
        let bindTargets = (0..<concurrentListeners).map { _ in
            NIOHTTPServerConfiguration.BindTarget.hostAndPort(host: "127.0.0.1", port: 0)
        }

        var serverConfiguration: NIOHTTPServerConfiguration
        let trustRootsPEMPath: String?

        if version == .plaintextHTTP1_1 {
            serverConfiguration = try .init(
                bindTargets: bindTargets,
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
            serverConfigurationOverride?(&serverConfiguration)

            trustRootsPEMPath = nil
        } else {
            (serverConfiguration, trustRootsPEMPath) = try self.makeSecureUpgradeServerConfiguration(
                supportedHTTPVersions: [.init(version)],
                concurrentListeners: concurrentListeners
            )
            serverConfigurationOverride?(&serverConfiguration)
        }

        let server = NIOHTTPServer(logger: serverLogger, configuration: serverConfiguration)
        let clientConfiguration = ClientConfiguration(
            logger: clientLogger,
            httpVersion: version,
            trustRootsPEMPath: trustRootsPEMPath
        )

        return (server, clientConfiguration)
    }

    static func makeMTLSServerAndClientConfiguration(
        for version: NIOHTTPServer.HTTPVersion,
        clientLogger: Logger,
        serverLogger: Logger,
        serverTrustConfiguration: NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration,
        concurrentListeners: Int = 1
    ) throws -> (NIOHTTPServer, ClientConfiguration) {
        guard version != .plaintextHTTP1_1 else {
            throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity
        }
        #if HTTP3
        guard version != .http3 else {
            throw NIOHTTPServerConfigurationError.mTLSNotCurrentlySupportedOverHTTP3
        }
        #endif

        let serverChain = try TestCA.makeSelfSignedChainWithSAN()
        let clientChain = try TestCA.makeSelfSignedChain()
        let (serverLeafPath, serverCAPath, serverKeyPath) = try serverChain.writeToDisk()

        let bindTargets = (0..<concurrentListeners).map { _ in
            NIOHTTPServerConfiguration.BindTarget.hostAndPort(host: "127.0.0.1", port: 0)
        }

        let server = NIOHTTPServer(
            logger: serverLogger,
            configuration: try .init(
                bindTargets: bindTargets,
                supportedHTTPVersions: [.init(version)],
                transportSecurity: .mTLS(
                    credentials: .x509(.pemFile(certificateChainPath: serverLeafPath, privateKeyPath: serverKeyPath)),
                    trustConfiguration: serverTrustConfiguration
                )
            )
        )

        let clientConfiguration = ClientConfiguration(
            logger: clientLogger,
            httpVersion: version,
            trustRootsPEMPath: serverCAPath,
            clientChain: clientChain
        )

        return (server, clientConfiguration)
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPFields {
    /// Returns the body encoding header fields required for the given HTTP version.
    static func makeBodyEncodingHeaders(for httpVersion: NIOHTTPServer.HTTPVersion) -> HTTPFields {
        switch httpVersion {
        case .plaintextHTTP1_1, .http1_1:
            [.transferEncoding: "chunked"]

        case .http2:
            [:]

        #if HTTP3
        case .http3:
            [:]
        #endif
        }
    }
}

@available(anyAppleOS 26.0, *)
extension String {
    static func makeScheme(for httpVersion: NIOHTTPServer.HTTPVersion) -> String {
        switch httpVersion {
        case .plaintextHTTP1_1:
            "http"

        case .http1_1, .http2:
            "https"

        #if HTTP3
        case .http3:
            "https"
        #endif
        }
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPRequest {
    /// Creates an ``HTTPRequest`` with the appropriate headers for the given `httpVersion`.
    static func makeRequest(
        method: HTTPRequest.Method,
        authority: String = "test",
        path: String = "/",
        for httpVersion: NIOHTTPServer.HTTPVersion
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            scheme: .makeScheme(for: httpVersion),
            authority: authority,
            path: path,
            headerFields: .makeBodyEncodingHeaders(for: httpVersion)
        )
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPResponse {
    /// Creates an ``HTTPResponse`` with the given status and the appropriate headers for the given `httpVersion`.
    static func makeResponse(
        status: HTTPResponse.Status,
        for httpVersion: NIOHTTPServer.HTTPVersion
    ) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headerFields: .makeBodyEncodingHeaders(for: httpVersion)
        )
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPRequestPart {
    static func testHead(
        method: HTTPRequest.Method,
        authority: String = "test",
        path: String = "/",
        for version: NIOHTTPServer.HTTPVersion
    ) -> HTTPRequestPart {
        .head(HTTPRequest(method: method, scheme: .makeScheme(for: version), authority: authority, path: path))
    }

    static let testBody = HTTPRequestPart.body(.testData)

    static let testEnd = HTTPRequestPart.end(.testTrailer)
}

extension ByteBuffer {
    static let testData = ByteBuffer(repeating: 5, count: 100)
}

extension HTTPFields {
    static let testTrailer: HTTPFields = [.trailer: "test_trailer"]
}
