/// A protocol that represents an asynchronous reader capable of reading elements from some source.
///
/// ``AsyncReader`` defines an interface for types that can asynchronously read elements
/// of a specified type from a source.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public protocol AsyncReader<ReadElement, ReadFailure> {
    /// The type of elements that can be read by this reader.
    associatedtype ReadElement: ~Copyable, ~Escapable

    /// The type of error that can be thrown during reading operations.
    associatedtype ReadFailure: Error

    /// Reads an element from the underlying source and processes it with the provided body function.
    ///
    /// This method asynchronously reads an element from whatever source the reader
    /// represents, then passes it to the provided body function. The operation may complete immediately
    /// or may await resources or processing time.
    ///
    /// - Parameter body: A function that consumes the read element and performs some operation
    ///   on it, returning a value of type `Return`. When the element is `nil`, it indicates that
    ///   this is a terminal value, signaling the end of the reading operation or stream.
    ///
    /// - Returns: The value returned by the body function after processing the read element.
    ///
    /// - Throws: An error of type `ReadFailure` if the read operation cannot be completed successfully.
    ///
    /// - Note: This method is marked as `mutating` because reading operations often change the internal
    ///   state of the reader.
    ///
    /// ```swift
    /// var fileReader: FileAsyncReader = ...
    ///
    /// // Read data from a file asynchronously and process it
    /// let result = try await fileReader.read { data in
    ///     guard let data else {
    ///         // Handle end of stream/terminal value
    ///         return finalProcessedValue
    ///     }
    ///     // Process the non-nil data
    ///     return processedValue
    /// }
    /// ```
    mutating func read<Return>(
        body: (consuming ReadElement?) async throws -> Return
    ) async throws(ReadFailure) -> Return
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension AsyncReader {
    /// Collects elements from the reader up to a specified limit and processes them with a body function.
    ///
    /// This method continuously reads elements from the async reader, accumulating them in a buffer
    /// until either the end of the stream is reached (indicated by a `nil` element) or the specified
    /// limit is exceeded. Once collection is complete, the accumulated elements are passed to the
    /// provided body function as a `Span` for processing.
    ///
    /// - Parameters:
    ///   - limit: The maximum number of elements to collect before throwing a `LimitExceeded` error.
    ///     This prevents unbounded memory growth when reading from potentially infinite streams.
    ///   - body: A closure that receives a `Span` containing all collected elements and returns
    ///     a result of type `Result`. This closure is called once after all elements have been
    ///     collected successfully.
    ///
    /// - Returns: The value returned by the body closure after processing the collected elements.
    ///
    /// - Throws:
    ///   - `LimitExceeded` if the number of elements exceeds the specified limit before the stream ends.
    ///   - Any error thrown by the underlying read operations or the body closure.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var reader: SomeAsyncReader = ...
    ///
    /// let processedData = try await reader.collect(upTo: 1000) { span in
    ///     // Process all collected elements
    /// }
    /// ```
    ///
    /// ## Memory Considerations
    ///
    /// Since this method buffers all elements in memory before processing, it should be used
    /// with caution on large datasets. The `limit` parameter serves as a safety mechanism
    /// to prevent excessive memory usage.
    public consuming func collect<Result>(
        upTo limit: Int,
        body: (Span<ReadElement>) async throws -> Result
    ) async throws -> Result where ReadElement: Copyable {
        var buffer = [ReadElement]()
        var shouldContinue = true
        while shouldContinue {
            try await self.read { element in
                guard let element else {
                    shouldContinue = false
                    return
                }
                guard buffer.count < limit else {
                    throw LimitExceeded()
                }
                buffer.append(element)
            }
        }
        return try await body(buffer.span)
    }

    /// Collects elements from the reader up to a specified limit and processes them with a body function.
    ///
    /// This method continuously reads elements from the async reader, accumulating them in a buffer
    /// until either the end of the stream is reached (indicated by a `nil` element) or the specified
    /// limit is exceeded. Once collection is complete, the accumulated elements are passed to the
    /// provided body function as a `Span` for processing.
    ///
    /// - Parameters:
    ///   - limit: The maximum number of elements to collect before throwing a `LimitExceeded` error.
    ///     This prevents unbounded memory growth when reading from potentially infinite streams.
    ///   - body: A closure that receives a `Span` containing all collected elements and returns
    ///     a result of type `Result`. This closure is called once after all elements have been
    ///     collected successfully.
    ///
    /// - Returns: The value returned by the body closure after processing the collected elements.
    ///
    /// - Throws:
    ///   - `LimitExceeded` if the number of elements exceeds the specified limit before the stream ends.
    ///   - Any error thrown by the underlying read operations or the body closure.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var reader: SomeAsyncReader = ...
    ///
    /// let processedData = try await reader.collect(upTo: 1000) { span in
    ///     // Process all collected elements
    /// }
    /// ```
    ///
    /// ## Memory Considerations
    ///
    /// Since this method buffers all elements in memory before processing, it should be used
    /// with caution on large datasets. The `limit` parameter serves as a safety mechanism
    /// to prevent excessive memory usage.
    public consuming func collect<Element, Result>(
        upTo limit: Int,
        body: (Span<Element>) async throws -> Result
    ) async throws -> Result where ReadElement == Span<Element> {
        var buffer = [Element]()
        var shouldContinue = true
        while shouldContinue {
            try await self.read { span in
                guard let span else {
                    shouldContinue = false
                    return
                }
                guard (buffer.count + span.count) < limit else {
                    throw LimitExceeded()
                }

                buffer.reserveCapacity(span.count)
                for index in span.indices {
                    buffer.append(span[index])
                }
            }
        }
        return try await body(buffer.span)
    }
}
