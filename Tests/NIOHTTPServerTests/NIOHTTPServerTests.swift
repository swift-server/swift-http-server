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
import HTTPServer
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

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Obtain the listening address correctly")
    func testListeningAddress() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 1234))
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
            try await server.listeningAddress
        }
    }

    @Test("Plaintext request-response")
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func testPlaintext() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0))
        )

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                #expect(request == Self.makeRequest(method: .post, scheme: "http", for: .http1_1))

                var buffer = ByteBuffer()
                let (_, finalElement) = try await reader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    return try await bodyReader.collect(upTo: Self.bodyData.readableBytes + 1) { body in
                        buffer.writeBytes(body.bytes)
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
                        expectedTrailers: Self.trailer
                    )
                }
            }
        )
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test(
        "mTLS request-response with custom verification callback returning peer certificates",
        arguments: [HTTPVersion.http1_1, HTTPVersion.http2]
    )
    func testMTLS(httpVersion: HTTPVersion) async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        let clientChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                transportSecurity: .mTLS(
                    certificateChain: [serverChain.leaf],
                    privateKey: serverChain.privateKey,
                    trustRoots: [clientChain.ca],
                    customCertificateVerificationCallback: { certificates in
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
                            buffer.writeBytes(body.bytes)
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
                    let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServerOverMTLS(
                            at: serverAddress,
                            clientChain: clientChain,
                            trustRoots: [serverChain.ca],
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                    let client = try await Self.unwrapNegotiatedChannel(clientChannel, httpVersion)

                    try await client.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                        try await outbound.write(Self.reqBody)
                        try await outbound.write(Self.reqEnd)

                        try await Self.validateResponse(
                            inbound,
                            expectedHead: [Self.responseHead(status: .ok, for: httpVersion)],
                            expectedBody: [Self.bodyData],
                            expectedTrailers: Self.trailer
                        )

                        responseReceived()
                    }
                }
            )
        }
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Multiple informational response headers", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testMultipleInformationalResponseHeaders(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try self.makeSecureUpgradeServer()

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
                    let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                    let client = try await Self.unwrapNegotiatedChannel(clientChannel, httpVersion)

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
                            expectedTrailers: Self.trailer
                        )
                        responseReceived()
                    }
                }
            )
        }
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Client closes stream without sending end part", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testRequestWithoutEndPart(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try self.makeSecureUpgradeServer()

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
                            try await bodyReader.read(maximumCount: nil) { _ in }
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
                    let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                    let client = try await Self.unwrapNegotiatedChannel(clientChannel, httpVersion)

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

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Bi-directional streaming", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testBidirectionalStreaming(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try self.makeSecureUpgradeServer()

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
                        // swift-format-ignore: ReplaceForEachWithForLoop
                        try await bodyAsyncReader.forEach { span in
                            var buffer = ByteBuffer()
                            buffer.writeBytes(span.bytes)
                            #expect(buffer == ByteBuffer(bytes: [UInt8(count)]))
                            count += 1

                            try await responseBodyWriter.write(span)
                        }
                    }
                    #expect(finalElement == Self.trailer)

                    return Self.trailer
                }
            },
            body: { serverAddress in
                let clientChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestSecureUpgradeHTTPServer(
                        at: serverAddress,
                        trustRoots: serverChain.chain,
                        applicationProtocol: httpVersion.alpnIdentifier
                    )
                let client = try await Self.unwrapNegotiatedChannel(clientChannel, httpVersion)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .post, scheme: "https", authority: "", path: "/")))
                    var responseIterator = inbound.makeAsyncIterator()

                    let head = try await responseIterator.next()
                    #expect(head == .head(Self.responseHead(status: .ok, for: httpVersion)))

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

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Multiple concurrent connections", arguments: [HTTPVersion.http1_1, HTTPVersion.http2])
    func testMultipleConcurrentConnections(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try self.makeSecureUpgradeServer()

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
                                let clientChannel = try await ClientBootstrap(
                                    group: .singletonMultiThreadedEventLoopGroup
                                )
                                .connectToTestSecureUpgradeHTTPServer(
                                    at: serverAddress,
                                    trustRoots: serverChain.chain,
                                    applicationProtocol: httpVersion.alpnIdentifier
                                )

                                let client = try await Self.unwrapNegotiatedChannel(clientChannel, httpVersion)
                                try await client.executeThenClose { inbound, outbound in
                                    try await outbound.write(
                                        .head(.init(method: .post, scheme: "https", authority: "", path: "/"))
                                    )
                                    try await outbound.write(Self.reqBody)
                                    try await outbound.write(.end(nil))

                                    try await Self.validateResponse(
                                        inbound,
                                        expectedHead: [Self.responseHead(status: .ok, for: httpVersion)],
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

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Multiple concurrent HTTP/2 streams")
    func testMultipleConcurrentHTTP2Streams() async throws {
        let (server, serverChain) = try self.makeSecureUpgradeServer()

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
}
extension NIOHTTPServerTests {
    static let bodyData = ByteBuffer(repeating: 5, count: 100)
    static let reqBody = HTTPRequestPart.body(Self.bodyData)

    static let trailer: HTTPFields = [.trailer: "test_trailer"]
    static let reqEnd = HTTPRequestPart.end(trailer)

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func makeSecureUpgradeServer() throws -> (NIOHTTPServer, ChainPrivateKeyPair) {
        let serverChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                transportSecurity: .tls(certificateChain: serverChain.chain, privateKey: serverChain.privateKey)
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

        #expect(
            try await responseIterator.next() == nil,
            "Received another response part when the response stream should have finished.",
            sourceLocation: sourceLocation
        )
    }

    /// Unwraps a negotiated channel, asserting it matches the expected `httpVersion`. For HTTP/2, opens and returns a
    /// new stream channel.
    static func unwrapNegotiatedChannel(
        _ negotiatedChannel: NegotiatedClientConnection,
        _ httpVersion: HTTPVersion,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        switch negotiatedChannel {
        case .http1(let http1Channel):
            #expect(
                httpVersion == .http1_1,
                "Unexpectedly established an HTTP/1 connection.",
                sourceLocation: sourceLocation
            )
            return http1Channel

        case .http2(let http2StreamManager):
            #expect(
                httpVersion == .http2,
                "Unexpectedly established an HTTP/2 connection.",
                sourceLocation: sourceLocation
            )
            return try await http2StreamManager.openStream()
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

    /// Starts `server` with `serverHandler`, waits for it to begin listening, runs `body` with the listening address,
    /// then cancels the server task.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestConcludingReader,
            NIOHTTPServer.ResponseConcludingWriter
        >,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            // Add the server task to the group
            group.addTask {
                try await server.serve(handler: serverHandler)
            }

            // Wait for the server to start listening before running the body closure
            let listeningAddress = try await server.listeningAddress

            try await body(listeningAddress)

            // Shut the server down
            group.cancelAll()
        }
    }

    /// Reads the full request body and trailers from `reader`, then sends a `200 OK` response echoing them back.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    static func echoResponse(
        readUpTo limit: Int,
        reader: consuming HTTPRequestConcludingAsyncReader,
        sender: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ) async throws {
        let (requestBody, trailers) = try await reader.consumeAndConclude { bodyReader in
            var bodyReader = bodyReader
            return try await bodyReader.collect(upTo: limit) { span in
                var buffer = ByteBuffer()
                buffer.writeBytes(span.bytes)
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
