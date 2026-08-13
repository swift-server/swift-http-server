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
struct NIOHTTPServerWriterTests {
    let bodySampleOne: UInt8 = 1
    let bodySampleTwo: UInt8 = 2

    let trailerSampleOne: HTTPFields = [.serverTiming: "test"]
    let trailerSampleTwo: HTTPFields = [.serverTiming: "test", .cookie: "cookie"]

    @Test("Write single body element")
    @available(anyAppleOS 26.0, *)
    func testSingleWriteAndConclude() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = NIOHTTPServer.ResponseSender.Writer(writer: writer, writerState: .init())

        var buffer = UniqueArray<UInt8>(copying: [self.bodySampleOne])
        try await responseWriter.finish(buffer: &buffer, finalElement: self.trailerSampleOne)

        // Now read the response
        var responseIterator = sink.makeAsyncIterator()

        let element = try #require(await responseIterator.next())
        #expect(element == .body(.init(bytes: [self.bodySampleOne])))

        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleOne))
    }

    @Test("Write multiple body elements")
    @available(anyAppleOS 26.0, *)
    func testProduceMultipleElementsAndSingleTrailer() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        var responseWriter = NIOHTTPServer.ResponseSender.Writer(writer: writer, writerState: .init())

        var buffer = UniqueArray<UInt8>(copying: [self.bodySampleOne])
        try await responseWriter.write(buffer: &buffer)
        buffer = UniqueArray<UInt8>(copying: [self.bodySampleTwo])
        try await responseWriter.write(buffer: &buffer)
        try await responseWriter.finish(trailer: self.trailerSampleOne)

        var responseIterator = sink.makeAsyncIterator()

        let firstElement = try #require(await responseIterator.next())
        let secondElement = try #require(await responseIterator.next())
        #expect(firstElement == .body(.init(bytes: [self.bodySampleOne])))
        #expect(secondElement == .body(.init(bytes: [self.bodySampleTwo])))

        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleOne))
    }

    @Test("No body, just trailers")
    @available(anyAppleOS 26.0, *)
    func testNoBodyJustTrailers() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = NIOHTTPServer.ResponseSender.Writer(writer: writer, writerState: .init())

        try await responseWriter.finish(trailer: self.trailerSampleTwo)

        var responseIterator = sink.makeAsyncIterator()
        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleTwo))
    }

    #if HTTP3 && UnstableHTTPDatagrams
    @Test("takeDatagramWriter vends no datagram writer when not available")
    @available(anyAppleOS 26.0, *)
    func takeDatagramWriterVendsNilWhenNotAvailable() async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let sender = NIOHTTPServer.ResponseSender(
            writer: outboundWriter,
            writerState: .init(),
            datagramWriter: nil
        )

        var responseBodyWriter = try await sender.send(.init(status: .ok))
        let datagramWriter = responseBodyWriter.takeDatagramWriter()

        if case .some = datagramWriter {
            Issue.record("Unexpectedly received a datagram writer.")
        }

        // The response body writer should still be usable.
        var testBuffer = UniqueArray<UInt8>(repeating: 5, count: 10)
        try await responseBodyWriter.finish(buffer: &testBuffer)

        var responseIterator = sink.makeAsyncIterator()
        let head = try #require(await responseIterator.next())
        let body = try #require(await responseIterator.next())
        let end = try #require(await responseIterator.next())

        #expect(head == .head(.init(status: .ok)))
        #expect(body == .body(.init(repeating: 5, count: 10)))
        #expect(end == .end(nil))
    }

    @Test("takeDatagramWriter vends a response body and datagram writer")
    @available(anyAppleOS 26.0, *)
    func takeDatagramWriterVendsResponseAndDatagramWriter() async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let sender = NIOHTTPServer.ResponseSender(
            writer: outboundWriter,
            writerState: .init(),
            datagramWriter: NIOHTTPServer.DatagramWriter()
        )

        var responseBodyWriter = try await sender.send(.init(status: .ok))
        let datagramWriter = responseBodyWriter.takeDatagramWriter()

        var testBuffer = UniqueArray<UInt8>(repeating: 5, count: 10)
        try await responseBodyWriter.finish(buffer: &testBuffer)

        guard var datagramWriter = datagramWriter else {
            Issue.record("Expected a datagram writer but received `nil`.")
            return
        }

        // TODO: The underlying unreliable datagrams transport is not yet implemented.
        await #expect(throws: DatagramsError.notImplemented) {
            var emptyBuffer = UniqueArray<UInt8>()
            try await datagramWriter.write(buffer: &emptyBuffer)
        }

        var responseIterator = sink.makeAsyncIterator()
        let head = try #require(await responseIterator.next())
        let body = try #require(await responseIterator.next())
        let end = try #require(await responseIterator.next())

        #expect(head == .head(.init(status: .ok)))
        #expect(body == .body(.init(repeating: 5, count: 10)))
        #expect(end == .end(nil))
    }
    #endif  // HTTP3 && UnstableHTTPDatagrams
}

extension HTTPField.Name {
    static var serverTiming: Self {
        Self("Server-Timing")!
    }
}
