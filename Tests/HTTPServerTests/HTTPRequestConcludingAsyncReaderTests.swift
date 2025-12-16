@testable import HTTPServer
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOPosix
import Testing

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
                try await bodyReader.read { element in () }
            }
        }
    }

    @Test(
        "Request with concluding element",
        arguments: [ByteBuffer(repeating: 1, count: 100), ByteBuffer()],
        [
            HTTPFields([.init(name: .cookie, value: "test_cookie")]),
            HTTPFields([.init(name: .cookie, value: "first_cookie"), .init(name: .cookie, value: "second_cookie")])
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
            // Read just once: we only sent one body chunk
            try await bodyReader.read { element in
                if let element {
                    buffer.writeBytes(element.bytes)
                } else {
                    Issue.record("Unexpectedly failed to read the client's request body")
                }
            }

            // Attempting to read again should result in a `nil` element (we only sent one body chunk)
            try await bodyReader.read { element in
                if element != nil {
                    Issue.record("Received a non-nil value after the request body was completely read")
                }
            }

            return buffer
        }

        #expect(requestBody == body)
        #expect(finalElement == trailers)
    }

    @Test(
        "Streamed request with concluding element",
        arguments: [
            (0..<10).map { i in ByteBuffer() },  // 10 empty ByteBuffers
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
                let finalElement = try await requestReader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader

                    for chunk in bodyChunks {
                        try await bodyReader.read { element in
                            if let element {
                                var buffer = ByteBuffer()
                                buffer.writeBytes(element.bytes)
                                #expect(chunk == buffer)
                            } else {
                                Issue.record("Received a nil element before the request body was completely read")
                            }
                        }
                    }

                    try await bodyReader.read { element in
                        if element != nil {
                            Issue.record("Received a non-nil element after the request body was completely read")
                        }
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

        // Check that the read error is propagated
        try await #require(throws: TestError.errorWhileReading) {
            let requestReader = HTTPRequestConcludingAsyncReader(
                iterator: stream.makeAsyncIterator(),
                readerState: .init()
            )

            _ = try await requestReader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader

                try await bodyReader.read { element in
                    throw TestError.errorWhileReading
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

        let requestReader = HTTPRequestConcludingAsyncReader(iterator: stream.makeAsyncIterator(), readerState: .init())

        _ = try await requestReader.consumeAndConclude { requestBodyReader in
            var requestBodyReader = requestBodyReader

            // Attempting to collect a maximum of 9 bytes should result in a LimitExceeded error.
            await #expect(throws: LimitExceeded.self) {
                try await requestBodyReader.collect(upTo: 9) { element in
                    ()
                }
            }
        }
    }
}
