import HTTPServer
import HTTPTypes
import Logging
import Testing

@Suite
struct HTTPServerTests {
    @Test
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testSimpleAPI() async throws {
        try await HTTPServer.Server
            .serve(
                logger: Logger(label: "Test"),
                configuration: .init(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0)
                )
            ) { request, requestConcludingReader, sendResponse in
                _ = try await requestConcludingReader.collect(upTo: 100) { _ in }
                let responseConcludingWriter = try await sendResponse(HTTPResponse(status: .ok))
                try await responseConcludingWriter.writeAndConclude(
                    element: [1, 2].span,
                    finalElement: HTTPFields(dictionaryLiteral: (.acceptEncoding, "Encoding"))
                )
            }
    }
}
