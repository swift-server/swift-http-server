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
import HTTPTypes
import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
import Synchronization
import Testing

@testable import NIOHTTPServer

@Suite
struct HTTPKeepAliveHandlerTests {
    let serverLogger = Logger(label: "HTTPKeepAliveHandlerTests")

    /// Verifies the happy case: when a client pipelines multiple HTTP/1.1 requests
    /// on a single connection, all responses are returned in order and the connection
    /// stays alive (no `Connection: close`).
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Pipelined requests on a single connection all succeed")
    func testPipelinedRequests() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        let requestCount = 5

        try await NIOHTTPServerTests.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, _, reader, sender in
                try await NIOHTTPServerTests.echoResponse(readUpTo: 1024, reader: reader, sender: sender)
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    // Pipeline all requests up-front, then read all responses.
                    for i in 1...requestCount {
                        try await outbound.write(
                            .head(.init(method: .post, scheme: "http", authority: "", path: "/\(i)"))
                        )
                        try await outbound.write(.body(ByteBuffer(string: "request-\(i)")))
                        try await outbound.write(.end(nil))
                    }

                    var responseIterator = inbound.makeAsyncIterator()
                    for i in 1...requestCount {
                        let headPart = try await responseIterator.next()
                        guard case .head(let response) = headPart else {
                            Issue.record("Expected .head for request \(i), got \(String(describing: headPart))")
                            return
                        }
                        #expect(response.status == .ok)
                        // Connection should remain keep-alive — no Connection: close header.
                        #expect(
                            response.headerFields[.connection] != "close",
                            "Response \(i) unexpectedly had Connection: close: \(response.headerFields)"
                        )

                        // Drain body parts until .end.
                        var collectedBody = ByteBuffer()
                        while true {
                            let part = try await responseIterator.next()
                            if case .body(let buf) = part {
                                collectedBody.writeImmutableBuffer(buf)
                            } else if case .end = part {
                                break
                            } else {
                                Issue.record("Unexpected part for request \(i): \(String(describing: part))")
                                return
                            }
                        }
                        #expect(collectedBody == ByteBuffer(string: "request-\(i)"))
                    }
                }
            }
        )
    }

    /// Verifies that when the handler writes a short response (head + end, no body)
    /// before the request `.end` has arrived, the response head includes a
    /// `Connection: close` header and the server closes the connection.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Server sends head+end (no body) before request .end — Connection: close in header")
    func testShortResponseBeforeRequestEnd() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await NIOHTTPServerTests.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                // Read just one byte of the body to confirm we got past the head, then
                // write a body-less response (head + end only). Because the head is
                // still buffered by the keep-alive handler when `.end` is written, the
                // handler amends the head with `Connection: close` before flushing.
                let _ = try await reader.consumeAndConclude { partsReader in
                    var partsReader = partsReader
                    try await partsReader.read { _ in }
                }
                let writer = try await sender.send(
                    .init(status: .ok, headerFields: [.contentLength: "0"])
                )
                try await writer.writeAndConclude("".utf8.span, finalElement: nil)
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(
                        .head(.init(method: .post, scheme: "http", authority: "", path: "/"))
                    )
                    try await outbound.write(.body(ByteBuffer(string: "x")))

                    // Read the response: should have Connection: close in the head.
                    var responseIterator = inbound.makeAsyncIterator()
                    let headPart = try await responseIterator.next()
                    guard case .head(let response) = headPart else {
                        Issue.record("Expected .head, got \(String(describing: headPart))")
                        return
                    }
                    #expect(response.status == .ok)
                    #expect(
                        response.headerFields[.connection] == "close",
                        "Expected Connection: close, got headers: \(response.headerFields)"
                    )

                    // Drain until .end, then verify channel closed.
                    var sawEnd = false
                    while !sawEnd {
                        let part = try await responseIterator.next()
                        switch part {
                        case .body:
                            continue
                        case .end:
                            sawEnd = true
                        case .none:
                            Issue.record("Stream ended before response .end")
                            return
                        case .head:
                            Issue.record("Unexpected second .head: \(String(describing: part))")
                            return
                        }
                    }

                    let next = try await responseIterator.next()
                    #expect(next == nil, "Expected channel to be closed; got \(String(describing: next))")
                }
            }
        )
    }

    /// Verifies that informational (1xx) responses pass through the keep-alive handler
    /// without affecting buffering state. The handler writes a `100 Continue` before
    /// the request `.end` has arrived; the client must receive that informational
    /// response immediately (without waiting for request `.end`), and the connection
    /// must remain alive after the final response.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Informational (1xx) responses pass through without buffering or closing")
    func testInformationalResponsePassesThrough() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await NIOHTTPServerTests.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, _, reader, sender in
                // Only the first request exercises informational semantics; the
                // pipelined second request (path "/second") just verifies keep-alive.
                if request.path == "/" {
                    try await sender.sendInformational(.init(status: .continue))
                }

                // Read the full request body (until .end).
                let _ = try await reader.consumeAndConclude { partsReader in
                    var partsReader = partsReader
                    try await partsReader.collect(upTo: 1024) { _ in }
                }

                // Write the final response.
                let writer = try await sender.send(
                    .init(status: .ok, headerFields: [.contentLength: "5"])
                )
                try await writer.writeAndConclude("hello".utf8.span, finalElement: nil)
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(
                        .head(.init(method: .post, scheme: "http", authority: "", path: "/"))
                    )

                    // Read the 100 Continue before sending the request body — this
                    // only works if the informational response was forwarded without
                    // being buffered by the keep-alive handler.
                    var responseIterator = inbound.makeAsyncIterator()
                    let informationalPart = try await responseIterator.next()
                    guard case .head(let informational) = informationalPart else {
                        Issue.record("Expected informational .head, got \(String(describing: informationalPart))")
                        return
                    }
                    #expect(informational.status == .continue)

                    // Now send the body and end so the server can write the final
                    // response.
                    try await outbound.write(.body(ByteBuffer(string: "hello")))
                    try await outbound.write(.end(nil))

                    // Read the final 200 OK response.
                    let finalHeadPart = try await responseIterator.next()
                    guard case .head(let response) = finalHeadPart else {
                        Issue.record("Expected final .head, got \(String(describing: finalHeadPart))")
                        return
                    }
                    #expect(response.status == .ok)
                    #expect(
                        response.headerFields[.connection] != "close",
                        "Expected keep-alive after informational flow; got headers: \(response.headerFields)"
                    )

                    // Drain body and end.
                    var sawEnd = false
                    while !sawEnd {
                        let part = try await responseIterator.next()
                        switch part {
                        case .body:
                            continue
                        case .end:
                            sawEnd = true
                        case .none:
                            Issue.record("Stream ended before response .end")
                            return
                        case .head:
                            Issue.record("Unexpected .head: \(String(describing: part))")
                            return
                        }
                    }

                    // Pipeline a second request to verify keep-alive actually works.
                    try await outbound.write(
                        .head(.init(method: .get, scheme: "http", authority: "", path: "/second"))
                    )
                    try await outbound.write(.end(nil))

                    let secondHead = try await responseIterator.next()
                    guard case .head(let secondResponse) = secondHead else {
                        Issue.record("Expected second .head, got \(String(describing: secondHead))")
                        return
                    }
                    #expect(secondResponse.status == .ok)
                }
            }
        )
    }

    /// Verifies bidirectional streaming over HTTP/1.1: the handler writes the
    /// response head and body chunks while concurrently reading the request body.
    /// The client and server ping-pong — the client sends one byte, waits for its
    /// echo, then sends the next. This only works if the keep-alive handler flushes
    /// the response head as soon as a body chunk is written, rather than buffering
    /// everything until request `.end` arrives. Because the head is flushed before
    /// request `.end` arrives, the response carries `Connection: close` and the
    /// server closes the connection after writing response `.end`.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Bidirectional streaming works — head is flushed (with Connection: close) when a body part is written")
    func testBidirectionalStreamingOverHTTP1() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        try await NIOHTTPServerTests.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                // Echo request body parts back as response body parts, concurrently
                // with reading from the request body.
                var maybeReader = Optional(reader)
                let writer = try await sender.send(.init(status: .ok))
                try await writer.produceAndConclude { responseBodyWriter in
                    var responseBodyWriter = responseBodyWriter
                    let reader = maybeReader.take()!
                    let _ = try await reader.consumeAndConclude { bodyReader in
                        try await bodyReader.forEachBuffer { buffer in
                            try await responseBodyWriter.write(buffer.span)
                        }
                    }
                    return nil
                }
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(
                        .head(.init(method: .post, scheme: "http", authority: "", path: "/"))
                    )
                    // Write the first body byte before reading the response head, so
                    // the server has something to echo — this unblocks the buffered
                    // head in the keep-alive handler. This mirrors how real
                    // bidirectional clients (like the conformance `/echo` test) work.
                    let chunkCount = 5
                    let firstByte = ByteBuffer(bytes: [UInt8(ascii: "A")])
                    try await outbound.write(.body(firstByte))

                    var responseIterator = inbound.makeAsyncIterator()
                    let headPart = try await responseIterator.next()
                    guard case .head(let response) = headPart else {
                        Issue.record("Expected .head, got \(String(describing: headPart))")
                        return
                    }
                    #expect(response.status == .ok)
                    // The head was flushed because a body part was written before
                    // request `.end` arrived, so it carries `Connection: close`.
                    #expect(
                        response.headerFields[.connection] == "close",
                        "Expected Connection: close on bidirectional flow; got \(response.headerFields)"
                    )

                    // Read the echo of the first byte.
                    let firstEcho = try await responseIterator.next()
                    #expect(firstEcho == .body(firstByte))

                    // Ping-pong: write a byte, read its echo.
                    for i in 1..<chunkCount {
                        let byte = ByteBuffer(bytes: [UInt8(ascii: "A") + UInt8(i)])
                        try await outbound.write(.body(byte))
                        let echoed = try await responseIterator.next()
                        #expect(echoed == .body(byte))
                    }

                    // End the request; expect response end.
                    try await outbound.write(.end(nil))
                    let endPart = try await responseIterator.next()
                    #expect(endPart == .end(nil))

                    // The server should have closed the connection after writing
                    // response `.end`.
                    let next = try await responseIterator.next()
                    #expect(next == nil, "Expected channel to be closed; got \(String(describing: next))")
                }
            }
        )
    }

    /// Verifies that if an inbound read cycle ends without the request `.end` having
    /// arrived while the handler is mid-response, the buffered response head is
    /// amended with `Connection: close` and flushed, and the server closes the
    /// connection once response `.end` is written.
    ///
    /// We force the timing by having the handler write the response head, signal
    /// the client to send a body chunk (without `.end`), and then wait. When the
    /// server reads the body chunk, the read cycle ends with the head still
    /// buffered and request `.end` still missing — the keep-alive handler must add
    /// `Connection: close`.
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Read cycle ends without request .end while head is buffered — Connection: close added")
    func testReadCycleEndsWithoutRequestEnd_AddsConnectionClose() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        let (responseHeadWrittenStream, responseHeadWritten) = AsyncStream<Void>.makeStream()
        let (handlerCanFinishStream, handlerCanFinish) = AsyncStream<Void>.makeStream()

        try await NIOHTTPServerTests.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                // Write the response head before reading anything. The keep-alive
                // handler buffers it because request `.end` hasn't arrived.
                let writer = try await sender.send(
                    .init(status: .ok, headerFields: [.contentLength: "5"])
                )
                responseHeadWritten.yield()
                responseHeadWritten.finish()

                // Wait for the test to confirm it saw `Connection: close` before
                // we drain the request and finish the response.
                var canFinishIterator = handlerCanFinishStream.makeAsyncIterator()
                _ = await canFinishIterator.next()

                // Drain the request body + end and then write the response body + end.
                let _ = try await reader.consumeAndConclude { partsReader in
                    var partsReader = partsReader
                    try await partsReader.collect(upTo: 1024) { _ in }
                }
                try await writer.writeAndConclude("hello".utf8.span, finalElement: nil)
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    // Send only the head.
                    try await outbound.write(
                        .head(.init(method: .post, scheme: "http", authority: "", path: "/"))
                    )

                    // Wait for the handler to write the response head.
                    var signalIterator = responseHeadWrittenStream.makeAsyncIterator()
                    _ = await signalIterator.next()

                    // Send a single body byte, WITHOUT request `.end`. The server
                    // will see this as its own read cycle that ends with the
                    // request `.end` still missing — triggering the
                    // `Connection: close` amendment.
                    try await outbound.write(.body(ByteBuffer(string: "x")))

                    // Read the response head. It must carry `Connection: close`.
                    var responseIterator = inbound.makeAsyncIterator()
                    let headPart = try await responseIterator.next()
                    guard case .head(let response) = headPart else {
                        Issue.record("Expected .head, got \(String(describing: headPart))")
                        return
                    }
                    #expect(response.status == .ok)
                    #expect(
                        response.headerFields[.connection] == "close",
                        "Expected Connection: close after read cycle ended without request .end; got \(response.headerFields)"
                    )

                    // Let the handler finish and send the rest of the request.
                    handlerCanFinish.yield()
                    handlerCanFinish.finish()
                    try await outbound.write(.end(nil))

                    // Drain the response body + end.
                    var sawEnd = false
                    while !sawEnd {
                        let part = try await responseIterator.next()
                        switch part {
                        case .body:
                            continue
                        case .end:
                            sawEnd = true
                        case .none:
                            Issue.record("Stream ended before response .end")
                            return
                        case .head:
                            Issue.record("Unexpected second .head: \(String(describing: part))")
                            return
                        }
                    }

                    // The server should have closed the connection.
                    let next = try await responseIterator.next()
                    #expect(next == nil, "Expected channel close after response; got \(String(describing: next))")
                }
            }
        )
    }
}
