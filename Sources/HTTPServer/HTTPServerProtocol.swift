public import HTTPTypes

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
/// A generic HTTP server protocol that can handle incoming HTTP requests.
public protocol HTTPServerProtocol: Sendable, ~Copyable, ~Escapable {
    // TODO: write down in the proposal why we can't make the serve method generic over the handler (closure-based APIs can't
    // be implemented)

    /// The ``HTTPServerRequestHandler`` to use when handling requests.
    associatedtype RequestHandler: HTTPServerRequestHandler

    /// Starts an HTTP server with the specified request handler.
    ///
    /// This method creates and runs an HTTP server that processes incoming requests using the provided
    /// ``HTTPServerRequestHandler`` implementation.
    ///
    /// Implementations of this method should handle each connection concurrently using Swift's structured concurrency.
    ///
    /// - Parameters:
    ///   - handler: A ``HTTPServerRequestHandler`` implementation that processes incoming HTTP requests. The handler
    ///     receives each request along with a body reader and ``HTTPResponseSender``.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct EchoHandler: HTTPServerRequestHandler {
    ///     func handle(
    ///         request: HTTPRequest,
    ///         requestBodyAndTrailers: consuming HTTPRequestConcludingAsyncReader,
    ///         responseSender: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ///     ) async throws {
    ///         let response = HTTPResponse(status: .ok)
    ///         let writer = try await responseSender.send(response)
    ///         // Handle request and write response...
    ///     }
    /// }
    ///
    /// let server = // create an instance of a type conforming to the `ServerProtocol`
    ///
    /// try await server.serve(handler: EchoHandler())
    /// ```
    func serve(handler: RequestHandler) async throws
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension HTTPServerProtocol where RequestHandler == HTTPServerClosureRequestHandler<HTTPRequestConcludingAsyncReader, HTTPResponseConcludingAsyncWriter> {
    /// Starts an HTTP server with a closure-based request handler.
    ///
    /// This method provides a convenient way to start an HTTP server using a closure to handle incoming requests.
    ///
    /// - Parameters:
    ///   - handler: An async closure that processes HTTP requests. The closure receives:
    ///     - `HTTPRequest`: The incoming HTTP request with headers and metadata
    ///     - ``HTTPRequestConcludingAsyncReader``: An async reader for consuming the request body and trailers
    ///     - ``HTTPResponseSender``: A non-copyable wrapper for a function that accepts an `HTTPResponse` and provides access to an ``HTTPResponseConcludingAsyncWriter``
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await server.serve { request, bodyReader, sendResponse in
    ///     // Process the request
    ///     let response = HTTPResponse(status: .ok)
    ///     let writer = try await sendResponse(response)
    ///     try await writer.produceAndConclude { writer in
    ///         try await writer.write("Hello, World!".utf8)
    ///         return ((), nil)
    ///     }
    /// }
    /// ```
    public func serve(
        handler: nonisolated(nonsending) @Sendable @escaping (
            _ request: HTTPRequest,
            _ requestBodyAndTrailers: consuming sending HTTPRequestConcludingAsyncReader,
            _ responseSender: consuming sending HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
        ) async throws -> Void
    ) async throws {
        try await self.serve(handler: HTTPServerClosureRequestHandler(handler: handler))
    }
}
