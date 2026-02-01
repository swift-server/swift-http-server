//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public import AsyncStreaming
public import HTTPTypes
import NIOCore
import NIOHTTPTypes
import Synchronization

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
        /// The type of elements this reader provides.
        public typealias ReadElement = UInt8

        /// The type of errors that can occur during reading operations.
        public typealias ReadFailure = any Error

        /// The HTTP trailer fields captured at the end of the request.
        fileprivate var state: ReaderState

        struct RequestBodyStateMachine {
            enum State {
                // The request body is currently being read: expecting more request body parts or a request end part.
                case readingBody(ReadingBodyState)

                // The request end part was received. We have finished.
                case finished

                enum ReadingBodyState {
                    // Not yet received any request body parts
                    case initial

                    // `read` was called with a `maximumCount` value that was lower than the bytes available. The excess
                    // bytes are stored here so they can be dispensed in future calls to `read`.
                    case excess(ByteBuffer)

                    // No excess bytes currently needing to be stored
                    case noExcess
                }
            }

            private var state: State

            /// The iterator that provides HTTP request parts from the underlying channel.
            private var iterator: NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator

            init(iterator: NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator) {
                self.state = .readingBody(.initial)
                self.iterator = iterator
            }

            enum ReadResult {
                case readBody(ByteBuffer)
                case readEnd(HTTPFields?)
                case streamFinished
            }

            mutating func read(limit: Int?) async throws -> ReadResult {
                switch self.state {
                case .readingBody(let readingBodyState):
                    var bodyElement: ByteBuffer

                    switch readingBodyState {
                    case .excess(let excessElement):
                        // There was an excess of bytes from the previous call to `read`. We read directly from this
                        // excess and don't advance the iterator.
                        bodyElement = excessElement

                    case .initial, .noExcess:
                        // There is no excess from previous reads. We obtain the next element from the stream.
                        let requestPart = try await self.iterator.next(isolation: #isolation)

                        switch requestPart {
                        case .head:
                            fatalError("Unexpectedly received a request head.")

                        case .none:
                            fatalError("The stream unexpectedly ended before receiving a request end.")

                        case .body(let element):
                            bodyElement = element

                        case .end(let trailers):
                            self.state = .finished
                            return .readEnd(trailers)
                        }
                    }

                    if let limit, limit < bodyElement.readableBytes,
                        let truncated = bodyElement.readSlice(length: limit)
                    {
                        // There are more bytes available than `limit`. We must store the excess in a buffer for it to
                        // be consumed in the next call to `read`.
                        self.state = .readingBody(.excess(bodyElement))
                        return .readBody(truncated)
                    }

                    self.state = .readingBody(.noExcess)
                    return .readBody(bodyElement)

                case .finished:
                    return .streamFinished
                }
            }
        }

        var requestBodyStateMachine: RequestBodyStateMachine

        /// Initializes a new request body reader with the given NIO async channel iterator.
        ///
        /// - Parameter iterator: The NIO async channel inbound stream iterator to use for reading request parts.
        fileprivate init(
            iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
            readerState: ReaderState
        ) {
            self.requestBodyStateMachine = .init(iterator: iterator)
            self.state = readerState
        }

        /// Reads a chunk of request body data.
        ///
        /// - Parameter body: A function that consumes the read element (or nil for end of stream)
        ///                  and returns a value of type `Return`.
        /// - Returns: The value returned by the body function after processing the read element.
        /// - Throws: An error if the reading operation fails.
        public mutating func read<Return, Failure: Error>(
            maximumCount: Int?,
            body: nonisolated(nonsending) (consuming Span<ReadElement>) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            let readResult: RequestBodyStateMachine.ReadResult
            do {
                readResult = try await self.requestBodyStateMachine.read(limit: maximumCount)
            } catch {
                throw .first(error)
            }

            do {
                switch readResult {
                case .readBody(let readElement):
                    return try await body(Array(buffer: readElement).span)

                case .readEnd(let trailers):
                    self.state.wrapped.withLock { state in
                        state.trailers = trailers
                        state.finishedReading = true
                    }
                    return try await body(.init())

                case .streamFinished:
                    return try await body(.init())
                }
            } catch {
                throw .second(error)
            }
        }
    }

    final class ReaderState: Sendable {
        struct Wrapped {
            var trailers: HTTPFields? = nil
            var finishedReading: Bool = false
        }

        let wrapped: Mutex<Wrapped>

        init() {
            self.wrapped = .init(.init())
        }
    }

    /// The underlying reader type for the HTTP request body.
    public typealias Underlying = RequestBodyAsyncReader

    /// The type of the final element produced after all reads are completed (optional HTTP trailer fields).
    public typealias FinalElement = HTTPFields?

    /// The type of errors that can occur during reading operations.
    public typealias Failure = any Error

    private var iterator: NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?

    internal var state: ReaderState

    /// Initializes a new HTTP request body and trailers reader with the given NIO async channel iterator.
    ///
    /// - Parameter iterator: The NIO async channel inbound stream iterator to use for reading request parts.
    init(
        iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator,
        readerState: ReaderState
    ) {
        self.iterator = iterator
        self.state = readerState
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
    public consuming func consumeAndConclude<Return, Failure: Error>(
        body: nonisolated(nonsending) (consuming sending RequestBodyAsyncReader) async throws(Failure) -> Return
    ) async throws(Failure) -> (Return, HTTPFields?) {
        if let iterator = self.iterator.sendingTake() {
            let partsReader = RequestBodyAsyncReader(iterator: iterator, readerState: self.state)
            let result = try await body(partsReader)
            let trailers = self.state.wrapped.withLock { $0.trailers }
            return (result, trailers)
        } else {
            fatalError("consumeAndConclude called more than once")
        }
    }
}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader: Sendable {}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader.RequestBodyAsyncReader: Sendable {}

extension Optional {
    mutating func sendingTake() -> sending Self {
        let result = consume self
        self = nil
        return result
    }
}
