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

import Synchronization

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer {
    /// Something that happened on a connection, as reported by ``ConnectionEvents``.
    @nonexhaustive
    public enum ConnectionEvent: Sendable, Hashable {
        /// The peer's address changed.
        ///
        /// Over HTTP/3, a client can migrate its QUIC connection to a new network path (RFC 9000 § 9): for example,
        /// when it moves from Wi-Fi to cellular, or when a NAT rebinds the port it is reachable on. The associated value
        /// is the peer's new address, which ``ConnectionContext/remoteAddress`` reports from then on.
        case remoteAddressChanged(NIOHTTPServer.SocketAddress)
    }

    /// The events that happen on a connection.
    ///
    /// Any number of tasks can iterate this sequence concurrently: for example, a ``NIOHTTPServerConnectionHandler``
    /// alongside the request handlers of every request in flight on the connection. Each iterator receives every event
    /// that happens after it is created, and finishes once the connection closes.
    ///
    /// An iterator that falls behind keeps only the most recent events, dropping older ones. The connection's state,
    /// such as ``ConnectionContext/remoteAddress``, is always current, so read it rather than relying on receiving every
    /// event.
    ///
    /// ```swift
    /// for await event in requestContext.connectionEvents {
    ///     switch event {
    ///     case .remoteAddressChanged(let address):
    ///         logger.info("Client migrated", metadata: ["address": "\(address)"])
    ///     default:
    ///         break
    ///     }
    /// }
    /// ```
    public struct ConnectionEvents: AsyncSequence, Sendable {
        let broadcaster: ConnectionEventBroadcaster

        init(broadcaster: ConnectionEventBroadcaster) {
            self.broadcaster = broadcaster
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(base: self.broadcaster.subscribe().makeAsyncIterator())
        }

        /// An iterator over a connection's events.
        public struct AsyncIterator: AsyncIteratorProtocol {
            private var base: AsyncStream<ConnectionEvent>.Iterator

            init(base: AsyncStream<ConnectionEvent>.Iterator) {
                self.base = base
            }

            /// Returns the next event, or `nil` once the connection has closed or the current task is cancelled.
            public mutating func next(isolation actor: isolated (any Actor)?) async -> ConnectionEvent? {
                await self.base.next(isolation: actor)
            }

            /// Returns the next event, or `nil` once the connection has closed or the current task is cancelled.
            public mutating func next() async -> ConnectionEvent? {
                await self.base.next(isolation: #isolation)
            }
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.ConnectionEvents.AsyncIterator: Sendable {}

/// Delivers each of a connection's events to every ``NIOHTTPServer/ConnectionEvents`` iterator that exists when it
/// happens.
///
/// This is what lets several handlers iterate a connection's events concurrently: the iterators of a single
/// `AsyncStream` would instead compete for its elements, with each event reaching only one of them.
@available(anyAppleOS 27.0, *)
final class ConnectionEventBroadcaster: Sendable {
    /// How many undelivered events each iterator buffers before dropping the oldest.
    static let bufferedEventLimit = 16

    private struct State {
        var subscribers: [Int: AsyncStream<NIOHTTPServer.ConnectionEvent>.Continuation] = [:]
        var nextSubscriberID = 0
        var isFinished = false
    }

    private let state = Mutex(State())

    /// The number of iterators currently receiving events.
    var subscriberCount: Int {
        self.state.withLock { $0.subscribers.count }
    }

    /// Returns a stream of the events that happen from now on, which finishes once ``finish()`` is called.
    func subscribe() -> AsyncStream<NIOHTTPServer.ConnectionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NIOHTTPServer.ConnectionEvent.self,
            bufferingPolicy: .bufferingNewest(Self.bufferedEventLimit)
        )

        let subscriberID: Int? = self.state.withLock { state in
            guard !state.isFinished else { return nil }
            let subscriberID = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.subscribers[subscriberID] = continuation
            return subscriberID
        }

        guard let subscriberID else {
            // The connection has already closed, so there is nothing left to report.
            continuation.finish()
            return stream
        }

        // Stop delivering to an iterator once it is dropped, or the task iterating it is cancelled.
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: subscriberID) }
        }

        return stream
    }

    /// Delivers `event` to every subscribed iterator.
    func yield(_ event: NIOHTTPServer.ConnectionEvent) {
        self.state.withLock { state in
            for subscriber in state.subscribers.values {
                subscriber.yield(event)
            }
        }
    }

    /// Ends every subscribed iterator, and any that subscribe afterwards.
    func finish() {
        let subscribers = self.state.withLock { state in
            state.isFinished = true
            let subscribers = state.subscribers
            state.subscribers = [:]
            return subscribers
        }

        // Outside the lock: finishing a stream runs its termination handler, which takes the lock.
        for subscriber in subscribers.values {
            subscriber.finish()
        }
    }
}
