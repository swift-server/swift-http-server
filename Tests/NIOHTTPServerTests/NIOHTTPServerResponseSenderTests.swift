//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import BasicContainers
import NIOCore
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerResponseSenderTests {
    @Test("Informational header without informational status code")
    @available(anyAppleOS 27.0, *)
    func testInformationalResponseStatusCodePrecondition() async throws {
        // Sending an informational header with a non-1xx status code shouldn't be allowed
        try await #require(processExitsWith: .failure) {
            let (outboundWriter, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
            var sender = NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: .init())

            try await sender.sendInformational(.init(status: .ok, headerFields: [.contentType: "application/json"]))
        }
    }

    @Test("Multiple informational responses before final response")
    @available(anyAppleOS 27.0, *)
    func testSendMultipleInformationalResponses() async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        var sender = NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: .init())

        // Send two informational responses
        let firstInfoHead = HTTPResponse(status: .continue, headerFields: [.contentType: "application/json"])
        let secondInfoHead = HTTPResponse(status: .earlyHints, headerFields: [.contentType: "application/json"])
        try await sender.sendInformational(firstInfoHead)
        try await sender.sendInformational(secondInfoHead)

        // Then send the final response
        let finalResponseHead = HTTPResponse(status: .ok)
        let finalResponseBody = [UInt8]([1, 2])
        let finalResponseTrailer: HTTPFields = [.cookie: "cookie"]

        var buffer = UniqueArray(copying: finalResponseBody)
        try await sender.sendAndFinish(finalResponseHead, buffer: &buffer, trailer: finalResponseTrailer)

        var responseIterator = sink.makeAsyncIterator()
        let firstHead = try #require(await responseIterator.next())
        let secondHead = try #require(await responseIterator.next())
        let finalHead = try #require(await responseIterator.next())
        let body = try #require(await responseIterator.next())
        let trailer = try #require(await responseIterator.next())

        #expect(firstHead == .head(firstInfoHead))
        #expect(secondHead == .head(secondInfoHead))
        #expect(finalHead == .head(finalResponseHead))
        #expect(body == .body(ByteBuffer(bytes: finalResponseBody)))
        #expect(trailer == .end(finalResponseTrailer))
    }

    @Test("Buffered response drains its input and concludes the writer", arguments: [0, 2, 65536], [false, true])
    @available(anyAppleOS 27.0, *)
    func testBufferedResponse(byteCount: Int, includeTrailers: Bool) async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let state = NIOHTTPServer.ResponseSender.WriterState()
        let sender = NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: state)
        let response = HTTPResponse(status: .ok)
        let trailers: HTTPFields? = includeTrailers ? [.serverTiming: "test"] : nil
        var buffer = UniqueArray<UInt8>(copying: [UInt8](repeating: 97, count: byteCount))

        #expect(!state.wrapped.withLock { $0.finishedWriting })
        try await sender.sendAndFinish(response, buffer: &buffer, trailer: trailers)
        let drained = buffer.isEmpty
        #expect(drained)
        #expect(state.wrapped.withLock { $0.finishedWriting })

        var iterator = sink.makeAsyncIterator()
        #expect(await iterator.next() == .head(response))
        if byteCount > 0 {
            #expect(await iterator.next() == .body(ByteBuffer(repeating: 97, count: byteCount)))
        }
        #expect(await iterator.next() == .end(trailers))
    }

    @Test("Buffered response through the protocol requirement")
    @available(anyAppleOS 27.0, *)
    func testBufferedResponseThroughProtocol() async throws {
        func send<Sender: HTTPResponseSender & ~Copyable>(_ sender: consuming Sender) async throws
        where Sender.Writer: ~Copyable {
            var buffer = UniqueArray<UInt8>(copying: [1, 2, 3])
            try await sender.sendAndFinish(.init(status: .ok), buffer: &buffer, trailer: nil)
            let drained = buffer.isEmpty
            #expect(drained)
        }
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let state = NIOHTTPServer.ResponseSender.WriterState()
        try await send(NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: state))
        #expect(state.wrapped.withLock { $0.finishedWriting })
        var iterator = sink.makeAsyncIterator()
        #expect(await iterator.next() == .head(.init(status: .ok)))
        #expect(await iterator.next() == .body(ByteBuffer(bytes: [1, 2, 3])))
        #expect(await iterator.next() == .end(nil))
    }

    @Test("Buffered response rejects informational status")
    @available(anyAppleOS 27.0, *)
    func testBufferedResponseStatusPrecondition() async throws {
        await #expect(processExitsWith: .failure) {
            let (writer, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
            let sender = NIOHTTPServer.ResponseSender(writer: writer, writerState: .init())
            var buffer = UniqueArray<UInt8>()
            try await sender.sendAndFinish(.init(status: .continue), buffer: &buffer)
        }
    }
}
