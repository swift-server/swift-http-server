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

@testable import NIOHTTPServer

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
                try await bodyReader.read(maximumCount: nil) { _ in }
            }
        }
    }

    @Test("Stream cannot be finished before writing request end part")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testNotWritingRequestEndPartFatalError() async throws {
        await #expect(processExitsWith: .failure) {
            let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

            // Only write a request body part; do not write an end part.
            source.yield(.body(.init()))
            source.finish()

            let requestReader = HTTPRequestConcludingAsyncReader(
                iterator: stream.makeAsyncIterator(),
                readerState: .init()
            )

            _ = try await requestReader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader

                try await bodyReader.read(maximumCount: nil) { _ in }
                // The stream has finished without an end part. Calling `read` now should result in a fatal error.
                try await bodyReader.read(maximumCount: nil) { _ in }
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

            // There are more bytes available than our limit.
            let collected = try await requestBodyReader.collect(upTo: 9) { element in
                var buffer = ByteBuffer()
                buffer.writeBytes(element.bytes)
                return buffer
            }

            // We should only collect up to the limit (the first 9 bytes).
            #expect(collected == .init(repeating: 5, count: 9))
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("Multiple body chunks; multiple reads with limits")
    func testReadWithLimits() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // First write 10 bytes;
        source.yield(.body(.init(repeating: 1, count: 10)))
        // Then write another 5 bytes.
        source.yield(.body(.init(repeating: 2, count: 5)))
        source.yield(.end(nil))
        source.finish()

        let streamIterator = stream.makeAsyncIterator()

        let requestReader = HTTPRequestConcludingAsyncReader(iterator: streamIterator, readerState: .init())
        _ = try await requestReader.consumeAndConclude { requestBodyReader in
            var requestBodyReader = requestBodyReader

            // Collect 8 bytes (partial of first write).
            let collectedPartOne = try await requestBodyReader.collect(upTo: 8) { element in
                var buffer = ByteBuffer()
                buffer.writeBytes(element.bytes)
                return buffer
            }

            // Then collect 4 more bytes (overlap of first and second write).
            let collectedPartTwo = try await requestBodyReader.collect(upTo: 4) { element in
                var buffer = ByteBuffer()
                buffer.writeBytes(element.bytes)
                return buffer
            }

            // Then collect 3 more bytes (partial of second write).
            let collectedPartThree = try await requestBodyReader.collect(upTo: 3) { element in
                var buffer = ByteBuffer()
                buffer.writeBytes(element.bytes)
                return buffer
            }

            #expect(collectedPartOne == .init(repeating: 1, count: 8))
            #expect(collectedPartTwo == .init([1, 1, 2, 2]))
            #expect(collectedPartThree == .init(repeating: 2, count: 3))
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("Multiple random-length chunks; multiple reads with random limits")
    func testMultipleReadsWithRandomLimits() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // Generate random ByteBuffers of varying length and write them to the stream.
        var randomBuffer = ByteBuffer()
        for _ in 0..<100 {
            let randomNumber = UInt8.random(in: 1...50)
            let randomCount = Int.random(in: 1...50)

            let randomData = ByteBuffer(repeating: randomNumber, count: randomCount)
            // Store the data so we can track what we have wrote
            randomBuffer.writeImmutableBuffer(randomData)

            source.yield(.body(randomData))
        }
        source.yield(.end(nil))
        source.finish()

        let streamIterator = stream.makeAsyncIterator()

        let requestReader = HTTPRequestConcludingAsyncReader(iterator: streamIterator, readerState: .init())
        _ = try await requestReader.consumeAndConclude { requestBodyReader in
            var requestBodyReader = requestBodyReader

            var collectedBuffer = ByteBuffer()
            while true {
                let randomMaxCount = Int.random(in: 1...100)

                let collected = try await requestBodyReader.collect(upTo: randomMaxCount) { element in
                    var localBuffer = ByteBuffer()
                    localBuffer.writeBytes(element.bytes)
                    return localBuffer
                }

                if collected.readableBytes == 0 {
                    break
                }

                // The collected buffer should never exceed the specified max count.
                try #require(collected.readableBytes <= randomMaxCount)

                collectedBuffer.writeImmutableBuffer(collected)
            }

            // Check if the collected buffer exactly matches what was written to the stream.
            try #require(randomBuffer == collectedBuffer)
        }
    }
}
