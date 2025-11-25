public import HTTPTypes

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
/// A generic HTTP server protocol that can handle incoming HTTP requests.
public protocol HTTPServerProtocol: Sendable, ~Copyable, ~Escapable {
    // TODO: write down in the proposal we can't make the serve method generic over the handler
    // because otherwise, closure-based APIs can't be implemented.

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
