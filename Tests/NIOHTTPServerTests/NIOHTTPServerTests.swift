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

import AsyncStreaming
import HTTPAPIs
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import Synchronization
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerTests {
    let serverLogger = Logger(label: "NIOHTTPServerTests")

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

        try await Self.withServer(
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

    @Test("Plaintext request-response")
    @available(anyAppleOS 26.0, *)
    func testPlaintext() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                #expect(request == Self.makeRequest(method: .post, scheme: "http", for: .http1_1))

                var buffer = ByteBuffer()
                let (_, finalElement) = try await reader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    return try await bodyReader.collect(upTo: Self.bodyData.readableBytes + 1) { body in
                        buffer.writeBytes(body.span.bytes)
                    }
                }
                #expect(buffer == Self.bodyData)
                #expect(finalElement == Self.trailer)

                let responseBodySender = try await responseWriter.send(.init(status: .ok))
                try await responseBodySender.produceAndConclude { responseBodyWriter in
                    var responseBodyWriter = responseBodyWriter
                    try await responseBodyWriter.write(Self.bodyData.readableBytesUInt8Span)
                    return Self.trailer
                }
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    try await Self.validateResponse(
                        inbound,
                        expectedHead: [Self.responseHead(status: .ok, for: .http1_1)],
                        expectedBody: [Self.bodyData],
                        expectedTrailers: Self.trailer,
                        expectStreamEnd: false
                    )
                }
            }
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "mTLS request-response with custom verification callback returning peer certificates",
        arguments: [HTTPVersion.http1_1, HTTPVersion.http2]
    )
    func testMTLS(httpVersion: HTTPVersion) async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        let clientChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1, .http2(config: .init())],
                transportSecurity: .mTLS(
                    credentials: .inMemory(
                        certificateChain: [serverChain.leaf],
                        privateKey: serverChain.privateKey,
                    ),
                    trustConfiguration: .customCertificateVerificationCallback { certificates in
                        // Return the peer's certificate chain; this must then be accessible in the request handler
                        .certificateVerified(.init(.init(uncheckedCertificateChain: certificates)))
                    }
                )
            )
        )

        try await confirmation { responseReceived in
            try await Self.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                    #expect(request == Self.makeRequest(method: .post, for: httpVersion))

                    let peerChain = try #require(try await NIOHTTPServer.connectionContext.peerCertificateChain)
                    #expect(Array(peerChain) == [clientChain.leaf])

                    let (buffer, finalElement) = try await reader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader
                        var buffer = ByteBuffer()
                        _ = try await bodyReader.collect(upTo: Self.bodyData.readableBytes + 1) { body in
                            buffer.writeBytes(body.span.bytes)
                        }
                        return buffer
                    }
                    #expect(buffer == Self.bodyData)
                    #expect(finalElement == Self.trailer)

                    let sender = try await responseWriter.send(.init(status: .ok))
                    try await sender.produceAndConclude { bodyWriter in
                        var bodyWriter = bodyWriter
                        try await bodyWriter.write(Self.bodyData.readableBytesUInt8Span)
                        return Self.trailer
                    }
                },
                body: { serverAddress in
                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServerOverMTLS(
                            at: serverAddress,
                            clientChain: clientChain,
                            trustRoots: [serverChain.ca],
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                        .unwrapChannel(expectedHTTPVersion: httpVersion)

                    try await client.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                        try await outbound.write(Self.reqBody)
                        try await outbound.write(Self.reqEnd)

                        try await Self.validateResponse(
                            inbound,
                            expectedHead: [Self.responseHead(status: .ok, for: httpVersion)],
                            expectedBody: [Self.bodyData],
                            expectedTrailers: Self.trailer,
                            expectStreamEnd: httpVersion == .http2
                        )

                        responseReceived()
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Multiple informational response headers", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testMultipleInformationalResponseHeaders(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        try await confirmation { responseReceived in
            try await Self.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseSender in
                    try await responseSender.sendInformational(.init(status: .continue))
                    try await responseSender.sendInformational(.init(status: .earlyHints))
                    let writer = try await responseSender.send(.init(status: .ok))

                    try await writer.produceAndConclude { bodyWriter in
                        var bodyWriter = bodyWriter
                        try await bodyWriter.write(Self.bodyData.readableBytesUInt8Span)
                        return Self.trailer
                    }
                },
                body: { serverAddress in
                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                        .unwrapChannel(expectedHTTPVersion: httpVersion)

                    try await client.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .get, scheme: "https", authority: "", path: "/")))
                        try await outbound.write(.end(nil))

                        try await Self.validateResponse(
                            inbound,
                            expectedHead: [
                                .init(status: .continue),
                                .init(status: .earlyHints),
                                Self.responseHead(status: .ok, for: httpVersion),
                            ],
                            expectedBody: [Self.bodyData],
                            expectedTrailers: Self.trailer,
                            expectStreamEnd: httpVersion == .http2
                        )
                        responseReceived()
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Client closes stream without sending end part", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testRequestWithoutEndPart(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let requestReadPromise = elg.any().makePromise(of: Void.self)

        try await confirmation { responseReceived in
            try await Self.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseSender in
                    #expect(request == Self.makeRequest(method: .post, for: httpVersion))

                    _ = try await reader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader

                        // This should fail: the client has closed the stream without sending an end part.
                        let error = try await #require(throws: EitherError<Error, Never>.self) {
                            try await bodyReader.read { _ in }
                        }

                        switch httpVersion {
                        case .http1_1:
                            #expect(throws: HTTPParserError.invalidEOFState) { try error.unwrap() }

                        case .http2:
                            let h2Error = try #require(throws: NIOHTTP2Errors.StreamClosed.self) { try error.unwrap() }
                            #expect(h2Error.errorCode == .cancel)
                        }

                        requestReadPromise.succeed()
                    }
                },
                body: { serverAddress in
                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                        .unwrapChannel(expectedHTTPVersion: httpVersion)

                    try await client.executeThenClose { inbound, outbound in
                        // Only send a request head; finish the stream immediately afterwards.
                        try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                        outbound.finish()
                    }

                    // Wait for the server to handle the (partial) request before closing.
                    try await requestReadPromise.futureResult.get()

                    responseReceived()
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Bi-directional streaming", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testBidirectionalStreaming(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, requestReader, responseSender in
                #expect(request == Self.makeRequest(method: .post, for: httpVersion))

                var maybeReader = Optional(requestReader)

                try await responseSender.send(HTTPResponse(status: .ok)).produceAndConclude { responseBodyWriter in
                    var responseBodyWriter = responseBodyWriter

                    let reader = maybeReader.take()!

                    let (_, finalElement) = try await reader.consumeAndConclude { bodyAsyncReader in
                        var count = 1
                        try await bodyAsyncReader.forEachBuffer { buffer in
                            var chunk = ByteBuffer()
                            chunk.writeBytes(buffer.span.bytes)
                            #expect(chunk == ByteBuffer(bytes: [UInt8(count)]))
                            count += 1

                            try await responseBodyWriter.write(buffer.span)
                        }
                    }
                    #expect(finalElement == Self.trailer)

                    return Self.trailer
                }
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestSecureUpgradeHTTPServer(
                        at: serverAddress,
                        trustRoots: serverChain.chain,
                        applicationProtocol: httpVersion.alpnIdentifier
                    )
                    .unwrapChannel(expectedHTTPVersion: httpVersion)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                    var responseIterator = inbound.makeAsyncIterator()

                    // For HTTP/1.1, the keep-alive handler flushes the response head with
                    // `Connection: close` because a body part is written before the request
                    // `.end` arrives. HTTP/2 has no equivalent header.
                    var expectedHead = Self.responseHead(status: .ok, for: httpVersion)
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

                    try await outbound.write(.end(Self.trailer))
                    #expect(try await responseIterator.next() == .end(Self.trailer))
                }
            }
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test("Multiple serial HTTP/1.1 requests on the same connection")
    func testMultipleSerialHTTP1Requests() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        let requestCount = 3

        try await confirmation(expectedCount: requestCount) { responseReceived in
            try await Self.withServer(
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                    // Echo the request body back as the response body.
                    try await Self.echoResponse(readUpTo: 1024, reader: reader, sender: responseWriter)
                },
                body: { serverAddress in
                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestHTTP1Server(at: serverAddress)

                    try await client.executeThenClose { inbound, outbound in
                        var responseIterator = inbound.makeAsyncIterator()

                        for i in 1...requestCount {
                            // Send request
                            try await outbound.write(
                                .head(.init(method: .post, scheme: "http", authority: "", path: "/\(i)"))
                            )
                            try await outbound.write(Self.reqBody)
                            try await outbound.write(.end(nil))

                            // Read response
                            let headPart = try await responseIterator.next()
                            #expect(headPart == .head(Self.responseHead(status: .ok, for: .http1_1)))

                            let bodyPart = try await responseIterator.next()
                            #expect(bodyPart == .body(Self.bodyData))

                            let endPart = try await responseIterator.next()
                            #expect(endPart == .end(nil))

                            responseReceived()
                        }
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Multiple concurrent connections", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testMultipleConcurrentConnections(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        // We will create 10 connections and send a request from each connection. The server will fulfill the
        // `allOtherRequestsCanProceedPromise` promise after seeing the 10th request. All other requests will be blocked
        // waiting for that promise.
        let numConnections = 10
        let requestCounter = Mutex(0)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let allOtherRequestsCanProceedPromise = elg.any().makePromise(of: Void.self)

        try await confirmation(expectedCount: numConnections) { responseReceived in
            try await Self.withServer(
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

                    try await Self.echoResponse(readUpTo: 1024, reader: requestReader, sender: responseSender)
                },
                body: { serverAddress in
                    await withThrowingTaskGroup { group in
                        for _ in 1...numConnections {
                            group.addTask {
                                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                                    .connectToTestSecureUpgradeHTTPServer(
                                        at: serverAddress,
                                        trustRoots: serverChain.chain,
                                        applicationProtocol: httpVersion.alpnIdentifier
                                    )
                                    .unwrapChannel(expectedHTTPVersion: httpVersion)

                                try await client.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .post, scheme: "https", authority: "", path: "/"))
                                    )
                                    try await outbound.write(Self.reqBody)
                                    try await outbound.write(.end(nil))

                                    try await Self.validateResponse(
                                        inbound,
                                        expectedHead: [Self.responseHead(status: .ok, for: httpVersion)],
                                        expectedBody: [Self.bodyData],
                                        expectStreamEnd: httpVersion == .http2
                                    )

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Multiple concurrent HTTP/2 streams")
    func testMultipleConcurrentHTTP2Streams() async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        let numStreams = 10
        let requestCounter = Mutex(0)
        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let allOtherRequestsCanProceedPromise = elg.any().makePromise(of: Void.self)

        try await confirmation(expectedCount: numStreams) { responseReceived in
            try await Self.withServer(
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

                    try await Self.echoResponse(readUpTo: 1024, reader: requestReader, sender: responseSender)
                },
                body: { serverAddress in
                    await withThrowingTaskGroup { group in
                        for _ in 1...numStreams {
                            group.addTask {
                                let clientChannel = try await ClientBootstrap(
                                    group: .singletonMultiThreadedEventLoopGroup
                                )
                                .connectToTestSecureUpgradeHTTPServer(
                                    at: serverAddress,
                                    trustRoots: serverChain.chain,
                                    applicationProtocol: HTTPVersion.http2.alpnIdentifier
                                )

                                guard case .http2(let streamManager) = clientChannel else {
                                    Issue.record("Expected a HTTP/2 channel but got \(clientChannel).")
                                    return
                                }

                                let stream = try await streamManager.openStream()
                                try await stream.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .post, scheme: "https", authority: "", path: "/"))
                                    )
                                    try await outbound.write(Self.reqBody)
                                    try await outbound.write(.end(nil))

                                    try await Self.validateResponse(
                                        inbound,
                                        expectedHead: [Self.responseHead(status: .ok, for: .http2)],
                                        expectedBody: [Self.bodyData]
                                    )

                                    responseReceived()
                                }
                            }
                        }
                    }
                }
            )
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("Server can still process other connections despite one failing")
    func testServerCanContinueDespiteFailedConnection() async throws {
        let server = try NIOHTTPServerTests.makePlaintextHTTP1Server(logger: self.serverLogger)

        let elg: EventLoopGroup = .singletonMultiThreadedEventLoopGroup
        let firstRequestErrorCaught = elg.any().makePromise(of: Void.self)

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                do {
                    try await Self.echoResponse(
                        readUpTo: Self.bodyData.readableBytes,
                        reader: requestReader,
                        sender: responseSender
                    )
                } catch {
                    // Complete the promise
                    firstRequestErrorCaught.succeed()

                    // Propagate the error upwards
                    throw error
                }
            },
            body: { serverAddress in
                try await confirmation { responseReceived in
                    let firstClientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestHTTP1Server(at: serverAddress)

                    try await firstClientChannel.executeThenClose { inbound, outbound in
                        // Only send a request head; finish the stream immediately afterwards.
                        try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                    }

                    try await firstRequestErrorCaught.futureResult.get()

                    let secondClientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestHTTP1Server(at: serverAddress)

                    try await secondClientChannel.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                        try await outbound.write(.body(Self.bodyData))
                        try await outbound.write(.end(nil))

                        try await Self.validateResponse(
                            inbound,
                            expectedHead: [Self.responseHead(status: .ok, for: .http1_1)],
                            expectedBody: [Self.bodyData],
                            expectStreamEnd: false
                        )

                        responseReceived()
                    }
                }
            }
        )
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

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in },
            body: { (addresses: [NIOHTTPServer.SocketAddress]) in
                #expect(addresses.count == 2)
                #expect(addresses[0].port != addresses[1].port)
            }
        )
    }

    @available(anyAppleOS 26.0, *)
    @Test("Serve requests on multiple addresses independently")
    func testServeOnMultipleAddresses() async throws {
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

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                try await Self.echoResponse(
                    readUpTo: Self.bodyData.readableBytes,
                    reader: requestReader,
                    sender: responseSender
                )
            },
            body: { (addresses: [NIOHTTPServer.SocketAddress]) in
                #expect(addresses.count == 2)

                // Send a request to the first address
                let firstClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: addresses[0])

                try await firstClient.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    try await Self.validateResponse(
                        inbound,
                        expectedHead: [Self.responseHead(status: .ok, for: .http1_1)],
                        expectedBody: [Self.bodyData],
                        expectedTrailers: Self.trailer,
                        expectStreamEnd: false
                    )
                }

                // Send a request to the second address
                let secondClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: addresses[1])

                try await secondClient.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    try await Self.validateResponse(
                        inbound,
                        expectedHead: [Self.responseHead(status: .ok, for: .http1_1)],
                        expectedBody: [Self.bodyData],
                        expectedTrailers: Self.trailer,
                        expectStreamEnd: false
                    )
                }
            }
        )
    }

    /// Verifies the all-or-nothing listening semantics: when the server stops (e.g., due to cancellation),
    /// all bound addresses become unavailable simultaneously and ``listeningAddresses`` throws
    /// ``ListeningAddressError/serverClosed``. No subset of addresses continues serving after the server
    /// has stopped.
    @available(anyAppleOS 26.0, *)
    @Test("All addresses stop together and listeningAddresses throws after server stops")
    func testAllAddressesStopTogether() async throws {
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

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, context, requestReader, responseSender in
                try await Self.echoResponse(
                    readUpTo: Self.bodyData.readableBytes,
                    reader: requestReader,
                    sender: responseSender
                )
            },
            body: { addresses in
                #expect(addresses.count == 2)

                // Verify both addresses are serving
                for addr in addresses {
                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestHTTP1Server(at: addr)
                    try await client.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .post, scheme: "http", authority: "", path: "/")))
                        try await outbound.write(Self.reqBody)
                        try await outbound.write(Self.reqEnd)
                        try await Self.validateResponse(
                            inbound,
                            expectedHead: [Self.responseHead(status: .ok, for: .http1_1)],
                            expectedBody: [Self.bodyData],
                            expectedTrailers: Self.trailer,
                            expectStreamEnd: false
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

extension NIOHTTPServerTests {
    static let bodyData = ByteBuffer(repeating: 5, count: 100)
    static let reqBody = HTTPRequestPart.body(Self.bodyData)

    static let trailer: HTTPFields = [.trailer: "test_trailer"]
    static let reqEnd = HTTPRequestPart.end(trailer)

    @available(anyAppleOS 26.0, *)
    static func makePlaintextHTTP1Server(logger: Logger) throws -> NIOHTTPServer {
        let server = NIOHTTPServer(
            logger: logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        return server
    }

    @available(anyAppleOS 26.0, *)
    static func makeSecureUpgradeServer(
        bindTargets: [NIOHTTPServerConfiguration.BindTarget] = [.hostAndPort(host: "127.0.0.1", port: 0)],
        logger: Logger
    ) throws -> (NIOHTTPServer, ChainPrivateKeyPair) {
        let serverChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: logger,
            configuration: try .init(
                bindTargets: bindTargets,
                supportedHTTPVersions: [.http1_1, .http2(config: .defaults)],
                transportSecurity: .tls(
                    credentials: .inMemory(certificateChain: serverChain.chain, privateKey: serverChain.privateKey)
                )
            )
        )

        return (server, serverChain)
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
            #expect(headResponsePart == .head(expectedHeadPart), sourceLocation: sourceLocation)
        }

        for expectedBodyBuffer in expectedBody {
            let bodyResponsePart = try await responseIterator.next()
            #expect(bodyResponsePart == .body(expectedBodyBuffer), sourceLocation: sourceLocation)
        }

        let endResponsePart = try await responseIterator.next()
        #expect(endResponsePart == .end(expectedTrailers), sourceLocation: sourceLocation)

        if expectStreamEnd {
            #expect(
                try await responseIterator.next() == nil,
                "Received another response part when the response stream should have finished.",
                sourceLocation: sourceLocation
            )
        }
    }

    /// Returns the body encoding header fields required for the given HTTP version.
    static func makeBodyEncodingHeaders(for httpVersion: HTTPVersion) -> HTTPFields {
        switch httpVersion {
        case .http1_1:
            [.transferEncoding: "chunked"]
        case .http2:
            [:]
        }
    }

    /// Creates an ``HTTPRequest`` with the appropriate headers for the given `httpVersion`.
    static func makeRequest(
        method: HTTPRequest.Method,
        scheme: String = "https",
        authority: String = "",
        path: String = "/",
        for httpVersion: HTTPVersion
    ) -> HTTPRequest {
        let headers = self.makeBodyEncodingHeaders(for: httpVersion)
        return HTTPRequest(method: method, scheme: scheme, authority: authority, path: path, headerFields: headers)
    }

    /// Creates an ``HTTPResponse`` with the given status and the appropriate headers for the given `httpVersion`.
    static func responseHead(status: HTTPResponse.Status, for httpVersion: HTTPVersion) -> HTTPResponse {
        let headers = self.makeBodyEncodingHeaders(for: httpVersion)
        return HTTPResponse(status: status, headerFields: headers)
    }

    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with the first
    /// listening address, then cancels the server task.
    @available(anyAppleOS 26.0, *)
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestConcludingReader,
            NIOHTTPServer.ResponseConcludingWriter
        >,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await self.withServer(server: server, serverHandler: serverHandler) {
            (addresses: [NIOHTTPServer.SocketAddress]) in
            let address = try #require(addresses.first)
            try await body(address)
        }
    }

    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with all listening
    /// addresses, then cancels the server task.
    @available(anyAppleOS 26.0, *)
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestConcludingReader,
            NIOHTTPServer.ResponseConcludingWriter
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

    /// Reads the full request body and trailers from `reader`, then sends a `200 OK` response echoing them back.
    @available(anyAppleOS 26.0, *)
    static func echoResponse(
        readUpTo limit: Int,
        reader: consuming HTTPRequestConcludingAsyncReader,
        sender: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ) async throws {
        let (requestBody, trailers) = try await reader.consumeAndConclude { bodyReader in
            var bodyReader = bodyReader
            return try await bodyReader.collect(upTo: limit) { inputSpan in
                var buffer = ByteBuffer()
                buffer.writeBytes(inputSpan.span.bytes)
                return buffer
            }
        }

        let writer = try await sender.send(.init(status: .ok))
        try await writer.produceAndConclude { bodyWriter in
            var bodyWriter = bodyWriter
            try await bodyWriter.write(requestBody.readableBytesUInt8Span)
            return trailers
        }
    }
}
