import HTTPTypes
import Middleware
import Tracing

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TracingMiddleware<Input: ~Copyable>: Middleware {
    typealias NextInput = Input
    
    func intercept(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Void
    ) async throws {
        var maybeInput = Optional(input)
        try await withSpan("Span1") { _ in
            if let input = maybeInput.take() {
                try await next(input)
            }
        }
    }
}
