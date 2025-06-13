import HTTPServer
import HTTPTypes
import Middleware

struct RouteHandlerMiddleware<
    RequestConcludingAsyncReader: ConcludingAsyncReader & Copyable,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable,
>: Middleware, Sendable
where
    RequestConcludingAsyncReader.Underlying: AsyncReader<Span<UInt8>, any Error>,
    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying: AsyncWriter<Span<UInt8>, any Error>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    typealias Input = (
        HTTPRequest,
        RequestConcludingAsyncReader,
        (HTTPResponse) async throws -> ResponseConcludingAsyncWriter
    )
    typealias NextInput = Never

    init(
        requestConcludingAsyncReaderType: RequestConcludingAsyncReader.Type = RequestConcludingAsyncReader.self,
        responseConcludingAsyncWriterType: ResponseConcludingAsyncWriter.Type = ResponseConcludingAsyncWriter.self
    ) {
    }

    func intercept(
        input: Input,
        next: (NextInput) async throws -> Void
    ) async throws {
        try await input.2(HTTPResponse(status: .accepted)).produceAndConclude { responseBodyAsyncWriter in
            var responseBodyAsyncWriter = responseBodyAsyncWriter
            _ = try await input.1.consumeAndConclude { bodyAsyncReader in
                var shouldContinue = true
                while shouldContinue {
                    try await bodyAsyncReader.read { span in
                        guard let span else {
                            shouldContinue = false
                            return
                        }
                        try await responseBodyAsyncWriter.write(span)
                    }
                }
            }
            return HTTPFields(dictionaryLiteral: (HTTPField.Name.acceptEncoding, "encoding"))
        }
    }
}
