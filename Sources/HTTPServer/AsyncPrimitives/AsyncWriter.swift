/// A protocol that represents an asynchronous writer capable of writing elements to some destination.
///
/// ``AsyncWriter`` defines an interface for types that can asynchronously write elements
/// of a specified type to a destination.
public protocol AsyncWriter<WriteElement, WriteFailure>: ~Copyable {
    /// The type of elements that can be written by this writer.
    associatedtype WriteElement: ~Copyable, ~Escapable

    /// The type of error that can be thrown during writing operations.
    associatedtype WriteFailure: Error

    /// Writes the provided element to the underlying destination.
    ///
    /// This method asynchronously writes the given element to whatever destination the writer
    /// represents. The operation may complete immediately or may await resources or processing time.
    ///
    /// - Parameter element: The element to write. This typically represents a single item or a collection
    ///   of items depending on the specific writer implementation.
    ///
    /// - Throws: An error of type `WriteFailure` if the write operation cannot be completed successfully.
    ///
    /// - Note: This method is marked as `mutating` because writing operations often change the internal
    ///   state of the writer.
    ///
    /// ```swift
    /// var fileWriter: FileAsyncWriter = ...
    ///
    /// // Write data to a file asynchronously
    /// try await fileWriter.write(dataChunk)
    /// ```
    mutating func write(_ element: consuming WriteElement) async throws(WriteFailure)
}
