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

import HTTPTypes
import NIOCore
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite
struct HTTPResponseConcludingAsyncWriterTests {
    let bodySampleOne: UInt8 = 1
    let bodySampleTwo: UInt8 = 2

    let trailerSampleOne: HTTPFields = [.serverTiming: "test"]
    let trailerSampleTwo: HTTPFields = [.serverTiming: "test", .cookie: "cookie"]

    @Test("Write single body element")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testSingleWriteAndConclude() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = HTTPResponseConcludingAsyncWriter(writer: writer, writerState: .init())

        try await responseWriter.writeAndConclude(self.bodySampleOne, finalElement: self.trailerSampleOne)

        // Now read the response
        var responseIterator = sink.makeAsyncIterator()

        let element = try #require(await responseIterator.next())
        #expect(element == .body(.init(bytes: [self.bodySampleOne])))

        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleOne))
    }

    @Test("Write multiple body elements")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testProduceMultipleElementsAndSingleTrailer() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = HTTPResponseConcludingAsyncWriter(writer: writer, writerState: .init())

        try await responseWriter.produceAndConclude { bodyWriter in
            var bodyWriter = bodyWriter

            // Write multiple elements
            try await bodyWriter.write(self.bodySampleOne)
            try await bodyWriter.write(self.bodySampleTwo)

            return self.trailerSampleOne
        }

        var responseIterator = sink.makeAsyncIterator()

        let firstElement = try #require(await responseIterator.next())
        let secondElement = try #require(await responseIterator.next())
        #expect(firstElement == .body(.init(bytes: [self.bodySampleOne])))
        #expect(secondElement == .body(.init(bytes: [self.bodySampleTwo])))

        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleOne))
    }

    @Test("Throw while writing response")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testThrowWhileProducing() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()

        // Check that the write error is propagated
        try await #require(throws: TestError.errorWhileWriting) {
            let responseWriter = HTTPResponseConcludingAsyncWriter(writer: writer, writerState: .init())
            try await responseWriter.produceAndConclude { bodyWriter in
                var bodyWriter = bodyWriter

                // Write an element
                try await bodyWriter.write(self.bodySampleOne)
                // Then throw
                throw TestError.errorWhileWriting
            }
        }

        var responseIterator = sink.makeAsyncIterator()

        let firstElement = try #require(await responseIterator.next())
        #expect(firstElement == .body(.init(bytes: [self.bodySampleOne])))
    }

    @Test("Write multiple elements and multiple trailers")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testProduceMultipleElementsAndMultipleTrailers() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = HTTPResponseConcludingAsyncWriter(writer: writer, writerState: .init())

        try await responseWriter.produceAndConclude { bodyWriter in
            var bodyWriter = bodyWriter

            // Write multiple elements
            try await bodyWriter.write(self.bodySampleOne)
            try await bodyWriter.write(self.bodySampleTwo)

            return self.trailerSampleTwo
        }

        var responseIterator = sink.makeAsyncIterator()

        let firstElement = try #require(await responseIterator.next())
        let secondElement = try #require(await responseIterator.next())
        #expect(firstElement == .body(.init(bytes: [self.bodySampleOne])))
        #expect(secondElement == .body(.init(bytes: [self.bodySampleTwo])))

        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleTwo))
    }

    @Test("No body, just trailers")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testNoBodyJustTrailers() async throws {
        let (writer, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let responseWriter = HTTPResponseConcludingAsyncWriter(writer: writer, writerState: .init())

        try await responseWriter.produceAndConclude { bodyWriter in
            self.trailerSampleTwo
        }

        var responseIterator = sink.makeAsyncIterator()
        let trailer = try #require(await responseIterator.next())
        #expect(trailer == .end(self.trailerSampleTwo))
    }
}

extension HTTPField.Name {
    static var serverTiming: Self {
        Self("Server-Timing")!
    }
}
