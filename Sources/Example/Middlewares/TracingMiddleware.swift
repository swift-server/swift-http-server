import HTTPTypes
import Middleware
import Tracing

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
