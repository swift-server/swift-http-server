public import HTTPTypes
public import AsyncStreaming
public import Middleware
public import HTTPServer

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct RouteHandlerMiddleware<
    RequestConcludingAsyncReader: ConcludingAsyncReader & ~Copyable,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable,
>: Middleware, Sendable
where
    RequestConcludingAsyncReader.Underlying: AsyncReader<UInt8, any Error>,
    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying: AsyncWriter<UInt8, any Error>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    public typealias Input = RequestResponseMiddlewareBox<RequestConcludingAsyncReader, ResponseConcludingAsyncWriter>
    public typealias NextInput = Never

    public func intercept(
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
                            var bodyAsyncReader = bodyAsyncReader
                            try await bodyAsyncReader.read(maximumCount: nil) { span in
                                try await responseBodyAsyncWriter.write(span)
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
