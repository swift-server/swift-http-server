public import HTTPTypes

/// This type ensures that a single `HTTPResponse` is sent back to the client when handling a request with
/// ``Server/serve(logger:configuration:handler:)-(_,_,RequestHandler)`` or ``Server/serve(logger:configuration:handler:)-(_,_,(HTTPRequest,HTTPRequestConcludingAsyncReader,HTTPResponseSender<HTTPResponseConcludingAsyncWriter>)->Void)``.
///
/// The user will get a ``HTTPResponseSender`` as part of the handler, and they will only be allowed to call ``sendResponse(_:)``
/// once before the sender is consumed and cannot be referenced again. This forces structure in the response flow, requiring users to
/// send a single response before they can stream a response body and trailers using the returned `ResponseWriter`.
public struct HTTPResponseSender<ResponseWriter: ConcludingAsyncWriter & ~Copyable>: ~Copyable {
    private let _sendResponse: (HTTPResponse) async throws -> ResponseWriter

    package init(
        _ sendResponse: @escaping (HTTPResponse) async throws -> ResponseWriter
    ) {
        self._sendResponse = sendResponse
    }
    
    /// Send the given `HTTPResponse` and get back a `ResponseWriter` to which to write a response body and trailers.
    /// - Parameter response: The `HTTPResponse` to send back to the client.
    /// - Returns: The `ResponseWriter` to which to write a response body and trailers.
    consuming public func sendResponse(_ response: HTTPResponse) async throws -> ResponseWriter {
        try await self._sendResponse(response)
    }
}

@available(*, unavailable)
extension HTTPResponseSender: Sendable {}
