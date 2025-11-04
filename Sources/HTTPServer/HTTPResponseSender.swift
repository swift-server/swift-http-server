public import HTTPTypes

/// This type ensures that a single non-informational (1xx) `HTTPResponse` is sent back to the client when handling a request.
///
/// The user will get a ``HTTPResponseSender`` as part of
/// ``HTTPServerRequestHandler/handle(request:requestBodyAndTrailers:responseSender:)``, and they
/// will only be allowed to call ``sendResponse(_:)`` once before the sender is consumed and cannot be referenced again.
///
/// This forces structure in the response flow, requiring users to send a single response before they can stream a response body and
/// trailers using the returned `ResponseWriter`.
public struct HTTPResponseSender<ResponseWriter: ConcludingAsyncWriter & ~Copyable>: ~Copyable {
    private let _sendInformationalResponse: ((HTTPResponse) async throws -> ())?

    private let _sendResponse: (HTTPResponse) async throws -> ResponseWriter

    public init(
        _ sendResponse: @escaping (HTTPResponse) async throws -> ResponseWriter,
        _ sendInformationalResponse: ((HTTPResponse) async throws -> ())? = nil
    ) {
        self._sendResponse = sendResponse
        self._sendInformationalResponse = sendInformationalResponse
    }
    
    /// Send the given `HTTPResponse` and get back a `ResponseWriter` to which to write a response body and trailers.
    /// - Parameter response: The final `HTTPResponse` to send back to the client.
    /// - Returns: The `ResponseWriter` to which to write a response body and trailers.
    /// - Important: Note this method is consuming: after you send this response, you won't be able to send any more responses.
    ///             If you need to send an informational (1xx) response, use ``sendInformationalResponse(_:)`` instead.
    consuming public func sendResponse(_ response: HTTPResponse) async throws -> ResponseWriter {
        precondition(response.status.kind != .informational)
        return try await self._sendResponse(response)
    }
    
    /// Send the given informational (1xx) response.
    /// - Parameter response: An informational `HTTPResponse` to send back to the client.
    public func sendInformationalResponse(_ response: HTTPResponse) async throws {
        guard let _sendInformationalResponse else { return }
        precondition(response.status.kind == .informational)
        return try await _sendInformationalResponse(response)
    }
}

@available(*, unavailable)
extension HTTPResponseSender: Sendable {}
