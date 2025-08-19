public import HTTPTypes
import NIOCore
import NIOHTTPTypes

/// A specialized reader for HTTP request bodies and trailers that manages the reading process
/// and captures the final trailer fields.
///
/// ``HTTPRequestConcludingAsyncReader`` enables reading request body chunks incrementally
/// and concluding with the HTTP trailer fields received at the end of the request. This type
/// follows the ``ConcludingAsyncReader`` pattern, which allows for asynchronous consumption of
/// a stream with a conclusive final element.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct HTTPRequestConcludingAsyncReader: ConcludingAsyncReader, ~Copyable {
    /// A reader for HTTP request body chunks that implements the ``AsyncReader`` protocol.
    ///
    /// This reader processes the body parts of an HTTP request and provides them as spans of bytes,
    /// while also capturing any trailer fields received at the end of the request.
    public struct RequestBodyAsyncReader: AsyncReader, ~Copyable {
        /// The type of elements this reader provides (byte spans representing body chunks).
        public typealias ReadElement = Span<UInt8>

        /// The type of errors that can occur during reading operations.
        public typealias ReadFailure = any Error

        /// The HTTP trailer fields captured at the end of the request.
        fileprivate var state: ReaderState?

        /// The iterator that provides HTTP request parts from the underlying channel.
        private var iterator: NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator

        /// Initializes a new request body reader with the given NIO async channel iterator.
        ///
        /// - Parameter iterator: The NIO async channel inbound stream iterator to use for reading request parts.
        fileprivate init(
            iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator
        ) {
            self.iterator = iterator
        }

        /// Reads a chunk of request body data.
        ///
        /// - Parameter body: A function that consumes the read element (or nil for end of stream)
        ///                  and returns a value of type `Return`.
        /// - Returns: The value returned by the body function after processing the read element.
        /// - Throws: An error if the reading operation fails.
        public mutating func read<Return>(
            body: (consuming ReadElement?) async throws -> Return
        ) async throws(ReadFailure) -> Return {
            switch try await self.iterator.next(isolation: #isolation) {
            case .head:
                fatalError()
            case .body(let element):
                // TODO: Add ByteBuffer span interfaces
                return try await body(Array(buffer: element).span)
            case .end(let trailers):
                self.state?.trailers = trailers
                self.state?.finishedReading = true
                return try await body(nil)
            case .none:
                return try await body(nil)
            }
        }
    }

    final class ReaderState {
        var trailers: HTTPFields? = nil
        var finishedReading: Bool = false
    }

    /// The underlying reader type for the HTTP request body.
    public typealias Underlying = RequestBodyAsyncReader

    /// The type of the final element produced after all reads are completed (optional HTTP trailer fields).
    public typealias FinalElement = HTTPFields?

    /// The type of errors that can occur during reading operations.
    public typealias Failure = any Error

    /// The internal reader that provides HTTP request parts from the underlying channel.
    private var partsReader: RequestBodyAsyncReader

    fileprivate let readerState: ReaderState

    /// Initializes a new HTTP request body and trailers reader with the given NIO async channel iterator.
    ///
    /// - Parameter iterator: The NIO async channel inbound stream iterator to use for reading request parts.
    init(
        iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
        readerState: ReaderState
    ) {
        self.partsReader = RequestBodyAsyncReader(iterator: iterator)
        self.readerState = readerState
    }

    /// Processes the request body reading operation and captures the final trailer fields.
    ///
    /// This method provides a request body reader to the given closure, allowing it to read
    /// chunks of the request body incrementally. Once the closure completes, the method returns
    /// both the result from the closure and any trailer fields that were received at the end
    /// of the HTTP request.
    ///
    /// - Parameter body: A closure that takes a request body reader and returns a result value.
    /// - Returns: A tuple containing the value returned by the body closure and the HTTP trailer fields (if any).
    /// - Throws: Any error encountered during the reading process.
    ///
    /// - Example:
    /// ```swift
    /// let requestReader: HTTPRequestConcludingAsyncReader = ...
    ///
    /// let (bodyData, trailers) = try await requestReader.consumeAndConclude { reader in
    ///     var collectedData = [UInt8]()
    ///
    ///     // Read chunks until end of stream
    ///     while let chunk = try await reader.read(body: { $0 }) {
    ///         collectedData.append(contentsOf: chunk)
    ///     }
    ///     return collectedData
    /// }
    /// ```
    public consuming func consumeAndConclude<Return>(
        body: (consuming RequestBodyAsyncReader) async throws -> Return
    ) async throws -> (Return, HTTPFields?) {
        self.partsReader.state = self.readerState
        let result = try await body(self.partsReader)
        return (result, self.readerState.trailers)
    }
}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader: Sendable {}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader.RequestBodyAsyncReader: Sendable {}
