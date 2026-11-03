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

public import BasicContainers
import NIOCore
import NIOHTTPTypes
import Synchronization

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    public struct Reader: AsyncReader, ~Copyable {
        typealias Iterator = NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator

        /// The reader's state.
        enum State: ~Copyable {
            /// We are reading request body part(s) and waiting for the request `.end`.
            case reading(Reading)

            /// We have seen the request `.end` part.
            case finished

            /// The underlying stream ended or threw an error before request `.end` was observed.
            case failed(any Error)

            struct Reading: ~Copyable {
                var iterator: Iterator

                /// Records that we saw the request `.end`, and releases the iterator.
                var exchangeState: NIOHTTPServer.ExchangeState.RequestHandle
            }
        }

        public typealias ReadElement = UInt8

        public typealias Buffer = UniqueArray<UInt8>

        public typealias FinalElement = HTTPFields?

        public typealias ReadFailure = any Error

        private var state: State

        /// A reusable buffer handed to the body closure on each call to ``read(body:)``.
        /// Reusing it across calls preserves the allocation; the buffer is cleared
        /// (while keeping its capacity) at the start of every read.
        private var buffer: UniqueArray<UInt8>

        /// Initializes a new request body reader.
        ///
        /// - Parameters:
        ///   - iterator: The iterator that yields HTTP request parts.
        ///   - exchangeState: The reader's access to the request-response exchange state.
        init(
            iterator: consuming sending Iterator,
            exchangeState: consuming NIOHTTPServer.ExchangeState.RequestHandle
        ) {
            self.state = .reading(.init(iterator: iterator, exchangeState: exchangeState))
            self.buffer = UniqueArray<UInt8>()
        }

        #if HTTP3 && UnstableHTTPDatagrams
        /// The unreliable datagram reader, present when the underlying transport is capable of reading/writing
        /// unreliable datagrams.
        private var datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>?

        /// Initializes a new request body reader that can also vend an unreliable datagram reader if the underlying
        /// transport supports unreliable datagrams.
        init(
            iterator: consuming sending Iterator,
            exchangeState: consuming NIOHTTPServer.ExchangeState.RequestHandle,
            datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>?
        ) {
            self.init(iterator: iterator, exchangeState: exchangeState)
            self.datagramStreamFuture = datagramStreamFuture
        }
        #endif

        public mutating func read<Return: ~Copyable, Failure: Error>(
            body: (inout Buffer, consuming HTTPFields??) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            let requestPart: HTTPRequestPart
            do {
                requestPart = try await self.state.nextRequestPart(isolation: #isolation)
            } catch {
                throw .first(error)
            }

            let trailerFields: HTTPFields??
            self.buffer.removeAll(keepingCapacity: true)
            switch requestPart {
            case .head:
                fatalError()
            case .body(let element):
                self.buffer.reserveCapacity(element.readableBytes)
                self.buffer.append(copying: element.readableBytesUInt8Span)
                trailerFields = nil
            case .end(let trailer):
                trailerFields = trailer
            }

            do {
                return try await body(&self.buffer, trailerFields)
            } catch {
                throw .second(error)
            }
        }
    }
}

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer.Reader.State {
    /// Reads the next request part from the iterator and transitions the state accordingly.
    ///
    /// - Throws:
    ///   - ``RequestBodyReadError/readAfterRequestEnd`` if request `.end` has already been seen, or;
    ///   - ``RequestBodyReadError/streamEnded`` if the stream ends before request `.end`, or;
    ///   - the error thrown by the iterator.
    ///
    ///    Once in the failed state, every subsequent call rethrows the same error.
    mutating func nextRequestPart(isolation actor: isolated (any Actor)?) async throws -> HTTPRequestPart {
        switch consume self {
        case .reading(var reading):
            let requestPart: HTTPRequestPart?
            do {
                requestPart = try await reading.iterator.next(isolation: actor)
            } catch {
                self = .failed(error)
                throw error
            }

            guard let requestPart else {
                // The stream ended before we got a request end part.
                self = .failed(RequestBodyReadError.streamEnded)

                throw RequestBodyReadError.streamEnded
            }

            switch requestPart {
            case .head:
                // The head part should have already been read from the iterator before it was given to `Reader`.
                fatalError()

            case .body:
                self = .reading(reading)

            case .end:
                self = .finished

                // Record that we've finished reading. For an HTTP/1.1 exchange, this moves the iterator back into the
                // exchange state so the request loop can recover it for the next request on the same connection. For
                // other exchanges, it drops the iterator.
                nonisolated(unsafe) let iterator = reading.iterator
                unsafe reading.exchangeState.recordEnd(releasing: iterator)
            }
            return requestPart

        case .finished:
            self = .finished
            throw RequestBodyReadError.readAfterRequestEnd

        case .failed(let error):
            self = .failed(error)
            throw error
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.Reader: Sendable {}

#if HTTP3 && UnstableHTTPDatagrams
@available(anyAppleOS 27.0, *)
extension NIOHTTPServer.Reader {
    /// Returns the unreliable datagram reader for this stream, if both the server and the client have advertised
    /// support for receiving datagrams.
    ///
    /// - Note: This function will suspend until the server has received the SETTINGS frame from the client. This is
    ///   because the server must send _and_ receive the `SETTINGS_H3_DATAGRAMS` setting with value 1 before sending or
    ///   receiving unreliable datagrams. See https://datatracker.ietf.org/doc/html/rfc9297#section-2.1.1-3.
    ///
    /// - Important: This function can only be called once. Any successive calls will result in a runtime crash.
    public mutating func takeDatagramReader() async -> sending NIOHTTPServer.DatagramReader? {
        guard let streamFuture = self.datagramStreamFuture else {
            // The server did not advertise support for receiving datagrams.
            return nil
        }

        do {
            let stream = try await streamFuture.get()
            return NIOHTTPServer.DatagramReader(iterator: stream.inbound.makeAsyncIterator())
        } catch {
            // The peer did not agree to receiving datagrams.
            return nil
        }
    }
}
#endif  // HTTP3 && UnstableHTTPDatagrams
