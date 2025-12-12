@testable import HTTPServer
import NIOCore
import NIOHTTPTypes
import HTTPTypes
import Testing

@Suite
struct HTTPResponseSenderTests {
    @Test("Informational header without informational status code")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testInformationalResponseStatusCodePrecondition() async throws {
        // Sending an informational header with a non-1xx status code shouldn't be allowed
        try await #require(processExitsWith: .failure) {
            let (outboundWriter, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
            let sender = HTTPResponseSender { response in
                try await outboundWriter.write(.head(response))
                return HTTPResponseConcludingAsyncWriter(
                    writer: outboundWriter,
                    writerState: .init()
                )
            } sendInformational: { response in
                try await outboundWriter.write(.head(response))
            }

            try await sender.sendInformational(.init(status: .ok, headerFields: [.contentType: "application/json"]))
        }
    }

    @Test("Multiple informational responses before final response")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testSendMultipleInformationalResponses() async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        let sender = HTTPResponseSender { response in
            try await outboundWriter.write(.head(response))
            return HTTPResponseConcludingAsyncWriter(
                writer: outboundWriter,
                writerState: .init()
            )
        } sendInformational: { response in
            try await outboundWriter.write(.head(response))
        }

        // Send two informational responses
        let firstInfoHead = HTTPResponse(status: .continue, headerFields: [.contentType: "application/json"])
        let secondInfoHead = HTTPResponse(status: .earlyHints, headerFields: [.contentType: "application/json"])
        try await sender.sendInformational(firstInfoHead)
        try await sender.sendInformational(secondInfoHead)

        // Then send the final response
        let finalResponseHead = HTTPResponse(status: .ok, headerFields: [:])
        let finalResponseBody = [UInt8]([1, 2])
        let finalResponseTrailer: HTTPFields = [.cookie: "cookie"]

        let responseWriter = try await sender.send(.init(status: .ok, headerFields: [:]))
        try await responseWriter.produceAndConclude { bodyTrailerWriter in
            var bodyTrailerWriter = bodyTrailerWriter
            try await bodyTrailerWriter.write(finalResponseBody.span)
            return finalResponseTrailer
        }

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
}
