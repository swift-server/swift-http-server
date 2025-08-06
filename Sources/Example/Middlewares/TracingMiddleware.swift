import HTTPTypes
import Middleware
import Tracing

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TracingMiddleware<Input>: Middleware {
    func intercept(
        input: Input,
        next: (NextInput) async throws -> Void
    ) async throws {
        try await withSpan("Span1") { _ in
            try await next(input)
        }
    }
}
