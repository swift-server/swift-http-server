import HTTPServer
import HTTPTypes
import Logging
import Testing

@Suite
struct HTTPServerTests {
    @Test
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testConsumingServe() async throws {
        try await HTTPServer.Server
            .serve(
                logger: Logger(label: "Test"),
                configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0)),
                handler: HTTPServerTests.executeTestBody(request:requestReader:responseSender:)
            )
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Sendable
    nonisolated(nonsending) static func executeTestBody(
        request: HTTPRequest,
        requestReader: consuming HTTPRequestConcludingAsyncReader,
        responseSender: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ) async throws {
        _ = try await requestReader.collect(upTo: 100) { _ in }
        // Uncommenting this would cause a "requestReader consumed more than once" error.
        //_ = try await requestReader.collect(upTo: 100) { _ in }

        let responseConcludingWriter = try await responseSender.sendResponse(HTTPResponse(status: .ok))
        // Uncommenting this would cause a "responseSender consumed more than once" error.
        //let responseConcludingWriter2 = try await responseSender.sendResponse(HTTPResponse(status: .ok))

        // Uncommenting this would cause a "requestReader consumed more than once" error.
        //_ = try await requestReader.consumeAndConclude { reader in
        //    var reader = reader
        //    try await reader.read { elem in }
        //}

        try await responseConcludingWriter.produceAndConclude { writer in
            var writer = writer
            try await writer.write([1,2].span)
            return nil
        }

        // Uncommenting this would cause a "responseConcludingWriter consumed more than once" error.
        //try await responseConcludingWriter.writeAndConclude(
        //    element: [1, 2].span,
        //    finalElement: HTTPFields(dictionaryLiteral: (.acceptEncoding, "Encoding"))
        //)
    }
}
