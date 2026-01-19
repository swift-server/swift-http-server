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

import AsyncStreaming
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

@testable import HTTPServer

@Suite
struct HTTPRequestConcludingAsyncReaderTests {
    @Test("Head request not allowed")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testWriteHeadRequestPartFatalError() async throws {
        // The request body reader should fatal error if it receives a head part
        await #expect(processExitsWith: .failure) {
            let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

            // Write just a request head
            source.yield(.head(.init(method: .get, scheme: "http", authority: "", path: "")))
            source.finish()

            let requestReader = HTTPRequestConcludingAsyncReader(
                iterator: stream.makeAsyncIterator(),
                readerState: .init()
            )

            _ = try await requestReader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader
                try await bodyReader.read(maximumCount: nil) { element in () }
            }
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
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testRequestWithConcludingElement(body: ByteBuffer, trailers: HTTPFields) async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // First write the request
        source.yield(.body(body))
        source.yield(.end(trailers))
        source.finish()

        // Then start reading the request
        let requestReader = HTTPRequestConcludingAsyncReader(iterator: stream.makeAsyncIterator(), readerState: .init())
        let (requestBody, finalElement) = try await requestReader.consumeAndConclude { bodyReader in
            var bodyReader = bodyReader

            var buffer = ByteBuffer()
            // Read the body chunk
            try await bodyReader.read(maximumCount: nil) { element in
                buffer.writeBytes(element.bytes)
                return
            }

            // Now read the trailer. We should get back an empty element here, but the trailer should be available in
            // the tuple returned by `consumeAndConclude`
            try await bodyReader.read(maximumCount: nil) { element in
                #expect(element.count == 0)
            }

            return buffer
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
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
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
                let requestReader = HTTPRequestConcludingAsyncReader(
                    iterator: stream.makeAsyncIterator(),
                    readerState: .init()
                )
                let (_, finalElement) = try await requestReader.consumeAndConclude { bodyReader in
                    // Read all body chunks
                    var chunksProcessed = 0
                    // swift-format-ignore: ReplaceForEachWithForLoop
                    try await bodyReader.forEach { element in
                        var buffer = ByteBuffer()
                        buffer.writeBytes(element.bytes)
                        #expect(bodyChunks[chunksProcessed] == buffer)

                        chunksProcessed += 1
                    }
                }

                #expect(finalElement == trailers)
            }
        }
    }

    @Test("Throw while reading request")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testThrowingWhileReadingRequest() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        let bodyChunks = (0..<10).map { i in ByteBuffer(bytes: [i]) }
        for chunk in bodyChunks {
            source.yield(.body(chunk))
        }
        source.yield(.end([.cookie: "test"]))
        source.finish()

        let requestReader = HTTPRequestConcludingAsyncReader(
            iterator: stream.makeAsyncIterator(),
            readerState: .init()
        )

        _ = await requestReader.consumeAndConclude { bodyReader in
            var bodyReader = bodyReader

            // Check that the read error is propagated
            await #expect(throws: TestError.errorWhileReading) {
                do {
                    try await bodyReader.read(maximumCount: nil) { (element) throws(TestError) in
                        throw TestError.errorWhileReading
                    }
                } catch let eitherError as EitherError<Error, TestError> {
                    try eitherError.unwrap()
                }
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("More bytes available than consumption limit")
    func testCollectMoreBytesThanAvailable() async throws {
        await #expect(processExitsWith: .failure) {
            let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

            // Write 10 bytes
            source.yield(.body(.init(repeating: 5, count: 10)))
            source.finish()

            let requestReader = HTTPRequestConcludingAsyncReader(
                iterator: stream.makeAsyncIterator(),
                readerState: .init()
            )

            _ = try await requestReader.consumeAndConclude { requestBodyReader in
                var requestBodyReader = requestBodyReader

                // Since there are more bytes than requested, this should fail.
                try await requestBodyReader.collect(upTo: 9) { element in
                    ()
                }
            }
        }
    }
}
