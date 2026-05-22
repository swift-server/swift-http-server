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
public import BasicContainers
public import HTTPAPIs
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
@available(anyAppleOS 26.0, *)
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

        /// The buffer type used to hand elements to the caller.
        public typealias Buffer = UniqueArray<UInt8>

        /// The HTTP trailer fields captured at the end of the request.
        fileprivate var state: ReaderState

        /// The iterator that provides HTTP request parts from the underlying channel.
        /// Taken from `state` at construction; returned to `state` when this reader
        /// observes request `.end` so the outer request loop can recover it for
        /// HTTP/1.1 keep-alive.
        private var iterator: NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?

        /// A reusable buffer handed to the body closure on each call to ``read(body:)``.
        /// Reusing it across calls preserves the allocation; the buffer is cleared
        /// (while keeping its capacity) at the start of every read.
        private var buffer: UniqueArray<UInt8>

        /// Initializes a new request body reader, taking the iterator from the
        /// shared `ReaderState`.
        fileprivate init(readerState: ReaderState) {
            self.state = readerState
            self.iterator = readerState.takeIterator()
            self.buffer = UniqueArray<UInt8>()
        }

        /// Reads a chunk of request body data.
        public mutating func read<Return: ~Copyable, Failure: Error>(
            body: nonisolated(nonsending) (inout Buffer) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            let requestPart: HTTPRequestPart?
            do {
                requestPart = try await self.iterator?.next(isolation: #isolation)
            } catch {
                throw .first(error)
            }

            self.buffer.removeAll(keepingCapacity: true)
            switch requestPart {
            case .head:
                fatalError()
            case .body(let element):
                self.buffer.reserveCapacity(element.readableBytes)
                self.buffer.append(copying: element.readableBytesUInt8Span)
            case .end(let trailers):
                // Move the iterator back into ReaderState so the outer request
                // loop can recover it for the next request on the same connection
                // (HTTP/1.1 keep-alive).
                nonisolated(unsafe) let iter = self.iterator.take()
                self.state.wrapped.withLock { state in
                    state.trailers = trailers
                    state.finishedReading = true
                    _ = state.iterator.swap(newValue: iter)
                }
            case .none:
                throw .first(RequestBodyReadError.streamEndedBeforeReceivingRequestEnd)
            }

            do {
                return try await body(&self.buffer)
            } catch {
                throw .second(error)
            }
        }
    }

    final class ReaderState: Sendable {
        struct Wrapped: ~Copyable {
            var trailers: HTTPFields? = nil
            var finishedReading: Bool = false

            /// The iterator. Initially populated from the channel; taken by the
            /// body reader at construction time and returned by it once request
            /// `.end` has been observed (for HTTP/1.1 keep-alive recovery).
            var iterator:
                Disconnected<
                    NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?
                >
        }

        let wrapped: Mutex<Wrapped>

        init(iterator: consuming sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator) {
            self.wrapped = .init(.init(iterator: Disconnected(value: iterator)))
        }

        /// Takes the iterator out of the state. Returns the iterator if present,
        /// or `nil` if it's already been taken (e.g. by the body reader).
        func takeIterator() -> sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator? {
            self.wrapped.withLock { state in
                state.iterator.swap(newValue: nil)
            }
        }
    }

    /// The underlying reader type for the HTTP request body.
    public typealias Underlying = RequestBodyAsyncReader

    /// The type of the final element produced after all reads are completed (optional HTTP trailer fields).
    public typealias FinalElement = HTTPFields?

    /// The type of errors that can occur during reading operations.
    public typealias Failure = any Error

    internal var state: ReaderState

    /// Initializes a new HTTP request body and trailers reader.
    ///
    /// - Parameter readerState: The shared reader state that holds the iterator and captures trailers.
    init(readerState: ReaderState) {
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
        let partsReader = RequestBodyAsyncReader(readerState: self.state)
        let result = try await body(partsReader)
        let trailers = self.state.wrapped.withLock { $0.trailers }
        return (result, trailers)
    }
}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader: Sendable {}

@available(*, unavailable)
extension HTTPRequestConcludingAsyncReader.RequestBodyAsyncReader: Sendable {}
