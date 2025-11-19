/// A protocol that defines the context for an HTTP request.
///
/// Conforming types represent contextual information that can be associated with
/// an HTTP request throughout its lifecycle.
public protocol HTTPRequestContext: Sendable {

}

/// The default implementation of an ``HTTPRequestContext`` for HTTP server requests.
///
/// This struct provides a concrete type for representing the context of HTTP requests
/// handled by a server.
public struct HTTPServerRequestContext: HTTPRequestContext {
    /// Creates a new HTTP server request context.
    public init() {}
}
