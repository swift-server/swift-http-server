import HTTPServer
import HTTPTypes
import Middleware

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct RouteHandlerMiddleware<
    RequestConcludingAsyncReader: ConcludingAsyncReader & ~Copyable,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable,
>: Middleware, Sendable
where
    RequestConcludingAsyncReader.Underlying: AsyncReader<Span<UInt8>, any Error>,
    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying: AsyncWriter<Span<UInt8>, any Error>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    typealias Input = RequestResponseMiddlewareBox<RequestConcludingAsyncReader, ResponseConcludingAsyncWriter>
    typealias NextInput = Never

    func intercept(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Void
    ) async throws {
        try await input.withContents { request, _, requestReader, responseSender in
            var maybeReader = Optional(requestReader)
            try await responseSender.send(HTTPResponse(status: .accepted))
                .produceAndConclude { responseBodyAsyncWriter in
                    var responseBodyAsyncWriter = responseBodyAsyncWriter
                    if let reader = maybeReader.take() {
                        _ = try await reader.consumeAndConclude { bodyAsyncReader in
                            var shouldContinue = true
                            var bodyAsyncReader = bodyAsyncReader
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
                    } else {
                        fatalError("Closure run more than once")
                    }
                }
        }
    }
}
