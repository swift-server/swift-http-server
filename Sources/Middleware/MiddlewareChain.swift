/// A concrete implementation of ``Middleware`` that represents a single middleware or a chain of middlewares.
///
/// `MiddlewareChain` provides a structured way to compose middleware components, allowing them
/// to be linked together to form a processing pipeline. It serves both as a wrapper for
/// individual middleware components and as a container for chains of middleware.
///
/// This type plays a central role in the middleware architecture, providing a common
/// interface that can represent both simple and complex middleware arrangements.
public struct MiddlewareChain<Input, NextInput>: Middleware {
    private let middlewareFunc:
        (
            Input,
            (NextInput) async throws -> Void
        ) async throws -> Void

    /// Creates a new middleware chain from an existing middleware component.
    ///
    /// This initializer converts any type conforming to the ``Middleware`` protocol into a
    /// ``MiddlewareChain``, allowing it to be composed with other middleware chains.
    ///
    /// - Parameter middleware: The middleware component to wrap in a chain.
    public init(middleware: some Middleware<Input, NextInput>) {
        self.middlewareFunc = middleware.intercept
    }

    /// Creates a middleware chain using a raw middleware function.
    ///
    /// This internal initializer allows for the creation of middleware chains from
    /// closure-based implementations, which is particularly useful for composed middlewares.
    ///
    /// - Parameter middlewareFunc: A closure that implements the middleware's behavior.
    init(
        middlewareFunc: @escaping (
            Input,
            (NextInput) async throws -> Void
        ) async throws -> Void
    ) {
        self.middlewareFunc = middlewareFunc
    }

    /// Intercepts and processes the input, then calls the next middleware or handler.
    ///
    /// This method defines the core behavior of a middleware. It receives the current input,
    /// performs its operation, and then passes control to the next middleware or handler.
    ///
    /// - Parameters:
    ///   - input: The input data to be processed by this middleware.
    ///   - next: A closure representing the next step in the middleware chain.
    ///           It accepts a parameter of type `NextInput`.
    ///
    /// - Throws: Any error that occurs during processing.
    public func intercept(
        input: Input,
        next: (NextInput) async throws -> Void
    ) async throws {
        try await middlewareFunc(input, next)
    }
}
