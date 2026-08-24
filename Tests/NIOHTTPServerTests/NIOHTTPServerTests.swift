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
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOQUIC
import NIOSSL
import SwiftASN1
import Synchronization
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerTests {
    let clientLogger = Logger(label: "NIOHTTPServerTests.client")
    let serverLogger = Logger(label: "NIOHTTPServerTests.server")

    @available(anyAppleOS 26.0, *)
    @Test("Obtain the listening address correctly")
    func testListeningAddress() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 1234),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in },
            body: { serverAddress in
                let address = try #require(serverAddress.ipv4)
                #expect(address.host == "127.0.0.1")
                #expect(address.port == 1234)
            }
        )

        // Now that the server has shut down, try obtaining the listening address. This should result in an error.
        await #expect(throws: ListeningAddressError.serverClosed) {
            try await server.listeningAddresses
        }
    }

    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test(
        "Request-response",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2, .http3]
    )
    #else
    @Test(
        "Request-response",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    #endif
    func testRequestResponse(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await confirmation { responseReceived in
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                    #expect(request == .makeRequest(method: .post, for: httpVersion))

                    let testData = ByteBuffer.testData
                    var collected = UniqueArray<UInt8>()
                    collected.reserveCapacity(testData.readableBytes + 1)
                    let finalElement = try await reader.collect(into: &collected)
                    var buffer = ByteBuffer()
                    buffer.writeBytes(collected.span.bytes)
                    #expect(buffer == testData)
                    #expect(finalElement == .testTrailer)

                    var responseBody = UniqueArray<UInt8>(copying: testData.readableBytesUInt8Span)
                    try await responseWriter.sendAndFinish(
                        .init(status: .ok),
                        buffer: &responseBody,
                        trailer: .testTrailer
                    )
                }
            ) { _, inbound, outbound in
                try await outbound.write(.testHead(method: .post, for: httpVersion))
                try await outbound.write(.testBody)
                try await outbound.write(.testEnd)

                try await TestHelpers.validateResponse(
                    inbound,
                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                    expectedBody: [.testData],
                    expectedTrailers: .testTrailer,
                    expectStreamEnd: httpVersion != .plaintextHTTP1_1 && httpVersion != .http1_1
                )

                responseReceived()
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "mTLS request-response with custom verification callback returning peer certificates",
        arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2]
    )
    func testMTLS(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeMTLSServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger,
            serverTrustConfiguration: .init(
                .customCertificateVerificationCallback { certificates in
                    // Return the peer's certificate chain; this must then be accessible in the request handler.
                    .certificateVerified(.init(.init(uncheckedCertificateChain: certificates)))
                }
            )
        )
        let clientLeaf = try #require(clientConfiguration.clientChain?.leaf)

        try await confirmation { responseReceived in
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                    #expect(request == .makeRequest(method: .post, for: httpVersion))

                    let peerChain = try #require(try await requestContext.peerCertificateChain)
                    #expect(Array(peerChain) == [clientLeaf])

                    let testData = ByteBuffer.testData
                    var collected = UniqueArray<UInt8>()
                    collected.reserveCapacity(testData.readableBytes + 1)
                    let finalElement = try await reader.collect(into: &collected)
                    var buffer = ByteBuffer()
                    buffer.writeBytes(collected.span.bytes)
                    #expect(buffer == testData)
                    #expect(finalElement == .testTrailer)

                    var responseBody = UniqueArray<UInt8>(copying: testData.readableBytesUInt8Span)
                    try await responseWriter.sendAndFinish(
                        .init(status: .ok),
                        buffer: &responseBody,
                        trailer: .testTrailer
                    )
                }
            ) { _, inbound, outbound in
                try await outbound.write(.testHead(method: .post, for: httpVersion))
                try await outbound.write(.testBody)
                try await outbound.write(.testEnd)

                try await TestHelpers.validateResponse(
                    inbound,
                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                    expectedBody: [.testData],
                    expectedTrailers: .testTrailer,
                    expectStreamEnd: httpVersion == .http2
                )

                responseReceived()
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test(
        "Multiple informational response headers",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2, .http3]
    )
    #else
    @Test(
        "Multiple informational response headers",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    #endif
    func testMultipleInformationalResponseHeaders(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await confirmation { responseReceived in
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, _, reader, responseSender in
                    var responseSender = responseSender
                    try await responseSender.sendInformational(.init(status: .continue))
                    try await responseSender.sendInformational(.init(status: .earlyHints))
                    let testData = ByteBuffer.testData
                    var buffer = UniqueArray<UInt8>(copying: testData.readableBytesUInt8Span)
                    try await responseSender.sendAndFinish(.init(status: .ok), buffer: &buffer, trailer: .testTrailer)
                }
            ) { _, inbound, outbound in
                try await outbound.write(.testHead(method: .get, for: httpVersion))
                try await outbound.write(.end(nil))

                try await TestHelpers.validateResponse(
                    inbound,
                    expectedHead: [
                        .init(status: .continue),
                        .init(status: .earlyHints),
                        .makeResponse(status: .ok, for: httpVersion),
                    ],
                    expectedBody: [.testData],
                    expectedTrailers: .testTrailer,
                    expectStreamEnd: httpVersion != .plaintextHTTP1_1 && httpVersion != .http1_1
                )

                responseReceived()
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "Client closes stream without sending end part",
        arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2]
    )
    func testRequestWithoutEndPart(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let requestReadPromise = elg.any().makePromise(of: Void.self)

        try await confirmation { responseReceived in
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseSender in
                    var reader = reader
                    #expect(request == .makeRequest(method: .post, for: httpVersion))

                    // This should fail: the client has closed the stream without sending an end part.
                    let error = try await #require(throws: EitherError<Error, Never>.self) {
                        try await reader.read { _, _ in }
                    }

                    if case .http1_1 = httpVersion {
                        #expect(throws: HTTPParserError.invalidEOFState) { try error.unwrap() }
                    } else if case .http2 = httpVersion {
                        let h2Error = try #require(throws: NIOHTTP2Errors.StreamClosed.self) { try error.unwrap() }
                        #expect(h2Error.errorCode == .cancel)
                    }

                    requestReadPromise.succeed()
                }
            ) { _, inbound, outbound in
                // Only send a request head; finish the stream immediately afterwards.
                try await outbound.write(.testHead(method: .post, for: httpVersion))
                outbound.finish()

                // Wait for the server to handle the (partial) request before closing.
                try await requestReadPromise.futureResult.get()

                responseReceived()
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Bi-directional streaming", arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2])
    func testBidirectionalStreaming(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, requestReader, responseSender in
                #expect(request == .makeRequest(method: .post, for: httpVersion))

                var responseBodyWriter = try await responseSender.send(HTTPResponse(status: .ok))

                var count = 1
                let finalElement = try await requestReader.forEachBuffer { buffer in
                    if buffer.isEmpty { return }

                    var chunk = ByteBuffer()
                    chunk.writeBytes(buffer.span.bytes)
                    #expect(chunk == ByteBuffer(bytes: [UInt8(count)]))
                    count += 1

                    try await responseBodyWriter.write(buffer: &buffer)
                }
                #expect(finalElement == .testTrailer)

                try await responseBodyWriter.finish(trailer: .testTrailer)
            }
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .post, for: httpVersion))
            var responseIterator = inbound.makeAsyncIterator()

            // For HTTP/1.1, the keep-alive handler flushes the response head with
            // `Connection: close` because a body part is written before the request
            // `.end` arrives. HTTP/2 has no equivalent header.
            var expectedHead = HTTPResponse.makeResponse(status: .ok, for: httpVersion)
            if httpVersion == .http1_1 {
                expectedHead.headerFields[.connection] = "close"
            }
            let head = try await responseIterator.next()
            #expect(head == .head(expectedHead))

            for i in 1...5 {
                let body = ByteBuffer(bytes: [UInt8(i)])
                try await outbound.write(.body(body))

                let response = try await responseIterator.next()
                #expect(response == .body(body))
            }

            try await outbound.write(.end(.testTrailer))
            #expect(try await responseIterator.next() == .end(.testTrailer))
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "Multiple serial HTTP/1.1 requests on the same connection",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testMultipleSerialHTTP1Requests(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let requestCount = 3

        try await confirmation(expectedCount: requestCount) { responseReceived in
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                    // Echo the request body back as the response body.
                    try await TestHelpers.echoResponse(readUpTo: 1024, reader: reader, sender: responseWriter)
                }
            ) { _, inbound, outbound in
                var responseIterator = inbound.makeAsyncIterator()

                for i in 1...requestCount {
                    // Send request
                    try await outbound.write(.testHead(method: .post, path: "/\(i)", for: http1Variant))
                    try await outbound.write(.testBody)
                    try await outbound.write(.end(nil))

                    // Read response
                    let headPart = try await responseIterator.next()
                    #expect(headPart == .head(.makeResponse(status: .ok, for: http1Variant)))

                    let bodyPart = try await responseIterator.next()
                    #expect(bodyPart == .body(.testData))

                    let endPart = try await responseIterator.next()
                    #expect(endPart == .end(nil))

                    responseReceived()
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test(
        "Multiple concurrent connections",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2, .http3]
    )
    #else
    @Test(
        "Multiple concurrent connections",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    #endif
    func testMultipleConcurrentConnections(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // We will create 10 connections and send a request from each connection. The server will fulfill the
        // `allOtherRequestsCanProceedPromise` promise after seeing the 10th request. All other requests will be blocked
        // waiting for that promise.
        let numConnections = 10
        let requestCounter = Mutex(0)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let allOtherRequestsCanProceedPromise = elg.any().makePromise(of: Void.self)

        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await TestHelpers.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                    let requestNumber = requestCounter.withLock { counter in
                        counter += 1
                        return counter
                    }

                    if requestNumber == numConnections {
                        allOtherRequestsCanProceedPromise.succeed()
                    } else {
                        // Block until the server receives the final request that will fulfill the promise.
                        try await allOtherRequestsCanProceedPromise.futureResult.get()
                    }

                    try await TestHelpers.echoResponse(readUpTo: 1024, reader: requestReader, sender: responseSender)
                }
            ) { (serverAddress: NIOHTTPServer.SocketAddress) in
                await withThrowingTaskGroup { group in
                    for _ in 1...numConnections {
                        group.addTask {
                            try await TestClientConnection.withConnectedRequestChannel(
                                configuration: clientConfiguration,
                                serverAddress: serverAddress
                            ) { inbound, outbound in
                                try await outbound.write(.testHead(method: .post, for: httpVersion))
                                try await outbound.write(.testBody)
                                try await outbound.write(.end(nil))

                                try await TestHelpers.validateResponse(
                                    inbound,
                                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                                    expectedBody: [.testData],
                                    expectStreamEnd: httpVersion != .plaintextHTTP1_1 && httpVersion != .http1_1
                                )

                                responseReceived()
                            }
                        }
                    }
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test("Multiple concurrent streams over single connection", arguments: [NIOHTTPServer.HTTPVersion.http2, .http3])
    #else
    @Test("Multiple concurrent streams over single connection", arguments: [NIOHTTPServer.HTTPVersion.http2])
    #endif
    func testMultipleConcurrentStreams(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let numStreams = 10
        let requestCounter = Mutex(0)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let allOtherRequestsCanProceedPromise = elg.any().makePromise(of: Void.self)

        try await confirmation(expectedCount: numStreams) { responseReceived in
            try await TestHelpers.withClientServerConnection(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                    let requestNumber = requestCounter.withLock { counter in
                        counter += 1
                        return counter
                    }

                    if requestNumber == numStreams {
                        allOtherRequestsCanProceedPromise.succeed()
                    } else {
                        // Block until the server receives the final request that will fulfill the promise.
                        try await allOtherRequestsCanProceedPromise.futureResult.get()
                    }

                    try await TestHelpers.echoResponse(readUpTo: 1024, reader: requestReader, sender: responseSender)
                }
            ) { _, connection in
                await withThrowingTaskGroup { group in
                    for _ in 1...numStreams {
                        group.addTask {
                            let stream = try await connection.makeRequestChannel(expectedHTTPVersion: httpVersion)
                            try await stream.executeThenClose { inbound, outbound in
                                try await outbound.write(.testHead(method: .post, for: httpVersion))
                                try await outbound.write(.testBody)
                                try await outbound.write(.end(nil))

                                try await TestHelpers.validateResponse(
                                    inbound,
                                    expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                                    expectedBody: [.testData]
                                )

                                responseReceived()
                            }
                        }
                    }
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "Server can still process other connections despite one failing",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    func testServerCanContinueDespiteFailedConnection(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let firstRequestErrorCaught = elg.any().makePromise(of: Void.self)

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                do {
                    try await TestHelpers.echoResponse(
                        readUpTo: ByteBuffer.testData.readableBytes,
                        reader: requestReader,
                        sender: responseSender
                    )
                } catch {
                    // Complete the promise
                    firstRequestErrorCaught.succeed()

                    // Propagate the error upwards
                    throw error
                }
            }
        ) { serverAddress in
            try await confirmation { responseReceived in
                try await TestClientConnection.withConnectedRequestChannel(
                    configuration: clientConfiguration,
                    serverAddress: serverAddress
                ) { inbound, outbound in
                    // Only send a request head; finish the stream immediately afterwards.
                    try await outbound.write(.testHead(method: .post, for: httpVersion))
                }

                try await firstRequestErrorCaught.futureResult.get()

                try await TestClientConnection.withConnectedRequestChannel(
                    configuration: clientConfiguration,
                    serverAddress: serverAddress
                ) { inbound, outbound in
                    try await outbound.write(.testHead(method: .post, for: httpVersion))
                    try await outbound.write(.testBody)
                    try await outbound.write(.end(nil))

                    try await TestHelpers.validateResponse(
                        inbound,
                        expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                        expectedBody: [.testData],
                        expectStreamEnd: httpVersion == .http2
                    )

                    responseReceived()
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Bind to multiple addresses")
    func testMultipleBindAddresses() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTargets: [
                    .hostAndPort(host: "127.0.0.1", port: 0),
                    .hostAndPort(host: "127.0.0.1", port: 0),
                ],
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in },
            body: { addresses in
                #expect(addresses.count == 2)
                let firstPort = try #require(addresses[0].port)
                let secondPort = try #require(addresses[1].port)
                #expect(firstPort != secondPort)
            }
        )
    }

    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test(
        "Serve requests on multiple addresses independently",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2, .http3]
    )
    #else
    @Test(
        "Serve requests on multiple addresses independently",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    #endif
    func testServeOnMultipleAddresses(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger,
            concurrentListeners: 2
        )

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                try await TestHelpers.echoResponse(
                    readUpTo: ByteBuffer.testData.readableBytes,
                    reader: requestReader,
                    sender: responseSender
                )
            },
            body: { addresses in
                #expect(addresses.count == 2)

                for address in addresses {
                    try await TestClientConnection.withConnectedRequestChannel(
                        configuration: clientConfiguration,
                        serverAddress: address
                    ) { inbound, outbound in
                        try await outbound.write(.testHead(method: .post, for: httpVersion))
                        try await outbound.write(.testBody)
                        try await outbound.write(.testEnd)

                        try await TestHelpers.validateResponse(
                            inbound,
                            expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                            expectedBody: [.testData],
                            expectedTrailers: .testTrailer,
                            expectStreamEnd: httpVersion != .plaintextHTTP1_1 && httpVersion != .http1_1
                        )
                    }
                }
            }
        )
    }

    /// Verifies the all-or-nothing listening semantics: when the server stops (e.g., due to cancellation),
    /// all bound addresses become unavailable simultaneously and ``listeningAddresses`` throws
    /// ``ListeningAddressError/serverClosed``. No subset of addresses continues serving after the server
    /// has stopped.
    @available(anyAppleOS 26.0, *)
    #if HTTP3
    @Test(
        "All addresses stop together and listeningAddresses throws after server stops",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2, .http3]
    )
    #else
    @Test(
        "All addresses stop together and listeningAddresses throws after server stops",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1, .http2]
    )
    #endif
    func testAllAddressesStopTogether(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger,
            concurrentListeners: 2
        )

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                try await TestHelpers.echoResponse(
                    readUpTo: ByteBuffer.testData.readableBytes,
                    reader: requestReader,
                    sender: responseSender
                )
            },
            body: { addresses in
                #expect(addresses.count == 2)

                // Verify both addresses are serving
                for address in addresses {
                    try await TestClientConnection.withConnectedRequestChannel(
                        configuration: clientConfiguration,
                        serverAddress: address
                    ) { inbound, outbound in
                        try await outbound.write(.testHead(method: .post, for: httpVersion))
                        try await outbound.write(.testBody)
                        try await outbound.write(.testEnd)
                        try await TestHelpers.validateResponse(
                            inbound,
                            expectedHead: [.makeResponse(status: .ok, for: httpVersion)],
                            expectedBody: [.testData],
                            expectedTrailers: .testTrailer,
                            expectStreamEnd: httpVersion != .plaintextHTTP1_1 && httpVersion != .http1_1
                        )
                    }
                }
            }
        )

        // After the server has stopped, listeningAddresses must throw rather than returning stale addresses.
        await #expect(throws: ListeningAddressError.serverClosed) {
            try await server.listeningAddresses
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Empty bind targets throws error")
    func testEmptyBindTargetsThrows() throws {
        #expect(throws: NIOHTTPServerConfigurationError.noBindTargetsSpecified) {
            try NIOHTTPServerConfiguration(
                bindTargets: [],
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        }
    }

    /// Verifies that when a later bind target fails, any previously-bound listening channels are cleaned up
    /// before the error propagates to the caller. Without cleanup, the already-bound sockets would leak and
    /// keep their ports occupied even though the server never started serving.
    ///
    /// The test binds two targets. The second target is configured to fail by pointing at a port that's
    /// already in use. We verify `serve` throws an `IOError` with `EADDRINUSE`, and that we can
    /// immediately rebind to the first target's port — proving the first channel was closed before the
    /// error propagated.
    ///
    /// We use a specific port for the first target (rather than `port: 0`) so we know what port to rebind
    /// to for the verification. The port is below the typical ephemeral range used by `port: 0`
    /// allocations on Linux (32768+) and macOS (49152+), so other tests using `port: 0` cannot
    /// accidentally be assigned this port by the OS.
    @available(anyAppleOS 26.0, *)
    @Test("Previously bound channels are closed when a later bind fails")
    func testPreviouslyBoundChannelsAreClosedOnPartialBindFailure() async throws {
        let firstPort = 30_210

        // Hold a live listener on an ephemeral port. The server's second bind will conflict with this
        // listener and fail with "address already in use".
        let occupiedListener = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeSucceededFuture(channel)
            }
        let occupiedPort = try #require(occupiedListener.channel.localAddress?.port)
        defer { occupiedListener.channel.close(promise: nil) }

        // Configure a server that binds to [firstPort, occupiedPort]. The first bind should succeed,
        // the second should fail with "address already in use", causing cleanup of the first channel.
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTargets: [
                    .hostAndPort(host: "127.0.0.1", port: firstPort),
                    .hostAndPort(host: "127.0.0.1", port: occupiedPort),
                ],
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        let error = await #expect(throws: IOError.self) {
            try await server.serve(
                handler: HTTPServerClosureRequestHandler { _, _, _, _ in }
            )
        }
        #expect(error?.errnoCode == EADDRINUSE)

        // If the first channel was properly closed, we should be able to bind to firstPort again.
        // If it wasn't (i.e., the channel leaked), this bind will fail with "address already in use".
        let rebindAttempt = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: firstPort) { channel in
                channel.eventLoop.makeSucceededFuture(channel)
            }
        try await rebindAttempt.channel.close()
    }
}
