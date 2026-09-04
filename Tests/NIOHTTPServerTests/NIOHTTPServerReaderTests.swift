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
import NIOEmbedded
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

@testable import NIOHTTPServer

#if HTTP3
import NIOHTTP3
#endif

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
        await #expect(throws: TestError.intentional) {
            do {
                try await requestReader.read { _, _ throws(TestError) in
                    throw TestError.intentional
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

            var buffer = UniqueArray<UInt8>()
            buffer.reserveCapacity(9)
            do {
                _ = try await requestReader.collect(exactlyInto: &buffer)
            } catch let error
                as EitherError<
                    any Error,
                    EitherError<AsyncReaderLeftOverElementsError, AsyncReaderInsufficientElementsError>
                >
            {
                do {
                    try error.unwrap()
                } catch let inner
                    as EitherError<
                        AsyncReaderLeftOverElementsError,
                        AsyncReaderInsufficientElementsError
                    >
                {
                    try inner.unwrap()
                }
            }
        }
    }

    #if HTTP3 && UnstableHTTPDatagrams
    @Test("takeDatagramReader vends no datagram reader when not available")
    @available(anyAppleOS 26.0, *)
    func takeDatagramReaderVendsNilWhenNotAvailable() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()
        source.yield(.body(ByteBuffer(bytes: [1, 2, 3])))
        source.yield(.end(nil))
        source.finish()

        var requestBodyReader = NIOHTTPServer.Reader(readerState: .init(iterator: stream.makeAsyncIterator()))

        let datagramReader = await requestBodyReader.takeDatagramReader()
        var collected: [UInt8] = []

        if case .some = datagramReader {
            Issue.record("Unexpectedly received a datagram reader.")
        }

        // The request body reader should still be usable.
        try await requestBodyReader.read { buffer, _ in
            for index in buffer.indices { collected.append(buffer[index]) }
        }

        #expect(collected == [1, 2, 3])
    }

    @Test("takeDatagramReader vends a request body and datagram reader")
    @available(anyAppleOS 26.0, *)
    func takeDatagramReaderVendsRequestAndDatagramReader() async throws {
        let (reliableStream, reliableSource) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()
        reliableSource.yield(.body(ByteBuffer(bytes: [1, 2, 3])))
        reliableSource.yield(.end(nil))
        reliableSource.finish()

        // Set up a mock connection channel where we will write a datagram to.
        let connectionChannel = EmbeddedChannel()
        let datagramsNegotiatedPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        let handler = HTTP3ConnectionManager(
            eventLoop: connectionChannel.eventLoop,
            logger: .init(label: "test"),
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        try connectionChannel.pipeline.syncOperations.addHandler(handler)

        // Now create the reader.
        let datagramStreamPromise = connectionChannel.eventLoop.makePromise(of: HTTP3UnreliableDatagramStream.self)
        var requestBodyReader = NIOHTTPServer.Reader(
            readerState: .init(iterator: reliableStream.makeAsyncIterator()),
            datagramStreamFuture: datagramStreamPromise.futureResult
        )

        // First read from the reliable stream.
        var collected: [UInt8] = []
        try await requestBodyReader.read { buffer, _ in
            for index in buffer.indices { collected.append(buffer[index]) }
        }
        #expect(collected == [1, 2, 3])

        // Simulate the peer advertising support for receiving datagrams.
        connectionChannel.pipeline.fireUserInboundEventTriggered(ReceivedSettings(datagramsSupported: true))

        // Now simulate the arrival of a new stream with ID 0.
        let mockStream = HTTP3UnreliableDatagramStream(
            streamID: 0,
            connectionChannel: connectionChannel,
            maxBufferedDatagrams: 16
        )
        handler.register(datagramStream: mockStream)
        datagramStreamPromise.succeed(mockStream)

        let datagramReader = await requestBodyReader.takeDatagramReader()
        guard var datagramReader = datagramReader else {
            Issue.record("Expected a datagram reader but received `nil`.")
            return
        }

        // Now write a datagram addressed for stream ID 0 to the connection channel.
        try connectionChannel.writeInbound(HTTP3Datagram(streamID: 0, payload: .init([4, 5])))

        // We should be able to read the datagram from the datagram reader.
        #expect(try await TestHelpers.readDatagram(&datagramReader) == [4, 5])
    }

    @Test("Inbound datagrams are buffered up to a limit", arguments: [10, 20, 100])
    @available(anyAppleOS 26.0, *)
    func datagramsAreBufferedUpToLimit(maxBufferedDatagrams: Int) async throws {
        let (reliableStream, _) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()

        // Set up a mock connection channel where we will write a datagram to.
        let connectionChannel = EmbeddedChannel()
        let datagramsNegotiatedPromise = connectionChannel.eventLoop.makePromise(of: Void.self)
        let handler = HTTP3ConnectionManager(
            eventLoop: connectionChannel.eventLoop,
            logger: .init(label: "test"),
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        try connectionChannel.pipeline.syncOperations.addHandler(handler)

        // Now create the reader.
        let datagramStreamPromise = connectionChannel.eventLoop.makePromise(of: HTTP3UnreliableDatagramStream.self)
        var requestBodyReader = NIOHTTPServer.Reader(
            readerState: .init(iterator: reliableStream.makeAsyncIterator()),
            datagramStreamFuture: datagramStreamPromise.futureResult
        )

        // Simulate the peer advertising support for receiving datagrams.
        connectionChannel.pipeline.fireUserInboundEventTriggered(ReceivedSettings(datagramsSupported: true))

        // Now simulate the arrival of a new stream with ID 0.
        let mockStream = HTTP3UnreliableDatagramStream(
            streamID: 0,
            connectionChannel: connectionChannel,
            maxBufferedDatagrams: maxBufferedDatagrams
        )
        handler.register(datagramStream: mockStream)
        datagramStreamPromise.succeed(mockStream)

        let datagramReader = await requestBodyReader.takeDatagramReader()
        guard var datagramReader = datagramReader else {
            Issue.record("Expected a datagram reader but received `nil`.")
            return
        }

        // Now write datagrams until the buffer is full.
        for i in 0..<maxBufferedDatagrams {
            let payload = ByteBuffer([UInt8(i)])
            try connectionChannel.writeInbound(HTTP3Datagram(streamID: 0, payload: payload))
        }
        let lastInteger = UInt8(maxBufferedDatagrams)
        // Write two more datagrams.
        try connectionChannel.writeInbound(HTTP3Datagram(streamID: 0, payload: .init([lastInteger])))
        try connectionChannel.writeInbound(HTTP3Datagram(streamID: 0, payload: .init([lastInteger + 1])))
        try await connectionChannel.close()

        // We should be able to read just `maxBufferedDatagrams` number of datagrams. The two oldest datagrams should be
        // dropped.
        for i in 2..<maxBufferedDatagrams + 2 {
            let payload = [UInt8(i)]
            #expect(try await TestHelpers.readDatagram(&datagramReader) == payload)
        }
        #expect(try await TestHelpers.readDatagram(&datagramReader) == nil)
        #expect(try await TestHelpers.readDatagram(&datagramReader) == nil)
    }
    #endif  // HTTP3 && UnstableHTTPDatagrams
}
