public import HTTPTypes

/// A closure-based implementation of ``HTTPServerRequestHandler``.
///
/// ``HTTPServerClosureRequestHandler`` provides a convenient way to create an HTTP request handler
/// using a closure instead of conforming a custom type to the ``HTTPServerRequestHandler`` protocol.
/// This is useful for simple handlers or when you need to create handlers dynamically.
///
/// - Example:
/// ```swift
/// let echoHandler = HTTPServerClosureRequestHandler { request, bodyReader, sendResponse in
///     // Read the entire request body
///     let (bodyData, _) = try await bodyReader.consumeAndConclude { reader in
///         // ... body reading code ...
///     }
///
///     // Create and send response
///     var response = HTTPResponse(status: .ok)
///     let responseWriter = try await sendResponse(response)
///     try await responseWriter.produceAndConclude { writer in
///         try await writer.write(bodyData.span)
///         return ((), nil)
///     }
/// }
/// ```
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct HTTPServerClosureRequestHandler: HTTPServerRequestHandler {
    /// The underlying closure that handles HTTP requests
    private let _handler:
        nonisolated(nonsending) @Sendable (
            HTTPRequest,
            consuming HTTPRequestConcludingAsyncReader,
            consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
        ) async throws -> Void

    /// Creates a new closure-based HTTP request handler.
    ///
    /// - Parameter handler: A closure that will be called to handle each incoming HTTP request.
    ///   The closure takes the same parameters as the ``HTTPServerRequestHandler/handle(request:requestConcludingAsyncReader:sendResponse:)`` method.
    public init(
        handler: nonisolated(nonsending) @Sendable @escaping (
            HTTPRequest,
            consuming HTTPRequestConcludingAsyncReader,
            consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
        ) async throws -> Void
    ) {
        self._handler = handler
    }

    /// Handles an incoming HTTP request by delegating to the closure provided at initialization.
    ///
    /// This method simply forwards all parameters to the handler closure.
    ///
    /// - Parameters:
    ///   - request: The HTTP request headers and metadata.
    ///   - requestConcludingAsyncReader: A reader for accessing the request body data and trailing headers.
    ///   - sendResponse: A callback function to send the HTTP response.
    public func handle(
        request: HTTPRequest,
        requestConcludingAsyncReader: consuming HTTPRequestConcludingAsyncReader,
        sendResponse: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ) async throws {
        try await self._handler(request, requestConcludingAsyncReader, sendResponse)
    }
}
