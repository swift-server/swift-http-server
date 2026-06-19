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
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerReaderTests {
    @Test("Head request not allowed")
    @available(anyAppleOS 26.0, *)
    func testWriteHeadRequestPartFatalError() async throws {
        // The request body reader should fatal error if it receives a head part
        await #expect(processExitsWith: .failure) {
            let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

            // Write just a request head
            source.yield(.head(.init(method: .get, scheme: "http", authority: "", path: "")))
            source.finish()

            var requestReader = NIOHTTPServer.Reader(
                readerState: .init(iterator: stream.makeAsyncIterator())
            )

            try await requestReader.read { _, _ in }
        }
    }

    @Test("Stream cannot be finished before writing request end part")
    @available(anyAppleOS 26.0, *)
    func testNotWritingRequestEndPartFatalError() async throws {
        await #expect(processExitsWith: .failure) {
            let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

            // Only write a request body part; do not write an end part.
            source.yield(.body(.init()))
            source.finish()

            var requestReader = NIOHTTPServer.Reader(
                readerState: .init(iterator: stream.makeAsyncIterator())
            )

            try await requestReader.read { _, _ in }
            // The stream has finished without an end part. Calling `read` now should result in a fatal error.
            try await requestReader.read { _, _ in }
        }
    }

    @Test(
        "Request with concluding element",
        arguments: [ByteBuffer(repeating: 1, count: 100), ByteBuffer()],
        [
            HTTPFields([.init(name: .cookie, value: "test_cookie")]),
            HTTPFields([.init(name: .cookie, value: "first_cookie"), .init(name: .cookie, value: "second_cookie")]),
        ]
    )
    @available(anyAppleOS 26.0, *)
    func testRequestWithConcludingElement(body: ByteBuffer, trailers: HTTPFields) async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        source.yield(.body(body))
        source.yield(.end(trailers))
        source.finish()

        var requestReader = NIOHTTPServer.Reader(readerState: .init(iterator: stream.makeAsyncIterator()))
        var requestBody = ByteBuffer()

        _ = try await requestReader.read { buffer, _ in
            _ = requestBody.writeBytes(buffer.span.bytes)
        }

        let finalElement = try await requestReader.read { _, finalElement in
            finalElement
        }

        #expect(requestBody == body)
        #expect(finalElement == trailers)
    }

    @Test(
        "Streamed request with concluding element",
        arguments: [
            (0..<100).map { i in ByteBuffer(bytes: [i]) }  // 100 single-byte ByteBuffers
        ],
        [
            HTTPFields([.init(name: .cookie, value: "test")]),
            HTTPFields([.init(name: .cookie, value: "first_cookie"), .init(name: .cookie, value: "second_cookie")]),
        ]
    )
    @available(anyAppleOS 26.0, *)
    func testStreamedRequestBody(bodyChunks: [ByteBuffer], trailers: HTTPFields) async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // Execute the writer and reader tasks concurrently
        await withThrowingTaskGroup { group in
            group.addTask {
                for chunk in bodyChunks {
                    source.yield(.body(chunk))
                }
                source.yield(.end(trailers))
                source.finish()
            }

            group.addTask {
                let requestReader = NIOHTTPServer.Reader(
                    readerState: .init(iterator: stream.makeAsyncIterator())
                )
                // Read all body chunks
                var chunksProcessed = 0
                let finalElement = try await requestReader.forEachBuffer { buffer in
                    if buffer.isEmpty { return }

                    var chunk = ByteBuffer()
                    chunk.writeBytes(buffer.span.bytes)
                    #expect(bodyChunks[chunksProcessed] == chunk)

                    chunksProcessed += 1
                }

                #expect(finalElement == trailers)
            }
        }
    }

    @Test("Throw while reading request")
    @available(anyAppleOS 26.0, *)
    func testThrowingWhileReadingRequest() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        let bodyChunks = (0..<10).map { i in ByteBuffer(bytes: [i]) }
        for chunk in bodyChunks {
            source.yield(.body(chunk))
        }
        source.yield(.end([.cookie: "test"]))
        source.finish()

        var requestReader = NIOHTTPServer.Reader(
            readerState: .init(iterator: stream.makeAsyncIterator())
        )

        // Check that the read error is propagated
        await #expect(throws: TestError.errorWhileReading) {
            do {
                try await requestReader.read { _, _ throws(TestError) in
                    throw TestError.errorWhileReading
                }
            } catch let eitherError as EitherError<Error, TestError> {
                try eitherError.unwrap()
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("More bytes available than consumption limit")
    func testCollectMoreBytesThanAvailable() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // Write 10 bytes
        source.yield(.body(.init(repeating: 5, count: 10)))
        source.finish()

        // There are more bytes available than our limit.
        await #expect(throws: AsyncReaderLeftOverElementsError.self) {
            let requestReader = NIOHTTPServer.Reader(
                readerState: .init(iterator: stream.makeAsyncIterator())
            )

            do {
                _ = try await requestReader.collect(upTo: 9) { _ in }
            } catch let eitherEitherError
                as EitherError<EitherError<Error, AsyncReaderLeftOverElementsError>, Never>
            {
                do {
                    try eitherEitherError.unwrap()
                } catch let eitherError as EitherError<Error, AsyncReaderLeftOverElementsError> {
                    try eitherError.unwrap()
                }
            }
        }
    }
}
