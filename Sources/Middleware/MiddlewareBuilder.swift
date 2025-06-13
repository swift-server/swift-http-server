/// A result builder that enables a declarative syntax for constructing middleware chains.
///
/// ``MiddlewareChainBuilder`` leverages Swift's result builder feature to allow developers
/// to create complex middleware pipelines using a clean, DSL-like syntax. It handles
/// the type checking and composition of middleware components automatically.
///
/// This makes it easier to construct middleware chains that might involve multiple
/// transformations and conditional processing logic without having to manually manage
/// the type relationships between different middleware components.
///
/// Example usage:
/// ```swift
/// @MiddlewareChainBuilder
/// func buildMiddlewareChain() -> some Middleware<Request, Response> {
///     LoggingMiddleware()
///     AuthenticationMiddleware()
///     if shouldCompress {
///         CompressionMiddleware()
///     }
///     RoutingMiddleware()
/// }
/// ```
@resultBuilder
public struct MiddlewareChainBuilder {
    /// Builds a middleware chain from a single middleware component.
    ///
    /// This is the base case for the result builder pattern, handling a single middleware.
    ///
    /// - Parameter middleware: The single middleware component to wrap in a chain.
    /// - Returns: A middleware chain containing the single component.
    public static func buildPartialBlock<I: Middleware>(
        first middleware: I
    ) -> MiddlewareChain<I.Input, I.NextInput> {
        MiddlewareChain(middleware: middleware)
    }

    /// Chains together two middleware components, ensuring their input and output types match.
    ///
    /// This method composes two middlewares where the output of the first matches the input of the second,
    /// creating a unified processing pipeline.
    ///
    /// - Parameters:
    ///   - accumulated: The first middleware in the chain.
    ///   - next: The second middleware in the chain, which accepts the output of the first.
    /// - Returns: A new middleware chain that represents the composition of both middlewares.
    public static func buildPartialBlock<Input, MiddleInput, NextInput>(
        accumulated: MiddlewareChain<Input, MiddleInput>,
        next: MiddlewareChain<MiddleInput, NextInput>
    ) -> MiddlewareChain<Input, NextInput> {
        let chained = ChainedMiddleware(first: accumulated, second: next)
        return MiddlewareChain(middlewareFunc: chained.intercept)
    }

    /// Converts a middleware expression to a middleware chain.
    ///
    /// This method allows middleware components to be used directly in result builder expressions.
    ///
    /// - Parameter middleware: The middleware component to convert.
    /// - Returns: A middleware chain wrapping the input middleware.
    public static func buildExpression<I: Middleware>(
        _ middleware: I
    ) -> MiddlewareChain<I.Input, I.NextInput> {
        MiddlewareChain(middleware: middleware)
    }

    /// Specialized overload for middleware that works with tuple inputs containing three elements.
    ///
    /// This method helps the compiler resolve type information for more complex middleware inputs.
    ///
    /// - Parameter middleware: The middleware with a three-element tuple input.
    /// - Returns: A middleware chain wrapping the input middleware.
    public static func buildExpression<I: Middleware, T1, T2, T3>(
        _ middleware: I
    ) -> MiddlewareChain<I.Input, I.NextInput> where I.Input == (T1, T2, T3) {
        MiddlewareChain(middleware: middleware)
    }

    /// Specialized overload for middleware that works with tuple inputs containing a function.
    ///
    /// This method helps the compiler resolve type information for middleware that processes
    /// function parameters as part of their input tuple.
    ///
    /// - Parameter middleware: The middleware with a function-containing tuple input.
    /// - Returns: A middleware chain wrapping the input middleware.
    public static func buildExpression<I: Middleware, T1, T2, Param, Result>(
        _ middleware: I
    ) -> MiddlewareChain<I.Input, I.NextInput> where I.Input == (T1, T2, (Param) async throws -> Result) {
        MiddlewareChain(middleware: middleware)
    }

    /// Handles optional middleware components in the chain.
    ///
    /// This method allows for conditional inclusion of middleware components through
    /// optional values, enabling dynamic middleware chains.
    ///
    /// - Parameter component: An optional middleware chain component.
    /// - Returns: The input component, preserving its optional nature.
    public static func buildOptional<Input, NextInput>(
        _ component: MiddlewareChain<Input, NextInput>?
    ) -> MiddlewareChain<Input, NextInput>? {
        component
    }

    /// Handles the "then" branch of conditional middleware inclusion.
    ///
    /// This method supports `if`/`else` conditions in the middleware chain builder DSL.
    ///
    /// - Parameter component: The middleware chain from the "then" branch.
    /// - Returns: The provided middleware chain.
    public static func buildEither<Input, NextInput>(
        first component: MiddlewareChain<Input, NextInput>
    ) -> MiddlewareChain<Input, NextInput> {
        component
    }

    /// Handles the "else" branch of conditional middleware inclusion.
    ///
    /// This method supports `if`/`else` conditions in the middleware chain builder DSL.
    ///
    /// - Parameter component: The middleware chain from the "else" branch.
    /// - Returns: The provided middleware chain.
    public static func buildEither<Input, NextInput>(
        second component: MiddlewareChain<Input, NextInput>
    ) -> MiddlewareChain<Input, NextInput> {
        component
    }
}
