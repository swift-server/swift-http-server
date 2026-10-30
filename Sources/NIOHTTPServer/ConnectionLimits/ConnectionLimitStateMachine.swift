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

import NIOCore

/// Decides when ``ConnectionLimitHandler`` may forward `read()` calls and admit accepted connections.
struct ConnectionLimitStateMachine {
    /// Tracks whether a `read()` call is waiting to be forwarded.
    private enum ReadState {
        /// We are not holding back a `read()` call.
        case idle

        /// We are holding back a `read()` call until an admitted connection closes.
        case waitingForCapacity

        /// We are holding back a `read()` call until the connection rate limiter has a token again.
        case waitingForToken

        /// The handler was removed.
        case removed
    }

    /// The `maxConnections` limit: how many admitted connections can be open at once.
    private struct OpenConnectionLimit {
        let maxConnections: Int
        private var openConnections = 0

        init(maxConnections: Int) {
            self.maxConnections = maxConnections
        }

        /// Whether another connection may be admitted.
        var hasCapacity: Bool {
            self.openConnections < self.maxConnections
        }

        mutating func connectionOpened() {
            self.openConnections += 1
        }

        mutating func connectionClosed() {
            assert(self.openConnections > 0, "More connections closed than opened")
            self.openConnections -= 1
        }
    }

    /// The `newConnectionRateLimit`: how quickly incoming connections can be accepted.
    private struct RateLimit {
        private var tokens: TokenBucket

        init(newConnectionRateLimit: Int) {
            // Round up so that tokens never refill faster than the configured rate.
            let rate = Int64(newConnectionRateLimit)
            let refillInterval = TimeAmount.nanoseconds((1_000_000_000 + rate - 1) / rate)
            self.tokens = TokenBucket(capacity: newConnectionRateLimit, refillInterval: refillInterval)
        }

        /// How long until another connection may be accepted, or `nil` if a connection can be accepted now.
        mutating func timeUntilNextConnection(now: NIODeadline) -> TimeAmount? {
            self.tokens.timeUntilNextToken(now: now)
        }

        /// Takes a token for an admitted connection.
        mutating func connectionAdmitted(now: NIODeadline) {
            self.tokens.take(now: now)
        }
    }

    private var readState: ReadState = .idle

    /// `nil` when `maxConnections` isn't set.
    private var openConnectionLimit: OpenConnectionLimit?

    /// `nil` when `newConnectionRateLimit` isn't set.
    private var rateLimit: RateLimit?

    /// At least one of the limits must be set.
    ///
    /// - Parameters:
    ///   - maxConnections: How many admitted connections can be open at once. `nil` means unlimited.
    ///   - newConnectionRateLimit: How quickly connections can be accepted. `nil` means unlimited.
    init(maxConnections: Int? = nil, newConnectionRateLimit: Int? = nil) {
        assert(
            maxConnections != nil || newConnectionRateLimit != nil,
            "A ConnectionLimitStateMachine needs at least one limit"
        )

        self.openConnectionLimit = maxConnections.map { limit in
            OpenConnectionLimit(maxConnections: limit)
        }

        self.rateLimit = newConnectionRateLimit.map { limit in
            RateLimit(newConnectionRateLimit: limit)
        }
    }

    /// The action the handler should take following a `read()` call.
    enum ReadAction: Equatable {
        /// Forward the `read()` call.
        case forwardRead

        /// Keep the `read()` call waiting, and schedule the next-token callback which should call
        /// ``nextTokenDue(now:)`` after `delay`.
        case waitForNextToken(in: TimeAmount)

        /// Don't forward the `read()` call now.
        case doNothing
    }

    /// Determines whether the handler should forward or hold back an incoming `read()` call.
    mutating func read(now: NIODeadline) -> ReadAction {
        switch self.readState {
        case .idle, .waitingForCapacity:
            return self.readIfAllowed(now: now)

        case .waitingForToken:
            // The next-token callback is scheduled. Hold for now; that callback will decide what to do with the
            // `read()` call.
            return .doNothing

        case .removed:
            preconditionFailure("read() called after the handler was removed")
        }
    }

    /// Forwards the waiting read if no limit is reached.
    private mutating func readIfAllowed(now: NIODeadline) -> ReadAction {
        switch self.readState {
        case .idle, .waitingForCapacity, .waitingForToken:
            if let openConnectionLimit = self.openConnectionLimit {
                guard openConnectionLimit.hasCapacity else {
                    // We hit the limit for active connections. Hold the `read()` call until some connections close.
                    self.readState = .waitingForCapacity
                    return .doNothing
                }
            }

            if let delay = self.rateLimit?.timeUntilNextConnection(now: now) {
                // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                self.readState = .waitingForToken
                return .waitForNextToken(in: delay)
            }

            self.readState = .idle
            return .forwardRead

        case .removed:
            preconditionFailure("Only a new or held read() call should be checked against the limits")
        }
    }

    /// Informs the state machine that the handler accepted a connection.
    mutating func connectionAccepted(now: NIODeadline) {
        guard self.readState != .removed else {
            preconditionFailure("connectionAccepted(now:) called after the handler was removed")
        }

        // We might temporarily exceed the limits here. This is because a single `read()` call can potentially lead to
        // multiple connections being accepted (depending on the `MaxMessagesPerReadOption` channel option, which
        // defaults to 4).
        //
        // For the connection rate limit, the token balance becomes negative when we exceed the limit. While the token
        // balance is negative, we artificially consume tokens (i.e. take a token and do nothing with it) until the
        // "debt" is repaid. For the active connection limit, we just go over the limit. New connections are only
        // admitted once the limit comes down.
        self.rateLimit?.connectionAdmitted(now: now)

        self.openConnectionLimit?.connectionOpened()
    }

    /// An admitted connection closed.
    mutating func connectionClosed(now: NIODeadline) -> ReadAction {
        switch self.readState {
        case .idle:
            self.openConnectionLimit?.connectionClosed()
            return .doNothing

        case .waitingForCapacity:
            self.openConnectionLimit?.connectionClosed()
            // We previously held back a `read()` call due to the connection limit being hit. Check if that `read()`
            // call can be forwarded now.
            return self.readIfAllowed(now: now)

        case .waitingForToken:
            self.openConnectionLimit?.connectionClosed()
            // The next-token callback is scheduled. That callback will decide whether we can call `read()` again.
            return .doNothing

        case .removed:
            return .doNothing
        }
    }

    /// The next-token callback scheduled by a ``ReadAction/waitForNextToken(in:)`` action was called.
    mutating func nextTokenDue(now: NIODeadline) -> ReadAction {
        switch self.readState {
        case .waitingForToken:
            // We previously held back a `read()` call due to the connection rate limit being hit. We have now waited
            // for the token refill interval, so let's check if the `read()` call can be forwarded now.
            return self.readIfAllowed(now: now)

        case .idle, .waitingForCapacity:
            preconditionFailure("nextTokenDue(now:) called while no next-token callback is scheduled")

        case .removed:
            return .doNothing
        }
    }

    /// What the handler should do once it is removed from the pipeline.
    enum HandlerRemovedAction: Equatable {
        /// Cancel the next-token callback, which is scheduled.
        case cancelNextTokenCallback

        /// There's nothing to clean up.
        case doNothing
    }

    /// The handler was removed from the pipeline. Nothing is forwarded or started after this.
    mutating func handlerRemoved() -> HandlerRemovedAction {
        switch self.readState {
        case .waitingForToken:
            self.readState = .removed
            return .cancelNextTokenCallback

        case .idle, .waitingForCapacity:
            self.readState = .removed
            return .doNothing

        case .removed:
            preconditionFailure("handlerRemoved() called twice")
        }
    }
}
