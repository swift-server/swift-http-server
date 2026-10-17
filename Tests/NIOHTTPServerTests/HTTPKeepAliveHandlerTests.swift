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
import NIOHTTPTypes
import NIOPosix
import Synchronization
import Testing

@testable import NIOHTTPServer

@Suite
struct HTTPKeepAliveHandlerTests {
    let clientLogger = Logger(label: "HTTPKeepAliveHandlerTests.client")
    let serverLogger = Logger(label: "HTTPKeepAliveHandlerTests.server")

    /// Verifies the happy case: when a client pipelines multiple HTTP/1.1 requests
    /// on a single connection, all responses are returned in order and the connection
    /// stays alive (no `Connection: close`).
    @available(anyAppleOS 27.0, *)
    @Test(
        "Pipelined requests on a single connection all succeed",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testPipelinedRequests(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let requestCount = 5

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, _, reader, sender in
                try await TestHelpers.echoResponse(readUpTo: 1024, reader: reader, sender: sender)
            }
        ) { _, inbound, outbound in
            // Pipeline all requests up-front, then read all responses.
            for i in 1...requestCount {
                try await outbound.write(.testHead(method: .post, path: "/\(i)", for: http1Variant))
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

    /// Verifies that when the handler writes a short response (head + end, no body)
    /// before the request `.end` has arrived, the response head includes a
    /// `Connection: close` header and the server closes the connection.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Server sends head+end (no body) before request .end — Connection: close in header",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testShortResponseBeforeRequestEnd(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                var reader = reader
                // Read just one byte of the body to confirm we got past the head, then
                // write a body-less response (head + end only). Because the head is
                // still buffered by the keep-alive handler when `.end` is written, the
                // handler amends the head with `Connection: close` before flushing.
                try await reader.read { _, _ in }
                try await sender.sendAndFinish(
                    .init(status: .ok, headerFields: [.contentLength: "0"])
                )
            },
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .post, for: http1Variant))
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

    /// Verifies that informational (1xx) responses pass through the keep-alive handler
    /// without affecting buffering state. The handler writes a `100 Continue` before
    /// the request `.end` has arrived; the client must receive that informational
    /// response immediately (without waiting for request `.end`), and the connection
    /// must remain alive after the final response.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Informational (1xx) responses pass through without buffering or closing",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testInformationalResponsePassesThrough(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, _, reader, sender in
                var sender = sender
                // Only the first request exercises informational semantics; the
                // pipelined second request (path "/second") just verifies keep-alive.
                if request.path == "/" {
                    try await sender.sendInformational(.init(status: .continue))
                }

                // Read the full request body (until .end).
                var requestBody = UniqueArray<UInt8>()
                requestBody.reserveCapacity(1024)
                _ = try await reader.collect(into: &requestBody)

                // Write the final response.
                var buffer = UniqueArray(copying: "hello".utf8)
                try await sender.sendAndFinish(
                    .init(status: .ok, headerFields: [.contentLength: "5"]),
                    buffer: &buffer
                )
            }
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .post, for: http1Variant))

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

    /// Verifies bidirectional streaming over HTTP/1.1: the handler writes the
    /// response head and body chunks while concurrently reading the request body.
    /// The client and server ping-pong — the client sends one byte, waits for its
    /// echo, then sends the next. This only works if the keep-alive handler flushes
    /// the response head as soon as a body chunk is written, rather than buffering
    /// everything until request `.end` arrives. Because the head is flushed before
    /// request `.end` arrives, the response carries `Connection: close` and the
    /// server closes the connection after writing response `.end`.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Bidirectional streaming works — head is flushed (with Connection: close) when a body part is written",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testBidirectionalStreamingOverHTTP1(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                // Echo request body parts back as response body parts, concurrently
                // with reading from the request body.
                let writer = try await sender.send(.init(status: .ok))
                try await reader.pipe(into: writer)
            }
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .post, for: http1Variant))
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
    @available(anyAppleOS 27.0, *)
    @Test(
        "Read cycle ends without request .end while head is buffered — Connection: close added",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testReadCycleEndsWithoutRequestEnd_AddsConnectionClose(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let (responseHeadWrittenStream, responseHeadWritten) = AsyncStream<Void>.makeStream()
        let (handlerCanFinishStream, handlerCanFinish) = AsyncStream<Void>.makeStream()

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
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
                var requestBody = UniqueArray<UInt8>()
                requestBody.reserveCapacity(1024)
                _ = try await reader.collect(into: &requestBody)
                var buffer = UniqueArray(copying: "hello".utf8)
                try await writer.finish(buffer: &buffer)
            }
        ) { _, inbound, outbound in
            // Send only the head.
            try await outbound.write(.testHead(method: .post, for: http1Variant))

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

    /// Verifies that when the request head carries `Connection: close`, the
    /// response is amended with `Connection: close` and the server closes the
    /// connection after writing response `.end`, even though the request was
    /// fully received before the response was written.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Request Connection: close closes the connection after the response ends",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testRequestConnectionCloseClosesAfterResponse(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                var requestBody = UniqueArray<UInt8>()
                requestBody.reserveCapacity(1024)
                _ = try await reader.collect(into: &requestBody)

                var buffer = UniqueArray(copying: "ok".utf8)
                try await sender.sendAndFinish(
                    .init(status: .ok, headerFields: [.contentLength: "2"]),
                    buffer: &buffer
                )
            }
        ) { _, inbound, outbound in
            var request = HTTPRequest(
                method: .get,
                scheme: .makeScheme(for: http1Variant),
                authority: "test",
                path: "/"
            )
            request.headerFields[.connection] = "close"
            try await outbound.write(.head(request))
            try await outbound.write(.end(nil))

            var responseIterator = inbound.makeAsyncIterator()
            let headPart = try await responseIterator.next()
            guard case .head(let response) = headPart else {
                Issue.record("Expected .head, got \(String(describing: headPart))")
                return
            }
            #expect(response.status == .ok)
            #expect(
                response.headerFields[.connection] == "close",
                "Expected Connection: close on the response, got headers: \(response.headerFields)"
            )

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

    /// Embedded-channel counterpart: a fully received request whose head carries
    /// `Connection: close` must amend the response head and close after `.end`.
    @available(anyAppleOS 27.0, *)
    @Test func testRequestConnectionCloseClosesEmbeddedChannelAfterResponseEnd() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())

        try channel.writeInbound(
            HTTPRequestPart.head(
                .init(
                    method: .get,
                    scheme: "http",
                    authority: "test",
                    path: "/",
                    headerFields: [.connection: "close"]
                )
            )
        )
        try channel.writeInbound(HTTPRequestPart.end(nil))

        try channel.writeOutbound(
            HTTPResponsePart.head(.init(status: .ok, headerFields: [.contentLength: "0"]))
        )
        try channel.writeOutbound(HTTPResponsePart.end(nil))
        channel.embeddedEventLoop.run()

        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .head(let response):
            #expect(response.status == .ok)
            #expect(
                response.headerFields[.connection] == "close",
                "Expected Connection: close, got headers: \(response.headerFields)"
            )

        case let other:
            Issue.record("Expected the response head, got \(String(describing: other))")
        }

        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .end:
            ()

        case let other:
            Issue.record("Expected response .end, got \(String(describing: other))")
        }

        #expect(!channel.isActive, "Expected the channel to close after response .end")
        _ = try? channel.finish()
    }

    /// Pipelining regression: only the last of three POSTs asks to close. The
    /// server must answer all three; only the last response may carry
    /// `Connection: close`, and the connection must close after that response.
    ///
    /// Writing response `.end` can synchronously deliver the next pipelined
    /// request into `channelRead`. Closing must use the flag captured *before*
    /// that write, or response 2 would close the connection and drop request 3.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Pipelined POSTs: only the last Connection: close closes after that response",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    func testPipelinedPostsOnlyLastConnectionClose(http1Variant: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        let requestCount = 3

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, sender in
                try await TestHelpers.echoResponse(readUpTo: 1024, reader: reader, sender: sender)
            }
        ) { _, inbound, outbound in
            for i in 1...requestCount {
                var request = HTTPRequest(
                    method: .post,
                    scheme: .makeScheme(for: http1Variant),
                    authority: "test",
                    path: "/\(i)"
                )
                if i == requestCount {
                    request.headerFields[.connection] = "close"
                }
                try await outbound.write(.head(request))
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
                if i == requestCount {
                    #expect(
                        response.headerFields[.connection] == "close",
                        "Response \(i) should have Connection: close: \(response.headerFields)"
                    )
                } else {
                    #expect(
                        response.headerFields[.connection] != "close",
                        "Response \(i) unexpectedly had Connection: close: \(response.headerFields)"
                    )
                }

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

            let next = try await responseIterator.next()
            #expect(
                next == nil,
                "Expected channel to be closed after the last response; got \(String(describing: next))"
            )
        }
    }

    /// `Connection` is a list header: a `close` token in any field, in any
    /// position, with any case, must close after the response.
    @available(anyAppleOS 27.0, *)
    @Test(
        "Connection close token forms close the EmbeddedChannel after the response",
        arguments: [
            "close",
            "keep-alive, close",
            "close, TE",
            "Close",
        ]
    )
    func testConnectionCloseTokenForms(connectionValue: String) throws {
        var headerFields = HTTPFields()
        headerFields[.connection] = connectionValue
        try self.assertEmbeddedChannelClosesForConnectionFields(headerFields)
    }

    /// Multiple `Connection` fields must be scanned independently so a `close`
    /// token on a later field is not missed.
    @available(anyAppleOS 27.0, *)
    @Test func testConnectionCloseAcrossMultipleConnectionFields() throws {
        try self.assertEmbeddedChannelClosesForConnectionFields(
            HTTPFields([
                .init(name: .connection, value: "keep-alive"),
                .init(name: .connection, value: "close"),
            ])
        )
    }

    @available(anyAppleOS 27.0, *)
    private func assertEmbeddedChannelClosesForConnectionFields(_ headerFields: HTTPFields) throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())

        try channel.writeInbound(
            HTTPRequestPart.head(
                .init(
                    method: .get,
                    scheme: "http",
                    authority: "test",
                    path: "/",
                    headerFields: headerFields
                )
            )
        )
        try channel.writeInbound(HTTPRequestPart.end(nil))

        try channel.writeOutbound(
            HTTPResponsePart.head(.init(status: .ok, headerFields: [.contentLength: "0"]))
        )
        try channel.writeOutbound(HTTPResponsePart.end(nil))
        channel.embeddedEventLoop.run()

        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .head(let response):
            #expect(response.status == .ok)
            #expect(
                response.headerFields[.connection] == "close",
                "Expected Connection: close, got headers: \(response.headerFields)"
            )

        case let other:
            Issue.record("Expected the response head, got \(String(describing: other))")
        }

        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .end:
            ()

        case let other:
            Issue.record("Expected response .end, got \(String(describing: other))")
        }

        #expect(!channel.isActive, "Expected the channel to close after response .end")
        _ = try? channel.finish()
    }

    @available(anyAppleOS 27.0, *)
    @Test func channelClosesOnConnectionError() async throws {
        let channel = EmbeddedChannel()
        try await channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).get()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())

        // Simulate an incoming request and then a connection error.
        try channel.writeInbound(HTTPRequestPart.testHead(method: .get, for: .plaintextHTTP1_1))
        channel.pipeline.fireErrorCaught(TestError.intentional)

        // The connection error will trigger the channel to be closed on the next event loop tick. Let's test the
        // behaviour before the tick and after the tick.

        // Trying to write before the channel closes will result in the connection error being propagated.
        await #expect(throws: TestError.intentional) {
            try await channel.writeAndFlush(HTTPResponsePart.head(.init(status: .ok)))
        }

        // Now run the event loop so the channel can close.
        channel.embeddedEventLoop.run()

        // Now the channel should have closed. Trying to write should result in `ChannelError.ioOnClosedChannel`.
        await #expect(throws: ChannelError.ioOnClosedChannel) {
            try await channel.writeAndFlush(HTTPResponsePart.head(.init(status: .ok)))
        }
    }
}
