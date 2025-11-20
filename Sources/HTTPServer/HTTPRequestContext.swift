/// A context object that carries additional information about an HTTP request.
///
/// `HTTPRequestContext` provides a way to pass metadata and implementation-specific
/// information through the HTTP request pipeline. This is particularly useful when
/// you need to attach custom data that should be available throughout the request's
/// lifecycle.
///
/// ## Implementation-Specific Data
///
/// Different server implementations can store their own specific data by conforming to the
/// ``ImplementationSpecific`` protocol:
///
/// ```swift
/// struct MyCustomContext: HTTPRequestContext.ImplementationSpecific {
///     let requestID: UUID
///     let startTime: Date
/// }
///
/// var context = HTTPRequestContext()
/// context.implementationSpecific = MyCustomContext(
///     requestID: UUID(),
///     startTime: Date()
/// )
/// ```
public struct HTTPRequestContext: Sendable {

    /// Conform your custom types to this protocol to store implementation-specific
    /// data within an ``HTTPRequestContext``.
    public protocol ImplementationSpecific: Sendable {}

    /// Optional implementation-specific data associated with this request context.
    ///
    /// Use this property to store custom data that is specific to your HTTP
    /// implementation. The stored value can be any type that conforms to
    /// ``ImplementationSpecific``.
    public var implementationSpecific: (any ImplementationSpecific)?
}
