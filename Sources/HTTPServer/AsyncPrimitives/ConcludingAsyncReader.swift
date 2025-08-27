/// A protocol that represents an asynchronous reader that produces elements and concludes with a final value.
///
/// ``ConcludingAsyncReader`` adds functionality to asynchronous readers that need to
/// provide a conclusive element after all reads are completed. This is particularly useful
/// for streams that have meaningful completion states beyond just terminating, such as
/// HTTP responses that include headers after the body is fully read.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol ConcludingAsyncReader<Underlying, FinalElement>: ~Copyable {
    /// The underlying asynchronous reader type that produces elements.
    associatedtype Underlying: AsyncReader, ~Copyable, ~Escapable

    /// The type of the final element produced after all reads are completed.
    associatedtype FinalElement

    /// Processes the underlying async reader until completion and returns both the result of processing
    /// and a final element.
    ///
    /// - Parameter body: A closure that takes the underlying `AsyncReader` and returns a value.
    /// - Returns: A tuple containing the value returned by the body closure and the final element.
    /// - Throws: Any error thrown by the body closure or encountered while processing the reader.
    ///
    /// - Note: This method consumes the concluding async reader, meaning it can only be called once on a value type.
    ///
    /// ```swift
    /// let responseReader: HTTPResponseReader = ...
    ///
    /// // Process the body while capturing the final response status
    /// let (bodyData, statusCode) = try await responseReader.consumeAndConclude { reader in
    ///     var collectedData = Data()
    ///     while let chunk = try await reader.read(body: { $0 }) {
    ///         collectedData.append(chunk)
    ///     }
    ///     return collectedData
    /// }
    /// ```
    consuming func consumeAndConclude<Return>(
        body: (consuming Underlying) async throws -> Return
    ) async throws -> (Return, FinalElement)
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension ConcludingAsyncReader where Self: ~Copyable {
    /// Processes the underlying async reader until completion and returns only the final element.
    ///
    /// This is a convenience method when the body's return value is `Void` and only returns the final element.
    ///
    /// - Parameter body: A closure that takes the underlying `AsyncReader`.
    /// - Returns: The final element produced after all reads are completed.
    /// - Throws: Any error thrown by the body closure or encountered while processing the reader.
    ///
    /// - Note: This method consumes the concluding async reader, meaning it can only be called once on a value type.
    ///
    /// ```swift
    /// let responseReader: HTTPResponseReader = ...
    ///
    /// // Process the body but only capture the final response status
    /// let statusCode = try await responseReader.consumeAndConclude { reader in
    ///     while let chunk = try await reader.read(body: { $0 }) {
    ///         // Process chunks but don't collect them
    ///         print("Received chunk of size: \(chunk.count)")
    ///     }
    /// }
    /// ```
    public consuming func consumeAndConclude(
        body: (consuming Underlying) async throws -> Void
    ) async throws -> FinalElement {
        let (_, finalElement) = try await self.consumeAndConclude { reader in
            try await body(reader)
        }
        return finalElement
    }

    /// Collects elements from the underlying async reader and returns both the processed result and final element.
    ///
    /// This method provides a convenient way to collect elements from the underlying reader while
    /// capturing both the processing result and the final element that concludes the reading operation.
    /// It combines the functionality of ``AsyncReader/collect(upTo:body:)-(_,(Span<Element>) -> Result)`` from ``AsyncReader`` with the concluding
    /// behavior of ``ConcludingAsyncReader``.
    ///
    /// - Parameter limit: The maximum number of elements to collect before throwing a `LimitExceeded` error.
    /// - Parameter body: A closure that processes the collected elements as a `Span` and returns a result.
    ///
    /// - Returns: A tuple containing the result from processing the collected elements and the final element.
    ///
    /// - Throws:
    ///   - `LimitExceeded` if the number of elements exceeds the specified limit.
    ///   - Any error thrown by the body closure or the underlying read operations.
    ///
    /// ```swift
    /// let responseReader: HTTPConcludingReader = ...
    ///
    /// // Collect response data and get final headers
    /// let (processedData, finalHeaders) = try await responseReader.collect(upTo: 1024 * 1024) { span in
    ///     // Process all collected elements
    /// }
    /// ```
    public consuming func collect<Result>(
        upTo limit: Int,
        body: (Span<Underlying.ReadElement>) async throws -> Result
    ) async throws -> (Result, FinalElement) where Underlying.ReadElement: Copyable {
        try await self.consumeAndConclude { reader in
            var reader = reader
            return try await reader.collect(upTo: limit) { span in
                try await body(span)
            }
        }
    }

    /// Collects elements from the underlying async reader and returns both the processed result and final element.
    ///
    /// This method provides a convenient way to collect elements from the underlying reader while
    /// capturing both the processing result and the final element that concludes the reading operation.
    /// It combines the functionality of ``AsyncReader/collect(upTo:body:)-(_,(Span<Element>) -> Result)`` from ``AsyncReader`` with the concluding
    /// behavior of ``ConcludingAsyncReader``.
    ///
    /// - Parameter limit: The maximum number of elements to collect before throwing a `LimitExceeded` error.
    /// - Parameter body: A closure that processes the collected elements as a `Span` and returns a result.
    ///
    /// - Returns: A tuple containing the result from processing the collected elements and the final element.
    ///
    /// - Throws:
    ///   - `LimitExceeded` if the number of elements exceeds the specified limit.
    ///   - Any error thrown by the body closure or the underlying read operations.
    ///
    /// ```swift
    /// let responseReader: HTTPConcludingReader = ...
    ///
    /// // Collect response data and get final headers
    /// let (processedData, finalHeaders) = try await responseReader.collect(upTo: 1024 * 1024) { span in
    ///     // Process all collected elements
    /// }
    /// ```
    public consuming func collect<Element, Result>(
        upTo limit: Int,
        body: (Span<Element>) async throws -> Result
    ) async throws -> (Result, FinalElement) where Underlying.ReadElement == Span<Element> {
        try await self.consumeAndConclude { reader in
            var reader = reader
            return try await reader.collect(upTo: limit) { span in
                try await body(span)
            }
        }
    }
}
