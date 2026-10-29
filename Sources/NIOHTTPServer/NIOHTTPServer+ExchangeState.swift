//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import Logging
import NIOCore
import NIOHTTPTypes
import Synchronization

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    /// The state of a request-response exchange.
    final class ExchangeState: Sendable {
        private struct Storage: ~Copyable {
            /// Whether the reader has observed the request `.end` part.
            var finishedReading: Bool = false

            /// Whether the response has been sent.
            var finishedWriting: Bool = false

            /// The request iterator, for HTTP/1.1 connection reuse. Stored here at the start of the request, and
            /// expected to be moved back once the request `.end` part has been read from the reader.
            var iterator: Disconnected<NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator?> = .init(value: nil)
        }

        private let storage: Mutex<Storage> = .init(.init())

        /// Whether the reader has seen the request `.end` part.
        var finishedReading: Bool {
            self.storage.withLock { $0.finishedReading }
        }

        /// Whether the response has been sent.
        var finishedWriting: Bool {
            self.storage.withLock { $0.finishedWriting }
        }

        /// Takes the iterator the reader, and resets the state so the next request on the connection can reuse it.
        ///
        /// - Returns: The iterator, or `nil` if the reader didn't see the request `.end` part, or the iterator has
        ///   already been taken. If `nil`, the connection cannot be reused for another request.
        func takeIterator() -> sending NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator? {
            self.storage.withLock {
                $0.finishedReading = false
                $0.finishedWriting = false
                return $0.iterator.swap(newValue: nil)
            }
        }

        /// The request reader's access to the request-response exchange state.
        struct RequestHandle: ~Copyable, Sendable {
            private let state: ExchangeState

            /// Whether to reuse the request iterator. This is exclusively for HTTP/1.1 connection re-use.
            private let reuseIterator: Bool

            /// A handle for HTTP/1.1 connection re-use.
            static func reusable(state: ExchangeState) -> RequestHandle {
                RequestHandle(state: state, reuseIterator: true)
            }

            /// A handle for an HTTP/2 or HTTP/3 stream.
            static func singleUse(state: ExchangeState) -> RequestHandle {
                RequestHandle(state: state, reuseIterator: false)
            }

            /// Records that the reader seen the request `.end` part. For HTTP/1.1, the iterator is moved back into the
            /// exchange state to support connection re-use. Otherwise, the iterator is dropped.
            consuming func recordEnd(releasing iterator: consuming sending Reader.Iterator) {
                guard self.reuseIterator else {
                    self.state.storage.withLock { $0.finishedReading = true }
                    return
                }

                nonisolated(unsafe) let iterator: Reader.Iterator? = iterator
                self.state.storage.withLock { storage in
                    storage.finishedReading = true
                    _ = unsafe storage.iterator.swap(newValue: iterator)
                }
            }
        }

        /// The response sender's access to the request-response exchange state.
        struct ResponseHandle: ~Copyable, Sendable {
            private let state: ExchangeState

            init(state: ExchangeState) {
                self.state = state
            }

            /// Records that the response was sent.
            consuming func recordEnd() {
                self.state.storage.withLock { $0.finishedWriting = true }
            }
        }
    }

    /// Coordinates the re-use of an HTTP/1.1 connection.
    struct HTTP1ConnectionReuseCoordinator: ~Copyable {
        /// The state shared by every request-response exchange on the connection.
        let state = ExchangeState()

        private var requestIterator: Disconnected<Reader.Iterator?>
        private let responseWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>

        /// Initializes the coordinator.
        ///
        /// - Parameters:
        ///   - requestIterator: The iterator that yields the connection's HTTP request parts.
        ///   - responseWriter: The writer for the connection's HTTP response parts.
        init(
            requestIterator: consuming sending Reader.Iterator,
            responseWriter: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        ) {
            self.requestIterator = Disconnected(value: requestIterator)
            self.responseWriter = responseWriter
        }

        /// Reads the head of the next request on the connection.
        ///
        /// - Precondition: No exchange is in progress.
        /// - Returns: The request head, or `nil` if there are no more requests on the connection.
        /// - Throws: The error thrown by the iterator, after which the connection cannot be used again.
        mutating func nextRequestHead(logger: Logger) async throws -> HTTPRequest? {
            guard var iterator = self.requestIterator.swap(newValue: nil) else {
                preconditionFailure("An exchange is in progress")
            }

            let requestHead = try await iterator.nextRequestHead(logger: logger)
            _ = self.requestIterator.swap(newValue: iterator)
            return requestHead
        }

        /// Makes the request reader for the next exchange on the connection.
        ///
        /// - Precondition: No exchange is in progress.
        mutating func makeReader() -> sending Reader {
            guard let iterator = self.requestIterator.swap(newValue: nil) else {
                preconditionFailure("An exchange is in progress")
            }

            assert(!self.state.finishedReading && !self.state.finishedWriting, "Exchange state wasn't reset")
            return Reader(iterator: iterator, exchangeState: .reusable(state: self.state))
        }

        /// Makes the response sender for the next exchange on the connection.
        func makeResponseSender() -> sending ResponseSender {
            ResponseSender(writer: self.responseWriter, exchangeState: .init(state: self.state))
        }

        /// Recovers the iterator from the exchange state so that the connection can be re-used for the next request.
        ///
        /// - Returns: Whether the connection can be re-used.
        mutating func recoverIterator() -> Bool {
            guard let iterator = self.state.takeIterator() else { return false }
            _ = self.requestIterator.swap(newValue: iterator)
            return true
        }
    }
}
